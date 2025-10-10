// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

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
        marketManagerIsolated.canRedeemWithCollateralRemoval(
            address(pendleStrategyCTokenSTETH),
            0,
            user1,
            0,
            0,
            false
        );
    }

    function test_canRedeemWithCollateralRemoval_fail_whenRedeemIsDisabled()
        public
    {
        skip(20 minutes);

        borrowableCUSDC.accrueIfNeeded();

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
        borrowableCUSDC.accrueIfNeeded();

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

        borrowableCUSDC.accrueIfNeeded();

        vm.startPrank(address(borrowableCDAI));

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral.selector
        );

        _canRedeemBorrowableCDAIWithCollateralRemoval(1999e18, balance, collateral, true);
    }

    function test_canRedeemWithCollateralRemoval_success_withCollateralRemoved()
        public
    {
        uint256 tokensRedeemed = _ONE;

        skip(20 minutes);

        borrowableCUSDC.accrueIfNeeded();

        uint256 underlyingBalance = dai.balanceOf(user1);
        uint256 totalSupply = borrowableCDAI.totalSupply();
        uint256 totalCollateral = borrowableCDAI.marketCollateralPosted();
        uint256 balance = borrowableCDAI.balanceOf(user1);
        uint256 collateral = borrowableCDAI.collateralPosted(user1);

        vm.startPrank(address(borrowableCDAI));
        
        uint256 collateralRemoved = _canRedeemBorrowableCDAIWithCollateralRemoval(tokensRedeemed, balance, collateral, true);

        assertEq(dai.balanceOf(user1), underlyingBalance, "dai balance should not have changed");
        assertEq(borrowableCDAI.balanceOf(user1), balance, "borrowableCDAI balance should not have changed");
        assertEq(borrowableCDAI.totalSupply(), totalSupply, "borrowableCDAI totalSupply should not have changed");
        assertEq(borrowableCDAI.collateralPosted(user1), collateral, "borrowableCDAI collateral should not have changed");
        assertEq(borrowableCDAI.marketCollateralPosted(), totalCollateral, "borrowableCDAI market collateral should not have changed");
        assertEq(collateralRemoved, tokensRedeemed, "Expect to remove exactly tokensRedeemed");
    }

    function test_canRedeemWithCollateralRemoval_success_withNoCollateralRemoved()
        public
    {
        uint256 tokensRedeemed = _ONE;

        _prepareDAI(user1, _ONE + _ONE);

        vm.startPrank(user1);
        dai.approve(address(borrowableCDAI), _ONE + _ONE);
        borrowableCDAI.deposit(_ONE + _ONE, user1);
        vm.stopPrank();

        skip(20 minutes);

        borrowableCUSDC.accrueIfNeeded();

        uint256 underlyingBalance = dai.balanceOf(user1);
        uint256 totalSupply = borrowableCDAI.totalSupply();
        uint256 totalCollateral = borrowableCDAI.marketCollateralPosted();
        uint256 balance = borrowableCDAI.balanceOf(user1);
        uint256 collateral = borrowableCDAI.collateralPosted(user1);

        vm.startPrank(address(borrowableCDAI));
        
        uint256 collateralRemoved = _canRedeemBorrowableCDAIWithCollateralRemoval(tokensRedeemed, balance, collateral, false);

        assertEq(dai.balanceOf(user1), underlyingBalance, "dai balance should not have changed");
        assertEq(borrowableCDAI.balanceOf(user1), balance, "borrowableCDAI balance should not have changed");
        assertEq(borrowableCDAI.totalSupply(), totalSupply, "borrowableCDAI totalSupply should not have changed");
        assertEq(borrowableCDAI.collateralPosted(user1), collateral, "borrowableCDAI collateral should not have changed");
        assertEq(borrowableCDAI.marketCollateralPosted(), totalCollateral, "borrowableCDAI market collateral should not have changed");
        assertEq(collateralRemoved, 0, "Expect no collateral to be redeemed");
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

        borrowableCUSDC.accrueIfNeeded();

        uint256 underlyingBalance = dai.balanceOf(user1);
        uint256 balance = borrowableCDAI.balanceOf(user1);
        uint256 totalSupply = borrowableCDAI.totalSupply();
        uint256 collateral = borrowableCDAI.collateralPosted(user1);
        uint256 totalCollateral = borrowableCDAI.marketCollateralPosted();

        vm.startPrank(address(borrowableCDAI));
        uint256 collateralRemoved = _canRedeemBorrowableCDAIWithCollateralRemoval(tokensRedeemed, balance, collateral, true);

        assertEq(dai.balanceOf(user1), underlyingBalance, "dai balance should not have changed");
        assertEq(borrowableCDAI.balanceOf(user1), balance, "borrowableCDAI balance should not have changed");
        assertEq(borrowableCDAI.totalSupply(), totalSupply, "borrowableCDAI totalSupply should not have changed");
        assertEq(borrowableCDAI.collateralPosted(user1), collateral, "borrowableCDAI collateral should not have changed");
        assertEq(borrowableCDAI.marketCollateralPosted(), totalCollateral, "borrowableCDAI market collateral should not have changed");
        assertEq(collateralRemoved, tokensRedeemed, "Expect to remove tokensRedeemed collateral");
        
    }

    // deposit 2000 dai as collateral
    // deposit 2000 dai as non-collateral
    function test_canRedeemWithCollateralRemoval_success_removeCollateralWhenCollateralNotIsInUse()
        public
    {
        uint256 newTokensDeposited = 2000e18;
        uint256 tokensRedeemed = newTokensDeposited * 2;

        _prepareDAI(user1, newTokensDeposited * 2);

        vm.startPrank(user1);
        dai.approve(address(borrowableCDAI), newTokensDeposited * 2);
        borrowableCDAI.depositAsCollateral(newTokensDeposited, user1);
        borrowableCDAI.deposit(newTokensDeposited, user1);
        vm.stopPrank();

        skip(20 minutes);

        borrowableCUSDC.accrueIfNeeded();

        uint256 underlyingBalance = dai.balanceOf(user1);
        uint256 balance = borrowableCDAI.balanceOf(user1);
        uint256 totalSupply = borrowableCDAI.totalSupply();
        uint256 collateral = borrowableCDAI.collateralPosted(user1);
        uint256 totalCollateral = borrowableCDAI.marketCollateralPosted();

        vm.startPrank(address(borrowableCDAI));
        vm.expectEmit(true, true, true, true, address(marketManagerIsolated));
        emit PositionUpdated(address(borrowableCDAI), user1, false);
        uint256 collateralRemoved = _canRedeemBorrowableCDAIWithCollateralRemoval(tokensRedeemed, balance, collateral, false);

        assertEq(dai.balanceOf(user1), underlyingBalance, "dai balance should not have changed");
        assertEq(borrowableCDAI.balanceOf(user1), balance, "borrowableCDAI balance should not have changed");
        assertEq(borrowableCDAI.totalSupply(), totalSupply, "borrowableCDAI totalSupply should not have changed");
        assertEq(borrowableCDAI.collateralPosted(user1), collateral, "borrowableCDAI collateral should not have changed");
        assertEq(borrowableCDAI.marketCollateralPosted(), totalCollateral, "borrowableCDAI market collateral should not have changed");
        assertEq(collateralRemoved, newTokensDeposited, "Expect to remove all collateral that was deposited");
    }

    function test_canRedeemWithCollateralRemoval_success_removeCollateralAndNotCollateralWhenCollateralNotIsInUse()
        public
    {
        uint256 newTokensDeposited = 2000e18;
        uint256 collateralRedeemed = newTokensDeposited;
        uint256 nonCollateralRedeemed = newTokensDeposited;
        uint256 tokensRedeemed = collateralRedeemed + nonCollateralRedeemed;

        _prepareDAI(user1, newTokensDeposited * 2);

        vm.startPrank(user1);
        dai.approve(address(borrowableCDAI), newTokensDeposited * 2);
        borrowableCDAI.depositAsCollateral(newTokensDeposited, user1);
        borrowableCDAI.deposit(newTokensDeposited, user1);
        vm.stopPrank();

        skip(20 minutes);

        borrowableCUSDC.accrueIfNeeded();

        uint256 underlyingBalance = dai.balanceOf(user1);
        uint256 balance = borrowableCDAI.balanceOf(user1);
        uint256 totalSupply = borrowableCDAI.totalSupply();
        uint256 collateral = borrowableCDAI.collateralPosted(user1);
        uint256 totalCollateral = borrowableCDAI.marketCollateralPosted();

        vm.startPrank(address(borrowableCDAI));
        vm.expectEmit(true, true, true, true, address(marketManagerIsolated));
        emit PositionUpdated(address(borrowableCDAI), user1, false);
        uint256 collateralRemoved = _canRedeemBorrowableCDAIWithCollateralRemoval(tokensRedeemed, balance, collateral, false);

        assertEq(dai.balanceOf(user1), underlyingBalance, "dai balance should not have changed");
        assertEq(borrowableCDAI.balanceOf(user1), balance, "borrowableCDAI balance should not have changed");
        assertEq(borrowableCDAI.totalSupply(), totalSupply, "borrowableCDAI totalSupply should not have changed");
        assertEq(borrowableCDAI.collateralPosted(user1), collateral, "borrowableCDAI collateral should not have changed");
        assertEq(borrowableCDAI.marketCollateralPosted(), totalCollateral, "borrowableCDAI market collateral should not have changed");
        assertEq(collateralRemoved, collateralRedeemed, "Expect to only remove collateralRedeemed not tokensRedeemed");
    }

    function test_canRedeemWithCollateralRemoval_success_removeAllCollateral() public {
        // Step 1: User1 deposits 2000e6+1 USDC.
        uint user1DepositAmount = 2000e6+1;
        _prepareUSDC(user1, user1DepositAmount);
        vm.startPrank(user1);
        usdc.approve(address(borrowableCUSDC), user1DepositAmount);
        borrowableCUSDC.depositAsCollateral(user1DepositAmount, user1);
        vm.stopPrank();

        // Step 2: User2 deposits 2000e18 DAI (as collateral), then borrow 250e6 USDC.
        _prepareDAI(user2, 2000e18);
        vm.startPrank(user2);
        dai.approve(address(borrowableCDAI), 2000e18);
        borrowableCDAI.depositAsCollateral(2000e18, user2);
        borrowableCUSDC.borrow(250e6, user2);
        vm.stopPrank();

        // Step 3: Accrue interest.
        skip(30 minutes);
        borrowableCUSDC.accrueIfNeeded();

        // Step 4: User2 repays all USDC debt.
        _prepareUSDC(user2, 100000e6);
        vm.startPrank(user2);

        usdc.approve(address(borrowableCUSDC), 100000e6);
        borrowableCUSDC.repay(0);

        vm.stopPrank();

        // cUSDC exchange rate = 1000000160493755749

        assertEq(user1DepositAmount, borrowableCUSDC.collateralPosted(user1));

        // Step 5: User1 tries to remove all collateral, succeeds.
        vm.startPrank(user1);

        borrowableCUSDC.removeCollateral(user1DepositAmount);
        assertEq(0, borrowableCUSDC.collateralPosted(user1));
        
        vm.stopPrank();
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
