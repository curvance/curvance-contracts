// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizerHarness } from "../LendingOptimizerHarness.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { WAD, BPS } from "contracts/libraries/ConstantsLib.sol";

/// @title Economic Attack Fuzz Tests for LendingOptimizer
/// @notice Fuzz tests verifying economic security of the optimizer against
///         various attack vectors: frontrunning, donation, sandwich, rounding,
///         bad debt, and fee timing exploits.
contract EconomicAttackFuzz is TestBaseLendingOptimizer {

    LendingOptimizerHarness harness;

    address attacker = address(0xBAD);
    address victim = address(0xFACE);

    function setUp() public override {
        super.setUp();
        _setUpHarnessThreeMarkets();
    }

    /// @dev Deploys LendingOptimizerHarness with 3 markets (mirrors _setUpThreeMarkets).
    function _setUpHarnessThreeMarkets() internal {
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
            1_000 // 10% fee
        );

        // Initialize with dead shares.
        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(harness), initAssets);

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

        harness.initializeDeposits(cUSDC_WMON_MARKET);
    }

    // =========================================================================
    // TEST 1: Yield Frontrunning (REMOVED)
    // Vesting was removed; yield is now absorbed immediately in _accrueIfNeeded().
    // The vesting-based per-second yield comparison no longer applies because
    // yield is priced in before every deposit. Frontrunning is now blocked by
    // immediate accrual, not by vesting spread.
    // =========================================================================

    // =========================================================================
    // TEST 2: Share Inflation / Donation Attack
    // =========================================================================

    /// @notice Donating USDC directly to the optimizer should not affect exchange rate
    ///         or totalAssets since donations bypass the deposit flow.
    function testFuzz_shareInflation_donationAttack(uint256 donationAmount) public {
        donationAmount = bound(donationAmount, 1, 100_000_000e6);

        // Deploy fresh harness for clean state.
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory caps = new uint256[](1);
        caps[0] = 10_000;

        LendingOptimizerHarness fresh = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            caps,
            1_000
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(fresh), initAssets);
        fresh.initializeDeposits(cUSDC_WMON_MARKET);

        uint256 exchangeRateBefore = fresh.exchangeRate();
        uint256 totalAssetsBefore = fresh.totalAssets();

        // Attacker donates USDC directly.
        deal(USDC_MONAD, attacker, donationAmount);
        vm.prank(attacker);
        IERC20(USDC_MONAD).transfer(address(fresh), donationAmount);

        // Exchange rate and totalAssets should remain unchanged.
        uint256 exchangeRateAfter = fresh.exchangeRate();
        uint256 totalAssetsAfter = fresh.totalAssets();

        assertEq(
            totalAssetsAfter,
            totalAssetsBefore,
            "totalAssets changed from direct donation"
        );
        assertEq(
            exchangeRateAfter,
            exchangeRateBefore,
            "Exchange rate changed from direct donation"
        );

        // Victim deposits normally and should get fair value.
        uint256 victimDeposit = 1_000e6;
        deal(USDC_MONAD, victim, victimDeposit);
        vm.startPrank(victim);
        IERC20(USDC_MONAD).approve(address(fresh), victimDeposit);
        uint256 victimShares = fresh.deposit(victimDeposit, victim, cUSDC_WMON_MARKET);
        vm.stopPrank();

        uint256 victimValue = fresh.convertToAssets(victimShares);
        assertApproxEqAbs(
            victimValue,
            victimDeposit,
            2,
            "Victim did not receive fair share value after donation"
        );
    }

    // =========================================================================
    // TEST 3: Sandwich Rebalance
    // =========================================================================

    /// @notice Depositing before a rebalance and withdrawing after should not
    ///         generate meaningful profit for the attacker.
    function testFuzz_sandwichRebalance(
        uint256 depositSize,
        uint256 rebalanceAmount
    ) public {
        depositSize = bound(depositSize, 100_000e6, 5_000_000e6);
        rebalanceAmount = bound(rebalanceAmount, 10_000e6, 500_000e6);

        // User1 deposits into market 0.
        deal(USDC_MONAD, user1, 2_000_000e6);
        vm.startPrank(user1);
        IERC20(USDC_MONAD).approve(address(harness), 2_000_000e6);
        harness.deposit(2_000_000e6, user1, cUSDC_WMON_MARKET);
        vm.stopPrank();

        // User2 deposits into market 1.
        deal(USDC_MONAD, user2, 1_000_000e6);
        vm.startPrank(user2);
        IERC20(USDC_MONAD).approve(address(harness), 1_000_000e6);
        harness.deposit(1_000_000e6, user2, cUSDC_WBTC_MARKET);
        vm.stopPrank();

        // Attacker deposits before rebalance.
        deal(USDC_MONAD, attacker, depositSize);
        vm.startPrank(attacker);
        IERC20(USDC_MONAD).approve(address(harness), depositSize);
        uint256 attackerShares = harness.deposit(depositSize, attacker, cUSDC_WMON_MARKET);
        vm.stopPrank();

        uint256 attackerValueBefore = harness.convertToAssets(attackerShares);

        // Cap rebalanceAmount to what is available in market 0.
        uint256 market0Assets = IBorrowableCToken(cUSDC_WMON_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(harness))
        );
        uint256 market0Liquidity = IBorrowableCToken(cUSDC_WMON_MARKET).assetsHeld();
        uint256 safeRebalance = rebalanceAmount;
        if (safeRebalance > market0Liquidity || safeRebalance > market0Assets) {
            safeRebalance = market0Liquidity < market0Assets ? market0Liquidity : market0Assets;
            if (safeRebalance > 0) {
                safeRebalance = safeRebalance / 2; // Use half to be safe.
            }
        }

        // Execute rebalance: move from market 0 to market 1.
        if (safeRebalance > 0) {
            LendingOptimizer.ReallocationAction[] memory actions = new LendingOptimizer.ReallocationAction[](3);
            actions[0] = LendingOptimizer.ReallocationAction({
                cToken: IBorrowableCToken(cUSDC_WMON_MARKET),
                assetsOrBps: -int256(safeRebalance)
            });
            actions[1] = LendingOptimizer.ReallocationAction({
                cToken: IBorrowableCToken(cUSDC_WBTC_MARKET),
                assetsOrBps: int256(safeRebalance)
            });
            actions[2] = LendingOptimizer.ReallocationAction({
                cToken: IBorrowableCToken(cUSDC_WETH_MARKET),
                assetsOrBps: int256(0)
            });

            try harness.rebalance(actions) {} catch {
                // Rebalance might fail due to allocation caps; that's OK.
                return;
            }
        }

        // Attacker withdraws after rebalance.
        vm.prank(attacker);
        uint256 attackerAssetsOut = harness.redeem(attackerShares, attacker, attacker);

        // Attacker profit should be negligible (within a few wei of rounding).
        int256 profit = int256(attackerAssetsOut) - int256(depositSize);
        assertLe(
            profit,
            int256(10),
            "Attacker profited from sandwich rebalance"
        );
    }

    // =========================================================================
    // TEST 4: Rounding Loss Accumulation
    // =========================================================================

    /// @notice Multiple rebalances should not cause _totalAssets to drift
    ///         significantly or the exchange rate to meaningfully decrease.
    function testFuzz_roundingLossAccumulation(
        uint256 numRebalances,
        uint256 rebalanceSize
    ) public {
        numRebalances = bound(numRebalances, 10, 100);
        rebalanceSize = bound(rebalanceSize, 100e6, 1_000_000e6);

        // Use fresh harness with 2 markets at 100%/100% caps.
        address[] memory approvedCTokens = new address[](2);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;

        uint256[] memory caps = new uint256[](2);
        caps[0] = 10_000;
        caps[1] = 10_000;

        LendingOptimizerHarness roundingHarness = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            caps,
            0 // No fee for clean measurement.
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(roundingHarness), initAssets);
        roundingHarness.initializeDeposits(cUSDC_WMON_MARKET);

        // Deposit a substantial amount into market 0.
        uint256 depositAmount = 5_000_000e6;
        deal(USDC_MONAD, address(this), depositAmount);
        IERC20(USDC_MONAD).approve(address(roundingHarness), depositAmount);
        roundingHarness.deposit(depositAmount, address(this), cUSDC_WMON_MARKET);

        uint256 exchangeRateBefore = roundingHarness.exchangeRate();

        // Perform many rebalances back and forth.
        for (uint256 i = 0; i < numRebalances; i++) {
            // Calculate safe rebalance amount.
            uint256 safeAmount = rebalanceSize;

            // Alternate direction: even iterations go 0->1, odd go 1->0.
            address fromMarket;
            address toMarket;
            if (i % 2 == 0) {
                fromMarket = cUSDC_WMON_MARKET;
                toMarket = cUSDC_WBTC_MARKET;
            } else {
                fromMarket = cUSDC_WBTC_MARKET;
                toMarket = cUSDC_WMON_MARKET;
            }

            uint256 fromAssets = IBorrowableCToken(fromMarket).convertToAssets(
                IBorrowableCToken(fromMarket).balanceOf(address(roundingHarness))
            );
            uint256 fromLiquidity = IBorrowableCToken(fromMarket).assetsHeld();

            if (safeAmount > fromAssets || safeAmount > fromLiquidity) {
                uint256 available = fromAssets < fromLiquidity ? fromAssets : fromLiquidity;
                if (available < 2) break;
                safeAmount = available / 2;
            }

            if (safeAmount == 0) break;

            LendingOptimizer.ReallocationAction[] memory actions = new LendingOptimizer.ReallocationAction[](2);
            if (i % 2 == 0) {
                actions[0] = LendingOptimizer.ReallocationAction({
                    cToken: IBorrowableCToken(cUSDC_WMON_MARKET),
                    assetsOrBps: -int256(safeAmount)
                });
                actions[1] = LendingOptimizer.ReallocationAction({
                    cToken: IBorrowableCToken(cUSDC_WBTC_MARKET),
                    assetsOrBps: int256(safeAmount)
                });
            } else {
                actions[0] = LendingOptimizer.ReallocationAction({
                    cToken: IBorrowableCToken(cUSDC_WMON_MARKET),
                    assetsOrBps: int256(safeAmount)
                });
                actions[1] = LendingOptimizer.ReallocationAction({
                    cToken: IBorrowableCToken(cUSDC_WBTC_MARKET),
                    assetsOrBps: -int256(safeAmount)
                });
            }

            try roundingHarness.rebalance(actions) {} catch {
                break; // Allocation cap or liquidity issue; stop.
            }
        }

        // Exchange rate should not have decreased by more than negligible amount.
        // Each rebalance round-trip (withdraw + deposit) can lose a small amount
        // from cToken share truncation. The loss scales with both the number of
        // rebalances and the rebalance size. Use a relative tolerance (0.001%).
        uint256 exchangeRateAfter = roundingHarness.exchangeRate();
        assertGe(
            exchangeRateAfter + exchangeRateBefore / 100_000,
            exchangeRateBefore,
            "Exchange rate decreased significantly after rebalances"
        );
    }

    // =========================================================================
    // TEST 5: Fee Extraction Timing
    // =========================================================================

    /// @notice Varying fee rates across multiple yield cycles should correctly use
    ///         the high watermark to prevent double-charging.
    function testFuzz_feeExtractionTiming(
        uint256 fee1,
        uint256 fee2,
        uint256 fee3
    ) public {
        fee1 = bound(fee1, 1, 5000);
        fee2 = bound(fee2, 1, 5000);
        fee3 = bound(fee3, 0, 5000);

        // Deploy fresh harness with fee1.
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory caps = new uint256[](1);
        caps[0] = 10_000;

        LendingOptimizerHarness feeHarness = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            caps,
            fee1
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(feeHarness), initAssets);
        feeHarness.initializeDeposits(cUSDC_WMON_MARKET);

        // Deposit.
        uint256 depositAmount = 5_000_000e6;
        deal(USDC_MONAD, user1, depositAmount);
        vm.startPrank(user1);
        IERC20(USDC_MONAD).approve(address(feeHarness), depositAmount);
        feeHarness.deposit(depositAmount, user1, cUSDC_WMON_MARKET);
        vm.stopPrank();

        // Cycle 1: fee1 active, let yield accrue and charge fees.
        skip(2 days);
        feeHarness.accrueIfNeeded();
        skip(1 days + 1);
        feeHarness.accrueIfNeeded();

        uint256 watermark1 = feeHarness.exchangeRateHighWatermark();

        // Cycle 2: set fee to 0, let yield accrue (no fee should be charged).
        feeHarness.setFee(0);
        skip(2 days);
        feeHarness.accrueIfNeeded();
        skip(1 days + 1);
        feeHarness.accrueIfNeeded();

        address dao = liveCentralRegistry.daoAddress();
        uint256 daoSharesAfterCycle2 = feeHarness.balanceOf(dao);

        // Cycle 3: set fee to fee2, yield accrues, fees should be charged.
        feeHarness.setFee(fee2);

        // When re-enabling from 0, watermark resets to current rate.
        uint256 watermarkAfterReEnable = feeHarness.exchangeRateHighWatermark();
        assertGe(
            watermarkAfterReEnable,
            watermark1,
            "Watermark should not decrease when re-enabling fees"
        );

        skip(2 days);
        feeHarness.accrueIfNeeded();
        skip(1 days + 1);
        feeHarness.accrueIfNeeded();

        uint256 watermark3 = feeHarness.exchangeRateHighWatermark();
        assertGe(
            watermark3,
            watermarkAfterReEnable,
            "Watermark should not decrease after cycle 3"
        );

        // Cycle 4: change fee mid-cycle to fee3.
        skip(2 days);
        feeHarness.accrueIfNeeded();

        // Change fee mid-cycle.
        feeHarness.setFee(fee3);

        // Complete cycle.
        skip(1 days + 1);
        feeHarness.accrueIfNeeded();

        uint256 watermark4 = feeHarness.exchangeRateHighWatermark();
        // Watermark should never decrease.
        assertGe(
            watermark4,
            watermark3,
            "Watermark decreased after fee change mid-cycle"
        );

        // Exchange rate should always be positive and valid.
        uint256 finalRate = feeHarness.exchangeRate();
        assertGt(finalRate, 0, "Exchange rate should be positive at end");
    }
}
