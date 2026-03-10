// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IERC165 } from "contracts/interfaces/IERC165.sol";
import { IPluginDelegable } from "contracts/interfaces/IPluginDelegable.sol";
import { ERC4626 } from "contracts/libraries/external/ERC4626.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { WAD, BPS } from "contracts/libraries/ConstantsLib.sol";

contract TestLendingOptimizerUpdateCap is TestBaseLendingOptimizer {

    event AllocationCapUpdated(address indexed cToken, uint256 newCap);

    function setUp() public override {
        super.setUp();
    }

    // ==================== SUCCESS CASES ====================

    function test_lendingOptimizer_updateCap_success_increaseCap() public {
        // Setup with two markets (60% + 50% = 110% total caps).
        _setUpTwoMarkets();

        // Verify initial cap.
        assertEq(optimizer.allocationCaps(cUSDC_WMON_MARKET), 6_000 * 1e14, "Initial cap should be 60%");

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Increase cap from 60% to 80%.
        optimizer.updateCap(cUSDC_WMON_MARKET, 8_000);

        // Verify cap was updated.
        assertEq(optimizer.allocationCaps(cUSDC_WMON_MARKET), 8_000 * 1e14, "Cap should be updated to 80%");
    }

    function test_lendingOptimizer_updateCap_success_decreaseCap() public {
        // Setup with two markets (60% + 50% = 110% total caps).
        _setUpTwoMarkets();

        // Verify initial cap.
        assertEq(optimizer.allocationCaps(cUSDC_WBTC_MARKET), 5_000 * 1e14, "Initial cap should be 50%");

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Decrease cap from 50% to 40% (total would be 60% + 40% = 100%, still valid).
        optimizer.updateCap(cUSDC_WBTC_MARKET, 4_000);

        // Verify cap was updated.
        assertEq(optimizer.allocationCaps(cUSDC_WBTC_MARKET), 4_000 * 1e14, "Cap should be updated to 40%");
    }

    function test_lendingOptimizer_updateCap_success_decreaseCapToMinimumValid() public {
        // Setup with three markets (60% + 50% + 20% = 130% total caps).
        _setUpThreeMarkets();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Decrease 60% cap to 30% (total would be 30% + 50% + 20% = 100%, exactly valid).
        optimizer.updateCap(cUSDC_WMON_MARKET, 3_000);

        // Verify cap was updated.
        assertEq(optimizer.allocationCaps(cUSDC_WMON_MARKET), 3_000 * 1e14, "Cap should be updated to 30%");
    }

    function test_lendingOptimizer_updateCap_success_toMaxCap() public {
        // Setup with one market.
        _setUpOneMarket();

        // Verify initial cap (100% since it's the only market).
        assertEq(optimizer.allocationCaps(cUSDC_WMON_MARKET), WAD, "Initial cap should be 100%");

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Update to exactly 100% (should succeed since it's max allowed).
        optimizer.updateCap(cUSDC_WMON_MARKET, 10_000);

        // Verify cap remains at 100%.
        assertEq(optimizer.allocationCaps(cUSDC_WMON_MARKET), WAD, "Cap should remain at 100%");
    }

    function test_lendingOptimizer_updateCap_success_toMinimumCap() public {
        // Setup with one market.
        _setUpOneMarket();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Update to 1 BPS (0.01%), minimum valid cap.
        // This will fail validation since total caps would be < 100%,
        // but let's first add another market with high cap.
        optimizer.addApprovedAsset(cUSDC_WBTC_MARKET, 10_000);

        // Now update first market to minimum cap (1 BPS = 0.01%).
        optimizer.updateCap(cUSDC_WMON_MARKET, 1);

        // Verify cap was updated.
        assertEq(optimizer.allocationCaps(cUSDC_WMON_MARKET), 1 * 1e14, "Cap should be updated to 0.01%");
    }

    function test_lendingOptimizer_updateCap_success_emitsEvent() public {
        // Setup with one market.
        _setUpOneMarket();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Update cap from 100% to 80%.
        // First add another market to ensure total caps >= 100% after decrease.
        optimizer.addApprovedAsset(cUSDC_WBTC_MARKET, 5_000);

        // Expect event to be emitted.
        vm.expectEmit(true, false, false, true);
        emit AllocationCapUpdated(cUSDC_WMON_MARKET, 8_000 * 1e14);

        // Now update the first market's cap.
        optimizer.updateCap(cUSDC_WMON_MARKET, 8_000);
    }

    function test_lendingOptimizer_updateCap_success_multipleUpdates() public {
        // Setup with three markets (60% + 50% + 20% = 130% total caps).
        _setUpThreeMarkets();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Update first market: 60% -> 40% (total: 40% + 50% + 20% = 110%).
        optimizer.updateCap(cUSDC_WMON_MARKET, 4_000);
        assertEq(optimizer.allocationCaps(cUSDC_WMON_MARKET), 4_000 * 1e14, "First update should set to 40%");

        // Update second market: 50% -> 35% (total: 40% + 35% + 20% = 95% < 100%).
        // This should revert.
        vm.expectRevert(LendingOptimizer.LendingOptimizer__InsufficientAllocationCaps.selector);
        optimizer.updateCap(cUSDC_WBTC_MARKET, 3_500);

        // Update second market: 50% -> 40% (total: 40% + 40% + 20% = 100%).
        optimizer.updateCap(cUSDC_WBTC_MARKET, 4_000);
        assertEq(optimizer.allocationCaps(cUSDC_WBTC_MARKET), 4_000 * 1e14, "Second update should set to 40%");

        // Update third market: 20% -> 30% (total: 40% + 40% + 30% = 110%).
        optimizer.updateCap(cUSDC_WETH_MARKET, 3_000);
        assertEq(optimizer.allocationCaps(cUSDC_WETH_MARKET), 3_000 * 1e14, "Third update should set to 30%");
    }

    function test_lendingOptimizer_updateCap_success_increaseDoesNotValidate() public {
        // Setup with three markets (60% + 50% + 20% = 130% total caps).
        _setUpThreeMarkets();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // First decrease to exactly 100% (60% + 30% + 10% = 100%).
        optimizer.updateCap(cUSDC_WBTC_MARKET, 3_000);
        optimizer.updateCap(cUSDC_WETH_MARKET, 1_000);

        // Verify total is exactly 100%.
        uint256 totalCaps = optimizer.allocationCaps(cUSDC_WMON_MARKET) +
                           optimizer.allocationCaps(cUSDC_WBTC_MARKET) +
                           optimizer.allocationCaps(cUSDC_WETH_MARKET);
        assertEq(totalCaps, WAD, "Total caps should be exactly 100%");

        // Increasing any cap should succeed without validation issues.
        optimizer.updateCap(cUSDC_WETH_MARKET, 5_000);
        assertEq(optimizer.allocationCaps(cUSDC_WETH_MARKET), 5_000 * 1e14, "Increase should succeed");
    }

    // ==================== FAILURE CASES ====================

    function test_lendingOptimizer_updateCap_fail_whenUnauthorized() public {
        // Setup with one market.
        _setUpOneMarket();

        // Mock market permissions to return false.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(false)
        );

        vm.expectRevert(LendingOptimizer.LendingOptimizer__Unauthorized.selector);
        optimizer.updateCap(cUSDC_WMON_MARKET, 8_000);
    }

    function test_lendingOptimizer_updateCap_fail_whenMarketNotApproved() public {
        // Setup with one market.
        _setUpOneMarket();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Try to update cap of a non-approved market.
        vm.expectRevert(LendingOptimizer.LendingOptimizer__MarketNotApproved.selector);
        optimizer.updateCap(cUSDC_WBTC_MARKET, 5_000);
    }

    function test_lendingOptimizer_updateCap_fail_whenCapIsZero() public {
        // Setup with one market.
        _setUpOneMarket();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Try to update cap to 0.
        vm.expectRevert(LendingOptimizer.LendingOptimizer__InvalidParameter.selector);
        optimizer.updateCap(cUSDC_WMON_MARKET, 0);
    }

    function test_lendingOptimizer_updateCap_fail_whenCapExceeds100Percent() public {
        // Setup with one market.
        _setUpOneMarket();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Try to update cap to > 10_000 BPS (> 100%).
        vm.expectRevert(LendingOptimizer.LendingOptimizer__InvalidParameter.selector);
        optimizer.updateCap(cUSDC_WMON_MARKET, 10_001);
    }

    function test_lendingOptimizer_updateCap_fail_whenCapFarExceeds100Percent() public {
        // Setup with one market.
        _setUpOneMarket();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Try to update cap to a very large value.
        vm.expectRevert(LendingOptimizer.LendingOptimizer__InvalidParameter.selector);
        optimizer.updateCap(cUSDC_WMON_MARKET, type(uint256).max);
    }

    function test_lendingOptimizer_updateCap_fail_whenDecreaseBreaksTotalCaps() public {
        // Setup with two markets (60% + 50% = 110% total caps).
        _setUpTwoMarkets();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Try to decrease 60% cap to 40% (total would be 40% + 50% = 90% < 100%).
        vm.expectRevert(LendingOptimizer.LendingOptimizer__InsufficientAllocationCaps.selector);
        optimizer.updateCap(cUSDC_WMON_MARKET, 4_000);
    }

    function test_lendingOptimizer_updateCap_fail_whenDecreaseBreaksTotalCaps_singleMarket() public {
        // Setup with one market at 100%.
        _setUpOneMarket();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Try to decrease 100% cap to 99% (total would be 99% < 100%).
        vm.expectRevert(LendingOptimizer.LendingOptimizer__InsufficientAllocationCaps.selector);
        optimizer.updateCap(cUSDC_WMON_MARKET, 9_999);
    }

    function test_lendingOptimizer_updateCap_fail_whenDecreaseBreaksTotalCaps_threeMarkets() public {
        // Setup with three markets (60% + 50% + 20% = 130% total caps).
        _setUpThreeMarkets();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Try to decrease 60% cap to 20% (total would be 20% + 50% + 20% = 90% < 100%).
        vm.expectRevert(LendingOptimizer.LendingOptimizer__InsufficientAllocationCaps.selector);
        optimizer.updateCap(cUSDC_WMON_MARKET, 2_000);
    }

    function test_lendingOptimizer_updateCap_fail_whenZeroAddress() public {
        // Setup with one market.
        _setUpOneMarket();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Try to update cap for zero address (will fail with MarketNotApproved since it's not approved).
        vm.expectRevert(LendingOptimizer.LendingOptimizer__MarketNotApproved.selector);
        optimizer.updateCap(address(0), 5_000);
    }

    // ==================== EDGE CASES ====================

    function test_lendingOptimizer_updateCap_success_sameCap() public {
        // Setup with one market at 100%.
        _setUpOneMarket();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Update to the same cap value (100%).
        uint256 capBefore = optimizer.allocationCaps(cUSDC_WMON_MARKET);
        optimizer.updateCap(cUSDC_WMON_MARKET, 10_000);
        uint256 capAfter = optimizer.allocationCaps(cUSDC_WMON_MARKET);

        assertEq(capBefore, capAfter, "Cap should remain the same");
        assertEq(capAfter, WAD, "Cap should be 100%");
    }

    function test_lendingOptimizer_updateCap_success_boundaryExactly100Percent() public {
        // Setup with two markets (60% + 50% = 110% total caps).
        _setUpTwoMarkets();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Decrease 60% cap to 50% (total would be 50% + 50% = 100%, exactly valid).
        optimizer.updateCap(cUSDC_WMON_MARKET, 5_000);

        // Verify total is exactly 100%.
        uint256 totalCaps = optimizer.allocationCaps(cUSDC_WMON_MARKET) +
                           optimizer.allocationCaps(cUSDC_WBTC_MARKET);
        assertEq(totalCaps, WAD, "Total caps should be exactly 100%");
    }

    function test_lendingOptimizer_updateCap_fail_boundaryJustBelow100Percent() public {
        // Setup with two markets (60% + 50% = 110% total caps).
        _setUpTwoMarkets();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Try to decrease 60% cap to 49.99% (4999 BPS).
        // Total would be 49.99% + 50% = 99.99% < 100%.
        vm.expectRevert(LendingOptimizer.LendingOptimizer__InsufficientAllocationCaps.selector);
        optimizer.updateCap(cUSDC_WMON_MARKET, 4_999);
    }

    function test_lendingOptimizer_updateCap_success_withDeposits() public {
        // Setup with two markets.
        _setUpTwoMarkets();

        // Deposit some assets.
        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        optimizer.deposit(10_000e6, address(this));

        // Record state before update.
        uint256 totalAssetsBefore = optimizer.totalAssets();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Update cap (increase).
        optimizer.updateCap(cUSDC_WMON_MARKET, 8_000);

        // Verify cap was updated.
        assertEq(optimizer.allocationCaps(cUSDC_WMON_MARKET), 8_000 * 1e14, "Cap should be updated to 80%");

        // Verify total assets are unchanged.
        uint256 totalAssetsAfter = optimizer.totalAssets();
        assertApproxEqAbs(totalAssetsAfter, totalAssetsBefore, 1, "Total assets should be unchanged");
    }

    function test_lendingOptimizer_updateCap_success_afterYieldAccrual() public {
        // Setup with two markets.
        _setUpTwoMarkets();

        // Deposit some assets.
        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        optimizer.deposit(10_000e6, address(this));

        // Skip forward to simulate yield accrual.
        skip(30 days);

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Update cap should still work after yield accrual.
        optimizer.updateCap(cUSDC_WMON_MARKET, 7_000);
        assertEq(optimizer.allocationCaps(cUSDC_WMON_MARKET), 7_000 * 1e14, "Cap should be updated to 70%");
    }

    // ==================== FUZZ TESTS ====================

    function testFuzz_lendingOptimizer_updateCap_increaseCap(uint256 newCapBps) public {
        // Setup with two markets (60% + 50% = 110% total caps).
        _setUpTwoMarkets();

        // Bound newCapBps to valid range for increase (current cap is 60%, so 6001-10000).
        newCapBps = bound(newCapBps, 6_001, 10_000);

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Update cap.
        optimizer.updateCap(cUSDC_WMON_MARKET, newCapBps);

        // Verify cap was updated.
        assertEq(optimizer.allocationCaps(cUSDC_WMON_MARKET), newCapBps * 1e14, "Cap should be updated");
    }

    function testFuzz_lendingOptimizer_updateCap_decreaseCap(uint256 newCapBps) public {
        // Setup with two markets (60% + 50% = 110% total caps).
        _setUpTwoMarkets();

        // Bound newCapBps to valid range for decrease while maintaining >= 100% total.
        // Current: 60% + 50% = 110%. Min for first market: 100% - 50% = 50% = 5000 BPS.
        newCapBps = bound(newCapBps, 5_000, 5_999);

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Update cap.
        optimizer.updateCap(cUSDC_WMON_MARKET, newCapBps);

        // Verify cap was updated.
        assertEq(optimizer.allocationCaps(cUSDC_WMON_MARKET), newCapBps * 1e14, "Cap should be updated");

        // Verify total caps still >= 100%.
        uint256 totalCaps = optimizer.allocationCaps(cUSDC_WMON_MARKET) +
                           optimizer.allocationCaps(cUSDC_WBTC_MARKET);
        assertGe(totalCaps, WAD, "Total caps should be >= 100%");
    }

    function testFuzz_lendingOptimizer_updateCap_fail_invalidCap(uint256 newCapBps) public {
        // Setup with one market.
        _setUpOneMarket();

        // Bound to invalid range (0 or > 10000).
        vm.assume(newCapBps == 0 || newCapBps > 10_000);

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Update cap should fail.
        vm.expectRevert(LendingOptimizer.LendingOptimizer__InvalidParameter.selector);
        optimizer.updateCap(cUSDC_WMON_MARKET, newCapBps);
    }
}
