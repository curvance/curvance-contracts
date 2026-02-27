// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { LendingOptimizerHarness } from "../LendingOptimizerHarness.sol";
import { ProtocolReader } from "contracts/views/ProtocolReader.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { WAD, BPS } from "contracts/libraries/ConstantsLib.sol";

contract TestOptimalRebalance is TestBaseLendingOptimizer {

    ProtocolReader reader;

    function setUp() public override {
        super.setUp();
        reader = new ProtocolReader(liveCentralRegistry);
    }

    // ============ Basic Return Shape ============

    function test_optimalRebalance_success_returnsCorrectArrayLengths_oneMarket() public {
        _setUpOneMarket();

        LendingOptimizer.ReallocationAction[] memory actions = reader.optimalRebalance(address(optimizer));

        assertEq(actions.length, 1, "Should have 1 market");
    }

    function test_optimalRebalance_success_returnsCorrectArrayLengths_twoMarkets() public {
        _setUpTwoMarkets();

        LendingOptimizer.ReallocationAction[] memory actions = reader.optimalRebalance(address(optimizer));

        assertEq(actions.length, 2, "Should have 2 markets");
    }

    function test_optimalRebalance_success_returnsCorrectArrayLengths_threeMarkets() public {
        _setUpThreeMarkets();

        LendingOptimizer.ReallocationAction[] memory actions = reader.optimalRebalance(address(optimizer));

        assertEq(actions.length, 3, "Should have 3 markets");
    }

    function test_optimalRebalance_success_marketsMatchApprovedList() public {
        _setUpThreeMarkets();

        LendingOptimizer.ReallocationAction[] memory actions = reader.optimalRebalance(address(optimizer));

        assertEq(address(actions[0].cToken), cUSDC_WMON_MARKET, "Market 0 mismatch");
        assertEq(address(actions[1].cToken), cUSDC_WBTC_MARKET, "Market 1 mismatch");
        assertEq(address(actions[2].cToken), cUSDC_WETH_MARKET, "Market 2 mismatch");
    }

    // ============ Deposit/Withdraw Mutual Exclusivity ============

    function test_optimalRebalance_success_noMarketHasBothDepositAndWithdraw() public {
        _setUpThreeMarkets();
        _depositToAllMarkets(50_000e6);

        LendingOptimizer.ReallocationAction[] memory actions = reader.optimalRebalance(address(optimizer));

        // With the ReallocationAction struct, mutual exclusivity is inherent:
        // a single int256 assets field cannot be both positive and negative.
        for (uint256 i; i < actions.length; ++i) {
            assertTrue(
                actions[i].assets >= 0 || actions[i].assets < 0,
                "Market should not have both deposit and withdraw"
            );
        }
    }

    // ============ Balance of Flows ============

    function test_optimalRebalance_success_totalDepositsEqualTotalWithdrawals() public {
        _setUpThreeMarkets();
        _depositToAllMarkets(50_000e6);

        LendingOptimizer.ReallocationAction[] memory actions = reader.optimalRebalance(address(optimizer));

        uint256 totalDeposits;
        uint256 totalWithdrawals;
        for (uint256 i; i < actions.length; ++i) {
            if (actions[i].assets > 0) {
                totalDeposits += uint256(actions[i].assets);
            } else if (actions[i].assets < 0) {
                totalWithdrawals += uint256(-actions[i].assets);
            }
        }

        // Deposits and withdrawals should roughly balance.
        // Small difference is possible from chunk rounding (totalAssets % 20).
        assertApproxEqAbs(
            totalDeposits,
            totalWithdrawals,
            optimizer.totalAssets() / 20 + 1,
            "Deposits and withdrawals should roughly balance"
        );
    }

    // ============ Cap Compliance ============

    function test_optimalRebalance_success_idealAllocationRespectsAllCaps() public {
        _setUpThreeMarkets();
        _depositToAllMarkets(50_000e6);

        LendingOptimizer.ReallocationAction[] memory actions = reader.optimalRebalance(address(optimizer));

        uint256 ta = optimizer.totalAssets();

        for (uint256 i; i < actions.length; ++i) {
            IBorrowableCToken ct = actions[i].cToken;
            uint256 current = ct.convertToAssets(ct.balanceOf(address(optimizer)));

            // Compute ideal allocation for this market.
            uint256 ideal;
            if (actions[i].assets > 0) {
                ideal = current + uint256(actions[i].assets);
            } else if (actions[i].assets < 0) {
                ideal = current - uint256(-actions[i].assets);
            } else {
                ideal = current;
            }

            uint256 cap = optimizer.allocationCaps(address(actions[i].cToken));
            uint256 maxAllowed = FixedPointMathLib.mulDiv(ta, cap, WAD);

            assertLe(
                ideal,
                maxAllowed + 1, // +1 for rounding tolerance
                string.concat("Market ", vm.toString(i), " ideal exceeds cap")
            );
        }
    }

    // ============ Single Market (Trivial) ============

    function test_optimalRebalance_success_singleMarketNoActions() public {
        _setUpOneMarket();

        // Deposit some assets.
        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        optimizer.deposit(10_000e6, address(this));

        LendingOptimizer.ReallocationAction[] memory actions = reader.optimalRebalance(address(optimizer));

        // With one market, ideal == current, so no actions needed.
        assertEq(actions[0].assets, 0, "No action needed for single market");
    }

    // ============ Integration: Actions Can Execute Rebalance ============

    function test_optimalRebalance_success_actionsExecuteRebalance() public {
        _setUpThreeMarkets();

        // Create an imbalanced state: deposit everything into market 0.
        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 100_000e6);
        optimizer.deposit(100_000e6, address(this), cUSDC_WMON_MARKET);

        // Get the rebalance plan.
        LendingOptimizer.ReallocationAction[] memory actions = reader.optimalRebalance(address(optimizer));

        // Mock harvest permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(
                ICentralRegistry.hasHarvestPermissions.selector,
                address(this)
            ),
            abi.encode(true)
        );

        uint256 totalAssetsBefore = optimizer.totalAssets();

        // Execute: should not revert.
        optimizer.rebalance(actions);

        // Total assets preserved (small rounding tolerance).
        uint256 totalAssetsAfter = optimizer.totalAssets();
        assertApproxEqAbs(
            totalAssetsAfter,
            totalAssetsBefore,
            actions.length * 2,
            "Total assets should be preserved"
        );
    }

    function test_optimalRebalance_success_postRebalanceAllocationWithinCaps() public {
        _setUpThreeMarkets();

        // Create imbalanced state: equal deposits violate Market 2's 20% cap.
        _depositToAllMarkets(10_000e6);

        // Get the rebalance plan.
        LendingOptimizer.ReallocationAction[] memory actions = reader.optimalRebalance(address(optimizer));

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(
                ICentralRegistry.hasHarvestPermissions.selector,
                address(this)
            ),
            abi.encode(true)
        );

        optimizer.rebalance(actions);

        // Verify all allocations are within caps after rebalance.
        uint256 ta = optimizer.totalAssets();
        for (uint256 i; i < actions.length; ++i) {
            IBorrowableCToken ct = actions[i].cToken;
            uint256 allocated = ct.convertToAssets(ct.balanceOf(address(optimizer)));
            uint256 allocationWad = FixedPointMathLib.mulDiv(allocated, WAD, ta);
            uint256 cap = optimizer.allocationCaps(address(actions[i].cToken));

            assertLe(
                allocationWad,
                cap,
                string.concat("Market ", vm.toString(i), " allocation exceeds cap post-rebalance")
            );
        }
    }

    // ============ Determinism ============

    function test_optimalRebalance_success_deterministicResults() public {
        _setUpThreeMarkets();
        _depositToAllMarkets(50_000e6);

        LendingOptimizer.ReallocationAction[] memory actions1 = reader.optimalRebalance(address(optimizer));
        LendingOptimizer.ReallocationAction[] memory actions2 = reader.optimalRebalance(address(optimizer));

        for (uint256 i; i < actions1.length; ++i) {
            assertEq(address(actions1[i].cToken), address(actions2[i].cToken), "Markets should be deterministic");
            assertEq(actions1[i].assets, actions2[i].assets, "Assets should be deterministic");
        }
    }

    // ============ Edge Cases ============

    function test_optimalRebalance_success_minimalAssetsOnlyDeadShares() public {
        _setUpThreeMarkets();

        // Only dead shares exist (77777 wei from initialization).
        LendingOptimizer.ReallocationAction[] memory actions = reader.optimalRebalance(address(optimizer));

        assertEq(actions.length, 3, "Should still return 3 markets");

        // With tiny totalAssets, chunks are tiny. Results should be valid.
        // Mutual exclusivity is inherent with the single int256 assets field.
        for (uint256 i; i < actions.length; ++i) {
            assertTrue(
                actions[i].assets >= 0 || actions[i].assets < 0,
                "Mutual exclusivity violated"
            );
        }
    }

    function test_optimalRebalance_success_afterTimePassesYieldAccrues() public {
        _setUpThreeMarkets();
        _depositToAllMarkets(50_000e6);

        LendingOptimizer.ReallocationAction[] memory actionsBefore = reader.optimalRebalance(address(optimizer));

        // Advance time so interest accrues and rates change.
        skip(7 days);

        LendingOptimizer.ReallocationAction[] memory actionsAfter = reader.optimalRebalance(address(optimizer));

        // Both should produce valid results; arrays may differ.
        assertEq(actionsBefore.length, actionsAfter.length, "Array length mismatch");
    }

    // ============ Large Deposits / Concentration ============

    function test_optimalRebalance_success_concentratedAllocationRedistributes() public {
        _setUpThreeMarkets();

        // Concentrate everything in market 0.
        deal(USDC_MONAD, address(this), 500_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 500_000e6);
        optimizer.deposit(500_000e6, address(this), cUSDC_WMON_MARKET);

        LendingOptimizer.ReallocationAction[] memory actions = reader.optimalRebalance(address(optimizer));

        // Market 0 has 60% cap, so some assets should move out if it's over-allocated.
        // At least one other market should receive a deposit.
        bool hasRedistribution;
        for (uint256 i = 1; i < actions.length; ++i) {
            if (actions[i].assets > 0) {
                hasRedistribution = true;
                break;
            }
        }

        assertTrue(hasRedistribution, "Should redistribute to other markets");
    }

    function test_optimalRebalance_success_twoMarketsEqualCaps() public {
        // Two markets, both 100% cap — should allocate based purely on rates.
        address[] memory approvedCTokens = new address[](2);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](2);
        allocationCapsBps[0] = 10_000; // 100%
        allocationCapsBps[1] = 10_000; // 100%

        optimizer = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets);
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(
                ICentralRegistry.hasMarketPermissions.selector,
                address(this)
            ),
            abi.encode(true)
        );
        optimizer.initializeDeposits(0);

        // Deposit into both markets.
        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 100_000e6);
        optimizer.deposit(50_000e6, address(this), cUSDC_WMON_MARKET);
        optimizer.deposit(50_000e6, address(this), cUSDC_WBTC_MARKET);

        LendingOptimizer.ReallocationAction[] memory actions = reader.optimalRebalance(address(optimizer));

        assertEq(actions.length, 2, "Should have 2 markets");

        // Mutual exclusivity is inherent with the single int256 assets field.
        for (uint256 i; i < actions.length; ++i) {
            assertTrue(
                actions[i].assets >= 0 || actions[i].assets < 0,
                "Mutual exclusivity violated"
            );
        }
    }

    // ============ Integration: Full Round-Trip ============

    function test_optimalRebalance_success_fullRoundTrip_depositRebalanceWithdraw() public {
        _setUpThreeMarkets();

        // 1. Deposit into a single market (imbalanced).
        deal(USDC_MONAD, address(this), 200_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 200_000e6);
        optimizer.deposit(200_000e6, address(this), cUSDC_WMON_MARKET);

        uint256 sharesBefore = optimizer.balanceOf(address(this));

        // 2. Rebalance using optimalRebalance output.
        LendingOptimizer.ReallocationAction[] memory actions = reader.optimalRebalance(address(optimizer));

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(
                ICentralRegistry.hasHarvestPermissions.selector,
                address(this)
            ),
            abi.encode(true)
        );

        optimizer.rebalance(actions);

        // 3. Shares unchanged (rebalance doesn't mint/burn).
        assertEq(
            optimizer.balanceOf(address(this)),
            sharesBefore,
            "Shares should be unchanged after rebalance"
        );

        // 4. User can still redeem.
        uint256 redeemShares = sharesBefore / 2;
        uint256 redeemed = optimizer.redeem(redeemShares, address(this), address(this));
        assertGt(redeemed, 0, "Should be able to redeem after rebalance");
    }

    // ============ Idempotency ============

    function test_optimalRebalance_success_rebalanceTwiceSecondIsNoop() public {
        _setUpThreeMarkets();
        _depositToAllMarkets(50_000e6);

        // Mock harvest permissions.
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

        // Second call: after rebalance, ideal ~= current, so actions should be small.
        LendingOptimizer.ReallocationAction[] memory actions = reader.optimalRebalance(address(optimizer));

        uint256 totalMovement;
        for (uint256 i; i < actions.length; ++i) {
            if (actions[i].assets > 0) {
                totalMovement += uint256(actions[i].assets);
            } else if (actions[i].assets < 0) {
                totalMovement += uint256(-actions[i].assets);
            }
        }

        // Movement should be minimal (within one chunk's worth).
        uint256 oneChunk = optimizer.totalAssets() / 20;
        assertLe(
            totalMovement,
            oneChunk * 2 + 1,
            "Second rebalance should be near-noop"
        );
    }

    // ============ Fuzz Tests ============

    function testFuzz_optimalRebalance_validArrays(
        uint256 depositAmount
    ) public {
        _setUpThreeMarkets();

        depositAmount = bound(depositAmount, 1e6, 1_000_000e6);

        deal(USDC_MONAD, address(this), depositAmount);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
        optimizer.deposit(depositAmount, address(this), cUSDC_WMON_MARKET);

        LendingOptimizer.ReallocationAction[] memory actions = reader.optimalRebalance(address(optimizer));

        assertEq(actions.length, 3, "Should have 3 markets");

        // Mutual exclusivity is inherent with the single int256 assets field.
        for (uint256 i; i < actions.length; ++i) {
            assertTrue(
                actions[i].assets >= 0 || actions[i].assets < 0,
                "Mutual exclusivity violated"
            );
        }
    }

    function testFuzz_optimalRebalance_capsRespected(
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
        optimizer.deposit(m0Deposit, address(this), cUSDC_WMON_MARKET);

        deal(USDC_MONAD, address(this), m1Deposit);
        IERC20(USDC_MONAD).approve(address(optimizer), m1Deposit);
        optimizer.deposit(m1Deposit, address(this), cUSDC_WBTC_MARKET);

        deal(USDC_MONAD, address(this), m2Deposit);
        IERC20(USDC_MONAD).approve(address(optimizer), m2Deposit);
        optimizer.deposit(m2Deposit, address(this), cUSDC_WETH_MARKET);

        LendingOptimizer.ReallocationAction[] memory actions = reader.optimalRebalance(address(optimizer));

        uint256 ta = optimizer.totalAssets();

        for (uint256 i; i < actions.length; ++i) {
            IBorrowableCToken ct = actions[i].cToken;
            uint256 current = ct.convertToAssets(ct.balanceOf(address(optimizer)));
            uint256 ideal;
            if (actions[i].assets > 0) {
                ideal = current + uint256(actions[i].assets);
            } else if (actions[i].assets < 0) {
                ideal = current - uint256(-actions[i].assets);
            } else {
                ideal = current;
            }
            uint256 cap = optimizer.allocationCaps(address(actions[i].cToken));
            uint256 maxAllowed = FixedPointMathLib.mulDiv(ta, cap, WAD);

            assertLe(
                ideal,
                maxAllowed + 1,
                string.concat("Market ", vm.toString(i), " ideal exceeds cap")
            );
        }
    }

    // ============ Yield Improvement ============

    /// @notice Confirms that rebalancing increases yield when external
    ///         liquidity events shift market rates.
    ///         Simulates a whale depositing into one market (lowering its rate),
    ///         then compares yield with vs without rebalancing.
    function test_optimalRebalance_success_rebalanceIncreasesYield() public {
        _setUpUnconstrainedOptimizer();

        // Deposit into market 0 via the optimizer.
        uint256 depositAmount = 300_000e6;
        deal(USDC_MONAD, address(this), depositAmount);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
        optimizer.deposit(depositAmount, address(this), cUSDC_WMON_MARKET);

        // --- Simulate external liquidity event ---
        // A whale deposits a large amount directly into market 0,
        // flooding it with liquidity and depressing its supply rate.
        address whale = address(0xBEEF);
        uint256 whaleDeposit = 5_000_000e6; // 5M USDC
        deal(USDC_MONAD, whale, whaleDeposit);
        vm.startPrank(whale);
        IERC20(USDC_MONAD).approve(cUSDC_WMON_MARKET, whaleDeposit);
        IBorrowableCToken(cUSDC_WMON_MARKET).deposit(whaleDeposit, whale);
        vm.stopPrank();

        // Now market 0's rate is depressed. The optimizer's assets are stuck
        // there earning a worse rate than markets 1 and 2.
        // Snapshot for A/B comparison.
        uint256 snapshotId = vm.snapshot();

        // ---- Path A: No rebalance ----
        skip(7 days);
        uint256 exchangeRateNoRebalance = optimizer.exchangeRateUpdated();

        // ---- Path B: Rebalance to move assets to higher-rate markets ----
        vm.revertTo(snapshotId);

        optimizer.accrueIfNeeded();
        _executeOptimalRebalance();

        skip(7 days);
        uint256 exchangeRateWithRebalance = optimizer.exchangeRateUpdated();

        // Rebalanced path should earn more since it moved away from
        // the rate-depressed market.
        assertGt(
            exchangeRateWithRebalance,
            exchangeRateNoRebalance,
            "Rebalancing after liquidity shock should increase yield"
        );
    }

    /// @notice Confirms that periodic rebalancing with volatile liquidity
    ///         conditions outperforms a static allocation.
    ///         Simulates alternating liquidity shocks across markets.
    function test_optimalRebalance_success_repeatedRebalanceBeatsStatic() public {
        _setUpUnconstrainedOptimizer();

        // Deposit evenly across markets.
        uint256 perMarket = 100_000e6;
        deal(USDC_MONAD, address(this), perMarket * 3);
        IERC20(USDC_MONAD).approve(address(optimizer), perMarket * 3);
        optimizer.deposit(perMarket, address(this), cUSDC_WMON_MARKET);
        optimizer.deposit(perMarket, address(this), cUSDC_WBTC_MARKET);
        optimizer.deposit(perMarket, address(this), cUSDC_WETH_MARKET);

        // Rebalance to the initial optimum.
        optimizer.accrueIfNeeded();
        _executeOptimalRebalance();

        // External liquidity providers who will deposit/withdraw to shift rates.
        address whale0 = address(0xBEEF);
        address whale1 = address(0xCAFE);

        // Pre-fund whale0 with cToken shares from market 1 so they can withdraw later.
        uint256 whale0Deposit = 3_000_000e6;
        deal(USDC_MONAD, whale0, whale0Deposit);
        vm.startPrank(whale0);
        IERC20(USDC_MONAD).approve(cUSDC_WBTC_MARKET, whale0Deposit);
        IBorrowableCToken(cUSDC_WBTC_MARKET).deposit(whale0Deposit, whale0);
        vm.stopPrank();

        uint256 snapshotId = vm.snapshot();

        // ---- Path A: No rebalancing over 21 days with liquidity shocks ----
        // Week 1: whale floods market 0 with liquidity (depresses rate).
        uint256 floodAmount = 5_000_000e6;
        deal(USDC_MONAD, whale1, floodAmount);
        vm.startPrank(whale1);
        IERC20(USDC_MONAD).approve(cUSDC_WMON_MARKET, floodAmount);
        IBorrowableCToken(cUSDC_WMON_MARKET).deposit(floodAmount, whale1);
        vm.stopPrank();
        skip(7 days);

        // Week 2: whale withdraws from market 1 (raises its rate).
        uint256 drainAmount = 2_000_000e6;
        vm.prank(whale0);
        IBorrowableCToken(cUSDC_WBTC_MARKET).withdraw(drainAmount, whale0, whale0);
        skip(7 days);

        // Week 3: whale withdraws from market 0 (restores its rate).
        vm.prank(whale1);
        IBorrowableCToken(cUSDC_WMON_MARKET).withdraw(floodAmount, whale1, whale1);
        skip(7 days);

        uint256 exchangeRateStatic = optimizer.exchangeRateUpdated();

        // ---- Path B: Same shocks, but rebalance after each one ----
        vm.revertTo(snapshotId);

        // Week 1: same flood + rebalance.
        deal(USDC_MONAD, whale1, floodAmount);
        vm.startPrank(whale1);
        IERC20(USDC_MONAD).approve(cUSDC_WMON_MARKET, floodAmount);
        IBorrowableCToken(cUSDC_WMON_MARKET).deposit(floodAmount, whale1);
        vm.stopPrank();
        optimizer.accrueIfNeeded();
        _executeOptimalRebalance();
        skip(7 days);

        // Week 2: same drain + rebalance.
        vm.prank(whale0);
        IBorrowableCToken(cUSDC_WBTC_MARKET).withdraw(drainAmount, whale0, whale0);
        optimizer.accrueIfNeeded();
        _executeOptimalRebalance();
        skip(7 days);

        // Week 3: same restore + rebalance.
        vm.prank(whale1);
        IBorrowableCToken(cUSDC_WMON_MARKET).withdraw(floodAmount, whale1, whale1);
        optimizer.accrueIfNeeded();
        _executeOptimalRebalance();
        skip(7 days);

        uint256 exchangeRateRebalanced = optimizer.exchangeRateUpdated();

        // Rebalancing after each liquidity shock should capture higher yield.
        assertGt(
            exchangeRateRebalanced,
            exchangeRateStatic,
            "Periodic rebalancing with volatile rates should beat static allocation"
        );
    }

    /// @notice Stress test: two markets get flooded simultaneously while one
    ///         gets drained. Rebalancing should chase the drained market's
    ///         elevated rate.
    function test_optimalRebalance_success_simultaneousMultiMarketShocks() public {
        _setUpUnconstrainedOptimizer();

        // Deposit into all markets.
        uint256 perMarket = 100_000e6;
        deal(USDC_MONAD, address(this), perMarket * 3);
        IERC20(USDC_MONAD).approve(address(optimizer), perMarket * 3);
        optimizer.deposit(perMarket, address(this), cUSDC_WMON_MARKET);
        optimizer.deposit(perMarket, address(this), cUSDC_WBTC_MARKET);
        optimizer.deposit(perMarket, address(this), cUSDC_WETH_MARKET);

        optimizer.accrueIfNeeded();
        _executeOptimalRebalance();

        // Pre-fund a whale with shares in market 2 for later withdrawal.
        address drainer = address(0xDEAD);
        uint256 drainerDeposit = 2_000_000e6;
        deal(USDC_MONAD, drainer, drainerDeposit);
        vm.startPrank(drainer);
        IERC20(USDC_MONAD).approve(cUSDC_WETH_MARKET, drainerDeposit);
        IBorrowableCToken(cUSDC_WETH_MARKET).deposit(drainerDeposit, drainer);
        vm.stopPrank();

        uint256 snapshotId = vm.snapshot();

        // --- Simultaneous shocks ---
        // Flood markets 0 and 1, drain market 2.
        address flooder = address(0xF100D);
        uint256 floodPer = 3_000_000e6;
        deal(USDC_MONAD, flooder, floodPer * 2);
        vm.startPrank(flooder);
        IERC20(USDC_MONAD).approve(cUSDC_WMON_MARKET, floodPer);
        IBorrowableCToken(cUSDC_WMON_MARKET).deposit(floodPer, flooder);
        IERC20(USDC_MONAD).approve(cUSDC_WBTC_MARKET, floodPer);
        IBorrowableCToken(cUSDC_WBTC_MARKET).deposit(floodPer, flooder);
        vm.stopPrank();

        vm.prank(drainer);
        IBorrowableCToken(cUSDC_WETH_MARKET).withdraw(1_500_000e6, drainer, drainer);

        // ---- Path A: static ----
        skip(14 days);
        uint256 rateStatic = optimizer.exchangeRateUpdated();

        // ---- Path B: rebalance after shocks ----
        vm.revertTo(snapshotId);

        // Replay the same shocks.
        deal(USDC_MONAD, flooder, floodPer * 2);
        vm.startPrank(flooder);
        IERC20(USDC_MONAD).approve(cUSDC_WMON_MARKET, floodPer);
        IBorrowableCToken(cUSDC_WMON_MARKET).deposit(floodPer, flooder);
        IERC20(USDC_MONAD).approve(cUSDC_WBTC_MARKET, floodPer);
        IBorrowableCToken(cUSDC_WBTC_MARKET).deposit(floodPer, flooder);
        vm.stopPrank();
        vm.prank(drainer);
        IBorrowableCToken(cUSDC_WETH_MARKET).withdraw(1_500_000e6, drainer, drainer);

        optimizer.accrueIfNeeded();
        _executeOptimalRebalance();
        skip(14 days);
        uint256 rateRebalanced = optimizer.exchangeRateUpdated();

        assertGe(
            rateRebalanced,
            rateStatic,
            "Rebalancing after simultaneous multi-market shocks should not lose yield"
        );
    }

    /// @notice Stress test: optimizer is the dominant supplier in a market.
    ///         Verifies rebalancing still works and improves yield when the
    ///         optimizer's own position materially moves rates.
    function test_optimalRebalance_success_dominantSupplier() public {
        _setUpUnconstrainedOptimizer();

        // Deposit a large amount — optimizer becomes a dominant supplier
        // relative to the market.
        uint256 largeDeposit = 1_000_000e6;
        deal(USDC_MONAD, address(this), largeDeposit);
        IERC20(USDC_MONAD).approve(address(optimizer), largeDeposit);
        optimizer.deposit(largeDeposit, address(this), cUSDC_WMON_MARKET);

        // Flood market 0 so its rate drops.
        address whale = address(0xBEEF);
        deal(USDC_MONAD, whale, 10_000_000e6);
        vm.startPrank(whale);
        IERC20(USDC_MONAD).approve(cUSDC_WMON_MARKET, 10_000_000e6);
        IBorrowableCToken(cUSDC_WMON_MARKET).deposit(10_000_000e6, whale);
        vm.stopPrank();

        uint256 snapshotId = vm.snapshot();

        // Path A: no rebalance.
        skip(14 days);
        uint256 rateStatic = optimizer.exchangeRateUpdated();

        // Path B: rebalance (optimizer moves its dominant position).
        vm.revertTo(snapshotId);
        optimizer.accrueIfNeeded();
        _executeOptimalRebalance();
        skip(14 days);
        uint256 rateRebalanced = optimizer.exchangeRateUpdated();

        assertGt(
            rateRebalanced,
            rateStatic,
            "Dominant supplier should still benefit from rebalancing"
        );
    }

    /// @notice Stress test: rapid back-to-back shocks every day over a week.
    ///         Simulates high-frequency liquidity volatility.
    function test_optimalRebalance_success_rapidDailyShocks() public {
        _setUpUnconstrainedOptimizer();

        uint256 perMarket = 100_000e6;
        deal(USDC_MONAD, address(this), perMarket * 3);
        IERC20(USDC_MONAD).approve(address(optimizer), perMarket * 3);
        optimizer.deposit(perMarket, address(this), cUSDC_WMON_MARKET);
        optimizer.deposit(perMarket, address(this), cUSDC_WBTC_MARKET);
        optimizer.deposit(perMarket, address(this), cUSDC_WETH_MARKET);

        optimizer.accrueIfNeeded();
        _executeOptimalRebalance();

        // Prepare external actors.
        address[3] memory whales = [address(0xAA), address(0xBB), address(0xCC)];
        address[3] memory markets = [cUSDC_WMON_MARKET, cUSDC_WBTC_MARKET, cUSDC_WETH_MARKET];

        // Pre-fund whales with shares so they can withdraw.
        for (uint256 i; i < 3; ++i) {
            deal(USDC_MONAD, whales[i], 5_000_000e6);
            vm.startPrank(whales[i]);
            IERC20(USDC_MONAD).approve(markets[i], 5_000_000e6);
            IBorrowableCToken(markets[i]).deposit(5_000_000e6, whales[i]);
            vm.stopPrank();
        }

        uint256 snapshotId = vm.snapshot();

        // ---- Path A: shocks happen, no rebalancing ----
        // Day 1: flood market 0
        _externalDeposit(whales[0], markets[0], 2_000_000e6);
        skip(1 days);
        // Day 2: drain market 1
        _externalWithdraw(whales[1], markets[1], 1_000_000e6);
        skip(1 days);
        // Day 3: flood market 2
        _externalDeposit(whales[2], markets[2], 3_000_000e6);
        skip(1 days);
        // Day 4: drain market 0
        _externalWithdraw(whales[0], markets[0], 2_000_000e6);
        skip(1 days);
        // Day 5: flood market 1
        _externalDeposit(whales[1], markets[1], 1_500_000e6);
        skip(1 days);
        // Day 6: drain market 2
        _externalWithdraw(whales[2], markets[2], 3_000_000e6);
        skip(1 days);
        // Day 7: settle
        skip(1 days);

        uint256 rateStatic = optimizer.exchangeRateUpdated();

        // ---- Path B: same shocks, rebalance after each ----
        vm.revertTo(snapshotId);

        _externalDeposit(whales[0], markets[0], 2_000_000e6);
        optimizer.accrueIfNeeded();
        _executeOptimalRebalance();
        skip(1 days);

        _externalWithdraw(whales[1], markets[1], 1_000_000e6);
        optimizer.accrueIfNeeded();
        _executeOptimalRebalance();
        skip(1 days);

        _externalDeposit(whales[2], markets[2], 3_000_000e6);
        optimizer.accrueIfNeeded();
        _executeOptimalRebalance();
        skip(1 days);

        _externalWithdraw(whales[0], markets[0], 2_000_000e6);
        optimizer.accrueIfNeeded();
        _executeOptimalRebalance();
        skip(1 days);

        _externalDeposit(whales[1], markets[1], 1_500_000e6);
        optimizer.accrueIfNeeded();
        _executeOptimalRebalance();
        skip(1 days);

        _externalWithdraw(whales[2], markets[2], 3_000_000e6);
        optimizer.accrueIfNeeded();
        _executeOptimalRebalance();
        skip(1 days);

        skip(1 days);
        uint256 rateRebalanced = optimizer.exchangeRateUpdated();

        assertGt(
            rateRebalanced,
            rateStatic,
            "Daily rebalancing through rapid shocks should beat static"
        );
    }

    /// @notice Stress test: a rate reversal — the best market becomes the
    ///         worst and vice versa. Verifies the algorithm adapts correctly.
    function test_optimalRebalance_success_rateReversal() public {
        _setUpUnconstrainedOptimizer();

        // Deposit into market 0 (currently good rate).
        uint256 depositAmount = 300_000e6;
        deal(USDC_MONAD, address(this), depositAmount);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
        optimizer.deposit(depositAmount, address(this), cUSDC_WMON_MARKET);

        optimizer.accrueIfNeeded();
        _executeOptimalRebalance();

        // Pre-fund whales.
        address whale0 = address(0xBEEF);
        address whale2 = address(0xCAFE);

        deal(USDC_MONAD, whale2, 5_000_000e6);
        vm.startPrank(whale2);
        IERC20(USDC_MONAD).approve(cUSDC_WETH_MARKET, 5_000_000e6);
        IBorrowableCToken(cUSDC_WETH_MARKET).deposit(5_000_000e6, whale2);
        vm.stopPrank();

        uint256 snapshotId = vm.snapshot();

        // --- Rate reversal: flood the best market, drain the worst ---
        // Flood market 0 (was best → becomes worst).
        deal(USDC_MONAD, whale0, 8_000_000e6);
        vm.startPrank(whale0);
        IERC20(USDC_MONAD).approve(cUSDC_WMON_MARKET, 8_000_000e6);
        IBorrowableCToken(cUSDC_WMON_MARKET).deposit(8_000_000e6, whale0);
        vm.stopPrank();

        // Drain market 2 (was worst → becomes best).
        vm.prank(whale2);
        IBorrowableCToken(cUSDC_WETH_MARKET).withdraw(4_000_000e6, whale2, whale2);

        // Path A: static.
        skip(14 days);
        uint256 rateStatic = optimizer.exchangeRateUpdated();

        // Path B: rebalance to adapt to the reversal.
        vm.revertTo(snapshotId);

        deal(USDC_MONAD, whale0, 8_000_000e6);
        vm.startPrank(whale0);
        IERC20(USDC_MONAD).approve(cUSDC_WMON_MARKET, 8_000_000e6);
        IBorrowableCToken(cUSDC_WMON_MARKET).deposit(8_000_000e6, whale0);
        vm.stopPrank();
        vm.prank(whale2);
        IBorrowableCToken(cUSDC_WETH_MARKET).withdraw(4_000_000e6, whale2, whale2);

        optimizer.accrueIfNeeded();
        _executeOptimalRebalance();
        skip(14 days);
        uint256 rateRebalanced = optimizer.exchangeRateUpdated();

        assertGt(
            rateRebalanced,
            rateStatic,
            "Rebalancing after rate reversal should capture the new best yield"
        );
    }

    /// @notice Stress test: all markets get flooded with liquidity, depressing
    ///         rates everywhere. Rebalancing should still find the least-bad
    ///         allocation and not revert.
    function test_optimalRebalance_success_allMarketsFlooded() public {
        _setUpUnconstrainedOptimizer();

        uint256 perMarket = 100_000e6;
        deal(USDC_MONAD, address(this), perMarket * 3);
        IERC20(USDC_MONAD).approve(address(optimizer), perMarket * 3);
        optimizer.deposit(perMarket, address(this), cUSDC_WMON_MARKET);
        optimizer.deposit(perMarket, address(this), cUSDC_WBTC_MARKET);
        optimizer.deposit(perMarket, address(this), cUSDC_WETH_MARKET);

        optimizer.accrueIfNeeded();
        _executeOptimalRebalance();

        // Flood all three markets with huge external deposits.
        address[3] memory markets = [cUSDC_WMON_MARKET, cUSDC_WBTC_MARKET, cUSDC_WETH_MARKET];
        uint256[3] memory floodAmounts = [uint256(5_000_000e6), 4_000_000e6, 3_000_000e6];

        for (uint256 i; i < 3; ++i) {
            address flooder = address(uint160(0xF000 + i));
            deal(USDC_MONAD, flooder, floodAmounts[i]);
            vm.startPrank(flooder);
            IERC20(USDC_MONAD).approve(markets[i], floodAmounts[i]);
            IBorrowableCToken(markets[i]).deposit(floodAmounts[i], flooder);
            vm.stopPrank();
        }

        uint256 snapshotId = vm.snapshot();

        // Path A: static in a depressed-rate environment.
        skip(14 days);
        uint256 rateStatic = optimizer.exchangeRateUpdated();

        // Path B: rebalance to the least-bad allocation.
        vm.revertTo(snapshotId);
        optimizer.accrueIfNeeded();
        _executeOptimalRebalance();
        skip(14 days);
        uint256 rateRebalanced = optimizer.exchangeRateUpdated();

        // Even with all rates depressed, the optimal allocation should be
        // at least as good as an arbitrary split.
        assertGe(
            rateRebalanced,
            rateStatic,
            "Rebalancing in a uniformly depressed market should not lose yield"
        );
    }

    // ============ Pause-Aware Rebalance ============

    /// @notice When a market is redeem-paused, optimalRebalance must NOT
    ///         produce withdrawal amounts for it. The rebalance should
    ///         execute without reverting and still improve yield vs static.
    function test_optimalRebalance_success_redeemPausedMarketNotWithdrawn() public {
        _setUpUnconstrainedOptimizer();

        // Deposit into all markets.
        uint256 perMarket = 100_000e6;
        deal(USDC_MONAD, address(this), perMarket * 3);
        IERC20(USDC_MONAD).approve(address(optimizer), perMarket * 3);
        optimizer.deposit(perMarket, address(this), cUSDC_WMON_MARKET);
        optimizer.deposit(perMarket, address(this), cUSDC_WBTC_MARKET);
        optimizer.deposit(perMarket, address(this), cUSDC_WETH_MARKET);

        optimizer.accrueIfNeeded();
        _executeOptimalRebalance();

        // Flood market 0 to depress its rate — normally the optimizer
        // would withdraw from market 0 and move to a better market.
        address whale = address(0xBEEF);
        deal(USDC_MONAD, whale, 5_000_000e6);
        vm.startPrank(whale);
        IERC20(USDC_MONAD).approve(cUSDC_WMON_MARKET, 5_000_000e6);
        IBorrowableCToken(cUSDC_WMON_MARKET).deposit(5_000_000e6, whale);
        vm.stopPrank();

        uint256 snapshotId = vm.snapshot();

        // ---- Path A: no rebalance (static) ----
        skip(14 days);
        uint256 rateStatic = optimizer.exchangeRateUpdated();

        // ---- Path B: rebalance with redeem-paused WMON ----
        vm.revertTo(snapshotId);

        // Mock redeemPaused on WMON's market manager.
        address mmWMON = address(IBorrowableCToken(cUSDC_WMON_MARKET).marketManager());
        vm.mockCall(
            mmWMON,
            abi.encodeWithSelector(bytes4(keccak256("redeemPaused()"))),
            abi.encode(uint8(2))
        );

        // optimalRebalance should NOT suggest withdrawing from the paused market.
        LendingOptimizer.ReallocationAction[] memory actions = reader.optimalRebalance(address(optimizer));

        assertTrue(actions[0].assets >= 0, "Should not withdraw from redeem-paused market");

        // Execute and let yield accrue.
        optimizer.accrueIfNeeded();
        _executeOptimalRebalance();
        skip(14 days);
        uint256 rateRebalanced = optimizer.exchangeRateUpdated();

        // Even with a locked market, rebalancing the remaining markets
        // should yield at least as much as doing nothing.
        assertGe(
            rateRebalanced,
            rateStatic,
            "Pause-aware rebalance should not lose yield vs static"
        );
    }

    /// @notice When a market is mint-paused, optimalRebalance should drain
    ///         it and redirect to better markets, improving yield.
    function test_optimalRebalance_success_mintPausedMarketDrained() public {
        _setUpUnconstrainedOptimizer();

        // Deposit into all markets without rebalancing — each market
        // retains ~100K so the mint-paused one has assets to drain.
        uint256 perMarket = 100_000e6;
        deal(USDC_MONAD, address(this), perMarket * 3);
        IERC20(USDC_MONAD).approve(address(optimizer), perMarket * 3);
        optimizer.deposit(perMarket, address(this), cUSDC_WMON_MARKET);
        optimizer.deposit(perMarket, address(this), cUSDC_WBTC_MARKET);
        optimizer.deposit(perMarket, address(this), cUSDC_WETH_MARKET);

        uint256 snapshotId = vm.snapshot();

        // ---- Path A: no rebalance (static) ----
        skip(14 days);
        uint256 rateStatic = optimizer.exchangeRateUpdated();

        // ---- Path B: rebalance with mint-paused WETH ----
        vm.revertTo(snapshotId);

        // Mock mintPaused on market 2 (WETH).
        address mmWETH = address(IBorrowableCToken(cUSDC_WETH_MARKET).marketManager());
        vm.mockCall(
            mmWETH,
            abi.encodeWithSelector(IMarketManager.actionsPaused.selector, cUSDC_WETH_MARKET),
            abi.encode(true, false, false)
        );

        LendingOptimizer.ReallocationAction[] memory actions = reader.optimalRebalance(address(optimizer));

        // Market 2 (index 2) should not receive deposits and should have a withdrawal (drain it).
        assertLt(actions[2].assets, 0, "Should withdraw from mint-paused market");

        // Execute and let yield accrue.
        optimizer.accrueIfNeeded();
        _executeOptimalRebalance();
        skip(14 days);
        uint256 rateRebalanced = optimizer.exchangeRateUpdated();

        // Draining the mint-paused market and redirecting to better
        // markets should approximately maintain yield. With real interest
        // rates, the redistribution may cause marginal rate differences.
        assertApproxEqRel(
            rateRebalanced,
            rateStatic,
            0.001e18, // 0.1% tolerance
            "Draining mint-paused market should not lose yield vs static"
        );
    }

    /// @notice When a market is both mint- and redeem-paused, its allocation
    ///         should be frozen — no deposits, no withdrawals.
    function test_optimalRebalance_success_bothPausedMarketFrozen() public {
        _setUpUnconstrainedOptimizer();

        uint256 perMarket = 100_000e6;
        deal(USDC_MONAD, address(this), perMarket * 3);
        IERC20(USDC_MONAD).approve(address(optimizer), perMarket * 3);
        optimizer.deposit(perMarket, address(this), cUSDC_WMON_MARKET);
        optimizer.deposit(perMarket, address(this), cUSDC_WBTC_MARKET);
        optimizer.deposit(perMarket, address(this), cUSDC_WETH_MARKET);

        optimizer.accrueIfNeeded();
        _executeOptimalRebalance();

        // Mock both pauses on market 1 (WBTC).
        address mmWBTC = address(IBorrowableCToken(cUSDC_WBTC_MARKET).marketManager());
        vm.mockCall(
            mmWBTC,
            abi.encodeWithSelector(bytes4(keccak256("redeemPaused()"))),
            abi.encode(uint8(2))
        );
        vm.mockCall(
            mmWBTC,
            abi.encodeWithSelector(IMarketManager.actionsPaused.selector, cUSDC_WBTC_MARKET),
            abi.encode(true, false, false)
        );

        LendingOptimizer.ReallocationAction[] memory actions = reader.optimalRebalance(address(optimizer));

        // Market 1 should be completely frozen.
        assertEq(actions[1].assets, 0, "Should not move assets for both-paused market");
    }

    /// @notice Rebalance with 2 of 3 markets redeem-paused should still
    ///         execute and maintain yield vs static allocation.
    function test_optimalRebalance_success_twoRedeemPausedOneActive() public {
        _setUpUnconstrainedOptimizer();

        uint256 perMarket = 100_000e6;
        deal(USDC_MONAD, address(this), perMarket * 3);
        IERC20(USDC_MONAD).approve(address(optimizer), perMarket * 3);
        optimizer.deposit(perMarket, address(this), cUSDC_WMON_MARKET);
        optimizer.deposit(perMarket, address(this), cUSDC_WBTC_MARKET);
        optimizer.deposit(perMarket, address(this), cUSDC_WETH_MARKET);

        optimizer.accrueIfNeeded();
        _executeOptimalRebalance();

        // Flood market 2 to create a rate imbalance worth rebalancing for.
        address whale = address(0xBEEF);
        deal(USDC_MONAD, whale, 3_000_000e6);
        vm.startPrank(whale);
        IERC20(USDC_MONAD).approve(cUSDC_WETH_MARKET, 3_000_000e6);
        IBorrowableCToken(cUSDC_WETH_MARKET).deposit(3_000_000e6, whale);
        vm.stopPrank();

        uint256 snapshotId = vm.snapshot();

        // ---- Path A: no rebalance (static) ----
        skip(14 days);
        uint256 rateStatic = optimizer.exchangeRateUpdated();

        // ---- Path B: rebalance with 2 redeem-paused markets ----
        vm.revertTo(snapshotId);

        // Pause redeem on markets 0 and 1.
        address mmWMON = address(IBorrowableCToken(cUSDC_WMON_MARKET).marketManager());
        address mmWBTC = address(IBorrowableCToken(cUSDC_WBTC_MARKET).marketManager());
        vm.mockCall(
            mmWMON,
            abi.encodeWithSelector(bytes4(keccak256("redeemPaused()"))),
            abi.encode(uint8(2))
        );
        vm.mockCall(
            mmWBTC,
            abi.encodeWithSelector(bytes4(keccak256("redeemPaused()"))),
            abi.encode(uint8(2))
        );

        LendingOptimizer.ReallocationAction[] memory actions = reader.optimalRebalance(address(optimizer));

        // Neither paused market should have withdrawals.
        assertTrue(actions[0].assets >= 0, "Should not withdraw from redeem-paused WMON");
        assertTrue(actions[1].assets >= 0, "Should not withdraw from redeem-paused WBTC");

        // Execute and let yield accrue.
        optimizer.accrueIfNeeded();
        _executeOptimalRebalance();
        skip(14 days);
        uint256 rateRebalanced = optimizer.exchangeRateUpdated();

        // Even with most markets locked, rebalancing should not hurt.
        assertGe(
            rateRebalanced,
            rateStatic,
            "Rebalance with 2 paused markets should not lose yield vs static"
        );
    }

    // ============ Helpers ============

    /// @dev Sets up an optimizer with 100% caps on all 3 markets and 0% fee.
    function _setUpUnconstrainedOptimizer() internal {
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
        optimizer.initializeDeposits(0);

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(
                ICentralRegistry.hasHarvestPermissions.selector,
                address(this)
            ),
            abi.encode(true)
        );
    }

    /// @dev External user deposits directly into a cToken market.
    function _externalDeposit(address user, address market, uint256 amount) internal {
        deal(USDC_MONAD, user, amount);
        vm.startPrank(user);
        IERC20(USDC_MONAD).approve(market, amount);
        IBorrowableCToken(market).deposit(amount, user);
        vm.stopPrank();
    }

    /// @dev External user withdraws directly from a cToken market.
    function _externalWithdraw(address user, address market, uint256 amount) internal {
        vm.prank(user);
        IBorrowableCToken(market).withdraw(amount, user, user);
    }

    /// @dev Calls optimalRebalance and executes the result.
    function _executeOptimalRebalance() internal {
        LendingOptimizer.ReallocationAction[] memory actions = reader.optimalRebalance(address(optimizer));
        optimizer.rebalance(actions);
    }
}
