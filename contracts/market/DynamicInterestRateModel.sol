// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { WAD, WAD_SQUARED } from "contracts/libraries/Constants.sol";
import { ERC165 } from "contracts/libraries/external/ERC165.sol";
import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";

import { IEToken } from "contracts/interfaces/IEToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IInterestRateModel } from "contracts/interfaces/IInterestRateModel.sol";

/// @title Curvance Dynamic Interest Rate Model.
/// @notice Manages borrow and supply interest rates for Curvance debt tokens.
/// @dev A dynamically adjusting interest rate model built to incentivize
///      growth, and minimize liquidity crunches.
///
///      At its core the Curvance Dynamic Interest Rate Model uses two
///      different interest rates:
///      The "baseInterestRate" which linearly increases interest until
///      `vertexStartingPoint` is reached, where `vertexInterestRate` then is
///      used instead. This behaves very similar to the classic "Jump Rate"
///      interest rate model just without the risk-free rate.
///
///      This model then builds on top of the previous systems by introducing
///      a dynamic "Vertex Multiplier" which increases the skew of
///      `vertexInterestRate`. The Vertex Multiplier is adjusted upward or
///      downward based on the utilization of liquidity inside the eToken
///      market.
///
///      This means that if utilization remains elevated during update
///      periods, the interest rate paid by borrowers will continually
///      increase. This will, in theory, attract new borrowers who require
///      a higher yield to provide liquidity to a particular market.
///      At the same time, higher borrow rates incentivize interest rate
///      sensitive borrowers to repay their outstanding debt.
///      These two actions both will decrease net liquidity utilization,
///      decreasing borrow rates, and with a heavy enough drop, begin
///      decreasing the Vertex Multiplier.
///
///      This process is optimized by the introduction of a decay mechanism.
///      When the Vertex Multiplier is elevated, the decay rate naturally
///      reduces the excess skew overtime. This has the effect of creating a
///      "downward sloping" interest rate model. From a mathematical sense,
///      this means when the multiplier value is elevated, a constant negative
///      velocity is applied to it, regardless of positive or negative
///      acceleration applied due to liquidity utilization. By having a
///      naturally decreasing interest rate model users are incentivized to
///      continually borrow from the eToken market over other solutions. Then,
///      when liquidity dries up, the interest rate model attracts new lenders.
///      The combination of these two forces should, in theory, create an
///      efficient system that naturally stimulates market growth while also
///      decreasing the risk of liquidity crunches.
///
///      The Vertex Multiplier adjustment logic is as follows:
///
///      When utilization is below `vertexStartingPoint`:
///         If the utilization is below the 'decreaseThresholdMax',
///         decay rate and maximum adjustment velocity is applied.
///         For higher utilizations (but still below the vertex),
///         a new multiplier is calculated by applying a negative curve value
///         to the adjustment. This new multiplier is also subjected to the
///         decay multiplier.
///
///      When utilization is above `vertexStartingPoint`:
///         If the utilization rate is below the 'increaseThreshold',
///         it simply applies the decay to the current multiplier.
///         If the utilization is higher, it calculates a new multiplier by
///         applying a positive curve value to the adjustment. This adjustment
///         is also subjected to the decay multiplier.
///
///      NOTE: The Dynamic Interest Rate model will not be able to update its
///            modifier until an earn token is properly linked to it via
///            setLinkedEToken().
///
///            If an earn token updates to another dynamic interest rate model
///            contract then this contract theoretically can still be called
///            by it afterwards if the smart contract was malformed, this does
///            not really have any tangible impact but for developers who may
///            adapt this smart contract in the future, I figure its worth
///            mentioning.
///
///            If implementing this dynamic interest rate model, its suggested
///            to not play too much with `MAX_VERTEX_ADJUSTMENT_RATE` because 
///            a user can try to "game" the multiplier updates by borrowing
///            large amounts to increase borrow rates, and repaying 20 minutes
///            later. Or lending a bunch to "suppress" interest rates, with
///            shorter adjustment rates this risk becomes virtually zero. 
///            
contract DynamicInterestRateModel is ERC165 {
    /// TYPES ///

    /// @title Rates Configuration
    /// @notice Stores configuration data for current Dynamic Interest
    ///         Rate Model.
    /// @param baseInterestRate Base rate at which interest is accumulated,
    ///                         per compound.
    /// @param vertexInterestRate Vertex rate at which interest is
    ///                           accumulated, per compound.
    /// @param vertexStartingPoint Utilization rate point where vertex rate
    ///                            is used, instead of base rate.
    /// @param adjustmentRate The rate at which the vertex multiplier
    ///                       is adjusted, in seconds.
    /// @param adjustmentVelocity The maximum rate at with the vertex
    ///                           multiplier is adjusted, in `WAD`.
    /// @param vertexMultiplierMax The maximum value that vertexMultiplier
    ///                            can be.
    /// @param decayRate Rate at which the vertex multiplier will decay
    ///                  per update, in `WAD`.
    /// @param increaseThreshold The utilization rate at which the vertex
    ///                          multiplier will begin to increase.
    /// @param increaseThresholdMax The utilization rate at which the vertex
    ///                             multiplier positive velocity will max out.
    /// @param decreaseThreshold The utilization rate at which the vertex
    ///                          multiplier will begin to decrease.
    /// @param decreaseThresholdMax The utilization rate at which the vertex
    ///                             multiplier negative velocity will max out.
    struct RatesConfiguration {
        uint256 baseInterestRate;
        uint256 vertexInterestRate;
        uint256 vertexStartingPoint;
        uint256 adjustmentRate;
        uint256 adjustmentVelocity;
        uint256 vertexMultiplierMax;
        uint256 decayRate;
        uint256 increaseThreshold;
        uint256 increaseThresholdMax;
        uint256 decreaseThreshold;
        uint256 decreaseThresholdMax;
    }

    /// CONSTANTS ///

    /// @notice Rate at which interest is compounded, in seconds.
    /// @dev 10 minutes = 600 seconds.
    uint256 public constant INTEREST_COMPOUND_RATE = 10 minutes;
    /// @notice Maximum Rate at which the vertex multiplier will
    ///         decay per adjustment, in `WAD`.
    /// @dev .05e18 = 5%.
    uint256 public constant MAX_VERTEX_DECAY_RATE = .05e18;
    /// @notice The maximum frequency in which the vertex can have
    ///         between adjustments. It is important that this value is not
    ///         too high as users could in theory borrow a ton of assets
    ///         right before adjustment shifts, artificially increasing rates.
    uint256 public constant MAX_VERTEX_ADJUSTMENT_RATE = 4 hours;
    /// @notice The minimum frequency in which the vertex can have
    ///         between adjustments.
    uint256 public constant MIN_VERTEX_ADJUSTMENT_RATE = 20 minutes;
    /// @notice The maximum rate at with the vertex multiplier is adjusted,
    ///         in WAD on top of base rate (1 `WAD`).
    ///         E.g. 1 * WAD = 200% multiplied to vertex interest rate per
    ///         adjustment at 100% utilization,
    ///         due to 100% (in WAD) applied on top.
    uint256 public constant MAX_VERTEX_ADJUSTMENT_VELOCITY = 1e18;
    /// @notice The minimum rate at with the vertex multiplier is adjusted,
    ///         in WAD on top of base rate (1 `WAD`).
    ///         E.g. 0.1 * WAD = 110% multiplied to vertex interest rate per
    ///         adjustment at 100% utilization,
    ///         due to 100% (in WAD) applied on top.
    uint256 public constant MIN_VERTEX_ADJUSTMENT_VELOCITY = 0.1e18;

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;

    /// @notice Unix time has 31,536,000 seconds per year.
    ///         All my homies hate leap seconds and leap years.
    uint256 internal constant _SECONDS_PER_YEAR = 31_536_000;
    /// @notice Mask of `vertexMultiplier` in `_currentRates`.
    uint256 internal constant _BITMASK_VERTEX_MULTIPLIER = (1 << 192) - 1;
    /// @notice The bit position of `nextUpdateTimestamp` in `_currentRates`.
    uint256 internal constant _BITPOS_UPDATE_TIMESTAMP = 192;
    /// @dev `bytes4(keccak256(bytes("DynamicInterestRateModel__Unauthorized()")))`.
    uint256 internal constant _UNAUTHORIZED_SELECTOR = 0xf7ff5148;
    /// @dev `bytes4(keccak256(bytes("DynamicInterestRateModel__InvalidToken()")))`.
    uint256 internal constant _INVALID_TOKEN_SELECTOR = 0x65fb74c1;

    /// STORAGE ///

    /// @notice The earn token linked to this interest rate model contract.
    /// @dev Once this earn token is set it can never be changed again
    ///      replicating an immutable value, it also will be completely
    ///      depreciated if that earn token ever switches to another
    ///      interest rate model, automatically depreciating this
    ///      implementation.
    address public linkedEToken;

    /// @notice Struct containing current configuration data for the
    ///         dynamic interest rate model.
    RatesConfiguration public ratesConfig;
    /// @dev Internal stored rates data.
    ///      Bits Layout:
    ///      - [0..191]   `vertexMultiplier`.
    ///      - [192..255] `nextUpdateTimestamp`.
    uint256 internal _currentRates;

    /// EVENTS ///

    event NewDynamicInterestRateModel(
        uint256 baseInterestRate,
        uint256 vertexInterestRate,
        uint256 vertexStartingPoint,
        uint256 adjustmentRate,
        uint256 adjustmentVelocity,
        uint256 vertexMultiplierMax,
        uint256 decayRate,
        uint256 increaseThreshold,
        uint256 increaseThresholdMax,
        uint256 decreaseThreshold,
        uint256 decreaseThresholdMax,
        bool vertexReset
    );

    event EarnTokenLinked(address eTokenAddress);

    /// ERRORS ///

    error DynamicInterestRateModel__Unauthorized();
    error DynamicInterestRateModel__InvalidToken();
    error DynamicInterestRateModel__InvalidCentralRegistry();
    error DynamicInterestRateModel__InvalidAdjustmentRate();
    error DynamicInterestRateModel__InvalidAdjustmentVelocity();
    error DynamicInterestRateModel__InvalidDecayRate();
    error DynamicInterestRateModel__InvalidMultiplierMax();

    /// CONSTRUCTOR ///

    /// @param baseRatePerYear The rate of increase in interest rate by
    ///                        utilization rate, in `basis points`.
    /// @param vertexRatePerYear The rate of increase in interest rate by
    ///                          utilization rate after `vertexUtilStart`,
    ///                          in `basis points`.
    /// @param vertexUtilStart The utilization point at which the vertex
    ///                        rate is applied, in `basis points`.
    /// @param adjustmentRate The rate at which the vertex multiplier is
    ///                       adjusted, in `seconds`.
    /// @param adjustmentVelocity The maximum rate at with the vertex
    ///                           multiplier is adjusted, in `basis points`.
    /// @param vertexMultiplierMax The maximum value that vertexMultiplier
    ///                            can be.
    /// @param decayRate Rate at which the vertex multiplier will decay per
    ///                  update, in `basis points`.
    constructor(
        ICentralRegistry centralRegistry_,
        uint256 baseRatePerYear,
        uint256 vertexRatePerYear,
        uint256 vertexUtilStart,
        uint256 adjustmentRate,
        uint256 adjustmentVelocity,
        uint256 vertexMultiplierMax,
        uint256 decayRate
    ) {
        if (
            !ERC165Checker.supportsInterface(
                address(centralRegistry_),
                type(ICentralRegistry).interfaceId
            )
        ) {
            revert DynamicInterestRateModel__InvalidCentralRegistry();
        }

        centralRegistry = centralRegistry_;

        _updateDynamicInterestRateModel(
            baseRatePerYear,
            vertexRatePerYear,
            vertexUtilStart,
            adjustmentRate,
            adjustmentVelocity,
            vertexMultiplierMax,
            decayRate,
            true
        );
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Sets the dynamic interest rate model's linked earn token
    ///         (eToken) which interest rates this contract will manage.
    /// @dev Once this function is properly it can never be called again.
    /// @param eTokenAddress The address of the earn token to be linked
    ///                      to this interest rate model contract.
    function setLinkedEToken(address eTokenAddress) external {
        if (!centralRegistry.hasDaoPermissions(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        // Validate that an earn token has not already been linked to this
        // smart contract.
        if (linkedEToken != address(0)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        // Validate that the token being linked is actually an earn token
        // and not a position token, if the token is not an mToken at all
        // this will also natively fail, which is fine too.
        if (IEToken(eTokenAddress).isPToken()) {
            _revert(_INVALID_TOKEN_SELECTOR);
        }

        // Validate that the earn token is actually expecting this interest
        // rate model to be linked to it.
        if (
            address(IEToken(eTokenAddress).interestRateModel()) !=
            address(this)
        ) {
            _revert(_INVALID_TOKEN_SELECTOR);
        }

        linkedEToken = eTokenAddress;

        emit EarnTokenLinked(eTokenAddress);
    }

    /// @notice Updates the dynamic interest rate model's configuration values
    ///         impacting for interest rates behave for the linked eToken.
    /// @param baseRatePerYear The rate of increase in interest rate by
    ///                        utilization rate, in `basis points`.
    /// @param vertexRatePerYear The rate of increase in interest rate by
    ///                          utilization rate after `vertexUtilStart`,
    ///                          in `basis points`.
    /// @param vertexUtilStart The utilization point at which the vertex
    ///                        rate is applied, in `basis points`.
    /// @param adjustmentRate The rate at which the vertex multiplier is
    ///                       adjusted, in `seconds`.
    /// @param adjustmentVelocity The maximum rate at with the vertex
    ///                           multiplier is adjusted, in `basis points`.
    /// @param vertexMultiplierMax The maximum value that vertexMultiplier
    ///                            can be.
    /// @param decayRate Rate at which the vertex multiplier will decay per
    ///                  update, in `basis points`.
    /// @param vertexReset Whether the vertex multiplier should be reset back
    ///                    to its default value.
    function updateDynamicInterestRateModel(
        uint256 baseRatePerYear,
        uint256 vertexRatePerYear,
        uint256 vertexUtilStart,
        uint256 adjustmentRate,
        uint256 adjustmentVelocity,
        uint256 vertexMultiplierMax,
        uint256 decayRate,
        bool vertexReset
    ) external {
        if (!centralRegistry.hasElevatedPermissions(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        _updateDynamicInterestRateModel(
            baseRatePerYear,
            vertexRatePerYear,
            vertexUtilStart,
            adjustmentRate,
            adjustmentVelocity,
            vertexMultiplierMax,
            decayRate,
            vertexReset
        );
    }

    /// @notice Calculates the current borrow rate per compound,
    ///         and updates the vertex multiplier if necessary.
    /// @param underlyingHeld The amount of underlying assets held in the
    ///                       market token.
    /// @param borrows The amount of outstanding borrows in the market token.
    /// @param reserves The amount of held reserves in the market token.
    /// @return borrowRate The borrow rate percentage per compound, in `WAD`.
    function getBorrowRateWithUpdate(
        uint256 underlyingHeld,
        uint256 borrows,
        uint256 reserves
    ) external returns (uint256 borrowRate) {
        // Validate that the linked earn token itself is calling to update
        // its interest rates.
        if (msg.sender != linkedEToken) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        uint256 util = utilizationRate(underlyingHeld, borrows, reserves);
        RatesConfiguration memory config = ratesConfig;
        uint256 vertexPoint = config.vertexStartingPoint;

        bool belowVertex = (util <= vertexPoint);

        // Pull current interest rate.
        if (belowVertex) {
            unchecked {
                borrowRate = _getBaseInterestRate(util);
            }
        } else {
            // We know this will not underflow or overflow,
            // because of Interest Rate Model configurations.
            unchecked {
                borrowRate = (_getVertexInterestRate(util - vertexPoint) +
                    _getBaseInterestRate(vertexPoint));
            }
        }

        // Execute interest rate update if necessary.
        if (block.timestamp >= updateTimestamp()) {
            // If the vertex multiplier is already at its minimum,
            // and would decrease more, can break here.
            if (vertexMultiplier() == WAD && util < config.increaseThreshold) {
                _setUpdateTimestamp(
                    uint64(block.timestamp + config.adjustmentRate)
                );
                return borrowRate;
            }

            if (belowVertex) {
                _currentRates = _packRatesData(
                    _updateForBelowVertex(config, util),
                    uint64(block.timestamp + config.adjustmentRate)
                );
                return borrowRate;
            }

            _currentRates = _packRatesData(
                _updateForAboveVertex(config, util),
                uint64(block.timestamp + config.adjustmentRate)
            );
        }
    }

    /// @notice Calculates the current borrow rate per year,
    ///         with updated vertex multiplier applied.
    /// @param underlyingHeld The amount of underlying assets held in the
    ///                       market.
    /// @param borrows The amount of borrows in the market.
    /// @param reserves The amount of reserves in the market.
    /// @return The borrow rate percentage per year, in `WAD`.
    function getPredictedBorrowRatePerYear(
        uint256 underlyingHeld,
        uint256 borrows,
        uint256 reserves
    ) external view returns (uint256) {
        return
            _SECONDS_PER_YEAR *
            (getPredictedBorrowRate(underlyingHeld, borrows, reserves) /
                INTEREST_COMPOUND_RATE);
    }

    /// @notice Calculates the current borrow rate per year.
    /// @param underlyingHeld The amount of underlying assets held in the
    ///                       market.
    /// @param borrows The amount of borrows in the market.
    /// @param reserves The amount of reserves in the market.
    /// @return The borrow rate percentage per year, in `WAD`.
    function getBorrowRatePerYear(
        uint256 underlyingHeld,
        uint256 borrows,
        uint256 reserves
    ) external view returns (uint256) {
        return
            _SECONDS_PER_YEAR *
            (getBorrowRate(underlyingHeld, borrows, reserves) /
                INTEREST_COMPOUND_RATE);
    }

    /// @notice Calculates the current supply rate per year.
    /// @param underlyingHeld The amount of underlying assets held in the
    ///                       market.
    /// @param borrows The amount of borrows in the market.
    /// @param reserves The amount of reserves in the market.
    /// @param interestFee The current interest rate reserve factor
    ///                    for the market.
    /// @return The supply rate percentage per year, in `WAD`.
    function getSupplyRatePerYear(
        uint256 underlyingHeld,
        uint256 borrows,
        uint256 reserves,
        uint256 interestFee
    ) external view returns (uint256) {
        return
            _SECONDS_PER_YEAR *
            (getSupplyRate(underlyingHeld, borrows, reserves, interestFee) /
                INTEREST_COMPOUND_RATE);
    }

    /// @notice Returns the rate at which interest compounds, in seconds.
    /// @return The rate at which interest compounds, in seconds.
    function compoundRate() external pure returns (uint256) {
        return INTEREST_COMPOUND_RATE;
    }

    /// @notice Returns the unpacked values from `_currentRates`.
    /// @return The current Vertex Multiplier, in `WAD`.
    /// @return The timestamp for the next vertex multiplier update,
    ///         in unix time.
    function currentRatesData() external view returns (uint256, uint256) {
        uint256 currentRates = _currentRates;
        return (
            uint192(currentRates),
            uint64(currentRates >> _BITPOS_UPDATE_TIMESTAMP)
        );
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Calculates the utilization rate of the market:
    ///         `borrows / (underlyingHeld + borrows - reserves)`.
    /// @param underlyingHeld The amount of underlying assets held in the
    ///                       market.
    /// @param borrows The amount of borrows in the market.
    /// @param reserves The amount of reserves in the market.
    /// @return The utilization rate between [0, WAD].
    function utilizationRate(
        uint256 underlyingHeld,
        uint256 borrows,
        uint256 reserves
    ) public pure returns (uint256) {
        // Utilization rate is 0 when there are no borrows.
        if (borrows == 0) {
            return 0;
        }

        uint256 utilRate = (borrows * WAD) /
            (underlyingHeld + borrows - reserves);
        // If reserves end up growing too much and cause util > 100%,
        // cap it to 100%.
        return utilRate > WAD ? WAD : utilRate;
    }

    /// @notice Calculates the current borrow rate per compound,
    ///         with updated vertex multiplier applied.
    /// @param underlyingHeld The amount of underlying assets held in the
    ///                       market token.
    /// @param borrows The amount of outstanding borrows in the market token.
    /// @param reserves The amount of held reserves in the market token.
    /// @return The borrow rate percentage per compound, in `WAD`.
    function getPredictedBorrowRate(
        uint256 underlyingHeld,
        uint256 borrows,
        uint256 reserves
    ) public view returns (uint256) {
        uint256 util = utilizationRate(underlyingHeld, borrows, reserves);
        RatesConfiguration memory config = ratesConfig;
        uint256 vertexPoint = config.vertexStartingPoint;

        // Query base interest rate directly since vertex multiplier is not
        // applied.
        if (util <= vertexPoint) {
            return _getBaseInterestRate(util);
        }

        if (vertexMultiplier() == WAD && util < config.increaseThreshold) {
            return (_getVertexInterestRate(util - vertexPoint) +
                _getBaseInterestRate(vertexPoint));
        }

        uint256 vertexInterestRate = ratesConfig.vertexInterestRate;
        uint256 newMultiplier = _updateForAboveVertex(config, util);
        return
            _getBaseInterestRate(vertexPoint) +
            ((util - vertexPoint) * vertexInterestRate * newMultiplier) /
            WAD_SQUARED;
    }

    /// @notice Calculates the current borrow rate, per compound.
    /// @dev This function's intention is for frontend data querying and
    ///     should not be used for onchain execution.
    /// @param underlyingHeld The amount of underlying assets held in the
    ///                       market token.
    /// @param borrows The amount of outstanding borrows in the market token.
    /// @param reserves The amount of held reserves in the market token.
    /// @return The borrow interest rate percentage, per compound, in `WAD`.
    function getBorrowRate(
        uint256 underlyingHeld,
        uint256 borrows,
        uint256 reserves
    ) public view returns (uint256) {
        uint256 util = utilizationRate(underlyingHeld, borrows, reserves);
        uint256 vertexPoint = ratesConfig.vertexStartingPoint;

        if (util <= vertexPoint) {
            unchecked {
                return _getBaseInterestRate(util);
            }
        }

        // We know this will not underflow or overflow,
        // because of Interest Rate Model configurations.
        unchecked {
            return (_getVertexInterestRate(util - vertexPoint) +
                _getBaseInterestRate(vertexPoint));
        }
    }

    /// @notice Calculates the current supply rate, per compound.
    /// @dev This function's intention is for frontend data querying and
    ///     should not be used for onchain execution.
    /// @param underlyingHeld The amount of underlying assets held in the
    ///                       market token.
    /// @param borrows The amount of outstanding borrows in the market token.
    /// @param reserves The amount of held reserves in the market token.
    /// @param interestFee The current interest rate protocol fee
    ///                    for the market token.
    /// @return The supply interest rate percentage, per compound, in `WAD`.
    function getSupplyRate(
        uint256 underlyingHeld,
        uint256 borrows,
        uint256 reserves,
        uint256 interestFee
    ) public view returns (uint256) {
        // RateToPool = (borrowRate * oneMinusReserveFactor) / WAD.
        uint256 rateToPool = (getBorrowRate(
            underlyingHeld,
            borrows,
            reserves
        ) * (WAD - interestFee)) / WAD;

        // Supply Rate = (utilizationRate * rateToPool) / WAD.
        return
            (utilizationRate(underlyingHeld, borrows, reserves) * rateToPool) /
            WAD;
    }

    /// @notice Returns the multiplier applied to the vertex interest rate,
    ///         in `WAD`.
    /// @return The multiplier applied to the vertex interest rate, in `WAD`.
    function vertexMultiplier() public view returns (uint256) {
        return _currentRates & _BITMASK_VERTEX_MULTIPLIER;
    }

    /// @notice Returns the next timestamp when `vertexMultiplier`
    ///         will be updated, in unix time.
    /// @return The next timestamp when `vertexMultiplier` will be updated,
    ///         in unix time.
    function updateTimestamp() public view returns (uint256) {
        return uint64(_currentRates >> _BITPOS_UPDATE_TIMESTAMP);
    }

    /// @inheritdoc ERC165
    /// @param interfaceId The interface ID to check.
    /// @return Whether the contract implements the interface.
    function supportsInterface(
        bytes4 interfaceId
    ) public view override returns (bool) {
        return
            interfaceId == type(IInterestRateModel).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Calculates the interest rate for `util` market utilization.
    /// @param util The utilization rate of the market.
    /// @return Returns the calculated interest rate, in `WAD`.
    function _getBaseInterestRate(
        uint256 util
    ) internal view returns (uint256) {
        return (util * ratesConfig.baseInterestRate) / WAD;
    }

    /// @notice Calculates the interest rate under `vertexInterestRate`
    ///         conditions, e.g. `util` > `vertex ` based on market
    ///         utilization.
    /// @param util The utilization rate of the market above
    ///            `vertexStartingPoint`.
    /// @return Returns the calculated interest rate, in `WAD`.
    function _getVertexInterestRate(
        uint256 util
    ) internal view returns (uint256) {
        // We divide by WAD to maintain precision.
        return
            (util * ratesConfig.vertexInterestRate * vertexMultiplier()) /
            WAD_SQUARED;
    }

    /// @notice Updates the parameters of the dynamic interest rate model
    ///         used in the market.
    /// @dev This function sets various parameters for the dynamic interest
    ///      rate model, adjusting how interest rates are calculated based
    ///      on system utilization.
    ///      Emits a {NewDynamicInterestRateModel} event.
    /// @param baseRatePerYear The base interest rate per year,
    ///                        in `basis points`.
    /// @param vertexRatePerYear The vertex interest rate per year,
    ///                          in `basis points`.
    /// @param vertexUtilStart The starting point of the vertex
    ///                        utilization, in `basis points`.
    /// @param adjustmentRate The rate at which the interest model adjusts.
    /// @param adjustmentVelocity The velocity of adjustment for the interest
    ///                           model.
    /// @param vertexMultiplierMax The maximum value that vertexMultiplier
    ///                            can be.
    /// @param decayRate The decay rate applied to the interest model.
    /// @param vertexReset A boolean flag indicating whether the vertex
    ///                    multiplier should be reset.
    function _updateDynamicInterestRateModel(
        uint256 baseRatePerYear,
        uint256 vertexRatePerYear,
        uint256 vertexUtilStart,
        uint256 adjustmentRate,
        uint256 adjustmentVelocity,
        uint256 vertexMultiplierMax,
        uint256 decayRate,
        bool vertexReset
    ) internal {
        // Convert the parameters from basis points to `WAD` format.
        // While inefficient, we want to minimize potential human error
        // as much as possible, even if it costs a bit extra gas on config.
        baseRatePerYear = _bpToWad(baseRatePerYear);
        vertexRatePerYear = _bpToWad(vertexRatePerYear);
        vertexUtilStart = _bpToWad(vertexUtilStart);
        adjustmentVelocity = _bpToWad(adjustmentVelocity);
        vertexMultiplierMax = _bpToWad(vertexMultiplierMax);
        decayRate = _bpToWad(decayRate);

        // Validate Adjustment Velocity is in acceptable bounds.
        if (
            adjustmentVelocity > MAX_VERTEX_ADJUSTMENT_VELOCITY ||
            adjustmentVelocity < MIN_VERTEX_ADJUSTMENT_VELOCITY
        ) {
            revert DynamicInterestRateModel__InvalidAdjustmentVelocity();
        }

        // Validate Adjustment Rate is in acceptable bounds.
        if (
            adjustmentRate > MAX_VERTEX_ADJUSTMENT_RATE ||
            adjustmentRate < MIN_VERTEX_ADJUSTMENT_RATE
        ) {
            revert DynamicInterestRateModel__InvalidAdjustmentRate();
        }

        // Validate Decay rate is below the maximum bound.
        if (decayRate > MAX_VERTEX_DECAY_RATE) {
            revert DynamicInterestRateModel__InvalidDecayRate();
        }

        // Our theoretical limit for the vertex multiplier is:
        // (2^256 - 1) / 3e36 = 3.8597e40.
        // Where 3e36 is the theoretical maximum value of shift and
        // 2^256 - 1 is type(uint256).max.
        // As a result, we cap the vertex maximum before this number to
        // prevent any overflows on values.
        if (vertexMultiplierMax > 1e40) {
            revert DynamicInterestRateModel__InvalidMultiplierMax();
        }

        RatesConfiguration storage config = ratesConfig;

        config.baseInterestRate =
            (INTEREST_COMPOUND_RATE * baseRatePerYear * WAD) /
            (_SECONDS_PER_YEAR * vertexUtilStart);
        config.vertexInterestRate =
            (INTEREST_COMPOUND_RATE * vertexRatePerYear * WAD) /
            (_SECONDS_PER_YEAR * (WAD - vertexUtilStart));

        config.vertexStartingPoint = vertexUtilStart;
        config.vertexMultiplierMax = vertexMultiplierMax;
        config.adjustmentRate = adjustmentRate;
        config.adjustmentVelocity = adjustmentVelocity;

        {
            // Scoping to avoid stack too deep.
            uint256 newMultiplier = vertexReset ? WAD : vertexMultiplier();
            _currentRates = _packRatesData(
                newMultiplier,
                uint64(block.timestamp + config.adjustmentRate)
            );
        }

        config.decayRate = decayRate;

        // Dynamic rates start increasing halfway between desired
        // utilization and 100% utilization, in `WAD`.
        uint256 thresholdLength = (WAD - vertexUtilStart) / 2;
        config.increaseThreshold = vertexUtilStart + thresholdLength;
        config.increaseThresholdMax = WAD;

        // Dynamic rates start decreasing as soon as we are below desired
        // utilization (vertexUtilStart).
        config.decreaseThreshold = vertexUtilStart;
        config.decreaseThresholdMax = vertexUtilStart - thresholdLength;

        RatesConfiguration memory cachedConfig = config;

        emit NewDynamicInterestRateModel(
            cachedConfig.baseInterestRate, // base rate.
            cachedConfig.vertexInterestRate, // vertex base rate.
            vertexUtilStart, // Vertex utilization rate start.
            adjustmentRate, // Adjustment rate.
            adjustmentVelocity, // Adjustment velocity.
            vertexMultiplierMax, // Vertex multiplier max.
            decayRate, // Decay rate.
            cachedConfig.increaseThreshold, // Vertex increase threshold.
            WAD, // Vertex increase threshold max.
            cachedConfig.decreaseThreshold, // Vertex decrease threshold.
            cachedConfig.decreaseThresholdMax, // Vertex decrease threshold max.
            vertexReset // Was vertex multiplier reset.
        );
    }

    /// @notice Calculates and returns the updated multiplier for scenarios
    ///         where the utilization rate is above the vertex.
    /// @dev This function is used to adjust the vertex multiplier based on
    ///      the eToken's current borrow utilization.
    ///      A decay mechanism is incorporated to gradually decrease the
    ///      multiplier, and ensures the multiplier does not fall below 1,
    ///      in WAD.
    ///      NOTE: The multiplier is updated with the following logic:
    ///      If the utilization is below the 'increaseThreshold',
    ///      it simply applies the decay to the current multiplier.
    ///      If the utilization is higher, it calculates a new multiplier by
    ///      applying a positive curve value to the adjustment.
    ///      This adjustment is also subjected to the decay multiplier.
    /// @param config The cached version of the current `RatesConfiguration`.
    /// @param util The current utilization value, used to determine how the
    ///             multiplier should be adjusted.
    /// @return The updated multiplier after applying decay and
    ///         adjustments based on the current utilization level.
    function _updateForAboveVertex(
        RatesConfiguration memory config,
        uint256 util
    ) internal view returns (uint256) {
        uint256 currentMultiplier = vertexMultiplier();
        // Calculate decay rate.
        uint256 decay = (currentMultiplier * config.decayRate) / WAD;
        uint256 newMultiplier;

        if (util <= config.increaseThreshold) {
            newMultiplier = currentMultiplier - decay;

            // Check if decay rate sends new rate below 1.
            return newMultiplier < WAD ? WAD : newMultiplier;
        }

        // Apply a positive multiplier to the current multiplier based on
        // `util` vs `increaseThreshold` and `increaseThresholdMax`.
        // Then apply decay effect.
        newMultiplier = _getPositiveShift(
            currentMultiplier, // `multiplier`.
            config.adjustmentVelocity, // `adjustmentVelocity`.
            decay, // `decay`.
            util, // `current`.
            config.increaseThreshold, // `start`.
            config.increaseThresholdMax // `end`.
        );

        // Update and return with adjustment and decay rate applied.
        // Its theorectically possible for the multiplier to be below 1
        // due to decay, so we need to check like in below vertex.
        if (newMultiplier < WAD) {
            return WAD;
        }

        // Make sure `newMultiplier` is not above the maximum allowed
        // vertex multiplier.
        return
            newMultiplier < config.vertexMultiplierMax
                ? newMultiplier
                : config.vertexMultiplierMax;
    }

    /// @notice Calculates and returns the updated multiplier for scenarios
    ///         where the utilization rate is below the vertex.
    /// @dev This function is used to adjust the vertex multiplier based on
    ///      the eToken's current borrow utilization.
    ///      A decay mechanism is incorporated to gradually decrease the
    ///      multiplier, and ensures the multiplier does not fall below 1,
    ///      in WAD.
    ///      NOTE: The multiplier is updated with the following logic:
    ///      If the utilization is below the 'decreaseThresholdMax',
    ///      decay rate and maximum adjustment velocity is applied.
    ///      For higher utilizations (but still below the vertex),
    ///      a new multiplier is calculated by applying a negative curve value
    ///      to the adjustment. This new multiplier is also subjected to the
    ///      decay multiplier.
    /// @param config The cached version of the current `RatesConfiguration`.
    /// @param util The current utilization value, used to determine how the
    ///             multiplier should be adjusted.
    /// @return The updated multiplier after applying decay and
    ///         adjustments based on the current utilization level.
    function _updateForBelowVertex(
        RatesConfiguration memory config,
        uint256 util
    ) internal view returns (uint256) {
        uint256 currentMultiplier = vertexMultiplier();
        // Calculate decay rate.
        uint256 decay = (currentMultiplier * config.decayRate) / WAD;
        uint256 newMultiplier;

        if (util <= config.decreaseThresholdMax) {
            // Apply maximum adjustVelocity reduction (shift = 1).
            // We only need to adjust for 1e18 precision since `shift`
            // is not used here.
            // currentMultiplier / (1 + adjustmentVelocity) = newMultiplier.
            newMultiplier =
                ((currentMultiplier * WAD) /
                    (WAD + config.adjustmentVelocity)) -
                decay;

            // Check if decay rate sends multiplier below 1.
            return newMultiplier < WAD ? WAD : newMultiplier;
        }

        // Apply a negative multiplier to the current multiplier based on
        // `util` vs `decreaseThreshold` and `decreaseThresholdMax`.
        // Then apply decay effect.
        newMultiplier = _getNegativeShift(
            currentMultiplier, // `multiplier`.
            config.adjustmentVelocity, // `adjustmentVelocity`.
            decay, // `decay`.
            util, // `current`.
            config.decreaseThreshold, // `start`.
            config.decreaseThresholdMax // `end`.
        );

        // Update and return with adjustment and decay rate applied.
        // But first check if new rate sends multiplier below 1.
        return newMultiplier < WAD ? WAD : newMultiplier;
    }

    /// @notice Calculates positive shift value based on `current`,
    ///         `start`, and `end` values. Then applies the linear curve
    ///         effect to the adjustment velocity, then applies the
    ///         adjustment velocity and decay effect to `multiplier`.
    /// @dev The shift is scaled by current, start, and end values and
    ///      multiplied by `WAD` to maintain precision. This results in 1,
    ///      (in `WAD`) if the current value is greater than or equal to
    ///      `end`. The terminal shift is then applied to the
    ///      adjustmentVelocity in determining the growth of `multiplier` for
    ///      this cycle, then the decay rate is applied.
    /// @param multiplier The current vertex multiplier value, in `WAD`.
    /// @param adjustmentVelocity The current adjustment velocity, the maximum
    ///                           rate at with the vertex multiplier is
    ///                           adjusted, as a % multiplier, in `WAD`.
    /// @param decay The current decay rate, calculated as a negative % value,
    ///              in `WAD`.
    /// @param current The current value, representing a point on the curve.
    /// @param start The start value of the curve, marking the beginning of
    ///              the calculation range.
    /// @param end The end value of the curve, marking the end of the
    ///            calculation range.
    /// @return The new multiplier with the calculated shift value,
    ///         and decay rate applied.
    function _getPositiveShift(
        uint256 multiplier,
        uint256 adjustmentVelocity,
        uint256 decay,
        uint256 current, // `util`.
        uint256 start, // `increaseThreshold`.
        uint256 end // `increaseThresholdMax`.
    ) internal pure returns (uint256) {
        // We do not need to check for current >= end, since we know util is
        // the absolute maximum utilization is 100%, and thus current == end.
        // Which will result in WAD result for `shift`.
        // Thus, this will be bound between [0, WAD].
        uint256 shift = ((current - start) * WAD) / (end - start);

        // Apply shift result to adjustment velocity.
        // Then add 100% on top for final adjustment value to `multiplier`.
        shift = WAD_SQUARED + (shift * adjustmentVelocity);

        // Apply positive `shift` effect to `currentMultiplier`, and
        // adjust for 1e36 precision. Then apply decay effect.
        return ((multiplier * shift) / WAD_SQUARED) - decay;
    }

    /// @notice Calculates negative shift value based on `current`,
    ///         `start`, and `end` values. Then applies the linear curve
    ///         effect to the adjustment velocity, then applies the
    ///         adjustment velocity and decay effect to `multiplier`.
    /// @dev The shift is scaled by current, start, and end values and
    ///      multiplied by `WAD` to maintain precision. This results in 1,
    ///      (in `WAD`) if the current value is less than or equal to
    ///      `end`. The terminal shift is then applied to the
    ///      adjustmentVelocity in determining the reduction of `multiplier`
    ///      for this cycle, then the decay rate is applied.
    /// @param multiplier The current vertex multiplier value, in `WAD`.
    /// @param adjustmentVelocity The current adjustment velocity, the maximum
    ///                           rate at with the vertex multiplier is
    ///                           adjusted, as a % multiplier, in `WAD`.
    /// @param decay The current decay rate, calculated as a negative % value,
    ///              in `WAD`.
    /// @param current The current value, representing a point on the curve.
    /// @param start The start value of the curve, marking the beginning of
    ///              the calculation range.
    /// @param end The end value of the curve, marking the end of the
    ///            calculation range.
    /// @return The new multiplier with the calculated shift value,
    ///         and decay rate applied.
    function _getNegativeShift(
        uint256 multiplier,
        uint256 adjustmentVelocity,
        uint256 decay,
        uint256 current, // `util`.
        uint256 start, // `decreaseThreshold`.
        uint256 end // `decreaseThresholdMax`.
    ) internal pure returns (uint256) {
        // Calculate linear curve multiplier. We know that current > end,
        // based on pre conditional checks.
        // Thus, this will be bound between [0, WAD].
        uint256 shift = ((start - current) * WAD) / (start - end);

        // Apply shift result to adjustment velocity.
        // Then add 100% on top for final adjustment value to `multiplier`.
        shift = WAD_SQUARED + (shift * adjustmentVelocity);

        // Apply negative `shift` effect to `currentMultiplier`, and
        // adjust for 1e36 precision. Then apply decay effect.
        return ((multiplier * WAD_SQUARED) / shift) - decay;
    }

    /// @notice Packs `newVertexMultiplier` together with `newTimestamp`,
    ///         to create new packed `_currentRates` value.
    /// @param newVertexMultiplier The new rate at which vertexInterestRate
    ///                            is multiplied, in `WAD`.
    /// @param newTimestamp The new timestamp when the vertex multiplier
    ///                     will be updated.
    /// @return result The new packed rates data value.
    function _packRatesData(
        uint256 newVertexMultiplier,
        uint256 newTimestamp
    ) internal pure returns (uint256 result) {
        /// @solidity memory-safe-assembly
        assembly {
            // Mask `newVertexMultiplier` to the lower 192 bits,
            // in case the upper bits somehow aren't clean.
            newVertexMultiplier := and(
                newVertexMultiplier,
                _BITMASK_VERTEX_MULTIPLIER
            )
            // `newVertexMultiplier | block.timestamp`.
            result := or(
                newVertexMultiplier,
                shl(_BITPOS_UPDATE_TIMESTAMP, newTimestamp)
            )
        }
    }

    /// @notice Packs `newTimestamp` with the current vertex multiplier,
    ///         to create new packed `_currentRates` value.
    /// @param newTimestamp The new timestamp when the vertex multiplier
    ///                     will be updated.
    function _setUpdateTimestamp(uint64 newTimestamp) internal {
        uint256 packedRatesData = _currentRates;
        uint256 timestampCasted;
        // Cast `timestampCasted` with assembly to avoid redundant masking.
        /// @solidity memory-safe-assembly
        assembly {
            timestampCasted := newTimestamp
        }
        packedRatesData =
            (packedRatesData & _BITMASK_VERTEX_MULTIPLIER) |
            (timestampCasted << _BITPOS_UPDATE_TIMESTAMP);
        _currentRates = packedRatesData;
    }

    /// @dev Internal helper for reverting efficiently.
    function _revert(uint256 s) internal pure {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, s)
            revert(0x1c, 0x04)
        }
    }

    /// @notice Multiplies `value` by 1e14 to convert it from `basis points`
    ///         to WAD.
    /// @dev Internal helper function for easily converting between scalars.
    /// @param value The value to convert from basis points to WAD.
    /// @return The value in WAD.
    function _bpToWad(uint256 value) internal pure returns (uint256) {
        return value * 1e14;
    }
}
