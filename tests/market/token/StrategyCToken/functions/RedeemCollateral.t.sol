// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { ERC20 } from "contracts/libraries/external/ERC20.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract RedeemTest is TestBaseStrategyCToken {
    event CollateralUpdated(uint256 shares, bool increased, address account);

    function setUp() public override {
        super.setUp();
        _prepareBALRETH(user1, _ONE + _ONE);

        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE + _ONE);
        strategyCBALRETH.depositAsCollateral(_ONE + _ONE, user1);
        vm.stopPrank();
    }

    function test_strategyCTokenRedeemCollateral_fail_whenTransferIsDisabled() public {
        skip(20 minutes);

        vm.startPrank(user1);
        centralRegistry.setTransferableStatus(true);
        vm.stopPrank();

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        _redeemCollateralBalRETH(_ONE);
    }

    function test_strategyCTokenRedeemCollateral_fail_whenUser2Unauthorized() public {
        skip(20 minutes);

        vm.expectRevert(ERC20.InsufficientAllowance.selector);

        vm.startPrank(user2);
        strategyCBALRETH.redeem(_ONE, user1, user1);
        vm.stopPrank();
    }

    function test_strategyCTokenRedeemCollateral_fail_whenCooldownIsNotEnded() public {
        skip(20 minutes);

        vm.startPrank(user1);
        centralRegistry.setCooldown(10 days);
        centralRegistry.setCooldown(5 days);
        vm.stopPrank();

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);

        _redeemCollateralBalRETH(_ONE);
    }

    function test_strategyCTokenRedeemCollateral_fail_whenAmountIsZero() public {
        skip(20 minutes);

        vm.expectRevert(
            BaseCToken.BaseCToken__ZeroAmount.selector
        );

        _redeemCollateralBalRETH(0);
    }

    function test_strategyCTokenRedeemCollateral_fail_whenRedeemAmountExceedsCTokens() public {
        skip(20 minutes);

        vm.expectRevert(BaseCToken.BaseCToken__InsufficientLiquidity.selector);
        _redeemCollateralBalRETH(10e18);
    }

    function test_strategyCTokenRedeemCollateral_fail_whenCooldownActive() public {
        _prepareBALRETH(user1, _ONE + _ONE);

        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE + _ONE);
        strategyCBALRETH.depositAsCollateral(_ONE + _ONE, user1);
        vm.stopPrank();

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__MinimumHoldPeriod.selector
        );

        _redeemCollateralBalRETH(_ONE);
    }

    function test_strategyCTokenRedeemCollateral_fail_whenCollateralIsRequired() public {
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

        _redeemCollateralBalRETH(3.9e18);
    }

    function test_strategyCTokenRedeemCollateral_success() public {
        skip(20 minutes);

        uint256 underlyingBalance = balRETH.balanceOf(user1);
        uint256 balance = strategyCBALRETH.balanceOf(user1);
        uint256 totalSupply = strategyCBALRETH.totalSupply();
        uint256 collateralRedeemed = _ONE;

        vm.expectEmit(true, true, true, true, address(strategyCBALRETH));
        emit CollateralUpdated(collateralRedeemed, false, user1);
        uint256 assets = _redeemCollateralBalRETH(collateralRedeemed);

        assertEq(balRETH.balanceOf(user1), underlyingBalance + assets);
        assertEq(strategyCBALRETH.balanceOf(user1), balance - collateralRedeemed);
        assertEq(strategyCBALRETH.totalSupply(), totalSupply - collateralRedeemed);
    }

    function test_strategyCTokenRedeemCollateral_success_User2WithApproval() public {
        skip(20 minutes);

        uint256 underlyingBalance = balRETH.balanceOf(user1);
        uint256 balance = strategyCBALRETH.balanceOf(user1);
        uint256 totalSupply = strategyCBALRETH.totalSupply();
        uint256 collateralRedeemed = 0.5e18;

        vm.startPrank(user1);
        strategyCBALRETH.approve(user2, _ONE);
        vm.stopPrank();
        
        vm.startPrank(user2);
        uint256 assets = strategyCBALRETH.redeem(collateralRedeemed, user2, user1);
        vm.stopPrank();

        assertEq(balRETH.balanceOf(user2), underlyingBalance + assets);
        assertEq(strategyCBALRETH.balanceOf(user1), balance - collateralRedeemed);
        assertEq(strategyCBALRETH.totalSupply(), totalSupply - collateralRedeemed);
    }

    function test_strategyCTokenRedeemCollateral_success_redeemCollateralWhenCollateralIsInUse() public {
        uint256 newTokensDeposited = 2e18;
        uint256 tokensRedeemed = 1e18;

        _prepareDAI(address(this), 2000e18);
        dai.approve(address(borrowableCDAI), 2000e18);
        borrowableCDAI.deposit(2000e18, address(this));

        _prepareBALRETH(user1, newTokensDeposited * 2);

        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), newTokensDeposited * 2);
        strategyCBALRETH.depositAsCollateral(newTokensDeposited, user1);
        borrowableCDAI.borrow(1000e18, user1);
        strategyCBALRETH.deposit(newTokensDeposited, user1);
        vm.stopPrank();

        skip(20 minutes);

        uint256 underlyingBalance = balRETH.balanceOf(user1);
        uint256 balance = strategyCBALRETH.balanceOf(user1);
        uint256 totalSupply = strategyCBALRETH.totalSupply();
        uint256 collateral = strategyCBALRETH.collateralPosted(user1);
        uint256 totalCollateral = strategyCBALRETH.marketCollateralPosted();

        vm.expectEmit(true, true, true, true, address(strategyCBALRETH));
        emit CollateralUpdated(tokensRedeemed, false, user1);
        uint256 assets = _redeemCollateralBalRETH(tokensRedeemed);

        assertEq(balRETH.balanceOf(user1), underlyingBalance + assets);
        assertEq(strategyCBALRETH.balanceOf(user1), balance - tokensRedeemed);
        assertEq(strategyCBALRETH.totalSupply(), totalSupply - tokensRedeemed);
        assertEq(strategyCBALRETH.collateralPosted(user1), collateral - tokensRedeemed);
        assertEq(strategyCBALRETH.marketCollateralPosted(), totalCollateral - tokensRedeemed);
    }

    function test_strategyCTokenRedeemCollateral_success_redeemNonCollateralAndCollateralWhenCollateralIsInUse() public {
        uint256 newTokensDeposited = 2e18;
        uint256 tokensRedeemed = 5e18;
        uint256 collateralRedeemed = 4e18;

        _prepareBALRETH(user1, newTokensDeposited * 2);

        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), newTokensDeposited * 2);
        strategyCBALRETH.depositAsCollateral(newTokensDeposited, user1);
        borrowableCDAI.borrow(1000e18, user1);
        strategyCBALRETH.deposit(newTokensDeposited, user1);
        vm.stopPrank();

        skip(20 minutes);

        uint256 underlyingBalance = balRETH.balanceOf(user1);
        uint256 balance = strategyCBALRETH.balanceOf(user1);
        uint256 totalSupply = strategyCBALRETH.totalSupply();
        uint256 collateral = strategyCBALRETH.collateralPosted(user1);
        uint256 totalCollateral = strategyCBALRETH.marketCollateralPosted();

        vm.expectEmit(true, true, true, true, address(strategyCBALRETH));
        emit CollateralUpdated(collateralRedeemed, false, user1);
        uint256 assets = _redeemCollateralBalRETH(tokensRedeemed);

        assertEq(balRETH.balanceOf(user1), underlyingBalance + assets);
        assertEq(strategyCBALRETH.balanceOf(user1), balance - tokensRedeemed);
        assertEq(strategyCBALRETH.totalSupply(), totalSupply - tokensRedeemed);
        assertEq(strategyCBALRETH.collateralPosted(user1), collateral - collateralRedeemed);
        assertEq(strategyCBALRETH.marketCollateralPosted(), totalCollateral - collateralRedeemed);
    }

    function _redeemCollateralBalRETH(uint256 shares) internal returns (uint256 assets) {
        vm.startPrank(user1);
        assets = strategyCBALRETH.redeemCollateral(shares, user1, user1);
        vm.stopPrank();
    }
}
