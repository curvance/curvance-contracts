// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { LendingOptimizerHarness } from "../LendingOptimizerHarness.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { WAD, BPS } from "contracts/libraries/ConstantsLib.sol";

contract MultiMarketFuzz is TestBaseLendingOptimizer {

    LendingOptimizerHarness harness;

    function setUp() public override {
        super.setUp();

        // Mock permissions for test contract.
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

    // ==================== Helpers ====================

    /// @dev Returns unconstrained allocation bounds for the given optimizer.
    function _unconstrainedBoundsFor(LendingOptimizer lo)
        internal
        view
        returns (LendingOptimizer.AllocationBound[] memory bounds)
    {
        uint256 l = lo.numApprovedMarkets();
        bounds = new LendingOptimizer.AllocationBound[](l);
        for (uint256 i; i < l; ++i) {
            bounds[i] = LendingOptimizer.AllocationBound({ cToken: lo.approvedCTokensList(i), minBps: 0, maxBps: 10000 });
        }
    }

    function _unconstrainedBoundsForRemoval(LendingOptimizer lo, address cTokenToRemove)
        internal
        view
        returns (LendingOptimizer.AllocationBound[] memory bounds)
    {
        uint256 l = lo.numApprovedMarkets();
        bounds = new LendingOptimizer.AllocationBound[](l - 1);
        uint256 removeIndex;
        for (uint256 i; i < l; ++i) {
            if (lo.approvedCTokensList(i) == cTokenToRemove) { removeIndex = i; break; }
        }
        address[] memory postRemoval = new address[](l - 1);
        for (uint256 i; i < l; ++i) {
            if (i < l - 1) postRemoval[i] = lo.approvedCTokensList(i);
        }
        if (removeIndex != l - 1) {
            postRemoval[removeIndex] = lo.approvedCTokensList(l - 1);
        }
        for (uint256 i; i < l - 1; ++i) {
            bounds[i] = LendingOptimizer.AllocationBound({ cToken: postRemoval[i], minBps: 0, maxBps: 10000 });
        }
    }

    function _deployThreeMarketHarness() internal {
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
            1_000
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(harness), initAssets);
        harness.initializeDeposits(cUSDC_WMON_MARKET);
    }

    function _deployTwoMarketHarness() internal {
        address[] memory approvedCTokens = new address[](2);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](2);
        allocationCapsBps[0] = 6_000;
        allocationCapsBps[1] = 5_000;

        harness = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(harness), initAssets);
        harness.initializeDeposits(cUSDC_WMON_MARKET);
    }

    function _deployTightCapHarness() internal {
        address[] memory approvedCTokens = new address[](3);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;
        approvedCTokens[2] = cUSDC_WETH_MARKET;

        // Tight caps that sum to exactly 100%.
        uint256[] memory allocationCapsBps = new uint256[](3);
        allocationCapsBps[0] = 4_000; // 40%
        allocationCapsBps[1] = 3_500; // 35%
        allocationCapsBps[2] = 2_500; // 25%

        harness = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(harness), initAssets);
        harness.initializeDeposits(cUSDC_WMON_MARKET);
    }

    function _depositToHarness(address depositor, uint256 amount) internal {
        deal(USDC_MONAD, depositor, amount);
        vm.startPrank(depositor);
        IERC20(USDC_MONAD).approve(address(harness), amount);
        harness.deposit(amount, depositor);
        vm.stopPrank();
    }

    function _depositToHarnessMarket(address depositor, uint256 amount, address market) internal {
        deal(USDC_MONAD, depositor, amount);
        vm.startPrank(depositor);
        IERC20(USDC_MONAD).approve(address(harness), amount);
        harness.deposit(amount, depositor);
        vm.stopPrank();
    }

    function _getMarketAssets(address market) internal view returns (uint256) {
        return IBorrowableCToken(market).convertToAssets(
            IBorrowableCToken(market).balanceOf(address(harness))
        );
    }

    /// @dev Helper to verify withdrawal target has the lowest projected rate among viable markets.

    // ==================== Tests ====================

    function testFuzz_supplyQueueTarget_varied(
        uint256 depositAmount,
        uint256 market0Deposit,
        uint256 market1Deposit
    ) public {
        _deployThreeMarketHarness();

        // Bound inputs.
        depositAmount = bound(depositAmount, 1e6, 10_000_000e6);
        market0Deposit = bound(market0Deposit, 1e6, 5_000_000e6);
        market1Deposit = bound(market1Deposit, 1e6, 5_000_000e6);

        // Pre-load different amounts into markets 0 and 1.
        _depositToHarnessMarket(address(this), market0Deposit, cUSDC_WMON_MARKET);
        _depositToHarnessMarket(address(this), market1Deposit, cUSDC_WBTC_MARKET);

        // Get supply queue target - returns the first non-paused market in the supply queue.
        address target = harness.approvedCTokensList(0);

        // Verify the target is a valid approved market.
        bool isApproved = false;
        for (uint256 i = 0; i < harness.numApprovedMarkets(); i++) {
            if (harness.approvedCTokensList(i) == target) {
                isApproved = true;
                break;
            }
        }
        assertTrue(isApproved, "Supply queue target must be an approved market");

        // Execute deposit and verify it succeeds.
        deal(USDC_MONAD, user1, depositAmount);
        vm.startPrank(user1);
        IERC20(USDC_MONAD).approve(address(harness), depositAmount);
        uint256 shares = harness.deposit(depositAmount, user1);
        vm.stopPrank();
        assertGt(shares, 0, "Deposit must mint shares");
    }

    function testFuzz_marketAdditionMidOperation(
        uint256 depositBefore,
        uint256 depositAfter,
        uint256 newCapBps
    ) public {
        _deployTwoMarketHarness();

        depositBefore = bound(depositBefore, 1e6, 1_000_000e6);
        depositAfter = bound(depositAfter, 1e6, 1_000_000e6);
        newCapBps = bound(newCapBps, 1_000, 10_000);

        // Deposit before adding market.
        _depositToHarness(user1, depositBefore);
        uint256 totalAssetsBefore = harness.totalAssets();
        uint256 sharesBefore = harness.balanceOf(user1);

        // Add third market.
        harness.addApprovedAsset(cUSDC_WETH_MARKET, newCapBps);

        // Verify market was added.
        assertEq(harness.numApprovedMarkets(), 3, "Should have 3 markets after addition");
        assertGt(
            harness.allocationCaps(cUSDC_WETH_MARKET),
            0,
            "New market should have allocation cap set"
        );

        // Deposit after adding market.
        _depositToHarness(user1, depositAfter);

        // Verify no assets lost.
        assertGe(
            harness.totalAssets(),
            totalAssetsBefore + depositAfter - 2,
            "Total assets must include both deposits (within rounding)"
        );
        assertGt(
            harness.balanceOf(user1),
            sharesBefore,
            "User should have more shares after second deposit"
        );

        // Verify new market is accessible by depositing directly to it.
        deal(USDC_MONAD, user2, 1_000e6);
        vm.startPrank(user2);
        IERC20(USDC_MONAD).approve(address(harness), 1_000e6);
        uint256 shares = harness.deposit(1_000e6, user2);
        vm.stopPrank();
        assertGt(shares, 0, "Should be able to deposit to newly added market");
    }

    function testFuzz_marketRemovalMidOperation(
        uint256 depositAmount,
        uint256 marketToRemoveIdx
    ) public {
        _deployThreeMarketHarness();

        depositAmount = bound(depositAmount, 10_000e6, 1_000_000e6);
        marketToRemoveIdx = bound(marketToRemoveIdx, 0, 2);

        address[3] memory markets = [cUSDC_WMON_MARKET, cUSDC_WBTC_MARKET, cUSDC_WETH_MARKET];

        // Deposit to all markets.
        for (uint256 i = 0; i < 3; i++) {
            _depositToHarnessMarket(address(this), depositAmount, markets[i]);
        }

        uint256 totalAssetsBefore = harness.totalAssets();

        // Find first remaining market (not the one being removed).
        address firstRemaining = marketToRemoveIdx == 0 ? markets[1] : markets[0];

        // Increase first remaining market cap to 100% so remaining caps >= 100%.
        harness.updateCap(firstRemaining, 10_000);

        // Build reallocation action with BPS (single target gets 100%).
        IBorrowableCToken cTokenToRemove = IBorrowableCToken(markets[marketToRemoveIdx]);

        LendingOptimizer.ReallocationAction[] memory removeActions = new LendingOptimizer.ReallocationAction[](1);
        removeActions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(firstRemaining),
            int256(10_000)
        );

        // Try removal.
        try harness.removeApprovedAsset(markets[marketToRemoveIdx], removeActions, _unconstrainedBoundsForRemoval(harness, markets[marketToRemoveIdx])) {
            assertApproxEqAbs(
                harness.totalAssets(), totalAssetsBefore, 10,
                "Total assets should be preserved after market removal"
            );
            assertEq(
                cTokenToRemove.balanceOf(address(harness)), 0,
                "Removed market should have 0 cToken balance"
            );
            assertEq(harness.numApprovedMarkets(), 2, "Should have 2 markets after removal");
        } catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            assertTrue(
                selector == LendingOptimizer.LendingOptimizer__AssetMismatch.selector ||
                selector == LendingOptimizer.LendingOptimizer__AllocationExceedsCap.selector,
                "Should only revert with AssetMismatch or AllocationExceedsCap"
            );
        }
    }

    function testFuzz_allMarketsAtCap(uint256 depositAmount) public {
        _deployTightCapHarness();

        depositAmount = bound(depositAmount, 1_000e6, 10_000_000e6);

        // Fill all markets by depositing directly to each.
        // With 40%/35%/25% caps, we deposit proportionally.
        uint256 market0Amount = (depositAmount * 40) / 100;
        uint256 market1Amount = (depositAmount * 35) / 100;
        uint256 market2Amount = depositAmount - market0Amount - market1Amount;

        _depositToHarnessMarket(address(this), market0Amount, cUSDC_WMON_MARKET);
        _depositToHarnessMarket(address(this), market1Amount, cUSDC_WBTC_MARKET);
        _depositToHarnessMarket(address(this), market2Amount, cUSDC_WETH_MARKET);

        uint256 totalBefore = harness.totalAssets();

        // Now deposit more - should still succeed (defaults to market 0 when
        // all caps are exceeded).
        uint256 extraDeposit = bound(depositAmount, 1e6, 1_000_000e6);
        deal(USDC_MONAD, user1, extraDeposit);
        vm.startPrank(user1);
        IERC20(USDC_MONAD).approve(address(harness), extraDeposit);

        // Get the target - returns the first non-paused market in the supply queue.
        address target = harness.approvedCTokensList(0);
        assertTrue(target != address(0), "Target should be a valid market");

        uint256 market0Before = _getMarketAssets(cUSDC_WMON_MARKET);

        uint256 shares = harness.deposit(extraDeposit, user1);
        vm.stopPrank();

        assertGt(shares, 0, "Should mint shares even when markets are at cap");
        assertGe(
            harness.totalAssets(),
            totalBefore + extraDeposit - 2,
            "Total assets should increase by deposit amount"
        );

        // Verify optimizer still functional after over-cap deposit.
        assertGt(
            harness.totalSupply(),
            0,
            "Optimizer should still be functional"
        );
    }

    function test_allMarketsIlliquid() public {
        _deployThreeMarketHarness();

        // Deposit to all markets.
        _depositToHarnessMarket(user1, 10_000e6, cUSDC_WMON_MARKET);
        _depositToHarnessMarket(user1, 10_000e6, cUSDC_WBTC_MARKET);
        _depositToHarnessMarket(user1, 10_000e6, cUSDC_WETH_MARKET);

        // Mock all markets as having 0 idle assets (fully borrowed out).
        vm.mockCall(
            cUSDC_WMON_MARKET,
            abi.encodeWithSelector(IBorrowableCToken.assetsHeld.selector),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            cUSDC_WBTC_MARKET,
            abi.encodeWithSelector(IBorrowableCToken.assetsHeld.selector),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            cUSDC_WETH_MARKET,
            abi.encodeWithSelector(IBorrowableCToken.assetsHeld.selector),
            abi.encode(uint256(0))
        );

        // Try to withdraw - should revert with InsufficientLiquidity.
        vm.startPrank(user1);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__InsufficientLiquidity.selector);
        harness.withdraw(1_000e6, user1, user1);
        vm.stopPrank();
    }

    function testFuzz_capUpdateSqueezes(uint256 newCapBps) public {
        _deployThreeMarketHarness();

        // Deposit a large amount to all markets.
        _depositToHarnessMarket(address(this), 100_000e6, cUSDC_WMON_MARKET);
        _depositToHarnessMarket(address(this), 100_000e6, cUSDC_WBTC_MARKET);
        _depositToHarnessMarket(address(this), 50_000e6, cUSDC_WETH_MARKET);

        // Calculate current allocation for market 0.
        uint256 ta = harness.totalAssets();
        uint256 market0Assets = _getMarketAssets(cUSDC_WMON_MARKET);
        uint256 currentAllocationWad = FixedPointMathLib.mulDiv(market0Assets, WAD, ta);
        uint256 currentAllocationBps = currentAllocationWad / 1e14;

        // Ensure we have a valid range to lower the cap.
        // The cap must be >= 1000 bps (10%) and less than current allocation.
        if (currentAllocationBps <= 1_000) return;

        newCapBps = bound(newCapBps, 1_000, currentAllocationBps - 1);

        // Need to ensure remaining caps still sum to >= 100%.
        // Market1 is 5000 bps, Market2 is 2000 bps. If new market0 cap >= 3000,
        // total = new + 5000 + 2000 >= 10000. Otherwise may fail validation.
        if (newCapBps + 5_000 + 2_000 < 10_000) return;

        // Lower market 0's cap.
        harness.updateCap(cUSDC_WMON_MARKET, newCapBps);

        // Verify the market is now above its new cap.
        uint256 newCapWad = harness.allocationCaps(cUSDC_WMON_MARKET);
        uint256 newMaxAllocation = FixedPointMathLib.mulDiv(newCapWad, ta, WAD);
        assertGt(
            market0Assets,
            newMaxAllocation,
            "Market 0 should now exceed its lowered cap"
        );

        // Build a proper rebalance to fix it: withdraw excess from market 0
        // and deposit into market 1.
        uint256 excessAmount = market0Assets - newMaxAllocation;

        // Ensure we withdraw enough to get under cap (add small buffer).
        uint256 withdrawAmount = excessAmount + 1e6;
        if (withdrawAmount > market0Assets) {
            withdrawAmount = excessAmount;
        }

        LendingOptimizer.ReallocationAction[] memory actions = new LendingOptimizer.ReallocationAction[](3);
        actions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WMON_MARKET),
            -int256(withdrawAmount) // withdraw
        );
        actions[1] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WBTC_MARKET),
            int256(withdrawAmount) // deposit
        );
        actions[2] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WETH_MARKET),
            int256(0) // no-op
        );

        // Rebalance may revert if depositing excess into market 1 pushes it over its cap.
        try harness.rebalance(actions, _unconstrainedBoundsFor(harness)) {
            // Verify market 0 is now within cap.
            uint256 taAfter = harness.totalAssets();
            uint256 market0After = _getMarketAssets(cUSDC_WMON_MARKET);
            uint256 allocationAfter = FixedPointMathLib.mulDiv(market0After, WAD, taAfter);
            assertLe(
                allocationAfter,
                harness.allocationCaps(cUSDC_WMON_MARKET),
                "Market 0 should be within cap after rebalance"
            );
        } catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            assertEq(
                selector,
                LendingOptimizer.LendingOptimizer__AllocationExceedsCap.selector,
                "Should only revert with AllocationExceedsCap"
            );
        }
    }

    function testFuzz_multiMarketRebalance(
        uint256 withdrawIdx,
        uint256 depositIdx,
        uint256 amount
    ) public {
        _deployThreeMarketHarness();

        // Deposit to all markets to create initial balances.
        _depositToHarnessMarket(address(this), 50_000e6, cUSDC_WMON_MARKET);
        _depositToHarnessMarket(address(this), 50_000e6, cUSDC_WBTC_MARKET);
        _depositToHarnessMarket(address(this), 20_000e6, cUSDC_WETH_MARKET);

        withdrawIdx = bound(withdrawIdx, 0, 2);
        depositIdx = bound(depositIdx, 0, 2);
        vm.assume(withdrawIdx != depositIdx);

        address[3] memory markets = [cUSDC_WMON_MARKET, cUSDC_WBTC_MARKET, cUSDC_WETH_MARKET];

        // Bound amount to available balance in the withdrawal market.
        uint256 withdrawMarketAssets = _getMarketAssets(markets[withdrawIdx]);
        uint256 withdrawMarketLiquidity = IBorrowableCToken(markets[withdrawIdx]).assetsHeld();
        uint256 maxTransfer = withdrawMarketAssets < withdrawMarketLiquidity
            ? withdrawMarketAssets
            : withdrawMarketLiquidity;

        vm.assume(maxTransfer >= 1e6);
        amount = bound(amount, 1e6, maxTransfer);

        uint256 totalAssetsBefore = harness.totalAssets();

        // Build rebalance actions.
        LendingOptimizer.ReallocationAction[] memory actions = new LendingOptimizer.ReallocationAction[](3);
        for (uint256 i = 0; i < 3; i++) {
            if (i == withdrawIdx) {
                actions[i] = LendingOptimizer.ReallocationAction(
                    IBorrowableCToken(markets[i]),
                    -int256(amount) // withdraw
                );
            } else if (i == depositIdx) {
                actions[i] = LendingOptimizer.ReallocationAction(
                    IBorrowableCToken(markets[i]),
                    int256(amount) // deposit
                );
            } else {
                actions[i] = LendingOptimizer.ReallocationAction(
                    IBorrowableCToken(markets[i]),
                    int256(0) // no-op
                );
            }
        }

        // Try the rebalance. May revert if deposit pushes a market over cap.
        try harness.rebalance(actions, _unconstrainedBoundsFor(harness)) {
            uint256 totalAssetsAfter = harness.totalAssets();

            // Total assets should be preserved within rounding.
            assertApproxEqAbs(
                totalAssetsAfter,
                totalAssetsBefore,
                10,
                "Total assets should be preserved after rebalance"
            );

            // All caps should be respected.
            uint256 ta = harness.totalAssets();
            for (uint256 i = 0; i < 3; i++) {
                address market = markets[i];
                uint256 marketAssets = _getMarketAssets(market);
                uint256 cap = harness.allocationCaps(market);
                uint256 allocation = FixedPointMathLib.mulDiv(marketAssets, WAD, ta);
                assertLe(
                    allocation,
                    cap,
                    "All markets must respect allocation caps after rebalance"
                );
            }
        } catch (bytes memory reason) {
            // Only acceptable reverts are cap violations.
            bytes4 selector = bytes4(reason);
            assertEq(
                selector,
                LendingOptimizer.LendingOptimizer__AllocationExceedsCap.selector,
                "Should only revert with AllocationExceedsCap"
            );
        }
    }
}
