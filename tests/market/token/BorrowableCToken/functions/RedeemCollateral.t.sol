// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseBorrowableCToken } from "../TestBaseBorrowableCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { ERC20 } from "contracts/libraries/external/ERC20.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract RedeemCollateralTest is TestBaseBorrowableCToken {
    event CollateralUpdated(uint256 shares, bool increased, address account);

    function setUp() public override {
        super.setUp();
        _prepareDAI(user1, 2000e18);

        vm.startPrank(user1);
        dai.approve(address(borrowableCDai), 2000e18);
        borrowableCDai.depositAsCollateral(2000e18, user1);
        vm.stopPrank();
    }

    function test_borrowableCTokenRedeemCollateral_fail_whenTransferIsDisabled() public {
        skip(20 minutes);

        vm.startPrank(user1);
        centralRegistry.setTransferableStatus(true);
        vm.stopPrank();

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        _redeemCollateralBorrowableCDai(_ONE);
    }

    function test_borrowableCTokenRedeemCollateral_fail_whenUser2Unauthorized() public {
        skip(20 minutes);

        vm.expectRevert(ERC20.InsufficientAllowance.selector);

        vm.startPrank(user2);
        borrowableCDai.redeem(_ONE, user1, user1);
        vm.stopPrank();
    }

    function test_borrowableCTokenRedeemCollateral_fail_whenCooldownIsNotEnded() public {
        skip(20 minutes);

        vm.startPrank(user1);
        centralRegistry.setCooldown(10 days);
        centralRegistry.setCooldown(5 days);
        vm.stopPrank();

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);

        _redeemCollateralBorrowableCDai(_ONE);
    }

    function test_borrowableCTokenRedeemCollateral_fail_whenAmountIsZero() public {
        skip(20 minutes);

        vm.expectRevert(
            BaseCToken.BaseCToken__ZeroAmount.selector
        );

        _redeemCollateralBorrowableCDai(0);
    }

    function test_borrowableCTokenRedeemCollateral_fail_whenRedeemAmountExceedsCTokens() public {
        skip(20 minutes);

        vm.expectRevert(BaseCToken.BaseCToken__InsufficientLiquidity.selector);
        _redeemCollateralBorrowableCDai(10000e18);
    }

    function test_borrowableCTokenRedeemCollateral_fail_whenCooldownActive() public {
        _prepareDAI(user1, _ONE + _ONE);

        vm.startPrank(user1);
        dai.approve(address(borrowableCDai), _ONE + _ONE);
        borrowableCDai.depositAsCollateral(_ONE + _ONE, user1);
        vm.stopPrank();

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__MinimumHoldPeriod.selector
        );

        _redeemCollateralBorrowableCDai(_ONE);
    }

    function test_borrowableCTokenRedeemCollateral_fail_whenCollateralIsRequired() public {
        _prepareUSDC(address(this), 2000e6);
        usdc.approve(address(borrowableCUSDC), 2000e6);
        borrowableCUSDC.deposit(2000e6, address(this));

        _prepareDAI(user1, 2000e18);

        vm.startPrank(user1);
        dai.approve(address(borrowableCDai), 2000e18);
        borrowableCDai.depositAsCollateral(2000e18, user1);
        borrowableCUSDC.borrow(1000e6, user1);
        vm.stopPrank();

        skip(20 minutes);

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral.selector
        );

        _redeemCollateralBorrowableCDai(3900e18);
    }

    function test_borrowableCTokenRedeemCollateral_success() public {
        skip(20 minutes);

        uint256 underlyingBalance = dai.balanceOf(user1);
        uint256 balance = borrowableCDai.balanceOf(user1);
        uint256 totalSupply = borrowableCDai.totalSupply();
        uint256 collateralRedeemed = _ONE;

        vm.expectEmit(true, true, true, true, address(borrowableCDai));
        emit CollateralUpdated(collateralRedeemed, false, user1);
        uint256 assets = _redeemCollateralBorrowableCDai(collateralRedeemed);

        assertEq(dai.balanceOf(user1), underlyingBalance + assets);
        assertEq(borrowableCDai.balanceOf(user1), balance - collateralRedeemed);
        assertEq(borrowableCDai.totalSupply(), totalSupply - collateralRedeemed);
    }

    function test_borrowableCTokenRedeemCollateral_success_User2WithApproval() public {
        skip(20 minutes);

        uint256 underlyingBalance = dai.balanceOf(user1);
        uint256 balance = borrowableCDai.balanceOf(user1);
        uint256 totalSupply = borrowableCDai.totalSupply();
        uint256 collateralRedeemed = _ONE;

        vm.startPrank(user1);
        borrowableCDai.approve(user2, collateralRedeemed);
        vm.stopPrank();
        
        vm.startPrank(user2);
        uint256 assets = borrowableCDai.redeem(collateralRedeemed, user2, user1);
        vm.stopPrank();

        assertEq(dai.balanceOf(user2), underlyingBalance + assets);
        assertEq(borrowableCDai.balanceOf(user1), balance - collateralRedeemed);
        assertEq(borrowableCDai.totalSupply(), totalSupply - collateralRedeemed);
    }

    function test_borrowableCTokenRedeemCollateral_success_whenCollateralIsInUse() public {
        uint256 newTokensDeposited = 2000e18;
        uint256 tokensRedeemed = 1000e18;

        _prepareUSDC(address(this), 2000e6);
        usdc.approve(address(borrowableCUSDC), 2000e6);
        borrowableCUSDC.deposit(2000e6, address(this));

        _prepareDAI(user1, newTokensDeposited * 2);

        vm.startPrank(user1);
        dai.approve(address(borrowableCDai), newTokensDeposited * 2);
        borrowableCDai.depositAsCollateral(newTokensDeposited, user1);
        borrowableCUSDC.borrow(1000e6, user1);
        borrowableCDai.deposit(newTokensDeposited, user1);
        vm.stopPrank();

        skip(20 minutes);

        uint256 underlyingBalance = dai.balanceOf(user1);
        uint256 balance = borrowableCDai.balanceOf(user1);
        uint256 totalSupply = borrowableCDai.totalSupply();
        uint256 collateral = borrowableCDai.collateralPosted(user1);
        uint256 totalCollateral = borrowableCDai.marketCollateralPosted();

        vm.expectEmit(true, true, true, true, address(borrowableCDai));
        emit CollateralUpdated(tokensRedeemed, false, user1);
        uint256 assets = _redeemCollateralBorrowableCDai(tokensRedeemed);

        assertEq(dai.balanceOf(user1), underlyingBalance + assets);
        assertEq(borrowableCDai.balanceOf(user1), balance - tokensRedeemed);
        assertEq(borrowableCDai.totalSupply(), totalSupply - tokensRedeemed);
        assertEq(borrowableCDai.collateralPosted(user1), collateral - tokensRedeemed);
        assertEq(borrowableCDai.marketCollateralPosted(), totalCollateral - tokensRedeemed);
    }

    function test_borrowableCTokenRedeemCollateral_success_whenCollateralNotIsInUse() public {
        uint256 newTokensDeposited = 2000e18;
        uint256 collateralRedeemed = newTokensDeposited * 2;

        _prepareDAI(user1, newTokensDeposited * 2);

        vm.startPrank(user1);
        dai.approve(address(borrowableCDai), newTokensDeposited * 2);
        borrowableCDai.depositAsCollateral(newTokensDeposited, user1);
        borrowableCDai.deposit(newTokensDeposited, user1);
        vm.stopPrank();

        skip(20 minutes);

        uint256 underlyingBalance = dai.balanceOf(user1);
        uint256 balance = borrowableCDai.balanceOf(user1);
        uint256 totalSupply = borrowableCDai.totalSupply();
        uint256 collateral = borrowableCDai.collateralPosted(user1);
        uint256 totalCollateral = borrowableCDai.marketCollateralPosted();

        vm.expectEmit(true, true, true, true, address(borrowableCDai));
        emit CollateralUpdated(collateralRedeemed, false, user1);
        uint256 assets = _redeemCollateralBorrowableCDai(collateralRedeemed);

        assertEq(dai.balanceOf(user1), underlyingBalance + assets);
        assertEq(borrowableCDai.balanceOf(user1), balance - collateralRedeemed);
        assertEq(borrowableCDai.totalSupply(), totalSupply - collateralRedeemed);
        assertEq(borrowableCDai.collateralPosted(user1), collateral - collateralRedeemed);
        assertEq(borrowableCDai.marketCollateralPosted(), totalCollateral - collateralRedeemed);
    }

    function _redeemCollateralBorrowableCDai(uint256 shares) internal returns (uint256 assets) {
        vm.startPrank(user1);
        assets = borrowableCDai.redeemCollateral(shares, user1, user1);
        vm.stopPrank();
    }
}
