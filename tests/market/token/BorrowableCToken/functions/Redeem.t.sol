// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseBorrowableCToken } from "../TestBaseBorrowableCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { ERC20 } from "contracts/libraries/external/ERC20.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract RedeemTest is TestBaseBorrowableCToken {
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event CollateralUpdated(uint256 shares, bool increased, address account);

    MockDataFeed public mockDaiFeed;

    function setUp() public override {
        _fork(18031848);

        _init();

        mockUsdcFeed = new MockDataFeed(_CHAINLINK_USDC_USD);
        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(mockUsdcFeed),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(mockUsdcFeed),
            0,
            true
        );
        mockDaiFeed = new MockDataFeed(_CHAINLINK_DAI_USD);
        chainlinkAdaptor.addAsset(
            _DAI_ADDRESS,
            address(mockDaiFeed),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _DAI_ADDRESS,
            address(mockDaiFeed),
            0,
            true
        );

        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockDaiFeed.setMockUpdatedAt(block.timestamp);

        oracleManager.addCTokenSupport(address(borrowableCDAI));

        _prepareUSDC(address(this), _ONE + 77777);
        _prepareDAI(address(this), 10e18 + 77777);
        
        usdc.approve(address(borrowableCUSDC), _ONE + 77777);
        dai.approve(address(borrowableCDAI), 10e18 + 77777);

        marketManagerIsolated.listTokens(address(borrowableCDAI), address(borrowableCUSDC));

        MarketManagerIsolated.TokenConfig memory cTokenConfig;
        cTokenConfig.cToken = address(borrowableCDAI);
        cTokenConfig.collRatio = 7000;
        cTokenConfig.collReqSoft = 4000;
        cTokenConfig.collReqHard = 3000;
        cTokenConfig.liqIncBase = 1000;
        cTokenConfig.liqIncHard = 1500;
        cTokenConfig.liqIncMin = 500;
        cTokenConfig.liqIncMax = 2000;
        cTokenConfig.minEffectiveCloseFactor = 2000;
        cTokenConfig.maxEffectiveCloseFactor = 3000;
        cTokenConfig.baseCFactor = 1000;
        cTokenConfig.collateralCap = 100_000e18;
        cTokenConfig.debtCap = 100_000e18;

        marketManagerIsolated.updateTokenConfig(cTokenConfig);

        cTokenConfig.cToken = address(borrowableCUSDC);
        cTokenConfig.debtCap = 100_000e6;
        marketManagerIsolated.updateTokenConfig(cTokenConfig);

        borrowableCDAI.mint(_ONE, address(this));

        _prepareDAI(user1, _ONE + _ONE);

        vm.startPrank(user1);
        dai.approve(address(borrowableCDAI), _ONE + _ONE);
        borrowableCDAI.depositAsCollateral(_ONE + _ONE, user1);
        vm.stopPrank();
    }

    function test_borrowableCTokenRedeem_fail_whenTransferIsDisabled() public {
        skip(20 minutes);

        vm.startPrank(user1);
        centralRegistry.setTransferableStatus(true);
        vm.stopPrank();

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        _redeemBorrowableCDai(_ONE);
    }

    function test_borrowableCTokenRedeem_fail_whenUser2Unauthorized() public {
        skip(20 minutes);

        vm.expectRevert(ERC20.InsufficientAllowance.selector);

        vm.startPrank(user2);
        borrowableCDAI.redeem(_ONE, user1, user1);
        vm.stopPrank();
    }

    function test_borrowableCTokenRedeem_fail_whenCooldownIsNotEnded() public {
        skip(20 minutes);

        vm.startPrank(user1);
        centralRegistry.setCooldown(10 days);
        centralRegistry.setCooldown(5 days);
        vm.stopPrank();

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);

        _redeemBorrowableCDai(_ONE);
    }

    function test_borrowableCTokenRedeem_fail_whenAmountIsZero() public {
        skip(20 minutes);

        vm.expectRevert(
            BaseCToken.BaseCToken__ZeroAmount.selector
        );

        _redeemBorrowableCDai(0);
    }

    function test_borrowableCTokenRedeem_fail_whenRedeemAmountExceedsCTokens() public {
        skip(20 minutes);

        vm.expectRevert(BaseCToken.BaseCToken__InsufficientLiquidity.selector);
        _redeemBorrowableCDai(10e18);
    }

    function test_borrowableCTokenRedeem_fail_whenCooldownActive() public {
        _prepareDAI(user1, _ONE + _ONE);

        vm.startPrank(user1);
        dai.approve(address(borrowableCDAI), _ONE + _ONE);
        borrowableCDAI.depositAsCollateral(_ONE + _ONE, user1);
        vm.stopPrank();

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__MinimumHoldPeriod.selector
        );

        _redeemBorrowableCDai(_ONE);
    }

    function test_borrowableCTokenRedeem_fail_whenCollateralIsRequired() public {
        _prepareUSDC(address(this), 200e6);
        usdc.approve(address(borrowableCUSDC), 200e6);
        borrowableCUSDC.deposit(200e6, address(this));

        _prepareDAI(user1, 1000e18);

        vm.startPrank(user1);
        dai.approve(address(borrowableCDAI), 1000e18);
        borrowableCDAI.depositAsCollateral(500e18, user1);
        borrowableCUSDC.borrow(100e6, user1);
        borrowableCDAI.deposit(500e18, user1);
        vm.stopPrank();

        skip(20 minutes);

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral.selector
        );

        _redeemBorrowableCDai(1000e18);
    }

    function test_borrowableCTokenRedeem_success() public {
        skip(20 minutes);

        uint256 underlyingBalance = dai.balanceOf(user1);
        uint256 balance = borrowableCDAI.balanceOf(user1);
        uint256 totalSupply = borrowableCDAI.totalSupply();
        uint256 collateralRedeemed = _ONE;

        vm.expectEmit(true, true, true, true, address(borrowableCDAI));
        emit Transfer(user1, address(0), collateralRedeemed);
        uint256 assets = _redeemBorrowableCDai(collateralRedeemed);

        assertEq(dai.balanceOf(user1), underlyingBalance + assets);
        assertEq(borrowableCDAI.balanceOf(user1), balance - collateralRedeemed);
        assertEq(borrowableCDAI.totalSupply(), totalSupply - collateralRedeemed);
    }

    function test_borrowableCTokenRedeem_success_User2WithApproval() public {
        skip(20 minutes);

        uint256 underlyingBalance = dai.balanceOf(user1);
        uint256 balance = borrowableCDAI.balanceOf(user1);
        uint256 totalSupply = borrowableCDAI.totalSupply();
        uint256 collateralRedeemed = 0.5e18;

        vm.startPrank(user1);
        borrowableCDAI.approve(user2, _ONE);
        vm.stopPrank();
        
        vm.startPrank(user2);
        uint256 assets = borrowableCDAI.redeem(collateralRedeemed, user2, user1);
        vm.stopPrank();

        assertEq(dai.balanceOf(user2), underlyingBalance + assets);
        assertEq(borrowableCDAI.balanceOf(user1), balance - collateralRedeemed);
        assertEq(borrowableCDAI.totalSupply(), totalSupply - collateralRedeemed);
    }

    function test_borrowableCTokenRedeem_success_redeemNonCollateralWhenCollateralIsInUse() public {
        uint256 newTokensDeposited = 500e18;
        uint256 tokensRedeemed = 500e18;
        uint256 collateralRedeemed = tokensRedeemed - newTokensDeposited; // This equals 0.

        _prepareUSDC(address(this), 200e6);
        usdc.approve(address(borrowableCUSDC), 200e6);
        borrowableCUSDC.deposit(200e6, address(this));

        _prepareDAI(user1, newTokensDeposited * 2);

        vm.startPrank(user1);
        dai.approve(address(borrowableCDAI), newTokensDeposited * 2);
        borrowableCDAI.depositAsCollateral(newTokensDeposited, user1);
        borrowableCUSDC.borrow(100e6, user1);
        borrowableCDAI.deposit(newTokensDeposited, user1);
        vm.stopPrank();

        skip(20 minutes);

        uint256 underlyingBalance = dai.balanceOf(user1);
        uint256 balance = borrowableCDAI.balanceOf(user1);
        uint256 totalSupply = borrowableCDAI.totalSupply();
        uint256 collateral = borrowableCDAI.collateralPosted(user1);
        uint256 totalCollateral = borrowableCDAI.marketCollateralPosted();

        vm.expectEmit(true, true, true, true, address(borrowableCDAI));
        emit Transfer(user1, address(0), tokensRedeemed);
        uint256 assets = _redeemBorrowableCDai(tokensRedeemed);

        assertEq(dai.balanceOf(user1), underlyingBalance + assets);
        assertEq(borrowableCDAI.balanceOf(user1), balance - tokensRedeemed);
        assertEq(borrowableCDAI.totalSupply(), totalSupply - tokensRedeemed);
        assertEq(borrowableCDAI.collateralPosted(user1), collateral - collateralRedeemed);
        assertEq(strategyCBALRETH.marketCollateralPosted(), totalCollateral - collateralRedeemed);
    }

    function test_borrowableCTokenRedeem_success_redeemNonCollateralAndCollateralWhenCollateralIsInUse() public {
        uint256 newTokensDeposited = 500e18;
        uint256 tokensRedeemed = 600e18;
        uint256 collateralRedeemed = tokensRedeemed - newTokensDeposited;

        _prepareUSDC(address(this), 200e6);
        usdc.approve(address(borrowableCUSDC), 200e6);
        borrowableCUSDC.deposit(200e6, address(this));

        _prepareDAI(user1, 1000e18);

        vm.startPrank(user1);
        dai.approve(address(borrowableCDAI), 1000e18);
        borrowableCDAI.depositAsCollateral(newTokensDeposited, user1);
        borrowableCUSDC.borrow(100e6, user1);
        borrowableCDAI.deposit(newTokensDeposited, user1);
        vm.stopPrank();

        skip(20 minutes);

        uint256 underlyingBalance = dai.balanceOf(user1);
        uint256 balance = borrowableCDAI.balanceOf(user1);
        uint256 totalSupply = borrowableCDAI.totalSupply();
        uint256 collateral = borrowableCDAI.collateralPosted(user1);
        uint256 totalCollateral = borrowableCDAI.marketCollateralPosted();

        vm.expectEmit(true, true, true, true, address(borrowableCDAI));
        emit CollateralUpdated(user1, address(0), collateralRedeemed);
        uint256 assets = _redeemBorrowableCDai(tokensRedeemed);

        assertEq(dai.balanceOf(user1), underlyingBalance + assets);
        assertEq(borrowableCDAI.balanceOf(user1), balance - tokensRedeemed);
        assertEq(borrowableCDAI.totalSupply(), totalSupply - tokensRedeemed);
        assertEq(borrowableCDAI.collateralPosted(user1), collateral - collateralRedeemed);
        assertEq(strategyCBALRETH.marketCollateralPosted(), totalCollateral - collateralRedeemed);
    }

    function _redeemBorrowableCDai(uint256 shares) internal returns (uint256 assets) {
        vm.startPrank(user1);
        assets = borrowableCDAI.redeem(shares, user1, user1);
        vm.stopPrank();
    }
}
