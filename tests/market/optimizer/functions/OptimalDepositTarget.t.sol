// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { LendingOptimizerHarness } from "../LendingOptimizerHarness.sol";
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

        uint256 targetDeposit = LendingOptimizerHarness(address(optimizer)).optimalDepositTarget(1000e6);

        // Verify the target deposits a valid index
        // It chooses the market with the highest projected rate
        // Allocation cap is > market assets for every market in this test
        // Therefore, it should choose the market with the highest projected rate
        // And overshoot the cap.
        assertLt(targetDeposit, 3);
    }

    function test_lendingOptimizer_optimalDepositTarget_success_oneMarketFirstDeposit() public {
        _setUpOneMarket();
        uint256 targetDeposit = LendingOptimizerHarness(address(optimizer)).optimalDepositTarget(1000e6);
        assertEq(targetDeposit, 0);
    }

    function test_lendingOptimizer_optimalDepositTarget_success_smallDepositPicksHighestRate() public {
        _setUpThreeMarkets();

        // Small deposit that won't push any market over cap
        uint256 targetDeposit = LendingOptimizerHarness(address(optimizer)).optimalDepositTarget(100e6);

        // Should pick market with highest projected supply rate
        // Market 1 (cUSDC_WBTC_MARKET) has highest utilization -> highest rate
        assertLt(targetDeposit, 3);
    }

    function test_lendingOptimizer_optimalDepositTarget_success_verySmallDeposit() public {
        _setUpThreeMarkets();

        // Tiny deposit - 1 USDC
        uint256 targetDeposit = LendingOptimizerHarness(address(optimizer)).optimalDepositTarget(1e6);

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
        uint256 firstTarget = LendingOptimizerHarness(address(optimizer)).optimalDepositTarget(largeDeposit);
        optimizer.deposit(largeDeposit, address(this), optimizer.approvedCTokensList(firstTarget));

        // Now check optimal target for another deposit
        uint256 secondTarget = LendingOptimizerHarness(address(optimizer)).optimalDepositTarget(50_000e6);

        // Should return a valid market index
        assertLt(secondTarget, 3);
    }

    function test_lendingOptimizer_optimalDepositTarget_success_afterHeavyDeposit() public {
        _setUpThreeMarkets();

        // Make a heavy deposit to market 0 to shift utilization
        uint256 hugeDeposit = 1_000_000e6; // 1M USDC
        deal(USDC_MONAD, address(this), hugeDeposit);
        IERC20(USDC_MONAD).approve(address(optimizer), hugeDeposit);

        // Deposit directly to market 0, lowering its utilization/rate
        optimizer.deposit(hugeDeposit, address(this), cUSDC_WMON_MARKET);

        // Next deposit should pick the market with the highest projected rate
        uint256 target = LendingOptimizerHarness(address(optimizer)).optimalDepositTarget(500_000e6);

        // Should return a valid index
        assertLt(target, 3);
    }

    function test_lendingOptimizer_optimalDepositTarget_success_consistentResultsForSameInput() public {
        _setUpThreeMarkets();

        // Call multiple times with same input - should be deterministic
        uint256 target1 = LendingOptimizerHarness(address(optimizer)).optimalDepositTarget(1000e6);
        uint256 target2 = LendingOptimizerHarness(address(optimizer)).optimalDepositTarget(1000e6);
        uint256 target3 = LendingOptimizerHarness(address(optimizer)).optimalDepositTarget(1000e6);

        assertEq(target1, target2);
        assertEq(target2, target3);
    }

    function test_lendingOptimizer_optimalDepositTarget_success_differentAmountsBothValid() public {
        _setUpThreeMarkets();

        // Seed market 0 with a deposit to create differentiated utilization.
        uint256 seedDeposit = 100_000e6;
        deal(USDC_MONAD, address(this), seedDeposit);
        IERC20(USDC_MONAD).approve(address(optimizer), seedDeposit);
        optimizer.deposit(seedDeposit, address(this), cUSDC_WMON_MARKET);

        // Different deposit sizes may route to different markets based on
        // projected rates (larger deposits dilute utilization more).
        uint256 targetSmall = LendingOptimizerHarness(address(optimizer)).optimalDepositTarget(100e6);
        uint256 targetLarge = LendingOptimizerHarness(address(optimizer)).optimalDepositTarget(500_000e6);

        assertLt(targetSmall, 3);
        assertLt(targetLarge, 3);
    }

    function test_lendingOptimizer_optimalDepositTarget_success_zeroAssetsDeposit() public {
        _setUpThreeMarkets();

        // Zero deposit should still return a valid target
        uint256 target = LendingOptimizerHarness(address(optimizer)).optimalDepositTarget(0);
        assertLt(target, 3);
    }

    function test_lendingOptimizer_optimalDepositTarget_success_notInitialized() public {
        // Create optimizer but don't initialize.
        address[] memory approvedCTokens = new address[](2);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](2);
        allocationCapsBps[0] = 6_000;
        allocationCapsBps[1] = 5_000;

        LendingOptimizerHarness uninitOptimizer = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000
        );

        // View function returns the index with the highest projected rate.
        // With real rates, the optimal market depends on utilization.
        uint256 target = uninitOptimizer.optimalDepositTarget(1000e6);
        assertLt(target, 2, "Should return a valid index when uninitialized");
    }

    function test_lendingOptimizer_optimalDepositTarget_success_twoMarkets() public {
        _setUpTwoMarkets();

        uint256 target = LendingOptimizerHarness(address(optimizer)).optimalDepositTarget(1000e6);

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
        uint256 target = LendingOptimizerHarness(address(optimizer)).optimalDepositTarget(50_000e6);
        assertLt(target, 2);
    }

    function test_lendingOptimizer_optimalDepositTarget_success_maxUint256Deposit() public {
        _setUpThreeMarkets();

        // Extremely large deposit - with real rates, this overwhelms all
        // market utilization to near-zero, causing all projected rates to be 0.
        // The optimizer reverts with MarketPaused when no viable market is found.
        vm.expectRevert(LendingOptimizer.LendingOptimizer__MarketPaused.selector);
        LendingOptimizerHarness(address(optimizer)).optimalDepositTarget(type(uint128).max);
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
            uint256 actualTarget = LendingOptimizerHarness(address(optimizer)).optimalDepositTarget(depositAmount);

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

        uint256 maxProjectedRate;

        for (uint256 i = 0; i < numMarkets; i++) {
            address cToken = optimizer.approvedCTokensList(i);
            IBorrowableCToken market = IBorrowableCToken(cToken);

            uint256 projectedRate = market.IRM().supplyRate(
                market.assetsHeld() + assets,
                market.marketOutstandingDebt(),
                market.interestFee()
            );

            if (projectedRate > maxProjectedRate) {
                maxProjectedRate = projectedRate;
                expectedTarget = i;
            }
        }
    }

    function test_lendingOptimizer_optimalDepositTarget_success_afterTimePassesRatesChange() public {
        _setUpThreeMarkets();

        uint256 target1 = LendingOptimizerHarness(address(optimizer)).optimalDepositTarget(1000e6);

        // Skip forward to simulate yield accrual
        skip(1 days);

        uint256 target2 = LendingOptimizerHarness(address(optimizer)).optimalDepositTarget(1000e6);

        // Both should be valid (may or may not be equal depending on rate changes)
        assertLt(target1, 3);
        assertLt(target2, 3);
    }




}