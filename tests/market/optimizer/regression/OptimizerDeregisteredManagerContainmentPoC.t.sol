// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {
    TestBaseLendingOptimizer
} from "tests/market/optimizer/TestBaseLendingOptimizer.sol";
import {
    LendingOptimizer
} from "contracts/market/optimizer/LendingOptimizer.sol";
import {CentralRegistry} from "contracts/architecture/CentralRegistry.sol";
import {
    MarketManagerIsolated
} from "contracts/market/isolated/MarketManagerIsolated.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IBorrowableCToken} from "contracts/interfaces/IBorrowableCToken.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";

/// @notice Same-state differential for registry removal versus route containment.
contract OptimizerDeregisteredManagerContainmentPoC is
    TestBaseLendingOptimizer
{
    address internal holder;
    address internal depositor;
    address internal routeHarvester;
    address internal outsider;

    function setUp() public override {
        super.setUp();
        _setUpTwoMarkets();

        holder = makeAddr("optimizer holder");
        depositor = makeAddr("permissionless depositor");
        routeHarvester = makeAddr("harvest-only operator");
        outsider = makeAddr("optimizer outsider");

        _depositAs(holder, 1_000e6);
        _balanceApprovedRoutes();

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(
                ICentralRegistry.hasHarvestPermissions.selector, routeHarvester
            ),
            abi.encode(true)
        );
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(
                ICentralRegistry.hasMarketPermissions.selector, routeHarvester
            ),
            abi.encode(false)
        );

        // Keep the comparison free of fresh cToken hold-period effects.
        skip(20 minutes);
        optimizer.accrueIfNeeded();
    }

    function test_deregistrationDoesNotRevokeRouteButOrderedContainmentDoes()
        public
    {
        uint256 sharedState = vm.snapshotState();
        _proveDeregistrationAloneLeavesTheRouteLive();

        assertTrue(
            vm.revertToState(sharedState), "restore shared pre-removal state"
        );
        _provePauseDrainAndDeregisterLastContainsTheRoute();
    }

    function _proveDeregistrationAloneLeavesTheRouteLive() internal {
        address targetManager = _marketMgrs[cUSDC_WMON_MARKET];
        CentralRegistry(address(liveCentralRegistry))
            .removeMarketManager(targetManager);
        assertFalse(
            liveCentralRegistry.isMarketManager(targetManager),
            "manager removed from registry discovery"
        );

        uint256 targetSharesBefore =
            IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer));
        _depositAs(depositor, 100e6);
        uint256 targetSharesAfterDeposit =
            IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer));
        assertGt(
            targetSharesAfterDeposit,
            targetSharesBefore,
            "permissionless deposit still enters deregistered manager"
        );

        LendingOptimizer.ReallocationAction[] memory actions =
            _twoMarketActions(10e6, -10e6);
        LendingOptimizer.AllocationBound[] memory bounds =
            _unconstrainedBounds();
        uint256 targetAssetsBeforeRebalance =
            _optimizerMarketAssets(cUSDC_WMON_MARKET);
        vm.prank(routeHarvester);
        optimizer.rebalance(actions, bounds);
        assertGt(
            _optimizerMarketAssets(cUSDC_WMON_MARKET),
            targetAssetsBeforeRebalance,
            "harvest-only rebalance still enters deregistered manager"
        );

        vm.prank(outsider);
        vm.expectRevert(
            LendingOptimizer.LendingOptimizer__Unauthorized.selector
        );
        optimizer.rebalance(actions, bounds);

        vm.prank(routeHarvester);
        vm.expectRevert(
            LendingOptimizer.LendingOptimizer__Unauthorized.selector
        );
        optimizer.updateCap(cUSDC_WBTC_MARKET, 10_000);

        optimizer.setMintPaused(true);
        vm.startPrank(depositor);
        deal(USDC_MONAD, depositor, 10e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10e6);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__MintPaused.selector);
        optimizer.deposit(10e6, depositor);
        vm.stopPrank();

        targetAssetsBeforeRebalance = _optimizerMarketAssets(cUSDC_WMON_MARKET);
        vm.prank(routeHarvester);
        optimizer.rebalance(actions, bounds);
        assertGt(
            _optimizerMarketAssets(cUSDC_WMON_MARKET),
            targetAssetsBeforeRebalance,
            "optimizer-global mint pause does not contain rebalance inflow"
        );
    }

    function _provePauseDrainAndDeregisterLastContainsTheRoute() internal {
        address targetManager = _marketMgrs[cUSDC_WMON_MARKET];
        MarketManagerIsolated(targetManager)
            .setMintPaused(cUSDC_WMON_MARKET, true);

        uint256 depositorBalanceBefore =
            IERC20(USDC_MONAD).balanceOf(depositor);
        uint256 depositorSharesBefore = optimizer.balanceOf(depositor);
        deal(USDC_MONAD, depositor, 100e6);
        vm.startPrank(depositor);
        IERC20(USDC_MONAD).approve(address(optimizer), 100e6);
        vm.expectRevert();
        optimizer.deposit(100e6, depositor);
        vm.stopPrank();
        assertEq(optimizer.balanceOf(depositor), depositorSharesBefore);
        assertEq(
            IERC20(USDC_MONAD).balanceOf(depositor),
            100e6,
            "target pause rolls back pulled user assets"
        );
        assertEq(
            depositorBalanceBefore, 0, "precondition: depositor starts empty"
        );

        LendingOptimizer.ReallocationAction[] memory blockedInflow =
            _twoMarketActions(10e6, -10e6);
        LendingOptimizer.AllocationBound[] memory blockedBounds =
            _unconstrainedBounds();
        vm.prank(routeHarvester);
        vm.expectRevert(
            LendingOptimizer.LendingOptimizer__MarketPaused.selector
        );
        optimizer.rebalance(blockedInflow, blockedBounds);

        optimizer.updateCap(cUSDC_WBTC_MARKET, 10_000);
        optimizer.accrueIfNeeded();

        uint256 navBefore = optimizer.totalAssets();
        uint256 holderSharesBefore = optimizer.balanceOf(holder);
        uint256 holderClaimBefore =
            optimizer.convertToAssets(holderSharesBefore);
        uint256 retainedAssetsBefore =
            _optimizerMarketAssets(cUSDC_WBTC_MARKET);

        LendingOptimizer.ReallocationAction[] memory removeActions =
            new LendingOptimizer.ReallocationAction[](1);
        removeActions[0] = LendingOptimizer.ReallocationAction({
            cToken: IBorrowableCToken(cUSDC_WBTC_MARKET), assetsOrBps: 10_000
        });
        LendingOptimizer.AllocationBound[] memory postRemovalBounds =
            _unconstrainedBoundsForRemoval(cUSDC_WMON_MARKET);

        optimizer.removeApprovedAsset(
            cUSDC_WMON_MARKET, removeActions, postRemovalBounds
        );

        assertEq(optimizer.numApprovedMarkets(), 1);
        assertEq(optimizer.approvedCTokensList(0), cUSDC_WBTC_MARKET);
        assertEq(optimizer.allocationCaps(cUSDC_WMON_MARKET), 0);
        assertEq(
            IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer)),
            0,
            "target route fully drained"
        );
        assertGt(
            _optimizerMarketAssets(cUSDC_WBTC_MARKET),
            retainedAssetsBefore,
            "retained route absorbs drained value"
        );
        assertApproxEqAbs(
            optimizer.totalAssets(),
            navBefore,
            1,
            "de-scope preserves optimizer NAV within one atomic USDC unit"
        );
        assertEq(
            optimizer.balanceOf(holder),
            holderSharesBefore,
            "de-scope does not change holder shares"
        );
        assertApproxEqAbs(
            optimizer.convertToAssets(holderSharesBefore),
            holderClaimBefore,
            1,
            "de-scope preserves holder claim within one atomic USDC unit"
        );
        assertEq(
            IERC20(USDC_MONAD).balanceOf(address(optimizer)),
            0,
            "drain leaves no idle underlying"
        );

        CentralRegistry(address(liveCentralRegistry))
            .removeMarketManager(targetManager);
        assertFalse(liveCentralRegistry.isMarketManager(targetManager));

        uint256 retainedSharesBeforeDeposit =
            IBorrowableCToken(cUSDC_WBTC_MARKET).balanceOf(address(optimizer));
        _depositAs(depositor, 100e6);
        assertEq(
            IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer)),
            0,
            "removed route remains inactive after new deposits"
        );
        assertGt(
            IBorrowableCToken(cUSDC_WBTC_MARKET).balanceOf(address(optimizer)),
            retainedSharesBeforeDeposit,
            "new deposits use only retained route"
        );

        skip(20 minutes);
        optimizer.accrueIfNeeded();
        uint256 holderExitPreview =
            optimizer.convertToAssets(optimizer.balanceOf(holder));
        uint256 holderShares = optimizer.balanceOf(holder);
        uint256 holderUnderlyingBefore = IERC20(USDC_MONAD).balanceOf(holder);
        vm.prank(holder);
        uint256 holderExit = optimizer.redeem(holderShares, holder, holder);
        assertApproxEqAbs(
            holderExit,
            holderExitPreview,
            1,
            "holder can realize post-containment claim"
        );
        assertEq(
            IERC20(USDC_MONAD).balanceOf(holder),
            holderUnderlyingBefore + holderExit,
            "holder exit is funded"
        );
    }

    function _balanceApprovedRoutes() internal {
        uint256 targetAssets = _optimizerMarketAssets(cUSDC_WMON_MARKET);
        uint256 retainedAssets = _optimizerMarketAssets(cUSDC_WBTC_MARKET);
        uint256 targetAfter = (targetAssets + retainedAssets) / 2;
        uint256 amount = targetAssets - targetAfter;
        optimizer.rebalance(
            _twoMarketActions(-int256(amount), int256(amount)),
            _unconstrainedBounds()
        );
    }

    function _twoMarketActions(int256 target, int256 retained)
        internal
        view
        returns (LendingOptimizer.ReallocationAction[] memory actions)
    {
        actions = new LendingOptimizer.ReallocationAction[](2);
        actions[0] = LendingOptimizer.ReallocationAction({
            cToken: IBorrowableCToken(cUSDC_WMON_MARKET), assetsOrBps: target
        });
        actions[1] = LendingOptimizer.ReallocationAction({
            cToken: IBorrowableCToken(cUSDC_WBTC_MARKET), assetsOrBps: retained
        });
    }

    function _depositAs(address account, uint256 assets)
        internal
        returns (uint256 shares)
    {
        deal(USDC_MONAD, account, assets);
        vm.startPrank(account);
        IERC20(USDC_MONAD).approve(address(optimizer), assets);
        shares = optimizer.deposit(assets, account);
        vm.stopPrank();
    }

    function _optimizerMarketAssets(address market)
        internal
        view
        returns (uint256)
    {
        IBorrowableCToken cToken = IBorrowableCToken(market);
        return cToken.convertToAssets(cToken.balanceOf(address(optimizer)));
    }
}
