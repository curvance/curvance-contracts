// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseDToken } from "../TestBaseDToken.sol";
import { DToken } from "contracts/market/collateral/DToken.sol";

contract DTokenRepayTest is TestBaseDToken {
    event Repay(address payer, address borrower, uint256 repayAmount);

    function setUp() public override {
        super.setUp();

        _setCbalRETHCollateralCaps(100_000e18);

        deal(_USDC_ADDRESS, address(dUSDC), 2000e6);

        marketManager.postCollateral(
            address(this),
            address(cBALRETH),
            1e18 - 1
        );

        vm.prank(user1);
        dUSDC.mintFor(100e6, address(this));

        dUSDC.borrow(100e6);

        skip(20 minutes);
    }

    function test_dTokenRepay_fail_whenRepayIsNotAllowed() public {
        rewind(1);

        vm.expectRevert();
        dUSDC.repay(100e6);
    }

    function test_dTokenRepay_fail_whenBorrowAmountExceedsCash() public {
        dUSDC.accrueInterest();

        uint256 debtBalanceCached = dUSDC.debtBalanceCached(address(this));

        vm.expectRevert(DToken.DToken__ExcessiveValue.selector);
        dUSDC.repay(debtBalanceCached + 1);
    }

    function test_dTokenRepay_success() public {
        dUSDC.accrueInterest();

        uint256 underlyingBalance = usdc.balanceOf(address(this));
        uint256 balance = dUSDC.balanceOf(address(this));
        uint256 totalSupply = dUSDC.totalSupply();
        uint256 totalBorrows = dUSDC.totalBorrows();

        vm.expectEmit(true, true, true, true, address(dUSDC));
        emit Repay(address(this), address(this), 100e6);

        dUSDC.repay(100e6);

        assertEq(usdc.balanceOf(address(this)), underlyingBalance - 100e6);
        assertEq(dUSDC.balanceOf(address(this)), balance);
        assertEq(dUSDC.totalSupply(), totalSupply);
        assertEq(dUSDC.totalBorrows(), totalBorrows - 100e6);
    }

    function test_dTokenRepay_success_whenRepayAll() public {
        dUSDC.accrueInterest();

        uint256 debtBalanceCached = dUSDC.debtBalanceCached(address(this));
        uint256 underlyingBalance = usdc.balanceOf(address(this));
        uint256 balance = dUSDC.balanceOf(address(this));
        uint256 totalSupply = dUSDC.totalSupply();
        uint256 totalBorrows = dUSDC.totalBorrows();

        vm.expectEmit(true, true, true, true, address(dUSDC));
        emit Repay(address(this), address(this), debtBalanceCached);

        dUSDC.repay(0);

        assertEq(
            usdc.balanceOf(address(this)),
            underlyingBalance - debtBalanceCached
        );
        assertEq(dUSDC.balanceOf(address(this)), balance);
        assertEq(dUSDC.totalSupply(), totalSupply);
        assertEq(dUSDC.totalBorrows(), totalBorrows - debtBalanceCached);
    }

    function test_borrowers_repayAllDebts() public {
        uint256 _BASE_UNDERLYING_RESERVE = 42069;
        uint256 initialUsdcReserves = 1000e6;
        _setCbalRETHCollateralCaps(100_000e18);

        uint256 addUsdcAmount = 1500e6;
        dUSDC.mint(
            _BASE_UNDERLYING_RESERVE + initialUsdcReserves + addUsdcAmount
        );

        address user101 = address(101);
        address user102 = address(102);
        address user103 = address(103);
        address[] memory users = new address[](3);
        users[0] = user101;
        users[1] = user102;
        users[2] = user103;

        // 1. users post collateral and borrow 100 usdc
        for (uint i; i < 3; ++i) {
            address user = users[i];
            deal(address(cBALRETH), user, 1e18);
            vm.startPrank(user);
            marketManager.postCollateral(user, address(cBALRETH), 1e18 - 1);
            dUSDC.borrow(100e6);
            vm.stopPrank();
        }

        // 2. repay user101 and user102 all debt after two days
        skip(2 days);
        for (uint i; i < 2; ++i) {
            address user = users[i];
            vm.startPrank(user);
            // give users enough usdc to repay their debt because accumulated interest
            deal(_USDC_ADDRESS, user, 1000e6);
            usdc.approve(address(dUSDC), type(uint256).max);
            dUSDC.repay(0);
            vm.stopPrank();
        }

        // can be called by malicious users
        for (uint i; i < 2; ++i) {
            skip(1 days);
            dUSDC.accrueInterest();
        }

        deal(_USDC_ADDRESS, users[2], 1000e6);
        vm.startPrank(users[2]);
        usdc.approve(address(dUSDC), type(uint256).max);
        // 3. user103 repay all his debt would revert because overflow
        // vm.expectRevert();
        dUSDC.repay(0);
        vm.stopPrank();
    }
}
