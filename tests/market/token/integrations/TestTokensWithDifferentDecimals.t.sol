// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import "tests/market/TestBaseMarketIsolated.sol";

contract TestTokensWithDifferentDecimals is TestBaseMarketIsolated {
    address public owner;

    MockDataFeed public mockUsdcFeed;
    MockDataFeed public mockWethFeed;
    MockDataFeed public mockRethFeed;

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

        // setup eUSDC
        {
            // support market
            _prepareUSDC(owner, 200000e6);
            usdc.approve(address(eUSDC), 200000e6);
        }

        // setup pBALRETH
        {
            // support market
            _prepareBALRETH(owner, 1 ether);
            balRETH.approve(address(pBALRETH), 1 ether);

        }

        marketManagerIsolated.listTokens(address(pBALRETH), address(eUSDC));

        // set collateral factor
        marketManagerIsolated.updatePositionToken(
            7000,    // collRatio 70%
            4000,    // collReqSoft 40%
            3000,    // collReqHard 25%
            1000,    // liqIncBase 10%
            1500,    // liqIncHard 15%
            500,     // liqIncMin 5%
            2000,    // liqIncMax 20%
            2000,    // minEffectiveCFactor 20%
            5000,    // maxEffectiveCFactor 50%
            1000     // baseCFactor 10%
        );
        address[] memory tokens = new address[](1);
        tokens[0] = address(pBALRETH);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManagerIsolated.setCollateralCaps(tokens, caps);

        tokens[0] = address(eUSDC);
        caps[0] = 100_000e6;
        marketManagerIsolated.setDebtCaps(tokens, caps);

        // provide enough liquidity
        provideEnoughLiquidityForLeverage();
    }

    function provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 200000e6);
        _prepareBALRETH(liquidityProvider, 10 ether);
        // mint eUSDC
        vm.startPrank(liquidityProvider);
        usdc.approve(address(eUSDC), 200000e6);
        eUSDC.mint(200000e6);
        // mint cBALETH
        balRETH.approve(address(pBALRETH), 10 ether);
        pBALRETH.deposit(10 ether, liquidityProvider);
        vm.stopPrank();
    }

    function testInitialize() public {
        assertTrue(pBALRETH.isCollateralizable());
        assertTrue(eUSDC.isBorrowable());
    }

    function testPTokenMintRedeem() public {
        _prepareBALRETH(user1, 2 ether);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1 ether);
        pBALRETH.deposit(1 ether, user1);
        pBALRETH.postCollateral(1 ether);
        assertEq(pBALRETH.balanceOf(user1), 1 ether);

        // try mintFor()
        balRETH.approve(address(pBALRETH), 1 ether);
        pBALRETH.deposit(1 ether, user2);
        assertEq(pBALRETH.balanceOf(user1), 1 ether);
        assertEq(pBALRETH.balanceOf(user2), 1 ether);

        // skip some period
        skip(20 minutes);

        // try redeem()
        pBALRETH.redeem(1 ether, user1, user1);
        vm.stopPrank();
        assertEq(pBALRETH.balanceOf(user1), 0);
    }

    function testETokenMintRedeem() public {
        _prepareUSDC(user1, 2e6);

        // try mint()
        vm.startPrank(user1);
        usdc.approve(address(eUSDC), 1e6);
        eUSDC.mint(1e6);
        assertEq(eUSDC.balanceOf(user1), 1e6);

        // try mintFor()
        usdc.approve(address(eUSDC), 1e6);
        eUSDC.mintFor(1e6, user2);
        assertEq(eUSDC.balanceOf(user1), 1e6);
        assertEq(eUSDC.balanceOf(user2), 1e6);

        // try redeem()
        eUSDC.redeem(1e6, address(this));
        vm.stopPrank();
        assertEq(eUSDC.balanceOf(user1), 0);
    }

    function testETokenBorrowRepay() public {
        _prepareBALRETH(user1, 1 ether);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1 ether);
        pBALRETH.deposit(1 ether, user1);
        pBALRETH.postCollateral(1 ether);

        assertEq(pBALRETH.balanceOf(user1), 1 ether);
        assertEq(pBALRETH.exchangeRate(), 1 ether);

        // try borrow()
        eUSDC.borrow(500e6);

        assertEq(eUSDC.balanceOf(user1), 0);
        assertEq(eUSDC.debtBalanceCached(user1), 500e6);
        assertEq(eUSDC.exchangeRateCached(), 1 ether);

        // try borrow()
        skip(1200);
        eUSDC.borrow(100e6);

        assertEq(eUSDC.balanceOf(user1), 0);
        assertGt(eUSDC.debtBalanceCached(user1), 600e6);
        assertGt(eUSDC.exchangeRateCached(), 1 ether);

        // skip min hold period
        skip(20 minutes);

        // try partial repay
        uint256 borrowBalanceBefore = eUSDC.debtBalanceCached(user1);
        uint256 exchangeRateBefore = eUSDC.exchangeRateCached();
        _prepareUSDC(user1, 200e6);
        usdc.approve(address(eUSDC), 200e6);
        eUSDC.repay(200e6);

        assertEq(eUSDC.balanceOf(user1), 0);
        assertGt(eUSDC.debtBalanceCached(user1), borrowBalanceBefore - 200e6);
        assertGt(eUSDC.exchangeRateCached(), exchangeRateBefore);

        // skip some period
        skip(20 minutes);

        // try repay full
        borrowBalanceBefore = eUSDC.debtBalanceCached(user1);
        exchangeRateBefore = eUSDC.exchangeRateCached();
        _prepareUSDC(user1, borrowBalanceBefore);
        usdc.approve(address(eUSDC), borrowBalanceBefore);
        eUSDC.repay(borrowBalanceBefore);
        vm.stopPrank();

        assertEq(eUSDC.balanceOf(user1), 0);
        assertGt(eUSDC.debtBalanceCached(user1), 0);
        assertGt(eUSDC.exchangeRateCached(), exchangeRateBefore);
    }

    function testPTokenRedeemOnBorrow() public {
        _prepareBALRETH(user1, 1 ether);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1 ether);
        pBALRETH.deposit(1 ether, user1);
        pBALRETH.postCollateral(1 ether);

        // try borrow()
        eUSDC.borrow(500e6);

        // skip min hold period
        skip(20 minutes);

        // can't redeem full
        vm.expectRevert(
            bytes4(keccak256("MarketManager__InsufficientCollateral()"))
        );
        pBALRETH.redeem(1 ether, user1, user1);

        // can redeem partially
        pBALRETH.redeem(0.2 ether, user1, user1);
        vm.stopPrank();

        assertEq(pBALRETH.balanceOf(user1), 0.8 ether);
        assertEq(pBALRETH.exchangeRate(), 1 ether);
    }

    function testETokenRedeemOnBorrow() public {
        // try mint()
        _prepareBALRETH(user1, 1 ether);
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1 ether);
        pBALRETH.deposit(1 ether, user1);
        pBALRETH.postCollateral(1 ether);

        // try mint()
        _prepareUSDC(user1, 1000e6);
        usdc.approve(address(eUSDC), 1000e6);
        eUSDC.mint(1000e6);

        // try borrow()
        eUSDC.borrow(500e6);

        // fail to redeem before minimum hold time pass
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__MinimumHoldPeriod.selector
        );
        eUSDC.redeem(1000e6, address(this));

        // skip min hold period
        skip(20 minutes);

        // can redeem fully
        eUSDC.redeem(1000e6, address(this));
        vm.stopPrank();

        assertEq(pBALRETH.balanceOf(user1), 1 ether);
        assertEq(pBALRETH.exchangeRate(), 1 ether);

        assertEq(eUSDC.balanceOf(user1), 0);
        assertGt(eUSDC.debtBalanceCached(user1), 500e6);
        assertGt(eUSDC.exchangeRateCached(), 1 ether);
    }

    function testPTokenTransferOnBorrow() public {
        _prepareBALRETH(user1, 1 ether);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1 ether);
        pBALRETH.deposit(1 ether, user1);
        pBALRETH.postCollateral(1 ether);

        // try borrow()
        eUSDC.borrow(500e6);

        // skip min hold period
        skip(20 minutes);

        // can't transfer full
        vm.expectRevert(
            bytes4(keccak256("MarketManager__InsufficientCollateral()"))
        );
        pBALRETH.transfer(user2, 1 ether);

        // can redeem partially
        pBALRETH.transfer(user2, 0.2 ether);
        vm.stopPrank();

        assertEq(pBALRETH.balanceOf(user1), 0.8 ether);
        assertEq(pBALRETH.balanceOf(user2), 0.2 ether);
        assertEq(pBALRETH.exchangeRate(), 1 ether);
    }

    function testETokenTransferOnBorrow() public {
        // try mint()
        _prepareBALRETH(user1, 1 ether);
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1 ether);
        pBALRETH.deposit(1 ether, user1);
        pBALRETH.postCollateral(1 ether);

        // try mint()
        _prepareUSDC(user1, 1000e6);
        usdc.approve(address(eUSDC), 1000e6);
        eUSDC.mint(1000e6);

        // try borrow()
        eUSDC.borrow(500e6);

        // skip min hold period
        skip(20 minutes);

        // try full transfer
        eUSDC.transfer(user2, 1000e6);
        vm.stopPrank();

        assertEq(pBALRETH.balanceOf(user1), 1 ether);
        assertEq(pBALRETH.exchangeRate(), 1 ether);

        assertEq(eUSDC.balanceOf(user1), 0);
        assertEq(eUSDC.debtBalanceCached(user1), 500e6);
        assertEq(eUSDC.exchangeRateCached(), 1 ether);

        assertEq(eUSDC.balanceOf(user2), 1000e6);
        assertEq(eUSDC.debtBalanceCached(user2), 0);
        assertEq(eUSDC.exchangeRateCached(), 1 ether);
    }

    function testLiquidationExact() public {
        _prepareBALRETH(user1, 1 ether);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1 ether);
        pBALRETH.deposit(1 ether, user1);
        pBALRETH.postCollateral(1 ether);

        // try borrow()
        eUSDC.borrow(1000e6);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);

        (uint256 balRETHPrice, ) = oracleManager.getPrice(
            address(balRETH),
            true,
            true
        );

        mockUsdcFeed.setMockAnswer(200000000);

        // try liquidate half
        _prepareUSDC(user2, 250e6);
        vm.startPrank(user2);
        usdc.approve(address(eUSDC), 250e6);

        address[] memory accounts = new address[](1);
        accounts[0] = user1;
        uint256[] memory debtAmounts = new uint256[](1);
        debtAmounts[0] = 250e6;

        eUSDC.liquidateExact(
            accounts,
            debtAmounts,
            address(pBALRETH));
        vm.stopPrank();

        assertApproxEqRel(
            pBALRETH.balanceOf(user1),
            1 ether - (500 ether * 1 ether) / balRETHPrice,
            0.02e18
        );
        assertEq(pBALRETH.exchangeRate(), 1 ether);

        assertEq(eUSDC.balanceOf(user1), 0);
        assertApproxEqRel(eUSDC.debtBalanceCached(user1), 750e6, 0.01e18);
        assertApproxEqRel(eUSDC.exchangeRateCached(), 1 ether, 0.01e18);
    }

    function testLiquidation() public {
        _prepareBALRETH(user1, 1 ether);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1 ether);
        pBALRETH.deposit(1 ether, user1);
        pBALRETH.postCollateral(1 ether);

        // try borrow()
        eUSDC.borrow(1000e6);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);

        (uint256 balRETHPrice, ) = oracleManager.getPrice(
            address(balRETH),
            true,
            true
        );

        mockUsdcFeed.setMockAnswer(150000000);

        // try liquidate
        _prepareUSDC(user2, 10000e6);
        vm.startPrank(user2);
        usdc.approve(address(eUSDC), 10000e6);
        
        address[] memory accounts = new address[](1);
        accounts[0] = user1;

        eUSDC.liquidate(
            accounts,
            address(pBALRETH));
        vm.stopPrank();

        assertApproxEqRel(
            pBALRETH.balanceOf(user1),
            1 ether - (1550 ether * 1e18) / balRETHPrice,
            0.06e18
        );
        assertEq(pBALRETH.exchangeRate(), 1 ether);

        assertEq(eUSDC.balanceOf(user1), 0);
        assertEq(eUSDC.debtBalanceCached(user1), 0);
        assertApproxEqRel(eUSDC.exchangeRateCached(), 1 ether, 0.01e18);
    }
}
