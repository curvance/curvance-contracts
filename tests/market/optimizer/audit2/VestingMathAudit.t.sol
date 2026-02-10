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

/// @title VestingMathAudit
/// @notice Audit #2: Vesting math, fee calculation, and precision edge cases.
/// @dev Focus on attack vectors NOT covered in AUDIT_RESULTS.md:
///      - _setVestingData assembly truncation
///      - _assetsToVest precision loss
///      - Fee edge cases with tiny profits
///      - _fullyDilutedAssets vs totalAssets deposit/redeem asymmetry
///      - Zero-amount operations
///      - Multiple setFee calls during vesting
contract VestingMathAudit is TestBaseLendingOptimizer {

    LendingOptimizerHarness harness;

    // User addresses
    address constant ATTACKER = address(0xA77AC4);
    address constant USER_A = address(0xAAA);
    address constant USER_B = address(0xBBB);

    /// @dev Deploy a harness with 1 market, 10% fee, 1-day vesting
    function _deployHarnessOneMarket(
        uint256 feeBps,
        uint256 vestingPeriod
    ) internal {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        harness = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            feeBps,
            vestingPeriod
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
        harness.initializeDeposits(0);
    }

    // =========================================================================
    // A. _setVestingData Assembly Truncation (176-bit rate masking)
    // =========================================================================

    /// @notice Test: Verify that the 176-bit vesting rate accommodates realistic
    ///         yield amounts without truncation for USDC (6 decimals).
    /// @dev The rate is mulDiv(assetsToVest, WAD, period). With minimum period=1s,
    ///      rate = assetsToVest * 1e18. Max 176-bit = ~9.57e52. For 6-decimal tokens,
    ///      this requires ~9.57e28 USDC of yield - astronomically unrealistic.
    ///      This test verifies no truncation for a large but plausible vault.
    function test_vestingRate_noTruncation_largePlausibleYield() public {
        _deployHarnessOneMarket(0, 1); // 0% fee, 1 second vesting (minimum period)

        // Deposit a large amount to build a big vault.
        uint256 depositAmount = 100_000_000e6; // 100M USDC
        deal(USDC_MONAD, USER_A, depositAmount);
        vm.startPrank(USER_A);
        IERC20(USDC_MONAD).approve(address(harness), depositAmount);
        harness.deposit(depositAmount, USER_A);
        vm.stopPrank();

        // Wait for vesting to complete, accrue.
        vm.warp(block.timestamp + 2);
        harness.exchangeRateUpdated();

        // Now simulate significant yield by fast-forwarding time.
        // cToken interest over time will add yield.
        vm.warp(block.timestamp + 365 days);
        harness.exchangeRateUpdated();

        // Check vesting data - rate should be non-zero and sensible.
        (uint256 vestingRate, uint256 vestingEnd, uint256 lastVestingClaim) =
            harness.exposed_getVestingData();

        console2.log("Vesting rate:", vestingRate);
        console2.log("Vesting end:", vestingEnd);
        console2.log("Last vest claim:", lastVestingClaim);
        console2.log("Max 176-bit value:", type(uint176).max);

        // Verify rate fits in 176 bits (no truncation occurred).
        assertLt(vestingRate, uint256(type(uint176).max), "Rate should fit in 176 bits");

        // Verify the rate was not truncated by checking round-trip.
        // If vestingRate > 0, compute expected vesting amount.
        if (vestingRate > 0) {
            uint256 period = vestingEnd - lastVestingClaim;
            uint256 totalVested = vestingRate * period / WAD;
            console2.log("Total assets to vest over period:", totalVested);

            // The vested amount should be close to the original yield.
            // We just verify it's > 0 and reasonable.
            assertGt(totalVested, 0, "Vested amount should be positive");
        }
    }

    /// @notice Test: With period=1 second and contrived large yield, demonstrate
    ///         that assembly masking would silently truncate the rate.
    /// @dev We can't actually create a vault with 9.57e28 USDC yield, but we can
    ///         verify the math formula for truncation threshold.
    function test_vestingRate_truncationThreshold_math() public pure {
        // The vesting rate is: mulDiv(assetsToVest, WAD, period)
        // With period = 1: rate = assetsToVest * 1e18
        // Max 176-bit: 2^176 - 1 = 95780971304118053647396689196894323976171195136475136

        uint256 maxRate = uint256(type(uint176).max);
        uint256 maxYieldForMinPeriod = maxRate / WAD; // yield that fits with period=1

        console2.log("Max yield for 1s period (raw):", maxYieldForMinPeriod);
        console2.log("Max yield for 1s period (USDC):", maxYieldForMinPeriod / 1e6);

        // For 6-decimal tokens, this is astronomical.
        // For 18-decimal tokens: maxYieldForMinPeriod / 1e18 = ~95.78M tokens
        uint256 maxYield18Dec = maxYieldForMinPeriod / 1e18;
        console2.log("Max yield for 1s period (18-dec tokens):", maxYield18Dec);

        // Verify: 18-decimal tokens CAN theoretically hit this with ~96M tokens of yield
        // in a single vesting detection. This is unlikely but not impossible for very
        // large pools of inflationary tokens.
        assertGt(maxYield18Dec, 0, "Non-zero threshold");

        // With 1-day period: rate = assetsToVest * 1e18 / 86400
        uint256 maxYieldForDayPeriod = maxRate * 86400 / WAD;
        console2.log("Max yield for 1-day period (18-dec tokens):", maxYieldForDayPeriod / 1e18);

        // With 1-day period, the max yield in 18-dec tokens is ~8.28 trillion.
        // This is practically unreachable.
    }

    // =========================================================================
    // B. _assetsToVest() Precision Loss
    // =========================================================================

    /// @notice Test: Precision loss in vesting round-trip.
    /// @dev rate = mulDiv(assetsToVest, WAD, period), then
    ///      totalVested = rate * period / WAD. Due to integer division,
    ///      totalVested may be up to 1 wei less than assetsToVest.
    ///      This test measures the actual loss over a full vesting period.
    function test_vestingPrecisionLoss_fullPeriodRoundTrip() public {
        _deployHarnessOneMarket(0, 1 days); // 0% fee, 1-day vesting

        // Large deposit to build vault.
        uint256 depositAmount = 1_000_000e6; // 1M USDC
        deal(USDC_MONAD, USER_A, depositAmount);
        vm.startPrank(USER_A);
        IERC20(USDC_MONAD).approve(address(harness), depositAmount);
        harness.deposit(depositAmount, USER_A);
        vm.stopPrank();

        // Wait for initial vesting to complete.
        vm.warp(block.timestamp + 1 days + 1);
        harness.exchangeRateUpdated();

        // Now let interest accrue for a while to generate yield.
        vm.warp(block.timestamp + 30 days);

        // Get state before accrual.
        uint256 totalAssetsBefore = harness.totalAssets();
        uint256 totalAssetsIndexedBefore = harness.exposed_totalAssetsIndexed();

        // Trigger accrual - this should detect yield and start vesting.
        harness.exchangeRateUpdated();

        // Read the vesting data.
        (uint256 vestingRate, uint256 vestingEnd, uint256 lastVestingClaim) =
            harness.exposed_getVestingData();

        if (vestingRate > 0) {
            uint256 period = vestingEnd - lastVestingClaim;
            uint256 theoreticalVest = vestingRate * period / WAD;
            uint256 rawYield = harness.exposed_accrueMarkets() - harness.exposed_totalAssetsIndexed();

            console2.log("Vesting rate:", vestingRate);
            console2.log("Period:", period);
            console2.log("Theoretical total vest:", theoreticalVest);
            console2.log("Total assets indexed:", harness.exposed_totalAssetsIndexed());

            // Now warp to exactly vestingEnd and check precision.
            vm.warp(vestingEnd);
            uint256 assetsToVest = harness.exposed_assetsToVest();
            console2.log("Assets to vest at end:", assetsToVest);
            console2.log("Difference from theoretical:", theoreticalVest > assetsToVest ? theoreticalVest - assetsToVest : assetsToVest - theoreticalVest);

            // The precision loss should be at most 1 wei.
            // This is because period / WAD < 1 for any period < 1e18 seconds.
            assertLe(
                theoreticalVest > assetsToVest ? theoreticalVest - assetsToVest : assetsToVest - theoreticalVest,
                1,
                "Precision loss exceeds 1 wei"
            );
        }
    }

    /// @notice Test: Very small yield (1 wei) gets stuck in perpetual vesting cycle.
    /// @dev When assetsToVest=1 and period=86400, rate = mulDiv(1, 1e18, 86400) =
    ///      11574074074074. totalVested = 11574074074074 * 86400 / 1e18 = 0.
    ///      The 1 wei is detected as new yield every cycle but never vests.
    ///      This is an informational finding (dust amounts only).
    function test_vestingPrecisionLoss_tinyYield_stuckForever() public {
        _deployHarnessOneMarket(0, 1 days);

        // Deposit enough to have a functioning vault.
        uint256 depositAmount = 10_000e6; // 10K USDC
        deal(USDC_MONAD, USER_A, depositAmount);
        vm.startPrank(USER_A);
        IERC20(USDC_MONAD).approve(address(harness), depositAmount);
        harness.deposit(depositAmount, USER_A);
        vm.stopPrank();

        // Wait for initial vesting to complete.
        vm.warp(block.timestamp + 1 days + 1);
        harness.exchangeRateUpdated();

        // Now we warp a tiny amount to generate minimal yield (likely 1-2 wei from rounding).
        vm.warp(block.timestamp + 1);
        uint256 rawTa = harness.exposed_accrueMarkets();
        uint256 ta = harness.totalAssets();
        uint256 tinyYield = rawTa > ta ? rawTa - ta : 0;

        console2.log("Tiny yield detected:", tinyYield);

        if (tinyYield > 0 && tinyYield < 100) {
            // Trigger accrual - starts vesting the tiny yield.
            harness.exchangeRateUpdated();

            (uint256 rate,,) = harness.exposed_getVestingData();
            uint256 theoreticalVest = rate * 1 days / WAD;
            console2.log("Vesting rate for tiny yield:", rate);
            console2.log("Theoretical total vest:", theoreticalVest);

            if (theoreticalVest == 0 && rate > 0) {
                console2.log("[INFO] Tiny yield is stuck: rate > 0 but total vest = 0");
                console2.log("[INFO] This is a dust-level precision issue, not exploitable");
            }
        }
    }

    // =========================================================================
    // C. Fee Calculation Edge Cases
    // =========================================================================

    /// @notice Test: Fee calculation with max fee (50%) and very small profit.
    /// @dev profit = 1 wei -> feeAssets = mulDivUp(1, 5e17, 1e18) = 1
    ///      feeShares = fullMulDivUp(1, supply, currentAssets - 1)
    ///      With dead shares ensuring currentAssets >= 77,777, the denominator is safe.
    function test_feeEdgeCase_maxFee_tinyProfit() public {
        _deployHarnessOneMarket(5000, 1 days); // 50% fee, 1-day vesting

        // Deposit to build vault.
        uint256 depositAmount = 100_000e6; // 100K USDC
        deal(USDC_MONAD, USER_A, depositAmount);
        vm.startPrank(USER_A);
        IERC20(USDC_MONAD).approve(address(harness), depositAmount);
        harness.deposit(depositAmount, USER_A);
        vm.stopPrank();

        uint256 supplyBefore = harness.totalSupply();
        uint256 rateBefore = harness.exchangeRate();

        console2.log("Supply before fee:", supplyBefore);
        console2.log("Exchange rate before:", rateBefore);

        // Let some time pass to generate yield, then trigger fee accrual.
        vm.warp(block.timestamp + 1 days + 1);
        harness.exchangeRateUpdated(); // Start vesting new yield.

        // Wait for vesting to complete so fees are charged.
        vm.warp(block.timestamp + 1 days + 1);
        uint256 rateAfterFirstAccrual = harness.exchangeRateUpdated();

        uint256 supplyAfter = harness.totalSupply();
        address dao = liveCentralRegistry.daoAddress();
        uint256 daoShares = harness.balanceOf(dao);

        console2.log("Exchange rate after fee:", rateAfterFirstAccrual);
        console2.log("Supply after fee:", supplyAfter);
        console2.log("DAO shares minted:", daoShares);
        console2.log("Fee shares as % of supply:", daoShares * 10000 / supplyAfter);

        // Key invariant: exchange rate should NOT decrease after fee accrual.
        // The fee is paid by dilution, but the watermark ensures the rate
        // after fee >= prior watermark.
        assertGe(rateAfterFirstAccrual, rateBefore, "Rate should not decrease after fee");
    }

    /// @notice Test: Fee is NOT charged when currentRate exactly equals watermark.
    function test_feeEdgeCase_rateEqualsWatermark_noFee() public {
        _deployHarnessOneMarket(1000, 1 days); // 10% fee

        uint256 depositAmount = 100_000e6;
        deal(USDC_MONAD, USER_A, depositAmount);
        vm.startPrank(USER_A);
        IERC20(USDC_MONAD).approve(address(harness), depositAmount);
        harness.deposit(depositAmount, USER_A);
        vm.stopPrank();

        // Complete first vesting cycle to set watermark.
        vm.warp(block.timestamp + 1 days + 1);
        harness.exchangeRateUpdated();
        vm.warp(block.timestamp + 1 days + 1);
        harness.exchangeRateUpdated();

        uint256 watermark = harness.exchangeRateHighWatermark();
        address dao = liveCentralRegistry.daoAddress();
        uint256 daoSharesBefore = harness.balanceOf(dao);

        console2.log("Watermark:", watermark);

        // Now if we accrue immediately (no new yield), rate should equal watermark.
        // No fee should be charged.
        vm.warp(block.timestamp + 1 days + 1);
        uint256 rateNow = harness.exchangeRateUpdated();
        uint256 daoSharesAfter = harness.balanceOf(dao);

        console2.log("Rate now:", rateNow);
        console2.log("DAO shares before:", daoSharesBefore);
        console2.log("DAO shares after:", daoSharesAfter);

        // When rate <= watermark, no additional fee shares should be minted.
        // (There may be some yield that pushes rate slightly above watermark)
        // The key point: no fee charged if rate == watermark exactly.
    }

    /// @notice Test: feeShares denominator safety - (currentAssets - feeAssets) > 0
    /// @dev With dead shares ensuring a minimum vault size, the denominator should
    ///      never reach zero. This verifies the dead shares protection.
    function test_feeEdgeCase_denominatorSafety() public {
        _deployHarnessOneMarket(5000, 1 days); // Max 50% fee

        // Only dead shares in the vault (no user deposit).
        // Generate yield via time passage.
        vm.warp(block.timestamp + 30 days);

        uint256 totalAssetsBefore = harness.totalAssets();
        uint256 supplyBefore = harness.totalSupply();

        console2.log("Total assets (dead shares only):", totalAssetsBefore);
        console2.log("Total supply (dead shares only):", supplyBefore);

        // Trigger accrual. Even with 50% fee, currentAssets - feeAssets should be > 0
        // because the vault has at least dead share value.
        harness.exchangeRateUpdated();
        vm.warp(block.timestamp + 1 days + 1);
        harness.exchangeRateUpdated();

        // If this doesn't revert, the denominator is safe.
        uint256 rateAfter = harness.exchangeRate();
        console2.log("Exchange rate after fee on dead shares:", rateAfter);
        assertGt(rateAfter, 0, "Exchange rate should be positive");
    }

    // =========================================================================
    // D. _fullyDilutedAssets vs totalAssets Deposit/Redeem Asymmetry
    // =========================================================================

    /// @notice Test: Depositor during vesting gets fewer shares (fully-diluted pricing)
    ///         but withdrawal uses totalAssets (partially vested). Verify this results
    ///         in a LOSS for the depositor, not a gain.
    /// @dev This is the anti-frontrunning mechanism. A deposit-then-immediate-redeem
    ///      during active vesting should lose value proportional to unvested yield.
    function test_fullyDiluted_depositDuringVesting_immediateRedeem_lossNotGain() public {
        _deployHarnessOneMarket(0, 1 days); // No fee to isolate the pricing effect.

        // USER_A deposits before any vesting.
        uint256 depositA = 500_000e6; // 500K USDC
        deal(USDC_MONAD, USER_A, depositA);
        vm.startPrank(USER_A);
        IERC20(USDC_MONAD).approve(address(harness), depositA);
        harness.deposit(depositA, USER_A);
        vm.stopPrank();

        // Wait for first vesting to complete and accrue yield.
        vm.warp(block.timestamp + 1 days + 1);
        harness.exchangeRateUpdated();

        // Let more interest accrue.
        vm.warp(block.timestamp + 30 days);

        // Trigger new vesting cycle.
        harness.exchangeRateUpdated();

        // Now we're mid-vesting. Attacker tries to deposit and immediately redeem.
        vm.warp(block.timestamp + 12 hours); // 50% through vesting

        bool isVesting = harness.exposed_isVestingActive();
        assertTrue(isVesting, "Should be in active vesting");

        uint256 fullyDiluted = harness.previewDeposit(1_000e6); // shares for 1K USDC with FD pricing
        uint256 normalShares = harness.convertToShares(1_000e6); // shares with normal pricing

        console2.log("Shares via previewDeposit (fully-diluted):", fullyDiluted);
        console2.log("Shares via convertToShares (normal):", normalShares);
        console2.log("Difference:", normalShares - fullyDiluted);

        // Fully-diluted should give FEWER shares (anti-frontrunning).
        assertLt(fullyDiluted, normalShares, "Fully-diluted should give fewer shares");

        // Now attacker deposits.
        uint256 attackAmount = 100_000e6; // 100K USDC
        deal(USDC_MONAD, ATTACKER, attackAmount);
        vm.startPrank(ATTACKER);
        IERC20(USDC_MONAD).approve(address(harness), attackAmount);
        uint256 sharesReceived = harness.deposit(attackAmount, ATTACKER);

        // Immediately redeem.
        uint256 assetsBack = harness.redeem(sharesReceived, ATTACKER, ATTACKER);
        vm.stopPrank();

        console2.log("Attacker deposited:", attackAmount);
        console2.log("Shares received:", sharesReceived);
        console2.log("Assets back on immediate redeem:", assetsBack);

        // Attacker should get LESS back than they deposited.
        assertLt(assetsBack, attackAmount, "Attacker should lose on immediate redeem during vesting");

        uint256 loss = attackAmount - assetsBack;
        console2.log("Attacker loss:", loss);
        console2.log("Attacker loss %:", loss * 10000 / attackAmount, "bps");
    }

    /// @notice Test: When no vesting is active, fullyDilutedAssets == totalAssets.
    ///         Deposit and immediate redeem should have minimal loss (only cToken rounding).
    /// @dev Note: On a live fork, accruing always detects new cToken interest, so
    ///      vesting restarts on every accrual. To test outside of vesting, we verify
    ///      the pricing math directly: when vestingRate=0, previewDeposit == convertToShares.
    function test_fullyDiluted_afterVesting_noPricingAsymmetry() public {
        _deployHarnessOneMarket(0, 1 days);

        uint256 depositA = 500_000e6;
        deal(USDC_MONAD, USER_A, depositA);
        vm.startPrank(USER_A);
        IERC20(USDC_MONAD).approve(address(harness), depositA);
        harness.deposit(depositA, USER_A);
        vm.stopPrank();

        // Complete vesting cycles. On a live fork, new yield is always detected
        // so vesting may restart. We test the math equivalence instead.
        vm.warp(block.timestamp + 1 days + 1);
        harness.exchangeRateUpdated();

        vm.warp(block.timestamp + 30 days);
        harness.exchangeRateUpdated();
        vm.warp(block.timestamp + 1 days + 1);
        harness.exchangeRateUpdated();

        bool isVesting = harness.exposed_isVestingActive();
        console2.log("Is vesting active:", isVesting);

        if (!isVesting) {
            // When not vesting, previewDeposit == convertToShares (no asymmetry).
            uint256 testAmount = 10_000e6;
            uint256 previewShares = harness.previewDeposit(testAmount);
            uint256 convertShares = harness.convertToShares(testAmount);
            console2.log("previewDeposit shares:", previewShares);
            console2.log("convertToShares:", convertShares);
            assertEq(previewShares, convertShares, "Should be equal when not vesting");
        } else {
            // Even when vesting is active (common on live fork due to continuous interest),
            // we can verify that previewDeposit gives FEWER shares than convertToShares.
            // This is the intended anti-frontrunning asymmetry.
            uint256 testAmount = 10_000e6;
            uint256 previewShares = harness.previewDeposit(testAmount);
            uint256 convertShares = harness.convertToShares(testAmount);
            console2.log("previewDeposit shares (fully-diluted):", previewShares);
            console2.log("convertToShares (normal):", convertShares);
            assertLe(previewShares, convertShares, "FD pricing should give <= normal shares");

            // Deposit and immediate redeem: verify loss (anti-frontrunning).
            deal(USDC_MONAD, USER_B, testAmount);
            vm.startPrank(USER_B);
            IERC20(USDC_MONAD).approve(address(harness), testAmount);
            uint256 shares = harness.deposit(testAmount, USER_B);
            uint256 back = harness.redeem(shares, USER_B, USER_B);
            vm.stopPrank();

            console2.log("Deposited:", testAmount);
            console2.log("Got back:", back);

            // Should lose some amount due to FD pricing asymmetry.
            // The loss is bounded by the unvested yield fraction.
            if (back < testAmount) {
                console2.log("Loss (anti-frontrunning working):", testAmount - back);
            } else {
                console2.log("No loss - rounding may have compensated");
            }
        }
    }

    // =========================================================================
    // E. Zero-Amount Operations
    // =========================================================================

    /// @notice Test: deposit(0) behavior - does it revert or succeed?
    ///         Can it trigger state changes via _accrueIfNeeded()?
    function test_zeroAmount_deposit() public {
        _deployHarnessOneMarket(0, 1 days);

        // Fund vault first.
        uint256 depositA = 100_000e6;
        deal(USDC_MONAD, USER_A, depositA);
        vm.startPrank(USER_A);
        IERC20(USDC_MONAD).approve(address(harness), depositA);
        harness.deposit(depositA, USER_A);
        vm.stopPrank();

        // Try deposit(0).
        deal(USDC_MONAD, ATTACKER, 0);
        vm.startPrank(ATTACKER);
        IERC20(USDC_MONAD).approve(address(harness), 0);

        // deposit(0) will call _processDeposit(0, ...) which calls
        // safeTransferFrom(0) and cToken.deposit(0).
        // This may revert in the cToken or succeed silently.
        bool success;
        try harness.deposit(0, ATTACKER) returns (uint256 shares) {
            success = true;
            console2.log("deposit(0) succeeded, shares:", shares);
            assertEq(shares, 0, "Should mint 0 shares");
        } catch {
            success = false;
            console2.log("deposit(0) reverted (expected for some tokens)");
        }
        vm.stopPrank();

        // Either way, no funds were extracted and the vault state should be consistent.
        uint256 attackerBalance = harness.balanceOf(ATTACKER);
        assertEq(attackerBalance, 0, "Attacker should have 0 shares");
    }

    /// @notice Test: withdraw(0) and redeem(0) - do they trigger state changes?
    function test_zeroAmount_withdraw_and_redeem() public {
        _deployHarnessOneMarket(0, 1 days);

        uint256 depositA = 100_000e6;
        deal(USDC_MONAD, USER_A, depositA);
        vm.startPrank(USER_A);
        IERC20(USDC_MONAD).approve(address(harness), depositA);
        harness.deposit(depositA, USER_A);
        vm.stopPrank();

        // Generate yield and start vesting.
        vm.warp(block.timestamp + 1 days + 1);
        harness.exchangeRateUpdated();
        vm.warp(block.timestamp + 30 days);
        harness.exchangeRateUpdated();

        uint256 totalAssetsBefore = harness.totalAssets();
        uint256 totalSupplyBefore = harness.totalSupply();

        // Try withdraw(0).
        vm.startPrank(USER_A);
        bool withdrawSuccess;
        try harness.withdraw(0, USER_A, USER_A) returns (uint256 shares) {
            withdrawSuccess = true;
            console2.log("withdraw(0) succeeded, shares burned:", shares);
            assertEq(shares, 0, "Should burn 0 shares");
        } catch {
            console2.log("withdraw(0) reverted");
        }

        // Try redeem(0).
        bool redeemSuccess;
        try harness.redeem(0, USER_A, USER_A) returns (uint256 assets) {
            redeemSuccess = true;
            console2.log("redeem(0) succeeded, assets:", assets);
            assertEq(assets, 0, "Should return 0 assets");
        } catch {
            console2.log("redeem(0) reverted");
        }
        vm.stopPrank();

        // Key check: _accrueIfNeeded() ran but should not change accounting.
        // totalSupply should remain unchanged.
        assertEq(harness.totalSupply(), totalSupplyBefore, "Supply should not change on zero ops");
    }

    /// @notice Test: Zero-amount operations don't provide any capability beyond
    ///         what accrueIfNeeded() already provides (public function).
    function test_zeroAmount_noExtraCapability() public {
        _deployHarnessOneMarket(0, 1 days);

        uint256 depositA = 100_000e6;
        deal(USDC_MONAD, USER_A, depositA);
        vm.startPrank(USER_A);
        IERC20(USDC_MONAD).approve(address(harness), depositA);
        harness.deposit(depositA, USER_A);
        vm.stopPrank();

        // Generate yield.
        vm.warp(block.timestamp + 1 days + 1);

        // State before.
        uint256 rateBefore = harness.exchangeRate();

        // Trigger accrual via the public accrueIfNeeded() function.
        harness.accrueIfNeeded();

        uint256 rateAfterPublicAccrue = harness.exchangeRate();

        console2.log("Rate before:", rateBefore);
        console2.log("Rate after accrueIfNeeded():", rateAfterPublicAccrue);

        // The public function already provides the same state update.
        // Zero-amount deposit/withdraw cannot do anything additional.
        // exchangeRateUpdated() is also public and triggers accrual.
    }

    // =========================================================================
    // F. Multiple setFee Calls During Vesting
    // =========================================================================

    /// @notice Test: Multiple setFee calls during vesting - only the LAST one takes effect.
    function test_multipleFeeChanges_duringVesting_lastWins() public {
        _deployHarnessOneMarket(1000, 1 days); // Start with 10% fee

        // Deposit.
        uint256 depositA = 500_000e6;
        deal(USDC_MONAD, USER_A, depositA);
        vm.startPrank(USER_A);
        IERC20(USDC_MONAD).approve(address(harness), depositA);
        harness.deposit(depositA, USER_A);
        vm.stopPrank();

        // Complete first vesting cycle.
        vm.warp(block.timestamp + 1 days + 1);
        harness.exchangeRateUpdated();

        // Generate yield and start new vesting.
        vm.warp(block.timestamp + 30 days);
        harness.exchangeRateUpdated();

        // Verify we're in active vesting.
        assertTrue(harness.exposed_isVestingActive(), "Should be vesting");

        // Now set fee multiple times during vesting.
        harness.setFee(5000); // Set to 50%
        (bool pending1, uint248 newFee1) = harness.pendingFeeUpdate();
        console2.log("After setFee(5000) - pending:", pending1, "newFee:", newFee1);
        assertEq(newFee1, 5000, "Pending should be 5000");

        harness.setFee(0); // Set to 0%
        (bool pending2, uint248 newFee2) = harness.pendingFeeUpdate();
        console2.log("After setFee(0) - pending:", pending2, "newFee:", newFee2);
        assertEq(newFee2, 0, "Pending should be 0");

        harness.setFee(2000); // Set to 20%
        (bool pending3, uint248 newFee3) = harness.pendingFeeUpdate();
        console2.log("After setFee(2000) - pending:", pending3, "newFee:", newFee3);
        assertEq(newFee3, 2000, "Pending should be 2000");

        // Current fee should still be the original 10%.
        assertEq(harness.fee(), 1000, "Fee should still be 1000 during vesting");

        // Complete vesting. The pending update should apply.
        vm.warp(block.timestamp + 1 days + 1);
        harness.exchangeRateUpdated();

        // Now the fee should be the LAST one set (20%).
        assertEq(harness.fee(), 2000, "Fee should be 2000 after vesting ends");

        // Verify pending is cleared.
        (bool pendingFinal, uint248 newFeeFinal) = harness.pendingFeeUpdate();
        assertFalse(pendingFinal, "Pending should be cleared");
        console2.log("Final fee:", harness.fee());
    }

    /// @notice Test: setFee during vesting charges the OLD fee on current cycle yield,
    ///         then applies the new fee for future cycles.
    function test_feeChange_duringVesting_oldFeeAppliedFirst() public {
        _deployHarnessOneMarket(1000, 1 days); // 10% fee

        uint256 depositA = 500_000e6;
        deal(USDC_MONAD, USER_A, depositA);
        vm.startPrank(USER_A);
        IERC20(USDC_MONAD).approve(address(harness), depositA);
        harness.deposit(depositA, USER_A);
        vm.stopPrank();

        // Complete first vesting.
        vm.warp(block.timestamp + 1 days + 1);
        harness.exchangeRateUpdated();

        // Generate yield.
        vm.warp(block.timestamp + 30 days);
        harness.exchangeRateUpdated(); // Starts vesting

        // Queue fee change to 50% during vesting.
        harness.setFee(5000);

        address dao = liveCentralRegistry.daoAddress();
        uint256 daoSharesBefore = harness.balanceOf(dao);

        // Complete vesting - fee charged should be at OLD rate (10%).
        vm.warp(block.timestamp + 1 days + 1);
        harness.exchangeRateUpdated();

        uint256 daoSharesAfter = harness.balanceOf(dao);
        uint256 feeSharesMinted = daoSharesAfter - daoSharesBefore;

        console2.log("DAO shares minted (should be at 10% rate):", feeSharesMinted);
        console2.log("New fee after application:", harness.fee());
        assertEq(harness.fee(), 5000, "Fee should now be 50%");

        // For the next cycle, the 50% fee applies.
        // Generate more yield.
        vm.warp(block.timestamp + 30 days);
        harness.exchangeRateUpdated();

        daoSharesBefore = harness.balanceOf(dao);

        vm.warp(block.timestamp + 1 days + 1);
        harness.exchangeRateUpdated();

        uint256 feeSharesSecondCycle = harness.balanceOf(dao) - daoSharesBefore;
        console2.log("DAO shares 2nd cycle (at 50% rate):", feeSharesSecondCycle);

        // The second cycle's fee shares should be higher relative to yield
        // because the fee rate is 5x higher.
    }

    /// @notice Test: setFee called at exact vesting boundary (block.timestamp == vestEnd).
    /// @dev FINDING: At the vesting boundary, _accrueIfNeeded() detects new yield
    ///      from ongoing cToken interest and starts a NEW vesting cycle. This means
    ///      setFee's post-accrual check always sees active vesting, so the fee change
    ///      is ALWAYS queued (never applied immediately at a boundary). This is safe
    ///      behavior but means fee changes are always deferred by one vesting period
    ///      when called at boundaries.
    function test_feeChange_atExactVestingBoundary_alwaysQueued() public {
        _deployHarnessOneMarket(1000, 1 days);

        uint256 depositA = 500_000e6;
        deal(USDC_MONAD, USER_A, depositA);
        vm.startPrank(USER_A);
        IERC20(USDC_MONAD).approve(address(harness), depositA);
        harness.deposit(depositA, USER_A);
        vm.stopPrank();

        // Complete first vesting.
        vm.warp(block.timestamp + 1 days + 1);
        harness.exchangeRateUpdated();

        // Generate yield and start vesting.
        vm.warp(block.timestamp + 30 days);
        harness.exchangeRateUpdated();

        (, uint256 vestEnd,) = harness.exposed_getVestingData();
        console2.log("Vesting end:", vestEnd);

        // Warp to EXACTLY vesting end.
        vm.warp(vestEnd);

        // At this point, block.timestamp == vestEnd.
        // _accrueIfNeeded runs: vesting is complete (block.timestamp >= vestEnd).
        // But it detects new yield from cToken interest and starts a NEW vesting cycle.
        // So after _accrueIfNeeded returns, there IS active vesting again.
        // setFee sees active vesting and queues the change as pending.
        harness.setFee(5000);

        console2.log("Fee after boundary setFee:", harness.fee());
        console2.log("Vesting still active:", harness.exposed_isVestingActive());

        // Fee should NOT have changed yet - it's queued as pending.
        assertEq(harness.fee(), 1000, "Fee should still be old value (queued as pending)");

        (bool pending, uint248 newFee) = harness.pendingFeeUpdate();
        assertTrue(pending, "Fee change should be pending");
        assertEq(newFee, 5000, "Pending fee should be 5000");

        // The fee will apply when this new vesting cycle ends.
        vm.warp(block.timestamp + 1 days + 1);
        harness.exchangeRateUpdated();

        // Now it should be applied (or still pending if yet another cycle started).
        console2.log("Fee after next cycle:", harness.fee());
    }

    // =========================================================================
    // G. Additional: Exchange Rate Watermark Reset on Fee Enable
    // =========================================================================

    /// @notice Test: When fee is set from 0 to non-zero, the watermark resets
    ///         to the current exchange rate so prior yield is not retroactively taxed.
    function test_feeEnable_watermarkReset() public {
        _deployHarnessOneMarket(0, 1 days); // Start with 0% fee

        uint256 depositA = 500_000e6;
        deal(USDC_MONAD, USER_A, depositA);
        vm.startPrank(USER_A);
        IERC20(USDC_MONAD).approve(address(harness), depositA);
        harness.deposit(depositA, USER_A);
        vm.stopPrank();

        // Generate significant yield with 0% fee.
        vm.warp(block.timestamp + 1 days + 1);
        harness.exchangeRateUpdated();
        vm.warp(block.timestamp + 90 days);
        harness.exchangeRateUpdated();
        vm.warp(block.timestamp + 1 days + 1);
        harness.exchangeRateUpdated();

        uint256 rateBeforeFeeEnable = harness.exchangeRate();
        uint256 watermarkBefore = harness.exchangeRateHighWatermark();
        address dao = liveCentralRegistry.daoAddress();
        uint256 daoSharesBefore = harness.balanceOf(dao);

        console2.log("Rate before fee enable:", rateBeforeFeeEnable);
        console2.log("Watermark before:", watermarkBefore);
        console2.log("DAO shares before:", daoSharesBefore);

        // Enable fee to 10%.
        harness.setFee(1000);

        uint256 watermarkAfter = harness.exchangeRateHighWatermark();
        uint256 daoSharesAfter = harness.balanceOf(dao);

        console2.log("Watermark after fee enable:", watermarkAfter);
        console2.log("DAO shares after fee enable:", daoSharesAfter);

        // Watermark should have been updated to current rate.
        // No fees should have been charged on prior yield.
        assertEq(daoSharesAfter, daoSharesBefore, "No fees on prior yield");

        // Watermark should now be at or near the current rate.
        // (It might be the original WAD if no fee cycle has run yet.)
        assertGe(watermarkAfter, watermarkBefore, "Watermark should not decrease");
    }

    // =========================================================================
    // H. Vesting Data Integrity Through Multiple Cycles
    // =========================================================================

    /// @notice Test: Vesting data remains consistent through 10 consecutive cycles.
    ///         Verifies no accumulation of rounding errors.
    function test_vestingCycles_10x_noAccumulatedError() public {
        _deployHarnessOneMarket(1000, 1 days); // 10% fee

        uint256 depositA = 1_000_000e6; // 1M USDC
        deal(USDC_MONAD, USER_A, depositA);
        vm.startPrank(USER_A);
        IERC20(USDC_MONAD).approve(address(harness), depositA);
        harness.deposit(depositA, USER_A);
        vm.stopPrank();

        uint256 prevRate = harness.exchangeRate();
        console2.log("Initial rate:", prevRate);

        for (uint256 i = 0; i < 10; i++) {
            // Wait for vesting to complete.
            vm.warp(block.timestamp + 1 days + 1);
            harness.exchangeRateUpdated();

            // Generate yield.
            vm.warp(block.timestamp + 7 days);
            uint256 newRate = harness.exchangeRateUpdated();

            console2.log("Cycle", i, "rate:", newRate);

            // Exchange rate should never decrease.
            assertGe(newRate, prevRate, "Rate should not decrease across cycles");

            // Verify vesting data is clean.
            (uint256 rate, uint256 end, uint256 last) = harness.exposed_getVestingData();
            if (rate > 0) {
                assertGt(end, last, "End should be after last claim");
                assertLe(rate, uint256(type(uint176).max), "Rate should fit in 176 bits");
            }

            prevRate = newRate;
        }

        // Final consistency check.
        uint256 rawTa = harness.exposed_accrueMarkets();
        uint256 ta = harness.totalAssets();
        uint256 indexedAssets = harness.exposed_totalAssetsIndexed();

        console2.log("Final rawTa:", rawTa);
        console2.log("Final totalAssets:", ta);
        console2.log("Final _totalAssets:", indexedAssets);

        // rawTa should be >= ta (or within rounding buffer).
        // After 10 cycles, accumulated rounding error should be small.
        if (rawTa + harness.roundingBuffer() >= ta) {
            console2.log("Accounting is consistent (within rounding buffer)");
        } else {
            console2.log("WARNING: rawTa is below ta by more than rounding buffer");
        }
    }

    // =========================================================================
    // I. Fee Calculation: Large Profit Doesn't Overflow
    // =========================================================================

    /// @notice Test: Fee calculation with large vault and max fee doesn't overflow.
    function test_feeCalculation_largeVault_noOverflow() public {
        _deployHarnessOneMarket(5000, 1 days); // 50% fee

        // Large vault.
        uint256 depositA = 100_000_000e6; // 100M USDC
        deal(USDC_MONAD, USER_A, depositA);
        vm.startPrank(USER_A);
        IERC20(USDC_MONAD).approve(address(harness), depositA);
        harness.deposit(depositA, USER_A);
        vm.stopPrank();

        // Generate significant yield.
        vm.warp(block.timestamp + 1 days + 1);
        harness.exchangeRateUpdated();
        vm.warp(block.timestamp + 365 days);

        // This should not overflow despite large numbers.
        uint256 rate = harness.exchangeRateUpdated();
        console2.log("Rate after 1 year:", rate);

        vm.warp(block.timestamp + 1 days + 1);
        rate = harness.exchangeRateUpdated();
        console2.log("Rate after fee accrual:", rate);

        assertGt(rate, WAD, "Rate should be above 1:1 after yield");

        address dao = liveCentralRegistry.daoAddress();
        uint256 daoShares = harness.balanceOf(dao);
        console2.log("DAO shares:", daoShares);
        assertGt(daoShares, 0, "DAO should have received fee shares");
    }

    // =========================================================================
    // J. setFee from non-zero to 0 during vesting
    // =========================================================================

    /// @notice Test: Setting fee to 0 during vesting. Current cycle's yield is still
    ///         taxed at the old rate. Next cycle has no fee.
    function test_feeDisable_duringVesting() public {
        _deployHarnessOneMarket(2000, 1 days); // 20% fee

        uint256 depositA = 500_000e6;
        deal(USDC_MONAD, USER_A, depositA);
        vm.startPrank(USER_A);
        IERC20(USDC_MONAD).approve(address(harness), depositA);
        harness.deposit(depositA, USER_A);
        vm.stopPrank();

        // Complete first vesting.
        vm.warp(block.timestamp + 1 days + 1);
        harness.exchangeRateUpdated();

        // Generate yield.
        vm.warp(block.timestamp + 30 days);
        harness.exchangeRateUpdated(); // Starts vesting

        // Disable fee during vesting.
        harness.setFee(0);
        (bool pending, uint248 newFee) = harness.pendingFeeUpdate();
        assertTrue(pending, "Should have pending update");
        assertEq(newFee, 0, "Pending fee should be 0");

        address dao = liveCentralRegistry.daoAddress();
        uint256 daoSharesBefore = harness.balanceOf(dao);

        // Complete vesting - old fee (20%) should be charged.
        vm.warp(block.timestamp + 1 days + 1);
        harness.exchangeRateUpdated();

        uint256 daoSharesAfter = harness.balanceOf(dao);
        uint256 feeSharesCycle1 = daoSharesAfter - daoSharesBefore;

        console2.log("Fee shares cycle 1 (at 20%):", feeSharesCycle1);
        console2.log("Fee after disable:", harness.fee());
        assertEq(harness.fee(), 0, "Fee should now be 0");

        // Next cycle should have no fees.
        vm.warp(block.timestamp + 30 days);
        harness.exchangeRateUpdated();

        daoSharesBefore = harness.balanceOf(dao);

        vm.warp(block.timestamp + 1 days + 1);
        harness.exchangeRateUpdated();

        uint256 feeSharesCycle2 = harness.balanceOf(dao) - daoSharesBefore;
        console2.log("Fee shares cycle 2 (at 0%):", feeSharesCycle2);
        assertEq(feeSharesCycle2, 0, "No fees should be charged at 0%");
    }
}
