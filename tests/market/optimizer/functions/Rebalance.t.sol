// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { LendingOptimizerHarness } from "../LendingOptimizerHarness.sol";
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
        LendingOptimizer.ReallocationAction[] memory actions = new LendingOptimizer.ReallocationAction[](3);
        actions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WMON_MARKET),
            int256(withdrawAmount)  // deposit
        );
        actions[1] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WBTC_MARKET),
            int256(0)  // no action
        );
        actions[2] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WETH_MARKET),
            -int256(withdrawAmount)  // withdraw
        );

        // Mock harvest permissions for this test contract.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasHarvestPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Execute rebalance.
        _rebalance(optimizer, actions, _unconstrainedBounds());

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

        LendingOptimizer.ReallocationAction[] memory actions = new LendingOptimizer.ReallocationAction[](3);
        actions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WMON_MARKET),
            -int256(transferAmount)  // withdraw from Market 0
        );
        actions[1] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WBTC_MARKET),
            int256(0)  // no action
        );
        actions[2] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WETH_MARKET),
            int256(transferAmount)  // deposit to Market 2 (will exceed 20% cap)
        );

        // Mock harvest permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasHarvestPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Expect revert with AllocationExceedsCap error.
        LendingOptimizer.AllocationBound[] memory bounds = _unconstrainedBounds();
        (address[] memory sq, address[] memory wq) = _currentQueues(optimizer);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__AllocationExceedsCap.selector);
        optimizer.rebalance(actions, bounds, sq, wq);
    }

    function test_lendingOptimizer_rebalance_fail_whenUnauthorized() public {
        _depositToAllMarkets(10_000e6);

        LendingOptimizer.ReallocationAction[] memory actions = new LendingOptimizer.ReallocationAction[](3);
        actions[0] = LendingOptimizer.ReallocationAction(IBorrowableCToken(cUSDC_WMON_MARKET), int256(0));
        actions[1] = LendingOptimizer.ReallocationAction(IBorrowableCToken(cUSDC_WBTC_MARKET), int256(0));
        actions[2] = LendingOptimizer.ReallocationAction(IBorrowableCToken(cUSDC_WETH_MARKET), int256(0));

        // Mock harvest permissions to return false (unauthorized).
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasHarvestPermissions.selector, address(this)),
            abi.encode(false)
        );

        LendingOptimizer.AllocationBound[] memory bounds = _unconstrainedBounds();
        (address[] memory sq, address[] memory wq) = _currentQueues(optimizer);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__Unauthorized.selector);
        optimizer.rebalance(actions, bounds, sq, wq);
    }

    function test_lendingOptimizer_rebalance_fail_whenArrayLengthMismatch() public {
        _depositToAllMarkets(10_000e6);

        // Create actions array with wrong length (2 instead of 3).
        LendingOptimizer.ReallocationAction[] memory actions = new LendingOptimizer.ReallocationAction[](2);
        actions[0] = LendingOptimizer.ReallocationAction(IBorrowableCToken(cUSDC_WMON_MARKET), int256(0));
        actions[1] = LendingOptimizer.ReallocationAction(IBorrowableCToken(cUSDC_WBTC_MARKET), int256(0));

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasHarvestPermissions.selector, address(this)),
            abi.encode(true)
        );

        LendingOptimizer.AllocationBound[] memory bounds = _unconstrainedBounds();
        (address[] memory sq, address[] memory wq) = _currentQueues(optimizer);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__ArrayLengthMismatch.selector);
        optimizer.rebalance(actions, bounds, sq, wq);
    }

    function test_lendingOptimizer_rebalance_fail_whenInvalidMarketOrder() public {
        _depositToAllMarkets(10_000e6);

        // Create actions with wrong market order (swapped index 1 and 2).
        LendingOptimizer.ReallocationAction[] memory actions = new LendingOptimizer.ReallocationAction[](3);
        actions[0] = LendingOptimizer.ReallocationAction(IBorrowableCToken(cUSDC_WMON_MARKET), int256(0));
        actions[1] = LendingOptimizer.ReallocationAction(IBorrowableCToken(cUSDC_WETH_MARKET), int256(0));  // Wrong: should be WBTC
        actions[2] = LendingOptimizer.ReallocationAction(IBorrowableCToken(cUSDC_WBTC_MARKET), int256(0));  // Wrong: should be WETH

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasHarvestPermissions.selector, address(this)),
            abi.encode(true)
        );

        LendingOptimizer.AllocationBound[] memory bounds = _unconstrainedBounds();
        (address[] memory sq, address[] memory wq) = _currentQueues(optimizer);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__InvalidParameter.selector);
        optimizer.rebalance(actions, bounds, sq, wq);
    }

    /// @notice Verifies that rebalance adjusts _totalAssets for rounding loss,
    ///         preventing false bad debt detection on subsequent accruals.
    function test_lendingOptimizer_rebalance_roundingLossDoesNotTriggerBadDebt() public {
        // Use a two-market setup with 100% caps to avoid allocation cap issues.
        // This test focuses on rounding loss, not cap validation.
        address[] memory approvedCTokens = new address[](2);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](2);
        allocationCapsBps[0] = 10_000; // 100%
        allocationCapsBps[1] = 10_000; // 100%

        LendingOptimizerHarness testOptimizer = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000 // 10% fee
        );

        // Initialize the optimizer.
        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(testOptimizer), initAssets);
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
        testOptimizer.initializeDeposits(cUSDC_WMON_MARKET);

        // Deposit 10k to each market via harness.
        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(testOptimizer), 10_000e6);
        testOptimizer.depositToMarket(10_000e6, address(this), cUSDC_WMON_MARKET);

        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(testOptimizer), 10_000e6);
        testOptimizer.depositToMarket(10_000e6, address(this), cUSDC_WBTC_MARKET);

        uint256 totalAssetsBefore = testOptimizer.totalAssets();
        uint256 totalSupplyBefore = testOptimizer.totalSupply();
        uint256 exchangeRateBefore = testOptimizer.exchangeRate();

        // Mock harvest permissions for rebalancing.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasHarvestPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Perform multiple rebalances to accumulate potential rounding losses.
        // Each rebalance moves assets between markets, potentially losing 1 wei per deposit.
        for (uint256 i = 0; i < 5; i++) {
            uint256 transferAmount = 1_000e6;

            LendingOptimizer.ReallocationAction[] memory actions = new LendingOptimizer.ReallocationAction[](2);
            actions[0] = LendingOptimizer.ReallocationAction(
                IBorrowableCToken(cUSDC_WMON_MARKET),
                int256(transferAmount)  // deposit
            );
            actions[1] = LendingOptimizer.ReallocationAction(
                IBorrowableCToken(cUSDC_WBTC_MARKET),
                -int256(transferAmount)  // withdraw
            );

            LendingOptimizer.AllocationBound[] memory bounds = new LendingOptimizer.AllocationBound[](2);
            bounds[0] = LendingOptimizer.AllocationBound({ minBps: 0, maxBps: 10000 });
            bounds[1] = LendingOptimizer.AllocationBound({ minBps: 0, maxBps: 10000 });
            _rebalance(testOptimizer, actions, bounds);
        }

        // Key test: Call exchangeRateUpdated which internally calls _accrueIfNeeded.
        // If _totalAssets wasn't properly adjusted for rounding loss, this would
        // detect rawTa < totalAssets and trigger bad debt handling, which clears vesting.
        // Instead, it should work normally.
        uint256 exchangeRateAfter = testOptimizer.exchangeRateUpdated();

        // Total assets may be slightly less due to accumulated rounding (up to 5 wei for 5 rebalances).
        uint256 totalAssetsAfter = testOptimizer.totalAssets();
        assertApproxEqAbs(totalAssetsAfter, totalAssetsBefore, 10, "Total assets should be ~preserved");

        // Total supply should be unchanged (no shares minted/burned during rebalance).
        uint256 totalSupplyAfter = testOptimizer.totalSupply();
        assertEq(totalSupplyAfter, totalSupplyBefore, "Total supply should be unchanged");

        // Exchange rate should be approximately preserved (may decrease slightly due to rounding loss).
        assertApproxEqRel(exchangeRateAfter, exchangeRateBefore, 0.0001e18, "Exchange rate should be ~preserved");

        // Verify the optimizer still functions normally - users can deposit and withdraw.
        deal(USDC_MONAD, address(this), 1_000e6);
        IERC20(USDC_MONAD).approve(address(testOptimizer), 1_000e6);
        uint256 shares = testOptimizer.deposit(1_000e6, address(this));
        assertGt(shares, 0, "Should be able to deposit after rebalance");

        // Withdraw should also work.
        uint256 assets = testOptimizer.redeem(shares / 2, address(this), address(this));
        assertGt(assets, 0, "Should be able to redeem after rebalance");
    }

    function test_lendingOptimizer_rebalance_fail_whenAssetMismatch() public {
        // Deposit to all markets equally.
        _depositToAllMarkets(10_000e6);

        // Create rebalance actions where withdrawal != deposit amounts.
        // Withdraw 2000 from Market 2 but only deposit 1000 to Market 0.
        LendingOptimizer.ReallocationAction[] memory actions = new LendingOptimizer.ReallocationAction[](3);
        actions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WMON_MARKET),
            int256(1_000e6)  // deposit 1000
        );
        actions[1] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WBTC_MARKET),
            int256(0)  // no action
        );
        actions[2] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WETH_MARKET),
            -int256(2_000e6)  // withdraw 2000
        );

        // Mock harvest permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasHarvestPermissions.selector, address(this)),
            abi.encode(true)
        );

        // sumDeclaredWithdrawals (2000) != sumDeclaredReallocated (1000)
        LendingOptimizer.AllocationBound[] memory bounds = _unconstrainedBounds();
        (address[] memory sq, address[] memory wq) = _currentQueues(optimizer);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__AssetMismatch.selector);
        optimizer.rebalance(actions, bounds, sq, wq);
    }

    function test_lendingOptimizer_rebalance_success_emitsRebalancedEvent() public {
        // Deposit to all markets equally to create an imbalance.
        _depositToAllMarkets(10_000e6);

        uint256 totalAssetsBefore = optimizer.totalAssets();

        // Bring Market 2 under its 20% cap by moving assets to Market 0.
        uint256 market2Assets = IBorrowableCToken(cUSDC_WETH_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WETH_MARKET).balanceOf(address(optimizer))
        );
        uint256 market2Target = (totalAssetsBefore * 20) / 100;
        uint256 transferAmount = market2Assets - market2Target;

        LendingOptimizer.ReallocationAction[] memory actions = new LendingOptimizer.ReallocationAction[](3);
        actions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WMON_MARKET),
            int256(transferAmount)  // deposit
        );
        actions[1] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WBTC_MARKET),
            int256(0)  // no action
        );
        actions[2] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WETH_MARKET),
            -int256(transferAmount)  // withdraw
        );

        // Mock harvest permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasHarvestPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Expect the Rebalanced event.
        // We check topic1 (totalAssets) and topic2 (markets) and topic3 (allocations)
        // are emitted without checking exact data values.
        vm.expectEmit(false, false, false, false, address(optimizer));
        emit LendingOptimizer.Rebalanced(0, new address[](0), new uint256[](0));

        _rebalance(optimizer, actions, _unconstrainedBounds());
    }

    /// @notice Tests that rebalance reverts when final allocation exceeds market caps.
    function test_lendingOptimizer_rebalance_fail_whenAllocationExceedsCap() public {
        // Deposit to all markets equally. This puts market 2 at 33% allocation,
        // which already exceeds its 20% cap.
        _depositToAllMarkets(10_000e6);

        uint256 transferAmount = 1_000e6;

        // Attempt to rebalance - even though we withdraw from market 2,
        // it will still be over its 20% cap after the rebalance.
        LendingOptimizer.ReallocationAction[] memory actions = new LendingOptimizer.ReallocationAction[](3);
        actions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WMON_MARKET),
            int256(transferAmount)
        );
        actions[1] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WBTC_MARKET),
            int256(0)
        );
        actions[2] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WETH_MARKET),
            -int256(transferAmount)
        );

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasHarvestPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Reverts because market 2's allocation (~30%) exceeds its 20% cap.
        LendingOptimizer.AllocationBound[] memory bounds = _unconstrainedBounds();
        (address[] memory sq, address[] memory wq) = _currentQueues(optimizer);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__AllocationExceedsCap.selector);
        optimizer.rebalance(actions, bounds, sq, wq);
    }

    function test_lendingOptimizer_rebalance_revert_withdrawalBelowMinReallocation() public {
        _depositToAllMarkets(10_000e6);

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasHarvestPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Build actions with a withdrawal amount below MIN_REALLOCATION_AMOUNT.
        LendingOptimizer.ReallocationAction[] memory actions = new LendingOptimizer.ReallocationAction[](3);
        actions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WMON_MARKET), int256(0)
        );
        actions[1] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WBTC_MARKET), optimizer.MIN_REALLOCATION_AMOUNT() - 1
        );
        actions[2] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WETH_MARKET), int256(0)
        );

        LendingOptimizer.AllocationBound[] memory bounds = _unconstrainedBounds();
        (address[] memory sq, address[] memory wq) = _currentQueues(optimizer);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__InvalidParameter.selector);
        optimizer.rebalance(actions, bounds, sq, wq);
    }

    // ============ Allocation Bounds Tests ============

    /// @notice A deposit between off-chain computation and on-chain execution
    ///         shifts allocations outside the bounds, causing revert.
    function test_lendingOptimizer_rebalance_revert_boundsViolatedByDeposit() public {
        // Use a 2-market setup with 100% caps so _verifyAllocationCaps never
        // fires and bounds become the sole protection layer.
        address[] memory approvedCTokens = new address[](2);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;

        uint256[] memory caps = new uint256[](2);
        caps[0] = 10_000; // 100%
        caps[1] = 10_000; // 100%

        LendingOptimizerHarness testOpt = new LendingOptimizerHarness(
            IERC20(USDC_MONAD), liveCentralRegistry, approvedCTokens, caps, 0
        );

        // Initialize and deposit 50/50.
        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(testOpt), initAssets);
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
        testOpt.initializeDeposits(cUSDC_WMON_MARKET);

        deal(USDC_MONAD, address(this), 40_000e6);
        IERC20(USDC_MONAD).approve(address(testOpt), 40_000e6);
        testOpt.depositToMarket(20_000e6, address(this), cUSDC_WMON_MARKET);
        testOpt.depositToMarket(20_000e6, address(this), cUSDC_WBTC_MARKET);

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasHarvestPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Harvester computes a no-op rebalance expecting ~50/50.
        LendingOptimizer.ReallocationAction[] memory actions = new LendingOptimizer.ReallocationAction[](2);
        actions[0] = LendingOptimizer.ReallocationAction(IBorrowableCToken(cUSDC_WMON_MARKET), int256(0));
        actions[1] = LendingOptimizer.ReallocationAction(IBorrowableCToken(cUSDC_WBTC_MARKET), int256(0));

        // Tight bounds: 48%-52% each.
        LendingOptimizer.AllocationBound[] memory bounds = new LendingOptimizer.AllocationBound[](2);
        bounds[0] = LendingOptimizer.AllocationBound({ minBps: 4800, maxBps: 5200 });
        bounds[1] = LendingOptimizer.AllocationBound({ minBps: 4800, maxBps: 5200 });

        // Frontrunner deposits 40k into market 0, skewing to ~75/25.
        address frontrunner = address(0xBEEF);
        deal(USDC_MONAD, frontrunner, 40_000e6);
        vm.startPrank(frontrunner);
        IERC20(USDC_MONAD).approve(address(testOpt), 40_000e6);
        testOpt.depositToMarket(40_000e6, frontrunner, cUSDC_WMON_MARKET);
        vm.stopPrank();

        // Rebalance reverts — the deposit shifted allocations outside bounds.
        (address[] memory sq, address[] memory wq) = _currentQueues(testOpt);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__AllocationOutOfBounds.selector);
        testOpt.rebalance(actions, bounds, sq, wq);
    }

    /// @notice A withdrawal between off-chain computation and on-chain execution
    ///         shifts allocations outside the bounds, causing revert.
    function test_lendingOptimizer_rebalance_revert_boundsViolatedByWithdrawal() public {
        // Use a 2-market setup with 100% caps.
        address[] memory approvedCTokens = new address[](2);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;

        uint256[] memory caps = new uint256[](2);
        caps[0] = 10_000;
        caps[1] = 10_000;

        LendingOptimizerHarness testOpt = new LendingOptimizerHarness(
            IERC20(USDC_MONAD), liveCentralRegistry, approvedCTokens, caps, 0
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(testOpt), initAssets);
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
        testOpt.initializeDeposits(cUSDC_WMON_MARKET);

        deal(USDC_MONAD, address(this), 40_000e6);
        IERC20(USDC_MONAD).approve(address(testOpt), 40_000e6);
        testOpt.depositToMarket(20_000e6, address(this), cUSDC_WMON_MARKET);
        testOpt.depositToMarket(20_000e6, address(this), cUSDC_WBTC_MARKET);

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasHarvestPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Harvester targets no-op, expecting ~50/50.
        LendingOptimizer.ReallocationAction[] memory actions = new LendingOptimizer.ReallocationAction[](2);
        actions[0] = LendingOptimizer.ReallocationAction(IBorrowableCToken(cUSDC_WMON_MARKET), int256(0));
        actions[1] = LendingOptimizer.ReallocationAction(IBorrowableCToken(cUSDC_WBTC_MARKET), int256(0));

        // Tight bounds: 48%-52% each.
        LendingOptimizer.AllocationBound[] memory bounds = new LendingOptimizer.AllocationBound[](2);
        bounds[0] = LendingOptimizer.AllocationBound({ minBps: 4800, maxBps: 5200 });
        bounds[1] = LendingOptimizer.AllocationBound({ minBps: 4800, maxBps: 5200 });

        // User withdraws 80% — multi-market drains worst-yield first,
        // skewing per-market allocations away from 50/50.
        uint256 shares = testOpt.balanceOf(address(this));
        testOpt.redeem(shares * 80 / 100, address(this), address(this));

        // Rebalance reverts — allocations shifted outside tight bounds.
        (address[] memory sq, address[] memory wq) = _currentQueues(testOpt);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__AllocationOutOfBounds.selector);
        testOpt.rebalance(actions, bounds, sq, wq);
    }

    /// @notice Bounds that match the post-rebalance state succeed.
    function test_lendingOptimizer_rebalance_success_exactBoundsPass() public {
        // Deposit respecting caps: 50% / 40% / 10%.
        deal(USDC_MONAD, address(this), 50_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 50_000e6);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(25_000e6, address(this), cUSDC_WMON_MARKET);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(20_000e6, address(this), cUSDC_WBTC_MARKET);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(5_000e6, address(this), cUSDC_WETH_MARKET);

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasHarvestPermissions.selector, address(this)),
            abi.encode(true)
        );

        // No-op rebalance.
        LendingOptimizer.ReallocationAction[] memory actions = new LendingOptimizer.ReallocationAction[](3);
        actions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WMON_MARKET), int256(0)
        );
        actions[1] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WBTC_MARKET), int256(0)
        );
        actions[2] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WETH_MARKET), int256(0)
        );

        // Wide bounds that comfortably fit ~50/40/10.
        LendingOptimizer.AllocationBound[] memory bounds = new LendingOptimizer.AllocationBound[](3);
        bounds[0] = LendingOptimizer.AllocationBound({ minBps: 4500, maxBps: 5500 });
        bounds[1] = LendingOptimizer.AllocationBound({ minBps: 3500, maxBps: 4500 });
        bounds[2] = LendingOptimizer.AllocationBound({ minBps: 500, maxBps: 1500 });

        // Should succeed — no state change, allocations within bounds.
        _rebalance(optimizer, actions, bounds);
    }

    /// @notice Bounds array length mismatch reverts.
    function test_lendingOptimizer_rebalance_revert_boundsLengthMismatch() public {
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasHarvestPermissions.selector, address(this)),
            abi.encode(true)
        );

        LendingOptimizer.ReallocationAction[] memory actions = new LendingOptimizer.ReallocationAction[](3);
        actions[0] = LendingOptimizer.ReallocationAction(IBorrowableCToken(cUSDC_WMON_MARKET), int256(0));
        actions[1] = LendingOptimizer.ReallocationAction(IBorrowableCToken(cUSDC_WBTC_MARKET), int256(0));
        actions[2] = LendingOptimizer.ReallocationAction(IBorrowableCToken(cUSDC_WETH_MARKET), int256(0));

        // Only 2 bounds for 3 markets.
        LendingOptimizer.AllocationBound[] memory bounds = new LendingOptimizer.AllocationBound[](2);
        bounds[0] = LendingOptimizer.AllocationBound({ minBps: 0, maxBps: 10000 });
        bounds[1] = LendingOptimizer.AllocationBound({ minBps: 0, maxBps: 10000 });

        (address[] memory sq, address[] memory wq) = _currentQueues(optimizer);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__ArrayLengthMismatch.selector);
        optimizer.rebalance(actions, bounds, sq, wq);
    }

    /// @notice Bounds set to zero tolerance revert on any non-exact allocation.
    function test_lendingOptimizer_rebalance_revert_zeroToleranceBounds() public {
        // Deposit respecting caps: 50% / 40% / 10%.
        deal(USDC_MONAD, address(this), 50_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 50_000e6);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(25_000e6, address(this), cUSDC_WMON_MARKET);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(20_000e6, address(this), cUSDC_WBTC_MARKET);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(5_000e6, address(this), cUSDC_WETH_MARKET);

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasHarvestPermissions.selector, address(this)),
            abi.encode(true)
        );

        LendingOptimizer.ReallocationAction[] memory actions = new LendingOptimizer.ReallocationAction[](3);
        actions[0] = LendingOptimizer.ReallocationAction(IBorrowableCToken(cUSDC_WMON_MARKET), int256(0));
        actions[1] = LendingOptimizer.ReallocationAction(IBorrowableCToken(cUSDC_WBTC_MARKET), int256(0));
        actions[2] = LendingOptimizer.ReallocationAction(IBorrowableCToken(cUSDC_WETH_MARKET), int256(0));

        // Impossibly tight: require exactly 5000/4000/1000 BPS.
        // BPS truncation means markets won't hit these exact values.
        LendingOptimizer.AllocationBound[] memory bounds = new LendingOptimizer.AllocationBound[](3);
        bounds[0] = LendingOptimizer.AllocationBound({ minBps: 5000, maxBps: 5000 });
        bounds[1] = LendingOptimizer.AllocationBound({ minBps: 4000, maxBps: 4000 });
        bounds[2] = LendingOptimizer.AllocationBound({ minBps: 1000, maxBps: 1000 });

        (address[] memory sq, address[] memory wq) = _currentQueues(optimizer);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__AllocationOutOfBounds.selector);
        optimizer.rebalance(actions, bounds, sq, wq);
    }
}
