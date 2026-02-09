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
            1_000,
            1 days
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(harness), initAssets);
        harness.initializeDeposits(0);
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
            1_000,
            1 days
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(harness), initAssets);
        harness.initializeDeposits(0);
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
            1_000,
            1 days
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(harness), initAssets);
        harness.initializeDeposits(0);
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
        harness.deposit(amount, depositor, market);
        vm.stopPrank();
    }

    function _getMarketAssets(address market) internal view returns (uint256) {
        return IBorrowableCToken(market).convertToAssets(
            IBorrowableCToken(market).balanceOf(address(harness))
        );
    }

    /// @dev Helper to verify deposit target is optimal among all viable markets.
    function _verifyDepositOptimal(
        uint256 targetIndex,
        uint256 depositAmount,
        uint256 newTotal
    ) internal view {
        address chosenMarket = harness.approvedCTokensList(targetIndex);
        uint256 chosenRate = harness.previewAssetImpact(
            IBorrowableCToken(chosenMarket),
            depositAmount,
            true
        );

        for (uint256 i = 0; i < 3; i++) {
            if (i == targetIndex) continue;
            address otherMarket = harness.approvedCTokensList(i);
            uint256 otherAssets = _getMarketAssets(otherMarket);
            uint256 otherCap = harness.allocationCaps(otherMarket);
            uint256 otherMaxAllocation = FixedPointMathLib.mulDiv(otherCap, newTotal, WAD);

            if (otherMaxAllocation > otherAssets) {
                uint256 otherRate = harness.previewAssetImpact(
                    IBorrowableCToken(otherMarket),
                    depositAmount,
                    true
                );
                assertGe(
                    chosenRate,
                    otherRate,
                    "Chosen market must have highest projected rate among viable markets"
                );
            }
        }
    }

    /// @dev Helper to verify withdrawal target is optimal among all viable markets.
    function _verifyWithdrawalOptimal(
        uint256 targetIndex,
        uint256 withdrawAmount
    ) internal view {
        address chosenMarket = harness.approvedCTokensList(targetIndex);
        uint256 chosenRate = harness.previewAssetImpact(
            IBorrowableCToken(chosenMarket),
            withdrawAmount,
            false
        );

        for (uint256 i = 0; i < 3; i++) {
            if (i == targetIndex) continue;
            address otherMarket = harness.approvedCTokensList(i);
            uint256 otherAssets = _getMarketAssets(otherMarket);
            uint256 otherLiquidity = IBorrowableCToken(otherMarket).assetsHeld();

            if (otherAssets >= withdrawAmount && otherLiquidity >= withdrawAmount) {
                uint256 otherRate = harness.previewAssetImpact(
                    IBorrowableCToken(otherMarket),
                    withdrawAmount,
                    false
                );
                assertLe(
                    chosenRate,
                    otherRate,
                    "Chosen market must have lowest projected rate among viable markets"
                );
            }
        }
    }

    // ==================== Tests ====================

    function testFuzz_optimalDepositTarget_varied(
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

        // Get optimal target.
        uint256 targetIndex = harness.optimalDepositTarget(depositAmount);

        // Verify the chosen index is valid.
        assertLt(targetIndex, 3, "Target index must be within bounds");

        // Verify the chosen market has cap headroom, OR no market has headroom
        // (fallback to market 0). If it has headroom, verify optimality.
        {
            address chosenMarket = harness.approvedCTokensList(targetIndex);
            uint256 newTotal = harness.totalAssets() + depositAmount;
            uint256 chosenMarketAssets = _getMarketAssets(chosenMarket);
            uint256 chosenMaxAllocation = FixedPointMathLib.mulDiv(
                harness.allocationCaps(chosenMarket), newTotal, WAD
            );

            if (chosenMaxAllocation > chosenMarketAssets) {
                _verifyDepositOptimal(targetIndex, depositAmount, newTotal);
            }
        }

        // Execute deposit and verify it succeeds.
        deal(USDC_MONAD, user1, depositAmount);
        vm.startPrank(user1);
        IERC20(USDC_MONAD).approve(address(harness), depositAmount);
        uint256 shares = harness.deposit(depositAmount, user1);
        vm.stopPrank();
        assertGt(shares, 0, "Deposit must mint shares");
    }

    function testFuzz_optimalWithdrawalTarget_varied(
        uint256 withdrawAmount,
        uint256 market0Deposit,
        uint256 market1Deposit
    ) public {
        _deployThreeMarketHarness();

        // Pre-load different amounts into markets.
        market0Deposit = bound(market0Deposit, 100e6, 5_000_000e6);
        market1Deposit = bound(market1Deposit, 100e6, 5_000_000e6);

        _depositToHarnessMarket(user1, market0Deposit, cUSDC_WMON_MARKET);
        _depositToHarnessMarket(user1, market1Deposit, cUSDC_WBTC_MARKET);

        // Bound withdraw to what is actually withdrawable.
        uint256 maxW = harness.maxWithdraw(user1);
        vm.assume(maxW >= 1e6);
        withdrawAmount = bound(withdrawAmount, 1e6, maxW);

        // Call optimalWithdrawalTarget.
        uint256 targetIndex = harness.optimalWithdrawalTarget(withdrawAmount);
        assertLt(targetIndex, 3, "Target index must be within bounds");

        {
            address chosenMarket = harness.approvedCTokensList(targetIndex);
            uint256 chosenAssets = _getMarketAssets(chosenMarket);
            uint256 chosenLiquidity = IBorrowableCToken(chosenMarket).assetsHeld();

            // Verify the chosen market has sufficient balance and liquidity.
            assertGe(chosenAssets, withdrawAmount, "Chosen market must have enough balance");
            assertGe(chosenLiquidity, withdrawAmount, "Chosen market must have enough liquidity");
        }

        // Verify no other viable market has a lower projected rate.
        _verifyWithdrawalOptimal(targetIndex, withdrawAmount);
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
        uint256 shares = harness.deposit(1_000e6, user2, cUSDC_WETH_MARKET);
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

        // Estimate redeem output and build reallocation action.
        IBorrowableCToken cTokenToRemove = IBorrowableCToken(markets[marketToRemoveIdx]);
        uint256 estimatedRedeem = cTokenToRemove.convertToAssets(
            cTokenToRemove.balanceOf(address(harness))
        );

        LendingOptimizer.RemoveAction[] memory removeActions = new LendingOptimizer.RemoveAction[](1);
        removeActions[0] = LendingOptimizer.RemoveAction(
            IBorrowableCToken(firstRemaining),
            estimatedRedeem
        );

        // Try removal - may fail if redeem output != estimate.
        try harness.removeApprovedAsset(marketToRemoveIdx, removeActions) {
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

        // Get the target - when all markets are at cap, defaults to market 0.
        uint256 target = harness.optimalDepositTarget(extraDeposit);
        assertLt(target, 3, "Target should be a valid index");

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

        LendingOptimizer.RebalanceAction[] memory actions = new LendingOptimizer.RebalanceAction[](3);
        actions[0] = LendingOptimizer.RebalanceAction(
            IBorrowableCToken(cUSDC_WMON_MARKET),
            withdrawAmount,
            false // withdraw
        );
        actions[1] = LendingOptimizer.RebalanceAction(
            IBorrowableCToken(cUSDC_WBTC_MARKET),
            withdrawAmount,
            true // deposit
        );
        actions[2] = LendingOptimizer.RebalanceAction(
            IBorrowableCToken(cUSDC_WETH_MARKET),
            0,
            true // no-op
        );

        // Proper rebalance should succeed.
        harness.rebalance(actions);

        // Verify market 0 is now within cap.
        uint256 taAfter = harness.totalAssets();
        uint256 market0After = _getMarketAssets(cUSDC_WMON_MARKET);
        uint256 allocationAfter = FixedPointMathLib.mulDiv(market0After, WAD, taAfter);
        assertLe(
            allocationAfter,
            harness.allocationCaps(cUSDC_WMON_MARKET),
            "Market 0 should be within cap after rebalance"
        );
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
        LendingOptimizer.RebalanceAction[] memory actions = new LendingOptimizer.RebalanceAction[](3);
        for (uint256 i = 0; i < 3; i++) {
            if (i == withdrawIdx) {
                actions[i] = LendingOptimizer.RebalanceAction(
                    IBorrowableCToken(markets[i]),
                    amount,
                    false // withdraw
                );
            } else if (i == depositIdx) {
                actions[i] = LendingOptimizer.RebalanceAction(
                    IBorrowableCToken(markets[i]),
                    amount,
                    true // deposit
                );
            } else {
                actions[i] = LendingOptimizer.RebalanceAction(
                    IBorrowableCToken(markets[i]),
                    0,
                    true // no-op
                );
            }
        }

        // Try the rebalance. May revert if deposit pushes a market over cap.
        try harness.rebalance(actions) {
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
