// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { DynamicIRM } from "contracts/market/DynamicIRM.sol";
import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";

import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";
import { ReentrancyGuard } from "contracts/libraries/ReentrancyGuardTransient.sol";
import { SECONDS_PER_YEAR, WAD, BPS } from "contracts/libraries/ConstantsLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IOracleAdaptor } from "contracts/interfaces/IOracleAdaptor.sol";

/// @title Curvance Protocol Manager.
/// @notice Allows management of protocol configurations.
/// @dev A hub contract for managing designated protocol configurations with
///      known trust assumptions in what can be modified and how.
///
///      Possible managed configurations include:
///      Token Liquidity configurations
///      Oracle Price Guard configurations
///      Dynamic Interest Rate Model configurations
///      Market Action Status configurations
///      Token Action Status configurations
///      Position Manager configurations
///
contract ProtocolManager is ReentrancyGuard {
    /// TYPES ///

    struct ManagementConfig {
        bool hasAuthority;
        PeriodLimits limits;
    }

    /// @title Period Adjustments.
    struct PeriodAdjustments {
        // Token Configs - Debt Cap
        int24 collRatio;
        int24 marginSoft;
        int24 marginHard;
        int120 collateralCap;
        // Interest Rate Model + Debt Cap
        int64 baseInterestRate;
        int112 debtCap; // Debt cap is out of order here to pack data a bit better
        int64 vertexInterestRate;
        int64 vertexStart;
        int16 adjustmentVelocity;
        int8 decayPerAdjustment;
        int16 vertexMultiplierMax;
        // Price Guard
        int88 basePriceUSD;
        int88 minPriceUSD;
        int88 basePriceNative;
        int88 minPriceNative;
    }

    /// @title Period Adjustment Limitations.
    struct PeriodLimits {
        // Token Configs - Debt Cap
        uint24 collRatioLimit;
        uint24 marginSoftLimit;
        uint24 marginHardLimit;
        uint120 collateralCapLimit;
        // Interest Rate Model + Debt Cap
        uint64 baseInterestRateLimit;
        uint112 debtCapLimit; // Debt cap is out of order here to pack data a bit better
        uint64 vertexInterestRateLimit;
        uint64 vertexStartLimit;
        uint16 adjustmentVelocityLimit;
        uint8 decayPerAdjustmentLimit;
        uint16 vertexMultiplierMaxLimit;
        // Price Guard
        uint88 basePriceUSDLimit;
        uint88 minPriceUSDLimit;
        uint88 basePriceNativeLimit;
        uint88 minPriceNativeLimit;
    }

    struct PermsConfig {
        bool canModifyPriceGuards;
        bool canModifyTokenConfig;
        bool canModifyIRM;
        bool canUnpause;
        bool canModifyMintStatus;
        bool canModifyCollateralizationStatus;
        bool canModifyBorrowStatus;
        bool canModifyLiquidationStatus;
        bool canModifyRedeemStatus;
        bool canModifyTransferStatus;
        bool canModifyPositionManagers;
    }

    /// CONSTANTS ///

    /// @notice The maximum period of time that a rewards claim window should
    ///         be open for, in unix time.
    uint256 public constant MAXIMUM_COLL_RATIO_LIMIT = 500;
    uint256 public constant MAXIMUM_MARGIN_LIMIT = 300;
    uint256 public constant MAXIMUM_COLL_CAP_LIMIT = type(uint112).max;
    uint256 public constant MAXIMUM_DEBT_CAP_LIMIT = type(uint104).max;
    uint256 public constant MAXIMUM_INTEREST_RATE_LIMIT = 1000;
    uint256 public constant MAXIMUM_ADJUSTMENT_VELOCITY_LIMIT = 500;
    uint256 public constant MAXIMUM_DECAY_RATE_LIMIT = 200;
    uint256 public constant MAXIMUM_VERTEX_MULTIPLIER_MAX_LIMIT = 50000;
    uint256 public constant MAXIMUM_PRICE_GUARD_PRICE_LIMIT = type(uint88).max;
    uint256 public constant WAD_TO_BPS = 1e14;

    /// @notice Whether the protocol manager can modify token configs.
    bool public immutable canModifyTokenConfig;
    /// @notice Whether the protocol manager can modify price guards.
    bool public immutable canModifyPriceGuards;
    /// @notice Whether the protocol manager can modify interest rate model configs.
    bool public immutable canModifyIRM;
    /// @notice Whether the protocol manager can unpause markets or only pause.
    bool public immutable canUnpause;
    /// @notice Whether the protocol manager can modify token mint status.
    bool public immutable canModifyMintStatus;
    /// @notice Whether the protocol manager can modify token collateralization status.
    bool public immutable canModifyCollateralizationStatus;
    /// @notice Whether the protocol manager can modify token borrow status.
    bool public immutable canModifyBorrowStatus;
    /// @notice Whether the protocol manager can modify market liquidation status.
    bool public immutable canModifyLiquidationStatus;
    /// @notice Whether the protocol manager can modify market redeem status.
    bool public immutable canModifyRedeemStatus;
    /// @notice Whether the protocol manager can modify market transfer status.
    bool public immutable canModifyTransferStatus;
    bool public immutable canModifyPositionManagers;

    /// @notice The duration of the period in which any value adjustment
    ///         restrictions are measured in, in seconds.
    /// @dev 604800 = 1 week.
    uint256 public constant periodDuration = 604800;

    /// @notice The initial timestamp that value adjustment restriction
    ///         periods are calculated off of.
    uint256 internal constant _unixStartTimestamp = 1766966400;

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;

    /// @notice The address managing parts of the Curvance Protocol.
    address public immutable protocolManager;

    /// STORAGE ///

    /// @notice Configuration for managing a protocol address.
    /// @dev Protocol address => Management Configuration
    mapping(address => ManagementConfig) public config;

    /// @notice Management adjustments per period (length = `periodDuration`).
    /// @dev Protocol Address => Period Timestamp Start => Adjustments.
    mapping(address => mapping(uint256 => PeriodAdjustments)) internal _periodAdjustments;

    /// EVENTS ///

    event ManagementAuthorityUpdated(
        address addressManaged,
        bool manages,
        PeriodLimits limits
    );

    /// ERRORS ///

    error ProtocolManager__ParametersAreInvalid();
    error ProtocolManager__Unauthorized();
    error ProtocolManager__MulDivFailed();
    error ProtocolManager__UintToIntError();

    constructor(
        ICentralRegistry cr,
        address pm,
        PermsConfig memory p,
        address[] memory managedAddresses,
        PeriodLimits[] memory l
    ) {
        CentralRegistryLib._isCentralRegistry(cr);
        centralRegistry = cr;
        protocolManager = pm;

        _updateManagementConfig(managedAddresses, l, true);

        canModifyPriceGuards = p.canModifyPriceGuards;
        canModifyTokenConfig = p.canModifyTokenConfig;
        canModifyIRM = p.canModifyIRM;
        canUnpause = p.canUnpause;
        canModifyMintStatus = p.canModifyMintStatus;
        canModifyCollateralizationStatus = p.canModifyCollateralizationStatus;
        canModifyBorrowStatus = p.canModifyBorrowStatus;
        canModifyLiquidationStatus = p.canModifyLiquidationStatus;
        canModifyRedeemStatus = p.canModifyRedeemStatus;
        canModifyTransferStatus = p.canModifyTransferStatus;
        canModifyPositionManagers = p.canModifyPositionManagers;
    }

    /// @notice Returns token config and IRM period adjustments.
    /// @param managedAddress The managed contract address.
    /// @param periodTimestamp The period timestamp to query.
    /// @return collRatio Collateral ratio adjustment.
    /// @return marginSoft Soft margin adjustment.
    /// @return marginHard Hard margin adjustment.
    /// @return collateralCap Collateral cap adjustment.
    /// @return debtCap Debt cap adjustment.
    /// @return baseInterestRate Base interest rate adjustment.
    /// @return vertexInterestRate Vertex interest rate adjustment.
    /// @return vertexStart Vertex start adjustment.
    /// @return adjustmentVelocity Adjustment velocity adjustment.
    /// @return decayPerAdjustment Decay per adjustment adjustment.
    /// @return vertexMultiplierMax Vertex multiplier max adjustment.
    function getMarketPeriodAdjustments(
        address managedAddress,
        uint256 periodTimestamp
    ) external view returns (
        int24, int24, int24, int120, int112,
        int64, int64, int64, int16, int8, int16
    ) {
        PeriodAdjustments storage p = _periodAdjustments[managedAddress][periodTimestamp];
        return (
            p.collRatio,
            p.marginSoft,
            p.marginHard,
            p.collateralCap,
            p.debtCap,
            p.baseInterestRate,
            p.vertexInterestRate,
            p.vertexStart,
            p.adjustmentVelocity,
            p.decayPerAdjustment,
            p.vertexMultiplierMax
        );
    }

    /// @notice Returns price guard period adjustments.
    /// @param managedAddress The managed contract address.
    /// @param periodTimestamp The period timestamp to query.
    /// @return basePriceUSD Base USD price adjustment.
    /// @return minPriceUSD Min USD price adjustment.
    /// @return basePriceNative Base native price adjustment.
    /// @return minPriceNative Min native price adjustment.
    function getPriceGuardPeriodAdjustments(
        address managedAddress,
        uint256 periodTimestamp
    ) external view returns (int88, int88, int88, int88) {
        PeriodAdjustments storage p = _periodAdjustments[managedAddress][periodTimestamp];
        return (p.basePriceUSD, p.minPriceUSD, p.basePriceNative, p.minPriceNative);
    }

    /// @notice Updates management configuration for `managedAddresses`.
    /// @dev Validates all limits against maximums before storing. Emits
    ///      {ManagementAuthorityUpdated} for each address in
    ///      `managedAddresses`.
    /// @param managedAddresses Array of addresses to configure.
    /// @param l Array of period adjustment limits for each address.
    /// @param hasAuthority Whether these addresses should have authority.
    function updateManagementConfig(
        address[] memory managedAddresses,
        PeriodLimits[] memory l,
        bool hasAuthority
    ) external nonReentrant {
        if (!centralRegistry.hasElevatedPermissions(msg.sender)) {
            revert ProtocolManager__Unauthorized();
        }

        _updateManagementConfig(managedAddresses, l, hasAuthority);
    }

    /// @notice Sets token liquidity configuration values for
    ///         `n.cToken` a listed cToken inside this market.
    /// @dev Emits a {TokenConfigUpdated} event.
    /// @param n A TokenConfig struct containing:
    ///                  cToken The Curvance token to update liquidity
    ///                         configuration values of.
    ///                  collRatio The ratio at which $1 of collateral can be
    ///                            borrowed against, for `n.cToken`, in `BPS`.
    ///                  collReqSoft The premium of excess collateral required
    ///                              to avoid soft liquidation, in `BPS`.
    ///                  collReqHard The premium of excess collateral required
    ///                              to avoid hard liquidation, in `BPS`.
    ///                  liqIncBase The default liquidation incentive for
    ///                             `n.cToken`, in `BPS`.
    ///                  liqIncHard The hard liquidation incentive for
    ///                             `n.cToken`, in `BPS`.
    ///                  liqIncMin The minimum possible liquidation incentive
    ///                            for `n.cToken` during an auction, in `BPS`.
    ///                  liqIncMax The maximum possible liquidation incentive
    ///                            for `n.cToken` during an auction, in `BPS`.
    ///                  closeFactorBase Maximum % that a liquidator can repay
    ///                                  when soft liquidating `n.cToken`
    ///                                  for an account.
    ///                  closeFactorMin The minimum possible close factor for
    ///                                 `n.cToken` during an auction, in `BPS`.
    ///                  closeFactorMax The maximum possible close factor for
    ///                                 `n.cToken` during an auction, in `BPS`.
    ///                  collateralCap The maximum amount of shares that can
    ///                                be collateralized of `n.cToken`
    ///                                inside this market.
    ///                  debtCap The maximum amount of assets that can be
    ///                          borrowed of `n.cToken` inside this market.
    function updateTokenConfig(
        address managedAddress,
        MarketManagerIsolated.TokenConfig memory n
    ) external nonReentrant {
        _checkAuthorityAndAsset(managedAddress, n.cToken, canModifyTokenConfig);
        MarketManagerIsolated mm = MarketManagerIsolated(managedAddress);

        if (!mm.isListed(n.cToken)) {
            revert ProtocolManager__ParametersAreInvalid();
        }

        PeriodAdjustments storage p = _periodAdjustments[n.cToken][getPeriodTimestamp()];
        PeriodLimits memory l = config[n.cToken].limits;

        (uint256 collRatio, uint256 collReqSoft, uint256 collReqHard) =
            mm.collConfig(n.cToken);

        p.collRatio = int24(_calcAdj(n.collRatio, collRatio, p.collRatio, l.collRatioLimit));
        p.marginSoft = int24(_calcAdj(n.collReqSoft, collReqSoft - BPS, p.marginSoft, l.marginSoftLimit));
        p.marginHard = int24(_calcAdj(n.collReqHard, collReqHard - BPS, p.marginHard, l.marginHardLimit));
        p.collateralCap = int120(_calcAdj(n.collateralCap, mm.collateralCaps(n.cToken), p.collateralCap, l.collateralCapLimit));
        p.debtCap = int112(_calcAdj(n.debtCap, mm.debtCaps(n.cToken), p.debtCap, l.debtCapLimit));
        
        mm.updateTokenConfig(n);
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
        address managedAddress,
        uint256 baseRatePerYear,
        uint256 vertexRatePerYear,
        uint256 vertexStart,
        uint256 adjustmentVelocity,
        uint256 decayPerAdjustment,
        uint256 vertexMultiplierMax,
        bool vertexReset
    ) external nonReentrant {
        _checkAuthority(managedAddress, canModifyIRM);

        PeriodAdjustments storage p = _periodAdjustments[managedAddress][getPeriodTimestamp()];
        PeriodLimits memory l = config[managedAddress].limits;
        DynamicIRM.RatesConfig memory rc;
        (
            rc.baseRatePerSecond,
            rc.vertexRatePerSecond,
            rc.vertexStart,
            ,
            ,
            rc.adjustmentVelocity,
            rc.decayPerAdjustment,
            rc.vertexMultiplierMax,
        ) = DynamicIRM(managedAddress).ratesConfig();

        p.baseInterestRate = int64(_calcAdj(baseRatePerYear, _perSecondToBPS(rc.baseRatePerSecond, rc.vertexStart), p.baseInterestRate, l.baseInterestRateLimit));
        p.vertexInterestRate = int64(_calcAdj(vertexRatePerYear, _perSecondToBPS(rc.vertexRatePerSecond, WAD - rc.vertexStart), p.vertexInterestRate, l.vertexInterestRateLimit));
        p.vertexStart = int64(_calcAdj(vertexStart, rc.vertexStart / WAD_TO_BPS, p.vertexStart, l.vertexStartLimit));
        p.adjustmentVelocity = int16(_calcAdj(adjustmentVelocity, rc.adjustmentVelocity, p.adjustmentVelocity, l.adjustmentVelocityLimit));
        p.decayPerAdjustment = int8(_calcAdj(decayPerAdjustment, rc.decayPerAdjustment, p.decayPerAdjustment, l.decayPerAdjustmentLimit));
        p.vertexMultiplierMax = int16(_calcAdj(vertexMultiplierMax, rc.vertexMultiplierMax / WAD_TO_BPS, p.vertexMultiplierMax, l.vertexMultiplierMaxLimit));
        
        DynamicIRM(managedAddress).updateDynamicIRM(
            baseRatePerYear,
            vertexRatePerYear,
            vertexStart,
            adjustmentVelocity,
            decayPerAdjustment,
            vertexMultiplierMax,
            vertexReset
        );
    }


    /// @notice Sets a PriceGuard when pricing `asset` denominated either USD
    ///         or native tokens depending on `inUSD`.
    /// @param asset The address of the asset to set a PriceGuard data on.
    /// @param inUSD Specifies whether the PriceGuard should be in
    ///              USD (true) or a chain's native token (false).
    /// @param timestampStart When `ips` should start increasing `basePrice`
    ///                       raising the maximum price returned when pricing
    ///                       `asset`.
    /// @param ips The magnitude that `basePrice` should increase overtime
    ///            overtime from `timestampStart`, in `WAD`, in seconds.
    /// @param basePrice The base price that should be the maximum price
    ///                  returned when pricing `asset`.
    /// @param minPrice The minimum price that should be allowed to be
    ///                 returned when pricing `asset`.
    function setGuardedPriceConfig(
        address managedAddress,
        address asset,
        bool inUSD,
        uint256 timestampStart,
        uint256 ips,
        uint256 basePrice,
        uint256 minPrice
    ) external nonReentrant {
        _checkAuthorityAndAsset(managedAddress, asset, canModifyPriceGuards);
        IOracleAdaptor oa = IOracleAdaptor(managedAddress);

        if (!oa.isSupportedAsset(asset)) {
            revert ProtocolManager__ParametersAreInvalid();
        }

        PeriodAdjustments storage p = _periodAdjustments[asset][getPeriodTimestamp()];
        PeriodLimits memory l = config[asset].limits;
        IOracleAdaptor.PriceGuard memory pg = oa.getPriceGuard(asset, inUSD);

        if (inUSD) {
            p.basePriceUSD = int88(_calcAdj(basePrice, pg.basePrice, p.basePriceUSD, l.basePriceUSDLimit));
            p.minPriceUSD = int88(_calcAdj(minPrice, pg.minPrice, p.minPriceUSD, l.minPriceUSDLimit));
        } else {
            p.basePriceNative = int88(_calcAdj(basePrice, pg.basePrice, p.basePriceNative, l.basePriceNativeLimit));
            p.minPriceNative = int88(_calcAdj(minPrice, pg.minPrice, p.minPriceNative, l.minPriceNativeLimit));
        }

        BaseOracleAdaptor(managedAddress).setGuardedPriceConfig(
            asset,
            inUSD,
            timestampStart,
            ips,
            basePrice,
            minPrice
        );
    }

    /// @notice Disables any PriceGuard active when pricing `asset`
    ///         denominated either USD or native tokens depending on `inUSD`.
    /// @dev Removes price bounds for the specified asset and denomination.
    /// @param asset asset The address of the asset to disable PriceGuard on.
    /// @param inUSD Whether to disable USD (true) or native (false) guard.
    function disableGuardedPriceConfig(
        address managedAddress,
        address asset,
        bool inUSD
    ) external nonReentrant {
        _checkAuthorityAndAsset(managedAddress, asset, canModifyPriceGuards);

        if (!IOracleAdaptor(managedAddress).isSupportedAsset(asset)) {
            revert ProtocolManager__ParametersAreInvalid();
        }

        BaseOracleAdaptor(managedAddress).disableGuardedPriceConfig(
            asset,
            inUSD
        );
    }

    /// @notice Sets pause status for various market actions.
    /// @dev Emits an {ActionPaused} or {TokenActionPaused} event.
    /// @param managedAddress The market manager address to update.
    /// @param cToken The Curvance token (only for Mint/Collateralization/Borrow).
    ///               Pass address(0) for market-wide actions.
    /// @param action 0=Liquidation, 1=Redeem, 2=Transfer, 3=Mint,
    ///               4=Collateralization, 5=Borrow.
    /// @param state Whether the action should be paused or unpaused.
    function setPaused(
        address managedAddress,
        address cToken,
        uint8 action,
        bool state
    ) external {
        if (!state && !canUnpause) {
            revert ProtocolManager__Unauthorized();
        }

        MarketManagerIsolated mm = MarketManagerIsolated(managedAddress);

        if (action == 0) {
            _checkAuthority(managedAddress, canModifyLiquidationStatus);
            mm.setLiquidationPaused(state);
        } else if (action == 1) {
            _checkAuthority(managedAddress, canModifyRedeemStatus);
            mm.setRedeemPaused(state);
        } else if (action == 2) {
            _checkAuthority(managedAddress, canModifyTransferStatus);
            mm.setTransferPaused(state);
        } else if (action == 3) {
            _checkAuthorityAndAsset(managedAddress, cToken, canModifyMintStatus);
            mm.setMintPaused(cToken, state);
        } else if (action == 4) {
            _checkAuthorityAndAsset(managedAddress, cToken, canModifyCollateralizationStatus);
            mm.setCollateralizationPaused(cToken, state);
        } else if (action == 5) {
            _checkAuthorityAndAsset(managedAddress, cToken, canModifyBorrowStatus);
            mm.setBorrowPaused(cToken, state);
        } else {
            revert ProtocolManager__ParametersAreInvalid();
        }
    }

    /// @notice Adds or removes a position manager address for complex
    ///         position actions.
    /// @dev Emits a {PositionManagerUpdated} event.
    /// @param managedAddress The market manager address to update.
    /// @param pm The address to add or remove position manager permissions for.
    /// @param add Whether to add (true) or remove (false) the position manager.
    function updatePositionManager(
        address managedAddress,
        address pm,
        bool add
    ) external {
        _checkAuthority(managedAddress, canModifyPositionManagers);

        if (add) {
            MarketManagerIsolated(managedAddress).addPositionManager(pm);
        } else {
            MarketManagerIsolated(managedAddress).removePositionManager(pm);
        }
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Returns the current period timestamp for adjustment tracking.
    /// @dev Periods are calculated from `_unixStartTimestamp` in increments
    ///      of `periodDuration`. Used to bucket adjustments by time period.
    /// @return x The start timestamp of the current period.
    function getPeriodTimestamp() public view returns (uint256 x) {
        uint256 periods = (block.timestamp - _unixStartTimestamp) / periodDuration;
        x = _unixStartTimestamp + (periods * periodDuration);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Calculates and validates the new period adjustment value.
    /// @dev Reverts if the absolute adjustment exceeds the limit allowed
    ///      for the period.
    /// @param newValue The new value being set.
    /// @param currentValue The current value in the system.
    /// @param existingAdj The total existing adjustments for this period.
    /// @param limit The maximum allowed absolute adjustment for this period.
    /// @return adj The new adjustment value to store.
    function _calcAdj(
        uint256 newValue,
        uint256 currentValue,
        int256 existingAdj,
        uint256 limit
    ) internal pure returns (int256 adj) {
        adj = _toInt256(newValue) - _toInt256(currentValue) + existingAdj;
        // We dont have to worry about overflow when casting these later since
        // adjustment limit values are same bit size `adj` is cast to later.
        if (_abs(adj) > limit) revert ProtocolManager__ParametersAreInvalid();
    }

    /// @notice Updates management configuration for `managedAddresses`.
    /// @dev Validates all limits against maximums before storing. Emits
    ///      {ManagementAuthorityUpdated} for each address in
    ///      `managedAddresses`.
    /// @param managedAddresses Array of addresses to configure.
    /// @param l Array of period adjustment limits for each address.
    /// @param hasAuthority Whether these addresses should have authority.
    function _updateManagementConfig(
        address[] memory managedAddresses,
        PeriodLimits[] memory l,
        bool hasAuthority
    ) internal {
        uint256 numManagedAddresses = managedAddresses.length;
        if (numManagedAddresses == 0) {
            revert ProtocolManager__ParametersAreInvalid();
        }

        if (numManagedAddresses != l.length) {
            revert ProtocolManager__ParametersAreInvalid();
        }

        address cachedAddress;
        PeriodLimits memory limits;
        for (uint i; i < numManagedAddresses; ++i) {
            cachedAddress = managedAddresses[i];
            limits = l[i];

            if (
                limits.collRatioLimit > MAXIMUM_COLL_RATIO_LIMIT ||
                limits.marginSoftLimit > MAXIMUM_MARGIN_LIMIT ||
                limits.marginHardLimit > MAXIMUM_MARGIN_LIMIT ||
                limits.collateralCapLimit > MAXIMUM_COLL_CAP_LIMIT ||
                limits.debtCapLimit > MAXIMUM_DEBT_CAP_LIMIT ||
                limits.baseInterestRateLimit > MAXIMUM_INTEREST_RATE_LIMIT ||
                limits.vertexInterestRateLimit > MAXIMUM_INTEREST_RATE_LIMIT ||
                limits.vertexStartLimit > MAXIMUM_INTEREST_RATE_LIMIT ||
                limits.adjustmentVelocityLimit > MAXIMUM_ADJUSTMENT_VELOCITY_LIMIT ||
                limits.decayPerAdjustmentLimit > MAXIMUM_DECAY_RATE_LIMIT ||
                limits.vertexMultiplierMaxLimit > MAXIMUM_VERTEX_MULTIPLIER_MAX_LIMIT ||
                limits.basePriceUSDLimit > MAXIMUM_PRICE_GUARD_PRICE_LIMIT ||
                limits.minPriceUSDLimit > MAXIMUM_PRICE_GUARD_PRICE_LIMIT ||
                limits.basePriceNativeLimit > MAXIMUM_PRICE_GUARD_PRICE_LIMIT ||
                limits.minPriceNativeLimit > MAXIMUM_PRICE_GUARD_PRICE_LIMIT
            ) {
                revert ProtocolManager__ParametersAreInvalid();
            }

            config[cachedAddress].hasAuthority = hasAuthority;

            if (hasAuthority) {
                config[cachedAddress].limits = limits;
            } else {
                delete config[cachedAddress].limits;
            }

            emit ManagementAuthorityUpdated(
                cachedAddress,
                hasAuthority,
                config[cachedAddress].limits
            );
        }  
    }

    /// @notice Validates caller authority and managed address permissions.
    /// @dev Reverts if caller is not the protocol manager, if the authority
    ///      flag is false, or if the managed address lacks authority.
    /// @param managedAddress The address being managed.
    /// @param authority The permission flag that must be enabled.
    function _checkAuthority(
        address managedAddress,
        bool authority
    ) internal view {
        if (msg.sender != protocolManager) {
            revert ProtocolManager__Unauthorized();
        }

        if (!authority) {
            revert ProtocolManager__Unauthorized();
        }

        if (!config[managedAddress].hasAuthority) {
            revert ProtocolManager__Unauthorized();
        }
    }

    /// @notice Validates caller authority for both managed address and asset.
    /// @dev Calls `_checkAuthority` for managed address, then additionally
    ///      verifies the asset has authority configured.
    /// @param managedAddress The address being managed.
    /// @param asset The asset address that must also have authority.
    /// @param authority The permission flag that must be enabled.
    function _checkAuthorityAndAsset(
        address managedAddress,
        address asset,
        bool authority
    ) internal view {
        _checkAuthority(managedAddress, authority);
        
        if (!config[asset].hasAuthority) {
            revert ProtocolManager__Unauthorized();
        }
    }

    /// @dev Returns `floor(x * y / d)`.
    /// Reverts if `x * y` overflows, or `d` is zero.
    function _mulDiv(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 z) {
        /// @solidity memory-safe-assembly
        assembly {
            // Equivalent to require(d != 0 && (y == 0 || x <= type(uint256).max / y))
            if iszero(mul(d, iszero(mul(y, gt(x, div(not(0), y)))))) {
                mstore(0x00, 0x2f7ad0d8) // `ProtocolManager__MulDivFailed()`.
                revert(0x1c, 0x04)
            }
            z := div(mul(x, y), d)
        }
    }

    /// @notice Converts per-second rate back to BPS with proper rounding.
    /// @dev Uses rounding division to avoid ~1 BPS precision loss from truncation.
    /// @param ratePerSecond The rate per second (as stored in DynamicIRM).
    /// @param vertexFactor Either vertexStart or (WAD - vertexStart) in WAD.
    /// @return bps The rate in BPS, rounded to nearest.
    function _perSecondToBPS(
        uint256 ratePerSecond,
        uint256 vertexFactor
    ) internal pure returns (uint256 bps) {
        uint256 wadValue = _mulDiv(ratePerSecond, SECONDS_PER_YEAR * vertexFactor, WAD);
        bps = (wadValue + WAD_TO_BPS / 2) / WAD_TO_BPS;
    }

    /// @notice Returns the absolute value of `value`.
    /// @dev Safe for all inputs including `type(int256).min`. Uses two's
    ///      complement identity: `-x == ~x + 1`. By computing `~value + 1`
    ///      in uint256 space.
    /// @param value The signed integer to compute the absolute value of.
    /// @return x The absolute value of `value`.
    function _abs(int256 value) internal pure returns (uint256 x) {
        // For negative: cast to uint, then negate in uint space
        // -value == ~value + 1 (two's complement)
        x = value >= 0 ? uint256(value) : uint256(~value) + 1;
    }

    /// @notice Converts an unsigned uint256 into a signed int256.
    /// @param value The uint256 value to convert to int256.
    /// @return x The converted int256 value.
    function _toInt256(uint256 value) internal pure returns (int256 x) {
        // Note: Unsafe cast below is okay because `type(int256).max`
        //       is guaranteed to be positive
        if (value > uint256(type(int256).max)) {
            revert ProtocolManager__UintToIntError();
        }

        x = int256(value);
    }
}