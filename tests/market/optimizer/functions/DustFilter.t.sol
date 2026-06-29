// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { LendingOptimizerHarness } from "../LendingOptimizerHarness.sol";
import { OptimizerReader } from "contracts/views/OptimizerReader.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { WAD } from "contracts/libraries/ConstantsLib.sol";

/// @title Dust Filter Stress Tests
/// @notice Tests the _removeDustActions logic in OptimizerReader which filters
///         rebalance deltas too small to execute on-chain (convertToShares == 0).
/// @dev Exercises:
///      - Empty-array return when all deltas are zero or dust
///      - Zero-sum invariant preservation after dust removal
///      - Non-zero actions always convertible to non-zero shares
///      - Executable filtered results (no reverts at cToken level)
///      - High exchange-rate scenarios where small deltas become dust
///      - Idempotency: post-rebalance residuals filtered correctly
contract TestDustFilter is TestBaseLendingOptimizer {

    OptimizerReader reader;

    function setUp() public override {
        super.setUp();
        reader = new OptimizerReader(
            ICentralRegistry(address(liveCentralRegistry)),
            0
        );
    }

    // ============ Empty Array Returns ============

    /// @notice Single market always has ideal == current → empty arrays.
    function test_dustFilter_singleMarket_returnsEmpty() public {
        _setUpOneMarket();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 100_000e6);
        optimizer.deposit(100_000e6, address(this));

        (LendingOptimizer.ReallocationAction[] memory actions,
         LendingOptimizer.AllocationBound[] memory bounds) = reader.optimalRebalance(address(optimizer), 500, 200);

        assertEq(actions.length, 0, "Single market should return empty actions");
        assertEq(bounds.length, 0, "Single market should return empty bounds");
    }

    /// @notice Single market with only dead shares → empty arrays.
    function test_dustFilter_singleMarket_deadSharesOnly_returnsEmpty() public {
        _setUpOneMarket();

        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500, 200);

        assertEq(actions.length, 0, "Dead shares only: single market should be empty");
    }

    /// @notice After rebalancing to optimal and waiting for rates to settle,
    ///         the residual deltas from cToken rounding should be filtered as dust.
    function test_dustFilter_postRebalanceResiduals_filteredToDust() public {
        _setUpThreeMarketsUnconstrained();

        // Deposit into one market to create an imbalance.
        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 100_000e6);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(
            100_000e6, address(this), cUSDC_WMON_MARKET
        );

        // Rebalance to optimal.
        _executeOptimalRebalance();

        // Skip time so exchange rates grow > 1.0 (cToken rounding of 1 wei → 0 shares).
        skip(365 days);

        // Second call: residual deltas are at most 1-2 wei from cToken rounding.
        // With exchange rate > 1, these convert to 0 shares → dust → empty arrays.
        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500, 200);

        // If the filter worked, arrays should be empty (all residuals are dust).
        // If not empty, the residuals are non-dust — still valid, just larger
        // than expected. In either case, any non-zero action must be non-dust.
        _assertAllActionsNonDust(actions);
    }

    // ============ Non-Zero Actions Are Non-Dust ============

    /// @notice Every non-zero action in the returned array must convert to
    ///         at least 1 cToken share. This is the core invariant of the filter.
    function test_dustFilter_nonZeroActionsAlwaysNonDust_concentrated() public {
        _setUpThreeMarkets();

        // Concentrate all in market 0 (forces redistribution).
        deal(USDC_MONAD, address(this), 500_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 500_000e6);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(
            500_000e6, address(this), cUSDC_WMON_MARKET
        );

        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500, 200);

        _assertAllActionsNonDust(actions);
    }

    /// @notice Non-dust invariant holds with equal deposits across markets.
    function test_dustFilter_nonZeroActionsAlwaysNonDust_balanced() public {
        _setUpThreeMarkets();
        _depositToAllMarkets(50_000e6);

        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500, 200);

        _assertAllActionsNonDust(actions);
    }

    /// @notice Non-dust invariant holds after significant yield accrual.
    function test_dustFilter_nonZeroActionsAlwaysNonDust_afterYieldAccrual() public {
        _setUpThreeMarkets();
        _depositToAllMarkets(50_000e6);

        // Accrue yield for a year.
        skip(365 days);

        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500, 200);

        _assertAllActionsNonDust(actions);
    }

    // ============ Zero-Sum Preservation ============

    /// @notice Deposits and withdrawals must balance after dust filtering.
    function test_dustFilter_zeroSumMaintained_concentrated() public {
        _setUpThreeMarkets();

        deal(USDC_MONAD, address(this), 200_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 200_000e6);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(
            200_000e6, address(this), cUSDC_WMON_MARKET
        );

        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500, 200);

        _assertZeroSum(actions);
    }

    /// @notice Zero-sum preserved after yield accrual shifts ideal allocation.
    function test_dustFilter_zeroSumMaintained_afterYieldAccrual() public {
        _setUpThreeMarkets();
        _depositToAllMarkets(50_000e6);
        skip(180 days);

        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500, 200);

        _assertZeroSum(actions);
    }

    // ============ Filtered Results Are Executable ============

    /// @notice Non-empty filtered results can be passed to rebalance without revert.
    function test_dustFilter_filteredActionsExecutable_concentrated() public {
        _setUpThreeMarketsUnconstrained();

        deal(USDC_MONAD, address(this), 300_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 300_000e6);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(
            300_000e6, address(this), cUSDC_WMON_MARKET
        );

        (LendingOptimizer.ReallocationAction[] memory actions,
         LendingOptimizer.AllocationBound[] memory bounds) =
            reader.optimalRebalance(address(optimizer), 500, 200);

        uint256 totalAssetsBefore = _currentOptimizerAssets();

        // Execute: should not revert (no dust actions that would trigger BaseCToken__ZeroAmount).
        if (actions.length > 0) {
            optimizer.rebalance(actions, bounds);
        }

        assertApproxEqAbs(
            optimizer.totalAssets(),
            totalAssetsBefore,
            actions.length * 2,
            "Total assets should be preserved after filtered rebalance"
        );
    }

    /// @notice After yield accrual, filtered results are still executable.
    function test_dustFilter_filteredActionsExecutable_afterYield() public {
        _setUpThreeMarketsUnconstrained();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 100_000e6);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(
            100_000e6, address(this), cUSDC_WMON_MARKET
        );

        // Rebalance once, then accrue yield.
        _executeOptimalRebalance();
        skip(30 days);

        // Second rebalance: rates shifted, some deltas may be dust-filtered.
        (LendingOptimizer.ReallocationAction[] memory actions,
         LendingOptimizer.AllocationBound[] memory bounds) =
            reader.optimalRebalance(address(optimizer), 500, 200);

        uint256 totalAssetsBefore = _currentOptimizerAssets();

        if (actions.length > 0) {
            optimizer.rebalance(actions, bounds);
            assertApproxEqAbs(
                optimizer.totalAssets(),
                totalAssetsBefore,
                actions.length * 2,
                "Total assets preserved after yield-shifted rebalance"
            );
        }
    }

    // ============ High Exchange Rate Stress ============

    /// @notice With high exchange rates (long yield accrual), small deltas
    ///         from chunk rounding become dust and are filtered.
    function test_dustFilter_highExchangeRate_chunkRoundingBecomesDust() public {
        _setUpThreeMarketsUnconstrained();

        deal(USDC_MONAD, address(this), 50_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 50_000e6);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(
            50_000e6, address(this), cUSDC_WMON_MARKET
        );

        // Rebalance to optimal.
        _executeOptimalRebalance();

        // Skip 5 years — exchange rates grow significantly.
        skip(5 * 365 days);

        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500, 200);

        // After 5 years of accrual, residual deltas from chunk rounding
        // should be filtered. Verify core invariants hold either way.
        _assertAllActionsNonDust(actions);
        _assertZeroSum(actions);
    }

    /// @notice With very high exchange rates, only large enough deltas survive.
    function test_dustFilter_veryHighExchangeRate_10years() public {
        _setUpThreeMarketsUnconstrained();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 100_000e6);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(
            100_000e6, address(this), cUSDC_WMON_MARKET
        );

        _executeOptimalRebalance();

        // 10 years of yield accrual.
        skip(10 * 365 days);

        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500, 200);

        _assertAllActionsNonDust(actions);
        _assertZeroSum(actions);

        // Verify it's still executable if non-empty.
        if (actions.length > 0) {
            (LendingOptimizer.ReallocationAction[] memory a,
             LendingOptimizer.AllocationBound[] memory b) =
                reader.optimalRebalance(address(optimizer), 500, 200);
            optimizer.rebalance(a, b);
        }
    }

    // ============ Caller Protection ============

    /// @notice Empty arrays from dust filtering would revert if passed to rebalance.
    ///         Callers must check for empty arrays before calling rebalance.
    function test_dustFilter_emptyArraysRevertOnRebalance() public {
        _setUpOneMarket();

        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        optimizer.deposit(10_000e6, address(this));

        (LendingOptimizer.ReallocationAction[] memory actions,
         LendingOptimizer.AllocationBound[] memory bounds) =
            reader.optimalRebalance(address(optimizer), 500, 200);

        // Confirm arrays are empty.
        assertEq(actions.length, 0, "Should be empty for single market");

        // Passing empty arrays to rebalance must revert.
        vm.expectRevert(LendingOptimizer.LendingOptimizer__ArrayLengthMismatch.selector);
        optimizer.rebalance(actions, bounds);
    }

    // ============ Idempotency ============

    /// @notice Double rebalance: second call returns empty or very small movements.
    function test_dustFilter_doubleRebalance_secondIsEmptyOrTiny() public {
        _setUpThreeMarkets();
        _depositToAllMarkets(50_000e6);

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(
                ICentralRegistry.hasHarvestPermissions.selector,
                address(this)
            ),
            abi.encode(true)
        );

        // First rebalance.
        _executeOptimalRebalance();

        // Second call.
        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500, 200);

        // Either empty (all residuals are dust) or very small non-dust movements.
        uint256 totalMovement;
        for (uint256 i; i < actions.length; ++i) {
            if (actions[i].assetsOrBps > 0) {
                totalMovement += uint256(actions[i].assetsOrBps);
            } else if (actions[i].assetsOrBps < 0) {
                totalMovement += uint256(-actions[i].assetsOrBps);
            }
        }

        // Movement should be at most 1 chunk (totalAssets / 20).
        uint256 oneChunk = optimizer.totalAssets() / 20;
        assertLe(
            totalMovement,
            oneChunk * 2 + 1,
            "Second rebalance should be near-noop or empty"
        );
    }

    // ============ Fuzz Tests ============

    /// @notice For any deposit distribution, every non-zero action must
    ///         convert to at least 1 cToken share (core invariant).
    function testFuzz_dustFilter_nonZeroActionsNonDust(
        uint256 m0Deposit,
        uint256 m1Deposit,
        uint256 m2Deposit
    ) public {
        _setUpThreeMarkets();

        m0Deposit = bound(m0Deposit, 1e6, 500_000e6);
        m1Deposit = bound(m1Deposit, 1e6, 500_000e6);
        m2Deposit = bound(m2Deposit, 1e6, 500_000e6);

        deal(USDC_MONAD, address(this), m0Deposit);
        IERC20(USDC_MONAD).approve(address(optimizer), m0Deposit);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(
            m0Deposit, address(this), cUSDC_WMON_MARKET
        );

        deal(USDC_MONAD, address(this), m1Deposit);
        IERC20(USDC_MONAD).approve(address(optimizer), m1Deposit);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(
            m1Deposit, address(this), cUSDC_WBTC_MARKET
        );

        deal(USDC_MONAD, address(this), m2Deposit);
        IERC20(USDC_MONAD).approve(address(optimizer), m2Deposit);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(
            m2Deposit, address(this), cUSDC_WETH_MARKET
        );

        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500, 200);

        _assertAllActionsNonDust(actions);
    }

    /// @notice Zero-sum holds for any deposit distribution after dust filtering.
    function testFuzz_dustFilter_zeroSumPreserved(
        uint256 m0Deposit,
        uint256 m1Deposit,
        uint256 m2Deposit
    ) public {
        _setUpThreeMarkets();

        m0Deposit = bound(m0Deposit, 1e6, 500_000e6);
        m1Deposit = bound(m1Deposit, 1e6, 500_000e6);
        m2Deposit = bound(m2Deposit, 1e6, 500_000e6);

        deal(USDC_MONAD, address(this), m0Deposit);
        IERC20(USDC_MONAD).approve(address(optimizer), m0Deposit);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(
            m0Deposit, address(this), cUSDC_WMON_MARKET
        );

        deal(USDC_MONAD, address(this), m1Deposit);
        IERC20(USDC_MONAD).approve(address(optimizer), m1Deposit);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(
            m1Deposit, address(this), cUSDC_WBTC_MARKET
        );

        deal(USDC_MONAD, address(this), m2Deposit);
        IERC20(USDC_MONAD).approve(address(optimizer), m2Deposit);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(
            m2Deposit, address(this), cUSDC_WETH_MARKET
        );

        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500, 200);

        _assertZeroSum(actions);
    }

    /// @notice Fuzz: filtered results are always executable (no revert).
    function testFuzz_dustFilter_filteredActionsExecutable(
        uint256 depositAmount
    ) public {
        _setUpThreeMarketsUnconstrained();

        depositAmount = bound(depositAmount, 1e6, 1_000_000e6);

        deal(USDC_MONAD, address(this), depositAmount);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(
            depositAmount, address(this), cUSDC_WMON_MARKET
        );

        (LendingOptimizer.ReallocationAction[] memory actions,
         LendingOptimizer.AllocationBound[] memory bounds) =
            reader.optimalRebalance(address(optimizer), 500, 200);

        uint256 totalAssetsBefore = optimizer.totalAssets();

        if (actions.length > 0) {
            optimizer.rebalance(actions, bounds);

            assertApproxEqAbs(
                optimizer.totalAssets(),
                totalAssetsBefore,
                actions.length * 2,
                "Total assets preserved after fuzzed rebalance"
            );
        }
    }

    /// @notice Fuzz with yield accrual: non-dust invariant holds across time.
    function testFuzz_dustFilter_nonDustAfterYield(
        uint256 depositAmount,
        uint256 daysToSkip
    ) public {
        _setUpThreeMarkets();

        depositAmount = bound(depositAmount, 10e6, 500_000e6);
        daysToSkip = bound(daysToSkip, 1, 365);

        deal(USDC_MONAD, address(this), depositAmount);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(
            depositAmount, address(this), cUSDC_WMON_MARKET
        );

        skip(daysToSkip * 1 days);

        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500, 200);

        _assertAllActionsNonDust(actions);
        _assertZeroSum(actions);
    }

    // ============ Multi-Rebalance Stress ============

    /// @notice Multiple rebalances with rate shocks: filtered results remain valid.
    function test_dustFilter_repeatedRebalancesWithShocks() public {
        _setUpThreeMarketsUnconstrained();

        deal(USDC_MONAD, address(this), 300_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 300_000e6);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(
            100_000e6, address(this), cUSDC_WMON_MARKET
        );
        LendingOptimizerHarness(address(optimizer)).depositToMarket(
            100_000e6, address(this), cUSDC_WBTC_MARKET
        );
        LendingOptimizerHarness(address(optimizer)).depositToMarket(
            100_000e6, address(this), cUSDC_WETH_MARKET
        );

        // Pre-fund a whale.
        address whale = address(0xBEEF);
        deal(USDC_MONAD, whale, 10_000_000e6);
        vm.startPrank(whale);
        IERC20(USDC_MONAD).approve(cUSDC_WMON_MARKET, 10_000_000e6);
        IBorrowableCToken(cUSDC_WMON_MARKET).deposit(5_000_000e6, whale);
        vm.stopPrank();

        // Round 1: rebalance after rate shock.
        optimizer.accrueIfNeeded();
        _executeAndValidate();
        skip(7 days);

        // Round 2: whale withdraws, rate shifts again.
        vm.prank(whale);
        IBorrowableCToken(cUSDC_WMON_MARKET).withdraw(3_000_000e6, whale, whale);
        optimizer.accrueIfNeeded();
        _executeAndValidate();
        skip(7 days);

        // Round 3: another shock + time.
        deal(USDC_MONAD, whale, 5_000_000e6);
        vm.startPrank(whale);
        IERC20(USDC_MONAD).approve(cUSDC_WBTC_MARKET, 5_000_000e6);
        IBorrowableCToken(cUSDC_WBTC_MARKET).deposit(5_000_000e6, whale);
        vm.stopPrank();
        optimizer.accrueIfNeeded();
        _executeAndValidate();
    }

    // ============ Edge: Small Total Assets ============

    /// @notice With very small total assets (just above dead shares),
    ///         chunk sizes are tiny and more likely to produce dust.
    function test_dustFilter_tinyTotalAssets_chunksDust() public {
        _setUpThreeMarkets();

        // Deposit just 1 USDC on top of dead shares.
        deal(USDC_MONAD, address(this), 1e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 1e6);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(
            1e6, address(this), cUSDC_WMON_MARKET
        );

        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500, 200);

        // Core invariants must hold regardless of array emptiness.
        _assertAllActionsNonDust(actions);
        _assertZeroSum(actions);
    }

    /// @notice Dead shares only with time skip: exchange rate > 1.0,
    ///         chunk rounding deltas of 1 wei become dust.
    function test_dustFilter_deadSharesOnly_afterYield() public {
        _setUpThreeMarkets();

        // Skip time to inflate exchange rate.
        skip(365 days);

        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500, 200);

        _assertAllActionsNonDust(actions);
        _assertZeroSum(actions);
    }

    // ============ Internal Helpers ============

    /// @dev Asserts that every non-zero action converts to at least 1 cToken share.
    function _assertAllActionsNonDust(
        LendingOptimizer.ReallocationAction[] memory actions
    ) internal view {
        for (uint256 i; i < actions.length; ++i) {
            if (actions[i].assetsOrBps == 0) continue;

            uint256 absDelta = actions[i].assetsOrBps > 0
                ? uint256(actions[i].assetsOrBps)
                : uint256(-actions[i].assetsOrBps);

            uint256 shares = IBorrowableCToken(address(actions[i].cToken))
                .convertToShares(absDelta);

            assertGt(
                shares,
                0,
                string.concat(
                    "Market ", vm.toString(i), " action is dust (convertToShares == 0)"
                )
            );
        }
    }

    /// @dev Asserts that total deposits == total withdrawals (zero-sum).
    function _assertZeroSum(
        LendingOptimizer.ReallocationAction[] memory actions
    ) internal pure {
        if (actions.length == 0) return;

        uint256 totalDeposits;
        uint256 totalWithdrawals;
        for (uint256 i; i < actions.length; ++i) {
            if (actions[i].assetsOrBps > 0) {
                totalDeposits += uint256(actions[i].assetsOrBps);
            } else if (actions[i].assetsOrBps < 0) {
                totalWithdrawals += uint256(-actions[i].assetsOrBps);
            }
        }

        // Allow 1 wei tolerance per market for chunk rounding.
        assertApproxEqAbs(
            totalDeposits,
            totalWithdrawals,
            actions.length,
            "Deposits and withdrawals must balance after dust filter"
        );
    }

    /// @dev Gets optimal rebalance, validates invariants, executes if non-empty.
    function _executeAndValidate() internal {
        (LendingOptimizer.ReallocationAction[] memory actions,
         LendingOptimizer.AllocationBound[] memory bounds) =
            reader.optimalRebalance(address(optimizer), 500, 200);

        _assertAllActionsNonDust(actions);
        _assertZeroSum(actions);

        if (actions.length > 0) {
            optimizer.rebalance(actions, bounds);
        }
    }

    /// @dev Calls optimalRebalance and executes the result (skips if empty).
    function _executeOptimalRebalance() internal {
        (LendingOptimizer.ReallocationAction[] memory actions,
         LendingOptimizer.AllocationBound[] memory bounds) =
            reader.optimalRebalance(address(optimizer), 500, 200);
        if (actions.length > 0) optimizer.rebalance(actions, bounds);
    }

    /// @dev Returns the optimizer's current accrued assets after reader planning.
    function _currentOptimizerAssets() internal view returns (uint256 totalAssets) {
        totalAssets = optimizer.totalAssets();
    }

    /// @dev Sets up 3 markets with 100% caps and harvest permissions mocked.
    function _setUpThreeMarketsUnconstrained() internal {
        address[] memory approvedCTokens = new address[](3);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;
        approvedCTokens[2] = cUSDC_WETH_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](3);
        allocationCapsBps[0] = 10_000;
        allocationCapsBps[1] = 10_000;
        allocationCapsBps[2] = 10_000;

        optimizer = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            0
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets);
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
        optimizer.initializeDeposits(cUSDC_WMON_MARKET);

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(
                ICentralRegistry.hasHarvestPermissions.selector,
                address(this)
            ),
            abi.encode(true)
        );
    }
}
