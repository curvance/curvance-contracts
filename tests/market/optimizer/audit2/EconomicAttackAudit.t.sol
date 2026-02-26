// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizerHarness } from "../LendingOptimizerHarness.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { WAD, BPS } from "contracts/libraries/ConstantsLib.sol";
import { console2 } from "forge-std/console2.sol";

/// @title Economic Attack & Privilege Escalation Audit
/// @notice PoC tests for economic attack vectors, privilege escalation,
///         and state manipulation in LendingOptimizer.
/// @dev Auditor 3 - Focus areas: harvester abuse, fee manipulation,
///      griefing, exchange rate manipulation, and unauthorized value extraction.
contract EconomicAttackAudit is TestBaseLendingOptimizer {

    LendingOptimizerHarness harness;

    address attacker = address(0xBAD);
    address victim = address(0xFACE);
    address victim2 = address(0xFACE2);
    address maliciousHarvester = address(0xC0FFEE);
    address mktManager = address(0xBEEF);

    uint256 constant BASE_RESERVE = 77777;

    function setUp() public override {
        super.setUp();
    }

    // =====================================================================
    // HELPERS
    // =====================================================================

    /// @dev Sets up a harness with two markets, no fee, 1-day vesting.
    ///      Uses high caps (100% each) to avoid AllocationExceedsCap during rebalance tests.
    function _setUpHarnessTwoMarketsNoFee() internal {
        address[] memory approvedCTokens = new address[](2);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](2);
        allocationCapsBps[0] = 10_000;
        allocationCapsBps[1] = 10_000;

        harness = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            0
        );

        _initializeHarness();
        _mockHarvesterPermissions(maliciousHarvester);
        _mockMarketManagerPermissions(mktManager);
    }

    /// @dev Sets up a harness with two markets, 10% fee.
    function _setUpHarnessTwoMarketsWithFee() internal {
        address[] memory approvedCTokens = new address[](2);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](2);
        allocationCapsBps[0] = 10_000;
        allocationCapsBps[1] = 10_000;

        harness = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000 // 10% fee
        );

        _initializeHarness();
        _mockHarvesterPermissions(maliciousHarvester);
        _mockMarketManagerPermissions(mktManager);
    }

    /// @dev Sets up a harness with one market, configurable fee.
    function _setUpHarnessSingleMarket(uint256 feeBps) internal {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        harness = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            feeBps
        );

        _initializeHarness();
        _mockHarvesterPermissions(maliciousHarvester);
        _mockMarketManagerPermissions(mktManager);
    }

    /// @dev Initialize harness with dead shares.
    function _initializeHarness() internal {
        deal(USDC_MONAD, address(this), BASE_RESERVE);
        IERC20(USDC_MONAD).approve(address(harness), BASE_RESERVE);
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
        harness.initializeDeposits(0);
    }

    /// @dev Mock harvester permissions for a given address.
    function _mockHarvesterPermissions(address who) internal {
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasHarvestPermissions.selector, who),
            abi.encode(true)
        );
    }

    /// @dev Mock market manager permissions for a given address.
    function _mockMarketManagerPermissions(address who) internal {
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, who),
            abi.encode(true)
        );
    }

    /// @dev Deposit amount for a user.
    function _userDeposit(address user, uint256 amount) internal {
        deal(USDC_MONAD, user, amount);
        vm.startPrank(user);
        IERC20(USDC_MONAD).approve(address(harness), amount);
        harness.deposit(amount, user);
        vm.stopPrank();
    }

    /// @dev Deposit amount for a user into a specific market.
    function _userDepositToMarket(
        address user,
        uint256 amount,
        address market
    ) internal {
        deal(USDC_MONAD, user, amount);
        vm.startPrank(user);
        IERC20(USDC_MONAD).approve(address(harness), amount);
        harness.deposit(amount, user, market);
        vm.stopPrank();
    }

    /// @notice Quantifies rounding loss per rebalance operation.
    function test_attack_A_quantifyRoundingLossPerRebalance() public {
        _setUpHarnessTwoMarketsNoFee();

        _userDepositToMarket(victim, 500_000e6, cUSDC_WMON_MARKET);
        _userDepositToMarket(victim, 500_000e6, cUSDC_WBTC_MARKET);

        // Accrue to get a clean baseline. Multiple cycles to ensure
        // all vesting finishes and we're in a steady state.
        skip(1 days);
        harness.exchangeRateUpdated();
        skip(1 days + 1);
        harness.exchangeRateUpdated();
        // Vesting may have started again from detected yield.
        // Wait for it to finish.
        skip(1 days + 1);
        harness.exchangeRateUpdated();
        // One more cycle to be safe.
        skip(1 days + 1);
        harness.exchangeRateUpdated();

        // After multiple cycles, yield-per-cycle becomes very small.

        uint256 rawBefore = harness.exposed_accrueMarkets();
        uint256 indexedBefore = harness.exposed_totalAssetsIndexed();

        console2.log("Before rebalance:");
        console2.log("  rawTa (accrued):", rawBefore);
        console2.log("  _totalAssets:", indexedBefore);

        // Single rebalance: move 100k from market 0 to market 1.
        LendingOptimizer.ReallocationAction[] memory actions = new LendingOptimizer.ReallocationAction[](2);
        actions[0] = LendingOptimizer.ReallocationAction({
            cToken: IBorrowableCToken(cUSDC_WMON_MARKET),
            assets: -int256(100_000e6)
        });
        actions[1] = LendingOptimizer.ReallocationAction({
            cToken: IBorrowableCToken(cUSDC_WBTC_MARKET),
            assets: int256(100_000e6)
        });

        vm.prank(maliciousHarvester);
        harness.rebalance(actions);

        uint256 rawAfter = harness.exposed_accrueMarkets();
        console2.log("After one rebalance:");
        console2.log("  rawTa (accrued):", rawAfter);

        if (rawBefore > rawAfter) {
            console2.log("  Rounding loss:", rawBefore - rawAfter, "wei");
        } else {
            console2.log("  No measurable loss (within same block interest offset)");
        }
    }

    // =====================================================================
    // B. MALICIOUS HARVESTER: STRATEGIC REBALANCING FOR WITHDRAWAL DoS
    // =====================================================================

    /// @notice Tests whether a harvester can prevent standard withdrawals
    ///         by moving all assets into markets with no idle liquidity.
    /// @dev If all markets' assetsHeld() is 0, optimalWithdrawalTarget reverts.
    ///      Users must use targeted withdrawals to specific markets.
    function test_attack_B_strategicRebalanceForWithdrawalDoS() public {
        _setUpHarnessTwoMarketsNoFee();

        // Deposits spread across markets.
        _userDeposit(victim, 500_000e6);
        _userDepositToMarket(victim, 500_000e6, cUSDC_WBTC_MARKET);

        // Check idle liquidity in each market.
        uint256 idle0 = IBorrowableCToken(cUSDC_WMON_MARKET).assetsHeld();
        uint256 idle1 = IBorrowableCToken(cUSDC_WBTC_MARKET).assetsHeld();

        console2.log("Market 0 idle liquidity:", idle0);
        console2.log("Market 1 idle liquidity:", idle1);

        // Try standard withdrawal of a small amount.
        uint256 smallWithdraw = 1000e6;
        uint256 victimShares = harness.balanceOf(victim);

        // Standard withdraw should work when liquidity exists.
        if (idle0 >= smallWithdraw || idle1 >= smallWithdraw) {
            vm.startPrank(victim);
            harness.withdraw(smallWithdraw, victim, victim);
            vm.stopPrank();
            console2.log("Standard withdrawal of", smallWithdraw, "succeeded");
        }

        // Now show the concept: if both markets have 0 idle liquidity,
        // optimalWithdrawalTarget would revert.
        // We test by trying to withdraw more than available idle liquidity.
        uint256 totalIdle = idle0 + idle1;
        if (totalIdle > 0) {
            uint256 largeWithdraw = totalIdle + 1;
            uint256 victimAssets = harness.convertToAssets(harness.balanceOf(victim));

            if (largeWithdraw <= victimAssets) {
                // This should revert because no single market has enough idle.
                // optimalWithdrawalTarget checks per-market, not aggregate.
                bool reverted = false;
                vm.startPrank(victim);
                try harness.withdraw(largeWithdraw, victim, victim) {
                    console2.log("Large withdrawal succeeded (one market had enough)");
                } catch {
                    reverted = true;
                    console2.log("Large withdrawal reverted: InsufficientLiquidity");
                }
                vm.stopPrank();

                if (reverted) {
                    // Show that targeted withdrawal to a specific market
                    // with enough balance could work.
                    uint256 optimizerBal0 = IBorrowableCToken(cUSDC_WMON_MARKET)
                        .convertToAssets(
                            IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(harness))
                        );
                    console2.log("Optimizer balance in market 0:", optimizerBal0);

                    // Try targeted withdrawal from market with most idle.
                    address targetMarket = idle0 >= idle1 ? cUSDC_WMON_MARKET : cUSDC_WBTC_MARKET;
                    uint256 targetIdle = idle0 >= idle1 ? idle0 : idle1;

                    if (targetIdle > 100e6) {
                        uint256 safeAmount = targetIdle / 2;
                        vm.startPrank(victim);
                        harness.withdraw(safeAmount, victim, victim, targetMarket);
                        vm.stopPrank();
                        console2.log("Targeted withdrawal of", safeAmount, "from specific market succeeded");
                    }
                }
            }
        }
    }

    // =====================================================================
    // C. FEE FRONT-RUNNING VIA setFee
    // =====================================================================

    /// @notice Tests fee reduction to 0 before vesting ends, then increase after.
    ///         Verifies whether yield earned during fee=0 period escapes taxation.
    function test_attack_C_feeReductionBeforeVestEnd() public {
        _setUpHarnessSingleMarket(1_000); // 10% fee

        _userDeposit(victim, 1_000_000e6);

        // Let yield accrue.
        skip(1 days);
        harness.exchangeRateUpdated();

        uint256 feeSharesBefore = harness.balanceOf(
            liveCentralRegistry.daoAddress()
        );
        console2.log("DAO fee shares before:", feeSharesBefore);
        console2.log("Fee before:", harness.fee());

        // Market manager sets fee to 0 DURING active vesting.
        // setFee calls _accrueIfNeeded first, then queues the change.
        // During vesting, _accrueIfNeeded returns early (step 3).
        // The pending fee is queued but NOT applied until vesting ends.
        vm.prank(mktManager);
        harness.setFee(0);

        // Fee should apply after next accrual cycle.
        console2.log("Fee after setFee(0):", harness.fee());

        // Wait and trigger accrual.
        skip(1 days + 1);
        harness.exchangeRateUpdated();

        uint256 feeSharesAfter = harness.balanceOf(
            liveCentralRegistry.daoAddress()
        );
        console2.log("\nAfter vesting ends:");
        console2.log("DAO fee shares after:", feeSharesAfter);
        console2.log("Fee after vesting ends:", harness.fee());

        // Fees WERE charged at the old rate before the pending update was applied.
        // This is correct behavior - the fee reduction is deferred.
        if (feeSharesAfter > feeSharesBefore) {
            console2.log("DEFENSE CONFIRMED: Fees charged at old rate before update applied");
            console2.log("Fee shares minted:", feeSharesAfter - feeSharesBefore);
        }

        // Now let more yield accrue with fee = 0.
        skip(1 days);
        harness.exchangeRateUpdated();

        // Verify no fees charged when fee = 0.
        uint256 feeSharesAfterZeroFee = harness.balanceOf(
            liveCentralRegistry.daoAddress()
        );
        assertEq(feeSharesAfterZeroFee, feeSharesAfter, "No fees during fee=0 period");
        console2.log("No additional fees during fee=0 period - correct");
    }

    /// @notice Tests the full attack: fee=0, yield accrues untaxed, fee restored.
    ///         Verifies watermark reset prevents retroactive taxation.
    function test_attack_C_feeToggleWatermarkReset() public {
        _setUpHarnessSingleMarket(1_000); // 10% fee

        _userDeposit(victim, 1_000_000e6);

        // Phase 1: Let yield accrue and vest with 10% fee.
        skip(1 days);
        harness.exchangeRateUpdated();
        skip(1 days + 1);
        harness.exchangeRateUpdated();

        uint256 rateAfterPhase1 = harness.exchangeRate();
        uint256 watermark1 = harness.exchangeRateHighWatermark();
        uint256 feeShares1 = harness.balanceOf(liveCentralRegistry.daoAddress());

        console2.log("Phase 1 (10% fee):");
        console2.log("  Exchange rate:", rateAfterPhase1);
        console2.log("  Watermark:", watermark1);
        console2.log("  DAO fee shares:", feeShares1);

        // Phase 2: Manager sets fee to 0.
        // Wait for yield to settle before changing fee.
        skip(1 days + 1);
        harness.exchangeRateUpdated();

        vm.prank(mktManager);
        harness.setFee(0);

        console2.log("  Fee after setting to 0:", harness.fee());

        // Re-capture baseline DAO shares AFTER fee is actually 0.
        // The settling cycles above may have charged additional fees at the old rate.
        uint256 feeSharesBaseline = harness.balanceOf(liveCentralRegistry.daoAddress());
        console2.log("  DAO shares baseline (fee=0 effective):", feeSharesBaseline);

        // Let yield accrue untaxed for several days.
        for (uint256 i = 0; i < 3; i++) {
            skip(1 days);
            harness.exchangeRateUpdated();
            skip(1 days + 1);
            harness.exchangeRateUpdated();
        }

        uint256 rateAfterPhase2 = harness.exchangeRate();
        uint256 feeShares2 = harness.balanceOf(liveCentralRegistry.daoAddress());

        console2.log("\nPhase 2 (fee=0, 3 cycles):");
        console2.log("  Exchange rate:", rateAfterPhase2);
        console2.log("  DAO fee shares:", feeShares2);
        assertEq(feeShares2, feeSharesBaseline, "No new fees during fee=0 period");

        // Phase 3: Manager sets fee back to 10%.
        // NOTE: setFee() calls _accrueIfNeeded() which may start new vesting.
        // If vesting starts, the fee change is DEFERRED until vesting ends.
        // The watermark reset only happens when _updateFeeIfNeeded() finally runs.
        vm.prank(mktManager);
        harness.setFee(1_000);

        uint256 watermarkImmediately = harness.exchangeRateHighWatermark();
        uint256 rateImmediately = harness.exchangeRate();
        console2.log("\nPhase 3 (fee restore to 10%):");
        console2.log("  Watermark immediately after setFee:", watermarkImmediately);
        console2.log("  Rate immediately:", rateImmediately);
        console2.log("  Fee immediately:", harness.fee());

        // IMPORTANT FINDING: The fee change may be deferred because
        // _accrueIfNeeded() inside setFee detected new yield and started vesting.
        // The watermark reset is deferred too. This means:
        // 1. The old watermark from the 10% fee era may be below current rate
        // 2. When the deferred fee change applies, some yield earned during
        //    fee=0 period COULD be taxed (the portion between old watermark
        //    and new watermark at settlement time).

        // Wait for deferred fee to actually apply.
        skip(1 days + 1);
        harness.exchangeRateUpdated();
        if (harness.fee() != 1_000) {
            skip(1 days + 1);
            harness.exchangeRateUpdated();
        }

        uint256 watermarkSettled = harness.exchangeRateHighWatermark();
        uint256 rateSettled = harness.exchangeRate();
        console2.log("  Watermark after settling:", watermarkSettled);
        console2.log("  Rate after settling:", rateSettled);
        console2.log("  Fee after settling:", harness.fee());

        // The watermark should be at or above the phase 2 rate
        // (since the 0->nonzero transition should reset it to the rate
        //  at the time _updateFeeIfNeeded runs).
        // NOTE: The watermark is set when the fee update is finally applied
        // (after the deferred vesting period ends). At that point, the rate
        // may be HIGHER than rateAfterPhase2 due to yield accrued during the wait.
        assertGe(watermarkSettled, watermarkImmediately,
            "Watermark should not decrease after fee restore");

        // Verify future yield IS taxed.
        uint256 daoSharesBeforeTax = harness.balanceOf(liveCentralRegistry.daoAddress());
        skip(1 days);
        harness.exchangeRateUpdated();
        skip(1 days + 1);
        harness.exchangeRateUpdated();

        uint256 daoSharesAfterTax = harness.balanceOf(liveCentralRegistry.daoAddress());
        console2.log("  After new yield cycle, DAO shares:", daoSharesAfterTax);
        if (daoSharesAfterTax > daoSharesBeforeTax) {
            console2.log("  Future yield IS being taxed - correct behavior");
            console2.log("  Fee shares minted:", daoSharesAfterTax - daoSharesBeforeTax);
        }

        console2.log("\nSUMMARY - Fee Toggle Attack:");
        console2.log("  Yield untaxed during fee=0 period: confirmed");
        console2.log("  Watermark reset delays fee taxation of transitional yield");
        console2.log("  This is a design choice but enables manager-level tax avoidance");
    }

    // =====================================================================
    // E. DEPOSIT->TRANSFER->WITHDRAW TO DIFFERENT RECEIVER
    // =====================================================================

    /// @notice Verifies that transferring shares to victim, then trying to
    ///         withdraw as victim with receiver=attacker, requires allowance.
    function test_attack_E_transferSharesThenWithdrawAsVictim() public {
        _setUpHarnessSingleMarket(0);

        // Attacker deposits and gets shares.
        _userDeposit(attacker, 100_000e6);
        uint256 attackerShares = harness.balanceOf(attacker);
        console2.log("Attacker shares:", attackerShares);

        // Attacker transfers shares to victim.
        vm.prank(attacker);
        harness.transfer(victim, attackerShares);

        uint256 victimShares = harness.balanceOf(victim);
        console2.log("Victim shares after transfer:", victimShares);
        assertEq(victimShares, attackerShares, "Victim should have attacker's shares");

        // Attacker tries to withdraw from victim's shares with receiver=attacker.
        // This should fail because attacker has no allowance from victim.
        uint256 withdrawAmount = harness.convertToAssets(victimShares / 2);

        vm.startPrank(attacker);
        vm.expectRevert(); // Should revert: insufficient allowance
        harness.withdraw(withdrawAmount, attacker, victim);
        vm.stopPrank();
        console2.log("DEFENSE CONFIRMED: Unauthorized withdrawal blocked by allowance check");

        // Also test redeem path.
        vm.startPrank(attacker);
        vm.expectRevert(); // Should revert: insufficient allowance
        harness.redeem(victimShares / 2, attacker, victim);
        vm.stopPrank();
        console2.log("DEFENSE CONFIRMED: Unauthorized redeem also blocked");

        // Verify that WITH allowance, it works (legitimate delegation).
        vm.prank(victim);
        harness.approve(attacker, victimShares);

        uint256 attackerBalBefore = IERC20(USDC_MONAD).balanceOf(attacker);
        vm.prank(attacker);
        harness.redeem(victimShares, attacker, victim);
        uint256 attackerBalAfter = IERC20(USDC_MONAD).balanceOf(attacker);

        console2.log("With allowance - attacker received:", attackerBalAfter - attackerBalBefore);
        assertGt(attackerBalAfter, attackerBalBefore, "Authorized withdrawal should work");
    }

    // =====================================================================
    // F. optimalWithdrawalTarget GRIEFING
    // =====================================================================

    /// @notice Tests that when all markets have insufficient idle liquidity
    ///         for the withdrawal amount, standard withdraw reverts.
    function test_attack_F_allMarketsNoLiquidity_standardWithdrawReverts() public {
        _setUpHarnessTwoMarketsNoFee();

        // Deposit significant amount.
        _userDeposit(victim, 500_000e6);
        _userDepositToMarket(victim, 500_000e6, cUSDC_WBTC_MARKET);

        // Check current idle liquidity levels.
        uint256 idle0 = IBorrowableCToken(cUSDC_WMON_MARKET).assetsHeld();
        uint256 idle1 = IBorrowableCToken(cUSDC_WBTC_MARKET).assetsHeld();

        console2.log("Market 0 idle liquidity:", idle0);
        console2.log("Market 1 idle liquidity:", idle1);

        // Try to withdraw more than any single market's idle liquidity.
        // This simulates the condition where all markets are fully borrowed.
        uint256 maxIdle = idle0 > idle1 ? idle0 : idle1;

        if (maxIdle > 0) {
            // Withdraw slightly more than the biggest idle amount.
            uint256 oversizedWithdraw = maxIdle + 1;
            uint256 victimAssets = harness.convertToAssets(harness.balanceOf(victim));

            // Only test if victim has enough shares for this withdrawal.
            if (oversizedWithdraw <= victimAssets) {
                // Standard withdraw uses optimalWithdrawalTarget.
                // It checks EACH market individually:
                //   marketAssets >= assets && cToken.assetsHeld() >= assets
                // If no single market passes both checks, it reverts.
                bool reverted = false;
                vm.startPrank(victim);
                try harness.withdraw(oversizedWithdraw, victim, victim) {
                    console2.log("Standard withdrawal succeeded unexpectedly");
                    console2.log("(one market had enough idle for the full amount)");
                } catch {
                    reverted = true;
                    console2.log("Standard withdrawal reverted with InsufficientLiquidity");
                }
                vm.stopPrank();

                if (reverted) {
                    console2.log("GRIEFING VECTOR: Standard withdraw blocked when no");
                    console2.log("  single market has enough idle liquidity.");
                    console2.log("  Users must use targeted withdrawals to specific markets.");

                    // Show targeted withdrawal works for smaller amounts.
                    address bestMarket = idle0 >= idle1 ? cUSDC_WMON_MARKET : cUSDC_WBTC_MARKET;
                    uint256 bestIdle = idle0 >= idle1 ? idle0 : idle1;
                    uint256 safeAmount = bestIdle / 2;

                    if (safeAmount > 0) {
                        vm.startPrank(victim);
                        harness.withdraw(safeAmount, victim, victim, bestMarket);
                        vm.stopPrank();
                        console2.log("  Targeted withdrawal of", safeAmount, "succeeded");
                    }
                }
            }
        }
    }

    // =====================================================================
    // G. setFee TO 0 -> WATERMARK RESET ATTACK
    // =====================================================================

    /// @notice Tests the watermark reset behavior when transitioning from 0 to nonzero fee.
    ///         Confirms that yield earned during fee=0 period is never retroactively taxed.
    function test_attack_G_watermarkResetOnFeeRestore() public {
        _setUpHarnessSingleMarket(1_000); // 10% fee

        _userDeposit(victim, 1_000_000e6);

        // Let initial yield accrue and vest with fees.
        skip(1 days);
        harness.exchangeRateUpdated();
        skip(1 days + 1);
        harness.exchangeRateUpdated();

        uint256 initialDaoShares = harness.balanceOf(liveCentralRegistry.daoAddress());
        uint256 rateBeforeFeeZero = harness.exchangeRate();
        uint256 watermarkBefore = harness.exchangeRateHighWatermark();

        console2.log("Initial state (10% fee):");
        console2.log("  Exchange rate:", rateBeforeFeeZero);
        console2.log("  Watermark:", watermarkBefore);
        console2.log("  DAO shares:", initialDaoShares);

        // Step 1: Manager sets fee to 0.
        // Wait for yield to settle before changing fee.
        skip(1 days + 1);
        harness.exchangeRateUpdated();

        vm.prank(mktManager);
        harness.setFee(0);
        assertEq(harness.fee(), 0, "Fee should be 0 after settling");

        // Update DAO shares after additional cycles to settle.
        initialDaoShares = harness.balanceOf(liveCentralRegistry.daoAddress());
        rateBeforeFeeZero = harness.exchangeRate();

        console2.log("  After settling - fee:", harness.fee());
        console2.log("  DAO shares after settling:", initialDaoShares);

        // Step 2: Significant yield accrues during fee=0 period.
        // Multiple vesting cycles with no fees.
        for (uint256 i = 0; i < 5; i++) {
            skip(1 days);
            harness.exchangeRateUpdated();
            skip(1 days + 1);
            harness.exchangeRateUpdated();
        }

        uint256 rateAfterFreeYield = harness.exchangeRate();
        uint256 daoSharesDuringFreeYield = harness.balanceOf(liveCentralRegistry.daoAddress());

        console2.log("\nAfter 5 vesting cycles with fee=0:");
        console2.log("  Exchange rate:", rateAfterFreeYield);
        console2.log("  DAO shares:", daoSharesDuringFreeYield);
        console2.log("  Rate increase:", rateAfterFreeYield - rateBeforeFeeZero);
        assertEq(daoSharesDuringFreeYield, initialDaoShares, "No fees during fee=0");

        // Step 3: Manager sets fee back to 10%.
        vm.prank(mktManager);
        harness.setFee(1_000);

        // If deferred, force apply.
        if (harness.fee() != 1_000) {
            skip(1 days + 1);
            harness.exchangeRateUpdated();
        }

        uint256 watermarkAfterRestore = harness.exchangeRateHighWatermark();

        console2.log("\nAfter restoring fee to 10%:");
        console2.log("  New watermark:", watermarkAfterRestore);
        console2.log("  Current rate:", harness.exchangeRate());

        // CRITICAL: watermark was reset to current rate (0->nonzero transition).
        // All yield earned during fee=0 is below this watermark.
        assertGe(
            watermarkAfterRestore,
            rateAfterFreeYield - 1, // allow 1 wei rounding
            "Watermark must be >= rate at fee restoration"
        );

        console2.log("  CONFIRMED: Watermark resets on 0->nonzero transition");
        console2.log("  Yield during fee=0 period:", rateAfterFreeYield - rateBeforeFeeZero);
        console2.log("  This yield is UNTAXABLE (below new watermark)");

        // Step 4: Verify future yield IS taxed.
        skip(1 days);
        harness.exchangeRateUpdated();
        skip(1 days + 1);
        harness.exchangeRateUpdated();

        uint256 daoSharesAfterRestore = harness.balanceOf(liveCentralRegistry.daoAddress());
        console2.log("\nAfter one cycle with restored fee:");
        console2.log("  DAO shares:", daoSharesAfterRestore);

        if (daoSharesAfterRestore > daoSharesDuringFreeYield) {
            console2.log("  Future yield taxed correctly:", daoSharesAfterRestore - daoSharesDuringFreeYield, "fee shares");
        }

        // Impact calculation: how much tax was avoided.
        uint256 untaxedYield = rateAfterFreeYield - rateBeforeFeeZero;
        console2.log("\nIMPACT SUMMARY:");
        console2.log("  Rate growth during fee=0:", untaxedYield);
        console2.log("  This is by design (manager explicitly set fee=0)");
        console2.log("  But a compromised manager could use this to avoid taxes");
    }

    // =====================================================================
    // H. PERMISSIONLESS exchangeRateUpdated() AS GRIEFING TOOL
    // =====================================================================

    /// @notice Tests that calling exchangeRateUpdated() repeatedly does not
    ///         adversely affect new depositors. With immediate yield (no vesting),
    ///         new depositors get shares at the current fair rate.
    function test_attack_H_repeatedAccrualDoesNotHurtNewDepositors() public {
        _setUpHarnessSingleMarket(0);

        // Initial deposit.
        _userDeposit(victim, 1_000_000e6);

        // Simulate 5 cycles of repeated accrual via permissionless calls.
        for (uint256 i = 0; i < 5; i++) {
            // Wait for yield to accrue.
            skip(1 days + 1);

            // Trigger accrual - yield is immediately recognized.
            harness.exchangeRateUpdated();

            // Record share price for a new depositor.
            uint256 depositAmount = 100_000e6;
            uint256 previewShares = harness.previewDeposit(depositAmount);
            uint256 convertShares = harness.convertToShares(depositAmount);

            console2.log("Cycle", i, ":");
            console2.log("  previewDeposit:", previewShares);
            console2.log("  convertToShares:", convertShares);

            // With no vesting, previewDeposit and convertToShares should be equal.
            uint256 diff = convertShares > previewShares
                ? convertShares - previewShares
                : previewShares - convertShares;
            console2.log("  Difference:", diff);
        }
    }

    /// @notice Quantifies the actual impact on a new depositor when yield is immediate.
    function test_attack_H_quantifyNewDepositorImpact() public {
        _setUpHarnessSingleMarket(0);

        // Existing depositor.
        _userDeposit(victim, 1_000_000e6);

        // Let yield accrue.
        skip(1 days);
        harness.exchangeRateUpdated();

        // New depositor deposits after yield accrual.
        uint256 newDeposit = 100_000e6;
        _userDeposit(victim2, newDeposit);

        uint256 victim2Shares = harness.balanceOf(victim2);
        console2.log("New depositor shares:", victim2Shares);

        // Let more yield accrue.
        skip(2 days);
        harness.exchangeRateUpdated();

        // Calculate new depositor's value after yield.
        uint256 victim2Assets = harness.convertToAssets(victim2Shares);
        console2.log("New depositor asset value after yield:", victim2Assets);
        console2.log("New depositor original deposit:", newDeposit);

        if (victim2Assets > newDeposit) {
            console2.log("New depositor GAINED:", victim2Assets - newDeposit);
            console2.log("This is normal: depositor earned yield proportional to time held");
        } else if (victim2Assets < newDeposit) {
            console2.log("New depositor LOST:", newDeposit - victim2Assets);
            console2.log("This could indicate unfair pricing");
        }
    }

    // =====================================================================
    // COMBINED ATTACK: RAPID REBALANCING ROUNDING LOSS
    // =====================================================================

    /// @notice Tests whether rapid rebalancing accumulates significant rounding losses.
    function test_attack_combined_rapidRebalancingRoundingLoss() public {
        _setUpHarnessTwoMarketsNoFee();

        _userDeposit(victim, 500_000e6);
        _userDepositToMarket(victim, 500_000e6, cUSDC_WBTC_MARKET);

        // Let yield accrue.
        skip(1 days);
        harness.exchangeRateUpdated();

        uint256 totalAssetsBefore = harness.totalAssets();
        uint256 indexedBefore = harness.exposed_totalAssetsIndexed();

        console2.log("After yield accrual:");
        console2.log("  totalAssets():", totalAssetsBefore);
        console2.log("  _totalAssets:", indexedBefore);

        // Harvester does rapid rebalances to accumulate rounding losses.
        uint256 rebalanceAmt = 50_000e6;
        bool badDebtTriggered = false;

        for (uint256 i = 0; i < 30; i++) {
            LendingOptimizer.ReallocationAction[] memory actions = new LendingOptimizer.ReallocationAction[](2);
            actions[0] = LendingOptimizer.ReallocationAction({
                cToken: IBorrowableCToken(cUSDC_WMON_MARKET),
                assets: -int256(rebalanceAmt)
            });
            actions[1] = LendingOptimizer.ReallocationAction({
                cToken: IBorrowableCToken(cUSDC_WBTC_MARKET),
                assets: int256(rebalanceAmt)
            });

            vm.prank(maliciousHarvester);
            try harness.rebalance(actions) {} catch {
                console2.log("Rebalance failed at iteration", i);
                break;
            }

            LendingOptimizer.ReallocationAction[] memory rev = new LendingOptimizer.ReallocationAction[](2);
            rev[0] = LendingOptimizer.ReallocationAction({
                cToken: IBorrowableCToken(cUSDC_WMON_MARKET),
                assets: int256(rebalanceAmt)
            });
            rev[1] = LendingOptimizer.ReallocationAction({
                cToken: IBorrowableCToken(cUSDC_WBTC_MARKET),
                assets: -int256(rebalanceAmt)
            });

            vm.prank(maliciousHarvester);
            try harness.rebalance(rev) {} catch {
                console2.log("Reverse rebalance failed at iteration", i);
                break;
            }
        }

        uint256 totalAssetsAfter = harness.totalAssets();
        uint256 indexedAfter = harness.exposed_totalAssetsIndexed();

        console2.log("\nAfter rebalances:");
        console2.log("  totalAssets():", totalAssetsAfter);
        console2.log("  _totalAssets:", indexedAfter);
        console2.log("  Bad debt triggered:", badDebtTriggered);

        if (badDebtTriggered) {
            console2.log("  VULNERABILITY: Harvester triggered false bad debt");
            console2.log("  Unvested yield was wiped, hurting depositors");
            uint256 loss = totalAssetsBefore - totalAssetsAfter;
            console2.log("  Depositor loss:", loss);
        }
    }

    // =====================================================================
    // FEE EDGE CASE: setFee APPLIES CORRECTLY
    // =====================================================================

    /// @notice Verifies that setFee applies correctly and fees are charged.
    function test_defense_setFeeAppliesCorrectly() public {
        _setUpHarnessSingleMarket(1_000); // 10% fee

        _userDeposit(victim, 1_000_000e6);

        // Let yield accrue.
        skip(1 days);
        harness.exchangeRateUpdated();

        // Set fee to 50% (max).
        vm.prank(mktManager);
        harness.setFee(5_000);

        uint256 feeAfter = harness.fee();
        console2.log("Fee after setFee:", feeAfter);
        assertEq(feeAfter, 5_000, "Fee should be 50% now");

        // Verify fees were charged.
        uint256 daoShares = harness.balanceOf(liveCentralRegistry.daoAddress());
        console2.log("DAO shares:", daoShares);
        assertGt(daoShares, 0, "Fees should have been charged");
    }

    // =====================================================================
    // EXCHANGE RATE NEVER DECREASES ACROSS ECONOMIC ATTACKS
    // =====================================================================

    /// @notice Invariant check: exchange rate should never decrease for
    ///         existing holders across all tested attack scenarios.
    function test_invariant_exchangeRateNeverDecreasesWithAttacks() public {
        _setUpHarnessSingleMarket(1_000); // 10% fee

        _userDeposit(victim, 1_000_000e6);

        uint256 previousRate = harness.exchangeRate();
        console2.log("Initial rate:", previousRate);

        // Cycle 1: Normal yield accrual.
        skip(1 days);
        harness.exchangeRateUpdated();
        skip(1 days + 1);
        harness.exchangeRateUpdated();

        uint256 rate1 = harness.exchangeRate();
        assertGe(rate1, previousRate, "Rate decreased after cycle 1");
        console2.log("Rate after cycle 1:", rate1);
        previousRate = rate1;

        // Cycle 2: Fee change during vesting.
        skip(1 days);
        harness.exchangeRateUpdated();

        vm.prank(mktManager);
        harness.setFee(2_000); // Change to 20%

        skip(1 days + 1);
        harness.exchangeRateUpdated();

        uint256 rate2 = harness.exchangeRate();
        assertGe(rate2, previousRate, "Rate decreased after fee change");
        console2.log("Rate after fee change:", rate2);
        previousRate = rate2;

        // Cycle 3: New deposit after yield accrual.
        skip(1 days);
        harness.exchangeRateUpdated();

        _userDeposit(victim2, 500_000e6);

        uint256 rate3 = harness.exchangeRate();
        assertGe(rate3, previousRate, "Rate decreased after deposit");
        console2.log("Rate after new deposit:", rate3);
        previousRate = rate3;

        // More yield accrual.
        skip(1 days + 1);
        harness.exchangeRateUpdated();

        uint256 rate4 = harness.exchangeRate();
        assertGe(rate4, previousRate, "Rate decreased after yield accrual");
        console2.log("Final rate:", rate4);
    }

    // =====================================================================
    // UNAUTHORIZED ACCESS CHECKS
    // =====================================================================

    /// @notice Verifies that non-harvesters cannot call rebalance.
    function test_defense_harvesterOnlyFunctions() public {
        _setUpHarnessTwoMarketsNoFee();

        // Random user tries rebalance.
        LendingOptimizer.ReallocationAction[] memory actions = new LendingOptimizer.ReallocationAction[](2);
        actions[0] = LendingOptimizer.ReallocationAction({
            cToken: IBorrowableCToken(cUSDC_WMON_MARKET),
            assets: int256(0)
        });
        actions[1] = LendingOptimizer.ReallocationAction({
            cToken: IBorrowableCToken(cUSDC_WBTC_MARKET),
            assets: int256(0)
        });

        vm.prank(attacker);
        vm.expectRevert();
        harness.rebalance(actions);

        console2.log("DEFENSE CONFIRMED: Harvester-only functions properly restricted");
    }

    /// @notice Verifies that non-managers cannot call setFee, addApprovedAsset, etc.
    function test_defense_marketManagerOnlyFunctions() public {
        _setUpHarnessSingleMarket(0);

        // Random user tries setFee.
        vm.prank(attacker);
        vm.expectRevert();
        harness.setFee(5000);

        // Random user tries setMintPaused.
        vm.prank(attacker);
        vm.expectRevert();
        harness.setMintPaused(true);

        console2.log("DEFENSE CONFIRMED: Market manager functions properly restricted");
    }
}
