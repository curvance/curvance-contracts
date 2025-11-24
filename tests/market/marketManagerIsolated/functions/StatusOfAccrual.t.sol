// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";

contract StatusOfAccrualTest is TestBaseMarketIsolated {
    function setUp() public override {
        super.setUp();

        deal(_DAI_ADDRESS, address(this), 77777);
        deal(_USDC_ADDRESS, address(this), 77777);

        dai.approve(address(borrowableCDAI), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(borrowableCDAI), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(borrowableCDAI), 10_000_000e18, 10_000_000e18);
        _setCTokenConfigBasic(address(borrowableCUSDC), 10_000_000e6, 10_000_000e6);

        // Provide USDC liquidity
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 1_000_000e6);
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), type(uint256).max);
        borrowableCUSDC.deposit(1_000_000e6, liquidityProvider);
        vm.stopPrank();
    }

    function test_statusOf_reports_accrued_debt_without_manual_accrual_calls() public {

        // Create debt
        address borrower = makeAddr("borrower");
        _prepareDAI(borrower, 10_000e18);
        vm.startPrank(borrower);
        dai.approve(address(borrowableCDAI), 10_000e18);
        borrowableCDAI.depositAsCollateral(10_000e18, borrower);
        borrowableCUSDC.borrow(1_000e6, borrower);
        vm.stopPrank();

        // Capture initial status
        (, , uint256 initialDebtUsd) = marketManagerIsolated.statusOf(borrower);

        // skip so interest needs to accrue
        skip(69 days);
        _refreshMockFeeds();

        // Call statusOf again after time has passed
        (, , uint256 laterDebtUsd) = marketManagerIsolated.statusOf(borrower);

        // Debt should have increased
        assertGt(laterDebtUsd, initialDebtUsd, "statusOf must reflect accrued interest");
    }
}


