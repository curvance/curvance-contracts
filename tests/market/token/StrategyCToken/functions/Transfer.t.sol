// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";


contract TransferTest is TestBaseStrategyCToken {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function setUp() public override {
        super.setUp();

        pendleStrategyCTokenSTETH.mint(100, address(this));
    }

    function test_strategyCTokenTransfer_fail_whenTransferZeroAmount()
        public
    {
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        pendleStrategyCTokenSTETH.transfer(user1, 0);
    }

    function test_strategyCTokenTransfer_fail_whenTransferIsNotAllowed()
        public
    {
        marketManagerIsolated.setTransferPaused(true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        pendleStrategyCTokenSTETH.transfer(user1, 1e18);
    }

    function test_strategyCTokenTransfer_fail_whenCollateralIsRequired() public {
        borrowableCDAI.deposit(1_000e18, address(this));
        deal(address(LP_wstETH_24Dec2025), user1, 150e18);

        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 150e18);
        uint256 collateralShares = pendleStrategyCTokenSTETH.deposit(100e18, user1);
        pendleStrategyCTokenSTETH.postCollateral(collateralShares);
        borrowableCDAI.borrow(50e18, user1);
        uint256 idleShares = pendleStrategyCTokenSTETH.deposit(50e18, user1);
        vm.stopPrank();

        skip(20 minutes);

        uint256 transferAmount = collateralShares + idleShares;
        uint256 ownerBalance = pendleStrategyCTokenSTETH.balanceOf(user1);
        uint256 receiverBalance = pendleStrategyCTokenSTETH.balanceOf(user2);
        uint256 collateral = pendleStrategyCTokenSTETH.collateralPosted(user1);
        uint256 totalCollateral = pendleStrategyCTokenSTETH.marketCollateralPosted();
        uint256 debt = borrowableCDAI.debtBalance(user1);

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral.selector
        );
        vm.prank(user1);
        pendleStrategyCTokenSTETH.transfer(user2, transferAmount);

        assertEq(pendleStrategyCTokenSTETH.balanceOf(user1), ownerBalance);
        assertEq(pendleStrategyCTokenSTETH.balanceOf(user2), receiverBalance);
        assertEq(pendleStrategyCTokenSTETH.collateralPosted(user1), collateral);
        assertEq(pendleStrategyCTokenSTETH.marketCollateralPosted(), totalCollateral);
        assertEq(borrowableCDAI.debtBalance(user1), debt);
    }

    function test_strategyCTokenTransfer_success() public {
        uint256 balance = pendleStrategyCTokenSTETH.balanceOf(address(this));
        uint256 user1Balance = pendleStrategyCTokenSTETH.balanceOf(user1);

        vm.expectEmit(true, true, true, true, address(pendleStrategyCTokenSTETH));
        emit Transfer(address(this), user1, 100);

        pendleStrategyCTokenSTETH.transfer(user1, 100);

        assertEq(pendleStrategyCTokenSTETH.balanceOf(address(this)), balance - 100);
        assertEq(pendleStrategyCTokenSTETH.balanceOf(user1), user1Balance + 100);
    }
}
