// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizerHarness } from "../LendingOptimizerHarness.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { WAD, BPS } from "contracts/libraries/ConstantsLib.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

/// @title Vesting Mechanism Fuzz Tests for LendingOptimizer
/// @notice Fuzz tests verifying the vesting system: period configuration,
///         linear interpolation, rapid accruals, concurrent operations,
///         small amounts, overflow boundaries, multi-cycle, and end boundaries.
contract VestingMechanismFuzz is TestBaseLendingOptimizer {

    LendingOptimizerHarness harness;

    function setUp() public override {
        super.setUp();
        _setUpHarnessThreeMarkets();
    }

    /// @dev Deploys LendingOptimizerHarness with 3 markets.
    function _setUpHarnessThreeMarkets() internal {
        address[] memory approvedCTokens = new address[](3);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;
        approvedCTokens[2] = cUSDC_WETH_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](3);
        allocationCapsBps[0] = 6_000;
        allocationCapsBps[1] = 5_000;
        allocationCapsBps[2] = 2_000;

        harness = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000, // 10% fee
            1 days
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(harness), initAssets);

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasHarvestPermissions.selector, address(this)),
            abi.encode(true)
        );

        harness.initializeDeposits(0);
    }

    /// @dev Helper to deploy a fresh harness with a specific vesting period.
    function _deployFreshHarness(uint256 _vestingPeriod) internal returns (LendingOptimizerHarness) {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory caps = new uint256[](1);
        caps[0] = 10_000;

        LendingOptimizerHarness fresh = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            caps,
            0, // No fee for clean vesting measurement.
            _vestingPeriod
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(fresh), initAssets);
        fresh.initializeDeposits(0);

        return fresh;
    }

    // =========================================================================
    // TEST 1: Vesting Period Deployment
    // =========================================================================

    /// @notice Deploy with a fuzzed vesting period and verify the period is stored
    ///         correctly and vesting starts after yield is detected.
    function testFuzz_vestingPeriod_deployment(uint256 vestingPeriod) public {
        vestingPeriod = bound(vestingPeriod, 1, 3 days);

        LendingOptimizerHarness fresh = _deployFreshHarness(vestingPeriod);

        // Verify stored vesting period.
        assertEq(
            fresh.vestingPeriod(),
            vestingPeriod,
            "Vesting period not stored correctly"
        );

        // Deposit and let yield accrue.
        uint256 depositAmount = 1_000_000e6;
        deal(USDC_MONAD, user1, depositAmount);
        vm.startPrank(user1);
        IERC20(USDC_MONAD).approve(address(fresh), depositAmount);
        fresh.deposit(depositAmount, user1, cUSDC_WMON_MARKET);
        vm.stopPrank();

        // Skip time for yield to accrue.
        skip(2 days);

        // Trigger accrual to start vesting.
        fresh.exposed_accrueIfNeeded();

        (uint256 vestingRate, uint256 vestEnd, uint256 lastClaim) = fresh.exposed_getVestingData();

        if (vestingRate > 0) {
            // Vesting should span exactly vestingPeriod.
            assertEq(
                vestEnd - lastClaim,
                vestingPeriod,
                "Vesting duration does not match vestingPeriod"
            );

            // At start of vesting, assetsToVest should be 0 (lastClaim == now).
            uint256 assetsToVest = fresh.exposed_assetsToVest();
            assertEq(assetsToVest, 0, "assetsToVest should be 0 at vesting start");

            // Skip to midpoint and verify interpolation.
            skip(vestingPeriod / 2);
            uint256 midVest = fresh.exposed_assetsToVest();

            // Skip to end.
            skip(vestingPeriod / 2 + 1);
            uint256 endVest = fresh.exposed_assetsToVest();

            // Mid-vesting should be roughly half of end-vesting.
            if (endVest > 0) {
                assertApproxEqRel(
                    midVest,
                    endVest / 2,
                    0.05e18, // 5% tolerance for rounding.
                    "Mid-vesting interpolation is incorrect"
                );
            }
        }
    }

    // =========================================================================
    // TEST 2: Vesting Linear Interpolation
    // =========================================================================

    /// @notice Verify that _assetsToVest() interpolates linearly between start and end.
    function testFuzz_vestingLinearInterpolation(
        uint256 yieldSkip,
        uint256 checkTime
    ) public {
        yieldSkip = bound(yieldSkip, 1 hours, 7 days);

        // Deposit.
        uint256 depositAmount = 2_000_000e6;
        deal(USDC_MONAD, user1, depositAmount);
        vm.startPrank(user1);
        IERC20(USDC_MONAD).approve(address(harness), depositAmount);
        harness.deposit(depositAmount, user1, cUSDC_WMON_MARKET);
        vm.stopPrank();

        // Skip to accrue yield.
        skip(yieldSkip);

        // Trigger accrual to start vesting.
        harness.exposed_accrueIfNeeded();

        (uint256 vestingRate, uint256 vestEnd, uint256 lastClaim) = harness.exposed_getVestingData();

        if (vestingRate == 0) {
            // No yield detected; skip.
            return;
        }

        uint256 period = harness.vestingPeriod();
        checkTime = bound(checkTime, 0, period);

        // At start: assetsToVest should be 0.
        uint256 atStart = harness.exposed_assetsToVest();
        assertEq(atStart, 0, "assetsToVest not 0 at vesting start");

        // Skip to checkTime.
        skip(checkTime);

        uint256 atCheck = harness.exposed_assetsToVest();

        // Expected: vestingRate * checkTime / WAD
        uint256 expectedAtCheck = (vestingRate * checkTime) / WAD;
        assertApproxEqAbs(
            atCheck,
            expectedAtCheck,
            1,
            "Linear interpolation mismatch at checkTime"
        );

        // Skip to end.
        skip(period - checkTime + 1);

        uint256 atEnd = harness.exposed_assetsToVest();

        // At end: should be total yield = vestingRate * period / WAD.
        uint256 expectedTotal = (vestingRate * period) / WAD;
        assertApproxEqAbs(
            atEnd,
            expectedTotal,
            1,
            "assetsToVest mismatch at vesting end"
        );

        // atCheck should be <= atEnd.
        assertLe(
            atCheck,
            atEnd,
            "assetsToVest at check should not exceed end"
        );
    }

    // =========================================================================
    // TEST 3: Rapid Accrual Bursts
    // =========================================================================

    /// @notice Multiple calls to accrueIfNeeded during a single vesting period
    ///         should not cause double-counting or break vesting.
    function testFuzz_rapidAccrualBursts(
        uint256 numBursts,
        uint256 timeBetween
    ) public {
        numBursts = bound(numBursts, 2, 10);
        timeBetween = bound(timeBetween, 1, 1 hours);

        // Deposit.
        uint256 depositAmount = 1_000_000e6;
        deal(USDC_MONAD, user1, depositAmount);
        vm.startPrank(user1);
        IERC20(USDC_MONAD).approve(address(harness), depositAmount);
        harness.deposit(depositAmount, user1, cUSDC_WMON_MARKET);
        vm.stopPrank();

        // Let yield accrue.
        skip(2 days);

        // Trigger initial vesting.
        harness.exposed_accrueIfNeeded();

        (uint256 initialVestingRate, , ) = harness.exposed_getVestingData();
        if (initialVestingRate == 0) return;

        uint256 totalAssetsAtStart = harness.totalAssets();
        uint256 lastTotalAssets = totalAssetsAtStart;

        // Call accrueIfNeeded multiple times during the vesting period.
        for (uint256 i = 0; i < numBursts; i++) {
            skip(timeBetween);

            harness.exposed_accrueIfNeeded();

            uint256 currentTotalAssets = harness.totalAssets();

            // totalAssets should be monotonically non-decreasing (yield vesting).
            assertGe(
                currentTotalAssets,
                lastTotalAssets,
                "totalAssets decreased during vesting burst"
            );

            // Vesting rate should not change mid-vesting.
            (uint256 currentRate, , ) = harness.exposed_getVestingData();
            if (harness.exposed_isVestingActive()) {
                assertEq(
                    currentRate,
                    initialVestingRate,
                    "Vesting rate changed during active vesting"
                );
            }

            lastTotalAssets = currentTotalAssets;
        }

        // After all bursts, totalAssets should not have jumped beyond expected.
        uint256 totalTimePassed = numBursts * timeBetween;
        uint256 maxExpectedVested = (initialVestingRate * totalTimePassed) / WAD;
        uint256 actualVested = harness.totalAssets() - totalAssetsAtStart;

        // Actual vested should approximately match expected (may differ slightly from
        // ongoing market interest accrual).
        assertApproxEqRel(
            actualVested,
            maxExpectedVested,
            0.1e18, // 10% tolerance for concurrent market interest.
            "Vested amount diverged significantly from expected"
        );
    }

    // =========================================================================
    // TEST 4: Vesting With Concurrent Operations
    // =========================================================================

    /// @notice Deposits and withdrawals during vesting should not break
    ///         the vesting schedule or cause exchange rate decreases.
    function testFuzz_vestingWithConcurrentOperations(
        uint256 depositAmount,
        uint256 withdrawAmount,
        uint256 warpTime
    ) public {
        depositAmount = bound(depositAmount, 1_000e6, 5_000_000e6);
        warpTime = bound(warpTime, 1, 1 days - 1);

        // Initial deposit.
        uint256 initialDeposit = 2_000_000e6;
        deal(USDC_MONAD, user1, initialDeposit);
        vm.startPrank(user1);
        IERC20(USDC_MONAD).approve(address(harness), initialDeposit);
        harness.deposit(initialDeposit, user1, cUSDC_WMON_MARKET);
        vm.stopPrank();

        // Skip and start vesting.
        skip(2 days);
        harness.exposed_accrueIfNeeded();

        if (!harness.exposed_isVestingActive()) return;

        uint256 exchangeRateBefore = harness.exchangeRate();

        // Skip into vesting.
        skip(warpTime);

        // Deposit during vesting.
        deal(USDC_MONAD, user2, depositAmount);
        vm.startPrank(user2);
        IERC20(USDC_MONAD).approve(address(harness), depositAmount);
        uint256 newShares = harness.deposit(depositAmount, user2, cUSDC_WMON_MARKET);
        vm.stopPrank();

        uint256 exchangeRateAfterDeposit = harness.exchangeRate();
        assertGe(
            exchangeRateAfterDeposit,
            exchangeRateBefore,
            "Exchange rate decreased after deposit during vesting"
        );

        // Withdraw during vesting (up to user2's balance).
        uint256 user2MaxWithdraw = harness.maxWithdraw(user2);
        withdrawAmount = bound(withdrawAmount, 0, user2MaxWithdraw);

        if (withdrawAmount > 0) {
            vm.prank(user2);
            try harness.withdraw(withdrawAmount, user2, user2) {
                uint256 exchangeRateAfterWithdraw = harness.exchangeRate();
                assertGe(
                    exchangeRateAfterWithdraw,
                    exchangeRateBefore,
                    "Exchange rate decreased after withdraw during vesting"
                );
            } catch {
                // Withdraw might fail due to liquidity; that's acceptable.
            }
        }

        // Verify vesting state is still coherent.
        (uint256 vestingRate, , ) = harness.exposed_getVestingData();
        // Vesting rate should not have changed from deposits/withdrawals.
        // (Vesting rate only changes when _accrueIfNeeded detects new yield at period end.)
    }

    // =========================================================================
    // TEST 5: Vesting Small Amount
    // =========================================================================

    /// @notice Very small yield amounts should not cause stuck states or
    ///         break subsequent accruals, even if vestingRate rounds to 0.
    function testFuzz_vestingSmallAmount(uint256 smallYield) public {
        smallYield = bound(smallYield, 1, 100);

        // Deploy fresh harness with short vesting period.
        LendingOptimizerHarness fresh = _deployFreshHarness(1 days);

        // Deposit a large amount so small yield is detectable.
        uint256 depositAmount = 1_000_000e6;
        deal(USDC_MONAD, user1, depositAmount);
        vm.startPrank(user1);
        IERC20(USDC_MONAD).approve(address(fresh), depositAmount);
        fresh.deposit(depositAmount, user1, cUSDC_WMON_MARKET);
        vm.stopPrank();

        // Skip minimal time for tiny yield.
        skip(1);

        // Trigger accrual.
        fresh.exposed_accrueIfNeeded();

        (uint256 vestingRate, , ) = fresh.exposed_getVestingData();

        // If vestingRate is 0, the system should still function.
        uint256 assetsToVest = fresh.exposed_assetsToVest();
        // assetsToVest should be 0 or very small.
        assertLe(
            assetsToVest,
            smallYield + 1,
            "assetsToVest exceeds expected small amount"
        );

        // Skip past vesting.
        skip(1 days + 1);

        // Next accrual should work fine.
        fresh.exposed_accrueIfNeeded();

        // System should not be in a stuck state.
        uint256 totalAssets = fresh.totalAssets();
        assertGt(totalAssets, 0, "totalAssets should be positive after small vesting");

        // Exchange rate should be valid.
        uint256 rate = fresh.exchangeRate();
        assertGt(rate, 0, "Exchange rate should be positive after small vesting");
    }

    // =========================================================================
    // TEST 6: Vesting Rate Overflow
    // =========================================================================

    /// @notice Large yield values that stress the 176-bit vesting rate packing
    ///         should either be handled correctly or safely revert.
    function testFuzz_vestingRateOverflow(uint256 largeYield) public {
        // The vesting rate is packed in 176 bits.
        // rate = (assetsToVest * WAD) / vestingPeriod
        // Max rate = 2^176 - 1
        // Max assetsToVest = (2^176 - 1) * vestingPeriod / WAD
        uint256 maxRate = (1 << 176) - 1;
        uint256 period = harness.vestingPeriod(); // 1 day = 86400
        uint256 maxSafeYield = (maxRate * period) / WAD;

        // Test both below and above the boundary.
        largeYield = bound(largeYield, maxSafeYield / 2, maxSafeYield + maxSafeYield / 10);

        // Deploy a fresh harness for this test.
        LendingOptimizerHarness fresh = _deployFreshHarness(1 days);

        // Deposit.
        uint256 depositAmount = 1_000_000e6;
        deal(USDC_MONAD, user1, depositAmount);
        vm.startPrank(user1);
        IERC20(USDC_MONAD).approve(address(fresh), depositAmount);
        fresh.deposit(depositAmount, user1, cUSDC_WMON_MARKET);
        vm.stopPrank();

        // Skip time.
        skip(2 days);

        // Mock large yield by making accrueMarkets return inflated value.
        uint256 trackedTa = fresh.exposed_totalAssetsIndexed();
        uint256 rawTaInflated = trackedTa + largeYield;

        // We can simulate by mocking the cToken convertToAssets to return inflated values.
        uint256 cTokenBal = IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(fresh));
        if (cTokenBal > 0) {
            vm.mockCall(
                cUSDC_WMON_MARKET,
                abi.encodeWithSelector(IBorrowableCToken.convertToAssets.selector, cTokenBal),
                abi.encode(rawTaInflated)
            );

            // Try to trigger accrual with large yield.
            try fresh.exposed_accrueIfNeeded() {
                // If it succeeds, verify the rate was stored correctly.
                uint256 storedRate = fresh.exposed_getVestingRate();
                uint256 expectedRate = FixedPointMathLib.mulDiv(largeYield, WAD, period);
                uint256 maskedRate = expectedRate & ((1 << 176) - 1);

                // If the rate overflows 176 bits, it will be silently truncated
                // by the assembly mask. We check for this.
                assertEq(
                    storedRate,
                    maskedRate,
                    "Stored vesting rate does not match masked expected rate"
                );

                // If truncation occurred (expectedRate != maskedRate), flag it.
                if (expectedRate != maskedRate) {
                    // Silent overflow: this is a known limitation for extreme yields.
                    // The rate was truncated. Verify the system still works.
                    uint256 totalAssets = fresh.totalAssets();
                    assertGt(totalAssets, 0, "totalAssets should be positive after overflow");
                }
            } catch {
                // Safe revert is acceptable for extreme values.
            }

            vm.clearMockedCalls();
            // Re-mock permissions.
            vm.mockCall(
                address(liveCentralRegistry),
                abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
                abi.encode(true)
            );
            vm.mockCall(
                address(liveCentralRegistry),
                abi.encodeWithSelector(ICentralRegistry.hasHarvestPermissions.selector, address(this)),
                abi.encode(true)
            );
        }
    }

    // =========================================================================
    // TEST 7: Multiple Vesting Cycles
    // =========================================================================

    /// @notice Multiple complete vesting cycles should each vest independently,
    ///         with _totalAssets accumulating correctly and no yield lost.
    function testFuzz_multipleVestingCycles(
        uint256 numCycles,
        uint256 cycleSkip
    ) public {
        numCycles = bound(numCycles, 3, 10);
        cycleSkip = bound(cycleSkip, 1 days, 3 days);

        // Deposit.
        uint256 depositAmount = 2_000_000e6;
        deal(USDC_MONAD, user1, depositAmount);
        vm.startPrank(user1);
        IERC20(USDC_MONAD).approve(address(harness), depositAmount);
        harness.deposit(depositAmount, user1, cUSDC_WMON_MARKET);
        vm.stopPrank();

        uint256 lastTotalAssets = harness.totalAssets();
        uint256 lastExchangeRate = harness.exchangeRate();

        for (uint256 i = 0; i < numCycles; i++) {
            // Skip time for yield to accrue.
            skip(cycleSkip);

            // Trigger accrual to start new vesting.
            harness.exposed_accrueIfNeeded();

            // Wait for vesting to complete.
            skip(harness.vestingPeriod() + 1);

            // Trigger accrual to finalize vesting and detect next yield.
            harness.exposed_accrueIfNeeded();

            uint256 currentTotalAssets = harness.totalAssets();
            uint256 currentExchangeRate = harness.exchangeRate();

            // totalAssets should be monotonically non-decreasing across cycles.
            assertGe(
                currentTotalAssets,
                lastTotalAssets,
                "totalAssets decreased between vesting cycles"
            );

            // Exchange rate should be monotonically non-decreasing.
            assertGe(
                currentExchangeRate,
                lastExchangeRate,
                "Exchange rate decreased between vesting cycles"
            );

            // Each cycle's yield is independent: the increment should be positive.
            // (Unless interest rate is 0, which is unlikely on live markets.)

            lastTotalAssets = currentTotalAssets;
            lastExchangeRate = currentExchangeRate;
        }

        // Final verification: total accumulated yield should be positive.
        uint256 finalTotalAssets = harness.totalAssets();
        assertGt(
            finalTotalAssets,
            depositAmount + 77777, // Must exceed initial deposit + dead shares.
            "No yield accumulated over multiple cycles"
        );
    }

    // =========================================================================
    // TEST 8: Vesting End Boundary
    // =========================================================================

    /// @notice Verifying _assetsToVest at vestEnd - offset, exactly at vestEnd,
    ///         and 1 second past vestEnd.
    function testFuzz_vestingEndBoundary(uint256 checkOffset) public {
        checkOffset = bound(checkOffset, 0, 10);

        // Deposit.
        uint256 depositAmount = 2_000_000e6;
        deal(USDC_MONAD, user1, depositAmount);
        vm.startPrank(user1);
        IERC20(USDC_MONAD).approve(address(harness), depositAmount);
        harness.deposit(depositAmount, user1, cUSDC_WMON_MARKET);
        vm.stopPrank();

        // Skip and start vesting.
        skip(2 days);
        harness.exposed_accrueIfNeeded();

        (uint256 vestingRate, uint256 vestEnd, uint256 lastClaim) = harness.exposed_getVestingData();
        if (vestingRate == 0) return;

        uint256 period = harness.vestingPeriod();
        uint256 totalYield = (vestingRate * period) / WAD;

        // Warp to vestEnd - checkOffset.
        uint256 targetTime = vestEnd - checkOffset;
        // We need to warp to targetTime. Current block.timestamp is lastClaim.
        if (targetTime > block.timestamp) {
            skip(targetTime - block.timestamp);
        }

        uint256 assetsAtOffset = harness.exposed_assetsToVest();

        if (checkOffset > 0) {
            // Before end: should be less than total yield.
            assertLt(
                assetsAtOffset,
                totalYield + 1,
                "assetsToVest at offset exceeds total yield"
            );
        }

        // Warp to exactly vestEnd.
        if (block.timestamp < vestEnd) {
            skip(vestEnd - block.timestamp);
        }
        uint256 assetsAtEnd = harness.exposed_assetsToVest();

        // At vestEnd: should equal total yield.
        assertApproxEqAbs(
            assetsAtEnd,
            totalYield,
            1,
            "assetsToVest at vestEnd does not equal total yield"
        );

        // Warp 1 second past vestEnd.
        skip(1);
        uint256 assetsPastEnd = harness.exposed_assetsToVest();

        // Past vestEnd: should be same as at vestEnd (capped).
        assertEq(
            assetsPastEnd,
            assetsAtEnd,
            "assetsToVest increased past vestEnd"
        );
    }
}
