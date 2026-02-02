// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ProtocolManager } from "contracts/architecture/ProtocolManager.sol";
import { TestProtocolManagerBase } from "tests/architecture/ProtocolManager/TestProtocolManagerBase.t.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @notice Tests for ProtocolManager.updateTokenConfig
/// @dev The manager (protocolManager address) calls updateTokenConfig to modify token
///      liquidity configurations (collRatio, margins, caps) on market managers.
///      Both the market manager and cToken asset must have authority in the config.
contract TestProtocolManagerUpdateTokenConfig is TestProtocolManagerBase {

    address public manager;

    function setUp() public override {
        super.setUp();

        manager = makeAddr("manager");

        // Deploy ProtocolManager with manager and managed addresses
        // Both the market manager AND the cToken need authority
        address[] memory managedAddresses = new address[](3);
        managedAddresses[0] = address(marketManagerIsolated); // The market being managed
        managedAddresses[1] = address(borrowableCUSDC_MONAD); // cToken asset
        managedAddresses[2] = address(borrowableCWMON);       // cToken asset

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](3);
        limits[0] = _getValidLimits();
        limits[1] = _getValidLimits();
        limits[2] = _getValidLimits();

        ProtocolManager.PermsConfig memory permsConfig = _getDefaultPermsConfig();

        protocolManager = new ProtocolManager(
            ICentralRegistry(address(centralRegistry)),
            manager,
            permsConfig,
            managedAddresses,
            limits
        );

        // Grant ProtocolManager market permissions so it can call updateTokenConfig
        centralRegistry.addMarketPermissions(address(protocolManager));
    }

    /// @notice Helper to get current token config values
    function _getCurrentConfig(address cToken) internal view returns (
        uint256 collRatio,
        uint256 collReqSoft,
        uint256 collReqHard,
        uint256 collateralCap,
        uint256 debtCap
    ) {
        (collRatio, collReqSoft, collReqHard) = marketManagerIsolated.collConfig(cToken);
        collateralCap = marketManagerIsolated.collateralCaps(cToken);
        debtCap = marketManagerIsolated.debtCaps(cToken);
    }

    /// @notice Helper to create a valid TokenConfig based on current values with small adjustments
    /// @dev Note: collConfig() returns stored values with BPS (10000) added, but updateTokenConfig()
    ///      expects input values without BPS. We subtract BPS here to get the input format.
    function _getValidTokenConfig(
        address cToken,
        int256 collRatioDelta,
        int256 collReqSoftDelta,
        int256 collReqHardDelta,
        int256 collCapDelta,
        int256 debtCapDelta
    ) internal view returns (MarketManagerIsolated.TokenConfig memory config) {
        (uint256 collRatio, uint256 collReqSoft, uint256 collReqHard, uint256 collCap, uint256 debtCap) =
            _getCurrentConfig(cToken);

        // collReqSoft and collReqHard are stored with BPS added, subtract to get input format
        uint256 BPS = 10000;

        config.cToken = cToken;
        config.collRatio = uint256(int256(collRatio) + collRatioDelta);
        config.collReqSoft = uint256(int256(collReqSoft - BPS) + collReqSoftDelta);
        config.collReqHard = uint256(int256(collReqHard - BPS) + collReqHardDelta);

        // Keep liquidation parameters valid (these are not tracked by ProtocolManager)
        config.liqIncBase = 1000;
        config.liqIncHard = 1500;
        config.liqIncMin = 10;
        config.liqIncMax = 2000;
        config.closeFactorBase = 2000;
        config.closeFactorMin = 2000;
        config.closeFactorMax = 5000;

        config.collateralCap = uint256(int256(collCap) + collCapDelta);
        config.debtCap = uint256(int256(debtCap) + debtCapDelta);
    }

    /// SUCCESS TESTS ///

    /// @notice Test successful updateTokenConfig with small collRatio increase
    function test_updateTokenConfig_success_collRatioIncrease() public {
        MarketManagerIsolated.TokenConfig memory config = _getValidTokenConfig(
            address(borrowableCWMON),
            50,  // +50 bps collRatio (within 100 limit)
            0,
            0,
            0,
            0
        );

        (uint256 oldCollRatio,,,,) = _getCurrentConfig(address(borrowableCWMON));

        vm.prank(manager);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config);

        (uint256 newCollRatio,,,,) = _getCurrentConfig(address(borrowableCWMON));
        assertEq(newCollRatio, oldCollRatio + 50, "collRatio should increase by 50");
    }

    /// @notice Test successful updateTokenConfig with collRatio decrease
    function test_updateTokenConfig_success_collRatioDecrease() public {
        MarketManagerIsolated.TokenConfig memory config = _getValidTokenConfig(
            address(borrowableCWMON),
            -50,  // -50 bps collRatio (within 100 limit)
            0,
            0,
            0,
            0
        );

        (uint256 oldCollRatio,,,,) = _getCurrentConfig(address(borrowableCWMON));

        vm.prank(manager);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config);

        (uint256 newCollRatio,,,,) = _getCurrentConfig(address(borrowableCWMON));
        assertEq(newCollRatio, oldCollRatio - 50, "collRatio should decrease by 50");
    }

    /// @notice Test successful updateTokenConfig with margin adjustments
    function test_updateTokenConfig_success_marginAdjustments() public {
        MarketManagerIsolated.TokenConfig memory config = _getValidTokenConfig(
            address(borrowableCWMON),
            0,
            40,   // +40 bps collReqSoft (within 50 limit)
            30,   // +30 bps collReqHard (within 100 limit, must stay < collReqSoft)
            0,
            0
        );

        (, uint256 oldMarginSoft, uint256 oldMarginHard,,) = _getCurrentConfig(address(borrowableCWMON));

        vm.prank(manager);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config);

        (, uint256 newMarginSoft, uint256 newMarginHard,,) = _getCurrentConfig(address(borrowableCWMON));
        assertEq(newMarginSoft, oldMarginSoft + 40, "collReqSoft should increase by 40");
        assertEq(newMarginHard, oldMarginHard + 30, "collReqHard should increase by 30");
    }

    /// @notice Test successful updateTokenConfig with collateralCap increase
    function test_updateTokenConfig_success_collateralCapIncrease() public {
        MarketManagerIsolated.TokenConfig memory config = _getValidTokenConfig(
            address(borrowableCWMON),
            0,
            0,
            0,
            500_000e18,  // +500k (within 1M limit)
            0
        );

        (,,, uint256 oldCollCap,) = _getCurrentConfig(address(borrowableCWMON));

        vm.prank(manager);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config);

        (,,, uint256 newCollCap,) = _getCurrentConfig(address(borrowableCWMON));
        assertEq(newCollCap, oldCollCap + 500_000e18, "collateralCap should increase by 500k");
    }

    /// @notice Test successful updateTokenConfig with debtCap increase
    function test_updateTokenConfig_success_debtCapIncrease() public {
        // Use USDC token which has debtCap configured
        MarketManagerIsolated.TokenConfig memory config = _getValidTokenConfig(
            address(borrowableCUSDC_MONAD),
            0,
            0,
            0,
            0,
            500_000e6  // +500k USDC (within 1M limit)
        );

        (,,,, uint256 oldDebtCap) = _getCurrentConfig(address(borrowableCUSDC_MONAD));

        vm.prank(manager);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config);

        (,,,, uint256 newDebtCap) = _getCurrentConfig(address(borrowableCUSDC_MONAD));
        assertEq(newDebtCap, oldDebtCap + 500_000e6, "debtCap should increase by 500k");
    }

    /// @notice Test successful multiple updates within the same period
    function test_updateTokenConfig_success_multipleUpdatesInPeriod() public {
        // First update: +30 collRatio
        MarketManagerIsolated.TokenConfig memory config1 = _getValidTokenConfig(
            address(borrowableCWMON),
            30,
            0,
            0,
            0,
            0
        );

        vm.prank(manager);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config1);

        // Second update: +30 more collRatio (total 60, still within 100 limit)
        MarketManagerIsolated.TokenConfig memory config2 = _getValidTokenConfig(
            address(borrowableCWMON),
            30,
            0,
            0,
            0,
            0
        );

        vm.prank(manager);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config2);

        // Verify period adjustments are tracked per-token
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();
        (int24 collRatioAdj,,,,,,,,,,) = protocolManager.getMarketPeriodAdjustments(
            address(borrowableCWMON),  // Query by cToken, not market
            periodTimestamp
        );
        assertEq(collRatioAdj, 60, "collRatio adjustment should be 60");
    }

    /// @notice Test successful update with all parameters changed
    function test_updateTokenConfig_success_allParametersChanged() public {
        MarketManagerIsolated.TokenConfig memory config = _getValidTokenConfig(
            address(borrowableCWMON),
            50,       // +50 collRatio
            20,       // +20 collReqSoft
            15,       // +15 collReqHard
            100_000e18,  // +100k collateralCap
            0
        );

        vm.prank(manager);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config);

        // Verify all adjustments tracked per-token
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();
        (
            int24 collRatioAdj,
            int24 collReqSoftAdj,
            int24 collReqHardAdj,
            int120 collCapAdj,
            ,,,,,,
        ) = protocolManager.getMarketPeriodAdjustments(
            address(borrowableCWMON),  // Query by cToken, not market
            periodTimestamp
        );

        assertEq(collRatioAdj, 50, "collRatio adjustment mismatch");
        assertEq(collReqSoftAdj, 20, "collReqSoft adjustment mismatch");
        assertEq(collReqHardAdj, 15, "collReqHard adjustment mismatch");
        assertEq(collCapAdj, int120(int256(100_000e18)), "collateralCap adjustment mismatch");
    }

    /// FAILURE TESTS ///

    /// @notice Test that non-manager cannot call updateTokenConfig
    function test_updateTokenConfig_fail_notManager() public {
        address notManager = makeAddr("notManager");

        MarketManagerIsolated.TokenConfig memory config = _getValidTokenConfig(
            address(borrowableCWMON),
            50,
            0,
            0,
            0,
            0
        );

        vm.prank(notManager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config);
    }

    /// @notice Test that manager cannot manage market without authority
    function test_updateTokenConfig_fail_marketNoAuthority() public {
        // Create a new market manager that doesn't have authority
        address unauthorizedMarket = makeAddr("unauthorizedMarket");

        MarketManagerIsolated.TokenConfig memory config = _getValidTokenConfig(
            address(borrowableCWMON),
            50,
            0,
            0,
            0,
            0
        );

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.updateTokenConfig(unauthorizedMarket, config);
    }

    /// @notice Test that manager cannot configure cToken without authority
    function test_updateTokenConfig_fail_cTokenNoAuthority() public {
        // Use a cToken address that doesn't have authority in ProtocolManager
        address unauthorizedCToken = makeAddr("unauthorizedCToken");

        MarketManagerIsolated.TokenConfig memory config;
        config.cToken = unauthorizedCToken;
        config.collRatio = 7000;
        config.collReqSoft = 4000;
        config.collReqHard = 3000;
        config.liqIncBase = 1000;
        config.liqIncHard = 1500;
        config.liqIncMin = 10;
        config.liqIncMax = 2000;
        config.closeFactorBase = 2000;
        config.closeFactorMin = 2000;
        config.closeFactorMax = 5000;

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config);
    }

    /// @notice Test that updateTokenConfig fails if canModifyTokenConfig is false
    function test_updateTokenConfig_fail_noPermission() public {
        // Deploy a new ProtocolManager without canModifyTokenConfig permission
        address[] memory managedAddresses = new address[](2);
        managedAddresses[0] = address(marketManagerIsolated);
        managedAddresses[1] = address(borrowableCWMON);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](2);
        limits[0] = _getValidLimits();
        limits[1] = _getValidLimits();

        ProtocolManager.PermsConfig memory permsConfig = ProtocolManager.PermsConfig({
            canModifyPriceGuards: true,
            canDisablePriceGuards: true,
            canModifyTokenConfig: false, // Disabled
            canModifyIRM: true,
            canUnpause: true,
            canModifyMintStatus: true,
            canModifyCollateralizationStatus: true,
            canModifyBorrowStatus: true,
            canModifyLiquidationStatus: true,
            canModifyRedeemStatus: true,
            canModifyTransferStatus: true,
            canModifyPositionManagers: true
        });

        ProtocolManager restrictedPM = new ProtocolManager(
            ICentralRegistry(address(centralRegistry)),
            manager,
            permsConfig,
            managedAddresses,
            limits
        );

        centralRegistry.addMarketPermissions(address(restrictedPM));

        MarketManagerIsolated.TokenConfig memory config = _getValidTokenConfig(
            address(borrowableCWMON),
            50,
            0,
            0,
            0,
            0
        );

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        restrictedPM.updateTokenConfig(address(marketManagerIsolated), config);
    }

    /// @notice Test that updateTokenConfig fails for unlisted cToken
    function test_updateTokenConfig_fail_cTokenNotListed() public {
        // Create a config with an address that isn't listed in the market
        // but does have authority in ProtocolManager
        address unlistedToken = makeAddr("unlistedToken");

        // First add authority for this token
        address[] memory newManagedAddresses = new address[](1);
        newManagedAddresses[0] = unlistedToken;
        ProtocolManager.PeriodLimits[] memory newLimits = new ProtocolManager.PeriodLimits[](1);
        newLimits[0] = _getValidLimits();

        // Update management config to add authority for unlisted token
        protocolManager.updateManagementConfig(newManagedAddresses, newLimits, true);

        MarketManagerIsolated.TokenConfig memory config;
        config.cToken = unlistedToken;
        config.collRatio = 7000;
        config.collReqSoft = 4000;
        config.collReqHard = 3000;
        config.liqIncBase = 1000;
        config.liqIncHard = 1500;
        config.liqIncMin = 10;
        config.liqIncMax = 2000;
        config.closeFactorBase = 2000;
        config.closeFactorMin = 2000;
        config.closeFactorMax = 5000;

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config);
    }

    /// @notice Test that collRatio adjustment exceeding limit reverts
    function test_updateTokenConfig_fail_collRatioLimitExceeded() public {
        // Limit is 100, try to adjust by 101
        MarketManagerIsolated.TokenConfig memory config = _getValidTokenConfig(
            address(borrowableCWMON),
            101,  // Exceeds 100 limit
            0,
            0,
            0,
            0
        );

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config);
    }

    /// @notice Test that collReqSoft adjustment exceeding limit reverts
    function test_updateTokenConfig_fail_collReqSoftLimitExceeded() public {
        // Limit is 50, try to adjust by 51
        MarketManagerIsolated.TokenConfig memory config = _getValidTokenConfig(
            address(borrowableCWMON),
            0,
            51,  // Exceeds 50 limit
            0,
            0,
            0
        );

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config);
    }

    /// @notice Test that collReqHard adjustment exceeding limit reverts
    function test_updateTokenConfig_fail_collReqHardLimitExceeded() public {
        // Limit is 100, try to adjust by 101
        // Need to also adjust collReqSoft to keep collReqHard < collReqSoft
        MarketManagerIsolated.TokenConfig memory config = _getValidTokenConfig(
            address(borrowableCWMON),
            0,
            0,
            101,  // Exceeds 100 limit
            0,
            0
        );

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config);
    }

    /// @notice Test that collateralCap adjustment exceeding limit reverts
    function test_updateTokenConfig_fail_collateralCapLimitExceeded() public {
        // Limit is 1_000_000e18, try to adjust by more
        MarketManagerIsolated.TokenConfig memory config = _getValidTokenConfig(
            address(borrowableCWMON),
            0,
            0,
            0,
            1_000_001e18,  // Exceeds 1M limit
            0
        );

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config);
    }

    /// @notice Test that debtCap adjustment exceeding limit reverts
    function test_updateTokenConfig_fail_debtCapLimitExceeded() public {
        // Limit is 1_000_000e18, try to adjust by more
        MarketManagerIsolated.TokenConfig memory config = _getValidTokenConfig(
            address(borrowableCUSDC_MONAD),
            0,
            0,
            0,
            0,
            int256(1_000_001e18)  // Exceeds 1M limit
        );

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config);
    }

    /// @notice Test that cumulative adjustments exceeding limit reverts
    function test_updateTokenConfig_fail_cumulativeAdjustmentExceedsLimit() public {
        // First update: +60 collRatio (within 100 limit)
        MarketManagerIsolated.TokenConfig memory config1 = _getValidTokenConfig(
            address(borrowableCWMON),
            60,
            0,
            0,
            0,
            0
        );

        vm.prank(manager);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config1);

        // Second update: +50 more collRatio (total 110, exceeds 100 limit)
        MarketManagerIsolated.TokenConfig memory config2 = _getValidTokenConfig(
            address(borrowableCWMON),
            50,
            0,
            0,
            0,
            0
        );

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config2);
    }

    /// @notice Test that negative cumulative adjustment exceeding limit reverts
    function test_updateTokenConfig_fail_negativeCumulativeAdjustmentExceedsLimit() public {
        // First update: -60 collRatio (within 100 limit)
        MarketManagerIsolated.TokenConfig memory config1 = _getValidTokenConfig(
            address(borrowableCWMON),
            -60,
            0,
            0,
            0,
            0
        );

        vm.prank(manager);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config1);

        // Second update: -50 more collRatio (total -110, exceeds 100 limit)
        MarketManagerIsolated.TokenConfig memory config2 = _getValidTokenConfig(
            address(borrowableCWMON),
            -50,
            0,
            0,
            0,
            0
        );

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config2);
    }

    /// ADDITIONAL COVERAGE TESTS ///

    /// @notice Test that zero adjustment works without error
    function test_updateTokenConfig_success_zeroAdjustment() public {
        MarketManagerIsolated.TokenConfig memory config = _getValidTokenConfig(
            address(borrowableCWMON),
            0,  // No change
            0,
            0,
            0,
            0
        );

        (uint256 oldCollRatio, uint256 oldMarginSoft, uint256 oldMarginHard, uint256 oldCollCap, uint256 oldDebtCap) =
            _getCurrentConfig(address(borrowableCWMON));

        vm.prank(manager);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config);

        (uint256 newCollRatio, uint256 newMarginSoft, uint256 newMarginHard, uint256 newCollCap, uint256 newDebtCap) =
            _getCurrentConfig(address(borrowableCWMON));

        assertEq(newCollRatio, oldCollRatio, "collRatio should remain unchanged");
        assertEq(newMarginSoft, oldMarginSoft, "collReqSoft should remain unchanged");
        assertEq(newMarginHard, oldMarginHard, "collReqHard should remain unchanged");
        assertEq(newCollCap, oldCollCap, "collateralCap should remain unchanged");
        assertEq(newDebtCap, oldDebtCap, "debtCap should remain unchanged");

        // Verify period adjustment is zero
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();
        (int24 collRatioAdj,,,,,,,,,,) = protocolManager.getMarketPeriodAdjustments(
            address(borrowableCWMON),  // Query by cToken
            periodTimestamp
        );
        assertEq(collRatioAdj, 0, "adjustment should be zero");
    }

    /// @notice Test successful negative margin adjustments
    function test_updateTokenConfig_success_negativeMarginAdjustments() public {
        MarketManagerIsolated.TokenConfig memory config = _getValidTokenConfig(
            address(borrowableCWMON),
            0,
            -40,  // -40 bps collReqSoft (within 50 limit)
            -30,  // -30 bps collReqHard (within 100 limit)
            0,
            0
        );

        (, uint256 oldMarginSoft, uint256 oldMarginHard,,) = _getCurrentConfig(address(borrowableCWMON));

        vm.prank(manager);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config);

        (, uint256 newMarginSoft, uint256 newMarginHard,,) = _getCurrentConfig(address(borrowableCWMON));
        assertEq(newMarginSoft, oldMarginSoft - 40, "collReqSoft should decrease by 40");
        assertEq(newMarginHard, oldMarginHard - 30, "collReqHard should decrease by 30");

        // Verify negative adjustments tracked per-token
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();
        (,int24 collReqSoftAdj, int24 collReqHardAdj,,,,,,,,) = protocolManager.getMarketPeriodAdjustments(
            address(borrowableCWMON),  // Query by cToken
            periodTimestamp
        );
        assertEq(collReqSoftAdj, -40, "collReqSoft adjustment should be -40");
        assertEq(collReqHardAdj, -30, "collReqHard adjustment should be -30");
    }

    /// @notice Test successful collateralCap decrease
    function test_updateTokenConfig_success_collateralCapDecrease() public {
        MarketManagerIsolated.TokenConfig memory config = _getValidTokenConfig(
            address(borrowableCWMON),
            0,
            0,
            0,
            -500_000e18,  // -500k (within 1M limit)
            0
        );

        (,,, uint256 oldCollCap,) = _getCurrentConfig(address(borrowableCWMON));

        vm.prank(manager);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config);

        (,,, uint256 newCollCap,) = _getCurrentConfig(address(borrowableCWMON));
        assertEq(newCollCap, oldCollCap - 500_000e18, "collateralCap should decrease by 500k");

        // Verify negative adjustment tracked per-token
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();
        (,,,int120 collCapAdj,,,,,,,) = protocolManager.getMarketPeriodAdjustments(
            address(borrowableCWMON),  // Query by cToken
            periodTimestamp
        );
        assertEq(collCapAdj, -int120(int256(500_000e18)), "collateralCap adjustment should be -500k");
    }

    /// @notice Test successful debtCap decrease
    function test_updateTokenConfig_success_debtCapDecrease() public {
        MarketManagerIsolated.TokenConfig memory config = _getValidTokenConfig(
            address(borrowableCUSDC_MONAD),
            0,
            0,
            0,
            0,
            -500_000e6  // -500k USDC (within 1M limit)
        );

        (,,,, uint256 oldDebtCap) = _getCurrentConfig(address(borrowableCUSDC_MONAD));

        vm.prank(manager);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config);

        (,,,, uint256 newDebtCap) = _getCurrentConfig(address(borrowableCUSDC_MONAD));
        assertEq(newDebtCap, oldDebtCap - 500_000e6, "debtCap should decrease by 500k");

        // Verify negative adjustment tracked per-token
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();
        (,,,,int112 debtCapAdj,,,,,,) = protocolManager.getMarketPeriodAdjustments(
            address(borrowableCUSDC_MONAD),  // Query by cToken
            periodTimestamp
        );
        assertEq(debtCapAdj, -int112(int256(500_000e6)), "debtCap adjustment should be -500k");
    }

    /// @notice Test mixed cumulative adjustments (positive then negative)
    function test_updateTokenConfig_success_mixedCumulativeAdjustments() public {
        // First update: +60 collRatio
        MarketManagerIsolated.TokenConfig memory config1 = _getValidTokenConfig(
            address(borrowableCWMON),
            60,
            0,
            0,
            0,
            0
        );

        vm.prank(manager);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config1);

        // Second update: -30 collRatio (net +30, within 100 limit)
        MarketManagerIsolated.TokenConfig memory config2 = _getValidTokenConfig(
            address(borrowableCWMON),
            -30,
            0,
            0,
            0,
            0
        );

        vm.prank(manager);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config2);

        // Verify net adjustment is +30 (tracked per-token)
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();
        (int24 collRatioAdj,,,,,,,,,,) = protocolManager.getMarketPeriodAdjustments(
            address(borrowableCWMON),  // Query by cToken, not market
            periodTimestamp
        );
        assertEq(collRatioAdj, 30, "net collRatio adjustment should be +30");
    }

    /// @notice Test mixed adjustments that net to zero
    function test_updateTokenConfig_success_mixedAdjustmentsNetZero() public {
        // First update: +50 collRatio
        MarketManagerIsolated.TokenConfig memory config1 = _getValidTokenConfig(
            address(borrowableCWMON),
            50,
            0,
            0,
            0,
            0
        );

        vm.prank(manager);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config1);

        // Second update: -50 collRatio (net 0)
        MarketManagerIsolated.TokenConfig memory config2 = _getValidTokenConfig(
            address(borrowableCWMON),
            -50,
            0,
            0,
            0,
            0
        );

        vm.prank(manager);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config2);

        // Verify net adjustment is 0 (tracked per-token)
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();
        (int24 collRatioAdj,,,,,,,,,,) = protocolManager.getMarketPeriodAdjustments(
            address(borrowableCWMON),  // Query by cToken, not market
            periodTimestamp
        );
        assertEq(collRatioAdj, 0, "net collRatio adjustment should be 0");
    }

    /// @notice Test querying period adjustments for a period with no activity
    function test_updateTokenConfig_queryEmptyPeriod() public {
        // Query a future period that has no adjustments (query by cToken)
        uint256 futurePeriod = protocolManager.getPeriodTimestamp() + 604800; // Next week

        (
            int24 collRatioAdj,
            int24 collReqSoftAdj,
            int24 collReqHardAdj,
            int120 collCapAdj,
            int112 debtCapAdj,
            ,,,,,
        ) = protocolManager.getMarketPeriodAdjustments(
            address(borrowableCWMON),  // Query by cToken, not market
            futurePeriod
        );

        assertEq(collRatioAdj, 0, "empty period should have zero collRatio adjustment");
        assertEq(collReqSoftAdj, 0, "empty period should have zero collReqSoft adjustment");
        assertEq(collReqHardAdj, 0, "empty period should have zero collReqHard adjustment");
        assertEq(collCapAdj, 0, "empty period should have zero collateralCap adjustment");
        assertEq(debtCapAdj, 0, "empty period should have zero debtCap adjustment");
    }

    /// @notice Test that mixed adjustments can still exceed limit
    /// @dev Uses collReqSoft to avoid both MarketManager constraints and underflow
    function test_updateTokenConfig_fail_mixedAdjustmentsExceedLimit() public {
        // First update: +40 collReqSoft (within 50 limit)
        MarketManagerIsolated.TokenConfig memory config1 = _getValidTokenConfig(
            address(borrowableCWMON),
            0,
            40,
            0,
            0,
            0
        );

        vm.prank(manager);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config1);

        // Second update: -100 collReqSoft (net -60, abs value exceeds 50 limit)
        MarketManagerIsolated.TokenConfig memory config2 = _getValidTokenConfig(
            address(borrowableCWMON),
            0,
            -100,
            0,
            0,
            0
        );

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config2);
    }

    /// @notice Test adjustments at exactly the limit boundary
    /// @dev Uses collateralCap instead of collRatio to avoid MarketManager's
    ///      MIN_LIQUIDATION_BUFFER constraint on collRatio
    function test_updateTokenConfig_success_exactlyAtLimit() public {
        // Adjust by exactly 1M (the collateralCap limit)
        MarketManagerIsolated.TokenConfig memory config = _getValidTokenConfig(
            address(borrowableCWMON),
            0,
            0,
            0,
            1_000_000e18,  // Exactly at 1M limit
            0
        );

        (,,, uint256 oldCollCap,) = _getCurrentConfig(address(borrowableCWMON));

        vm.prank(manager);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config);

        (,,, uint256 newCollCap,) = _getCurrentConfig(address(borrowableCWMON));
        assertEq(newCollCap, oldCollCap + 1_000_000e18, "collateralCap should increase by exactly 1M");

        // Verify adjustment tracked per-token
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();
        (,,,int120 collCapAdj,,,,,,,) = protocolManager.getMarketPeriodAdjustments(
            address(borrowableCWMON),  // Query by cToken, not market
            periodTimestamp
        );
        assertEq(collCapAdj, int120(int256(1_000_000e18)), "adjustment should be exactly 1M");
    }

    /// @notice Test negative adjustment at exactly the limit boundary
    function test_updateTokenConfig_success_negativeExactlyAtLimit() public {
        // Adjust by exactly -100 (the limit)
        MarketManagerIsolated.TokenConfig memory config = _getValidTokenConfig(
            address(borrowableCWMON),
            -100,  // Exactly at -100 limit
            0,
            0,
            0,
            0
        );

        (uint256 oldCollRatio,,,,) = _getCurrentConfig(address(borrowableCWMON));

        vm.prank(manager);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config);

        (uint256 newCollRatio,,,,) = _getCurrentConfig(address(borrowableCWMON));
        assertEq(newCollRatio, oldCollRatio - 100, "collRatio should decrease by exactly 100");

        // Verify adjustment tracked per-token
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();
        (int24 collRatioAdj,,,,,,,,,,) = protocolManager.getMarketPeriodAdjustments(
            address(borrowableCWMON),  // Query by cToken, not market
            periodTimestamp
        );
        assertEq(collRatioAdj, -100, "adjustment should be exactly -100");
    }

    /// CROSS-TOKEN INDEPENDENCE TESTS ///

    /// @notice Test that adjustments are tracked independently per cToken
    function test_updateTokenConfig_success_crossTokenIndependence() public {
        // First update: +50 collRatio on WMON
        MarketManagerIsolated.TokenConfig memory config1 = _getValidTokenConfig(
            address(borrowableCWMON),
            50,
            0,
            0,
            0,
            0
        );

        vm.prank(manager);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config1);

        // Second update: +30 collRatio on USDC (different token, same market)
        MarketManagerIsolated.TokenConfig memory config2 = _getValidTokenConfig(
            address(borrowableCUSDC_MONAD),
            30,
            0,
            0,
            0,
            0
        );

        vm.prank(manager);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config2);

        // Verify adjustments are tracked independently per token
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();

        (int24 wmonCollRatioAdj,,,,,,,,,,) = protocolManager.getMarketPeriodAdjustments(
            address(borrowableCWMON),
            periodTimestamp
        );
        assertEq(wmonCollRatioAdj, 50, "WMON collRatio adjustment should be 50");

        (int24 usdcCollRatioAdj,,,,,,,,,,) = protocolManager.getMarketPeriodAdjustments(
            address(borrowableCUSDC_MONAD),
            periodTimestamp
        );
        assertEq(usdcCollRatioAdj, 30, "USDC collRatio adjustment should be 30");
    }

    /// @notice Test that each token can use its full limit independently
    function test_updateTokenConfig_success_crossTokenFullLimits() public {
        // First update: +100 collRatio on WMON (at limit)
        MarketManagerIsolated.TokenConfig memory config1 = _getValidTokenConfig(
            address(borrowableCWMON),
            -100,  // Use negative to avoid MarketManager constraint
            0,
            0,
            0,
            0
        );

        vm.prank(manager);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config1);

        // Second update: +100 collRatio on USDC (also at limit - independent)
        MarketManagerIsolated.TokenConfig memory config2 = _getValidTokenConfig(
            address(borrowableCUSDC_MONAD),
            -100,  // Use negative to avoid MarketManager constraint
            0,
            0,
            0,
            0
        );

        // This should succeed because tokens are tracked independently
        vm.prank(manager);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config2);

        // Verify each token used its full limit
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();

        (int24 wmonAdj,,,,,,,,,,) = protocolManager.getMarketPeriodAdjustments(
            address(borrowableCWMON),
            periodTimestamp
        );
        assertEq(wmonAdj, -100, "WMON should use full -100 limit");

        (int24 usdcAdj,,,,,,,,,,) = protocolManager.getMarketPeriodAdjustments(
            address(borrowableCUSDC_MONAD),
            periodTimestamp
        );
        assertEq(usdcAdj, -100, "USDC should also use full -100 limit independently");
    }

    /// @notice Test that multiple parameters are tracked independently per token
    function test_updateTokenConfig_success_crossTokenMultipleParamsIndependent() public {
        // First update on WMON: +30 collRatio, +20 collReqSoft, +300k collateralCap
        MarketManagerIsolated.TokenConfig memory config1 = _getValidTokenConfig(
            address(borrowableCWMON),
            30,
            20,
            0,
            300_000e18,
            0
        );

        vm.prank(manager);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config1);

        // Second update on USDC: +20 collRatio, +15 collReqSoft, +200k collateralCap
        MarketManagerIsolated.TokenConfig memory config2 = _getValidTokenConfig(
            address(borrowableCUSDC_MONAD),
            20,
            15,
            0,
            200_000e18,
            0
        );

        vm.prank(manager);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config2);

        // Verify adjustments are tracked independently per token
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();

        // Check WMON adjustments
        (
            int24 wmonCollRatio,
            int24 wmonMarginSoft,
            ,
            int120 wmonCollCap,
            ,,,,,,
        ) = protocolManager.getMarketPeriodAdjustments(
            address(borrowableCWMON),
            periodTimestamp
        );
        assertEq(wmonCollRatio, 30, "WMON collRatio should be 30");
        assertEq(wmonMarginSoft, 20, "WMON collReqSoft should be 20");
        assertEq(wmonCollCap, int120(int256(300_000e18)), "WMON collateralCap should be 300k");

        // Check USDC adjustments
        (
            int24 usdcCollRatio,
            int24 usdcMarginSoft,
            ,
            int120 usdcCollCap,
            ,,,,,,
        ) = protocolManager.getMarketPeriodAdjustments(
            address(borrowableCUSDC_MONAD),
            periodTimestamp
        );
        assertEq(usdcCollRatio, 20, "USDC collRatio should be 20");
        assertEq(usdcMarginSoft, 15, "USDC collReqSoft should be 15");
        assertEq(usdcCollCap, int120(int256(200_000e18)), "USDC collateralCap should be 200k");
    }

    /// @notice Test that updating one token doesn't affect another's adjustments
    function test_updateTokenConfig_success_tokenUpdateNoSideEffect() public {
        // First update on WMON
        MarketManagerIsolated.TokenConfig memory config1 = _getValidTokenConfig(
            address(borrowableCWMON),
            50,
            25,
            0,
            100_000e18,
            0
        );

        vm.prank(manager);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config1);

        // Verify WMON has adjustments
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();
        (int24 wmonAdjBefore,,,,,,,,,,) = protocolManager.getMarketPeriodAdjustments(
            address(borrowableCWMON),
            periodTimestamp
        );
        assertEq(wmonAdjBefore, 50, "WMON should have adjustment");

        // Now update USDC with positive adjustments
        MarketManagerIsolated.TokenConfig memory config2 = _getValidTokenConfig(
            address(borrowableCUSDC_MONAD),
            -30,
            -10,
            0,
            50_000e18,  // Use positive cap change to avoid underflow
            0
        );

        vm.prank(manager);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config2);

        // Verify WMON adjustments are unchanged
        (int24 wmonAdjAfter,,,,,,,,,,) = protocolManager.getMarketPeriodAdjustments(
            address(borrowableCWMON),
            periodTimestamp
        );
        assertEq(wmonAdjAfter, 50, "WMON adjustment should be unchanged after USDC update");

        // Verify USDC has its own independent adjustments
        (int24 usdcAdj,,,,,,,,,,) = protocolManager.getMarketPeriodAdjustments(
            address(borrowableCUSDC_MONAD),
            periodTimestamp
        );
        assertEq(usdcAdj, -30, "USDC should have its own adjustment");
    }

    /// @notice Test that same token cumulative updates still work correctly
    function test_updateTokenConfig_success_sameTokenCumulativeWithOtherToken() public {
        // First update on WMON: +30
        MarketManagerIsolated.TokenConfig memory config1 = _getValidTokenConfig(
            address(borrowableCWMON),
            30,
            0,
            0,
            0,
            0
        );

        vm.prank(manager);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config1);

        // Update USDC: +50
        MarketManagerIsolated.TokenConfig memory config2 = _getValidTokenConfig(
            address(borrowableCUSDC_MONAD),
            50,
            0,
            0,
            0,
            0
        );

        vm.prank(manager);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config2);

        // Second update on WMON: +40 (cumulative = 70)
        MarketManagerIsolated.TokenConfig memory config3 = _getValidTokenConfig(
            address(borrowableCWMON),
            40,
            0,
            0,
            0,
            0
        );

        vm.prank(manager);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config3);

        // Verify WMON has cumulative adjustment
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();
        (int24 wmonAdj,,,,,,,,,,) = protocolManager.getMarketPeriodAdjustments(
            address(borrowableCWMON),
            periodTimestamp
        );
        assertEq(wmonAdj, 70, "WMON cumulative adjustment should be 30 + 40 = 70");

        // Verify USDC is unaffected
        (int24 usdcAdj,,,,,,,,,,) = protocolManager.getMarketPeriodAdjustments(
            address(borrowableCUSDC_MONAD),
            periodTimestamp
        );
        assertEq(usdcAdj, 50, "USDC adjustment should remain 50");
    }

    /// @notice Test that each token's limit is enforced independently
    function test_updateTokenConfig_fail_singleTokenLimitEnforced() public {
        // Max out WMON adjustment at limit
        MarketManagerIsolated.TokenConfig memory config1 = _getValidTokenConfig(
            address(borrowableCWMON),
            -100,  // At limit
            0,
            0,
            0,
            0
        );

        vm.prank(manager);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config1);

        // Try to exceed WMON limit (should fail even though USDC has room)
        MarketManagerIsolated.TokenConfig memory config2 = _getValidTokenConfig(
            address(borrowableCWMON),
            -10,  // Would make cumulative -110
            0,
            0,
            0,
            0
        );

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config2);

        // But USDC can still be updated independently
        MarketManagerIsolated.TokenConfig memory config3 = _getValidTokenConfig(
            address(borrowableCUSDC_MONAD),
            -50,
            0,
            0,
            0,
            0
        );

        vm.prank(manager);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), config3);

        // Verify USDC was updated
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();
        (int24 usdcAdj,,,,,,,,,,) = protocolManager.getMarketPeriodAdjustments(
            address(borrowableCUSDC_MONAD),
            periodTimestamp
        );
        assertEq(usdcAdj, -50, "USDC should be updated independently of WMON limit");
    }

}
