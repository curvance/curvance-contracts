// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract CanRedeemWithCollateralRemovalTest is TestBaseMarketIsolated {
    event PositionUpdated(address cToken, address account, bool open);

    function setUp() public override {
        super.setUp();
        _prepareUSDC(address(this), _ONE + 77777);
        _prepareDAI(address(this), 10e18 + 77777);
        
        usdc.approve(address(borrowableCUSDC), _ONE + 77777);
        dai.approve(address(borrowableCDAI), 10e18 + 77777);

        marketManagerIsolated.listTokens(address(borrowableCDAI), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 100_000e18);
        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 100_000e6);
    }

    function test_canRedeemWithCollateralRemoval_fail_whenCallerIsNotCToken()
        public
    {
        vm.prank(user1);

        uint256 balance = borrowableCDAI.balanceOf(user1);
        uint256 collateral = borrowableCDAI.collateralPosted(user1);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        _canRedeemBorrowableCDAIWithCollateralRemoval(100e18, balance, collateral, false);
    }

    function test_canRedeem_fail_whenTokenNotListed() public {
        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        marketManagerIsolated.canRedeem(address(strategyCBALRETH), 100e6, user1);
    }

    function test_canRedeemWithCollateralRemoval_fail_whenRedeemIsDisabled()
        public
    {
        skip(20 minutes);

        centralRegistry.setTransferableStatus(true);

        uint256 balance = borrowableCDAI.balanceOf(user1);
        uint256 collateral = borrowableCDAI.collateralPosted(user1);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        _canRedeemBorrowableCDAIWithCollateralRemoval(100e18, balance, collateral, true);
    }

    function test_canRedeemWithCollateralRemoval_fail_whenCooldownIsNotEnded()
        public
    {
        skip(20 minutes);

        vm.startPrank(user1);
        centralRegistry.setCooldown(10 days);
        centralRegistry.setCooldown(5 days);
        vm.stopPrank();

        uint256 balance = borrowableCDAI.balanceOf(user1);
        uint256 collateral = borrowableCDAI.collateralPosted(user1);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);

        _canRedeemBorrowableCDAIWithCollateralRemoval(100e18, balance, collateral, true);
    }

    function test_canRedeemWithCollateralRemoval_fail_whenCooldownActive()
        public
    {
        _prepareDAI(user1, _ONE + _ONE);

        vm.startPrank(user1);
        dai.approve(address(borrowableCDAI), _ONE + _ONE);
        borrowableCDAI.depositAsCollateral(_ONE + _ONE, user1);
        vm.stopPrank();

        uint256 balance = borrowableCDAI.balanceOf(user1);
        uint256 collateral = borrowableCDAI.collateralPosted(user1);

        vm.startPrank(address(borrowableCDAI));

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__MinimumHoldPeriod.selector
        );

        _canRedeemBorrowableCDAIWithCollateralRemoval(100e18, balance, collateral, true);
    }

    function test_canRedeemWithCollateralRemoval_fail_whenCollateralIsRequired()
        public
    {
        _prepareUSDC(address(this), 2000e6);
        usdc.approve(address(borrowableCUSDC), 2000e6);
        borrowableCUSDC.deposit(2000e6, address(this));

        _prepareDAI(user1, 2000e18);

        vm.startPrank(user1);
        dai.approve(address(borrowableCDAI), 2000e18);
        borrowableCDAI.depositAsCollateral(2000e18, user1);
        borrowableCUSDC.borrow(1000e6, user1);
        vm.stopPrank();

        uint256 balance = borrowableCDAI.balanceOf(user1);
        uint256 collateral = borrowableCDAI.collateralPosted(user1);

        skip(20 minutes);

        vm.startPrank(address(borrowableCDAI));

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral.selector
        );

        _canRedeemBorrowableCDAIWithCollateralRemoval(1999e18, balance, collateral, true);
    }

    function test_canRedeemWithCollateralRemoval_success_withCollateralRemoved()
        public
    {
        uint256 collateralRedeemed = _ONE;

        skip(20 minutes);

        uint256 underlyingBalance = dai.balanceOf(user1);
        uint256 totalSupply = borrowableCDAI.totalSupply();
        uint256 totalCollateral = borrowableCDAI.marketCollateralPosted();
        uint256 balance = borrowableCDAI.balanceOf(user1);
        uint256 collateral = borrowableCDAI.collateralPosted(user1);

        vm.startPrank(address(borrowableCDAI));
        
        uint256 collateralToRemove = _canRedeemBorrowableCDAIWithCollateralRemoval(collateralRedeemed, balance, collateral, true);

        assertEq(dai.balanceOf(user1), underlyingBalance, "dai balance should not have changed");
        assertEq(borrowableCDAI.balanceOf(user1), balance, "borrowableCDAI balance should not have changed");
        assertEq(borrowableCDAI.totalSupply(), totalSupply, "borrowableCDAI totalSupply should not have changed");
        assertEq(borrowableCDAI.collateralPosted(user1), collateral, "borrowableCDAI collateral should not have changed");
        assertEq(borrowableCDAI.marketCollateralPosted(), totalCollateral, "borrowableCDAI market collateral should not have changed");
        assertEq(collateralToRemove, collateralRedeemed, "Expect to remove exactly collateralRedeemed");
    }

    function test_canRedeemWithCollateralRemoval_success_withNoCollateralRemoved()
        public
    {
        uint256 collateralRedeemed = _ONE;

        skip(20 minutes);

        uint256 underlyingBalance = dai.balanceOf(user1);
        uint256 totalSupply = borrowableCDAI.totalSupply();
        uint256 totalCollateral = borrowableCDAI.marketCollateralPosted();
        uint256 balance = borrowableCDAI.balanceOf(user1);
        uint256 collateral = borrowableCDAI.collateralPosted(user1);

        vm.startPrank(address(borrowableCDAI));
        
        uint256 collateralToRemove = _canRedeemBorrowableCDAIWithCollateralRemoval(collateralRedeemed, balance, collateral, false);

        assertEq(dai.balanceOf(user1), underlyingBalance, "dai balance should not have changed");
        assertEq(borrowableCDAI.balanceOf(user1), balance, "borrowableCDAI balance should not have changed");
        assertEq(borrowableCDAI.totalSupply(), totalSupply, "borrowableCDAI totalSupply should not have changed");
        assertEq(borrowableCDAI.collateralPosted(user1), collateral, "borrowableCDAI collateral should not have changed");
        assertEq(borrowableCDAI.marketCollateralPosted(), totalCollateral, "borrowableCDAI market collateral should not have changed");
        assertEq(collateralToRemove, 0, "Expect no collateral to be redeemed");
    }

    function test_canRedeemWithCollateralRemoval_success_removeCollateralWhenCollateralIsInUse()
        public
    {
        uint256 newTokensDeposited = 2000e18;
        uint256 tokensRedeemed = 1000e18;

        _prepareUSDC(address(this), 2000e6);
        usdc.approve(address(borrowableCUSDC), 2000e6);
        borrowableCUSDC.deposit(2000e6, address(this));

        _prepareDAI(user1, newTokensDeposited * 2);

        vm.startPrank(user1);
        dai.approve(address(borrowableCDAI), newTokensDeposited * 2);
        borrowableCDAI.depositAsCollateral(newTokensDeposited, user1);
        borrowableCUSDC.borrow(250e6, user1);
        borrowableCDAI.deposit(newTokensDeposited, user1);
        vm.stopPrank();

        skip(20 minutes);

        uint256 underlyingBalance = dai.balanceOf(user1);
        uint256 balance = borrowableCDAI.balanceOf(user1);
        uint256 totalSupply = borrowableCDAI.totalSupply();
        uint256 collateral = borrowableCDAI.collateralPosted(user1);
        uint256 totalCollateral = borrowableCDAI.marketCollateralPosted();

        vm.startPrank(address(borrowableCDAI));
        uint256 collateralRedeemed = _canRedeemBorrowableCDAIWithCollateralRemoval(tokensRedeemed, balance, collateral, true);

        assertEq(dai.balanceOf(user1), underlyingBalance, "dai balance should not have changed");
        assertEq(borrowableCDAI.balanceOf(user1), balance, "borrowableCDAI balance should not have changed");
        assertEq(borrowableCDAI.totalSupply(), totalSupply, "borrowableCDAI totalSupply should not have changed");
        assertEq(borrowableCDAI.collateralPosted(user1), collateral, "borrowableCDAI collateral should not have changed");
        assertEq(borrowableCDAI.marketCollateralPosted(), totalCollateral, "borrowableCDAI market collateral should not have changed");
        assertEq(tokensRedeemed, collateralRedeemed, "Expect to remove tokensRedeemed collateral");
        
    }

    // deposit 2000 dai as collateral
    // deposit 2000 dai as non-collateral
    function test_canRedeemWithCollateralRemoval_success_removeCollateralWhenCollateralNotIsInUse()
        public
    {
        uint256 newTokensDeposited = 2000e18;
        uint256 collateralRedeemed = newTokensDeposited * 2;

        _prepareDAI(user1, newTokensDeposited * 2);

        vm.startPrank(user1);
        dai.approve(address(borrowableCDAI), newTokensDeposited * 2);
        borrowableCDAI.depositAsCollateral(newTokensDeposited, user1);
        borrowableCDAI.deposit(newTokensDeposited, user1);
        vm.stopPrank();

        skip(20 minutes);

        uint256 underlyingBalance = dai.balanceOf(user1);
        uint256 balance = borrowableCDAI.balanceOf(user1);
        uint256 totalSupply = borrowableCDAI.totalSupply();
        uint256 collateral = borrowableCDAI.collateralPosted(user1);
        uint256 totalCollateral = borrowableCDAI.marketCollateralPosted();

        vm.startPrank(address(borrowableCDAI));
        vm.expectEmit(true, true, true, true, address(marketManagerIsolated));
        emit PositionUpdated(address(borrowableCDAI), user1, false);
        uint256 collateralToRemove = _canRedeemBorrowableCDAIWithCollateralRemoval(collateralRedeemed, balance, collateral, false);

        assertEq(dai.balanceOf(user1), underlyingBalance, "dai balance should not have changed");
        assertEq(borrowableCDAI.balanceOf(user1), balance, "borrowableCDAI balance should not have changed");
        assertEq(borrowableCDAI.totalSupply(), totalSupply, "borrowableCDAI totalSupply should not have changed");
        assertEq(collateralToRemove, collateralRedeemed, "borrowableCDAI collateral should not have changed");
        assertEq(borrowableCDAI.marketCollateralPosted(), totalCollateral, "borrowableCDAI market collateral should not have changed");
        assertEq(collateralToRemove, collateralRedeemed, "Expect to remove all collateral that was deposited");
    }

    function test_canRedeemWithCollateralRemoval_success_removeCollateralAndNotCollateralWhenCollateralNotIsInUse()
        public
    {
        uint256 newTokensDeposited = 2000e18;
        uint256 collateralRedeemed = newTokensDeposited;
        uint256 nonCollateralRedeemed = newTokensDeposited;
        uint256 totalRedemption = collateralRedeemed + nonCollateralRedeemed;

        _prepareDAI(user1, newTokensDeposited * 2);

        vm.startPrank(user1);
        dai.approve(address(borrowableCDAI), newTokensDeposited * 2);
        borrowableCDAI.depositAsCollateral(newTokensDeposited, user1);
        borrowableCDAI.deposit(newTokensDeposited, user1);
        vm.stopPrank();

        skip(20 minutes);

        uint256 underlyingBalance = dai.balanceOf(user1);
        uint256 balance = borrowableCDAI.balanceOf(user1);
        uint256 totalSupply = borrowableCDAI.totalSupply();
        uint256 collateral = borrowableCDAI.collateralPosted(user1);
        uint256 totalCollateral = borrowableCDAI.marketCollateralPosted();

        vm.startPrank(address(borrowableCDAI));
        vm.expectEmit(true, true, true, true, address(marketManagerIsolated));
        emit PositionUpdated(address(borrowableCDAI), user1, false);
        uint256 collateralToRemove = _canRedeemBorrowableCDAIWithCollateralRemoval(totalRedemption, balance, collateral, false);

        assertEq(dai.balanceOf(user1), underlyingBalance, "dai balance should not have changed");
        assertEq(borrowableCDAI.balanceOf(user1), balance, "borrowableCDAI balance should not have changed");
        assertEq(borrowableCDAI.totalSupply(), totalSupply, "borrowableCDAI totalSupply should not have changed");
        assertEq(borrowableCDAI.collateralPosted(user1), collateral, "borrowableCDAI collateral should not have changed");
        assertEq(borrowableCDAI.marketCollateralPosted(), totalCollateral, "borrowableCDAI market collateral should not have changed");
        assertEq(collateralToRemove, collateralRedeemed, "Expect to only remove collateralRedeemed not totalRedemption");
    }

    function _canRedeemBorrowableCDAIWithCollateralRemoval(
        uint256 shares,
        uint256 balance,
        uint256 collateral,
        bool forceRedeem
    ) internal returns (uint256 collateralRedeemed) {
        collateralRedeemed = marketManagerIsolated.canRedeemWithCollateralRemoval(
            address(borrowableCDAI),
            shares,
            user1,
            balance,
            collateral,
            forceRedeem
        );
    }
}
