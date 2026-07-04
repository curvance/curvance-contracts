// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { LendingOptimizerHarness } from "tests/market/optimizer/LendingOptimizerHarness.sol";
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

    function test_lendingOptimizer_removeApprovedAsset_totalBpsFailureRollsBackExternalMarketActions() public {
        optimizer.accrueIfNeeded();

        uint256 totalBefore = optimizer.totalAssets();
        uint256 idleBefore = IERC20(USDC_MONAD).balanceOf(address(optimizer));
        address marketToRemove = cUSDC_WMON_MARKET;
        address firstTarget = cUSDC_WBTC_MARKET;
        address secondTarget = cUSDC_WETH_MARKET;
        uint256 removedSharesBefore = IBorrowableCToken(marketToRemove).balanceOf(address(optimizer));
        uint256 firstTargetSharesBefore = IBorrowableCToken(firstTarget).balanceOf(address(optimizer));
        uint256 secondTargetSharesBefore = IBorrowableCToken(secondTarget).balanceOf(address(optimizer));
        uint256 removedCapBefore = optimizer.allocationCaps(marketToRemove);

        optimizer.updateCap(firstTarget, 10_000);
        optimizer.updateCap(secondTarget, 10_000);

        LendingOptimizer.ReallocationAction[] memory removeActions =
            new LendingOptimizer.ReallocationAction[](2);
        removeActions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(firstTarget),
            int256(9_000)
        );
        removeActions[1] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(secondTarget),
            int256(900)
        );
        LendingOptimizer.AllocationBound[] memory bounds = _unconstrainedBoundsForRemoval(marketToRemove);

        vm.expectRevert(LendingOptimizer.LendingOptimizer__InvalidParameter.selector);
        optimizer.removeApprovedAsset(marketToRemove, removeActions, bounds);

        assertEq(optimizer.totalAssets(), totalBefore, "total assets rollback");
        assertEq(optimizer.numApprovedMarkets(), 3, "market list rollback");
        assertEq(optimizer.allocationCaps(marketToRemove), removedCapBefore, "removed cap rollback");
        assertEq(IERC20(USDC_MONAD).balanceOf(address(optimizer)), idleBefore, "idle underlying rollback");
        assertEq(
            IBorrowableCToken(marketToRemove).balanceOf(address(optimizer)),
            removedSharesBefore,
            "removed market shares rollback"
        );
        assertEq(
            IBorrowableCToken(firstTarget).balanceOf(address(optimizer)),
            firstTargetSharesBefore,
            "first target shares rollback"
        );
        assertEq(
            IBorrowableCToken(secondTarget).balanceOf(address(optimizer)),
            secondTargetSharesBefore,
            "second target shares rollback"
        );
    }

    function test_lendingOptimizer_removeApprovedAsset_boundsFailureRollsBackExternalMarketActions() public {
        optimizer.accrueIfNeeded();

        uint256 totalBefore = optimizer.totalAssets();
        uint256 idleBefore = IERC20(USDC_MONAD).balanceOf(address(optimizer));
        address marketToRemove = cUSDC_WMON_MARKET;
        address targetMarket = cUSDC_WBTC_MARKET;
        address untouchedMarket = cUSDC_WETH_MARKET;
        uint256 removedSharesBefore = IBorrowableCToken(marketToRemove).balanceOf(address(optimizer));
        uint256 targetSharesBefore = IBorrowableCToken(targetMarket).balanceOf(address(optimizer));
        uint256 untouchedSharesBefore = IBorrowableCToken(untouchedMarket).balanceOf(address(optimizer));
        uint256 removedCapBefore = optimizer.allocationCaps(marketToRemove);

        optimizer.updateCap(targetMarket, 10_000);
        optimizer.updateCap(untouchedMarket, 10_000);

        LendingOptimizer.ReallocationAction[] memory removeActions =
            new LendingOptimizer.ReallocationAction[](1);
        removeActions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(targetMarket),
            int256(10_000)
        );

        LendingOptimizer.AllocationBound[] memory bounds = _unconstrainedBoundsForRemoval(marketToRemove);
        bounds[0] = LendingOptimizer.AllocationBound({
            cToken: bounds[0].cToken,
            minBps: 10_000,
            maxBps: 10_000
        });

        vm.expectRevert(LendingOptimizer.LendingOptimizer__AllocationOutOfBounds.selector);
        optimizer.removeApprovedAsset(marketToRemove, removeActions, bounds);

        assertEq(optimizer.totalAssets(), totalBefore, "total assets rollback");
        assertEq(optimizer.numApprovedMarkets(), 3, "market list rollback");
        assertEq(optimizer.allocationCaps(marketToRemove), removedCapBefore, "removed cap rollback");
        assertEq(IERC20(USDC_MONAD).balanceOf(address(optimizer)), idleBefore, "idle underlying rollback");
        assertEq(
            IBorrowableCToken(marketToRemove).balanceOf(address(optimizer)),
            removedSharesBefore,
            "removed market shares rollback"
        );
        assertEq(
            IBorrowableCToken(targetMarket).balanceOf(address(optimizer)),
            targetSharesBefore,
            "target market shares rollback"
        );
        assertEq(
            IBorrowableCToken(untouchedMarket).balanceOf(address(optimizer)),
            untouchedSharesBefore,
            "untouched market shares rollback"
        );
    }

    function test_lendingOptimizer_removeApprovedAsset_canonicalZeroShareLastTargetDustIsBounded() public {
        address[] memory approvedCTokens = new address[](3);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;
        approvedCTokens[2] = cUSDC_WETH_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](3);
        allocationCapsBps[0] = 10_000;
        allocationCapsBps[1] = 10_000;
        allocationCapsBps[2] = 10_000;

        LendingOptimizerHarness smallOptimizer = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            0
        );

        deal(USDC_MONAD, address(this), 77777);
        IERC20(USDC_MONAD).approve(address(smallOptimizer), 77777);
        smallOptimizer.initializeDeposits(cUSDC_WMON_MARKET);

        _depositToLocalMarket(smallOptimizer, 10_000e6, cUSDC_WMON_MARKET);
        _depositToLocalMarket(smallOptimizer, 10_000e6, cUSDC_WBTC_MARKET);
        _depositToLocalMarket(smallOptimizer, 5_000, cUSDC_WETH_MARKET);

        skip(365 days);
        smallOptimizer.accrueIfNeeded();

        uint256 sharesToRedeem = IBorrowableCToken(cUSDC_WETH_MARKET).balanceOf(address(smallOptimizer));
        uint256 assetsRedeemedPreview = IBorrowableCToken(cUSDC_WETH_MARKET).convertToAssets(sharesToRedeem);
        uint256 firstTargetAmount = (assetsRedeemedPreview * 9_999) / 10_000;
        uint256 lastTargetAmount = assetsRedeemedPreview - firstTargetAmount;

        assertGt(
            IBorrowableCToken(cUSDC_WMON_MARKET).convertToShares(firstTargetAmount),
            0,
            "first target deposit should be canonical non-dust"
        );
        assertEq(
            IBorrowableCToken(cUSDC_WBTC_MARKET).convertToShares(lastTargetAmount),
            0,
            "last target should be canonical cToken dust"
        );
        assertLe(
            lastTargetAmount,
            IBorrowableCToken(cUSDC_WBTC_MARKET).convertToAssets(1),
            "zero-share remainder must be bounded by one cToken share value"
        );

        uint256 idleBefore = IERC20(USDC_MONAD).balanceOf(address(smallOptimizer));
        uint256 totalBefore = smallOptimizer.totalAssets();

        LendingOptimizer.ReallocationAction[] memory removeActions =
            new LendingOptimizer.ReallocationAction[](2);
        removeActions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WMON_MARKET),
            int256(9_999)
        );
        removeActions[1] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WBTC_MARKET),
            int256(1)
        );

        LendingOptimizer.AllocationBound[] memory bounds = new LendingOptimizer.AllocationBound[](2);
        bounds[0] = LendingOptimizer.AllocationBound({
            cToken: cUSDC_WMON_MARKET,
            minBps: 0,
            maxBps: 10_000
        });
        bounds[1] = LendingOptimizer.AllocationBound({
            cToken: cUSDC_WBTC_MARKET,
            minBps: 0,
            maxBps: 10_000
        });

        smallOptimizer.removeApprovedAsset(cUSDC_WETH_MARKET, removeActions, bounds);

        uint256 idleDelta = IERC20(USDC_MONAD).balanceOf(address(smallOptimizer)) - idleBefore;
        assertEq(idleDelta, lastTargetAmount, "canonical zero-share remainder stays idle");
        assertLe(idleDelta, 10_000, "canonical zero-share removal dust stays sub-cent");
        assertLe(totalBefore - smallOptimizer.totalAssets(), idleDelta + 2, "NAV drop bounded by dust plus cToken rounding");
    }

    function _sumApprovedMarketAssets() internal view returns (uint256 sum) {
        uint256 length = optimizer.numApprovedMarkets();
        for (uint256 i; i < length; ++i) {
            IBorrowableCToken market = IBorrowableCToken(optimizer.approvedCTokensList(i));
            sum += market.convertToAssets(market.balanceOf(address(optimizer)));
        }
        sum += IERC20(USDC_MONAD).balanceOf(address(optimizer));
    }

    function _depositToLocalMarket(
        LendingOptimizerHarness localOptimizer,
        uint256 assets,
        address market
    ) internal {
        deal(USDC_MONAD, address(this), assets);
        IERC20(USDC_MONAD).approve(address(localOptimizer), assets);
        localOptimizer.depositToMarket(assets, address(this), market);
    }
}
