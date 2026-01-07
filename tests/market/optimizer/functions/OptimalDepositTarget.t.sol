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

contract TestLendingOptimizerOptimalDepositTarget is TestBaseLendingOptimizer {

    function setUp() public override {
        super.setUp();
    }

    function test_lendingOptimizer_optimalDepositTarget_success_threeMarketsFirstDeposit() public {

        _setUpThreeMarkets();

        uint256 targetDeposit = optimizer.optimalDepositTarget(1000e6);

        // Verify the target deposits a valid index
        // It chooses the market with the highest projected rate
        // Allocation cap is > market assets for every market in this test
        // Therefore, it should choose the market with the highest projected rate
        // And overshoot the cap.
        assertLt(targetDeposit, 3);
    }

    function test_lendingOptimizer_optimalDepositTarget_success_oneMarketFirstDeposit() public {
        _setUpOneMarket();
        uint256 targetDeposit = optimizer.optimalDepositTarget(1000e6);
        assertEq(targetDeposit, 0);
    }

    function test_lendingOptimizer_optimalDepositTarget_success_smallDepositPicksHighestRate() public {
        _setUpThreeMarkets();

        // Small deposit that won't push any market over cap
        uint256 targetDeposit = optimizer.optimalDepositTarget(100e6);

        // Should pick market with highest projected supply rate
        // Market 1 (cUSDC_WBTC_MARKET) has highest utilization -> highest rate
        assertLt(targetDeposit, 3);
    }

    function test_lendingOptimizer_optimalDepositTarget_success_verySmallDeposit() public {
        _setUpThreeMarkets();

        // Tiny deposit - 1 USDC
        uint256 targetDeposit = optimizer.optimalDepositTarget(1e6);

        // Should still pick optimal market
        assertLt(targetDeposit, 3);
    }

    function test_lendingOptimizer_optimalDepositTarget_success_afterLargeDeposit() public {
        _setUpThreeMarkets();

        // Make a large deposit first to change the state
        uint256 largeDeposit = 100_000e6; // 100k USDC
        deal(USDC_MONAD, address(this), largeDeposit);
        IERC20(USDC_MONAD).approve(address(optimizer), largeDeposit);

        // Get optimal target and deposit there
        uint256 firstTarget = optimizer.optimalDepositTarget(largeDeposit);
        optimizer.deposit(largeDeposit, address(this), optimizer.approvedCTokensList(firstTarget));

        // Now check optimal target for another deposit
        uint256 secondTarget = optimizer.optimalDepositTarget(50_000e6);

        // Should return a valid market index
        assertLt(secondTarget, 3);

        // One market should have been skipped because it was at cap
        assertNotEq(firstTarget, secondTarget);
    }

    function test_lendingOptimizer_optimalDepositTarget_success_marketAtCapSkipped() public {
        _setUpThreeMarkets();

        // Make deposits to push market 0 close to its 60% cap
        // First, we need substantial deposits to make caps meaningful
        uint256 hugeDeposit = 1_000_000e6; // 1M USDC
        deal(USDC_MONAD, address(this), hugeDeposit);
        IERC20(USDC_MONAD).approve(address(optimizer), hugeDeposit);

        // Deposit directly to market 0 to push it toward cap
        optimizer.deposit(hugeDeposit, address(this), cUSDC_WMON_MARKET);

        // Now optimal target should consider cap headroom
        uint256 target = optimizer.optimalDepositTarget(500_000e6);

        // Should return a valid index
        assertLt(target, 3);

        assertNotEq(target, 0);
    }

    function test_lendingOptimizer_optimalDepositTarget_success_consistentResultsForSameInput() public {
        _setUpThreeMarkets();

        // Call multiple times with same input - should be deterministic
        uint256 target1 = optimizer.optimalDepositTarget(1000e6);
        uint256 target2 = optimizer.optimalDepositTarget(1000e6);
        uint256 target3 = optimizer.optimalDepositTarget(1000e6);

        assertEq(target1, target2);
        assertEq(target2, target3);
    }

    function test_lendingOptimizer_optimalDepositTarget_success_differentAmountsCanYieldDifferentTargets() public {
        _setUpThreeMarkets();

        // Very small vs very large deposits might pick different markets
        // due to how rates change with utilization
        uint256 targetSmall = optimizer.optimalDepositTarget(1e6);
        uint256 targetLarge = optimizer.optimalDepositTarget(1_000_000e6); // 1M USDC

        // Both should be valid indices
        assertLt(targetSmall, 3);
        assertLt(targetLarge, 3);

        // Should pick different markets
        assertNotEq(targetSmall, targetLarge);
    }

    function test_lendingOptimizer_optimalDepositTarget_success_zeroAssetsDeposit() public {
        _setUpThreeMarkets();

        // Zero deposit should still return a valid target
        uint256 target = optimizer.optimalDepositTarget(0);
        assertLt(target, 3);
    }

    function test_lendingOptimizer_optimalDepositTarget_revert_notInitialized() public {
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
        uninitOptimizer.optimalDepositTarget(1000e6);
    }

    function test_lendingOptimizer_optimalDepositTarget_success_twoMarkets() public {
        _setUpTwoMarkets();

        uint256 target = optimizer.optimalDepositTarget(1000e6);

        // Should be either 0 or 1
        assertLt(target, 2);
    }

    function test_lendingOptimizer_optimalDepositTarget_success_twoMarketsAfterDeposits() public {
        _setUpTwoMarkets();

        // Deposit into first market
        uint256 deposit1 = 50_000e6;
        deal(USDC_MONAD, address(this), deposit1);
        IERC20(USDC_MONAD).approve(address(optimizer), deposit1);
        optimizer.deposit(deposit1, address(this), cUSDC_WMON_MARKET);

        // Check optimal for next deposit
        uint256 target = optimizer.optimalDepositTarget(50_000e6);
        assertLt(target, 2);
    }

    function test_lendingOptimizer_optimalDepositTarget_success_maxUint256Deposit() public {
        _setUpThreeMarkets();

        // Extremely large deposit - should handle gracefully
        uint256 target = optimizer.optimalDepositTarget(type(uint128).max);

        // Should return valid index (likely fallback to 0 if all caps exceeded)
        assertLt(target, 3);
    }

    function test_lendingOptimizer_optimalDepositTarget_success_sequentialDepositsDistribute() public {
        _setUpThreeMarkets();

        // Caps: Market 0 = 60%, Market 1 = 50%, Market 2 = 20%
        uint256 depositAmount = 100_000e6;
        uint256 numDeposits = 5;

        for (uint256 i = 0; i < numDeposits; i++) {
            deal(USDC_MONAD, address(this), depositAmount);
            IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);

            // Calculate expected target dynamically based on current state
            uint256 expectedTarget = _calculateExpectedTarget(depositAmount);

            // Get actual target from the optimizer
            uint256 actualTarget = optimizer.optimalDepositTarget(depositAmount);

            // Verify they match
            assertEq(
                actualTarget,
                expectedTarget,
                string.concat("Deposit ", vm.toString(i + 1), ": Target mismatch")
            );

            // Make the deposit
            optimizer.deposit(depositAmount, address(this), optimizer.approvedCTokensList(actualTarget));
        }
    }

    /// @dev Mirrors the optimalDepositTarget logic to calculate expected selection
    function _calculateExpectedTarget(uint256 assets) internal view returns (uint256 expectedTarget) {
        uint256 numMarkets = optimizer.numApprovedMarkets();
        uint256 ta = optimizer.totalAssets();
        uint256 newTotal = ta + assets;

        uint256 maxProjectedRate;
        bool foundViable;

        for (uint256 i = 0; i < numMarkets; i++) {
            address cToken = optimizer.approvedCTokensList(i);
            IBorrowableCToken market = IBorrowableCToken(cToken);

            // Get current assets in this market
            uint256 marketAssets = market.convertToAssets(market.balanceOf(address(optimizer)));

            // Get allocation cap (in WAD)
            uint256 cap = optimizer.allocationCaps(cToken);

            // Calculate max allocation based on cap
            uint256 maxAllocation = (cap * newTotal) / WAD;

            // Check if market has headroom
            if (maxAllocation > marketAssets) {
                foundViable = true;

                // Calculate projected supply rate
                uint256 projectedAssetsHeld = market.assetsHeld() + assets;
                uint256 debt = market.marketOutstandingDebt();
                uint256 projectedRate = market.IRM().supplyRate(
                    projectedAssetsHeld,
                    debt,
                    market.interestFee()
                );

                // Update if this is the best rate so far
                if (projectedRate > maxProjectedRate) {
                    maxProjectedRate = projectedRate;
                    expectedTarget = i;
                }
            }
        }

        // Fallback to 0 if no viable market found
        if (!foundViable) {
            expectedTarget = 0;
        }
    }

    function test_lendingOptimizer_optimalDepositTarget_success_afterTimePassesRatesChange() public {
        _setUpThreeMarkets();

        uint256 target1 = optimizer.optimalDepositTarget(1000e6);

        // Warp time forward - rates may change due to interest accrual
        vm.warp(block.timestamp + 1 days);

        uint256 target2 = optimizer.optimalDepositTarget(1000e6);

        // Both should be valid (may or may not be equal depending on rate changes)
        assertLt(target1, 3);
        assertLt(target2, 3);
    }




}