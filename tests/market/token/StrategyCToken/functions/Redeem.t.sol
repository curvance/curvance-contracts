// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { ERC20 } from "contracts/libraries/external/ERC20.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract RedeemTest is TestBaseStrategyCToken {
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event CollateralUpdated(uint256 shares, bool increased, address account);

    function setUp() public override {
        super.setUp();
        
        deal(address(LP_wstETH_24Dec2025), user1, _ONE + _ONE);

        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE + _ONE);
        pendleStrategyCTokenSTETH.depositAsCollateral(_ONE + _ONE, user1);
        vm.stopPrank();
    }

    function test_strategyCTokenRedeem_fail_whenTransferIsDisabled() public {
        skip(20 minutes);

        vm.startPrank(user1);
        centralRegistry.setTransferableStatus(true);
        vm.stopPrank();

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        _redeemBalPendleStrategyCTokenSTETH(_ONE);
    }

    function test_strategyCTokenRedeem_fail_whenUser2Unauthorized() public {
        skip(20 minutes);

        vm.expectRevert(ERC20.InsufficientAllowance.selector);

        vm.startPrank(user2);
        pendleStrategyCTokenSTETH.redeem(_ONE, user1, user1);
        vm.stopPrank();
    }

    function test_strategyCTokenRedeem_fail_whenCooldownIsNotEnded() public {
        skip(20 minutes);

        vm.startPrank(user1);
        centralRegistry.setCooldown(10 days);
        centralRegistry.setCooldown(5 days);
        vm.stopPrank();

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);

        _redeemBalPendleStrategyCTokenSTETH(_ONE);
    }

    function test_strategyCTokenRedeem_fail_whenAmountIsZero() public {
        skip(20 minutes);

        vm.expectRevert(
            BaseCToken.BaseCToken__ZeroAmount.selector
        );

        _redeemBalPendleStrategyCTokenSTETH(0);
    }

    function test_strategyCTokenRedeem_fail_whenRedeemAmountExceedsCTokens() public {
        skip(20 minutes);

        vm.expectRevert(BaseCToken.BaseCToken__InsufficientLiquidity.selector);
        _redeemBalPendleStrategyCTokenSTETH(10e18);
    }

    function test_strategyCTokenRedeem_fail_whenCooldownActive() public {
        deal(address(LP_wstETH_24Dec2025), user1, _ONE + _ONE);

        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE + _ONE);
        pendleStrategyCTokenSTETH.depositAsCollateral(_ONE + _ONE, user1);
        vm.stopPrank();

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__MinimumHoldPeriod.selector
        );

        _redeemBalPendleStrategyCTokenSTETH(_ONE);
    }

    function test_strategyCTokenRedeem_fail_whenCollateralIsRequired() public {
        deal(address(dai), address(this), 2000e18);
        dai.approve(address(borrowableCDAI), 2000e18);
        borrowableCDAI.deposit(2000e18, address(this));

        deal(address(LP_wstETH_24Dec2025), user1, _ONE + _ONE);

        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE + _ONE);
        pendleStrategyCTokenSTETH.depositAsCollateral(_ONE + _ONE, user1);
        borrowableCDAI.borrow(1000e18, user1);
        vm.stopPrank();

        skip(20 minutes);

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral.selector
        );

        _redeemBalPendleStrategyCTokenSTETH(3.9e18);
    }

    function test_strategyCTokenRedeem_success() public {
        skip(20 minutes);

        uint256 underlyingBalance = LP_wstETH_24Dec2025.balanceOf(user1);
        uint256 balance = pendleStrategyCTokenSTETH.balanceOf(user1);
        uint256 totalSupply = pendleStrategyCTokenSTETH.totalSupply();
        uint256 collateralRedeemed = _ONE;

        vm.expectEmit(true, true, true, true, address(pendleStrategyCTokenSTETH));
        emit Transfer(user1, address(0), collateralRedeemed);
        uint256 assets = _redeemBalPendleStrategyCTokenSTETH(collateralRedeemed);

        assertEq(LP_wstETH_24Dec2025.balanceOf(user1), underlyingBalance + assets);
        assertEq(pendleStrategyCTokenSTETH.balanceOf(user1), balance - collateralRedeemed);
        assertEq(pendleStrategyCTokenSTETH.totalSupply(), totalSupply - collateralRedeemed);
    }

    function test_strategyCTokenRedeem_success_User2WithApproval() public {
        skip(20 minutes);

        uint256 underlyingBalance = LP_wstETH_24Dec2025.balanceOf(user1);
        uint256 balance = pendleStrategyCTokenSTETH.balanceOf(user1);
        uint256 totalSupply = pendleStrategyCTokenSTETH.totalSupply();
        uint256 collateralRedeemed = 0.5e18;

        vm.startPrank(user1);
        pendleStrategyCTokenSTETH.approve(user2, _ONE);
        vm.stopPrank();
        
        vm.startPrank(user2);
        uint256 assets = pendleStrategyCTokenSTETH.redeem(collateralRedeemed, user2, user1);
        vm.stopPrank();

        assertEq(LP_wstETH_24Dec2025.balanceOf(user2), underlyingBalance + assets);
        assertEq(pendleStrategyCTokenSTETH.balanceOf(user1), balance - collateralRedeemed);
        assertEq(pendleStrategyCTokenSTETH.totalSupply(), totalSupply - collateralRedeemed);
    }

    function test_strategyCTokenRedeem_success_User2WithMaxApproval() public {
        skip(20 minutes);

        uint256 underlyingBalance = LP_wstETH_24Dec2025.balanceOf(user1);
        uint256 balance = pendleStrategyCTokenSTETH.balanceOf(user1);
        uint256 totalSupply = pendleStrategyCTokenSTETH.totalSupply();
        uint256 collateralRedeemed = 0.5e18;

        vm.startPrank(user1);
        pendleStrategyCTokenSTETH.approve(user2, type(uint256).max);
        vm.stopPrank();
        
        vm.startPrank(user2);
        uint256 assets = pendleStrategyCTokenSTETH.redeem(collateralRedeemed, user2, user1);
        vm.stopPrank();

        assertEq(LP_wstETH_24Dec2025.balanceOf(user2), underlyingBalance + assets);
        assertEq(pendleStrategyCTokenSTETH.balanceOf(user1), balance - collateralRedeemed);
        assertEq(pendleStrategyCTokenSTETH.totalSupply(), totalSupply - collateralRedeemed);
        assertEq(pendleStrategyCTokenSTETH.allowance(user1, user2), type(uint256).max);
    }

    function test_strategyCTokenRedeem_success_redeemNonCollateralWhenCollateralIsInUse() public {
        uint256 newTokensDeposited = 2e18;
        uint256 tokensRedeemed = 2e18;
        uint256 collateralRedeemed = tokensRedeemed - newTokensDeposited; // This equals 0.

        _prepareDAI(address(this), 2000e18);
        dai.approve(address(borrowableCDAI), 2000e18);
        borrowableCDAI.deposit(2000e18, address(this));

        deal(address(LP_wstETH_24Dec2025), user1, newTokensDeposited * 2);

        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), newTokensDeposited * 2);
        pendleStrategyCTokenSTETH.depositAsCollateral(newTokensDeposited, user1);
        borrowableCDAI.borrow(1000e18, user1);
        pendleStrategyCTokenSTETH.deposit(newTokensDeposited, user1);
        vm.stopPrank();

        skip(20 minutes);

        uint256 underlyingBalance = LP_wstETH_24Dec2025.balanceOf(user1);
        uint256 balance = pendleStrategyCTokenSTETH.balanceOf(user1);
        uint256 totalSupply = pendleStrategyCTokenSTETH.totalSupply();
        uint256 collateral = pendleStrategyCTokenSTETH.collateralPosted(user1);
        uint256 totalCollateral = pendleStrategyCTokenSTETH.marketCollateralPosted();

        vm.expectEmit(true, true, true, true, address(pendleStrategyCTokenSTETH));
        emit Transfer(user1, address(0), tokensRedeemed);
        uint256 assets = _redeemBalPendleStrategyCTokenSTETH(tokensRedeemed);

        assertEq(LP_wstETH_24Dec2025.balanceOf(user1), underlyingBalance + assets);
        assertEq(pendleStrategyCTokenSTETH.balanceOf(user1), balance - tokensRedeemed);
        assertEq(pendleStrategyCTokenSTETH.totalSupply(), totalSupply - tokensRedeemed);
        assertEq(pendleStrategyCTokenSTETH.collateralPosted(user1), collateral - collateralRedeemed);
        assertEq(pendleStrategyCTokenSTETH.marketCollateralPosted(), totalCollateral - collateralRedeemed);
    }

    function test_strategyCTokenRedeem_success_redeemNonCollateralAndCollateralWhenCollateralIsInUse() public {
        uint256 newTokensDeposited = 2e18;
        uint256 tokensRedeemed = 2.5e18;
        uint256 collateralRedeemed = tokensRedeemed - newTokensDeposited;

        _prepareDAI(address(this), 2000e18);
        dai.approve(address(borrowableCDAI), 2000e18);
        borrowableCDAI.deposit(2000e18, address(this));

        deal(address(LP_wstETH_24Dec2025), user1, newTokensDeposited * 2);

        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), newTokensDeposited * 2);
        pendleStrategyCTokenSTETH.depositAsCollateral(newTokensDeposited, user1);
        borrowableCDAI.borrow(1000e18, user1);
        pendleStrategyCTokenSTETH.deposit(newTokensDeposited, user1);
        vm.stopPrank();

        skip(20 minutes);

        uint256 underlyingBalance = LP_wstETH_24Dec2025.balanceOf(user1);
        uint256 balance = pendleStrategyCTokenSTETH.balanceOf(user1);
        uint256 totalSupply = pendleStrategyCTokenSTETH.totalSupply();
        uint256 collateral = pendleStrategyCTokenSTETH.collateralPosted(user1);
        uint256 totalCollateral = pendleStrategyCTokenSTETH.marketCollateralPosted();

        vm.expectEmit(true, true, true, true, address(pendleStrategyCTokenSTETH));
        emit CollateralUpdated(collateralRedeemed, false, user1);
        uint256 assets = _redeemBalPendleStrategyCTokenSTETH(tokensRedeemed);

        assertEq(LP_wstETH_24Dec2025.balanceOf(user1), underlyingBalance + assets);
        assertEq(pendleStrategyCTokenSTETH.balanceOf(user1), balance - tokensRedeemed);
        assertEq(pendleStrategyCTokenSTETH.totalSupply(), totalSupply - tokensRedeemed);
        assertEq(pendleStrategyCTokenSTETH.collateralPosted(user1), collateral - collateralRedeemed);
        assertEq(pendleStrategyCTokenSTETH.marketCollateralPosted(), totalCollateral - collateralRedeemed);
    }

    function _redeemBalPendleStrategyCTokenSTETH(uint256 shares) internal returns (uint256 assets) {
        vm.startPrank(user1);
        assets = pendleStrategyCTokenSTETH.redeem(shares, user1, user1);
        vm.stopPrank();
    }
}
