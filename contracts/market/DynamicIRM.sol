// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";
import { SECONDS_PER_YEAR, BPS, WAD, WAD_BPS, WAD_SQUARED } from "contracts/libraries/ConstantsLib.sol";

import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { ERC165 } from "contracts/libraries/external/ERC165.sol";

import { IBorrowableCToken, IDynamicIRM } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @title Curvance Dynamic Interest Rate Model.
/// @notice Manages borrow and lending interest rates for borrowable Curvance
///         tokens.
/// @dev A dynamically adjusting interest rate model built to incentivize
///      growth, and minimize liquidity crunches.
///
///      At its core the Curvance Dynamic Interest Rate Model uses two
///      different interest rates:
///      The "baseRatePerSecond" linearly increases interest until
///      `vertexStart` is reached, where `vertexRatePerSecond` then is
///      used instead. This behaves very similar to the classic "Jump Rate"
///      interest rate model just without the risk-free rate.
///
///      This model then builds on top of the previous systems by introducing
///      a dynamic "Vertex Multiplier" which increases the skew of
///      `vertexRatePerSecond`. The Vertex Multiplier is adjusted upward or
///      downward based on the utilization of liquidity inside the
///      borrowableCToken pool.
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
///      continually borrow from the borrowableCToken market over other
///      solutions. Then, when liquidity dries up, the interest rate model
///      attracts new lenders. The combination of these two forces should,
///      in theory, create an efficient system that naturally stimulates
///      market growth while also decreasing the risk of liquidity crunches.
///
///      The Vertex Multiplier adjustment logic is as follows:
///
///      When utilization is below `vertexStart`:
///         If the utilization is below the 'decreaseThresholdEnd',
///         decay rate and maximum adjustment velocity is applied.
///         For higher utilizations (but still below the vertex),
///         a new multiplier is calculated by applying a negative curve value
///         to the adjustment. This new multiplier is also subjected to the
///         decay multiplier.
///
///      When utilization is above `vertexStart`:
///         If the utilization rate is below the 'increaseThresholdStart',
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
contract DynamicIRM is IDynamicIRM, ERC165 {
    /// TYPES ///

    /// @title Rates Configuration
    /// @notice Stores configuration data for current Dynamic Interest
    ///         Rate Model.
    /// @param baseRatePerSecond Rate at which interest is accumulated,
    ///                          before `vertexStart`, per second, in `WAD`.
    /// @param vertexRatePerSecond Rate at which interest is
    ///                            accumulated, after `vertexStart`,
    ///                            per second, in `WAD`.
    /// @param vertexStart Utilization rate point where vertex rate
    ///                    is used, instead of base rate, in `WAD`.
    /// @param increaseThresholdStart The utilization rate at which the vertex
    ///                               multiplier will begin to increase,
    ///                               in `BPS`.
    /// @param decreaseThresholdEnd The utilization rate at which the vertex
    ///                             multiplier negative velocity will max out,
    ///                             in `BPS`.
    /// @param adjustmentVelocity The maximum rate at which `vertexMultiplier`
    ///                           is adjusted per `adjustmentRate`, in `BPS`.
    /// @param decayPerAdjustment The rate at which `vertexMultiplier` will
    ///                           decay back down per `adjustmentRate`,
    ///                           in `BPS`.
    /// @param vertexMultiplierMax The maximum value that `vertexMultiplier`
    ///                            can be, in `multiplier` denomination
    ///                            aka `WAD`.
    /// @param linkedToken The borrowable Curvance token linked to this
    ///                    interest rate model contract.
    /// @dev Once this token is set it can never be changed, like an immutable
    ///      variable, this IRM will also be depreciated if that token ever
    ///      switches IRMs.
    struct RatesConfig {
        uint64 baseRatePerSecond;
        uint64 vertexRatePerSecond;
        uint64 vertexStart;
        uint16 increaseThresholdStart;
        uint16 decreaseThresholdEnd;
        uint16 adjustmentVelocity;
        uint16 decayPerAdjustment;
        uint96 vertexMultiplierMax;
        address linkedToken;
    }

    /// CONSTANTS ///

    /// @notice The interval at which interest rates are adjusted, in seconds.
    /// @dev 10 minutes = 600 seconds.
    uint256 public constant ADJUSTMENT_RATE = 10 minutes;
    
    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;

    /// @notice The maximum value that the annual base interest rate can
    ///         be set to, in `WAD`.
    ///         E.g. 1.5 * WAD = 150% Base Interest Rate value at
    ///         `vertexStart` % borrowing utilization.
    uint256 internal constant _MAX_BASE_INTEREST_RATE_PER_YEAR = 1.5e18;
    /// @notice The maximum value that the annual vertex interest rate can
    ///         be set to, in `WAD`.
    ///         E.g. 2 * WAD = 200% Vertex Interest Rate value at
    ///         100% borrowing utilization.
    uint256 internal constant _MAX_VERTEX_INTEREST_RATE_PER_YEAR = 2e18;
    /// @notice The maximum value that the vertex interest rate can
    ///         be set to begin at, in `WAD`.
    ///         E.g. 0.99 * WAD = Vertex rate begins at 99% utilization.
    uint256 internal constant _MAX_VERTEX_START = 0.99e18;
    /// @notice The minimum value that the vertex interest rate can
    ///         be set to begin at, in `WAD`.
    ///         E.g. 0.50 * WAD = Vertex rate begins at 50% utilization.
    uint256 internal constant _MIN_VERTEX_START = 0.5e18;
    /// @notice The maximum rate at which `vertexMultiplier` is adjusted,
    ///         in BPS on top of base rate (1 `BPS`).
    ///         E.g. 1 * BPS = 200% multiplied to vertex interest rate per
    ///         `ADJUSTMENT_RATE` at 100% utilization.
    uint256 internal constant _MAX_VERTEX_ADJUSTMENT_VELOCITY = 2000;
    /// @notice The minimum rate at which `vertexMultiplier` is adjusted,
    ///         in BPS on top of base rate (1 `BPS`).
    ///         E.g. 0.01 * BPS = 101% multiplied to vertex interest rate per
    ///         `ADJUSTMENT_RATE` at 100% utilization.
    uint256 internal constant _MIN_VERTEX_ADJUSTMENT_VELOCITY = 100;
        /// @notice Maximum Rate at which `vertexMultiplier` will
    ///         decay per `ADJUSTMENT_RATE`, in `BPS`.
    /// @dev 200 = 2%.
    uint256 internal constant _MAX_VERTEX_DECAY_RATE = 200;
    /// @notice The maximum value that `vertexMultiplierMax` can be set
    ///         to, in `WAD`.
    ///         E.g. 1 * WAD = 100% Maximum `vertexMultiplierMax` value.
    uint256 internal constant _MAXIMUM_VERTEX_MULTIPLIER_MAX = type(uint96).max;
    /// @notice The minimum value that `vertexMultiplierMax` can be set to,
    ///         in `WAD`.
    ///         E.g. 1 * WAD = 100% Minimum `vertexMultiplierMax` value.
    uint256 internal constant _MINIMUM_VERTEX_MULTIPLIER_MAX = WAD;

    /// STORAGE ///

    /// @notice The dynamic value applied to `vertexRatePerSecond`, increasing
    ///         it as `utilizationRate` remains elevated over time, adjusted
    ///         every `ADJUSTMENT_RATE`, in `WAD`.
    uint256 public vertexMultiplier;

    /// @notice Struct containing current configuration data for the
    ///         dynamic interest rate model.
    RatesConfig public ratesConfig;

    /// EVENTS ///

    event NewIRM(RatesConfig config);
    event TokenLinked(address borrowableCToken);

    /// ERRORS ///

    error DynamicIRM__Unauthorized();
    error DynamicIRM__InvalidToken();
    error DynamicIRM__InvalidUtilizationStart();
    error DynamicIRM__InvalidInterestRatePerYear();
    error DynamicIRM__InvalidAdjustmentRate();
    error DynamicIRM__InvalidAdjustmentVelocity();
    error DynamicIRM__InvalidDecayRate();
    error DynamicIRM__InvalidMultiplierMax();

    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
    /// @param baseRatePerYear Rate at which interest is accumulated,
    ///                        before `vertexStart`, per year,
    ///                        in `BPS`.
    /// @param vertexRatePerYear Rate at which interest is accumulated,
    ///                          after `vertexStart`, per year,
    ///                          in `BPS`.
    /// @param vertexStart The utilization point at which the vertex
    ///                    rate is applied, in `BPS`.
    /// @param adjustmentVelocity The maximum rate at which `vertexMultiplier`
    ///                           is adjusted per `adjustmentRate`, in `BPS`.
    /// @param decayPerAdjustment The rate at which `vertexMultiplier` will
    ///                           decay back down per `adjustmentRate`,
    ///                           in `BPS`.
    /// @param vertexMultiplierMax The maximum value that `vertexMultiplier`
    ///                            can be, in `BPS`.
    constructor(
        ICentralRegistry cr,
        uint256 baseRatePerYear,
        uint256 vertexRatePerYear,
        uint256 vertexStart,
        uint256 adjustmentVelocity,
        uint256 decayPerAdjustment,
        uint256 vertexMultiplierMax
    ) {
        CentralRegistryLib._isCentralRegistry(cr);
        centralRegistry = cr;

        _updateDynamicIRM(
            baseRatePerYear,
            vertexRatePerYear,
            vertexStart,
            adjustmentVelocity,
            decayPerAdjustment,
            vertexMultiplierMax,
            true
        );
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice The borrowable Curvance token linked to this interest rate
    ///         model contract.
    /// @dev Once this token is set it can never be changed, like an immutable
    ///      variable, this IRM will also be depreciated if that token ever
    ///      switches IRMs.
    /// @return result The linked borrowableCToken address.
    function linkedToken() external view returns(address result) {
        result = ratesConfig.linkedToken;
    }

    /// @notice Sets the dynamic interest rate model's linked borrowable
    ///         Curvance token (cToken) which interest rates this contract
    ///         will manage.
    /// @dev Once this function is properly it can never be called again.
    /// @param cTokenAddress The address of the token to be linked
    ///                      to this interest rate model contract.
    function setLinkedToken(address cTokenAddress) external {
        if (!centralRegistry.hasDaoPermissions(msg.sender)) {
            revert DynamicIRM__Unauthorized();
        }

        RatesConfig storage c = ratesConfig;

        // Validate that a borrowable Curvance token has not already been
        // linked to this smart contract.
        if (c.linkedToken != address(0)) {
            revert DynamicIRM__Unauthorized();
        }

        // Validate that the token being linked is actually a borrowable token
        // if the token is not a Curvance token this will also natively fail,
        // which is fine too.
        if (!IBorrowableCToken(cTokenAddress).isBorrowable()) {
            revert DynamicIRM__InvalidToken();
        }

        // Validate that the token is actually expecting this interest
        // rate model to be linked to it.
        if (address(IBorrowableCToken(cTokenAddress).IRM()) != address(this)) {
            revert DynamicIRM__InvalidToken();
        }

        c.linkedToken = cTokenAddress;

        emit TokenLinked(cTokenAddress);
    }

    /// @notice Updates the dynamic interest rate model's configuration
    ///         for calculating interest payment for `linkedToken`.
    /// @param baseRatePerYear Rate at which interest is accumulated,
    ///                        before `vertexStart`, per year, in `BPS`.
    /// @param vertexRatePerYear Rate at which interest is accumulated,
    ///                          after `vertexStart`, per year, in `BPS`.
    /// @param vertexStart The utilization point at which the vertex
    ///                    rate is applied, in `BPS`.
    /// @param adjustmentVelocity The maximum rate at which `vertexMultiplier`
    ///                           is adjusted per `adjustmentRate`, in `BPS`.
    /// @param decayPerAdjustment The rate at which `vertexMultiplier` will
    ///                           decay back down per `adjustmentRate`,
    ///                           in `BPS`.
    /// @param vertexMultiplierMax The maximum value that `vertexMultiplier`
    ///                            can be, in `BPS`.
    /// @param vertexReset Whether `vertexMultiplier` should be reset back
    ///                    to its default value.
    function updateDynamicIRM(
        uint256 baseRatePerYear,
        uint256 vertexRatePerYear,
        uint256 vertexStart,
        uint256 adjustmentVelocity,
        uint256 decayPerAdjustment,
        uint256 vertexMultiplierMax,
        bool vertexReset
    ) external {
        _checkMarketPermissions();

        _updateDynamicIRM(
            baseRatePerYear,
            vertexRatePerYear,
            vertexStart,
            adjustmentVelocity,
            decayPerAdjustment,
            vertexMultiplierMax,
            vertexReset
        );
    }

    /// @notice Calculates the interest rate paid per second by borrowers,
    ///         in percentage paid, per second, in `WAD`, and updates
    ///         `vertexMultiplier` if necessary.
    /// @dev NOTE: Updates to `vertexMultiplier` are applied to `ratesPerSecond`
    ///            AFTER the next adjustment, this is to prevent someone flash
    ///            borrowing/lending a ton of capital and moving rates.
    /// @param assetsHeld The amount of underlying assets held in the pool.
    /// @param debt The amount of outstanding debt in the pool.
    /// @return ratePerSecond The interest rate paid per second by borrowers,
    ///                       in percentage paid, per second, in `WAD`.
    /// @return adjustmentRate The period of time at which interest rates are
    ///                        adjusted, in seconds.
    function adjustedBorrowRate(
        uint256 assetsHeld,
        uint256 debt
    ) external returns (uint256 ratePerSecond, uint256 adjustmentRate) {
        RatesConfig memory c = ratesConfig;

        // Validate that the linked token itself is calling to update
        // its interest accrued.
        if (msg.sender != c.linkedToken) {
            revert DynamicIRM__Unauthorized();
        }

        uint256 util = utilizationRate(assetsHeld, debt);
        uint256 vertexPoint = c.vertexStart;
        uint256 multiplier = vertexMultiplier;
        bool belowVertex = (util <= vertexPoint);
        
        // Pull current interest rate.
        if (belowVertex) {
            ratePerSecond = _baseRate(util, c.baseRatePerSecond);
        } else {
            ratePerSecond = _vertexRate(
                util,
                c.baseRatePerSecond,
                c.vertexRatePerSecond,
                vertexPoint,
                multiplier
            );
        }

        // If `vertexMultiplier` is already at its minimum,
        // and would decrease more, can break here.
        // Convert `util` to `BPS` by dividing to be in same terms as
        // `increaseThresholdStart`, no precision loss as a result.
        if (multiplier == WAD && (util / 1e14) < c.increaseThresholdStart) {
            return (ratePerSecond, ADJUSTMENT_RATE);
        }

        /// Vertex Multiplier adjustment cases below:

        /// Case 1: Vertex Multiplier downward adjustment.
        if (belowVertex) {
            vertexMultiplier = _updateBelowVertex(c, util, multiplier);
            return (ratePerSecond, ADJUSTMENT_RATE);
        }

        /// Case 2: Vertex Multiplier upward adjustment.
        vertexMultiplier = _updateAboveVertex(c, util, multiplier);
        adjustmentRate = ADJUSTMENT_RATE;
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Calculates the current borrow rate per second,
    ///         with updated `vertexMultiplier` applied.
    /// @param assetsHeld The amount of underlying assets held in the pool.
    /// @param debt The amount of outstanding debt in the pool.
    /// @return result The borrow rate percentage per second, in `WAD`.
    function predictedBorrowRate(
        uint256 assetsHeld,
        uint256 debt
    ) public view returns (uint256 result) {
        uint256 util = utilizationRate(assetsHeld, debt);
        RatesConfig memory c = ratesConfig;
        uint256 vertexStart = c.vertexStart;

        // Directly pull interest rate since `vertexMultiplier` is irrelevant
        // with util <= vertexStart.
        if (util <= vertexStart) {
            return _baseRate(util, c.baseRatePerSecond);
        }

        uint256 multiplier = vertexMultiplier;
        // Vertex multiplier is not going to change so we can pull interest
        // rate with current `vertexMultiplier`.
        // Convert `util` to `BPS` by dividing to be in same terms as
        // `increaseThresholdStart`, no precision loss as a result.
        if (multiplier == WAD && (util / 1e14) < c.increaseThresholdStart) {
            return _vertexRate(
                util,
                c.baseRatePerSecond,
                c.vertexRatePerSecond,
                vertexStart,
                multiplier
            );
        }

        // Get updated vertex multiplier then pull interest rate with new
        // vertex multiplier.
        result = _vertexRate(
            util,
            c.baseRatePerSecond,
            c.vertexRatePerSecond,
            vertexStart,
            _updateAboveVertex(c, util, multiplier)
        );
    }

    /// @notice Calculates the current borrow rate, per second.
    /// @dev This function's intention is for frontend data querying and
    ///     should not be used for onchain execution.
    /// @param assetsHeld The amount of underlying assets held in the pool.
    /// @param debt The amount of outstanding debt in the pool.
    /// @return result The borrow interest rate percentage, per second,
    ///                in `WAD`.
    function borrowRate(
        uint256 assetsHeld,
        uint256 debt
    ) public view returns (uint256 result) {
        uint256 util = utilizationRate(assetsHeld, debt);
        // Cache from storage since we only need to query a new config values.
        RatesConfig storage c = ratesConfig;
        uint256 vertexStart = c.vertexStart;

        if (util <= vertexStart) {
            return _baseRate(util, c.baseRatePerSecond);
        }

        result = _vertexRate(
            util,
            c.baseRatePerSecond,
            c.vertexRatePerSecond,
            vertexStart,
            vertexMultiplier
        );
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
    function supplyRate(
        uint256 assetsHeld,
        uint256 debt,
        uint256 interestFee
    ) public view returns (uint256 result) {
        // RateToLenders = (borrowRate * (1 - Interest Fee)) / WAD.
        uint256 rateToLenders =  _mulDiv(
            borrowRate(assetsHeld, debt),
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

    /// @notice Calculates the borrow utilization rate of the market.
    /// @param assetsHeld The amount of underlying assets held in the pool.
    /// @param debt The amount of outstanding debt in the pool.
    /// @return result The utilization rate between [0, WAD].
    function utilizationRate(
        uint256 assetsHeld,
        uint256 debt
    ) public pure returns (uint256 result) {
        // Utilization rate is 0 when there are no outstanding debt.
        result = debt == 0 ? 0 : _mulDiv(debt, WAD, assetsHeld + debt);
    }

    /// @inheritdoc ERC165
    /// @param interfaceId The interface ID to check.
    /// @return result Whether the contract implements the interface.
    function supportsInterface(
        bytes4 interfaceId
    ) public view override returns (bool result) {
        result = interfaceId == type(IDynamicIRM).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Calculates the interest rate for `util` market utilization.
    /// @param util The utilization rate of the market, in `WAD`.
    /// @return r The calculated base interest rate, in `WAD`.
    function _baseRate(
        uint256 util,
        uint256 baseRatePerSecond
    ) internal pure returns (uint256 r) {
        r = _mulDiv(util, baseRatePerSecond, WAD);
    }

    /// @notice Calculates the interest rate under `vertexRatePerSecond`
    ///         conditions, e.g. `util` > `vertex ` based on market
    ///         utilization.
    /// @param util The utilization rate of the market above
    ///            `vertexStart`, in `WAD`.
    /// @param vertexStart The point at which utilization begins
    ///                    calculating interest rate paid off
    ///                    `vertexRatePerSecond` * `multiplier`.
    /// @param multiplier The multiplicative value applied to 
    ///                   `vertexRatePerSecond`, in `WAD`.
    /// @return r The calculated vertex interest rate, in `WAD`.
    function _vertexRate(
        uint256 util,
        uint256 baseRatePerSecond,
        uint256 vertexRatePerSecond,
        uint256 vertexStart,
        uint256 multiplier
    ) internal pure returns (uint256 r) {
        r = _mulDiv(vertexStart, baseRatePerSecond, WAD) +
            _mulDiv(
            util - vertexStart,
            vertexRatePerSecond * multiplier,
            WAD_SQUARED
        );
    }

    /// @notice Updates the parameters of the dynamic interest rate model
    ///         used in the market.
    /// @dev This function sets various parameters for the dynamic interest
    ///      rate model, adjusting how interest rates are calculated based
    ///      on system utilization.
    ///      Emits a {NewIRM} event.
    /// @param baseRatePerYear Rate at which interest is accumulated,
    ///                        before `vertexStart`, per year,
    ///                        in `BPS`.
    /// @param vertexRatePerYear Rate at which interest is accumulated,
    ///                          after `vertexStart`, per year,
    ///                          in `BPS`.
    /// @param vertexStart The utilization point at which the vertex
    ///                            rate is applied, in `BPS`.
    /// @param adjustmentVelocity The maximum rate at which `vertexMultiplier`
    ///                           is adjusted per `adjustmentRate`, in `BPS`.
    /// @param decayPerAdjustment The rate at which `vertexMultiplier` will
    ///                           decay back down per `adjustmentRate`,
    ///                           in `BPS`.
    /// @param vertexMultiplierMax The maximum value that `vertexMultiplier`
    ///                            can be, in `BPS`.
    /// @param vertexReset A boolean flag indicating whether `vertexMultiplier`
    ///                    should be reset to `WAD`.
    function _updateDynamicIRM(
        uint256 baseRatePerYear,
        uint256 vertexRatePerYear,
        uint256 vertexStart,
        uint256 adjustmentVelocity,
        uint256 decayPerAdjustment,
        uint256 vertexMultiplierMax,
        bool vertexReset
    ) internal {
        // Convert the parameters from `BPS` to `WAD` format.
        // While inefficient, we want to minimize potential human error
        // as much as possible, even if it costs a bit extra gas on config.
        baseRatePerYear = _bpToWad(baseRatePerYear);
        vertexRatePerYear = _bpToWad(vertexRatePerYear);
        vertexStart = _bpToWad(vertexStart);
        vertexMultiplierMax = _bpToWad(vertexMultiplierMax);

        /// Validate config values are within allowed constraints.
        if (
            vertexStart > _MAX_VERTEX_START ||
            vertexStart < _MIN_VERTEX_START
        ) {
            revert DynamicIRM__InvalidUtilizationStart();
        }

        if (
            baseRatePerYear > _MAX_BASE_INTEREST_RATE_PER_YEAR ||
            vertexRatePerYear > _MAX_VERTEX_INTEREST_RATE_PER_YEAR
        ) {
            revert DynamicIRM__InvalidInterestRatePerYear();
        }

        if (decayPerAdjustment > _MAX_VERTEX_DECAY_RATE) {
            revert DynamicIRM__InvalidDecayRate();
        }
        
        if (
            adjustmentVelocity > _MAX_VERTEX_ADJUSTMENT_VELOCITY ||
            adjustmentVelocity < _MIN_VERTEX_ADJUSTMENT_VELOCITY
        ) {
            revert DynamicIRM__InvalidAdjustmentVelocity();
        }

        if (
            vertexMultiplierMax > _MAXIMUM_VERTEX_MULTIPLIER_MAX ||
            vertexMultiplierMax < _MINIMUM_VERTEX_MULTIPLIER_MAX
        ) {
            revert DynamicIRM__InvalidMultiplierMax();
        }

        RatesConfig storage config = ratesConfig;

        config.baseRatePerSecond = uint64(_mulDiv(
            baseRatePerYear,
            WAD,
            SECONDS_PER_YEAR * vertexStart
        ));

        config.vertexRatePerSecond = uint64(_mulDiv(
            vertexRatePerYear,
            WAD,
            SECONDS_PER_YEAR * (WAD - vertexStart)
        ));

        config.vertexStart = uint64(vertexStart);
        config.adjustmentVelocity = uint16(adjustmentVelocity);
        config.decayPerAdjustment = uint16(decayPerAdjustment);
        config.vertexMultiplierMax = uint96(vertexMultiplierMax);
        vertexMultiplier = vertexReset ? WAD : vertexMultiplier;

        // Dynamic rates start increasing halfway between desired
        // utilization and 100% utilization, in `WAD`.
        uint256 thresholdLength = (WAD - vertexStart) / 2;

        // Dynamic rates start increasing as soon as we are halfway between
        // `vertexStart` and 100% utilization. Convert to `BPS` form to save a
        // storage slot and `vertexStart` is set in `BPS` so we shouldnt lose
        // precision.
        config.increaseThresholdStart =
            uint16((vertexStart + thresholdLength) / 1e14);

        // Dynamic rates start decreasing as soon as we are below desired
        // utilization (vertexStart) and maximizes an equal utilization down
        // from where increase threshold starts upward. Convert to `BPS` form
        // to save a storage slot and `vertexStart` is set in `BPS` so we
        // shouldnt lose precision.
        config.decreaseThresholdEnd =
            uint16((vertexStart - thresholdLength) / 1e14);

        emit NewIRM(config);
    }

    /// @notice Calculates and returns the updated multiplier for scenarios
    ///         where the utilization rate is above the vertex.
    /// @dev This function is used to adjust `vertexMultiplier` based on
    ///      the borrowableCToken's current borrow utilization.
    ///      A decay mechanism is incorporated to gradually decrease the
    ///      multiplier, and ensures the multiplier does not fall below 1,
    ///      in WAD.
    ///      NOTE: The multiplier is updated with the following logic:
    ///      If the utilization is below the 'increaseThresholdStart',
    ///      it simply applies the decay to the current multiplier.
    ///      If the utilization is higher, it calculates a new multiplier by
    ///      applying a positive curve value to the adjustment.
    ///      This adjustment is also subjected to the decay multiplier.
    /// @param c The cached version of the current `RatesConfig`.
    /// @param util The current utilization value, used to determine how the
    ///             multiplier should be adjusted.
    /// @param multiplier The dynamic value applied to `vertexRatePerSecond`
    ///                   that will be adjusted, in `WAD`.
    /// @return newMultiplier The updated multiplier after applying decay
    ///                       and adjustments based on the current utilization
    ///                       level.
    function _updateAboveVertex(
        RatesConfig memory c,
        uint256 util,
        uint256 multiplier
    ) internal pure returns (uint256 newMultiplier) {
        // Calculate decay rate.
        uint256 decay = _mulDiv(multiplier, c.decayPerAdjustment, BPS);

        if ((util / 1e14) <= c.increaseThresholdStart) {
            newMultiplier = multiplier - decay;

            // Check if decay rate sends new rate below 1.
            return newMultiplier < WAD ? WAD : newMultiplier;
        }

        // Apply a positive multiplier to the current multiplier based on
        // `util` vs `increaseThresholdStart` and `WAD`.
        // Then apply decay effect.
        newMultiplier = _positiveShift(
            multiplier, // `multiplier` in `WAD`.
            c.adjustmentVelocity, // `adjustmentVelocity` in `BPS`.
            decay, // `decay` in `multiplier` aka `WAD`.
            util, // `current` in `WAD`.
            1e14 * uint256(c.increaseThresholdStart) // `start` convert to WAD to match util.
        );

        // Update and return with adjustment and decay rate applied.
        // Its theorectically possible for the multiplier to be below 1
        // due to decay, so we need to check like in below vertex.
        if (newMultiplier < WAD) {
            return WAD;
        }

        // Make sure `newMultiplier` is not above `vertexMultiplierMax`.
        newMultiplier = newMultiplier < c.vertexMultiplierMax
            ? newMultiplier
            : c.vertexMultiplierMax;
    }

    /// @notice Calculates and returns the updated multiplier for scenarios
    ///         where the utilization rate is below the vertex.
    /// @dev This function is used to adjust `vertexMultiplier` based on
    ///      the borrowableCToken's current borrow utilization.
    ///      A decay mechanism is incorporated to gradually decrease the
    ///      multiplier, and ensures the multiplier does not fall below 1,
    ///      in WAD.
    ///      NOTE: The multiplier is updated with the following logic:
    ///      If the utilization is below the 'decreaseThresholdEnd',
    ///      decay rate and maximum adjustment velocity is applied.
    ///      For higher utilizations (but still below the vertex),
    ///      a new multiplier is calculated by applying a negative curve value
    ///      to the adjustment. This new multiplier is also subjected to the
    ///      decay multiplier.
    /// @param c The cached version of the current `RatesConfig`.
    /// @param util The current utilization value, used to determine how the
    ///             multiplier should be adjusted.
    /// @param multiplier The dynamic value applied to `vertexRatePerSecond`
    ///                   that will be adjusted, in `WAD`.
    /// @return newMultiplier The updated multiplier after applying decay
    ///                       and adjustments based on the current utilization
    ///                       level.
    function _updateBelowVertex(
        RatesConfig memory c,
        uint256 util,
        uint256 multiplier
    ) internal pure returns (uint256 newMultiplier) {
        // Calculate decay rate.
        uint256 decay = _mulDiv(multiplier, c.decayPerAdjustment, BPS);

        // Convert `util` to `BPS` by dividing to be in same terms as
        // `decreaseThresholdEnd`, no precision loss as a result.
        if ((util / 1e14) <= c.decreaseThresholdEnd) {
            // Apply maximum adjustVelocity reduction (shift = 1).
            // We only need to adjust for 1e18 precision since `shift`
            // is not used here.
            // currentMultiplier / (1 + adjustmentVelocity) = newMultiplier.
            newMultiplier = _mulDiv(
                multiplier,
                BPS,
                BPS + c.adjustmentVelocity
            ) - decay;

            // Check if decay rate sends multiplier below 1.
            return newMultiplier < WAD ? WAD : newMultiplier;
        }

        // Apply a negative multiplier to the current multiplier based on
        // `util` vs `vertexStart` and `decreaseThresholdEnd`.
        // Then apply decay effect.
        newMultiplier = _negativeShift(
            multiplier, // `multiplier` in `WAD`.
            c.adjustmentVelocity, // `adjustmentVelocity` in `BPS`.
            decay, // `decay` in `multiplier` aka `WAD`.
            util, // `current` in `WAD`.
            c.vertexStart, // `start` in `WAD`.
            1e14 * uint256(c.decreaseThresholdEnd) // `end` convert to WAD to match util/vertexStart.
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
    /// @param multiplier The dynamic value applied to `vertexRatePerSecond`
    ///                   that will be adjusted, in `WAD`.
    /// @param adjustmentVelocity The maximum rate at which `vertexMultiplier`
    ///                           is adjusted per `adjustmentRate`, in `BPS`.
    /// @param decay The current decay rate, calculated as a negative % value,
    ///              in `multiplier` denomination, aka `WAD` form.
    /// @param current The current value, representing a point on the curve.
    /// @param start The start value of the curve, marking the beginning of
    ///              the calculation range.
    /// @return result The new multiplier with the calculated shift value,
    ///                and decay rate applied.
    function _positiveShift(
        uint256 multiplier,
        uint256 adjustmentVelocity,
        uint256 decay,
        uint256 current, // `util`.
        uint256 start // `increaseThresholdStart`.
    ) internal pure returns (uint256 result) {
        // We do not need to check for current >= end, since we know util is
        // the absolute maximum utilization is 100%, and thus current == end.
        // Which will result in WAD result for `shift`.
        // Thus, this will be bound between [0, WAD].
        uint256 shift = _mulDiv(current - start, WAD, WAD - start);

        // Apply `shift` result to adjustment velocity.
        // Then add 100% on top for final adjustment value to `multiplier`.
        // We use WAD_BPS here since `shift` is in `WAD` for max precision but
        // `adjustmentVelocity` is in BPS since it does not need greater
        // precision due to being configured in `BPS`.
        shift = WAD_BPS + (shift * adjustmentVelocity);

        // Apply positive `shift` effect to `currentMultiplier`, and
        // adjust for 1e36 precision. Then apply decay effect.
        result = _mulDiv(multiplier, shift, WAD_BPS) -  decay;
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
    /// @param multiplier The dynamic value applied to `vertexRatePerSecond`
    ///                   that will be adjusted, in `WAD`.
    /// @param adjustmentVelocity The maximum rate at which `vertexMultiplier`
    ///                           is adjusted per `adjustmentRate`, in `BPS`.
    /// @param decay The current decay rate, calculated as a negative % value,
    ///              in `multiplier` denomination, aka `WAD` form.
    /// @param current The current value, representing a point on the curve.
    /// @param start The start value of the curve, marking the beginning of
    ///              the calculation range, equal to `vertexStart`.
    /// @param end The end value of the curve, marking the end of the
    ///            calculation range.
    /// @return result The new multiplier with the calculated shift value,
    ///                and decay rate applied.
    function _negativeShift(
        uint256 multiplier,
        uint256 adjustmentVelocity,
        uint256 decay,
        uint256 current, // `util`.
        uint256 start, // `vertexStart`.
        uint256 end // `decreaseThresholdEnd`.
    ) internal pure returns (uint256 result) {
        // Calculate linear curve multiplier. We know that current > end,
        // based on pre conditional checks.
        // Thus, this will be bound between [0, WAD].
        uint256 shift = _mulDiv(start - current, WAD, start - end);

        // Apply `shift` result to adjustment velocity.
        // Then add 100% on top for final adjustment value to `multiplier`.
        // We use WAD_BPS here since `shift` is in `WAD` for max precision but
        // `adjustmentVelocity` is in BPS since it does not need greater
        // precision due to being configured in `BPS`.
        shift = WAD_BPS + (shift * adjustmentVelocity);

        // Apply negative `shift` effect to `currentMultiplier`, and
        // adjust for 1e36 precision. Then apply decay effect.
        result = _mulDiv(multiplier, WAD_BPS, shift) -  decay;
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

    /// @dev Checks whether the caller has sufficient permissioning.
    function _checkMarketPermissions() internal view virtual {
        if (!centralRegistry.hasMarketPermissions(msg.sender)) {
            revert DynamicIRM__Unauthorized();
        }
    }

    /// @notice Multiplies `value` by 1e14 to convert it from `BPS`
    ///         to `WAD`.
    /// @dev Internal helper function for easily converting between scalars.
    /// @param value The value to convert from `BPS` to `WAD`.
    /// @return result The value, in `WAD`.
    function _bpToWad(uint256 value) internal pure returns (uint256 result) {
        result = value * 1e14;
    }
}