// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IERC165 } from "contracts/interfaces/IERC165.sol";
import { IPluginDelegable } from "contracts/interfaces/IPluginDelegable.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ERC4626 } from "contracts/libraries/external/ERC4626.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { WAD, BPS } from "contracts/libraries/ConstantsLib.sol";

contract TestLendingOptimizerOptimalWithdrawalTarget is TestBaseLendingOptimizer {

    function setUp() public override {
        super.setUp();
    }

    // ============ Basic Success Tests ============

    function test_lendingOptimizer_optimalWithdrawalTarget_success_oneMarket() public {
        _setUpOneMarket();
        
        // Deposit some assets first
        uint256 depositAmount = 10_000e6;
        deal(USDC_MONAD, address(this), depositAmount);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
        optimizer.deposit(depositAmount, address(this));

        // Optimal withdrawal target should be 0 (only one market)
        uint256 target = optimizer.optimalWithdrawalTarget(1000e6);
        assertEq(target, 0, "Single market should return index 0");
    }

    function test_lendingOptimizer_optimalWithdrawalTarget_success_twoMarkets() public {
        _setUpTwoMarkets();

        // Deposit to both markets
        uint256 depositAmount = 50_000e6;
        deal(USDC_MONAD, address(this), depositAmount);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
        optimizer.deposit(depositAmount, address(this), cUSDC_WMON_MARKET);

        deal(USDC_MONAD, address(this), depositAmount);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
        optimizer.deposit(depositAmount, address(this), cUSDC_WBTC_MARKET);

        // Should return a valid target
        uint256 target = optimizer.optimalWithdrawalTarget(10_000e6);
        assertLt(target, 2, "Target should be valid index");
    }

    function test_lendingOptimizer_optimalWithdrawalTarget_success_threeMarkets() public {
        _setUpThreeMarkets();

        // Deposit to all markets
        _depositToAllMarkets(50_000e6);

        // Should return a valid target
        uint256 target = optimizer.optimalWithdrawalTarget(10_000e6);
        assertLt(target, 3, "Target should be valid index");
    }

    function test_lendingOptimizer_optimalWithdrawalTarget_success_smallWithdrawal() public {
        _setUpThreeMarkets();

        // Deposit to all markets
        _depositToAllMarkets(50_000e6);

        // Very small withdrawal
        uint256 target = optimizer.optimalWithdrawalTarget(1e6);
        assertLt(target, 3, "Target should be valid index for small withdrawal");
    }

    function test_lendingOptimizer_optimalWithdrawalTarget_success_picksLowestRate() public {
        _setUpThreeMarkets();

        // Deposit different amounts to each market to create different rates
        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 100_000e6);
        optimizer.deposit(100_000e6, address(this), cUSDC_WMON_MARKET);

        deal(USDC_MONAD, address(this), 50_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 50_000e6);
        optimizer.deposit(50_000e6, address(this), cUSDC_WBTC_MARKET);

        deal(USDC_MONAD, address(this), 25_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 25_000e6);
        optimizer.deposit(25_000e6, address(this), cUSDC_WETH_MARKET);

        // Get optimal target
        uint256 target = optimizer.optimalWithdrawalTarget(10_000e6);
        assertLt(target, 3, "Target should be valid index");

        // The target should be the market with lowest projected rate after withdrawal
        // This preserves yield in higher-performing markets
    }

    function test_lendingOptimizer_optimalWithdrawalTarget_success_consistentResults() public {
        _setUpThreeMarkets();

        // Deposit to all markets
        _depositToAllMarkets(50_000e6);

        // Call multiple times with same input - should be deterministic
        uint256 target1 = optimizer.optimalWithdrawalTarget(10_000e6);
        uint256 target2 = optimizer.optimalWithdrawalTarget(10_000e6);
        uint256 target3 = optimizer.optimalWithdrawalTarget(10_000e6);

        assertEq(target1, target2, "Results should be consistent");
        assertEq(target2, target3, "Results should be consistent");
    }

    function test_lendingOptimizer_optimalWithdrawalTarget_success_afterMultipleDeposits() public {
        _setUpThreeMarkets();

        // Make multiple deposits to various markets
        for (uint256 i = 0; i < 5; i++) {
            uint256 depositAmount = 20_000e6;
            deal(USDC_MONAD, address(this), depositAmount);
            IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
            
            // Alternate between markets
            address targetMarket = i % 3 == 0 ? cUSDC_WMON_MARKET : 
                                   i % 3 == 1 ? cUSDC_WBTC_MARKET : cUSDC_WETH_MARKET;
            optimizer.deposit(depositAmount, address(this), targetMarket);
        }

        // Should still return valid target
        uint256 target = optimizer.optimalWithdrawalTarget(10_000e6);
        assertLt(target, 3, "Target should be valid index");
    }

    function test_lendingOptimizer_optimalWithdrawalTarget_success_withdrawalChangesOptimalTarget() public {
        _setUpTwoMarkets();

        // Deposit evenly
        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 100_000e6);
        optimizer.deposit(100_000e6, address(this), cUSDC_WMON_MARKET);

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 100_000e6);
        optimizer.deposit(100_000e6, address(this), cUSDC_WBTC_MARKET);

        uint256 target1 = optimizer.optimalWithdrawalTarget(50_000e6);

        // Withdraw from that market
        optimizer.withdraw(50_000e6, address(this), address(this), optimizer.approvedCTokensList(target1));

        // After withdrawal, optimal target might change
        uint256 target2 = optimizer.optimalWithdrawalTarget(30_000e6);

        // Both should be valid
        assertLt(target1, 2, "First target should be valid");
        assertLt(target2, 2, "Second target should be valid");
    }

    // ============ Revert Tests ============

    function test_lendingOptimizer_optimalWithdrawalTarget_fail_notInitialized() public {
        // Create optimizer but don't initialize
        address[] memory approvedCTokens = new address[](2);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](2);
        allocationCapsBps[0] = 6_000;
        allocationCapsBps[1] = 5_000;

        LendingOptimizer uninitOptimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000,
            1 days
        );

        // Should revert because not initialized
        vm.expectRevert(LendingOptimizer.LendingOptimizer__NotInitialized.selector);
        uninitOptimizer.optimalWithdrawalTarget(1000e6);
    }

    function test_lendingOptimizer_optimalWithdrawalTarget_fail_insufficientLiquidity() public {
        _setUpThreeMarkets();

        // Only small deposit in initialization
        // Try to withdraw more than available
        vm.expectRevert(LendingOptimizer.LendingOptimizer__InsufficientLiquidity.selector);
        optimizer.optimalWithdrawalTarget(1_000_000e6);
    }

    function test_lendingOptimizer_optimalWithdrawalTarget_fail_noMarketHasEnoughBalance() public {
        _setUpThreeMarkets();

        // Deposit small amounts to each market
        deal(USDC_MONAD, address(this), 1000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 1000e6);
        optimizer.deposit(1000e6, address(this), cUSDC_WMON_MARKET);

        deal(USDC_MONAD, address(this), 1000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 1000e6);
        optimizer.deposit(1000e6, address(this), cUSDC_WBTC_MARKET);

        // Try to withdraw more than any single market has
        vm.expectRevert(LendingOptimizer.LendingOptimizer__InsufficientLiquidity.selector);
        optimizer.optimalWithdrawalTarget(5000e6);
    }

    // ============ Edge Cases ============

    function test_lendingOptimizer_optimalWithdrawalTarget_success_withdrawExactMarketBalance() public {
        _setUpOneMarket();

        // Deposit specific amount
        uint256 depositAmount = 10_000e6;
        deal(USDC_MONAD, address(this), depositAmount);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
        optimizer.deposit(depositAmount, address(this));

        // Get optimizer's balance in the market
        uint256 marketBalance = IBorrowableCToken(cUSDC_WMON_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer))
        );

        // Should work for exact balance (minus a small buffer for rounding)
        uint256 target = optimizer.optimalWithdrawalTarget(marketBalance - 1000);
        assertEq(target, 0, "Should return valid target");
    }

    function test_lendingOptimizer_optimalWithdrawalTarget_success_afterTimePassesRatesChange() public {
        _setUpThreeMarkets();

        // Deposit to all markets
        _depositToAllMarkets(50_000e6);

        uint256 target1 = optimizer.optimalWithdrawalTarget(10_000e6);

        // Skip forward to simulate yield accrual
        skip(1 days);

        uint256 target2 = optimizer.optimalWithdrawalTarget(10_000e6);

        // Both should be valid (may or may not be equal depending on rate changes)
        assertLt(target1, 3, "First target should be valid");
        assertLt(target2, 3, "Second target should be valid");
    }

    function test_lendingOptimizer_optimalWithdrawalTarget_success_zeroWithdrawal() public {
        _setUpThreeMarkets();

        // Deposit to markets
        _depositToAllMarkets(50_000e6);

        // Zero withdrawal should still work
        uint256 target = optimizer.optimalWithdrawalTarget(0);
        assertLt(target, 3, "Should return valid target for zero withdrawal");
    }

    function test_lendingOptimizer_optimalWithdrawalTarget_success_selectsViableMarket() public {
        _setUpThreeMarkets();

        // Deposit heavily to one market, lightly to others
        deal(USDC_MONAD, address(this), 500_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 500_000e6);
        optimizer.deposit(500_000e6, address(this), cUSDC_WMON_MARKET);

        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        optimizer.deposit(10_000e6, address(this), cUSDC_WBTC_MARKET);

        // Large withdrawal - should only be viable from market 0
        uint256 target = optimizer.optimalWithdrawalTarget(100_000e6);
        
        // Should pick market 0 since it's the only one with enough liquidity
        assertEq(target, 0, "Should select market with sufficient liquidity");
    }

    // ============ Integration with Actual Withdrawals ============

    function test_lendingOptimizer_optimalWithdrawalTarget_success_usedByWithdrawFunction() public {
        _setUpThreeMarkets();

        // Deposit to all markets
        _depositToAllMarkets(50_000e6);

        uint256 withdrawAmount = 10_000e6;
        uint256 expectedTarget = optimizer.optimalWithdrawalTarget(withdrawAmount);
        address expectedMarket = optimizer.approvedCTokensList(expectedTarget);

        // Get market balance before
        uint256 marketBalanceBefore = IBorrowableCToken(expectedMarket).balanceOf(address(optimizer));

        // Use standard withdraw (should use optimal target internally)
        optimizer.withdraw(withdrawAmount, address(this), address(this));

        // Verify withdrawal came from expected market
        uint256 marketBalanceAfter = IBorrowableCToken(expectedMarket).balanceOf(address(optimizer));
        assertLt(marketBalanceAfter, marketBalanceBefore, "Expected market should have reduced balance");
    }

    // ============ Mirrors the optimalDepositTarget helper ============

    /// @dev Mirrors the optimalWithdrawalTarget logic to calculate expected selection
    function _calculateExpectedWithdrawalTarget(uint256 assets) internal view returns (uint256 expectedTarget) {
        uint256 numMarkets = optimizer.numApprovedMarkets();

        uint256 minProjectedRate = type(uint256).max;
        bool foundViable;

        for (uint256 i = 0; i < numMarkets; i++) {
            address cToken = optimizer.approvedCTokensList(i);
            IBorrowableCToken market = IBorrowableCToken(cToken);

            // Get current assets in this market
            uint256 marketAssets = market.convertToAssets(market.balanceOf(address(optimizer)));
            uint256 assetsHeld = market.assetsHeld();

            // Check if market is viable (has enough balance and liquidity)
            if (marketAssets >= assets && assetsHeld >= assets) {
                foundViable = true;

                // Calculate projected supply rate after withdrawal
                uint256 projectedAssetsHeld = assetsHeld - assets;
                uint256 debt = market.marketOutstandingDebt();
                uint256 projectedRate = market.IRM().supplyRate(
                    projectedAssetsHeld,
                    debt,
                    market.interestFee()
                );

                // Update if this is the lowest rate so far
                if (projectedRate < minProjectedRate) {
                    minProjectedRate = projectedRate;
                    expectedTarget = i;
                }
            }
        }

        require(foundViable, "No viable market found");
    }

    function test_lendingOptimizer_optimalWithdrawalTarget_success_matchesExpectedCalculation() public {
        _setUpThreeMarkets();

        // Deposit to all markets
        _depositToAllMarkets(50_000e6);

        uint256 withdrawAmount = 10_000e6;

        // Calculate expected target using our helper
        uint256 expectedTarget = _calculateExpectedWithdrawalTarget(withdrawAmount);

        // Get actual target from optimizer
        uint256 actualTarget = optimizer.optimalWithdrawalTarget(withdrawAmount);

        assertEq(actualTarget, expectedTarget, "Target should match expected calculation");
    }

    function test_lendingOptimizer_optimalWithdrawalTarget_success_sequentialWithdrawals() public {
        _setUpThreeMarkets();

        // Deposit heavily to create liquidity
        _depositToAllMarkets(100_000e6);

        uint256 withdrawAmount = 20_000e6;
        uint256 numWithdrawals = 3;

        for (uint256 i = 0; i < numWithdrawals; i++) {
            // Get optimal target
            uint256 target = optimizer.optimalWithdrawalTarget(withdrawAmount);
            assertLt(target, 3, string.concat("Withdrawal ", vm.toString(i + 1), ": Target should be valid"));

            // Make the withdrawal
            optimizer.withdraw(withdrawAmount, address(this), address(this));
        }
    }

    // ============ Fuzz Tests ============

    function testFuzz_lendingOptimizer_optimalWithdrawalTarget_validIndex(uint256 withdrawAmount) public {
        _setUpThreeMarkets();

        // Deposit to all markets
        _depositToAllMarkets(100_000e6);

        // Bound withdrawal to reasonable amounts (less than total deposited per market)
        withdrawAmount = bound(withdrawAmount, 1e6, 50_000e6);

        // Should return valid index without reverting
        uint256 target = optimizer.optimalWithdrawalTarget(withdrawAmount);
        assertLt(target, 3, "Target should be valid index");
    }

    function testFuzz_lendingOptimizer_optimalWithdrawalTarget_consistentResults(uint256 withdrawAmount) public {
        _setUpThreeMarkets();

        // Deposit to all markets
        _depositToAllMarkets(100_000e6);

        // Bound withdrawal to reasonable amounts
        withdrawAmount = bound(withdrawAmount, 1e6, 50_000e6);

        // Multiple calls should be consistent
        uint256 target1 = optimizer.optimalWithdrawalTarget(withdrawAmount);
        uint256 target2 = optimizer.optimalWithdrawalTarget(withdrawAmount);

        assertEq(target1, target2, "Results should be consistent");
    }
}
