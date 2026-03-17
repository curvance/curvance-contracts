// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { LendingOptimizerHarness } from "../LendingOptimizerHarness.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

/// @title Negative path tests for removeApprovedAsset
/// @notice Covers revert branches that are uncovered in the main test file.
contract TestRemoveApprovedAssetNegative is TestBaseLendingOptimizer {

    function setUp() public override {
        super.setUp();
    }

    function test_reverts_notApproved() public {
        _setUpTwoMarkets();

        LendingOptimizer.ReallocationAction[] memory actions =
            new LendingOptimizer.ReallocationAction[](0);

        vm.expectRevert(LendingOptimizer.LendingOptimizer__MarketNotApproved.selector);
        optimizer.removeApprovedAsset(address(0xdead), actions);
    }

    function test_reverts_noReallocationTargets_withAssets() public {
        // Use 3 markets so removal leaves caps >= 100%.
        _setUpThreeMarkets();

        // Deposit only into the market we'll remove via harness.
        LendingOptimizerHarness harness = LendingOptimizerHarness(address(optimizer));
        deal(USDC_MONAD, address(this), 1_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000e6);
        harness.depositToMarket(1_000e6, address(this), cUSDC_WETH_MARKET);

        // Empty actions array but market has assets — should revert.
        LendingOptimizer.ReallocationAction[] memory actions =
            new LendingOptimizer.ReallocationAction[](0);

        vm.expectRevert(LendingOptimizer.LendingOptimizer__InvalidParameter.selector);
        optimizer.removeApprovedAsset(cUSDC_WETH_MARKET, actions);
    }

    function test_reverts_zeroBps() public {
        _setUpThreeMarkets();

        LendingOptimizerHarness harness = LendingOptimizerHarness(address(optimizer));
        deal(USDC_MONAD, address(this), 1_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000e6);
        harness.depositToMarket(1_000e6, address(this), cUSDC_WETH_MARKET);

        // BPS = 0 is invalid.
        LendingOptimizer.ReallocationAction[] memory actions =
            new LendingOptimizer.ReallocationAction[](1);
        actions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WMON_MARKET), int256(0)
        );

        vm.expectRevert(LendingOptimizer.LendingOptimizer__InvalidParameter.selector);
        optimizer.removeApprovedAsset(cUSDC_WETH_MARKET, actions);
    }

    function test_reverts_unapprovedTarget() public {
        _setUpThreeMarkets();

        LendingOptimizerHarness harness = LendingOptimizerHarness(address(optimizer));
        deal(USDC_MONAD, address(this), 1_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000e6);
        harness.depositToMarket(1_000e6, address(this), cUSDC_WETH_MARKET);

        // Target is not approved.
        LendingOptimizer.ReallocationAction[] memory actions =
            new LendingOptimizer.ReallocationAction[](1);
        actions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(address(0xdead)), int256(10000)
        );

        vm.expectRevert(LendingOptimizer.LendingOptimizer__MarketNotApproved.selector);
        optimizer.removeApprovedAsset(cUSDC_WETH_MARKET, actions);
    }

    function test_reverts_bpsNotHundredPercent() public {
        _setUpThreeMarkets();

        LendingOptimizerHarness harness = LendingOptimizerHarness(address(optimizer));
        deal(USDC_MONAD, address(this), 1_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000e6);
        harness.depositToMarket(1_000e6, address(this), cUSDC_WETH_MARKET);

        // BPS = 5000, not 10000.
        LendingOptimizer.ReallocationAction[] memory actions =
            new LendingOptimizer.ReallocationAction[](1);
        actions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WMON_MARKET), int256(5000)
        );

        vm.expectRevert(LendingOptimizer.LendingOptimizer__InvalidParameter.selector);
        optimizer.removeApprovedAsset(cUSDC_WETH_MARKET, actions);
    }
}
