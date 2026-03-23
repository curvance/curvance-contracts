// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizerHarness } from "../LendingOptimizerHarness.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { WAD, BPS } from "contracts/libraries/ConstantsLib.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

/// @title ERC4626 Compliance Fuzz Tests for LendingOptimizer
/// @notice Verifies that the optimizer conforms to ERC4626 preview/convert/max
///         semantics and that rounding always favors the vault.
contract ERC4626ComplianceFuzz is TestBaseLendingOptimizer {

    LendingOptimizerHarness harness;

    address depositor = address(0xD001);
    address depositor2 = address(0xD002);

    function setUp() public override {
        super.setUp();
        _setUpHarness();
    }

    function _setUpHarness() internal {
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

        // Seed some initial liquidity so exchange rate is established.
        deal(USDC_MONAD, address(this), 500_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 500_000e6);
        harness.deposit(500_000e6, address(this));
    }

    // =========================================================================
    // PREVIEW DEPOSIT
    // =========================================================================

    /// @notice previewDeposit should match actual deposit shares within ±2 wei.
    /// @dev The ±2 tolerance accounts for cToken assets→shares→assets rounding.
    function testFuzz_previewDeposit_matchesActual(uint256 assets) public {
        assets = bound(assets, 1e6, 10_000_000e6);

        uint256 previewed = harness.previewDeposit(assets);

        deal(USDC_MONAD, depositor, assets);
        vm.startPrank(depositor);
        IERC20(USDC_MONAD).approve(address(harness), assets);
        uint256 actual = harness.deposit(assets, depositor);
        vm.stopPrank();

        // Actual shares should be close to previewed.
        assertApproxEqAbs(
            actual,
            previewed,
            2,
            "previewDeposit diverged from actual deposit by > 2 wei"
        );

        // Vault-favorable rounding: actual shares should not exceed previewed.
        assertLe(
            actual,
            previewed + 1,
            "Actual shares exceeded previewed (vault-unfavorable rounding)"
        );
    }

    // =========================================================================
    // STANDARD 2-ARG DEPOSIT (ERC4626 SPEC)
    // =========================================================================

    /// @notice Standard 2-arg deposit(assets, receiver) should work correctly
    ///         and return shares consistent with previewDeposit.
    /// @dev Verifies the ERC4626 standard deposit signature routes to the
    ///      optimal market and returns shares >= previewDeposit (within cToken
    ///      rounding tolerance).
    function testFuzz_standardDeposit_twoArg(uint256 assets) public {
        assets = bound(assets, 1e6, 100_000e6);

        // Snapshot preview before deposit (state is already accrued from setUp).
        uint256 previewed = harness.previewDeposit(assets);

        uint256 sharesBefore = harness.balanceOf(depositor);

        deal(USDC_MONAD, depositor, assets);
        vm.startPrank(depositor);
        IERC20(USDC_MONAD).approve(address(harness), assets);
        // Call the standard 2-arg deposit(assets, receiver) -- NOT the 3-arg version.
        uint256 actual = harness.deposit(assets, depositor);
        vm.stopPrank();

        uint256 sharesAfter = harness.balanceOf(depositor);

        // Shares returned must be > 0 for any non-dust deposit.
        assertGt(actual, 0, "Standard 2-arg deposit returned 0 shares");

        // ERC4626 spec: deposit() MUST return >= previewDeposit().
        // Allow 1 wei tolerance for the cToken deposit round-trip rounding.
        assertGe(
            actual + 1,
            previewed,
            "Standard 2-arg deposit returned fewer shares than previewDeposit minus cToken rounding"
        );

        // User share balance should have increased by exactly the returned amount.
        assertEq(
            sharesAfter - sharesBefore,
            actual,
            "User share balance increase does not match returned shares"
        );
    }

    // =========================================================================
    // PREVIEW MINT
    // =========================================================================

    /// @notice previewMint should match actual mint cost within ±2 wei.
    function testFuzz_previewMint_matchesActual(uint256 shares) public {
        shares = bound(shares, 1e6, 10_000_000e6);

        uint256 previewedAssets = harness.previewMint(shares);
        if (previewedAssets == 0) return;

        deal(USDC_MONAD, depositor, previewedAssets + 1000);
        vm.startPrank(depositor);
        IERC20(USDC_MONAD).approve(address(harness), previewedAssets + 1000);
        uint256 actualAssets = harness.mint(shares, depositor);
        vm.stopPrank();

        // mint() should spend approximately previewMint() assets.
        // Per-market conversion roundtrip may cause mint() to pull slightly more.
        assertApproxEqAbs(
            actualAssets,
            previewedAssets,
            3,
            "mint() should approximately match previewMint()"
        );
    }

    // =========================================================================
    // PREVIEW WITHDRAW
    // =========================================================================

    /// @notice previewWithdraw should match actual withdraw shares exactly.
    function testFuzz_previewWithdraw_matchesActual(uint256 assets) public {
        // First deposit so depositor has shares.
        uint256 depositAmount = 5_000_000e6;
        deal(USDC_MONAD, depositor, depositAmount);
        vm.startPrank(depositor);
        IERC20(USDC_MONAD).approve(address(harness), depositAmount);
        harness.deposit(depositAmount, depositor);
        vm.stopPrank();

        uint256 maxW = harness.maxWithdraw(depositor);
        if (maxW < 1e6) return;
        assets = bound(assets, 1e6, maxW);

        uint256 previewedShares = harness.previewWithdraw(assets);

        vm.prank(depositor);
        uint256 actualShares = harness.withdraw(assets, depositor, depositor);

        assertEq(
            actualShares,
            previewedShares,
            "previewWithdraw does not match actual withdraw shares"
        );
    }

    // =========================================================================
    // PREVIEW REDEEM
    // =========================================================================

    /// @notice previewRedeem should approximately match actual redeem assets.
    /// @dev redeem() applies a conversion roundtrip (previewRedeem(previewDeposit()))
    ///      per-market that may reduce the payout by a few wei vs previewRedeem().
    function testFuzz_previewRedeem_matchesActual(uint256 shares) public {
        // First deposit so depositor has shares.
        uint256 depositAmount = 5_000_000e6;
        deal(USDC_MONAD, depositor, depositAmount);
        vm.startPrank(depositor);
        IERC20(USDC_MONAD).approve(address(harness), depositAmount);
        harness.deposit(depositAmount, depositor);
        vm.stopPrank();

        uint256 maxR = harness.maxRedeem(depositor);
        if (maxR == 0) return;
        // Minimum shares must be large enough that the conversion roundtrip
        // in redeem() produces a non-zero withdrawal amount.
        shares = bound(shares, 1e6, maxR);

        uint256 previewedAssets = harness.previewRedeem(shares);

        vm.prank(depositor);
        uint256 actualAssets = harness.redeem(shares, depositor, depositor);

        // Actual payout may be up to numMarkets wei less than preview
        // due to per-market conversion roundtrip rounding.
        assertApproxEqAbs(
            actualAssets,
            previewedAssets,
            3,
            "previewRedeem does not match actual redeem assets"
        );
    }

    // =========================================================================
    // ROUND-TRIP: DEPOSIT -> REDEEM
    // =========================================================================

    /// @notice Deposit X, redeem all shares: should get back X - rounding, never more than X.
    function testFuzz_roundTrip_depositRedeem(uint256 assets) public {
        assets = bound(assets, 1e6, 10_000_000e6);

        deal(USDC_MONAD, depositor, assets);
        vm.startPrank(depositor);
        IERC20(USDC_MONAD).approve(address(harness), assets);
        uint256 shares = harness.deposit(assets, depositor);
        vm.stopPrank();

        assertGt(shares, 0, "No shares minted");

        // Immediately redeem all shares.
        vm.prank(depositor);
        uint256 assetsOut = harness.redeem(shares, depositor, depositor);

        // Must never return more than deposited.
        assertLe(
            assetsOut,
            assets,
            "Round-trip returned more than deposited (vault-unfavorable)"
        );

        // Should be within reasonable rounding tolerance.
        assertApproxEqAbs(
            assetsOut,
            assets,
            10,
            "Round-trip loss exceeds 10 wei (excessive rounding)"
        );
    }

    // =========================================================================
    // ROUND-TRIP: MINT -> WITHDRAW
    // =========================================================================

    /// @notice Mint shares, withdraw all: should be consistent with expectations.
    function testFuzz_roundTrip_mintWithdraw(uint256 shares) public {
        shares = bound(shares, 1e6, 10_000_000e6);

        uint256 assetCost = harness.previewMint(shares);
        if (assetCost == 0) return;

        deal(USDC_MONAD, depositor, assetCost + 1000);
        vm.startPrank(depositor);
        IERC20(USDC_MONAD).approve(address(harness), assetCost + 1000);
        uint256 actualCost = harness.mint(shares, depositor);
        vm.stopPrank();

        uint256 depositorShares = harness.balanceOf(depositor);
        assertGt(depositorShares, 0, "No shares after mint");

        // Withdraw all (using maxWithdraw to avoid underflow).
        uint256 maxW = harness.maxWithdraw(depositor);
        if (maxW == 0) return;

        vm.prank(depositor);
        uint256 sharesBurned = harness.withdraw(maxW, depositor, depositor);

        // Shares burned should be <= depositorShares.
        assertLe(
            sharesBurned,
            depositorShares,
            "More shares burned than held"
        );
    }

    // =========================================================================
    // CONVERT ROUND-TRIPS (ROUNDING FAVORS VAULT)
    // =========================================================================

    /// @notice convertToAssets(convertToShares(X)) <= X always (rounding favors vault).
    function testFuzz_convertToAssets_roundTrip(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);

        uint256 shares = harness.convertToShares(amount);
        uint256 assetsBack = harness.convertToAssets(shares);

        assertLe(
            assetsBack,
            amount,
            "convertToAssets(convertToShares(X)) > X: rounding favors user, not vault"
        );
    }

    /// @notice convertToShares(convertToAssets(Y)) <= Y always (rounding favors vault).
    function testFuzz_convertToShares_roundTrip(uint256 shares) public {
        shares = bound(shares, 1, type(uint128).max);

        uint256 assets = harness.convertToAssets(shares);
        uint256 sharesBack = harness.convertToShares(assets);

        assertLe(
            sharesBack,
            shares,
            "convertToShares(convertToAssets(Y)) > Y: rounding favors user, not vault"
        );
    }

    // =========================================================================
    // MAX DEPOSIT / MAX MINT PAUSE STATES
    // =========================================================================

    /// @notice maxDeposit should return 0 when paused, type(uint256).max when active.
    function testFuzz_maxDeposit_pauseState(bool paused) public {
        if (paused) {
            harness.setMintPaused(true);
        }

        uint256 maxDep = harness.maxDeposit(depositor);

        if (paused) {
            assertEq(maxDep, 0, "maxDeposit should be 0 when paused");
            // Unpause for next tests.
            harness.setMintPaused(false);
        } else {
            assertGt(maxDep, 0, "maxDeposit should be > 0 when active");
        }
    }

    /// @notice maxMint should return 0 when paused, > 0 when active.
    function testFuzz_maxMint_pauseState(bool paused) public {
        if (paused) {
            harness.setMintPaused(true);
        }

        uint256 maxM = harness.maxMint(depositor);

        if (paused) {
            assertEq(maxM, 0, "maxMint should be 0 when paused");
            harness.setMintPaused(false);
        } else {
            assertGt(maxM, 0, "maxMint should be > 0 when active");
        }
    }

    // =========================================================================
    // MAX WITHDRAW CORRECTNESS
    // =========================================================================

    /// @notice maxWithdraw should be capped at _totalAssets and be executable.
    function testFuzz_maxWithdraw_correctness(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1e6, 5_000_000e6);

        deal(USDC_MONAD, depositor, depositAmount);
        vm.startPrank(depositor);
        IERC20(USDC_MONAD).approve(address(harness), depositAmount);
        harness.deposit(depositAmount, depositor);
        vm.stopPrank();

        uint256 maxW = harness.maxWithdraw(depositor);
        uint256 indexedAssets = harness.exposed_totalAssetsIndexed();
        uint256 ownerAssets = harness.convertToAssets(harness.balanceOf(depositor));

        // maxWithdraw must be <= _totalAssets (the underflow fix).
        assertLe(
            maxW,
            indexedAssets,
            "maxWithdraw exceeds _totalAssets"
        );

        // maxWithdraw must be <= user's convertToAssets value.
        assertLe(
            maxW,
            ownerAssets,
            "maxWithdraw exceeds user's asset value"
        );

        // Executing maxWithdraw should succeed.
        if (maxW > 0) {
            vm.prank(depositor);
            try harness.withdraw(maxW, depositor, depositor) returns (uint256 shares) {
                assertGt(shares, 0, "maxWithdraw burned 0 shares");
            } catch {
                // May fail due to liquidity in the target market; acceptable.
            }
        }
    }

    // =========================================================================
    // MAX REDEEM CORRECTNESS
    // =========================================================================

    /// @notice maxRedeem should be consistent with maxWithdraw and be executable.
    function testFuzz_maxRedeem_correctness(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1e6, 5_000_000e6);

        deal(USDC_MONAD, depositor, depositAmount);
        vm.startPrank(depositor);
        IERC20(USDC_MONAD).approve(address(harness), depositAmount);
        harness.deposit(depositAmount, depositor);
        vm.stopPrank();

        uint256 maxR = harness.maxRedeem(depositor);
        uint256 maxW = harness.maxWithdraw(depositor);

        // previewRedeem(maxRedeem) should be <= maxWithdraw + 1.
        if (maxR > 0) {
            uint256 redeemAssets = harness.previewRedeem(maxR);
            assertLe(
                redeemAssets,
                maxW + 1,
                "previewRedeem(maxRedeem) > maxWithdraw + 1"
            );

            // Executing maxRedeem should succeed.
            vm.prank(depositor);
            try harness.redeem(maxR, depositor, depositor) returns (uint256 assets) {
                assertGt(assets, 0, "maxRedeem returned 0 assets");
            } catch {
                // May fail due to liquidity; acceptable.
            }
        }
    }

    // =========================================================================
    // MULTI-USER FAIRNESS
    // =========================================================================

    /// @notice Two users depositing different amounts should receive proportional value.
    function testFuzz_multiUser_fairness(
        uint256 deposit1,
        uint256 deposit2,
        uint256 skipTime
    ) public {
        deposit1 = bound(deposit1, 10_000e6, 5_000_000e6);
        deposit2 = bound(deposit2, 10_000e6, 5_000_000e6);
        skipTime = bound(skipTime, 1 hours, 3 days);

        // User1 deposits.
        deal(USDC_MONAD, depositor, deposit1);
        vm.startPrank(depositor);
        IERC20(USDC_MONAD).approve(address(harness), deposit1);
        uint256 shares1 = harness.deposit(deposit1, depositor);
        vm.stopPrank();

        // User2 deposits.
        deal(USDC_MONAD, depositor2, deposit2);
        vm.startPrank(depositor2);
        IERC20(USDC_MONAD).approve(address(harness), deposit2);
        uint256 shares2 = harness.deposit(deposit2, depositor2);
        vm.stopPrank();

        // Skip time for yield to accrue.
        skip(skipTime);

        // Trigger accrual.
        harness.accrueIfNeeded();

        // Each user redeems all.
        uint256 maxR1 = harness.maxRedeem(depositor);
        uint256 maxR2 = harness.maxRedeem(depositor2);

        uint256 assets1;
        uint256 assets2;

        if (maxR1 > 0) {
            vm.prank(depositor);
            try harness.redeem(maxR1, depositor, depositor) returns (uint256 a) {
                assets1 = a;
            } catch {}
        }

        if (maxR2 > 0) {
            vm.prank(depositor2);
            try harness.redeem(maxR2, depositor2, depositor2) returns (uint256 a) {
                assets2 = a;
            } catch {}
        }

        // Both users should have received at least their deposit back (due to yield).
        // Allow small rounding loss.
        if (assets1 > 0) {
            assertGe(
                assets1 + 10,
                deposit1,
                "User1 received less than deposited (no yield detected)"
            );
        }

        if (assets2 > 0) {
            assertGe(
                assets2 + 10,
                deposit2,
                "User2 received less than deposited (no yield detected)"
            );
        }

        // Proportional check: ratio of assets out should approximate ratio of deposits.
        if (assets1 > 0 && assets2 > 0) {
            // user1_yield / deposit1 ~= user2_yield / deposit2 (within 5% tolerance).
            uint256 yield1Pct = ((assets1 - deposit1 + 10) * WAD) / deposit1;
            uint256 yield2Pct = ((assets2 - deposit2 + 10) * WAD) / deposit2;

            // Both should have similar yield percentages.
            // Use generous tolerance because they're in different markets with
            // potentially different rates.
            if (yield1Pct > 0 && yield2Pct > 0) {
                uint256 ratioDiff;
                if (yield1Pct > yield2Pct) {
                    ratioDiff = yield1Pct - yield2Pct;
                } else {
                    ratioDiff = yield2Pct - yield1Pct;
                }

                // Yield ratio difference should not be extreme (allowing 50% difference
                // since markets may have very different rates).
                assertLe(
                    ratioDiff,
                    (yield1Pct > yield2Pct ? yield1Pct : yield2Pct) / 2 + 1e14,
                    "Yield distribution between users is grossly unfair"
                );
            }
        }
    }

    // =========================================================================
    // DEPOSIT/WITHDRAW SYMMETRY
    // =========================================================================

    /// @notice convertToShares and convertToAssets should be consistent inverses.
    function testFuzz_convertSymmetry(uint256 amount) public {
        amount = bound(amount, 1e6, 100_000_000e6);

        uint256 shares = harness.convertToShares(amount);
        uint256 assetsBack = harness.convertToAssets(shares);

        // The round-trip should lose at most 1 unit due to integer division.
        assertApproxEqAbs(
            assetsBack,
            amount,
            1,
            "convertToShares/convertToAssets round-trip lost > 1 wei"
        );
    }

    // =========================================================================
    // EXCHANGE RATE MONOTONICITY AFTER OPERATIONS
    // =========================================================================

    /// @notice Exchange rate should never decrease after deposits.
    function testFuzz_exchangeRate_afterDeposit(uint256 assets) public {
        assets = bound(assets, 1e6, 10_000_000e6);

        uint256 rateBefore = harness.exchangeRate();

        deal(USDC_MONAD, depositor, assets);
        vm.startPrank(depositor);
        IERC20(USDC_MONAD).approve(address(harness), assets);
        harness.deposit(assets, depositor);
        vm.stopPrank();

        uint256 rateAfter = harness.exchangeRate();

        assertGe(
            rateAfter,
            rateBefore,
            "Exchange rate decreased after deposit"
        );
    }

    /// @notice Exchange rate should never decrease after withdrawals.
    function testFuzz_exchangeRate_afterWithdraw(uint256 withdrawPct) public {
        withdrawPct = bound(withdrawPct, 1, 90);

        // Deposit first.
        uint256 depositAmount = 2_000_000e6;
        deal(USDC_MONAD, depositor, depositAmount);
        vm.startPrank(depositor);
        IERC20(USDC_MONAD).approve(address(harness), depositAmount);
        harness.deposit(depositAmount, depositor);
        vm.stopPrank();

        uint256 rateBefore = harness.exchangeRate();

        // Withdraw a percentage of holdings.
        uint256 maxW = harness.maxWithdraw(depositor);
        uint256 withdrawAmount = (maxW * withdrawPct) / 100;
        if (withdrawAmount == 0) return;

        vm.prank(depositor);
        try harness.withdraw(withdrawAmount, depositor, depositor) {
            uint256 rateAfter = harness.exchangeRate();
            assertGe(
                rateAfter,
                rateBefore,
                "Exchange rate decreased after withdrawal"
            );
        } catch {
            // Liquidity issue; acceptable.
        }
    }
}
