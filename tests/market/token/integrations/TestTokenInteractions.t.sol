// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { LiquidityManager } from "contracts/market/LiquidityManager.sol";
import { IMToken } from "contracts/interfaces/IMToken.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";

import "tests/market/TestBaseMarket.sol";

contract TestTokenInteractions is TestBaseMarket {
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
        vm.warp(gaugeManager.startTime());
        vm.roll(block.number + 1000);

        mockDaiFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);

        (, int256 ethPrice, , , ) = mockWethFeed.latestRoundData();
        chainlinkEthUsd.updateAnswer(ethPrice);

        // setup eDAI
        {
            _prepareDAI(owner, 200_000e18);
            dai.approve(address(eDAI), 200_000e18);
            marketManager.listToken(address(eDAI));
            // add MToken support on oracle manager
            oracleManager.addMTokenSupport(address(eDAI));
        }

        // setup pBALRETH
        {
            // support market
            _prepareBALRETH(owner, _ONE);
            balRETH.approve(address(pBALRETH), _ONE);
            marketManager.listToken(address(pBALRETH));
            // set collateral factor
            marketManager.updatePositionToken(
                IMToken(address(pBALRETH)),
                7000,
                4000,
                3000,
                200,
                400,
                10,
                1000
            );
            address[] memory tokens = new address[](1);
            tokens[0] = address(pBALRETH);
            uint256[] memory caps = new uint256[](1);
            caps[0] = 100_000e18;
            marketManager.setPTokenCollateralCaps(tokens, caps);
        }

        // provide enough liquidity
        provideEnoughLiquidityForLeverage();
    }

    function provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareDAI(liquidityProvider, 200_000e18);
        _prepareBALRETH(liquidityProvider, 10e18);
        // mint eDAI
        vm.startPrank(liquidityProvider);
        dai.approve(address(eDAI), 200_000e18);
        eDAI.mint(200_000e18);
        // mint cBALETH
        balRETH.approve(address(pBALRETH), 10e18);
        pBALRETH.deposit(10e18, liquidityProvider);
        vm.stopPrank();
    }

    function testInitialize() public view {
        assertTrue(pBALRETH.isPToken());
        assertFalse(eDAI.isPToken());
    }

    function testPTokenMintRedeem() public {
        _prepareBALRETH(user1, 2e18);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), _ONE);
        pBALRETH.deposit(_ONE, user1);
        assertEq(pBALRETH.balanceOf(user1), _ONE);

        // try mintFor()
        balRETH.approve(address(pBALRETH), _ONE);
        pBALRETH.deposit(_ONE, user2);
        assertEq(pBALRETH.balanceOf(user1), _ONE);
        assertEq(pBALRETH.balanceOf(user2), _ONE);

        // try redeem()
        pBALRETH.redeem(_ONE, user1, user1);
        vm.stopPrank();
        assertEq(pBALRETH.balanceOf(user1), 0);
    }

    function testETokenMintRedeem() public {
        _prepareDAI(user1, 2e18);

        // try mint()
        vm.startPrank(user1);
        dai.approve(address(eDAI), _ONE);
        eDAI.mint(_ONE);
        assertEq(eDAI.balanceOf(user1), _ONE);

        // try mintFor()
        dai.approve(address(eDAI), _ONE);
        eDAI.mintFor(_ONE, user2);
        assertEq(eDAI.balanceOf(user1), _ONE);
        assertEq(eDAI.balanceOf(user2), _ONE);

        // try redeem()
        eDAI.redeem(_ONE, address(this));
        vm.stopPrank();
        assertEq(eDAI.balanceOf(user1), 0);
    }

    function testETokenBorrowRepay() public {
        _prepareBALRETH(user1, _ONE);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), _ONE);
        pBALRETH.deposit(_ONE, user1);
        marketManager.postCollateral(user1, address(pBALRETH), _ONE);

        assertEq(pBALRETH.balanceOf(user1), _ONE);
        assertEq(pBALRETH.exchangeRateCached(), _ONE);

        uint256 priceDecimals = mockDaiFeed.decimals();
        (, int256 daiPrice, , , ) = mockDaiFeed.latestRoundData();

        uint256 minimumBorrowAmount = (marketManager.MIN_ACTIVE_LOAN_SIZE() *
            (10 ** priceDecimals)) / uint256(daiPrice);

        // try borrow() with insufficient loan size
        vm.expectRevert(
            LiquidityManager.LiquidityManager__InsufficientLoanSize.selector
        );
        eDAI.borrow(minimumBorrowAmount - 1);

        // try borrow()
        eDAI.borrow(minimumBorrowAmount);

        assertEq(eDAI.balanceOf(user1), 0);
        assertEq(eDAI.debtBalanceCached(user1), minimumBorrowAmount);
        assertEq(eDAI.exchangeRateCached(), _ONE);

        // try borrow()
        skip(1200);
        eDAI.borrow(100e18);

        assertEq(eDAI.balanceOf(user1), 0);
        assertGt(eDAI.debtBalanceCached(user1), minimumBorrowAmount + 100e18);
        assertGt(eDAI.exchangeRateCached(), _ONE);

        // skip min hold period
        skip(20 minutes);

        // try partial repay
        uint256 borrowBalanceBefore = eDAI.debtBalanceCached(user1);
        uint256 exchangeRateBefore = eDAI.exchangeRateCached();
        _prepareDAI(user1, 20e18);
        dai.approve(address(eDAI), 20e18);
        eDAI.repay(20e18);

        assertEq(eDAI.balanceOf(user1), 0);
        assertGt(eDAI.debtBalanceCached(user1), borrowBalanceBefore - 20e18);
        assertGt(eDAI.exchangeRateCached(), exchangeRateBefore);

        // skip some period
        skip(1200);

        // try repay full
        borrowBalanceBefore = eDAI.debtBalanceCached(user1);
        exchangeRateBefore = eDAI.exchangeRateCached();
        _prepareDAI(user1, borrowBalanceBefore);
        dai.approve(address(eDAI), borrowBalanceBefore);
        eDAI.repay(borrowBalanceBefore);
        vm.stopPrank();

        assertEq(eDAI.balanceOf(user1), 0);
        assertGt(eDAI.debtBalanceCached(user1), 0);
        assertGt(eDAI.exchangeRateCached(), exchangeRateBefore);
    }

    function testPTokenRedeemOnBorrow() public {
        _prepareBALRETH(user1, _ONE);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), _ONE);
        pBALRETH.deposit(_ONE, user1);
        marketManager.postCollateral(user1, address(pBALRETH), _ONE);

        // try borrow()
        eDAI.borrow(500e18);

        // skip min hold period
        skip(20 minutes);

        // can't redeem full
        vm.expectRevert(
            bytes4(keccak256("MarketManager__InsufficientCollateral()"))
        );
        pBALRETH.redeem(_ONE, user1, user1);

        // can redeem partially
        pBALRETH.redeem(0.2e18, user1, user1);
        vm.stopPrank();

        assertEq(pBALRETH.balanceOf(user1), 0.8e18);
        assertEq(pBALRETH.exchangeRateCached(), _ONE);
    }

    function testETokenRedeemOnBorrow() public {
        // try mint()
        _prepareBALRETH(user1, _ONE);
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), _ONE);
        pBALRETH.deposit(_ONE, user1);
        marketManager.postCollateral(user1, address(pBALRETH), _ONE);

        // try mint()
        _prepareDAI(user1, 1000e18);
        dai.approve(address(eDAI), 1000e18);
        eDAI.mint(1000e18);

        // try borrow()
        eDAI.borrow(500e18);

        // fail to redeem before minimum hold time pass
        vm.expectRevert(
            MarketManager.MarketManager__MinimumHoldPeriod.selector
        );
        eDAI.redeem(1000e18, address(this));

        // skip min hold period
        skip(20 minutes);

        // can redeem fully
        eDAI.redeem(1000e18, address(this));
        vm.stopPrank();

        assertEq(pBALRETH.balanceOf(user1), _ONE);
        assertEq(pBALRETH.exchangeRateCached(), _ONE);

        assertEq(eDAI.balanceOf(user1), 0);
        assertGt(eDAI.debtBalanceCached(user1), 500e18);
        assertGt(eDAI.exchangeRateCached(), _ONE);
    }

    function testPTokenTransferOnBorrow() public {
        _prepareBALRETH(user1, _ONE);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), _ONE);
        pBALRETH.deposit(_ONE, user1);
        marketManager.postCollateral(user1, address(pBALRETH), _ONE);

        // try borrow()
        eDAI.borrow(500e18);

        // skip min hold period
        skip(20 minutes);

        // can't transfer full
        vm.expectRevert(
            bytes4(keccak256("MarketManager__InsufficientCollateral()"))
        );
        pBALRETH.transfer(user2, _ONE);

        // can redeem partially
        pBALRETH.transfer(user2, 0.2e18);
        vm.stopPrank();

        assertEq(pBALRETH.balanceOf(user1), 0.8e18);
        assertEq(pBALRETH.balanceOf(user2), 0.2e18);
        assertEq(pBALRETH.exchangeRateCached(), _ONE);
    }

    function testETokenTransferOnBorrow() public {
        // try mint()
        _prepareBALRETH(user1, _ONE);
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), _ONE);
        pBALRETH.deposit(_ONE, user1);
        marketManager.postCollateral(user1, address(pBALRETH), _ONE);

        // try mint()
        _prepareDAI(user1, 1000e18);
        dai.approve(address(eDAI), 1000e18);
        eDAI.mint(1000e18);

        // try borrow()
        eDAI.borrow(500e18);

        // skip min hold period
        skip(20 minutes);

        // try full transfer
        eDAI.transfer(user2, 1000e18);
        vm.stopPrank();

        assertEq(pBALRETH.balanceOf(user1), _ONE);
        assertEq(pBALRETH.exchangeRateCached(), _ONE);

        assertEq(eDAI.balanceOf(user1), 0);
        assertEq(eDAI.debtBalanceCached(user1), 500e18);

        assertEq(eDAI.balanceOf(user2), 1000e18);
        assertEq(eDAI.debtBalanceCached(user2), 0e18);
        assertEq(eDAI.exchangeRateCached(), _ONE);
    }

    function testLiquidationExact() public {
        _prepareBALRETH(user1, _ONE);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), _ONE);
        pBALRETH.deposit(_ONE, user1);
        marketManager.postCollateral(user1, address(pBALRETH), _ONE);

        // try borrow()
        eDAI.borrow(1000e18);
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
        dai.approve(address(eDAI), 250e18);
        eDAI.liquidateExact(user1, 250e18, IMToken(address(pBALRETH)));
        vm.stopPrank();

        assertApproxEqRel(
            pBALRETH.balanceOf(user1),
            _ONE - (500e18 * _ONE) / balRETHPrice,
            0.02e18
        );
        assertEq(pBALRETH.exchangeRateCached(), _ONE);

        assertEq(eDAI.balanceOf(user1), 0);
        assertApproxEqRel(eDAI.debtBalanceCached(user1), 750e18, 0.01e18);
        assertApproxEqRel(eDAI.exchangeRateCached(), _ONE, 0.01e18);
    }

    function testLiquidation() public {
        _prepareBALRETH(user1, _ONE);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), _ONE);
        pBALRETH.deposit(_ONE, user1);
        marketManager.postCollateral(user1, address(pBALRETH), _ONE);

        // try borrow()
        eDAI.borrow(1000e18);
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
        dai.approve(address(eDAI), 10_000e18);
        eDAI.liquidate(user1, IMToken(address(pBALRETH)));
        vm.stopPrank();

        assertApproxEqRel(
            pBALRETH.balanceOf(user1),
            _ONE - (1550e18 * _ONE) / balRETHPrice,
            0.06e18
        );
        assertEq(pBALRETH.exchangeRateCached(), _ONE);

        assertEq(eDAI.balanceOf(user1), 0);
        assertEq(eDAI.debtBalanceCached(user1), 0);
        assertApproxEqRel(eDAI.exchangeRateCached(), _ONE, 0.01e18);
    }

    function testLiquidationWithFullValueLoss() public {
        _prepareBALRETH(user1, _ONE);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), _ONE);
        pBALRETH.deposit(_ONE, user1);
        marketManager.postCollateral(user1, address(pBALRETH), _ONE);

        // try borrow()
        eDAI.borrow(1000e18);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);

        mockDaiFeed.setMockAnswer(10e8);

        // try liquidate
        _prepareDAI(user2, 10_000e18);
        vm.startPrank(user2);
        dai.approve(address(eDAI), 10_000e18);
        eDAI.liquidate(user1, IMToken(address(pBALRETH)));
        vm.stopPrank();

        assertEq(pBALRETH.balanceOf(user1), 0);
        assertEq(pBALRETH.exchangeRateCached(), _ONE);

        assertEq(eDAI.balanceOf(user1), 0);
        assertApproxEqRel(eDAI.debtBalanceCached(user1), 830e18, 0.01e18);
        assertApproxEqRel(eDAI.exchangeRateCached(), _ONE, 0.01e18);
    }

    function testSoftLiquidation() public {
        _prepareBALRETH(user1, _ONE);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), _ONE);
        pBALRETH.deposit(_ONE, user1);
        marketManager.postCollateral(user1, address(pBALRETH), _ONE);

        // try borrow()
        eDAI.borrow(1000e18);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);

        (uint256 balRETHPrice, ) = oracleManager.getPrice(
            address(balRETH),
            true,
            true
        );

        uint256 debtBalance = eDAI.debtBalanceWithUpdateSafe(user1);

        uint256 daiPrice = ((balRETHPrice * 1e8 * 1e18) / debtBalance) /
            1.4e18 +
            1;

        mockDaiFeed.setMockAnswer(int256(daiPrice));

        // try liquidate
        _prepareDAI(user2, 1000e18);
        vm.startPrank(user2);
        dai.approve(address(eDAI), 1000e18);
        eDAI.liquidate(user1, IMToken(address(pBALRETH)));
        vm.stopPrank();

        assertApproxEqRel(
            pBALRETH.balanceOf(user1),
            _ONE - (daiPrice * 1e10 * _ONE) / balRETHPrice,
            0.08e18
        );
        assertEq(pBALRETH.exchangeRateCached(), _ONE);

        assertEq(eDAI.balanceOf(user1), 0);
        assertApproxEqRel(eDAI.debtBalanceCached(user1), 900e18, 0.01e18);
        assertApproxEqRel(eDAI.exchangeRateCached(), _ONE, 0.01e18);
    }

    function testRevertBorrowAndLiquidateWithZeroCollRatio() public {
        _deployPBALRETH();

        balRETH.approve(address(pBALRETH), _ONE);
        marketManager.listToken(address(pBALRETH));

        oracleManager.addMTokenSupport(address(pBALRETH));

        // set collateral factor
        marketManager.updatePositionToken(
            IMToken(address(pBALRETH)),
            0,
            4000,
            3000,
            200,
            400,
            10,
            1000
        );

        _prepareBALRETH(user1, _ONE);

        // try mint()
        vm.startPrank(user1);

        balRETH.approve(address(pBALRETH), _ONE);
        pBALRETH.deposit(_ONE, user1);

        vm.expectRevert(
            MarketManager.MarketManager__CollateralCapReached.selector
        );
        marketManager.postCollateral(user1, address(pBALRETH), _ONE);

        vm.expectRevert(
            MarketManager.MarketManager__InsufficientCollateral.selector
        );
        eDAI.borrow(1000e18);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);

        mockDaiFeed.setMockAnswer(1.5e8);

        // try liquidate
        _prepareDAI(user2, 10_000e18);
        vm.startPrank(user2);
        dai.approve(address(eDAI), 10_000e18);
        vm.expectRevert(
            MarketManager.MarketManager__InvalidParameter.selector
        );
        eDAI.liquidate(user1, IMToken(address(pBALRETH)));
        vm.stopPrank();

        vm.prank(user1);
        pBALRETH.withdraw(_ONE, user1, user1);
    }
}
