// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { ERC20 } from "contracts/libraries/external/ERC20.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract WithdrawCollateralTest is TestBaseMarketIsolated {
    event CollateralUpdated(uint256 shares, bool increased, address account);

    function setUp() public override {
        super.setUp();
        
        _prepareUSDC(address(this), _ONE + 77777);
        _prepareDAI(address(this), 10e18 + 77777);
        
        usdc.approve(address(borrowableCUSDC), _ONE + 77777);
        dai.approve(address(borrowableCDAI), 10e18 + 77777);

        marketManagerIsolated.listTokens(address(borrowableCDAI), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 100_000e18);
        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 100_000e6);

        borrowableCDAI.mint(_ONE, address(this));

        _prepareDAI(user1, 2000e18);

        vm.startPrank(user1);
        dai.approve(address(borrowableCDAI), 2000e18);
        borrowableCDAI.depositAsCollateral(2000e18, user1);
        vm.stopPrank();
    }

    function test_borrowableCTokenWithdrawCollateral_fail_whenTransferIsDisabled() public {
        skip(20 minutes);

        vm.startPrank(user1);
        centralRegistry.setTransferableStatus(true);
        vm.stopPrank();

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        _withdrawCollateralBorrowableCDai(_ONE);
    }

    function test_borrowableCTokenWithdrawCollateral_fail_whenUser2Unauthorized() public {
        skip(20 minutes);

        vm.expectRevert(ERC20.InsufficientAllowance.selector);

        vm.startPrank(user2);
        borrowableCDAI.redeem(_ONE, user1, user1);
        vm.stopPrank();
    }

    function test_borrowableCTokenWithdrawCollateral_fail_whenCooldownIsNotEnded() public {
        skip(20 minutes);

        vm.startPrank(user1);
        centralRegistry.setCooldown(10 days);
        centralRegistry.setCooldown(5 days);
        vm.stopPrank();

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);

        _withdrawCollateralBorrowableCDai(_ONE);
    }

    function test_borrowableCTokenWithdrawCollateral_fail_whenAmountIsZero() public {
        skip(20 minutes);

        vm.expectRevert(
            BaseCToken.BaseCToken__ZeroAmount.selector
        );

        _withdrawCollateralBorrowableCDai(0);
    }

    function test_borrowableCTokenWithdrawCollateral_fail_whenRedeemAmountExceedsCTokens() public {
        skip(20 minutes);

        vm.expectRevert(BaseCToken.BaseCToken__InsufficientLiquidity.selector);
        _withdrawCollateralBorrowableCDai(10000e18);
    }

    function test_borrowableCTokenWithdrawCollateral_fail_whenCooldownActive() public {
        _prepareDAI(user1, _ONE + _ONE);

        vm.startPrank(user1);
        dai.approve(address(borrowableCDAI), _ONE + _ONE);
        borrowableCDAI.depositAsCollateral(_ONE + _ONE, user1);
        vm.stopPrank();

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__MinimumHoldPeriod.selector
        );

        _withdrawCollateralBorrowableCDai(_ONE);
    }

    function test_borrowableCTokenWithdrawCollateral_fail_whenCollateralIsRequired() public {
        _prepareUSDC(address(this), 2000e6);
        usdc.approve(address(borrowableCUSDC), 2000e6);
        borrowableCUSDC.deposit(2000e6, address(this));

        _prepareDAI(user1, 2000e18);

        vm.startPrank(user1);
        dai.approve(address(borrowableCDAI), 2000e18);
        borrowableCDAI.depositAsCollateral(2000e18, user1);
        borrowableCUSDC.borrow(1000e6, user1);
        vm.stopPrank();

        skip(20 minutes);

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral.selector
        );

        _withdrawCollateralBorrowableCDai(3900e18);
    }

    function test_borrowableCTokenWithdrawCollateral_success() public {
        skip(20 minutes);

        uint256 underlyingBalance = dai.balanceOf(user1);
        uint256 balance = borrowableCDAI.balanceOf(user1);
        uint256 totalSupply = borrowableCDAI.totalSupply();
        uint256 collateralRedeemed = _ONE;

        vm.expectEmit(true, true, true, true, address(borrowableCDAI));
        emit CollateralUpdated(collateralRedeemed, false, user1);
        uint256 assets = _withdrawCollateralBorrowableCDai(collateralRedeemed);

        assertEq(dai.balanceOf(user1), underlyingBalance + assets);
        assertEq(borrowableCDAI.balanceOf(user1), balance - collateralRedeemed);
        assertEq(borrowableCDAI.totalSupply(), totalSupply - collateralRedeemed);
    }

    function test_borrowableCTokenWithdrawCollateral_success_User2WithApproval() public {
        skip(20 minutes);

        uint256 underlyingBalance = dai.balanceOf(user1);
        uint256 balance = borrowableCDAI.balanceOf(user1);
        uint256 totalSupply = borrowableCDAI.totalSupply();
        uint256 collateralRedeemed = _ONE;

        vm.startPrank(user1);
        borrowableCDAI.approve(user2, collateralRedeemed);
        vm.stopPrank();
        
        vm.startPrank(user2);
        uint256 assets = borrowableCDAI.redeem(collateralRedeemed, user2, user1);
        vm.stopPrank();

        assertEq(dai.balanceOf(user2), underlyingBalance + assets);
        assertEq(borrowableCDAI.balanceOf(user1), balance - collateralRedeemed);
        assertEq(borrowableCDAI.totalSupply(), totalSupply - collateralRedeemed);
    }

    function test_borrowableCTokenWithdrawCollateral_success_whenCollateralIsInUse() public {
        uint256 newTokensDeposited = 2000e18;
        uint256 tokensRedeemed = 1000e18;

        _prepareUSDC(address(this), 2000e6);
        usdc.approve(address(borrowableCUSDC), 2000e6);
        borrowableCUSDC.deposit(2000e6, address(this));

        _prepareDAI(user1, newTokensDeposited * 2);

        vm.startPrank(user1);
        dai.approve(address(borrowableCDAI), newTokensDeposited * 2);
        borrowableCDAI.depositAsCollateral(newTokensDeposited, user1);
        borrowableCUSDC.borrow(1000e6, user1);
        borrowableCDAI.deposit(newTokensDeposited, user1);
        vm.stopPrank();

        skip(20 minutes);

        uint256 underlyingBalance = dai.balanceOf(user1);
        uint256 balance = borrowableCDAI.balanceOf(user1);
        uint256 totalSupply = borrowableCDAI.totalSupply();
        uint256 collateral = borrowableCDAI.collateralPosted(user1);
        uint256 totalCollateral = borrowableCDAI.marketCollateralPosted();

        vm.expectEmit(true, true, true, true, address(borrowableCDAI));
        emit CollateralUpdated(tokensRedeemed, false, user1);
        uint256 assets = _withdrawCollateralBorrowableCDai(tokensRedeemed);

        assertEq(dai.balanceOf(user1), underlyingBalance + assets);
        assertEq(borrowableCDAI.balanceOf(user1), balance - tokensRedeemed);
        assertEq(borrowableCDAI.totalSupply(), totalSupply - tokensRedeemed);
        assertEq(borrowableCDAI.collateralPosted(user1), collateral - tokensRedeemed);
        assertEq(borrowableCDAI.marketCollateralPosted(), totalCollateral - tokensRedeemed);
    }

    function test_borrowableCTokenWithdrawCollateral_success_whenCollateralNotIsInUse() public {
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

        vm.expectEmit(true, true, true, true, address(borrowableCDAI));
        emit CollateralUpdated(collateralRedeemed, false, user1);
        uint256 assets = _withdrawCollateralBorrowableCDai(collateralRedeemed);

        assertEq(dai.balanceOf(user1), underlyingBalance + assets);
        assertEq(borrowableCDAI.balanceOf(user1), balance - collateralRedeemed);
        assertEq(borrowableCDAI.totalSupply(), totalSupply - collateralRedeemed);
        assertEq(borrowableCDAI.collateralPosted(user1), collateral - collateralRedeemed);
        assertEq(borrowableCDAI.marketCollateralPosted(), totalCollateral - collateralRedeemed);
    }

    function _withdrawCollateralBorrowableCDai(uint256 assets) internal returns (uint256 shares) {
        vm.startPrank(user1);
        shares = borrowableCDAI.withdrawCollateral(assets, user1, user1);
        vm.stopPrank();
    }
}
