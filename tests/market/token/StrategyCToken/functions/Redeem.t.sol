// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract RedeemTest is TestBaseStrategyCToken {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function setUp() public override {
        super.setUp();
        _prepareBALRETH(user1, _ONE + _ONE);

        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE + _ONE);
        strategyCBALRETH.depositAsCollateral(_ONE + _ONE, user1);
        vm.stopPrank();
    }

    function test_strategyCTokenRedeem_fail_whenTransferIsDisabled() public {
        centralRegistry.setTransferableStatus(true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        _redeemBalRETH(_ONE);
    }

    function test_strategyCTokenRedeem_fail_whenUser2Unauthorized() public {
        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);

        vm.startPrank(user2);
        strategyCBALRETH.redeem(_ONE, user1, user1);
        vm.stopPrank();
    }

    function test_strategyCTokenRedeem_fail_whenCooldownIsNotEnded() public {
        centralRegistry.setCooldown(10 days);
        centralRegistry.setCooldown(5 days);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);

        _redeemBalRETH(_ONE);
    }

    function test_strategyCTokenRedeem_fail_whenAmountIsZero() public {
        vm.expectRevert(
            BaseCToken.BaseCToken__ZeroAmount.selector
        );

        _redeemBalRETH(0);
    }

    function test_strategyCTokenRedeem_fail_whenRedeemAmountExceedsCTokens() public {
        vm.expectRevert(BaseCToken.BaseCToken__InsufficientLiquidity.selector);
        _redeemBalRETH(10e18);
    }

    function test_strategyCTokenRedeem_fail_whenCooldownActive() public {
        _prepareBALRETH(user1, _ONE + _ONE);

        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE + _ONE);
        strategyCBALRETH.depositAsCollateral(_ONE + _ONE, user1);
        vm.stopPrank();

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__MinimumHoldPeriod.selector
        );

        _redeemBalRETH(_ONE);
    }

    function test_strategyCTokenRedeem_fail_whenCollateralIsRequired() public {
        _prepareDAI(address(this), 2000e18);
        dai.approve(address(borrowableCDAI), 2000e18);
        borrowableCDAI.deposit(2000e18, address(this));

        _prepareBALRETH(user1, _ONE + _ONE);

        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE + _ONE);
        strategyCBALRETH.depositAsCollateral(_ONE + _ONE, user1);
        borrowableCDAI.borrow(1000e18, user1);
        vm.stopPrank();

        skip(20 minutes);

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral.selector
        );

        _redeemBalRETH(1.9e18);
    }

    function test_strategyCTokenRedeem_success() public {
        uint256 underlyingBalance = balRETH.balanceOf(user1);
        uint256 balance = strategyCBALRETH.balanceOf(user1);
        uint256 totalSupply = strategyCBALRETH.totalSupply();

        uint256 newCollateral = _ONE;

        vm.expectEmit(true, true, true, true, address(strategyCBALRETH));
        emit Transfer(user1, address(0), _ONE);

        uint256 assets = _redeemBalRETH(_ONE);

        assertEq(balRETH.balanceOf(user1), underlyingBalance + assets);
        assertEq(strategyCBALRETH.balanceOf(user1), balance - assets);
        assertEq(strategyCBALRETH.totalSupply(), totalSupply - assets);
    }

    function test_strategyCTokenRedeem_success_User2WithApproval() public {
        uint256 underlyingBalance = balRETH.balanceOf(user1);
        uint256 balance = strategyCBALRETH.balanceOf(user1);
        uint256 totalSupply = strategyCBALRETH.totalSupply();

        vm.startPrank(user1);
        borrowableCDAI.approve(user2, _ONE);
        vm.stopPrank();
        
        vm.startPrank(user2);
        emit Transfer(user1, address(0), 0.5e18);
        strategyCBALRETH.redeem(_ONE, user2, user1);
        vm.stopPrank();

        assertEq(balRETH.balanceOf(user2), underlyingBalance + assets);
        assertEq(strategyCBALRETH.balanceOf(user1), balance - assets);
        assertEq(strategyCBALRETH.totalSupply(), totalSupply - assets);
    }

    function test_strategyCTokenRedeem_success_whenCollateralIsInUse() public {
        _prepareDAI(address(this), 2000e18);
        dai.approve(address(borrowableCDAI), 2000e18);
        borrowableCDAI.deposit(2000e18, address(this));

        _prepareBALRETH(user1, _ONE + _ONE + _ONE);

        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE + _ONE);
        strategyCBALRETH.depositAsCollateral(_ONE + _ONE, user1);
        borrowableCDAI.borrow(1000e18, user1);
        strategyCBALRETH.deposit(_ONE + _ONE, user1);
        vm.stopPrank();

        emit Transfer(user1, address(0), 0.5e18);
        _redeemBalRETH(0.5e18);
    }

    function _redeemBalRETH(uint256 shares) internal returns (uint256 assets) {
        vm.startPrank(user1);
        assets = strategyCBALRETH.redeem(shares, user1, user1);
        vm.stopPrank();
    }
}
