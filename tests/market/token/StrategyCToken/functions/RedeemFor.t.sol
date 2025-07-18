// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract RedeemForTest is TestBaseStrategyCToken {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function setUp() public override {
        super.setUp();
        _prepareBALRETH(user1, _ONE + _ONE);

        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE + _ONE);
        strategyCBALRETH.depositAsCollateral(_ONE + _ONE, user1);

        // Approve delegated collateral removal for `user1` by `user2`.
        strategyCBALRETH.setDelegateApproval(user2, true);
        vm.stopPrank();
    }

    function test_strategyCTokenRedeemFor_fail_whenNotDelegated() public {
        vm.startPrank(user1);
        strategyCBALRETH.setDelegateApproval(user2, false);
        vm.stopPrank();

        skip(20 minutes);

        vm.expectRevert(PluginDelegable.PluginDelegable__Unauthorized.selector);
        _redeemBalRETHForUser1(_ONE);
    }

    function test_strategyCTokenRedeemFor_fail_whenTransferIsDisabled() public {
        skip(20 minutes);

        vm.startPrank(user1);
        centralRegistry.setTransferableStatus(true);
        vm.stopPrank();

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        _redeemBalRETHForUser1(_ONE);
    }

    function test_strategyCTokenRedeemFor_fail_whenCooldownIsNotEnded() public {
        skip(20 minutes);

        vm.startPrank(user1);
        centralRegistry.setCooldown(10 days);
        centralRegistry.setCooldown(5 days);
        vm.stopPrank();

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);

        _redeemBalRETHForUser1(_ONE);
    }

    function test_strategyCTokenRedeemFor_fail_whenAmountIsZero() public {
        skip(20 minutes);

        vm.expectRevert(
            BaseCToken.BaseCToken__ZeroAmount.selector
        );

        _redeemBalRETHForUser1(0);
    }

    function test_strategyCTokenRedeemFor_fail_whenRedeemAmountExceedsCTokens() public {
        vm.expectRevert(BaseCToken.BaseCToken__InsufficientLiquidity.selector);
        _redeemBalRETHForUser1(10e18);
    }

    function test_strategyCTokenRedeemFor_fail_whenCooldownActive() public {
        _prepareBALRETH(user1, _ONE + _ONE);

        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE + _ONE);
        strategyCBALRETH.depositAsCollateral(_ONE + _ONE, user1);
        vm.stopPrank();

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__MinimumHoldPeriod.selector
        );

        _redeemBalRETHForUser1(_ONE);
    }

    function test_strategyCTokenRedeemFor_fail_whenCollateralIsRequired() public {
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

        _redeemBalRETHForUser1(3.9e18);
    }

    function test_strategyCTokenRedeemFor_success() public {
        skip(20 minutes);

        uint256 underlyingBalance = balRETH.balanceOf(user1);
        uint256 balance = strategyCBALRETH.balanceOf(user1);
        uint256 totalSupply = strategyCBALRETH.totalSupply();
        uint256 collateralRedeemed = _ONE;

        vm.expectEmit(true, true, true, true, address(strategyCBALRETH));
        emit Transfer(user1, address(0), collateralRedeemed);
        uint256 assets = _redeemBalRETHForUser1(collateralRedeemed);

        assertEq(balRETH.balanceOf(user1), underlyingBalance + assets);
        assertEq(strategyCBALRETH.balanceOf(user1), balance - collateralRedeemed);
        assertEq(strategyCBALRETH.totalSupply(), totalSupply - collateralRedeemed);
    }

    function test_strategyCTokenRedeemFor_success_whenCollateralIsInUse() public {
        _prepareDAI(address(this), 2000e18);
        dai.approve(address(borrowableCDAI), 2000e18);
        borrowableCDAI.deposit(2000e18, address(this));

        _prepareBALRETH(user1, _ONE + _ONE + _ONE);

        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE + _ONE + _ONE);
        strategyCBALRETH.depositAsCollateral(_ONE + _ONE, user1);
        borrowableCDAI.borrow(1000e18, user1);
        strategyCBALRETH.deposit(_ONE, user1);
        vm.stopPrank();

        skip(20 minutes);

        uint256 underlyingBalance = balRETH.balanceOf(user1);
        uint256 balance = strategyCBALRETH.balanceOf(user1);
        uint256 totalSupply = strategyCBALRETH.totalSupply();
        uint256 collateralRedeemed = 0.5e18;

        vm.expectEmit(true, true, true, true, address(strategyCBALRETH));
        emit Transfer(user1, address(0), collateralRedeemed);
        uint256 assets = _redeemBalRETHForUser1(collateralRedeemed);

        assertEq(balRETH.balanceOf(user1), underlyingBalance + assets);
        assertEq(strategyCBALRETH.balanceOf(user1), balance - collateralRedeemed);
        assertEq(strategyCBALRETH.totalSupply(), totalSupply - collateralRedeemed);
    }

    function _redeemBalRETHForUser1(uint256 shares) internal returns (uint256 assets) {
        vm.startPrank(user2);
        assets = strategyCBALRETH.redeemFor(shares, user1, user1);
        vm.stopPrank();
    }
}
