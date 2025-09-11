// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { ERC20 } from "contracts/libraries/external/ERC20.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract RedeemCollateralTest is TestBaseStrategyCToken {
    event CollateralUpdated(uint256 shares, bool increased, address account);

    function setUp() public override {
        super.setUp();
        
        deal(address(LP_wstETH_24Dec2025), user1, _ONE + _ONE);

        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE + _ONE);
        pendleStrategyCTokenSTETH.depositAsCollateral(_ONE + _ONE, user1);
        vm.stopPrank();
    }

    function test_strategyCTokenRedeemCollateral_fail_whenTransferIsDisabled() public {
        skip(20 minutes);

        vm.startPrank(user1);
        centralRegistry.setTransferableStatus(true);
        vm.stopPrank();

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        _redeemCollateralBalPendleStrategyCTokenSTETH(_ONE);
    }

    function test_strategyCTokenRedeemCollateral_fail_whenUser2Unauthorized() public {
        skip(20 minutes);

        vm.expectRevert(ERC20.InsufficientAllowance.selector);

        vm.startPrank(user2);
        pendleStrategyCTokenSTETH.redeem(_ONE, user1, user1);
        vm.stopPrank();
    }

    function test_strategyCTokenRedeemCollateral_fail_whenCooldownIsNotEnded() public {
        skip(20 minutes);

        vm.startPrank(user1);
        centralRegistry.setCooldown(10 days);
        centralRegistry.setCooldown(5 days);
        vm.stopPrank();

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);

        _redeemCollateralBalPendleStrategyCTokenSTETH(_ONE);
    }

    function test_strategyCTokenRedeemCollateral_fail_whenAmountIsZero() public {
        skip(20 minutes);

        vm.expectRevert(
            BaseCToken.BaseCToken__ZeroAmount.selector
        );

        _redeemCollateralBalPendleStrategyCTokenSTETH(0);
    }

    function test_strategyCTokenRedeemCollateral_fail_whenRedeemAmountExceedsCTokens() public {
        skip(20 minutes);

        vm.expectRevert(BaseCToken.BaseCToken__InsufficientLiquidity.selector);
        _redeemCollateralBalPendleStrategyCTokenSTETH(10e18);
    }

    function test_strategyCTokenRedeemCollateral_fail_whenCooldownActive() public {
        deal(address(LP_wstETH_24Dec2025), user1, _ONE + _ONE);

        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE + _ONE);
        pendleStrategyCTokenSTETH.depositAsCollateral(_ONE + _ONE, user1);
        vm.stopPrank();

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__MinimumHoldPeriod.selector
        );

        _redeemCollateralBalPendleStrategyCTokenSTETH(_ONE);
    }

    function test_strategyCTokenRedeemCollateral_fail_whenCollateralIsRequired() public {
        _prepareDAI(address(this), 2000e18);
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

        _redeemCollateralBalPendleStrategyCTokenSTETH(3.9e18);
    }

    function test_strategyCTokenRedeemCollateral_success() public {
        skip(20 minutes);

        uint256 underlyingBalance = LP_wstETH_24Dec2025.balanceOf(user1);
        uint256 balance = pendleStrategyCTokenSTETH.balanceOf(user1);
        uint256 totalSupply = pendleStrategyCTokenSTETH.totalSupply();
        uint256 collateralRedeemed = _ONE;

        vm.expectEmit(true, true, true, true, address(pendleStrategyCTokenSTETH));
        emit CollateralUpdated(collateralRedeemed, false, user1);
        uint256 assets = _redeemCollateralBalPendleStrategyCTokenSTETH(collateralRedeemed);

        assertEq(LP_wstETH_24Dec2025.balanceOf(user1), underlyingBalance + assets);
        assertEq(pendleStrategyCTokenSTETH.balanceOf(user1), balance - collateralRedeemed);
        assertEq(pendleStrategyCTokenSTETH.totalSupply(), totalSupply - collateralRedeemed);
    }

    function test_strategyCTokenRedeemCollateral_success_User2WithApproval() public {
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

    function test_strategyCTokenRedeemCollateral_success_whenCollateralIsInUse() public {
        uint256 newTokensDeposited = 2e18;
        uint256 tokensRedeemed = 1e18;

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
        emit CollateralUpdated(tokensRedeemed, false, user1);
        uint256 assets = _redeemCollateralBalPendleStrategyCTokenSTETH(tokensRedeemed);

        assertEq(LP_wstETH_24Dec2025.balanceOf(user1), underlyingBalance + assets);
        assertEq(pendleStrategyCTokenSTETH.balanceOf(user1), balance - tokensRedeemed);
        assertEq(pendleStrategyCTokenSTETH.totalSupply(), totalSupply - tokensRedeemed);
        assertEq(pendleStrategyCTokenSTETH.collateralPosted(user1), collateral - tokensRedeemed);
        assertEq(pendleStrategyCTokenSTETH.marketCollateralPosted(), totalCollateral - tokensRedeemed);
    }

    function test_strategyCTokenRedeemCollateral_success_whenCollateralNotIsInUse() public {
        uint256 newTokensDeposited = 2e18;
        uint256 collateralRedeemed = newTokensDeposited * 2;

        deal(address(LP_wstETH_24Dec2025), user1, newTokensDeposited * 2);

        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), newTokensDeposited * 2);
        pendleStrategyCTokenSTETH.depositAsCollateral(newTokensDeposited, user1);
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
        uint256 assets = _redeemCollateralBalPendleStrategyCTokenSTETH(collateralRedeemed);

        assertEq(LP_wstETH_24Dec2025.balanceOf(user1), underlyingBalance + assets);
        assertEq(pendleStrategyCTokenSTETH.balanceOf(user1), balance - collateralRedeemed);
        assertEq(pendleStrategyCTokenSTETH.totalSupply(), totalSupply - collateralRedeemed);
        assertEq(pendleStrategyCTokenSTETH.collateralPosted(user1), collateral - collateralRedeemed);
        assertEq(pendleStrategyCTokenSTETH.marketCollateralPosted(), totalCollateral - collateralRedeemed);
    }

    function _redeemCollateralBalPendleStrategyCTokenSTETH(uint256 shares) internal returns (uint256 assets) {
        vm.startPrank(user1);
        assets = pendleStrategyCTokenSTETH.redeemCollateral(shares, user1, user1);
        vm.stopPrank();
    }
}
