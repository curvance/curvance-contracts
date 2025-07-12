// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { ICToken } from "contracts/interfaces/ICToken.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { LiquidityManagerIsolated } from "contracts/market/isolated/LiquidityManagerIsolated.sol";
import "tests/market/TestBaseMarketIsolated.sol";

contract TestTokenInteractions is TestBaseMarketIsolated {
    address public owner;

    MockDataFeed public mockDaiFeed;
    MockDataFeed public mockWethFeed;
    MockDataFeed public mockRethFeed;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        super.setUp();

        owner = address(this);

        // use mock pricing for testing
        mockDaiFeed = new MockDataFeed(_CHAINLINK_DAI_USD);
        chainlinkAdaptor.addAsset(_DAI_ADDRESS, address(mockDaiFeed), 0, true);
        dualChainlinkAdaptor.addAsset(
            _DAI_ADDRESS,
            address(mockDaiFeed),
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

        mockDaiFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);

        (, int256 ethPrice, , , ) = mockWethFeed.latestRoundData();
        chainlinkEthUsd.updateAnswer(ethPrice);

        // setup eDAI
        {
            _prepareDAI(owner, 200_000e18);
            dai.approve(address(borrowableCDAI), 200_000e18);
            // Add cToken support on Oracle Manager.
            oracleManager.addCTokenSupport(address(borrowableCDAI));
        }

        // setup strategyCBALRETH
        {
            // support market
            _prepareBALRETH(owner, _ONE);
            balRETH.approve(address(strategyCBALRETH), _ONE);
        }

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCDAI));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(strategyCBALRETH);
        tokenConfig.collRatio = 7000;
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.minEffectiveCloseFactor = 2000;
        tokenConfig.maxEffectiveCloseFactor = 5000;
        tokenConfig.baseCFactor = 1000;
        tokenConfig.collateralCap = 100_000e18;
        tokenConfig.debtCap = 0;

        marketManagerIsolated.updateTokenConfig(tokenConfig);

        tokenConfig.cToken = address(borrowableCDAI);
        tokenConfig.debtCap = 100_000e18;
        marketManagerIsolated.updateTokenConfig(tokenConfig);

        // provide enough liquidity
        provideEnoughLiquidityForLeverage();
    }

    function provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareDAI(liquidityProvider, 200_000e18);
        _prepareBALRETH(liquidityProvider, 10e18);
        // mint eDAI
        vm.startPrank(liquidityProvider);
        dai.approve(address(borrowableCDAI), 200_000e18);
        borrowableCDAI.deposit(200_000e18, liquidityProvider);
        // mint cBALETH
        balRETH.approve(address(strategyCBALRETH), 10e18);
        strategyCBALRETH.deposit(10e18, liquidityProvider);
        vm.stopPrank();
    }

    function testCTokenMintRedeem() public {
        _prepareBALRETH(user1, 2e18);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.mint(_ONE, user1);
        assertEq(strategyCBALRETH.balanceOf(user1), _ONE);

        // try mint to another user
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.mint(_ONE, user2);
        assertEq(strategyCBALRETH.balanceOf(user1), _ONE);
        assertEq(strategyCBALRETH.balanceOf(user2), _ONE);

        // try redeem()
        strategyCBALRETH.redeem(_ONE, user1, user1);
        vm.stopPrank();
        assertEq(strategyCBALRETH.balanceOf(user1), 0);
    }

    function testBorrowableCTokenMintRedeem() public {
        _prepareDAI(user1, 2e18);

        // try mint()
        vm.startPrank(user1);
        dai.approve(address(borrowableCDAI), _ONE);
        borrowableCDAI.mint(_ONE, user1);
        assertEq(borrowableCDAI.balanceOf(user1), _ONE);

        // try mint to another user
        dai.approve(address(borrowableCDAI), _ONE);
        borrowableCDAI.mint(_ONE, user2);
        assertEq(borrowableCDAI.balanceOf(user1), _ONE);
        assertEq(borrowableCDAI.balanceOf(user2), _ONE);

        // try redeem()
        borrowableCDAI.redeem(_ONE, address(this), user1);
        vm.stopPrank();
        assertEq(borrowableCDAI.balanceOf(user1), 0);
    }

    function testBorrowableCTokenBorrowRepay() public {
        _prepareBALRETH(user1, _ONE);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.deposit(_ONE, user1);
        strategyCBALRETH.postCollateral(_ONE);

        assertEq(strategyCBALRETH.balanceOf(user1), _ONE);
        assertEq(strategyCBALRETH.exchangeRate(), _ONE);

        uint256 priceDecimals = mockDaiFeed.decimals();
        (, int256 daiPrice, , , ) = mockDaiFeed.latestRoundData();

        uint256 minimumBorrowAmount = (marketManagerIsolated.MIN_ACTIVE_LOAN_SIZE() *
            (10 ** priceDecimals)) / uint256(daiPrice);

        // try borrow() with insufficient loan size
        vm.expectRevert(
            LiquidityManagerIsolated.LiquidityManager__InsufficientLoanSize.selector
        );
        borrowableCDAI.borrow(minimumBorrowAmount - 1);

        // try borrow()
        borrowableCDAI.borrow(minimumBorrowAmount);

        assertEq(borrowableCDAI.balanceOf(user1), 0);
        assertEq(borrowableCDAI.debtBalance(user1), minimumBorrowAmount);
        assertEq(borrowableCDAI.exchangeRate(), _ONE);

        // try borrow()
        skip(1200);
        borrowableCDAI.borrow(100e18);

        assertEq(borrowableCDAI.balanceOf(user1), 0);
        assertGt(borrowableCDAI.debtBalance(user1), minimumBorrowAmount + 100e18);
        assertGt(borrowableCDAI.exchangeRate(), _ONE);

        // skip min hold period
        skip(20 minutes);

        // try partial repay
        uint256 borrowBalanceBefore = borrowableCDAI.debtBalance(user1);
        uint256 exchangeRateBefore = borrowableCDAI.exchangeRate();
        _prepareDAI(user1, 20e18);
        dai.approve(address(borrowableCDAI), 20e18);
        borrowableCDAI.repay(20e18);

        assertEq(borrowableCDAI.balanceOf(user1), 0);
        assertGt(borrowableCDAI.debtBalance(user1), borrowBalanceBefore - 20e18);
        assertGt(borrowableCDAI.exchangeRate(), exchangeRateBefore);

        // skip some period
        skip(1200);

        // try repay full
        borrowBalanceBefore = borrowableCDAI.debtBalance(user1);
        exchangeRateBefore = borrowableCDAI.exchangeRate();
        _prepareDAI(user1, borrowBalanceBefore);
        dai.approve(address(borrowableCDAI), borrowBalanceBefore);
        borrowableCDAI.repay(borrowBalanceBefore);
        vm.stopPrank();

        assertEq(borrowableCDAI.balanceOf(user1), 0);
        assertGt(borrowableCDAI.debtBalance(user1), 0);
        assertGt(borrowableCDAI.exchangeRate(), exchangeRateBefore);
    }

    function testCTokenRedeemOnBorrow() public {
        _prepareBALRETH(user1, _ONE);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.deposit(_ONE, user1);
        strategyCBALRETH.postCollateral(_ONE);

        // try borrow()
        borrowableCDAI.borrow(500e18);

        // skip min hold period
        skip(20 minutes);

        // can't redeem full
        vm.expectRevert(
            bytes4(keccak256("MarketManager__InsufficientCollateral()"))
        );
        strategyCBALRETH.redeem(_ONE, user1, user1);

        // can redeem partially
        strategyCBALRETH.redeem(0.2e18, user1, user1);
        vm.stopPrank();

        assertEq(strategyCBALRETH.balanceOf(user1), 0.8e18);
        assertEq(strategyCBALRETH.exchangeRate(), _ONE);
    }

    function testBorrowableCTokenRedeemOnBorrow() public {
        // try mint()
        _prepareBALRETH(user1, _ONE);
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.deposit(_ONE, user1);
        strategyCBALRETH.postCollateral(_ONE);

        // try mint()
        _prepareDAI(user1, 1000e18);
        dai.approve(address(borrowableCDAI), 1000e18);
        borrowableCDAI.mint(1000e18, user1);

        // try borrow()
        borrowableCDAI.borrow(500e18);

        // fail to redeem before minimum hold time pass
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__MinimumHoldPeriod.selector
        );
        borrowableCDAI.redeem(1000e18, address(this), user1);

        // skip min hold period
        skip(20 minutes);

        // can redeem fully
        borrowableCDAI.redeem(1000e18, address(this), user1);
        vm.stopPrank();

        assertEq(strategyCBALRETH.balanceOf(user1), _ONE);
        assertEq(strategyCBALRETH.exchangeRate(), _ONE);

        assertEq(borrowableCDAI.balanceOf(user1), 0);
        assertGt(borrowableCDAI.debtBalance(user1), 500e18);
        assertGt(borrowableCDAI.exchangeRate(), _ONE);
    }

    function testCTokenTransferOnBorrow() public {
        _prepareBALRETH(user1, _ONE);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.deposit(_ONE, user1);
        strategyCBALRETH.postCollateral(_ONE);

        // try borrow()
        borrowableCDAI.borrow(500e18);

        // skip min hold period
        skip(20 minutes);

        // can't transfer full
        vm.expectRevert(
            bytes4(keccak256("MarketManager__InsufficientCollateral()"))
        );
        strategyCBALRETH.transfer(user2, _ONE);

        // can redeem partially
        strategyCBALRETH.transfer(user2, 0.2e18);
        vm.stopPrank();

        assertEq(strategyCBALRETH.balanceOf(user1), 0.8e18);
        assertEq(strategyCBALRETH.balanceOf(user2), 0.2e18);
        assertEq(strategyCBALRETH.exchangeRate(), _ONE);
    }

    function testBorrowableCTokenTransferOnBorrow() public {
        // try mint()
        _prepareBALRETH(user1, _ONE);
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.deposit(_ONE, user1);
        strategyCBALRETH.postCollateral(_ONE);

        // try mint()
        _prepareDAI(user1, 1000e18);
        dai.approve(address(borrowableCDAI), 1000e18);
        borrowableCDAI.deposit(1000e18, user1);

        // try borrow()
        borrowableCDAI.borrow(500e18);

        // skip min hold period
        skip(20 minutes);

        // try full transfer
        borrowableCDAI.transfer(user2, 1000e18);
        vm.stopPrank();

        assertEq(strategyCBALRETH.balanceOf(user1), _ONE);
        assertEq(strategyCBALRETH.exchangeRate(), _ONE);

        assertEq(borrowableCDAI.balanceOf(user1), 0);
        assertEq(borrowableCDAI.debtBalance(user1), 500e18);

        assertEq(borrowableCDAI.balanceOf(user2), 1000e18);
        assertEq(borrowableCDAI.debtBalance(user2), 0e18);
        assertEq(borrowableCDAI.exchangeRate(), _ONE);
    }

    function testLiquidationExact() public {
        _prepareBALRETH(user1, _ONE);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.deposit(_ONE, user1);
        strategyCBALRETH.postCollateral(_ONE);

        // try borrow()
        borrowableCDAI.borrow(1000e18);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);

        (uint256 balRETHPrice, ) = oracleManager.getPrice(
            address(balRETH),
            true,
            true
        );

        mockDaiFeed.setMockAnswer(2e8);

        // try liquidate half
        _prepareDAI(user2, 250e18);
        vm.startPrank(user2);
        dai.approve(address(borrowableCDAI), 250e18);
        address[] memory accounts = new address[](1);
        accounts[0] = user1;
        uint256[] memory debtAmounts = new uint256[](1);
        debtAmounts[0] = 250e18;
        borrowableCDAI.liquidateExact(
            accounts,
            debtAmounts,
            address(strategyCBALRETH));
        vm.stopPrank();

        assertApproxEqRel(
            strategyCBALRETH.balanceOf(user1),
            _ONE - (500e18 * _ONE) / balRETHPrice,
            0.02e18
        );
        assertEq(strategyCBALRETH.exchangeRate(), _ONE);

        assertEq(borrowableCDAI.balanceOf(user1), 0);
        assertApproxEqRel(borrowableCDAI.debtBalance(user1), 750e18, 0.01e18);
        assertApproxEqRel(borrowableCDAI.exchangeRate(), _ONE, 0.01e18);
    }

    function testLiquidation() public {
        _prepareBALRETH(user1, _ONE);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.deposit(_ONE, user1);
        strategyCBALRETH.postCollateral(_ONE);

        // try borrow()
        borrowableCDAI.borrow(1000e18);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);

        (uint256 balRETHPrice, ) = oracleManager.getPrice(
            address(balRETH),
            true,
            true
        );

        mockDaiFeed.setMockAnswer(1.5e8);

        // try liquidate
        _prepareDAI(user2, 10_000e18);
        vm.startPrank(user2);
        dai.approve(address(borrowableCDAI), 10_000e18);
        address[] memory accounts = new address[](1);
        accounts[0] = user1;

        borrowableCDAI.liquidate(
            accounts,
            address(strategyCBALRETH));
    
        vm.stopPrank();

        assertApproxEqRel(
            strategyCBALRETH.balanceOf(user1),
            _ONE - (1550e18 * _ONE) / balRETHPrice,
            0.06e18
        );
        assertEq(strategyCBALRETH.exchangeRate(), _ONE);

        assertEq(borrowableCDAI.balanceOf(user1), 0);
        assertEq(borrowableCDAI.debtBalance(user1), 0);
        assertApproxEqRel(borrowableCDAI.exchangeRate(), _ONE, 0.01e18);
    }

    function testLiquidationWithFullValueLoss() public {
        _prepareBALRETH(user1, _ONE);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.deposit(_ONE, user1);
        strategyCBALRETH.postCollateral(_ONE);

        // try borrow()
        borrowableCDAI.borrow(1000e18);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);

        mockDaiFeed.setMockAnswer(10e8);

        // try liquidate
        _prepareDAI(user2, 10_000e18);
        vm.startPrank(user2);
        dai.approve(address(borrowableCDAI), 10_000e18);
        address[] memory accounts = new address[](1);
        accounts[0] = user1;
        borrowableCDAI.liquidate(
            accounts,
            address(strategyCBALRETH));
        vm.stopPrank();

        assertEq(strategyCBALRETH.balanceOf(user1), 0);
        assertEq(strategyCBALRETH.exchangeRate(), _ONE);

        assertEq(borrowableCDAI.balanceOf(user1), 0);
        assertApproxEqRel(borrowableCDAI.debtBalance(user1), 830e18, 0.01e18);
        assertApproxEqRel(borrowableCDAI.exchangeRate(), _ONE, 0.01e18);
    }

    function testSoftLiquidation() public {
        _prepareBALRETH(user1, _ONE);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.deposit(_ONE, user1);
        strategyCBALRETH.postCollateral(_ONE);

        // try borrow()
        borrowableCDAI.borrow(1000e18);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);

        (uint256 balRETHPrice, ) = oracleManager.getPrice(
            address(balRETH),
            true,
            true
        );

        uint256 debtBalance = borrowableCDAI.debtBalanceUpdated(user1);

        uint256 daiPrice = ((balRETHPrice * 1e8 * 1e18) / debtBalance) /
            1.4e18 +
            1;

        mockDaiFeed.setMockAnswer(int256(daiPrice));

        // try liquidate
        _prepareDAI(user2, 1000e18);
        vm.startPrank(user2);
        dai.approve(address(borrowableCDAI), 1000e18);

        address[] memory accounts = new address[](1);
        accounts[0] = user1;

        borrowableCDAI.liquidate(
            accounts,
            address(strategyCBALRETH));
        vm.stopPrank();

        assertApproxEqRel(
            strategyCBALRETH.balanceOf(user1),
            _ONE - (daiPrice * 1e10 * _ONE) / balRETHPrice,
            0.08e18
        );
        assertEq(strategyCBALRETH.exchangeRate(), _ONE);

        assertEq(borrowableCDAI.balanceOf(user1), 0);
        assertApproxEqRel(borrowableCDAI.debtBalance(user1), 900e18, 0.01e18);
        assertApproxEqRel(borrowableCDAI.exchangeRate(), _ONE, 0.01e18);
    }

    function testRevertBorrowAndLiquidateWithZeroCollRatio() public {
        _deployStrategyCBALRETH();

        balRETH.approve(address(strategyCBALRETH), _ONE);
        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCDAI));

        oracleManager.addCTokenSupport(address(strategyCBALRETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(strategyCBALRETH);
        tokenConfig.collRatio = 0;
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.minEffectiveCloseFactor = 2000;
        tokenConfig.maxEffectiveCloseFactor = 5000;
        tokenConfig.baseCFactor = 1000;
        tokenConfig.collateralCap = 0;
        tokenConfig.debtCap = 0;

        marketManagerIsolated.updateTokenConfig(tokenConfig);

        tokenConfig.cToken = address(borrowableCDAI);
        tokenConfig.collRatio = 7000;
        tokenConfig.collateralCap = 100_000e18;
        tokenConfig.debtCap = 100_000e18;
        
        marketManagerIsolated.updateTokenConfig(tokenConfig);

        _prepareBALRETH(user1, _ONE);

        // try mint()
        vm.startPrank(user1);

        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.deposit(_ONE, user1);

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__CapReached.selector
        );
        strategyCBALRETH.postCollateral(_ONE);

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral.selector
        );
        borrowableCDAI.borrow(1000e18);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);

        mockDaiFeed.setMockAnswer(1.5e8);

        // try liquidate
        _prepareDAI(user2, 10_000e18);
        vm.startPrank(user2);
        dai.approve(address(borrowableCDAI), 10_000e18);

        address[] memory accounts = new address[](1);
        accounts[0] = user1;

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InvalidParameter.selector
        );
        borrowableCDAI.liquidate(
            accounts,
            address(strategyCBALRETH));
        vm.stopPrank();

        vm.prank(user1);
        strategyCBALRETH.withdraw(_ONE, user1, user1);
    }
}
