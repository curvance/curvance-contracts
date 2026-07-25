// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "./TestBaseLendingOptimizer.sol";
import { LendingOptimizerHarness } from "./LendingOptimizerHarness.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

/// @notice Demonstrates that the cToken's `withdraw()` rounding up shares
///         to burn causes the optimizer to lose 1 extra cToken share per
///         withdrawal. The optimizer overpays in cToken share value compared
///         to using `redeem()` (floor rounding).
contract CTokenRoundingLossTest is TestBaseLendingOptimizer {

    function setUp() public override {
        super.setUp();
    }

    /// @notice Core proof: show the cToken burns ⌈shares⌉ (ceil) when the
    ///         optimizer calls withdraw(assets), which is 1 more share than
    ///         the ⌊shares⌋ (floor) a redeem-based approach would use.
    function test_extra_share_burned_per_withdrawal() public {
        _deployOptimizer();
        _initAndDeposit();

        // Warp for non-1:1 cToken rate.
        vm.warp(block.timestamp + 30 days);
        optimizer.accrueIfNeeded();

        IBorrowableCToken cToken = IBorrowableCToken(cUSDC_WMON_MARKET);
        uint256 cTa = cToken.totalAssets();
        uint256 cSupply = cToken.totalSupply();

        // Find a withdrawal amount that triggers rounding.
        uint256 amount = _findRoundingAmount(cTa, cSupply);

        uint256 sharesFloor = FixedPointMathLib.fullMulDiv(amount, cSupply, cTa);
        uint256 sharesCeil = FixedPointMathLib.fullMulDivUp(amount, cSupply, cTa);

        emit log_named_uint("withdraw amount       ", amount);
        emit log_named_uint("cToken shares (floor) ", sharesFloor);
        emit log_named_uint("cToken shares (ceil)  ", sharesCeil);
        emit log_named_uint("extra shares burned   ", sharesCeil - sharesFloor);

        // Verify by doing the actual withdrawal and measuring balance change.
        uint256 balBefore = cToken.balanceOf(address(optimizer));

        address user = address(0xCAFE);
        vm.prank(user);
        optimizer.withdraw(amount, user, user);

        uint256 balAfter = cToken.balanceOf(address(optimizer));
        uint256 actualBurned = balBefore - balAfter;

        emit log_named_uint("actual shares burned  ", actualBurned);

        // The cToken burned the CEIL amount, which is 1 more than FLOOR.
        assertEq(actualBurned, sharesCeil, "cToken burned ceil shares");
        assertTrue(actualBurned > sharesFloor, "Optimizer lost 1 extra cToken share");
    }

    /// @notice Accumulate the extra share loss over many withdrawals.
    ///         Each withdrawal burns 1 extra cToken share. Over N withdrawals,
    ///         the optimizer holds N fewer shares than it would with floor rounding.
    function test_accumulated_extra_shares() public {
        _deployOptimizer();
        _initAndDeposit();

        vm.warp(block.timestamp + 30 days);
        optimizer.accrueIfNeeded();

        IBorrowableCToken cToken = IBorrowableCToken(cUSDC_WMON_MARKET);

        // Find rounding amount.
        uint256 amount = _findRoundingAmount(cToken.totalAssets(), cToken.totalSupply());

        uint256 balBefore = cToken.balanceOf(address(optimizer));
        uint256 numWithdrawals = 20;
        uint256 totalWithdrawn = 0;

        address user = address(0xCAFE);
        for (uint256 i = 0; i < numWithdrawals; i++) {
            vm.prank(user);
            optimizer.withdraw(amount, user, user);
            totalWithdrawn += amount;
        }

        uint256 balAfter = cToken.balanceOf(address(optimizer));
        uint256 totalSharesBurned = balBefore - balAfter;

        // What floor rounding would have burned (cumulative).
        // Note: cToken state changes after each withdrawal, so we approximate
        // by computing floor at the initial rate.
        // The key point: each withdrawal burns 1 extra share, so total excess ≈ N.
        uint256 cTa = cToken.totalAssets();
        uint256 cSupply = cToken.totalSupply();

        // Value of the excess shares at current rate.
        // Each excess share is worth cTa/cSupply ≈ 1.0001 assets.
        // N excess shares ≈ N * 1.0001 ≈ N assets of value leaked.
        emit log_named_uint("withdrawals done      ", numWithdrawals);
        emit log_named_uint("total assets withdrawn", totalWithdrawn);
        emit log_named_uint("total cToken shares burned", totalSharesBurned);
        emit log_named_uint("excess shares (~N extra)  ", totalSharesBurned - FixedPointMathLib.fullMulDiv(totalWithdrawn, cSupply, cTa));

        // The total burned must exceed what floor(totalWithdrawn * rate) would give.
        // This proves the optimizer lost extra cToken value.
        uint256 minBurnedIfFloor = FixedPointMathLib.fullMulDiv(totalWithdrawn, cSupply, cTa);
        assertTrue(totalSharesBurned > minBurnedIfFloor, "Optimizer lost extra cToken shares cumulatively");

        // Convert excess to asset value.
        uint256 excessShares = totalSharesBurned - minBurnedIfFloor;
        uint256 excessValue = FixedPointMathLib.fullMulDiv(excessShares, cTa, cSupply);
        emit log_named_uint("excess shares value (assets)", excessValue);
    }

    /// @notice Show the optimizer's exchange rate drops after a withdrawal
    ///         due to cToken rounding.
    ///
    ///   Two rounding layers compete:
    ///   - Optimizer level: previewWithdraw rounds UP shares → benefits remaining depositors
    ///   - cToken level: cToken.withdraw rounds UP shares to burn → hurts the pool
    ///
    ///   The cToken rounding loss = (cS - cBal) * (cA - r) / [cS * (cS - c)]
    ///   where cBal is the optimizer's cToken balance. When cBal/cS is small
    ///   (optimizer is a minor depositor in the cToken), the loss approaches
    ///   1 full cToken share, which can exceed the optimizer rounding benefit.
    ///
    ///   With a small deposit ($1k in a $500k cToken pool), the optimizer
    ///   holds ~0.2% of cToken shares, maximizing the rounding loss.
    function test_exchange_rate_drops() public {
        _deployOptimizer();

        // Use a small deposit so optimizer holds a tiny fraction of the cToken.
        // This maximizes the cToken rounding loss relative to optimizer benefit.
        _initAndDepositSmall();

        // Warp to build yield and get non-1:1 cToken rate.
        vm.warp(block.timestamp + 365 days);
        optimizer.accrueIfNeeded();

        // Record initial exchange rate in WAD.
        uint256 rateBefore = _exchangeRateWAD();

        emit log_named_uint("rate before (WAD)     ", rateBefore);
        emit log_named_uint("totalAssets before    ", optimizer.totalAssets());
        emit log_named_uint("totalSupply before    ", optimizer.totalSupply());

        IBorrowableCToken cToken = IBorrowableCToken(cUSDC_WMON_MARKET);
        uint256 optA = optimizer.totalAssets();
        uint256 optS = optimizer.totalSupply();
        uint256 cA = cToken.totalAssets();
        uint256 cS = cToken.totalSupply();
        uint256 cBal = cToken.balanceOf(address(optimizer));

        emit log_named_uint("cToken totalAssets    ", cA);
        emit log_named_uint("cToken totalSupply    ", cS);
        emit log_named_uint("optimizer cBal        ", cBal);
        emit log_named_uint("optimizer fraction (%)", cBal * 100 / cS);

        // Find amount where cToken rounding cost > optimizer rounding benefit.
        uint256 amount = _findRateDropAmount(optA, optS, cA, cS, cBal);

        emit log_named_uint("withdrawal amount     ", amount);

        // Show rounding at both levels.
        uint256 optFloor = FixedPointMathLib.fullMulDiv(amount, optS, optA);
        uint256 optCeil = FixedPointMathLib.fullMulDivUp(amount, optS, optA);
        uint256 ctFloor = FixedPointMathLib.fullMulDiv(amount, cS, cA);
        uint256 ctCeil = FixedPointMathLib.fullMulDivUp(amount, cS, cA);

        emit log_named_uint("opt shares (floor)    ", optFloor);
        emit log_named_uint("opt shares (ceil)     ", optCeil);
        emit log_named_uint("ct shares (floor)     ", ctFloor);
        emit log_named_uint("ct shares (ceil)      ", ctCeil);

        {
            address user = address(0xCAFE);
            uint256 previewShares = optimizer.previewWithdraw(amount);
            uint256 supplyBefore = optimizer.totalSupply();
            uint256 userAssetsBefore = IERC20(USDC_MONAD).balanceOf(user);

            // Do the withdrawal.
            vm.prank(user);
            uint256 actualShares = optimizer.withdraw(amount, user, user);

            emit log_named_uint("preview shares        ", previewShares);
            emit log_named_uint("actual shares burned  ", actualShares);

            assertEq(
                actualShares,
                previewShares + 1,
                "cToken rounding loss should exceed preview by one optimizer share"
            );
            assertEq(
                supplyBefore - optimizer.totalSupply(),
                actualShares,
                "returned shares should equal the optimizer supply delta"
            );
            assertEq(
                IERC20(USDC_MONAD).balanceOf(user) - userAssetsBefore,
                amount,
                "receiver should still receive the exact requested assets"
            );
        }

        // Re-sync to absorb cToken loss into _totalAssets.
        optimizer.accrueIfNeeded();

        uint256 rateAfter = _exchangeRateWAD();

        emit log_named_uint("rate after (WAD)      ", rateAfter);
        emit log_named_uint("totalAssets after     ", optimizer.totalAssets());
        emit log_named_uint("totalSupply after     ", optimizer.totalSupply());

        // With the new withdraw() implementation, the cToken rounding loss is
        // charged to the withdrawer by adding it to the shares burned. This
        // prevents the exchange rate from dropping. The rate should be preserved
        // or slightly increase (due to rounding loss accruing to the vault).
        assertGe(rateAfter, rateBefore, "Exchange rate should not drop with rounding loss charging");
    }

    function _exchangeRateWAD() internal view returns (uint256) {
        return FixedPointMathLib.fullMulDiv(1e18, optimizer.totalAssets(), optimizer.totalSupply());
    }

    // --- Helpers ---

    function _deployOptimizer() internal {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        uint256[] memory caps = new uint256[](1);
        caps[0] = 10_000;

        optimizer = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            caps,
            0 // 0% fee
        );

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(
                ICentralRegistry.hasMarketPermissions.selector,
                address(this)
            ),
            abi.encode(true)
        );
    }

    function _initAndDeposit() internal {
        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets);
        optimizer.initializeDeposits(cUSDC_WMON_MARKET);

        address user = address(0xCAFE);
        uint256 depositAmount = 500_000e6;
        deal(USDC_MONAD, user, depositAmount);
        vm.startPrank(user);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
        optimizer.deposit(depositAmount, user);
        vm.stopPrank();
    }

    function _initAndDepositSmall() internal {
        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets);
        optimizer.initializeDeposits(cUSDC_WMON_MARKET);

        // Small deposit: optimizer holds ~0.2% of the cToken pool.
        address user = address(0xCAFE);
        uint256 depositAmount = 1_000e6;
        deal(USDC_MONAD, user, depositAmount);
        vm.startPrank(user);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
        optimizer.deposit(depositAmount, user);
        vm.stopPrank();
    }

    function _findRoundingAmount(uint256 cTa, uint256 cSupply) internal pure returns (uint256) {
        for (uint256 amount = 100_000; amount <= 200_000; amount++) {
            if (FixedPointMathLib.fullMulDivUp(amount, cSupply, cTa) > FixedPointMathLib.fullMulDiv(amount, cSupply, cTa)) {
                return amount;
            }
        }
        revert("No rounding amount found");
    }

    /// @notice Find an amount where the cToken rounding cost exceeds the
    ///         optimizer rounding benefit, causing the exchange rate to drop.
    ///
    ///   Pre-filter with mulmod (cheap): skip amounts where cToken doesn't
    ///   round or where the optimizer's rounding benefit is too large.
    ///   Full simulation only for promising candidates.
    function _findRateDropAmount(
        uint256 optA, uint256 optS,
        uint256 cA, uint256 cS, uint256 cBal
    ) internal pure returns (uint256) {
        uint256 rateBefore = FixedPointMathLib.fullMulDiv(1e18, optA, optS);

        for (uint256 amount = 2; amount <= 50_000; amount++) {
            // cToken must round for there to be a loss.
            if (mulmod(amount, cS, cA) == 0) continue;

            uint256 optSharesCeil = FixedPointMathLib.fullMulDivUp(amount, optS, optA);
            uint256 ctCeil = FixedPointMathLib.fullMulDivUp(amount, cS, cA);

            uint256 newOptS = optS - optSharesCeil;
            if (newOptS == 0) continue;

            uint256 newCBal = cBal - ctCeil;
            uint256 newCA = cA - amount;
            uint256 newCS = cS - ctCeil;
            if (newCS == 0) continue;

            uint256 realAssets = FixedPointMathLib.fullMulDiv(newCBal, newCA, newCS);
            uint256 rateAfter = FixedPointMathLib.fullMulDiv(1e18, realAssets, newOptS);

            if (rateAfter < rateBefore) return amount;
        }
        revert("No rate-drop amount found in range");
    }
}
