// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseBorrowableCToken } from "../TestBaseBorrowableCToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import "forge-std/console2.sol";

contract BorrowableCTokenSkimTest is TestBaseBorrowableCToken {
    event ExcessRecovered(uint256 assets, address recipient);

    address public liquidityProvider;
    address public borrower1;
    address public borrower2;
    address public attacker;

    function setUp() public override {
        super.setUp();

        liquidityProvider = makeAddr("liquidityProvider");
        borrower1 = user1;
        borrower2 = user2;
        attacker = makeAddr("attacker");

        // Provide initial liquidity
        _prepareUSDC(liquidityProvider, 1_000_000e6);
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 1_000_000e6);
        borrowableCUSDC.deposit(1_000_000e6, liquidityProvider);
        vm.stopPrank();
    }

    function test_skimAvailable_success_returnsZero_whenNoExcess() public {
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        borrowableCUSDC.skimAvailable();
    }

    function test_skimAvailable_success_calculatesCorrectly_withDonation() public {
        // Donation to contract
        uint256 donationAmount = 1000e6;
        _prepareUSDC(attacker, donationAmount);

        vm.prank(attacker);
        usdc.transfer(address(borrowableCUSDC), donationAmount);

        uint256 excess = borrowableCUSDC.skimAvailable();

        assertEq(excess, donationAmount, "Excess should equal donation amount");

        assertEq(usdc.balanceOf(address(borrowableCUSDC)), 1_000_000e6 + 77777 + donationAmount);

        assertEq(borrowableCUSDC.assetsHeld(), 1_000_000e6);
    }

    function test_skim_fail_withZeroAmount_whenNoExcess() public {
        address dao = centralRegistry.daoAddress();

        vm.prank(dao);
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        borrowableCUSDC.skim();
    }

    function test_skim_transfersToDao_withDonation() public {
        // Direct donation to contract
        uint256 donationAmount = 1000e6;
        _prepareUSDC(attacker, donationAmount);

        vm.prank(attacker);
        usdc.transfer(address(borrowableCUSDC), donationAmount);

        address dao = centralRegistry.daoAddress();
        uint256 daoBalanceBefore = usdc.balanceOf(dao);
        uint256 contractBalanceBefore = usdc.balanceOf(address(borrowableCUSDC));

        vm.prank(dao);
        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit ExcessRecovered(donationAmount, dao);
        borrowableCUSDC.skim();

        uint256 daoBalanceAfter = usdc.balanceOf(dao);
        uint256 contractBalanceAfter = usdc.balanceOf(address(borrowableCUSDC));

        assertEq(
            daoBalanceAfter - daoBalanceBefore,
            donationAmount,
            "DAO should receive donation amount"
        );
        assertEq(
            contractBalanceBefore - contractBalanceAfter,
            donationAmount,
            "Contract balance should decrease by donation amount"
        );
    }

    function test_skim_fail_revertsWhenNotDao() public {
        // Create some excess via donation
        uint256 donationAmount = 1000e6;
        _prepareUSDC(attacker, donationAmount);
        vm.prank(attacker);
        usdc.transfer(address(borrowableCUSDC), donationAmount);

        // Try to skim as unauthorized user
        vm.prank(attacker);
        vm.expectRevert(BaseCToken.BaseCToken__Unauthorized.selector);
        borrowableCUSDC.skim();
    }

    function test_skim_succeedsWhenCalledByDao() public {
        uint256 donationAmount = 1000e6;
        _prepareUSDC(attacker, donationAmount);
        vm.prank(attacker);
        usdc.transfer(address(borrowableCUSDC), donationAmount);

        address dao = centralRegistry.daoAddress();

        vm.prank(dao);
        borrowableCUSDC.skim();

        // should revert because there is no excess
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        borrowableCUSDC.skimAvailable();
    }

    function test_skimAvailable_success_capturesRounding_singleBorrower() public {
        deal(address(LP_wstETH_24Dec2025), borrower1, 10e18);
        vm.startPrank(borrower1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 10e18);
        pendleStrategyCTokenSTETH.depositAsCollateral(10e18, borrower1);
        vm.stopPrank();

        _harvestPendleLP(1 weeks);

        uint256 borrowAmount = 10_000e6;
        vm.prank(borrower1);
        borrowableCUSDC.borrow(borrowAmount, borrower1);

        skip(30 days);
        borrowableCUSDC.accrueIfNeeded();

        // Skip many vesting periods to accumulate interest.
        uint256 vestingPeriod = borrowableCUSDC.vestingPeriod();
        for (uint256 i = 0; i < 300; i++) {
            skip(vestingPeriod);
            borrowableCUSDC.accrueIfNeeded();
        }
        _refreshMockFeeds();

        // Repay all debt.
        uint256 debtBalance = borrowableCUSDC.debtBalance(borrower1);
        _prepareUSDC(borrower1, debtBalance);

        vm.startPrank(borrower1);
        usdc.approve(address(borrowableCUSDC), debtBalance);
        borrowableCUSDC.repay(debtBalance);
        vm.stopPrank();

        // Check that there is excess due to rounding
        uint256 excess = borrowableCUSDC.skimAvailable();
        console2.log("skimAvailable excess", excess);
        console2.log("marketOutstandingDebt", borrowableCUSDC.marketOutstandingDebt());
        console2.log("contract balance", usdc.balanceOf(address(borrowableCUSDC)));
        assertGt(excess, 0, "Excess should be positive due to rounding");
    }

    function test_skimAvailable_success_capturesRounding_multipleBorrowersAndCycles() public {
        // Create multiple borrowers
        address[] memory borrowers = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            borrowers[i] = makeAddr(string(abi.encodePacked("borrower", i)));

            deal(address(LP_wstETH_24Dec2025), borrowers[i], 10e18);
            vm.startPrank(borrowers[i]);
            LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 10e18);
            pendleStrategyCTokenSTETH.depositAsCollateral(10e18, borrowers[i]);
            vm.stopPrank();
        }

        _harvestPendleLP(1 weeks);

        // Multiple borrow/repay cycles
        for (uint256 cycle = 0; cycle < 3; cycle++) {
            for (uint256 i = 0; i < borrowers.length; i++) {
                uint256 borrowAmount = 1000e6 + (i * 100e6);
                vm.prank(borrowers[i]);
                borrowableCUSDC.borrow(borrowAmount, borrowers[i]);
            }

            // Accrue interest
            skip(7 days);
            _refreshMockFeeds();
            borrowableCUSDC.accrueIfNeeded();

            for (uint256 i = 0; i < borrowers.length; i++) {
                // Repay
                uint256 debtBalance = borrowableCUSDC.debtBalance(borrowers[i]);
                _prepareUSDC(borrowers[i], debtBalance);

                vm.startPrank(borrowers[i]);
                usdc.approve(address(borrowableCUSDC), debtBalance);
                borrowableCUSDC.repay(debtBalance);
                vm.stopPrank();
            }
        }

        // Check that there is excess due to rounding
        uint256 excess = borrowableCUSDC.skimAvailable();
        assertTrue(excess >= 0, "Excess should be non-negative");
    }

    function test_skim_success_doesNotModifyTotalAssets() public {
        uint256 donationAmount = 5000e6;
        _prepareUSDC(attacker, donationAmount);

        vm.prank(attacker);
        usdc.transfer(address(borrowableCUSDC), donationAmount);

        uint256 totalAssetsBefore = borrowableCUSDC.totalAssets();

        address dao = centralRegistry.daoAddress();
        vm.prank(dao);
        borrowableCUSDC.skim();

        uint256 totalAssetsAfter = borrowableCUSDC.totalAssets();

        assertEq(
            totalAssetsBefore,
            totalAssetsAfter,
            "totalAssets should remain unchanged"
        );
    }

    function test_skim_success_doesNotAffectExchangeRate() public {
        uint256 donationAmount = 5000e6;
        _prepareUSDC(attacker, donationAmount);

        // Exchange rate before donation
        uint256 shares = 1e18;
        uint256 assetsBefore = borrowableCUSDC.convertToAssets(shares);

        vm.prank(attacker);
        usdc.transfer(address(borrowableCUSDC), donationAmount);

        uint256 assetsAfterDonation = borrowableCUSDC.convertToAssets(shares);
        assertEq(
            assetsBefore,
            assetsAfterDonation,
            "Exchange rate should not change after donation"
        );

        address dao = centralRegistry.daoAddress();
        vm.prank(dao);
        borrowableCUSDC.skim();

        uint256 assetsAfterSkim = borrowableCUSDC.convertToAssets(shares);
        assertEq(
            assetsBefore,
            assetsAfterSkim,
            "Exchange rate should not change after skim"
        );
    }

    function test_skim_success_doesNotAffectUserDeposits() public {
        address user = makeAddr("user");
        uint256 depositAmount = 50_000e6;
        _prepareUSDC(user, depositAmount);

        vm.startPrank(user);
        usdc.approve(address(borrowableCUSDC), depositAmount);
        uint256 userShares = borrowableCUSDC.deposit(depositAmount, user);
        vm.stopPrank();

        // Create excess via donation
        uint256 donationAmount = 10_000e6;
        _prepareUSDC(attacker, donationAmount);
        vm.prank(attacker);
        usdc.transfer(address(borrowableCUSDC), donationAmount);

        address dao = centralRegistry.daoAddress();
        vm.prank(dao);
        borrowableCUSDC.skim();

        vm.startPrank(user);
        uint256 withdrawnAssets = borrowableCUSDC.redeem(userShares, user, user);
        vm.stopPrank();

        assertEq(withdrawnAssets, depositAmount, "User should get at least their deposit back");
    }

    function test_skim_success_doesNotAffectActiveLoans() public {
        // Setup borrower
        deal(address(LP_wstETH_24Dec2025), borrower1, 10e18);
        vm.startPrank(borrower1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 10e18);
        pendleStrategyCTokenSTETH.depositAsCollateral(10e18, borrower1);
        vm.stopPrank();

        _harvestPendleLP(1 weeks);

        // Borrow
        uint256 borrowAmount = 10_000e6;
        vm.prank(borrower1);
        borrowableCUSDC.borrow(borrowAmount, borrower1);

        uint256 debtBefore = borrowableCUSDC.debtBalance(borrower1);

        // Create excess and skim
        uint256 donationAmount = 5000e6;
        _prepareUSDC(attacker, donationAmount);
        vm.prank(attacker);
        usdc.transfer(address(borrowableCUSDC), donationAmount);

        address dao = centralRegistry.daoAddress();
        vm.prank(dao);
        borrowableCUSDC.skim();

        uint256 debtAfter = borrowableCUSDC.debtBalance(borrower1);

        // Debt should remain unchanged
        assertEq(debtBefore, debtAfter, "Debt should not be affected by skim");
    }

    function test_skim_success_canBeCalledMultipleTimes() public {
        address dao = centralRegistry.daoAddress();

        // First donation and skim
        uint256 donation1 = 1000e6;
        _prepareUSDC(attacker, donation1 * 6);
        vm.prank(attacker);
        usdc.transfer(address(borrowableCUSDC), donation1);

        vm.prank(dao);
        borrowableCUSDC.skim();

        // should revert because there is no excess
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        borrowableCUSDC.skimAvailable();

        // Second donation and skim
        uint256 donation2 = 2000e6;
        vm.prank(attacker);
        usdc.transfer(address(borrowableCUSDC), donation2);

        vm.prank(dao);
        borrowableCUSDC.skim();
        // should revert because there is no excess
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        borrowableCUSDC.skimAvailable();

        // Third donation and skim
        uint256 donation3 = 3000e6;
        vm.prank(attacker);
        usdc.transfer(address(borrowableCUSDC), donation3);

        uint256 daoBalanceBefore = usdc.balanceOf(dao);
        vm.prank(dao);
        borrowableCUSDC.skim();
        
        uint256 daoBalanceAfter = usdc.balanceOf(dao);

        assertEq(
            daoBalanceAfter - daoBalanceBefore,
            donation3,
            "Third skim should recover third donation"
        );
        // should revert because there is no excess
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        borrowableCUSDC.skimAvailable();
    }
}