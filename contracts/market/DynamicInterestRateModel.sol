// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";
import { SECONDS_PER_YEAR, WAD, WAD_SQUARED } from "contracts/libraries/Constants.sol";

import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { ERC165 } from "contracts/libraries/external/ERC165.sol";

import { IBorrowableCToken, IInterestRateModel } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

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
///            modifier until a borrowable Curvance token is properly linked
///            to it via setlinkedToken().
///
///            If a borrowable Curvance token updates to another dynamic
///            interest rate model contract then this contract theoretically
///            can still be called by it afterwards if the smart contract was
///            malformed, this does not really have any tangible impact but
///            for developers who may adapt this smart contract in the future,
///            I figure its worth mentioning.
///
///            If implementing this dynamic interest rate model, its suggested
///            to not play too much with `_MAX_VERTEX_ADJUSTMENT_RATE` because 
///            a user can try to "game" the multiplier updates by borrowing
///            large amounts to increase borrow rates, and repaying 20 minutes
///            later. Or lending a bunch to "suppress" interest rates, with
///            shorter adjustment rates this risk becomes virtually zero. 
///            
contract DynamicInterestRateModel is IInterestRateModel, ERC165 {
    /// TYPES ///

    /// @title Rates Configuration
    /// @notice Stores configuration data for current Dynamic Interest
    ///         Rate Model.
    /// @param baseInterestRate Base rate at which interest is accumulated,
    ///                         per second.
    /// @param vertexInterestRate Vertex rate at which interest is
    ///                           accumulated, per second.
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

    
    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;

    /// @notice Maximum Rate at which the vertex multiplier will
    ///         decay per adjustment, in `WAD`.
    /// @dev .05e18 = 5%.
    uint256 internal constant _MAX_VERTEX_DECAY_RATE = .05e18;
    /// @notice The maximum frequency in which the vertex can have
    ///         between adjustments. It is important that this value is not
    ///         too high as users could in theory borrow a ton of assets
    ///         right before adjustment shifts, artificially increasing rates.
    uint256 internal constant _MAX_VERTEX_ADJUSTMENT_RATE = 4 hours;
    /// @notice The minimum frequency in which the vertex can have
    ///         between adjustments.
    uint256 internal constant _MIN_VERTEX_ADJUSTMENT_RATE = 20 minutes;
    /// @notice The maximum rate at with the vertex multiplier is adjusted,
    ///         in WAD on top of base rate (1 `WAD`).
    ///         E.g. 1 * WAD = 200% multiplied to vertex interest rate per
    ///         adjustment at 100% utilization,
    ///         due to 100% (in WAD) applied on top.
    uint256 internal constant _MAX_VERTEX_ADJUSTMENT_VELOCITY = 1e18;
    /// @notice The minimum rate at with the vertex multiplier is adjusted,
    ///         in WAD on top of base rate (1 `WAD`).
    ///         E.g. 0.1 * WAD = 110% multiplied to vertex interest rate per
    ///         adjustment at 100% utilization,
    ///         due to 100% (in WAD) applied on top.
    uint256 internal constant _MIN_VERTEX_ADJUSTMENT_VELOCITY = 0.1e18;
    /// @notice The maximum value that the vertex interest rate can
    ///         be set to begin at, in `WAD`.
    ///         E.g. 0.99 * WAD = Vertex rate begins at 99% utilization.
    uint256 internal constant _MAX_VERTEX_UTIL_START = 0.99e18;
    /// @notice The maximum value that the annual base interest rate can
    ///         be set to, in `WAD`.
    ///         E.g. 1.5 * WAD = 150% Base Interest Rate value at
    ///         `vertexStartingPoint` % borrowing utilization.
    uint256 internal constant _MAX_BASE_INTEREST_RATE_PER_YEAR = 1.5e18;
    /// @notice The maximum value that the annual vertex interest rate can
    ///         be set to, in `WAD`.
    ///         E.g. 2 * WAD = 200% Vertex Interest Rate value at
    ///         100% borrowing utilization.
    uint256 internal constant _MAX_VERTEX_INTEREST_RATE_PER_YEAR = 2e18;
    /// @notice The maximum value that the `vertexMultiplierMax` can be set
    ///         to, in `WAD`.
    ///         E.g. 1 * WAD = 100% Maximum vertex multiplier maximum value.
    /// @dev Our theoretical limit for the vertex multiplier is:
    ///      (2^256 - 1) / 3e36 = 3.8597e40.
    ///      Where 3e36 is the theoretical maximum value of shift and
    ///      2^256 - 1 is type(uint256).max.
    ///      As a result, we cap the vertex maximum before this number to
    ///      prevent any overflows on values.
    uint256 internal constant _MAXIMUM_VERTEX_MULTIPLIER_MAX = 1e40;
    /// @notice The minimum value that the `vertexMultiplierMax` can be set
    ///         to, in `WAD`.
    ///         E.g. 1 * WAD = 100% Minimum vertex multiplier maximum value.
    uint256 internal constant _MINIMUM_VERTEX_MULTIPLIER_MAX = 1e18;
    /// @notice The interval at which interest accrual is calculated,
    ///         in seconds.
    /// @dev 10 minutes = 600 seconds.
    uint256 internal constant _INTEREST_ACCRUAL_PERIOD = 10 minutes;
    /// @notice Mask of `vertexMultiplier` in `_currentRates`.
    uint256 internal constant _BITMASK_VERTEX_MULTIPLIER = (1 << 192) - 1;
    /// @notice The bit position of `nextUpdateTimestamp` in `_currentRates`.
    uint256 internal constant _BITPOS_UPDATE_TIMESTAMP = 192;
    /// @dev `bytes4(keccak256(bytes("DynamicInterestRateModel__Unauthorized()")))`.
    uint256 internal constant _UNAUTHORIZED_SELECTOR = 0xf7ff5148;

    /// STORAGE ///

    /// @notice The borrowable Curvance token linked to this interest rate
    ///         model contract.
    /// @dev Once this token is set it can never be changed again
    ///      replicating an immutable value, it also will be completely
    ///      depreciated if that token ever switches to another
    ///      interest rate model, automatically depreciating this
    ///      implementation.
    address public linkedToken;

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

    event TokenLinked(address cTokenAddress);

    /// ERRORS ///

    error DynamicInterestRateModel__Unauthorized();
    error DynamicInterestRateModel__InvalidToken();
    error DynamicInterestRateModel__InvalidUtilizationStart();
    error DynamicInterestRateModel__InvalidInterestRatePerYear();
    error DynamicInterestRateModel__InvalidAdjustmentRate();
    error DynamicInterestRateModel__InvalidAdjustmentVelocity();
    error DynamicInterestRateModel__InvalidDecayRate();
    error DynamicInterestRateModel__InvalidMultiplierMax();
    error DynamicInterestRateModel__InvalidThresholdLength();

    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
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
        ICentralRegistry cr,
        uint256 baseRatePerYear,
        uint256 vertexRatePerYear,
        uint256 vertexUtilStart,
        uint256 adjustmentRate,
        uint256 adjustmentVelocity,
        uint256 vertexMultiplierMax,
        uint256 decayRate
    ) {
        CentralRegistryLib._isCentralRegistry(cr);
        centralRegistry = cr;

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

    /// @notice Sets the dynamic interest rate model's linked borrowable
    ///         Curvance token (cToken) which interest rates this contract
    ///         will manage.
    /// @dev Once this function is properly it can never be called again.
    /// @param cTokenAddress The address of the token to be linked
    ///                      to this interest rate model contract.
    function setLinkedToken(address cTokenAddress) external {
        if (!centralRegistry.hasDaoPermissions(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        // Validate that a borrowable Curvance token has not already been
        // linked to this smart contract.
        if (linkedToken != address(0)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        // Validate that the token being linked is actually a borrowable token
        // if the token is not a Curvance token this will also natively fail,
        // which is fine too.
        if (!IBorrowableCToken(cTokenAddress).isBorrowable()) {
            revert DynamicInterestRateModel__InvalidToken();
        }

        // Validate that the token is actually expecting this interest
        // rate model to be linked to it.
        if (
            address(IBorrowableCToken(cTokenAddress).interestRateModel()) !=
            address(this)
        ) {
            revert DynamicInterestRateModel__InvalidToken();
        }

        linkedToken = cTokenAddress;

        emit TokenLinked(cTokenAddress);
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
        _checkMarketPermissions();

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

    /// @notice Calculates the current borrow rate per second,
    ///         and updates the vertex multiplier if necessary.
    /// @param assetsHeld The amount of underlying assets held in the pool.
    /// @param debt The amount of outstanding debt in the pool.
    /// @return borrowRate The borrow rate percentage per second, in `WAD`.
    function getBorrowRateWithUpdate(
        uint256 assetsHeld,
        uint256 debt
    ) external returns (uint256 borrowRate) {
        // Validate that the linked token itself is calling to update
        // its interest accrued.
        if (msg.sender != linkedToken) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        uint256 util = utilizationRate(assetsHeld, debt);
        RatesConfiguration memory config = ratesConfig;
        uint256 vertexPoint = config.vertexStartingPoint;

        bool belowVertex = (util <= vertexPoint);

        // Pull current interest rate.
        if (belowVertex) {
            borrowRate = _getBaseRate(util);
        } else {
            borrowRate = _getBaseRate(vertexPoint) +
                _getVertexRate(util - vertexPoint);
        }

        // Update interest rate vertex multiplier, if necessary.
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
    /// @param assetsHeld The amount of underlying assets held in the pool.
    /// @param debt The amount of outstanding debt in the pool.
    /// @return The borrow rate percentage per year, in `WAD`.
    function getPredictedBorrowRatePerYear(
        uint256 assetsHeld,
        uint256 debt
    ) external view returns (uint256) {
        return
            SECONDS_PER_YEAR * getPredictedBorrowRate(assetsHeld, debt);
    }

    /// @notice Calculates the current borrow rate per year.
    /// @param assetsHeld The amount of underlying assets held in the pool.
    /// @param debt The amount of outstanding debt in the pool.
    /// @return The borrow rate percentage per year, in `WAD`.
    function getBorrowRatePerYear(
        uint256 assetsHeld,
        uint256 debt
    ) external view returns (uint256) {
        return
            SECONDS_PER_YEAR * getBorrowRate(assetsHeld, debt);
    }

    /// @notice Calculates the current supply rate per year.
    /// @param assetsHeld The amount of underlying assets held in the pool.
    /// @param debt The amount of outstanding debt in the pool.
    /// @param interestFee The current interest accrual fee for the market.
    /// @return The supply rate percentage per year, in `WAD`.
    function getSupplyRatePerYear(
        uint256 assetsHeld,
        uint256 debt,
        uint256 interestFee
    ) external view returns (uint256) {
        return
            SECONDS_PER_YEAR * getSupplyRate(assetsHeld, debt, interestFee);
    }

    /// @notice Returns the interval at which interest accrual is calculated.
    /// @notice The interval at which interest accrual is calculated,
    ///         in seconds.
    function accrualPeriod() external pure returns (uint256) {
        return _INTEREST_ACCRUAL_PERIOD;
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

    /// @notice Calculates the borrow utilization rate of the market.
    /// @param assetsHeld The amount of underlying assets held in the pool.
    /// @param debt The amount of outstanding debt in the pool.
    /// @return result The utilization rate between [0, WAD].
    function utilizationRate(
        uint256 assetsHeld,
        uint256 debt
    ) public pure returns (uint256 result) {
        // Utilization rate is 0 when there are no outstanding debt.
        if (debt == 0) {
            return 0;
        }

        result = _mulDiv(debt, WAD, assetsHeld + debt);
    }

    /// @notice Calculates the current borrow rate per second,
    ///         with updated vertex multiplier applied.
    /// @param assetsHeld The amount of underlying assets held in the pool.
    /// @param debt The amount of outstanding debt in the pool.
    /// @return result The borrow rate percentage per second, in `WAD`.
    function getPredictedBorrowRate(
        uint256 assetsHeld,
        uint256 debt
    ) public view returns (uint256 result) {
        uint256 util = utilizationRate(assetsHeld, debt);
        RatesConfiguration memory config = ratesConfig;
        uint256 vertexPoint = config.vertexStartingPoint;

        // Query base interest rate directly since vertex multiplier is not
        // applied.
        if (util <= vertexPoint) {
            return _getBaseRate(util);
        }

        if (vertexMultiplier() == WAD && util < config.increaseThreshold) {
            return (_getVertexRate(util - vertexPoint) +
                _getBaseRate(vertexPoint));
        }

        uint256 newMultiplier = _updateForAboveVertex(config, util);
        result = _getBaseRate(vertexPoint) +
        _mulDiv(
            util - vertexPoint,
            config.vertexInterestRate * newMultiplier,
            WAD_SQUARED
        );
    }

    /// @notice Calculates the current borrow rate, per second.
    /// @dev This function's intention is for frontend data querying and
    ///     should not be used for onchain execution.
    /// @param assetsHeld The amount of underlying assets held in the pool.
    /// @param debt The amount of outstanding debt in the pool.
    /// @return result The borrow interest rate percentage, per second,
    ///                in `WAD`.
    function getBorrowRate(
        uint256 assetsHeld,
        uint256 debt
    ) public view returns (uint256 result) {
        uint256 util = utilizationRate(assetsHeld, debt);
        uint256 vertexPoint = ratesConfig.vertexStartingPoint;

        if (util <= vertexPoint) {
            unchecked {
                return _getBaseRate(util);
            }
        }

        result =
            _getBaseRate(vertexPoint) + _getVertexRate(util - vertexPoint);
    }

    /// @notice Calculates the current supply rate, per second.
    /// @dev This function's intention is for frontend data querying and
    ///     should not be used for onchain execution.
    /// @param assetsHeld The amount of underlying assets held in the pool.
    /// @param debt The amount of outstanding debt in the pool.
    /// @param interestFee The current interest rate protocol fee
    ///                    for the market token.
    /// @return result The supply interest rate percentage, per second,
    ///                in `WAD`.
    function getSupplyRate(
        uint256 assetsHeld,
        uint256 debt,
        uint256 interestFee
    ) public view returns (uint256 result) {
        // RateToLenders = (borrowRate * (1 - Interest Fee)) / WAD.
        uint256 rateToLenders =  _mulDiv(
            getBorrowRate(assetsHeld, debt),
            WAD - interestFee,
            WAD
        );

        // Supply Rate = (utilizationRate * rateToLenders) / WAD.
        result = _mulDiv(
            utilizationRate(assetsHeld, debt),
            rateToLenders,
            WAD
        );
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
    /// @param util The utilization rate of the market, in `WAD`.
    /// @return result The calculated base interest rate, in `WAD`.
    function _getBaseRate(
        uint256 util
    ) internal view returns (uint256 result) {
        result = _mulDiv(util, ratesConfig.baseInterestRate, WAD);
    }

    /// @notice Calculates the interest rate under `vertexInterestRate`
    ///         conditions, e.g. `util` > `vertex ` based on market
    ///         utilization.
    /// @param util The utilization rate of the market above
    ///            `vertexStartingPoint`, in `WAD`.
    /// @return result The calculated vertex interest rate, in `WAD`.
    function _getVertexRate(
        uint256 util
    ) internal view returns (uint256 result) {
        // We divide by WAD_SQUARED instead of WAD to maintain precision.
        result = _mulDiv(
            util,
            ratesConfig.vertexInterestRate * vertexMultiplier(),
            WAD_SQUARED
        );
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

        if (vertexUtilStart > _MAX_VERTEX_UTIL_START) {
            revert DynamicInterestRateModel__InvalidUtilizationStart();
        }

        if (baseRatePerYear > _MAX_BASE_INTEREST_RATE_PER_YEAR) {
            revert DynamicInterestRateModel__InvalidInterestRatePerYear();
        }

        if (vertexRatePerYear > _MAX_VERTEX_INTEREST_RATE_PER_YEAR) {
            revert DynamicInterestRateModel__InvalidInterestRatePerYear();
        }

        // Validate Decay rate is below the maximum bound.
        if (decayRate > _MAX_VERTEX_DECAY_RATE) {
            revert DynamicInterestRateModel__InvalidDecayRate();
        }

        // Validate Adjustment Velocity is in acceptable bounds.
        if (
            adjustmentVelocity > _MAX_VERTEX_ADJUSTMENT_VELOCITY ||
            adjustmentVelocity < _MIN_VERTEX_ADJUSTMENT_VELOCITY
        ) {
            revert DynamicInterestRateModel__InvalidAdjustmentVelocity();
        }

        // Validate Adjustment Rate is in acceptable bounds.
        if (
            adjustmentRate > _MAX_VERTEX_ADJUSTMENT_RATE ||
            adjustmentRate < _MIN_VERTEX_ADJUSTMENT_RATE
        ) {
            revert DynamicInterestRateModel__InvalidAdjustmentRate();
        }

        if (
            vertexMultiplierMax > _MAXIMUM_VERTEX_MULTIPLIER_MAX ||
            vertexMultiplierMax < _MINIMUM_VERTEX_MULTIPLIER_MAX
        ) {
            revert DynamicInterestRateModel__InvalidMultiplierMax();
        }

        RatesConfiguration storage config = ratesConfig;

        config.baseInterestRate = _mulDiv(
            baseRatePerYear,
            WAD,
            SECONDS_PER_YEAR * vertexUtilStart
        );

        config.vertexInterestRate = _mulDiv(
            vertexRatePerYear,
            WAD,
            SECONDS_PER_YEAR * (WAD - vertexUtilStart)
        );

        config.vertexStartingPoint = vertexUtilStart;
        config.vertexMultiplierMax = vertexMultiplierMax;
        config.adjustmentRate = adjustmentRate;
        config.adjustmentVelocity = adjustmentVelocity;

        _currentRates = _packRatesData(
            vertexReset ? WAD : vertexMultiplier(),
            uint64(block.timestamp + config.adjustmentRate)
        );

        config.decayRate = decayRate;

        // Dynamic rates start increasing halfway between desired
        // utilization and 100% utilization, in `WAD`.
        uint256 thresholdLength = (WAD - vertexUtilStart) / 2;
        config.increaseThreshold = vertexUtilStart + thresholdLength;
        config.increaseThresholdMax = WAD;

        if (vertexUtilStart < thresholdLength) {
            revert DynamicInterestRateModel__InvalidThresholdLength();
        }

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
        uint256 decay = _mulDiv(currentMultiplier, config.decayRate, WAD);
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
        uint256 decay = _mulDiv(currentMultiplier, config.decayRate, WAD);
        uint256 newMultiplier;

        if (util <= config.decreaseThresholdMax) {
            // Apply maximum adjustVelocity reduction (shift = 1).
            // We only need to adjust for 1e18 precision since `shift`
            // is not used here.
            // currentMultiplier / (1 + adjustmentVelocity) = newMultiplier.
            newMultiplier = _mulDiv(
                currentMultiplier,
                WAD,
                WAD + config.adjustmentVelocity
            ) - decay;

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
    ///      this period, then the decay rate is applied.
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
    /// @return result The new multiplier with the calculated shift value,
    ///                and decay rate applied.
    function _getPositiveShift(
        uint256 multiplier,
        uint256 adjustmentVelocity,
        uint256 decay,
        uint256 current, // `util`.
        uint256 start, // `increaseThreshold`.
        uint256 end // `increaseThresholdMax`.
    ) internal pure returns (uint256 result) {
        // We do not need to check for current >= end, since we know util is
        // the absolute maximum utilization is 100%, and thus current == end.
        // Which will result in WAD result for `shift`.
        // Thus, this will be bound between [0, WAD].
        uint256 shift = _mulDiv(current - start, WAD, end - start);

        // Apply shift result to adjustment velocity.
        // Then add 100% on top for final adjustment value to `multiplier`.
        shift = WAD_SQUARED + (shift * adjustmentVelocity);

        // Apply positive `shift` effect to `currentMultiplier`, and
        // adjust for 1e36 precision. Then apply decay effect.
        result = _mulDiv(multiplier, shift, WAD_SQUARED) -  decay;
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
    ///      for this period, then the decay rate is applied.
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
    /// @return result The new multiplier with the calculated shift value,
    ///                and decay rate applied.
    function _getNegativeShift(
        uint256 multiplier,
        uint256 adjustmentVelocity,
        uint256 decay,
        uint256 current, // `util`.
        uint256 start, // `decreaseThreshold`.
        uint256 end // `decreaseThresholdMax`.
    ) internal pure returns (uint256 result) {
        // Calculate linear curve multiplier. We know that current > end,
        // based on pre conditional checks.
        // Thus, this will be bound between [0, WAD].
        uint256 shift = _mulDiv(start - current, WAD, start - end);

        // Apply shift result to adjustment velocity.
        // Then add 100% on top for final adjustment value to `multiplier`.
        shift = WAD_SQUARED + (shift * adjustmentVelocity);

        // Apply negative `shift` effect to `currentMultiplier`, and
        // adjust for 1e36 precision. Then apply decay effect.
        result = _mulDiv(multiplier, WAD_SQUARED, shift) -  decay;
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
        uint256 currentRates = _currentRates;
        uint256 timestampCasted;

        // Cast `timestampCasted` with assembly to avoid redundant masking.
        /// @solidity memory-safe-assembly
        assembly {
            timestampCasted := newTimestamp
        }
        currentRates =
            (currentRates & _BITMASK_VERTEX_MULTIPLIER) |
            (timestampCasted << _BITPOS_UPDATE_TIMESTAMP);
        _currentRates = currentRates;
    }

    /// @dev Returns `floor(x * y / d)`.
    /// Reverts if `x * y` overflows, or `d` is zero.
    function _mulDiv(
        uint256 x,
        uint256 y,
        uint256 d
    ) internal pure returns (uint256 z) {
        z = FixedPointMathLib.mulDiv(x, y, d);
    }

    /// @dev Internal helper for reverting efficiently.
    function _revert(uint256 s) internal pure {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, s)
            revert(0x1c, 0x04)
        }
    }

    /// @dev Checks whether the caller has sufficient permissioning.
    function _checkMarketPermissions() internal view virtual {
        if (!centralRegistry.hasMarketPermissions(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
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
