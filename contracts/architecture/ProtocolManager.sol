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
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";
import { ICombinedAggregator } from "contracts/interfaces/ICombinedAggregator.sol";
import { IChainlinkStyleAdaptor } from "contracts/interfaces/IChainlinkStyleAdaptor.sol";

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

    /// @notice Configuration for a managed protocol address.
    struct ManagementConfig {
        bool hasAuthority;
        PeriodLimits limits;
    }

    /// @notice Period adjustments tracking for managed addresses.
    struct PeriodAdjustments {
        // Token Configs - Debt Cap
        int24 collRatio;
        int24 collReqSoft;
        int24 collReqHard;
        int120 collateralCap;
        // Interest Rate Model + Debt Cap
        int64 baseInterestRate;
        int112 debtCap; // Debt cap is out of order here to pack data a bit better
        int64 vertexInterestRate;
        int64 vertexStart;
        int16 adjustmentVelocity;
        int16 decayPerAdjustment;
        int24 vertexMultiplierMax;
        // Price Guard
        int96 basePriceUSD;
        int96 minPriceUSD;
        int96 basePriceNative;
        int96 minPriceNative;
    }

    /// @notice Period adjustment limitations for managed addresses.
    struct PeriodLimits {
        // Token Configs - Debt Cap
        uint24 collRatioLimit;
        uint24 collReqSoftLimit;
        uint24 collReqHardLimit;
        uint120 collateralCapLimit;
        // Interest Rate Model + Debt Cap
        uint64 baseInterestRateLimit;
        uint112 debtCapLimit; // Debt cap is out of order here to pack data a bit better
        uint64 vertexInterestRateLimit;
        uint64 vertexStartLimit;
        uint16 adjustmentVelocityLimit;
        uint16 decayPerAdjustmentLimit;
        uint24 vertexMultiplierMaxLimit;
        // Price Guard
        uint96 basePriceUSDLimit;
        uint96 minPriceUSDLimit;
        uint96 basePriceNativeLimit;
        uint96 minPriceNativeLimit;
    }

    /// @notice Permission flags for ProtocolManager capabilities.
    struct PermsConfig {
        bool canModifyPriceGuards;
        bool canDisablePriceGuards;
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

    /// @notice Maximum allowed period adjustment limits for token and IRM configs.
    /// @dev These cap the `PeriodLimits` values that can be set via `updateManagementConfig`.
    ///      All values in BPS unless otherwise noted.
    uint256 public constant MAXIMUM_COLL_RATIO_LIMIT = 500;
    uint256 public constant MAXIMUM_COLL_REQ_LIMIT = 500;
    uint256 public constant MAXIMUM_COLL_CAP_LIMIT = type(uint112).max;
    uint256 public constant MAXIMUM_DEBT_CAP_LIMIT = type(uint104).max;
    uint256 public constant MAXIMUM_INTEREST_RATE_LIMIT = 1000;
    uint256 public constant MAXIMUM_ADJUSTMENT_VELOCITY_LIMIT = 300;
    uint256 public constant MAXIMUM_DECAY_RATE_LIMIT = 120;
    uint256 public constant MAXIMUM_VERTEX_MULTIPLIER_MAX_LIMIT = 50000;
    /// @notice Maximum allowed period adjustment limit for price guard configs.
    uint256 public constant MAXIMUM_PRICE_GUARD_PRICE_LIMIT = uint256(uint96(type(int96).max));
    /// @notice Conversion factor from WAD (1e18) to BPS (1e4).
    uint256 public constant WAD_TO_BPS = 1e14;

    /// @notice Whether the protocol manager can modify token configs.
    bool public immutable canModifyTokenConfig;
    /// @notice Whether the protocol manager can modify price guards.
    bool public immutable canModifyPriceGuards;
    /// @notice Whether the protocol manager can disable price guards.
    /// @dev Separate from canModifyPriceGuards since disabling bypasses
    ///      period limits and is a more privileged operation.
    bool public immutable canDisablePriceGuards;
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
    /// @notice Whether the protocol manager can modify position managers.
    bool public immutable canModifyPositionManagers;

    /// @notice The duration of the period in which any value adjustment
    ///         restrictions are measured in, in seconds.
    /// @dev 604800 = 1 week.
    uint256 public constant PERIOD_DURATION = 604800;

    /// @notice The initial timestamp that value adjustment restriction
    ///         periods are calculated off of.
    uint256 internal constant _UNIX_START_TIMESTAMP = 1766966400;

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;

    /// @notice The address managing parts of the Curvance Protocol.
    address public immutable protocolManager;

    /// STORAGE ///

    /// @notice Configuration for managing a protocol address.
    /// @dev Protocol address => Management Configuration
    mapping(address => ManagementConfig) public config;

    /// @notice Management adjustments per period (length = `PERIOD_DURATION`).
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
    error ProtocolManager__TooEarlyInPeriod();

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
        canDisablePriceGuards = p.canDisablePriceGuards;
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
    /// @return collReqSoft Soft collateral requirement adjustment.
    /// @return collReqHard Hard collateral requirement adjustment.
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
        int64, int64, int64, int16, int16, int24
    ) {
        PeriodAdjustments storage p = _periodAdjustments[managedAddress][periodTimestamp];
        return (
            p.collRatio,
            p.collReqSoft,
            p.collReqHard,
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
    ) external view returns (int96, int96, int96, int96) {
        PeriodAdjustments storage p = _periodAdjustments[managedAddress][periodTimestamp];
        return (p.basePriceUSD, p.minPriceUSD, p.basePriceNative, p.minPriceNative);
    }

    /// @notice Updates management configuration for `managedAddresses`.
    /// @dev Validates all limits against maximums before storing. Emits
    ///      {ManagementAuthorityUpdated} for each address in
    ///      `managedAddresses`.
    ///
    ///      Can only be called in the final 1/3 of an adjustment period to
    ///      prevent inconsistent behavior when limits are reduced mid-period
    ///      while adjustments are already active. This ensures any temporary
    ///      state inconsistency resolves when the period resets.
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

        if (block.timestamp - getPeriodTimestamp() < (PERIOD_DURATION * 2) / 3) {
            revert ProtocolManager__TooEarlyInPeriod();
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
        p.collReqSoft = int24(_calcAdj(n.collReqSoft, collReqSoft - BPS, p.collReqSoft, l.collReqSoftLimit));
        p.collReqHard = int24(_calcAdj(n.collReqHard, collReqHard - BPS, p.collReqHard, l.collReqHardLimit));
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
        p.decayPerAdjustment = int16(_calcAdj(decayPerAdjustment, rc.decayPerAdjustment, p.decayPerAdjustment, l.decayPerAdjustmentLimit));
        p.vertexMultiplierMax = int24(_calcAdj(vertexMultiplierMax, rc.vertexMultiplierMax / WAD_TO_BPS, p.vertexMultiplierMax, l.vertexMultiplierMaxLimit));

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
    /// @param asset The address of the asset to configure a PriceGuard for.
    /// @param inUSD Specifies whether the PriceGuard should be in
    ///              USD (true) or a chain's native token (false).
    /// @param timestampStart When `ips` should start increasing `basePrice`
    ///                       raising the maximum price returned when pricing
    ///                       `asset`.
    /// @param ips The magnitude that `basePrice` should increase
    ///            overtime from `timestampStart`, in `WAD`, per second.
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

        IOracleAdaptor.PriceGuard memory pg = oa.getPriceGuard(asset, inUSD);

        // Enforce that ips and timestampStart match current values to prevent
        // price manipulation through these parameters.
        if (timestampStart != pg.timestampStart || ips != pg.ips) {
            revert ProtocolManager__ParametersAreInvalid();
        }

        _applyPriceGuardLimits(asset, inUSD, basePrice, minPrice, pg);

        BaseOracleAdaptor(managedAddress).setGuardedPriceConfig(
            asset,
            inUSD,
            timestampStart,
            ips,
            basePrice,
            minPrice
        );
    }

    /// @notice Sets a PriceGuard on a CombinedAggregator for pricing `asset`.
    /// @dev Validates that `managedAddress` is the aggregator configured for
    ///      `asset` and `inUSD` in the oracle adaptor before applying changes.
    ///      Unlike regular adaptors, CombinedAggregators have a single global
    ///      PriceGuard rather than per-asset/per-denomination guards.
    /// @param managedAddress The CombinedAggregator address to configure.
    /// @param asset The address of the asset priced by this aggregator.
    /// @param inUSD Specifies whether this aggregator is used for USD (true)
    ///              or native token (false) pricing of the asset.
    /// @param timestampStart When `ips` should start increasing `basePrice`
    ///                       raising the maximum price returned.
    /// @param ips The magnitude that `basePrice` should increase overtime
    ///            from `timestampStart`, in `WAD`, per second.
    /// @param basePrice The base price that should be the maximum price
    ///                  returned when pricing.
    /// @param minPrice The minimum price that should be allowed to be returned.
    function setGuardedPriceConfigCombined(
        address managedAddress,
        address asset,
        bool inUSD,
        uint256 timestampStart,
        uint256 ips,
        uint256 basePrice,
        uint256 minPrice
    ) external nonReentrant {
        _checkAuthorityAndAsset(managedAddress, asset, canModifyPriceGuards);

        // Validate inUSD matches the oracle configuration to ensure limit
        // tracking uses the correct bucket (USD vs native).
        address adaptor = IOracleManager(centralRegistry.oracleManager())
            .getPricingAdaptors(asset)[0];
        (, address aggregator, , ) = IChainlinkStyleAdaptor(adaptor).assetConfig(
            asset,
            inUSD
        );
        // Validate that the aggregator for the asset and inUSD matches the 
        // managedAddress (combined aggregator).
        if (aggregator != managedAddress) {
            revert ProtocolManager__ParametersAreInvalid();
        }

        // Get current price guard from the combined aggregator.
        // Combined aggregator does not have a `getPriceGuard()` function,
        // auto generated getters return the fields separately instead of a struct.
        (
            uint40 pgTimestampStart,
            uint40 pgIps,
            uint88 pgBasePrice,
            uint88 pgMinPrice
        ) = ICombinedAggregator(managedAddress).pg();

        // Enforce that ips and timestampStart match current values to prevent
        // price manipulation through these parameters.
        if (timestampStart != pgTimestampStart || ips != pgIps) {
            revert ProtocolManager__ParametersAreInvalid();
        }

        _applyPriceGuardLimits(
            asset,
            inUSD,
            basePrice,
            minPrice,
            IOracleAdaptor.PriceGuard({
                timestampStart: pgTimestampStart,
                ips: pgIps,
                basePrice: pgBasePrice,
                minPrice: pgMinPrice
            })
        );

        ICombinedAggregator(managedAddress).setGuardedPriceConfig(
            timestampStart,
            ips,
            basePrice,
            minPrice
        );
    }

    /// @notice Disables any PriceGuard active when pricing `asset`
    ///         denominated either USD or native tokens depending on `inUSD`.
    /// @dev Removes price bounds for the specified asset and denomination.
    ///      Uses separate permission from modifying since disabling bypasses
    ///      period limits and is a more privileged operation.
    /// @param managedAddress The oracle adaptor address to configure.
    /// @param asset The address of the asset to disable PriceGuard on.
    /// @param inUSD Whether to disable USD (true) or native (false) guard.
    function disableGuardedPriceConfig(
        address managedAddress,
        address asset,
        bool inUSD
    ) external nonReentrant {
        _checkAuthorityAndAsset(managedAddress, asset, canDisablePriceGuards);

        if (!IOracleAdaptor(managedAddress).isSupportedAsset(asset)) {
            revert ProtocolManager__ParametersAreInvalid();
        }

        BaseOracleAdaptor(managedAddress).disableGuardedPriceConfig(
            asset,
            inUSD
        );
    }

    /// @notice Disables the PriceGuard on a combined aggregator.
    /// @dev Combined aggregators have a single global PriceGuard (not per-asset
    ///      or per-denomination). Uses separate permission from modifying since
    ///      disabling bypasses period limits and is a more privileged operation.
    /// @param managedAddress The combined aggregator address to configure.
    function disableGuardedPriceConfigCombined(
        address managedAddress
    ) external nonReentrant {
        _checkAuthority(managedAddress, canDisablePriceGuards);

        ICombinedAggregator(managedAddress).disableGuardedPriceConfig();
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
    ) external nonReentrant {
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
    ) external nonReentrant {
        _checkAuthority(managedAddress, canModifyPositionManagers);

        if (add) {
            MarketManagerIsolated(managedAddress).addPositionManager(pm);
        } else {
            MarketManagerIsolated(managedAddress).removePositionManager(pm);
        }
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Returns the current period timestamp for adjustment tracking.
    /// @dev Periods are calculated from `_UNIX_START_TIMESTAMP` in increments
    ///      of `PERIOD_DURATION`. Used to bucket adjustments by time period.
    /// @return x The start timestamp of the current period.
    function getPeriodTimestamp() public view returns (uint256 x) {
        uint256 periods = (block.timestamp - _UNIX_START_TIMESTAMP) / PERIOD_DURATION;
        x = _UNIX_START_TIMESTAMP + (periods * PERIOD_DURATION);
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
        // We don't have to worry about overflow when casting these later since
        // adjustment limit values are the same bit size `adj` is cast to later.
        if (_abs(adj) > limit) revert ProtocolManager__ParametersAreInvalid();
    }

    /// @notice Applies price guard limit accounting for the current period.
    /// @param asset The asset to apply limits for.
    /// @param inUSD Whether to apply USD or native token limits.
    /// @param basePrice The new base price value.
    /// @param minPrice The new min price value.
    /// @param pg The current price guard configuration.
    function _applyPriceGuardLimits(
        address asset,
        bool inUSD,
        uint256 basePrice,
        uint256 minPrice,
        IOracleAdaptor.PriceGuard memory pg
    ) internal {
        PeriodAdjustments storage p = _periodAdjustments[asset][
            getPeriodTimestamp()
        ];
        PeriodLimits memory l = config[asset].limits;

        if (inUSD) {
            p.basePriceUSD = int96(
                _calcAdj(basePrice, pg.basePrice, p.basePriceUSD, l.basePriceUSDLimit)
            );
            p.minPriceUSD = int96(
                _calcAdj(minPrice, pg.minPrice, p.minPriceUSD, l.minPriceUSDLimit)
            );
        } else {
            p.basePriceNative = int96(
                _calcAdj(basePrice, pg.basePrice, p.basePriceNative, l.basePriceNativeLimit)
            );
            p.minPriceNative = int96(
                _calcAdj(minPrice, pg.minPrice, p.minPriceNative, l.minPriceNativeLimit)
            );
        }
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
        for (uint256 i; i < numManagedAddresses; ++i) {
            cachedAddress = managedAddresses[i];
            ManagementConfig storage cfg = config[cachedAddress];

            cfg.hasAuthority = hasAuthority;

            if (hasAuthority) {
                limits = l[i];

                if (
                    limits.collRatioLimit > MAXIMUM_COLL_RATIO_LIMIT ||
                    limits.collReqSoftLimit > MAXIMUM_COLL_REQ_LIMIT ||
                    limits.collReqHardLimit > MAXIMUM_COLL_REQ_LIMIT ||
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

                cfg.limits = limits;
            } else {
                delete cfg.limits;
            }

            emit ManagementAuthorityUpdated(
                cachedAddress,
                hasAuthority,
                cfg.limits
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
        if (msg.sender != protocolManager || 
            !authority ||
            !config[managedAddress].hasAuthority)
        {
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
    /// @dev Uses "round half up" division to restore the original BPS value.
    ///      Due to precision loss during the forward conversion (BPS → per-second
    ///      in DynamicIRM), the intermediate `wadValue` is slightly less than a
    ///      clean multiple of WAD_TO_BPS (e.g., 99999990905760 instead of 1e14).
    ///      This means the effective rounding direction is UP, which correctly
    ///      restores the original BPS value and ensures adjustment limits are
    ///      conservatively maintained.
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
    ///      complement identity: `-x == ~x + 1`. Computes `~value` in int256
    ///      space, casts to uint256, then adds 1.
    /// @param value The signed integer to compute the absolute value of.
    /// @return x The absolute value of `value`.
    function _abs(int256 value) internal pure returns (uint256 x) {
        // Two's complement: -value == ~value + 1
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