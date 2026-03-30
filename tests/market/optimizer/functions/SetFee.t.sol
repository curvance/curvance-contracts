// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { WAD, BPS } from "contracts/libraries/ConstantsLib.sol";

contract TestLendingOptimizerSetFee is TestBaseLendingOptimizer {

    event FeeUpdated(uint256 newFee);

    uint256 constant MAX_FEE_BPS = 5000;

    function setUp() public override {
        super.setUp();
    }

    // ==================== SUCCESS CASES ====================

    function test_lendingOptimizer_setFee_success_setNewFee() public {
        // Setup with one market and 10% fee.
        _setUpOneMarket();

        // Verify initial fee (10% = 1000 BPS = 0.1 WAD).
        assertEq(optimizer.fee(), 1_000, "Initial fee should be 10%");

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Set new fee to 20%.
        optimizer.setFee(2_000);

        // Verify fee was updated.
        assertEq(optimizer.fee(), 2_000, "Fee should be updated to 20%");
    }

    function test_lendingOptimizer_setFee_success_setToMaxFee() public {
        // Setup with one market.
        _setUpOneMarket();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Set fee to maximum (50%).
        optimizer.setFee(MAX_FEE_BPS);

        // Verify fee was updated to max.
        assertEq(optimizer.fee(), MAX_FEE_BPS, "Fee should be updated to 50%");
    }

    function test_lendingOptimizer_setFee_success_setToZero() public {
        // Setup with one market.
        _setUpOneMarket();

        // Verify initial fee is non-zero.
        assertGt(optimizer.fee(), 0, "Initial fee should be non-zero");

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Set fee to 0.
        optimizer.setFee(0);

        // Verify fee was updated to 0.
        assertEq(optimizer.fee(), 0, "Fee should be updated to 0");
    }

    function test_lendingOptimizer_setFee_success_emitsEvent() public {
        // Setup with one market.
        _setUpOneMarket();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Expect event to be emitted.
        vm.expectEmit(false, false, false, true);
        emit FeeUpdated(2_500);

        // Set fee to 25%.
        optimizer.setFee(2_500);
    }

    function test_lendingOptimizer_setFee_success_increaseFee() public {
        // Setup with one market (10% initial fee).
        _setUpOneMarket();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Increase fee from 10% to 30%.
        optimizer.setFee(3_000);
        assertEq(optimizer.fee(), 3_000, "Fee should be 30%");
    }

    function test_lendingOptimizer_setFee_success_decreaseFee() public {
        // Setup with one market (10% initial fee).
        _setUpOneMarket();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Decrease fee from 10% to 5%.
        optimizer.setFee(500);
        assertEq(optimizer.fee(), 500, "Fee should be 5%");
    }

    function test_lendingOptimizer_setFee_success_enableFromZero_updatesWatermark() public {
        // Setup with one market.
        _setUpOneMarket();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // First set fee to 0.
        optimizer.setFee(0);
        assertEq(optimizer.fee(), 0, "Fee should be 0");

        // Deposit some assets.
        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        optimizer.deposit(10_000e6, address(this));

        // Skip forward to simulate yield accrual in underlying markets.
        skip(30 days);

        // First accrueIfNeeded detects yield and starts vesting.
        optimizer.accrueIfNeeded();

        // Skip vesting period to let yield vest into _totalAssets.
        skip(1 days);

        // Second accrueIfNeeded vests the yield.
        optimizer.accrueIfNeeded();

        // Record watermark before enabling fees.
        uint256 watermarkBefore = optimizer.exchangeRateHighWatermark();

        // Enable fees from 0 - should update watermark to current rate.
        optimizer.setFee(1_000);

        // Verify watermark was updated.
        uint256 watermarkAfter = optimizer.exchangeRateHighWatermark();
        assertGe(watermarkAfter, watermarkBefore, "Watermark should be updated when enabling fees from 0");
    }

    function test_lendingOptimizer_setFee_success_noWatermarkUpdateWhenNotFromZero() public {
        // Setup with one market (10% initial fee).
        _setUpOneMarket();

        // Deposit some assets.
        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        optimizer.deposit(10_000e6, address(this));

        // Skip forward to simulate yield.
        skip(30 days);

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Force accrual to get current watermark using exchangeRateUpdated()
        // since exchangeRate() is now a simple view that reads cached state.
        optimizer.exchangeRateUpdated();
        uint256 watermarkBefore = optimizer.exchangeRateHighWatermark();

        // Change fee (not from 0) - watermark should not be reset.
        // setFee calls _accrueIfNeeded internally, but since we just accrued
        // in the same block, no new yield should be detected.
        optimizer.setFee(2_000);

        uint256 watermarkAfter = optimizer.exchangeRateHighWatermark();
        assertEq(watermarkAfter, watermarkBefore, "Watermark should not change when not enabling from 0");
    }

    function test_lendingOptimizer_setFee_success_multipleUpdates() public {
        // Setup with one market.
        _setUpOneMarket();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Multiple fee updates.
        optimizer.setFee(500);
        assertEq(optimizer.fee(), 500, "Fee should be 5%");

        optimizer.setFee(2_500);
        assertEq(optimizer.fee(), 2_500, "Fee should be 25%");

        optimizer.setFee(MAX_FEE_BPS);
        assertEq(optimizer.fee(), MAX_FEE_BPS, "Fee should be 50%");

        optimizer.setFee(0);
        assertEq(optimizer.fee(), 0, "Fee should be 0");
    }

    function test_lendingOptimizer_setFee_success_sameFee() public {
        // Setup with one market (10% initial fee).
        _setUpOneMarket();

        uint256 initialFee = optimizer.fee();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Set fee to same value.
        optimizer.setFee(1_000);

        // Verify fee unchanged.
        assertEq(optimizer.fee(), initialFee, "Fee should remain the same");
    }

    function test_lendingOptimizer_setFee_success_withDeposits() public {
        // Setup with one market.
        _setUpOneMarket();

        // Deposit some assets.
        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        optimizer.deposit(10_000e6, address(this));

        uint256 totalAssetsBefore = optimizer.totalAssets();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Set fee.
        optimizer.setFee(2_000);

        // Total assets should be unchanged by fee update.
        uint256 totalAssetsAfter = optimizer.totalAssets();
        assertApproxEqAbs(totalAssetsAfter, totalAssetsBefore, 1, "Total assets should be unchanged");
    }

    function test_lendingOptimizer_setFee_success_afterYieldAccrual() public {
        // Setup with one market.
        _setUpOneMarket();

        // Deposit some assets.
        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        optimizer.deposit(10_000e6, address(this));

        // Skip forward to simulate yield.
        skip(30 days);

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Set fee after yield has accrued - should work and accrue first.
        optimizer.setFee(3_000);
        assertEq(optimizer.fee(), 3_000, "Fee should be 30%");
    }

    function test_lendingOptimizer_setFee_success_minimumNonZeroFee() public {
        // Setup with one market.
        _setUpOneMarket();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Set minimum non-zero fee (1 BPS = 0.01%).
        optimizer.setFee(1);

        assertEq(optimizer.fee(), 1, "Fee should be 0.01%");
    }

    // ==================== FAILURE CASES ====================

    function test_lendingOptimizer_setFee_fail_whenUnauthorized() public {
        // Setup with one market.
        _setUpOneMarket();

        // Mock market permissions to return false.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(false)
        );

        vm.expectRevert(LendingOptimizer.LendingOptimizer__Unauthorized.selector);
        optimizer.setFee(2_000);
    }

    function test_lendingOptimizer_setFee_fail_whenExceedsMaxFee() public {
        // Setup with one market.
        _setUpOneMarket();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Try to set fee above MAX_FEE_BPS (50%).
        vm.expectRevert(LendingOptimizer.LendingOptimizer__FeeTooHigh.selector);
        optimizer.setFee(MAX_FEE_BPS + 1);
    }

    function test_lendingOptimizer_setFee_fail_whenFarExceedsMaxFee() public {
        // Setup with one market.
        _setUpOneMarket();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Try to set fee to 100%.
        vm.expectRevert(LendingOptimizer.LendingOptimizer__FeeTooHigh.selector);
        optimizer.setFee(10_000);
    }

    function test_lendingOptimizer_setFee_fail_whenVeryLargeValue() public {
        // Setup with one market.
        _setUpOneMarket();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Try to set fee to max uint256.
        vm.expectRevert(LendingOptimizer.LendingOptimizer__FeeTooHigh.selector);
        optimizer.setFee(type(uint256).max);
    }

    // ==================== EDGE CASES ====================

    function test_lendingOptimizer_setFee_success_boundaryAtMaxFee() public {
        // Setup with one market.
        _setUpOneMarket();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Set fee to exactly MAX_FEE_BPS - should succeed.
        optimizer.setFee(MAX_FEE_BPS);
        assertEq(optimizer.fee(), MAX_FEE_BPS, "Fee should be exactly 50%");
    }

    function test_lendingOptimizer_setFee_fail_boundaryJustAboveMaxFee() public {
        // Setup with one market.
        _setUpOneMarket();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Set fee to MAX_FEE_BPS + 1 - should fail.
        vm.expectRevert(LendingOptimizer.LendingOptimizer__FeeTooHigh.selector);
        optimizer.setFee(MAX_FEE_BPS + 1);
    }

    function test_lendingOptimizer_setFee_success_enableFromZero_noSupply() public {
        // Setup with one market.
        _setUpOneMarket();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Set fee to 0 first.
        optimizer.setFee(0);

        // Note: initializeDeposits was called in setup, so there is supply.
        // But enabling from 0 should still work.
        optimizer.setFee(1_000);
        assertEq(optimizer.fee(), 1_000, "Fee should be 10%");
    }

    function test_lendingOptimizer_setFee_success_zeroToZero() public {
        // Setup with one market.
        _setUpOneMarket();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Set fee to 0.
        optimizer.setFee(0);
        assertEq(optimizer.fee(), 0, "Fee should be 0");

        // Set fee to 0 again - should succeed.
        optimizer.setFee(0);
        assertEq(optimizer.fee(), 0, "Fee should still be 0");
    }

    // ==================== FUZZ TESTS ====================

    function testFuzz_lendingOptimizer_setFee_validFee(uint256 newFeeBps) public {
        // Setup with one market.
        _setUpOneMarket();

        // Bound to valid range [0, MAX_FEE_BPS].
        newFeeBps = bound(newFeeBps, 0, MAX_FEE_BPS);

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Set fee.
        optimizer.setFee(newFeeBps);

        // Verify fee was updated.
        assertEq(optimizer.fee(), newFeeBps, "Fee should be updated");
    }

    function testFuzz_lendingOptimizer_setFee_fail_invalidFee(uint256 newFeeBps) public {
        // Setup with one market.
        _setUpOneMarket();

        // Bound to invalid range (> MAX_FEE_BPS).
        vm.assume(newFeeBps > MAX_FEE_BPS);

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Set fee should fail.
        vm.expectRevert(LendingOptimizer.LendingOptimizer__FeeTooHigh.selector);
        optimizer.setFee(newFeeBps);
    }

    function testFuzz_lendingOptimizer_setFee_multipleChanges(uint256 fee1, uint256 fee2, uint256 fee3) public {
        // Setup with one market.
        _setUpOneMarket();

        // Bound to valid range.
        fee1 = bound(fee1, 0, MAX_FEE_BPS);
        fee2 = bound(fee2, 0, MAX_FEE_BPS);
        fee3 = bound(fee3, 0, MAX_FEE_BPS);

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Multiple fee changes.
        optimizer.setFee(fee1);
        assertEq(optimizer.fee(), fee1, "First fee update");

        optimizer.setFee(fee2);
        assertEq(optimizer.fee(), fee2, "Second fee update");

        optimizer.setFee(fee3);
        assertEq(optimizer.fee(), fee3, "Third fee update");
    }
}
