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

contract TestLendingOptimizerRebalance is TestBaseLendingOptimizer {

    function setUp() public override {
        super.setUp();
        _setUpThreeMarkets();
    }

    function test_lendingOptimizer_rebalance_success() public {
        // Deposit to all markets equally to create an imbalance in the allocation caps.
        // After this: each market has ~10,000e6 USDC (33% each).
        // But Market 2 (cUSDC_WETH_MARKET) only has a 20% cap, so it's over-allocated.
        _depositToAllMarkets(10_000e6);

        // Calculate current allocations before rebalance.
        uint256 totalAssetsBefore = optimizer.totalAssets();

        uint256 market0AssetsBefore = IBorrowableCToken(cUSDC_WMON_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer))
        );
        uint256 market1AssetsBefore = IBorrowableCToken(cUSDC_WBTC_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WBTC_MARKET).balanceOf(address(optimizer))
        );
        uint256 market2AssetsBefore = IBorrowableCToken(cUSDC_WETH_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WETH_MARKET).balanceOf(address(optimizer))
        );

        // Calculate target allocation for Market 2 to bring it under 20% cap.
        // Target: 20% of total = totalAssetsBefore * 20 / 100.
        // Current: ~33%. Need to withdraw the excess.
        uint256 market2TargetAssets = (totalAssetsBefore * 20) / 100;
        uint256 withdrawAmount = market2AssetsBefore - market2TargetAssets;

        // Create rebalance actions (must match approvedCTokensList order):
        // Index 0: cUSDC_WMON_MARKET (60% cap) - deposit
        // Index 1: cUSDC_WBTC_MARKET (50% cap) - no action
        // Index 2: cUSDC_WETH_MARKET (20% cap) - withdraw
        LendingOptimizer.RebalanceAction[] memory actions = new LendingOptimizer.RebalanceAction[](3);
        actions[0] = LendingOptimizer.RebalanceAction(
            IBorrowableCToken(cUSDC_WMON_MARKET),
            withdrawAmount,
            0,    // minAssetsOut
            true  // deposit
        );
        actions[1] = LendingOptimizer.RebalanceAction(
            IBorrowableCToken(cUSDC_WBTC_MARKET),
            0,
            0,    // minAssetsOut
            true  // no action (0 assets)
        );
        actions[2] = LendingOptimizer.RebalanceAction(
            IBorrowableCToken(cUSDC_WETH_MARKET),
            withdrawAmount,
            0,     // minAssetsOut
            false  // withdraw
        );

        // Mock harvest permissions for this test contract.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasHarvestPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Execute rebalance.
        optimizer.rebalance(actions);

        // Verify total assets are preserved (allowing for minor rounding).
        uint256 totalAssetsAfter = optimizer.totalAssets();
        assertApproxEqAbs(totalAssetsAfter, totalAssetsBefore, 10, "Total assets should be preserved");

        // Verify Market 0 received the rebalanced assets.
        uint256 market0AssetsAfter = IBorrowableCToken(cUSDC_WMON_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer))
        );
        assertGt(market0AssetsAfter, market0AssetsBefore, "Market 0 should have received assets");

        // Verify Market 1 stayed approximately the same.
        uint256 market1AssetsAfter = IBorrowableCToken(cUSDC_WBTC_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WBTC_MARKET).balanceOf(address(optimizer))
        );
        assertApproxEqAbs(market1AssetsAfter, market1AssetsBefore, 10, "Market 1 should stay the same");

        // Verify Market 2 had assets withdrawn.
        uint256 market2AssetsAfter = IBorrowableCToken(cUSDC_WETH_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WETH_MARKET).balanceOf(address(optimizer))
        );
        assertLt(market2AssetsAfter, market2AssetsBefore, "Market 2 should have less assets");

        // Verify all markets are within their allocation caps.
        uint256 market0Allocation = (market0AssetsAfter * WAD) / totalAssetsAfter;
        uint256 market1Allocation = (market1AssetsAfter * WAD) / totalAssetsAfter;
        uint256 market2Allocation = (market2AssetsAfter * WAD) / totalAssetsAfter;

        uint256 market0Cap = optimizer.allocationCaps(cUSDC_WMON_MARKET);
        uint256 market1Cap = optimizer.allocationCaps(cUSDC_WBTC_MARKET);
        uint256 market2Cap = optimizer.allocationCaps(cUSDC_WETH_MARKET);

        assertLe(market0Allocation, market0Cap, "Market 0 allocation exceeds cap");
        assertLe(market1Allocation, market1Cap, "Market 1 allocation exceeds cap");
        assertLe(market2Allocation, market2Cap, "Market 2 allocation exceeds cap");
    }

    function test_lendingOptimizer_rebalance_fail_whenExceedsCap() public {
        // Deposit to all markets equally.
        _depositToAllMarkets(10_000e6);

        // Try to rebalance in a way that pushes Market 2 (20% cap) over its cap.
        // Withdraw from Market 0 and deposit into Market 2.
        // This would push Market 2 from ~33% to ~50%, exceeding its 20% cap.
        uint256 transferAmount = 5_000e6;

        LendingOptimizer.RebalanceAction[] memory actions = new LendingOptimizer.RebalanceAction[](3);
        actions[0] = LendingOptimizer.RebalanceAction(
            IBorrowableCToken(cUSDC_WMON_MARKET),
            transferAmount,
            0,     // minAssetsOut
            false  // withdraw from Market 0
        );
        actions[1] = LendingOptimizer.RebalanceAction(
            IBorrowableCToken(cUSDC_WBTC_MARKET),
            0,
            0,    // minAssetsOut
            true  // no action
        );
        actions[2] = LendingOptimizer.RebalanceAction(
            IBorrowableCToken(cUSDC_WETH_MARKET),
            transferAmount,
            0,    // minAssetsOut
            true  // deposit to Market 2 (will exceed 20% cap)
        );

        // Mock harvest permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasHarvestPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Expect revert with AllocationExceedsCap error.
        vm.expectRevert(LendingOptimizer.LendingOptimizer__AllocationExceedsCap.selector);
        optimizer.rebalance(actions);
    }

    function test_lendingOptimizer_rebalance_fail_whenUnauthorized() public {
        _depositToAllMarkets(10_000e6);

        LendingOptimizer.RebalanceAction[] memory actions = new LendingOptimizer.RebalanceAction[](3);
        actions[0] = LendingOptimizer.RebalanceAction(IBorrowableCToken(cUSDC_WMON_MARKET), 0, 0, true);
        actions[1] = LendingOptimizer.RebalanceAction(IBorrowableCToken(cUSDC_WBTC_MARKET), 0, 0, true);
        actions[2] = LendingOptimizer.RebalanceAction(IBorrowableCToken(cUSDC_WETH_MARKET), 0, 0, true);

        // Mock harvest permissions to return false (unauthorized).
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasHarvestPermissions.selector, address(this)),
            abi.encode(false)
        );

        vm.expectRevert(LendingOptimizer.LendingOptimizer__Unauthorized.selector);
        optimizer.rebalance(actions);
    }

    function test_lendingOptimizer_rebalance_fail_whenArrayLengthMismatch() public {
        _depositToAllMarkets(10_000e6);

        // Create actions array with wrong length (2 instead of 3).
        LendingOptimizer.RebalanceAction[] memory actions = new LendingOptimizer.RebalanceAction[](2);
        actions[0] = LendingOptimizer.RebalanceAction(IBorrowableCToken(cUSDC_WMON_MARKET), 0, 0, true);
        actions[1] = LendingOptimizer.RebalanceAction(IBorrowableCToken(cUSDC_WBTC_MARKET), 0, 0, true);

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasHarvestPermissions.selector, address(this)),
            abi.encode(true)
        );

        vm.expectRevert(LendingOptimizer.LendingOptimizer__ArrayLengthMismatch.selector);
        optimizer.rebalance(actions);
    }

    function test_lendingOptimizer_rebalance_fail_whenInvalidMarketOrder() public {
        _depositToAllMarkets(10_000e6);

        // Create actions with wrong market order (swapped index 1 and 2).
        LendingOptimizer.RebalanceAction[] memory actions = new LendingOptimizer.RebalanceAction[](3);
        actions[0] = LendingOptimizer.RebalanceAction(IBorrowableCToken(cUSDC_WMON_MARKET), 0, 0, true);
        actions[1] = LendingOptimizer.RebalanceAction(IBorrowableCToken(cUSDC_WETH_MARKET), 0, 0, true);  // Wrong: should be WBTC
        actions[2] = LendingOptimizer.RebalanceAction(IBorrowableCToken(cUSDC_WBTC_MARKET), 0, 0, true);  // Wrong: should be WETH

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasHarvestPermissions.selector, address(this)),
            abi.encode(true)
        );

        vm.expectRevert(LendingOptimizer.LendingOptimizer__InvalidParameter.selector);
        optimizer.rebalance(actions);
    }
}
