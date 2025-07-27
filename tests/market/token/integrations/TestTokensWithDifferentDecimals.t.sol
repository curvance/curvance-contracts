// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import "tests/market/TestBaseMarketIsolated.sol";
import { WAD, WAD_SQUARED } from "contracts/libraries/Constants.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { console2 } from "forge-std/console2.sol";

contract TestTokensWithDifferentDecimals is TestBaseMarketIsolated {
    address public owner;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        super.setUp();

        owner = address(this);

        // use mock pricing for testing
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
        mockWethFeed = new MockDataFeed(_CHAINLINK_ETH_USD);
        chainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            address(mockWethFeed),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            address(mockWethFeed),
            0,
            true
        );
        mockRethFeed = new MockDataFeed(_CHAINLINK_RETH_ETH);
        chainlinkAdaptor.addAsset(
            _RETH_ADDRESS,
            address(mockRethFeed),
            0,
            false
        );
        dualChainlinkAdaptor.addAsset(
            _RETH_ADDRESS,
            address(mockRethFeed),
            0,
            false
        );

        // start epoch
        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);

        (, int256 ethPrice, , , ) = mockWethFeed.latestRoundData();
        chainlinkEthUsd.updateAnswer(ethPrice);

        // Setup borrowable cUSDC.
        {
            _prepareUSDC(owner, 200000e6);
            usdc.approve(address(borrowableCUSDC), 200000e6);
        }

        // Setup strategyCBALRETH.
        {
            _prepareBALRETH(owner, 1 ether);
            balRETH.approve(address(strategyCBALRETH), 1 ether);

        }

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 100_000e6);

        // provide enough liquidity
        provideEnoughLiquidityForLeverage();
    }

    function provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 200000e6);
        _prepareBALRETH(liquidityProvider, 10 ether);
        // Mint borrowable cUSDC.
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 200000e6);
        borrowableCUSDC.deposit(200000e6, liquidityProvider);
        // Mint cBALETH.
        balRETH.approve(address(strategyCBALRETH), 10 ether);
        strategyCBALRETH.deposit(10 ether, liquidityProvider);
        vm.stopPrank();
    }

    function testCTokenMintRedeem() public {
        _prepareBALRETH(user1, 2 ether);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 1 ether);
        strategyCBALRETH.deposit(1 ether, user1);
        strategyCBALRETH.postCollateral(1 ether);
        assertEq(strategyCBALRETH.balanceOf(user1), 1 ether);

        // try mintFor()
        balRETH.approve(address(strategyCBALRETH), 1 ether);
        strategyCBALRETH.deposit(1 ether, user2);
        assertEq(strategyCBALRETH.balanceOf(user1), 1 ether);
        assertEq(strategyCBALRETH.balanceOf(user2), 1 ether);

        // skip some period
        skip(20 minutes);

        // try redeem()
        strategyCBALRETH.redeem(1 ether, user1, user1);
        vm.stopPrank();
        assertEq(strategyCBALRETH.balanceOf(user1), 0);
    }

    function testBorrowableCTokenMintRedeem() public {
        _prepareUSDC(user1, 2e6);

        // try mint()
        vm.startPrank(user1);
        usdc.approve(address(borrowableCUSDC), 1e6);
        borrowableCUSDC.deposit(1e6, user1);
        assertEq(borrowableCUSDC.balanceOf(user1), 1e6);

        // try minting for user2
        usdc.approve(address(borrowableCUSDC), 1e6);
        borrowableCUSDC.deposit(1e6, user2);
        assertEq(borrowableCUSDC.balanceOf(user1), 1e6);
        assertEq(borrowableCUSDC.balanceOf(user2), 1e6);

        // try redeem()
        borrowableCUSDC.redeem(1e6, address(this), user1);
        vm.stopPrank();
        assertEq(borrowableCUSDC.balanceOf(user1), 0);
    }

    function testBorrowableCTokenBorrowRepay() public {
        _prepareBALRETH(user1, 1 ether);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 1 ether);
        strategyCBALRETH.deposit(1 ether, user1);
        strategyCBALRETH.postCollateral(1 ether);

        assertEq(strategyCBALRETH.balanceOf(user1), 1 ether);
        assertEq(strategyCBALRETH.exchangeRate(), 1 ether);

        // try borrow()
        borrowableCUSDC.borrow(500e6, user1);

        assertEq(borrowableCUSDC.balanceOf(user1), 0);
        assertEq(borrowableCUSDC.debtBalance(user1), 500e6);
        assertEq(borrowableCUSDC.exchangeRate(), 1 ether);

        // try borrow()
        skip(1200);
        borrowableCUSDC.borrow(100e6, user1);

        assertEq(borrowableCUSDC.balanceOf(user1), 0);
        assertGt(borrowableCUSDC.debtBalance(user1), 600e6);
        assertGt(borrowableCUSDC.exchangeRate(), 1 ether);

        // skip min hold period
        skip(20 minutes);

        // try partial repay
        uint256 borrowBalanceBefore = borrowableCUSDC.debtBalance(user1);
        uint256 exchangeRateBefore = borrowableCUSDC.exchangeRate();
        _prepareUSDC(user1, 200e6);
        usdc.approve(address(borrowableCUSDC), 200e6);
        borrowableCUSDC.repay(200e6);

        assertEq(borrowableCUSDC.balanceOf(user1), 0);
        assertGt(borrowableCUSDC.debtBalance(user1), borrowBalanceBefore - 200e6);
        assertGt(borrowableCUSDC.exchangeRate(), exchangeRateBefore);

        // skip some period
        skip(20 minutes);

        // try repay full
        borrowBalanceBefore = borrowableCUSDC.debtBalance(user1);
        exchangeRateBefore = borrowableCUSDC.exchangeRate();
        _prepareUSDC(user1, borrowBalanceBefore);
        usdc.approve(address(borrowableCUSDC), borrowBalanceBefore);
        borrowableCUSDC.repay(borrowBalanceBefore);
        vm.stopPrank();

        assertEq(borrowableCUSDC.balanceOf(user1), 0);
        assertGt(borrowableCUSDC.debtBalance(user1), 0);
        assertGt(borrowableCUSDC.exchangeRate(), exchangeRateBefore);
    }

    function testCTokenRedeemOnBorrow() public {
        _prepareBALRETH(user1, 1 ether);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 1 ether);
        strategyCBALRETH.deposit(1 ether, user1);
        strategyCBALRETH.postCollateral(1 ether);

        // try borrow()
        borrowableCUSDC.borrow(500e6, user1);

        // skip min hold period
        skip(20 minutes);

        // can't redeem full
        vm.expectRevert(
            bytes4(keccak256("MarketManager__InsufficientCollateral()"))
        );
        strategyCBALRETH.redeem(1 ether, user1, user1);

        // can redeem partially
        strategyCBALRETH.redeem(0.2 ether, user1, user1);
        vm.stopPrank();

        assertEq(strategyCBALRETH.balanceOf(user1), 0.8 ether);
        assertEq(strategyCBALRETH.exchangeRate(), 1 ether);
    }

    function testBorrowableCTokenRedeemOnBorrow() public {
        // try mint()
        _prepareBALRETH(user1, 1 ether);
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 1 ether);
        strategyCBALRETH.deposit(1 ether, user1);
        strategyCBALRETH.postCollateral(1 ether);

        // try mint()
        _prepareUSDC(user1, 1000e6);
        usdc.approve(address(borrowableCUSDC), 1000e6);
        borrowableCUSDC.deposit(1000e6, user1);

        // try borrow()
        borrowableCUSDC.borrow(500e6, user1);

        // fail to redeem before minimum hold time pass
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__MinimumHoldPeriod.selector
        );
        borrowableCUSDC.redeem(1000e6, address(this), user1);

        // skip min hold period
        skip(20 minutes);

        // can redeem fully
        borrowableCUSDC.redeem(1000e6, address(this), user1);
        vm.stopPrank();

        assertEq(strategyCBALRETH.balanceOf(user1), 1 ether);
        assertEq(strategyCBALRETH.exchangeRate(), 1 ether);

        assertEq(borrowableCUSDC.balanceOf(user1), 0);
        assertGt(borrowableCUSDC.debtBalance(user1), 500e6);
        assertGt(borrowableCUSDC.exchangeRate(), 1 ether);
    }

    function testCTokenTransferOnBorrow() public {
        _prepareBALRETH(user1, 1 ether);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 1 ether);
        strategyCBALRETH.deposit(1 ether, user1);
        strategyCBALRETH.postCollateral(1 ether);

        // try borrow()
        borrowableCUSDC.borrow(500e6, user1);

        // skip min hold period
        skip(20 minutes);

        // can't transfer full
        vm.expectRevert(
            bytes4(keccak256("MarketManager__InsufficientCollateral()"))
        );
        strategyCBALRETH.transfer(user2, 1 ether);

        // can redeem partially
        strategyCBALRETH.transfer(user2, 0.2 ether);
        vm.stopPrank();

        assertEq(strategyCBALRETH.balanceOf(user1), 0.8 ether);
        assertEq(strategyCBALRETH.balanceOf(user2), 0.2 ether);
        assertEq(strategyCBALRETH.exchangeRate(), 1 ether);
    }

    function testBorrowableCTokenTransferOnBorrow() public {
        // try mint()
        _prepareBALRETH(user1, 1 ether);
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 1 ether);
        strategyCBALRETH.deposit(1 ether, user1);
        strategyCBALRETH.postCollateral(1 ether);

        // try mint()
        _prepareUSDC(user1, 1000e6);
        usdc.approve(address(borrowableCUSDC), 1000e6);
        borrowableCUSDC.deposit(1000e6, user1);

        // try borrow()
        borrowableCUSDC.borrow(500e6, user1);

        // skip min hold period
        skip(20 minutes);

        // try full transfer
        borrowableCUSDC.transfer(user2, 1000e6);
        vm.stopPrank();

        assertEq(strategyCBALRETH.balanceOf(user1), 1 ether);
        assertEq(strategyCBALRETH.exchangeRate(), 1 ether);

        assertEq(borrowableCUSDC.balanceOf(user1), 0);
        assertEq(borrowableCUSDC.debtBalance(user1), 500e6);
        assertEq(borrowableCUSDC.exchangeRate(), 1 ether);

        assertEq(borrowableCUSDC.balanceOf(user2), 1000e6);
        assertEq(borrowableCUSDC.debtBalance(user2), 0);
        assertEq(borrowableCUSDC.exchangeRate(), 1 ether);
    }

    function testLiquidationExact() public {
        _prepareBALRETH(user1, 1 ether);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 1 ether);
        strategyCBALRETH.deposit(1 ether, user1);
        strategyCBALRETH.postCollateral(1 ether);

        // try borrow()
        borrowableCUSDC.borrow(1000e6, user1);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);

        mockUsdcFeed.setMockAnswer(200000000);

        ExpectedLiquidationValues memory expectedLiquidationValues = _calculateExpectedLiquidationValues(
            LiquidationParams({
                borrower: user1,
                collateralToken: address(strategyCBALRETH),
                borrowedToken: address(borrowableCUSDC),
                isLiquidateExact: true,
                liquidateExactAmount: 250e6,
                isAuction: false,
                isMultiMarketTest: false,
                marketManagerId: 0
            })
        );

        // try liquidate half
        _prepareUSDC(user2, 250e6);
        vm.startPrank(user2);
        usdc.approve(address(borrowableCUSDC), 250e6);

        address[] memory accounts = new address[](1);
        accounts[0] = user1;
        uint256[] memory debtAmounts = new uint256[](1);
        debtAmounts[0] = 250e6;

        uint256 currentDebtBalance = borrowableCUSDC.debtBalance(user1);

        borrowableCUSDC.liquidateExact(
            debtAmounts,
            accounts,
            address(strategyCBALRETH));
        vm.stopPrank();

        assertApproxEqRel(
            strategyCBALRETH.balanceOf(user1),
            1 ether - expectedLiquidationValues.collateralLiquidated,
            0.01e18
        );
        assertEq(strategyCBALRETH.exchangeRate(), 1 ether);

        assertEq(borrowableCUSDC.balanceOf(user1), 0);
        assertApproxEqRel(borrowableCUSDC.debtBalance(user1), currentDebtBalance - (expectedLiquidationValues.badDebt + 250e6), 0.01e18);
        assertApproxEqRel(borrowableCUSDC.exchangeRate(), 1 ether, 0.01e18);
    }

    function testLiquidation() public {
        _prepareBALRETH(user1, 1 ether);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 1 ether);
        strategyCBALRETH.deposit(1 ether, user1);
        strategyCBALRETH.postCollateral(1 ether);

        // try borrow()
        borrowableCUSDC.borrow(1000e6, user1);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);

        mockUsdcFeed.setMockAnswer(150000000);

        uint256 currentDebtBalance = borrowableCUSDC.debtBalance(user1);

        ExpectedLiquidationValues memory expectedLiquidationValues = _calculateExpectedLiquidationValues(
            LiquidationParams({
                borrower: user1,
                collateralToken: address(strategyCBALRETH),
                borrowedToken: address(borrowableCUSDC),
                isLiquidateExact: false,
                liquidateExactAmount: 0,
                isAuction: false,
                isMultiMarketTest: false,
                marketManagerId: 0
            })
        );
        
        // try liquidate
        _prepareUSDC(user2, 10000e6);
        vm.startPrank(user2);
        usdc.approve(address(borrowableCUSDC), 10000e6);
        
        address[] memory accounts = new address[](1);
        accounts[0] = user1;

        borrowableCUSDC.liquidate(
            accounts,
            address(strategyCBALRETH));
        vm.stopPrank();

        assertApproxEqRel(
            strategyCBALRETH.balanceOf(user1),
            1 ether - expectedLiquidationValues.collateralLiquidated,
            0.06e18
        );
        assertEq(strategyCBALRETH.exchangeRate(), 1 ether);

        assertEq(borrowableCUSDC.balanceOf(user1), 0);
        assertApproxEqRel(borrowableCUSDC.debtBalance(user1), currentDebtBalance - (expectedLiquidationValues.badDebt + expectedLiquidationValues.debtRepaid), 0.01e18);
        assertApproxEqRel(borrowableCUSDC.exchangeRate(), 1 ether, 0.01e18);
    }

}
