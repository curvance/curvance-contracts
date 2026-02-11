// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { LendingOptimizerHarness } from "./LendingOptimizerHarness.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { SimpleCToken } from "contracts/market/token/SimpleCToken.sol";
import { DynamicIRM } from "contracts/market/DynamicIRM.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { WAD, BPS } from "contracts/libraries/ConstantsLib.sol";
import { console2 } from "forge-std/console2.sol";

/// @title Watermark Manipulation Tests for LendingOptimizer
/// @notice Verifies that a controller cannot manipulate the high watermark
///         by toggling the performance fee through zero during a drawdown,
///         which would allow double-charging depositors on the recovery.
contract TestWatermarkManipulation is TestBaseMarketIsolated {

    LendingOptimizerHarness optimizer;

    address depositor1 = makeAddr("depositor1");
    address borrower1 = makeAddr("borrower1");

    uint256 constant BASE_RESERVE = 77777;

    function setUp() public override {
        super.setUp();

        // List tokens and configure market.
        _prepareDAI(address(this), BASE_RESERVE);
        _prepareUSDC(address(this), BASE_RESERVE);
        dai.approve(address(borrowableCDAI), BASE_RESERVE);
        usdc.approve(address(borrowableCUSDC), BASE_RESERVE);
        marketManagerIsolated.listTokens(address(borrowableCDAI), address(borrowableCUSDC));

        // Set configs for DAI (collateral) and USDC (debt).
        _setCTokenConfigBasic(address(borrowableCDAI), 1_000_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);

        // Deploy optimizer with 10% performance fee.
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = address(borrowableCUSDC);

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        optimizer = new LendingOptimizerHarness(
            IERC20(_USDC_ADDRESS),
            ICentralRegistry(address(centralRegistry)),
            approvedCTokens,
            allocationCapsBps,
            1000 // 10% performance fee
        );

        // Initialize optimizer with dead shares.
        _prepareUSDC(address(this), BASE_RESERVE);
        usdc.approve(address(optimizer), BASE_RESERVE);
        optimizer.initializeDeposits(0);
    }

    /// @dev Creates a borrower with DAI collateral and USDC debt.
    function _setupBorrower(
        address borrower,
        uint256 collateralAmount,
        uint256 borrowAmount
    ) internal {
        deal(_DAI_ADDRESS, borrower, collateralAmount);
        vm.startPrank(borrower);
        dai.approve(address(borrowableCDAI), collateralAmount);
        ICToken(address(borrowableCDAI)).depositAsCollateral(collateralAmount, borrower);
        IBorrowableCToken(address(borrowableCUSDC)).borrow(borrowAmount, borrower);
        vm.stopPrank();
    }

    /// @dev Crashes DAI price and liquidates a borrower to create bad debt.
    function _causeBadDebt(address borrower) internal {
        mockDaiFeed.setMockAnswer(0.05e8);
        _refreshMockFeeds();

        skip(7 days);
        _refreshMockFeeds();

        address[] memory accounts = new address[](1);
        accounts[0] = borrower;

        _prepareUSDC(address(this), 100_000e6);
        usdc.approve(address(borrowableCUSDC), 100_000e6);
        borrowableCUSDC.liquidate(accounts, address(borrowableCDAI));
    }

    // ==================== CORE ATTACK SCENARIO ====================

    /// @notice Tests that the watermark cannot be lowered by toggling the fee
    ///         through zero during a drawdown.
    ///
    ///         Attack flow (without the fix):
    ///         1. Yield accrues from interest, watermark rises
    ///         2. Bad debt causes rate to drop below watermark
    ///         3. Controller sets fee to 0 (no fees since rate < watermark)
    ///         4. Controller sets fee back to 10% -> watermark RESETS to low rate
    ///         5. Rate recovers -> fees charged on recovery
    ///
    ///         With the fix, step 4 keeps watermark at the high since
    ///         exchangeRateHighWatermark only ever increases.
    function test_watermark_cannotBeLoweredByFeeToggleDuringDrawdown() public {
        // 1. Deposit assets into optimizer.
        uint256 depositAmount = 100_000e6;
        _prepareUSDC(depositor1, depositAmount);
        vm.startPrank(depositor1);
        usdc.approve(address(optimizer), depositAmount);
        optimizer.deposit(depositAmount, depositor1);
        vm.stopPrank();

        // 2. Create a borrower so interest accrues in the USDC market.
        _setupBorrower(borrower1, 100_000e18, 50_000e6);

        // 3. Skip time so interest accrues, raising the exchange rate.
        skip(60 days);
        _refreshMockFeeds();
        optimizer.exchangeRateUpdated();

        uint256 watermarkAfterYield = optimizer.exchangeRateHighWatermark();
        uint256 rateAfterYield = FixedPointMathLib.mulDiv(
            WAD, optimizer.totalAssets(), optimizer.totalSupply()
        );

        console2.log("Watermark after yield:", watermarkAfterYield);
        console2.log("Rate after yield:", rateAfterYield);

        // Sanity: watermark should have risen from interest income.
        assertGt(watermarkAfterYield, WAD, "Watermark should have risen from yield");

        // 4. Crash DAI and liquidate to create bad debt -> rate drops.
        _causeBadDebt(borrower1);
        optimizer.accrueIfNeeded();

        uint256 rateAfterBadDebt = FixedPointMathLib.mulDiv(
            WAD, optimizer.totalAssets(), optimizer.totalSupply()
        );
        uint256 watermarkAfterBadDebt = optimizer.exchangeRateHighWatermark();

        console2.log("Rate after bad debt:", rateAfterBadDebt);
        console2.log("Watermark after bad debt:", watermarkAfterBadDebt);

        // Rate should have dropped below watermark.
        assertLt(rateAfterBadDebt, watermarkAfterBadDebt, "Rate should be below watermark after drawdown");

        // 5. Controller attempts the attack: toggle fee 0 -> non-zero.
        optimizer.setFee(0);

        uint256 watermarkAfterFeeZero = optimizer.exchangeRateHighWatermark();
        assertEq(watermarkAfterFeeZero, watermarkAfterBadDebt, "Watermark should not change when setting fee to 0");

        optimizer.setFee(1000); // Re-enable at 10%.

        uint256 watermarkAfterReEnable = optimizer.exchangeRateHighWatermark();
        console2.log("Watermark after re-enable:", watermarkAfterReEnable);

        // THE KEY ASSERTION: Watermark must NOT have decreased.
        assertGe(
            watermarkAfterReEnable,
            watermarkAfterYield,
            "Watermark must not decrease after fee toggle during drawdown"
        );
        assertEq(
            watermarkAfterReEnable,
            watermarkAfterBadDebt,
            "Watermark should remain at the pre-drawdown high"
        );
    }

    /// @notice Tests that the watermark correctly moves UP when re-enabling
    ///         fees after the rate has risen above the old watermark.
    function test_watermark_movesUpWhenReEnablingFeesAboveWatermark() public {
        // Deposit assets.
        uint256 depositAmount = 100_000e6;
        _prepareUSDC(depositor1, depositAmount);
        vm.startPrank(depositor1);
        usdc.approve(address(optimizer), depositAmount);
        optimizer.deposit(depositAmount, depositor1);
        vm.stopPrank();

        // Create a borrower so interest accrues.
        _setupBorrower(borrower1, 100_000e18, 50_000e6);

        uint256 watermarkInitial = optimizer.exchangeRateHighWatermark();

        // Disable fees.
        optimizer.setFee(0);

        // Let yield accrue while fees are off.
        skip(60 days);
        _refreshMockFeeds();
        optimizer.accrueIfNeeded();

        uint256 rateAfterYield = FixedPointMathLib.mulDiv(
            WAD, optimizer.totalAssets(), optimizer.totalSupply()
        );

        console2.log("Initial watermark:", watermarkInitial);
        console2.log("Rate after yield (fees off):", rateAfterYield);

        // Rate should be above the initial watermark from interest income.
        assertGt(rateAfterYield, watermarkInitial, "Rate should exceed initial watermark after yield");

        // Re-enable fees.
        optimizer.setFee(1000);

        uint256 watermarkAfterReEnable = optimizer.exchangeRateHighWatermark();
        console2.log("Watermark after re-enable:", watermarkAfterReEnable);

        // Watermark should have moved up to the current rate.
        assertGt(
            watermarkAfterReEnable,
            watermarkInitial,
            "Watermark should increase when rate exceeds old watermark"
        );
        assertEq(
            watermarkAfterReEnable,
            rateAfterYield,
            "Watermark should equal current rate when re-enabling above old watermark"
        );
    }

    /// @notice Tests that repeated fee toggling cannot progressively
    ///         lower the watermark across multiple cycles.
    function test_watermark_resilientToRepeatedFeeToggling() public {
        // Deposit assets.
        uint256 depositAmount = 100_000e6;
        _prepareUSDC(depositor1, depositAmount);
        vm.startPrank(depositor1);
        usdc.approve(address(optimizer), depositAmount);
        optimizer.deposit(depositAmount, depositor1);
        vm.stopPrank();

        // Create a borrower so interest accrues.
        _setupBorrower(borrower1, 100_000e18, 50_000e6);

        // Let yield accrue.
        skip(30 days);
        _refreshMockFeeds();
        optimizer.exchangeRateUpdated();

        uint256 highWatermark = optimizer.exchangeRateHighWatermark();

        // Repeatedly toggle fee through zero.
        for (uint256 i; i < 5; ++i) {
            optimizer.setFee(0);
            optimizer.setFee(1000);

            uint256 currentWatermark = optimizer.exchangeRateHighWatermark();
            assertGe(
                currentWatermark,
                highWatermark,
                "Watermark must never decrease through fee toggling"
            );
        }
    }

    /// @notice Tests that no fee shares are minted during recovery back to
    ///         the old watermark after the attack is prevented.
    function test_watermark_noFeesChargedOnRecoveryAfterDrawdown() public {
        // Deposit assets.
        uint256 depositAmount = 100_000e6;
        _prepareUSDC(depositor1, depositAmount);
        vm.startPrank(depositor1);
        usdc.approve(address(optimizer), depositAmount);
        optimizer.deposit(depositAmount, depositor1);
        vm.stopPrank();

        // Create a borrower so interest accrues.
        _setupBorrower(borrower1, 100_000e18, 50_000e6);

        // Let yield accrue.
        skip(30 days);
        _refreshMockFeeds();
        optimizer.exchangeRateUpdated();

        uint256 watermarkBeforeDrawdown = optimizer.exchangeRateHighWatermark();
        assertGt(watermarkBeforeDrawdown, WAD, "Watermark should have risen");

        // Cause bad debt.
        _causeBadDebt(borrower1);
        optimizer.accrueIfNeeded();

        // Controller attempts the toggle attack.
        optimizer.setFee(0);
        optimizer.setFee(1000);

        // Watermark should still be at the pre-drawdown high.
        assertEq(
            optimizer.exchangeRateHighWatermark(),
            watermarkBeforeDrawdown,
            "Watermark should be preserved"
        );

        address dao = centralRegistry.daoAddress();
        uint256 daoSharesAfterToggle = optimizer.balanceOf(dao);

        // Simulate partial recovery (another borrower generates interest,
        // but not enough to exceed the old watermark).
        // Reset DAI price to normal for the recovery phase.
        mockDaiFeed.setMockAnswer(1e8);
        _refreshMockFeeds();

        address borrower2 = makeAddr("borrower2");
        _setupBorrower(borrower2, 50_000e18, 20_000e6);

        skip(30 days);
        _refreshMockFeeds();
        optimizer.exchangeRateUpdated();

        uint256 rateAfterRecovery = FixedPointMathLib.mulDiv(
            WAD, optimizer.totalAssets(), optimizer.totalSupply()
        );

        console2.log("Watermark:", watermarkBeforeDrawdown);
        console2.log("Rate after partial recovery:", rateAfterRecovery);

        // If rate is still below watermark, no fee shares should have been minted.
        if (rateAfterRecovery < watermarkBeforeDrawdown) {
            uint256 daoSharesAfterRecovery = optimizer.balanceOf(dao);
            assertEq(
                daoSharesAfterRecovery,
                daoSharesAfterToggle,
                "No fee shares should be minted while recovering below watermark"
            );
        }
    }
}
