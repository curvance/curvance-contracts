// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { LendingOptimizerHarness } from "../LendingOptimizerHarness.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @title LO-L-06 Regression: removeApprovedAsset dust-carryover underflow
/// @notice LendingOptimizer.sol:619-635. The skip branch in the reallocation
///         loop subtracts `depositAmount` from `totalDeposited` to "carry the
///         dust forward". On non-last iterations this is balanced by a prior
///         `totalDeposited += depositAmount`. On the LAST iteration there is
///         no prior addition (the last uses `assetsRedeemed - totalDeposited`
///         to compute the remainder). When all three of the following hold:
///           (1) i == lastAction
///           (2) convertToShares(depositAmount) == 0 on the last target
///           (3) last-action BPS > 5000 (so depositAmount > totalDeposited)
///         the subtraction underflows and reverts with Panic(0x11).
contract RemoveApprovedAssetDustRegression is TestBaseLendingOptimizer {

    function setUp() public override {
        super.setUp();

        // Three markets — we'll remove WETH and reallocate across WMON (2000 BPS) + WBTC (8000 BPS).
        _setUpThreeMarkets();

        deal(USDC_MONAD, address(this), 20_100e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 20_100e6);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(10_000e6, address(this), cUSDC_WMON_MARKET);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(10_000e6, address(this), cUSDC_WBTC_MARKET);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(100e6, address(this), cUSDC_WETH_MARKET);
    }

    /// @notice Regression test for the L-06 fix.
    /// @dev Pre-fix: this exact configuration reverted with Panic(0x11) inside
    ///      the skip-branch subtract on the last iteration. Post-fix: the
    ///      subtract is guarded with `if (i != lastAction)`, so the last-
    ///      iteration dust stays idle on the optimizer (recoverable via skim).
    function test_regression_LO_L_06_lastActionDustStaysIdle() public {
        // Same setup that used to trigger Panic(0x11):
        // WBTC's convertToShares mocked to 0, last-action BPS = 8000.
        vm.mockCall(
            cUSDC_WBTC_MARKET,
            abi.encodeWithSelector(IBorrowableCToken.convertToShares.selector),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        LendingOptimizer.ReallocationAction[] memory removeActions = new LendingOptimizer.ReallocationAction[](2);
        removeActions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WMON_MARKET),
            int256(2_000)
        );
        removeActions[1] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WBTC_MARKET),
            int256(8_000)
        );

        LendingOptimizer.AllocationBound[] memory bounds = _unconstrainedBoundsForRemoval(cUSDC_WETH_MARKET);

        uint256 idleUsdcBefore = IERC20(USDC_MONAD).balanceOf(address(optimizer));

        // With the fix applied, the call completes without reverting.
        optimizer.removeApprovedAsset(cUSDC_WETH_MARKET, removeActions, bounds);

        // Market is removed.
        assertEq(optimizer.numApprovedMarkets(), 2, "WETH market removed");

        // Last-action dust sits idle on the optimizer — skim()-recoverable.
        uint256 idleUsdcAfter = IERC20(USDC_MONAD).balanceOf(address(optimizer));
        assertGt(idleUsdcAfter, idleUsdcBefore, "last-iteration dust left idle on optimizer");
    }

    /// @notice Companion: workaround path. Reordering so the high-BPS target
    ///         is NOT last avoids the bug entirely, because the skip-branch
    ///         subtract on a non-last iteration cancels a matching prior add.
    function test_regression_LO_L_06_reorderingAvoidsBug() public {
        // Same mock: WBTC's convertToShares still returns 0 for any input.
        vm.mockCall(
            cUSDC_WBTC_MARKET,
            abi.encodeWithSelector(IBorrowableCToken.convertToShares.selector),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // This time put the high-BPS target FIRST, low-BPS target LAST.
        // Same markets, same proportions — only the order changes.
        LendingOptimizer.ReallocationAction[] memory removeActions = new LendingOptimizer.ReallocationAction[](2);
        removeActions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WBTC_MARKET),
            int256(8_000)
        );
        removeActions[1] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WMON_MARKET),
            int256(2_000)
        );

        LendingOptimizer.AllocationBound[] memory bounds = _unconstrainedBoundsForRemoval(cUSDC_WETH_MARKET);

        // Loop trace (no revert):
        //   i=0 (WBTC, 8000 BPS): depositAmount = mulDiv ≈ 80e6. totalDeposited += 80e6 → 80e6.
        //                         convertToShares → 0 (mocked) → skip → totalDeposited -= 80e6 → 0.
        //                         (Non-last: skip subtract is balanced by prior add. Clean.)
        //   i=1 (WMON, 2000 BPS, last): depositAmount = assetsRedeemed - 0 = assetsRedeemed.
        //                         convertToShares real → >0 → deposit all.
        optimizer.removeApprovedAsset(cUSDC_WETH_MARKET, removeActions, bounds);

        // Completed without Panic.
        assertEq(optimizer.numApprovedMarkets(), 2, "WETH market removed");
    }
}
