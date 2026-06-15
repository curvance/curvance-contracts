// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { TestBaseLendingOptimizer } from "tests/market/optimizer/TestBaseLendingOptimizer.sol";

contract TestLendingOptimizerRemoveApprovedAssetAccounting is TestBaseLendingOptimizer {
    function setUp() public override {
        super.setUp();
        _setUpThreeMarkets();
        _depositToAllMarkets(500_000e6);
    }

    function test_lendingOptimizer_removeApprovedAsset_resyncsToRecoverableAssetsAfterRoundingLoss() public {
        optimizer.accrueIfNeeded();

        uint256 totalBefore = optimizer.totalAssets();
        address marketToRemove = cUSDC_WMON_MARKET;
        address targetMarket = cUSDC_WBTC_MARKET;

        optimizer.updateCap(targetMarket, 10_000);
        optimizer.updateCap(cUSDC_WETH_MARKET, 10_000);

        LendingOptimizer.ReallocationAction[] memory removeActions =
            new LendingOptimizer.ReallocationAction[](1);
        removeActions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(targetMarket),
            int256(10_000)
        );

        optimizer.removeApprovedAsset(
            marketToRemove,
            removeActions,
            _unconstrainedBoundsForRemoval(marketToRemove)
        );

        uint256 cachedAfterRemoval = optimizer.totalAssets();
        uint256 recoverableAfterRemoval = _sumApprovedMarketAssets();

        assertGe(
            cachedAfterRemoval,
            recoverableAfterRemoval,
            "cached accounting should not be below recoverable assets"
        );

        optimizer.accrueIfNeeded();
        uint256 resyncedAfterRemoval = optimizer.totalAssets();

        assertEq(
            resyncedAfterRemoval,
            recoverableAfterRemoval,
            "explicit accrual should resync to remaining market assets"
        );
        assertLe(
            totalBefore - resyncedAfterRemoval,
            1,
            "market removal should not leak more than bounded rounding dust"
        );
    }

    function test_lendingOptimizer_removeApprovedAsset_revertsWhenReallocationTargetOvercreditsTrackedAssets() public {
        optimizer.accrueIfNeeded();

        uint256 totalBefore = optimizer.totalAssets();
        address marketToRemove = cUSDC_WMON_MARKET;
        address targetMarket = cUSDC_WBTC_MARKET;
        uint256 sharesToRedeem = IBorrowableCToken(marketToRemove).balanceOf(address(optimizer));
        uint256 assetsToReallocate = IBorrowableCToken(marketToRemove).convertToAssets(sharesToRedeem);
        uint256 cTokenShares = assetsToReallocate;

        optimizer.updateCap(targetMarket, 10_000);
        optimizer.updateCap(cUSDC_WETH_MARKET, 10_000);

        vm.mockCall(
            targetMarket,
            abi.encodeWithSelector(IBorrowableCToken.convertToShares.selector, assetsToReallocate),
            abi.encode(cTokenShares)
        );
        vm.mockCall(
            targetMarket,
            abi.encodeWithSelector(IBorrowableCToken.deposit.selector, assetsToReallocate, address(optimizer)),
            abi.encode(cTokenShares)
        );
        vm.mockCall(
            targetMarket,
            abi.encodeWithSelector(IBorrowableCToken.convertToAssets.selector, cTokenShares),
            abi.encode(assetsToReallocate + 1)
        );

        LendingOptimizer.ReallocationAction[] memory removeActions =
            new LendingOptimizer.ReallocationAction[](1);
        removeActions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(targetMarket),
            int256(10_000)
        );
        LendingOptimizer.AllocationBound[] memory bounds = _unconstrainedBoundsForRemoval(marketToRemove);

        vm.expectRevert(LendingOptimizer.LendingOptimizer__AssetMismatch.selector);
        optimizer.removeApprovedAsset(marketToRemove, removeActions, bounds);

        assertEq(optimizer.totalAssets(), totalBefore, "total assets must roll back");
        assertEq(optimizer.numApprovedMarkets(), 3, "market removal must roll back");
        assertEq(
            IBorrowableCToken(marketToRemove).balanceOf(address(optimizer)),
            sharesToRedeem,
            "redeemed market shares must roll back"
        );
    }

    function _sumApprovedMarketAssets() internal view returns (uint256 sum) {
        uint256 length = optimizer.numApprovedMarkets();
        for (uint256 i; i < length; ++i) {
            IBorrowableCToken market = IBorrowableCToken(optimizer.approvedCTokensList(i));
            sum += market.convertToAssets(market.balanceOf(address(optimizer)));
        }
        sum += IERC20(USDC_MONAD).balanceOf(address(optimizer));
    }
}
