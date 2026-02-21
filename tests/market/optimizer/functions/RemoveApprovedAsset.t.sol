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

contract TestLendingOptimizerRemoveApprovedAsset is TestBaseLendingOptimizer {

    function setUp() public override {
        super.setUp();
    }

    function test_lendingOptimizer_removeApprovedAsset_success() public {
        // Setup with three markets (60% + 50% + 20% caps).
        // After removing 20% cap market, remaining 60% + 50% = 110% >= 100%.
        _setUpThreeMarkets();

        // Deposit to markets 0 and 1, with a smaller deposit to market 2
        // so the reallocation after removal fits within remaining caps.
        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        optimizer.deposit(10_000e6, address(this), cUSDC_WMON_MARKET);

        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        optimizer.deposit(10_000e6, address(this), cUSDC_WBTC_MARKET);

        deal(USDC_MONAD, address(this), 1_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000e6);
        optimizer.deposit(1_000e6, address(this), cUSDC_WETH_MARKET);

        // Record state before removal.
        uint256 totalAssetsBefore = optimizer.totalAssets();
        uint256 numMarketsBefore = optimizer.numApprovedMarkets();
        assertEq(numMarketsBefore, 3, "Should have 3 markets before removal");

        // Get assets in market 2 (cUSDC_WETH_MARKET) that will be removed.
        uint256 market2Assets = IBorrowableCToken(cUSDC_WETH_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WETH_MARKET).balanceOf(address(optimizer))
        );

        // Reallocate removed assets to market 0 (which has cap headroom).
        // After removal: total ~21K, market 0 ~11K (52%), cap 60% — within bounds.
        LendingOptimizer.RemoveAction[] memory removeActions = new LendingOptimizer.RemoveAction[](1);
        removeActions[0] = LendingOptimizer.RemoveAction(
            IBorrowableCToken(cUSDC_WMON_MARKET),
            market2Assets
        );

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Remove market at index 2 (cUSDC_WETH_MARKET with 20% cap).
        optimizer.removeApprovedAsset(2, removeActions);

        // Verify market was removed.
        uint256 numMarketsAfter = optimizer.numApprovedMarkets();
        assertEq(numMarketsAfter, 2, "Should have 2 markets after removal");

        // Verify the removed market's allocation cap is 0.
        assertEq(optimizer.allocationCaps(cUSDC_WETH_MARKET), 0, "Removed market cap should be 0");

        // Verify total assets are preserved (allowing for minor rounding).
        uint256 totalAssetsAfter = optimizer.totalAssets();
        assertApproxEqAbs(totalAssetsAfter, totalAssetsBefore, 10, "Total assets should be preserved");

        // Verify remaining markets are correct.
        assertEq(optimizer.approvedCTokensList(0), cUSDC_WMON_MARKET, "Market 0 should be WMON");
        assertEq(optimizer.approvedCTokensList(1), cUSDC_WBTC_MARKET, "Market 1 should be WBTC");
    }

    function test_lendingOptimizer_removeApprovedAsset_fail_whenOnlyOneMarket() public {
        // Setup with only one market.
        _setUpOneMarket();

        // Deposit some assets.
        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        optimizer.deposit(10_000e6, address(this));

        // Get assets in the only market.
        uint256 marketAssets = IBorrowableCToken(cUSDC_WMON_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer))
        );

        // Try to remove the only market with empty reallocation (no other market to reallocate to).
        LendingOptimizer.RemoveAction[] memory removeActions = new LendingOptimizer.RemoveAction[](0);

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Should revert because:
        // 1. If we try empty removeActions, it will revert with AssetMismatch (redeemed != reallocated)
        // 2. Even if we could remove, _validateAllocationCaps would fail with InsufficientAllocationCaps
        vm.expectRevert(LendingOptimizer.LendingOptimizer__InvalidParameter.selector);
        optimizer.removeApprovedAsset(0, removeActions);
    }

    function test_lendingOptimizer_removeApprovedAsset_success_afterUpdatingCap() public {
        // Setup with two markets (60% + 50% = 110%).
        // Removing either one would leave < 100%, so we need to updateCap first.
        _setUpTwoMarkets();

        // Deposit to both markets.
        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        optimizer.deposit(10_000e6, address(this), cUSDC_WMON_MARKET);

        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        optimizer.deposit(10_000e6, address(this), cUSDC_WBTC_MARKET);

        // Mock market permissions for all calls.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Get assets in market 1 (cUSDC_WBTC_MARKET) that will be removed.
        uint256 market1Assets = IBorrowableCToken(cUSDC_WBTC_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WBTC_MARKET).balanceOf(address(optimizer))
        );

        // Create remove actions.
        LendingOptimizer.RemoveAction[] memory removeActions = new LendingOptimizer.RemoveAction[](1);
        removeActions[0] = LendingOptimizer.RemoveAction(
            IBorrowableCToken(cUSDC_WMON_MARKET),
            market1Assets
        );

        // First, demonstrate that removal would fail without updating cap.
        // Market 0 has 60% cap, which is < 100%.
        vm.expectRevert(LendingOptimizer.LendingOptimizer__InsufficientAllocationCaps.selector);
        optimizer.removeApprovedAsset(1, removeActions);

        // Now update market 0's cap to 100% (10_000 BPS).
        // updateCap only validates when DECREASING, so increasing is allowed.
        optimizer.updateCap(cUSDC_WMON_MARKET, 10_000);

        // Verify cap was updated.
        assertEq(optimizer.allocationCaps(cUSDC_WMON_MARKET), 10_000 * 1e14, "Cap should be 100%");

        // Now removal should succeed.
        uint256 totalAssetsBefore = optimizer.totalAssets();
        optimizer.removeApprovedAsset(1, removeActions);

        // Verify market was removed.
        assertEq(optimizer.numApprovedMarkets(), 1, "Should have 1 market after removal");
        assertEq(optimizer.allocationCaps(cUSDC_WBTC_MARKET), 0, "Removed market cap should be 0");

        // Verify total assets are preserved.
        uint256 totalAssetsAfter = optimizer.totalAssets();
        assertApproxEqAbs(totalAssetsAfter, totalAssetsBefore, 10, "Total assets should be preserved");
    }

    function test_lendingOptimizer_removeApprovedAsset_success_emitsMarketRemovedEvent() public {
        // Setup with three markets (60% + 50% + 20% caps).
        _setUpThreeMarkets();

        // Deposit to markets so there are assets to reallocate.
        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        optimizer.deposit(10_000e6, address(this), cUSDC_WMON_MARKET);

        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        optimizer.deposit(10_000e6, address(this), cUSDC_WBTC_MARKET);

        deal(USDC_MONAD, address(this), 1_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000e6);
        optimizer.deposit(1_000e6, address(this), cUSDC_WETH_MARKET);

        // Get assets in market 2 for reallocation.
        uint256 market2Assets = IBorrowableCToken(cUSDC_WETH_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WETH_MARKET).balanceOf(address(optimizer))
        );

        LendingOptimizer.RemoveAction[] memory removeActions = new LendingOptimizer.RemoveAction[](1);
        removeActions[0] = LendingOptimizer.RemoveAction(
            IBorrowableCToken(cUSDC_WMON_MARKET),
            market2Assets
        );

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Expect the MarketRemoved event with the correct cToken address.
        vm.expectEmit(true, false, false, false, address(optimizer));
        emit LendingOptimizer.MarketRemoved(cUSDC_WETH_MARKET);

        optimizer.removeApprovedAsset(2, removeActions);
    }

    function test_lendingOptimizer_removeApprovedAsset_fail_whenRemainingCapsUnder100() public {
        // Setup with two markets (60% + 50% = 110%).
        // Removing either one leaves remaining cap < 100%.
        _setUpTwoMarkets();

        // Deposit to both markets.
        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        optimizer.deposit(10_000e6, address(this), cUSDC_WMON_MARKET);

        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        optimizer.deposit(10_000e6, address(this), cUSDC_WBTC_MARKET);

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Try to remove market 0 (60% cap), leaving only market 1 (50% cap).
        uint256 market0Assets = IBorrowableCToken(cUSDC_WMON_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer))
        );

        LendingOptimizer.RemoveAction[] memory removeActions = new LendingOptimizer.RemoveAction[](1);
        removeActions[0] = LendingOptimizer.RemoveAction(
            IBorrowableCToken(cUSDC_WBTC_MARKET),
            market0Assets
        );

        // Should revert because remaining cap (50%) < 100%.
        vm.expectRevert(LendingOptimizer.LendingOptimizer__InsufficientAllocationCaps.selector);
        optimizer.removeApprovedAsset(0, removeActions);

        // Also try removing market 1 (50% cap), leaving only market 0 (60% cap).
        uint256 market1Assets = IBorrowableCToken(cUSDC_WBTC_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WBTC_MARKET).balanceOf(address(optimizer))
        );

        removeActions[0] = LendingOptimizer.RemoveAction(
            IBorrowableCToken(cUSDC_WMON_MARKET),
            market1Assets
        );

        // Should also revert because remaining cap (60%) < 100%.
        vm.expectRevert(LendingOptimizer.LendingOptimizer__InsufficientAllocationCaps.selector);
        optimizer.removeApprovedAsset(1, removeActions);
    }
}
