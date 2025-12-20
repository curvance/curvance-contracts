// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { DynamicIRM } from "contracts/market/DynamicIRM.sol";
import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";

import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";
import { ReentrancyGuard } from "contracts/libraries/ReentrancyGuardTransient.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";

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

    struct ManageConfig {
        bool hasAuthority;
        PeriodAdjustmentLimits limits;
    }

    /// @title Period Adjustments.
    struct PeriodAdjustments {
        int24 collRatio;
        int64 baseInterestRate;
        int64 vertexInterestRate;
        int64 vertexStart;
        int16 adjustmentRate;
        int8 decayPerAdjustment;
        int16 vertexMultiplierMax;
        int88 basePrice;
        int88 minPrice;
    }

    /// @title Period Adjustment Limitations.
    struct PeriodAdjustmentLimits {
        uint24 collRatioAdjustmentLimit;
        uint64 baseInterestRateAdjustmentLimit;
        uint64 vertexInterestRateAdjustmentLimit;
        uint64 vertexStartAdjustmentLimit;
        uint16 adjustmentRate;
        uint8 decayPerAdjustment;
        uint16 vertexMultiplierMax;
        uint88 basePriceAdjustmentLimit;
        uint88 minPriceAdjustmentLimit;
    }

    struct PermsConfig {
        bool canModifyPriceGuards;
        bool canModifyTokenConfig;
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
    uint256 public constant MAXIMUM_COLL_RATIO_ADJUSTMENT_LIMIT = 500;
    uint256 public constant MAXIMUM_INTEREST_RATE_ADJUSTMENT_LIMIT = 1000;
    uint256 public constant MAXIMUM_ADJUSTMENT_RATE_ADJUSTMENT_LIMIT = 500;
    uint256 public constant MAXIMUM_DECAY_RATE_ADJUSTMENT_LIMIT = 200;
    uint256 public constant MAXIMUM_VERTEX_MULTIPLIER_MAX_ADJUSTMENT_LIMIT = 50000;
    uint256 public constant MAXIMUM_PRICE_GUARD_PRICE_ADJUSTMENT_LIMIT = type(uint88).max;

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

    address public immutable protocolManager;

    /// STORAGE ///

    mapping(address => ManageConfig) public config;
    mapping(uint256 => PeriodAdjustments) public periodAdjustments;

    /// EVENTS ///

    event ManagementAuthorityUpdated(
        address addressManaged,
        bool manages,
        PeriodAdjustmentLimits limits
    );

    /// ERRORS ///

    error ProtocolManager__ParametersAreInvalid();
    error ProtocolManager__Unauthorized();

    constructor(
        ICentralRegistry cr,
        address pm,
        PermsConfig memory p,
        address[] memory managedAddresses,
        PeriodAdjustmentLimits[] memory l
    ) {
        CentralRegistryLib._isCentralRegistry(cr);
        centralRegistry = cr;
        protocolManager = pm;

        _updateManagementConfig(managedAddresses, l, true);

        canModifyPriceGuards = p.canModifyPriceGuards;
        canModifyTokenConfig = p.canModifyTokenConfig;
        canUnpause = p.canUnpause;
        canModifyMintStatus = p.canModifyMintStatus;
        canModifyCollateralizationStatus = p.canModifyCollateralizationStatus;
        canModifyBorrowStatus = p.canModifyBorrowStatus;
        canModifyLiquidationStatus = p.canModifyLiquidationStatus;
        canModifyRedeemStatus = p.canModifyRedeemStatus;
        canModifyTransferStatus = p.canModifyTransferStatus;
        canModifyPositionManagers = p.canModifyPositionManagers;
    }

    function updateManagementConfig(
        address[] memory managedAddresses,
        PeriodAdjustmentLimits[] memory l,
        bool hasAuthority
    ) external {
        if (!centralRegistry.hasElevatedPermissions(msg.sender)) {
            revert ProtocolManager__Unauthorized();
        }

        _updateManagementConfig(managedAddresses, l, hasAuthority);
    }

    /// @notice Sets token liquidity configuration values for
    ///         `newConfig.cToken` a listed cToken inside this market.
    /// @dev Emits a {TokenConfigUpdated} event.
    /// @param newConfig A TokenConfig struct containing:
    ///                  cToken The Curvance token to update liquidity
    ///                         configuration values of.
    ///                  collRatio The ratio at which $1 of collateral can be
    ///                            borrowed against, for `newConfig.cToken`,
    ///                            in `BPS`.
    ///                  collReqSoft The premium of excess collateral required
    ///                              to avoid soft liquidation, in `BPS`.
    ///                  collReqHard The premium of excess collateral required
    ///                              to avoid hard liquidation, in `BPS`.
    ///                  liqIncBase The default liquidation incentive for
    ///                             `newConfig.cToken`, in `BPS`.
    ///                  liqIncHard The hard liquidation incentive for
    ///                             `newConfig.cToken`, in `BPS`.
    ///                  liqIncMin The minimum possible liquidation incentive
    ///                            for `newConfig.cToken` during an auction,
    ///                            in `BPS`.
    ///                  liqIncMax The maximum possible liquidation incentive
    ///                            for `newConfig.cToken` during an auction,
    ///                            in `BPS`.
    ///                  closeFactorBase Maximum % that a liquidator can repay
    ///                                  when soft liquidating
    ///                                  `newConfig.cToken` for an account.
    ///                  closeFactorMin The minimum possible close factor for
    ///                                 `newConfig.cToken` during an auction,
    ///                                 in `BPS`.
    ///                  closeFactorMax The maximum possible close factor for
    ///                                 `newConfig.cToken` during an auction,
    ///                                 in `BPS`.
    ///                  collateralCap The maximum amount of shares that can
    ///                                be collateralized of `newConfig.cToken`
    ///                                inside this market.
    ///                  debtCap The maximum amount of assets that can be
    ///                          borrowed of `newConfig.cToken` inside this
    ///                          market.
    function updateTokenConfig(
        address managedAddress,
        MarketManagerIsolated.TokenConfig memory newConfig
    ) external {
        _checkAuthorityAndAsset(managedAddress, newConfig.cToken, canModifyTokenConfig);

        MarketManagerIsolated(managedAddress).updateTokenConfig(newConfig);
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
    ) external {
        _checkAuthorityAndAsset(managedAddress, asset, canModifyPriceGuards);

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
    /// @param asset The address of the asset to disable any PriceGuard data on.
    /// @param inUSD Specifies whether the PriceGuard disabled should be in
    ///              USD (true) or a chain's native token (false).
    function disableGuardedPriceConfig(
        address managedAddress,
        address asset,
        bool inUSD
    ) external {
        _checkAuthorityAndAsset(managedAddress, asset, canModifyPriceGuards);

        BaseOracleAdaptor(managedAddress).disableGuardedPriceConfig(
            asset,
            inUSD
        );
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
    ) external {
        _checkAuthority(managedAddress, canModifyIRM);

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

    /// @notice Admin function to set market-wide liquidation status.
    /// @dev Requires market permissions, corresponding contracts may restrict
    ///      `state` input. Emits an {ActionPaused} event.
    /// @param state Whether the desired action is pausing or unpausing.
    function setLiquidationPaused(
        address managedAddress,
        bool state
    ) external {
        _checkAuthority(managedAddress, canModifyLiquidationStatus);
        _checkUnpauseAuthority(state);

        MarketManagerIsolated(managedAddress).setLiquidationPaused(state);
    }

    /// @notice Admin function to set market-wide redemption status.
    /// @dev Requires market permissions, corresponding contracts may restrict
    ///      `state` input. Emits an {ActionPaused} event.
    /// @param state Whether redemptions should be paused or unpaused.
    function setRedeemPaused(address managedAddress, bool state) external {
        _checkAuthority(managedAddress, canModifyRedeemStatus);
        _checkUnpauseAuthority(state);

        MarketManagerIsolated(managedAddress).setRedeemPaused(state);
    }

    /// @notice Admin function to set market-wide transfer status.
    /// @dev Requires market permissions, corresponding contracts may restrict
    ///      `state` input. Emits an {ActionPaused} event.
    /// @param state Whether transfers should be paused or unpaused.
    function setTransferPaused(address managedAddress, bool state) external {
        _checkAuthority(managedAddress, canModifyTransferStatus);
        _checkUnpauseAuthority(state);

        MarketManagerIsolated(managedAddress).setTransferPaused(state);
    }

    /// @notice Admin function to set token-specific Curvance token
    ///         minting status.
    /// @dev Requires market permissions, corresponding contracts may restrict
    ///      `state` input. Emits a {TokenActionPaused} event.
    /// @param cToken The Curvance token to set minting status for.
    /// @param state Whether minting should be paused or unpaused.
    function setMintPaused(
        address managedAddress,
        address cToken,
        bool state
    ) external {
        _checkAuthorityAndAsset(managedAddress, cToken, canModifyMintStatus);
        _checkUnpauseAuthority(state);

        MarketManagerIsolated(managedAddress).setMintPaused(cToken, state);
    }

    /// @notice Admin function to set token-specific Curvance token
    ///         collateralization status.
    /// @dev Requires market permissions, corresponding contracts may restrict
    ///      `state` input. Emits a {TokenActionPaused} event.
    /// @param cToken The Curvance token to set collateralization status for.
    /// @param state Whether collateralization should be paused or unpaused.
    function setCollateralizationPaused(
        address managedAddress,
        address cToken,
        bool state
    ) external {
        _checkAuthorityAndAsset(managedAddress, cToken, canModifyCollateralizationStatus);
        _checkUnpauseAuthority(state);

        MarketManagerIsolated(managedAddress).setCollateralizationPaused(cToken, state);
    }

    /// @notice Admin function to set token-specific Curvance token
    ///         borrowing status.
    /// @dev Requires market permissions, corresponding contracts may restrict
    ///      `state` input. Emits a {TokenActionPaused} event.
    /// @param cToken The Curvance token to set borrowing status for.
    /// @param state Whether borrowing should be paused or unpaused.
    function setBorrowPaused(
        address managedAddress,
        address cToken,
        bool state
    ) external {
        _checkAuthorityAndAsset(managedAddress, cToken, canModifyBorrowStatus);
        _checkUnpauseAuthority(state);

        MarketManagerIsolated(managedAddress).setBorrowPaused(cToken, state);
    }

    /// @notice Adds a new position manager address for complex
    ///         position actions.
    /// @dev Requires timelock authority.
    ///      Emits a {PositionManagerUpdated} event.
    /// @param newPM The address to add position manager permissions for.
    function addPositionManager(
        address managedAddress,
        address newPM
    ) external {
        _checkAuthority(managedAddress, canModifyPositionManagers);

        MarketManagerIsolated(managedAddress).addPositionManager(newPM);
    }

    /// @notice Removes a current position manager address from complex
    ///         position actions.
    /// @dev Requires timelock authority.
    ///      Emits a {PositionManagerUpdated} event.
    /// @param oldPM The address to remove position manager permissions for.
    function removePositionManager(
        address managedAddress,
        address oldPM
    ) external {
        _checkAuthority(managedAddress, canModifyPositionManagers);

        MarketManagerIsolated(managedAddress).removePositionManager(oldPM);
    }

    /// INTERNAL FUNCTIONS ///

    function _updateManagementConfig(
        address[] memory managedAddresses,
        PeriodAdjustmentLimits[] memory l,
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
        PeriodAdjustmentLimits memory cachedLimits;
        for (uint i; i < numManagedAddresses; ++i) {
            cachedAddress = managedAddresses[i];
            cachedLimits = l[i];

            if (
                cachedLimits.collRatioAdjustmentLimit > MAXIMUM_COLL_RATIO_ADJUSTMENT_LIMIT ||
                cachedLimits.baseInterestRateAdjustmentLimit > MAXIMUM_INTEREST_RATE_ADJUSTMENT_LIMIT ||
                cachedLimits.vertexInterestRateAdjustmentLimit > MAXIMUM_INTEREST_RATE_ADJUSTMENT_LIMIT ||
                cachedLimits.vertexStartAdjustmentLimit > MAXIMUM_INTEREST_RATE_ADJUSTMENT_LIMIT ||
                cachedLimits.adjustmentRate > MAXIMUM_ADJUSTMENT_RATE_ADJUSTMENT_LIMIT ||
                cachedLimits.decayPerAdjustment > MAXIMUM_DECAY_RATE_ADJUSTMENT_LIMIT ||
                cachedLimits.vertexMultiplierMax > MAXIMUM_VERTEX_MULTIPLIER_MAX_ADJUSTMENT_LIMIT ||
                cachedLimits.basePriceAdjustmentLimit > MAXIMUM_PRICE_GUARD_PRICE_ADJUSTMENT_LIMIT ||
                cachedLimits.minPriceAdjustmentLimit > MAXIMUM_PRICE_GUARD_PRICE_ADJUSTMENT_LIMIT
            ) {
                revert ProtocolManager__ParametersAreInvalid();
            }

            config[cachedAddress].hasAuthority = hasAuthority;

            if (hasAuthority) {
                config[cachedAddress].limits = cachedLimits;
            } else {
                delete config[cachedAddress].limits;
            }

            emit ManagementAuthorityUpdated(
                cachedAddress,
                false,
                config[cachedAddress].limits
            );
        }  
    }

    /// @dev Returns the current period timestamp for checking adjustment limits.
    function _getPeriodTimestamp() internal view returns (uint256 result) {
        uint256 periods = (block.timestamp - _unixStartTimestamp) / periodDuration;
        result = _unixStartTimestamp + (periods * periodDuration);
    }

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

    /// @dev Checks whether the caller has sufficient permissioning.
    function _checkUnpauseAuthority(bool state) internal view {
        if (!state) {
            if (!canUnpause) {
                revert ProtocolManager__Unauthorized();
            }
        }
    }
}