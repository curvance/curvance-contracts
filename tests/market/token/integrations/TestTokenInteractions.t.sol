// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { IMToken } from "contracts/interfaces/market/IMToken.sol";
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
            _prepareDAI(owner, 200000e18);
            dai.approve(address(eDAI), 200000e18);
            marketManager.listToken(address(eDAI));
            // add MToken support on oracle manager
            oracleManager.addMTokenSupport(address(eDAI));
        }

        // setup pBALRETH
        {
            // support market
            _prepareBALRETH(owner, 1 ether);
            balRETH.approve(address(pBALRETH), 1 ether);
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
        _prepareDAI(liquidityProvider, 200000e18);
        _prepareBALRETH(liquidityProvider, 10 ether);
        // mint eDAI
        vm.startPrank(liquidityProvider);
        dai.approve(address(eDAI), 200000 ether);
        eDAI.mint(200000 ether);
        // mint cBALETH
        balRETH.approve(address(pBALRETH), 10 ether);
        pBALRETH.deposit(10 ether, liquidityProvider);
        vm.stopPrank();
    }

    function testInitialize() public {
        assertTrue(pBALRETH.isPToken());
        assertFalse(eDAI.isPToken());
    }

    function testPTokenMintRedeem() public {
        _prepareBALRETH(user1, 2 ether);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1 ether);
        pBALRETH.deposit(1 ether, user1);
        assertEq(pBALRETH.balanceOf(user1), 1 ether);

        // try mintFor()
        balRETH.approve(address(pBALRETH), 1 ether);
        pBALRETH.deposit(1 ether, user2);
        assertEq(pBALRETH.balanceOf(user1), 1 ether);
        assertEq(pBALRETH.balanceOf(user2), 1 ether);

        // try redeem()
        pBALRETH.redeem(1 ether, user1, user1);
        vm.stopPrank();
        assertEq(pBALRETH.balanceOf(user1), 0);
    }

    function testETokenMintRedeem() public {
        _prepareDAI(user1, 2 ether);

        // try mint()
        vm.startPrank(user1);
        dai.approve(address(eDAI), 1 ether);
        eDAI.mint(1 ether);
        assertEq(eDAI.balanceOf(user1), 1 ether);

        // try mintFor()
        dai.approve(address(eDAI), 1 ether);
        eDAI.mintFor(1 ether, user2);
        assertEq(eDAI.balanceOf(user1), 1 ether);
        assertEq(eDAI.balanceOf(user2), 1 ether);

        // try redeem()
        eDAI.redeem(1 ether);
        vm.stopPrank();
        assertEq(eDAI.balanceOf(user1), 0);
    }

    function testETokenBorrowRepay() public {
        _prepareBALRETH(user1, 1 ether);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1 ether);
        pBALRETH.deposit(1 ether, user1);
        marketManager.postCollateral(user1, address(pBALRETH), 1 ether);

        assertEq(pBALRETH.balanceOf(user1), 1 ether);
        assertEq(pBALRETH.exchangeRateCached(), 1 ether);

        // try borrow()
        eDAI.borrow(500 ether);

        assertEq(eDAI.balanceOf(user1), 0);
        assertEq(eDAI.debtBalanceCached(user1), 500 ether);
        assertEq(eDAI.exchangeRateCached(), 1 ether);

        // try borrow()
        skip(1200);
        eDAI.borrow(100 ether);

        assertEq(eDAI.balanceOf(user1), 0);
        assertGt(eDAI.debtBalanceCached(user1), 600 ether);
        assertGt(eDAI.exchangeRateCached(), 1 ether);

        // skip min hold period
        skip(20 minutes);

        // try partial repay
        uint256 borrowBalanceBefore = eDAI.debtBalanceCached(user1);
        uint256 exchangeRateBefore = eDAI.exchangeRateCached();
        _prepareDAI(user1, 200 ether);
        dai.approve(address(eDAI), 200 ether);
        eDAI.repay(200 ether);

        assertEq(eDAI.balanceOf(user1), 0);
        assertGt(
            eDAI.debtBalanceCached(user1),
            borrowBalanceBefore - 200 ether
        );
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
        _prepareBALRETH(user1, 1 ether);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1 ether);
        pBALRETH.deposit(1 ether, user1);
        marketManager.postCollateral(user1, address(pBALRETH), 1 ether);

        // try borrow()
        eDAI.borrow(500 ether);

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
        assertEq(pBALRETH.exchangeRateCached(), 1 ether);
    }

    function testETokenRedeemOnBorrow() public {
        // try mint()
        _prepareBALRETH(user1, 1 ether);
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1 ether);
        pBALRETH.deposit(1 ether, user1);
        marketManager.postCollateral(user1, address(pBALRETH), 1 ether);

        // try mint()
        _prepareDAI(user1, 1000 ether);
        dai.approve(address(eDAI), 1000 ether);
        eDAI.mint(1000 ether);

        // try borrow()
        eDAI.borrow(500 ether);

        // fail to redeem before minimum hold time pass
        vm.expectRevert(
            MarketManager.MarketManager__MinimumHoldPeriod.selector
        );
        eDAI.redeem(1000 ether);

        // skip min hold period
        skip(20 minutes);

        // can redeem fully
        eDAI.redeem(1000 ether);
        vm.stopPrank();

        assertEq(pBALRETH.balanceOf(user1), 1 ether);
        assertEq(pBALRETH.exchangeRateCached(), 1 ether);

        assertEq(eDAI.balanceOf(user1), 0);
        assertGt(eDAI.debtBalanceCached(user1), 500 ether);
        assertGt(eDAI.exchangeRateCached(), 1 ether);
    }

    function testPTokenTransferOnBorrow() public {
        _prepareBALRETH(user1, 1 ether);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1 ether);
        pBALRETH.deposit(1 ether, user1);
        marketManager.postCollateral(user1, address(pBALRETH), 1 ether);

        // try borrow()
        eDAI.borrow(500 ether);

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
        assertEq(pBALRETH.exchangeRateCached(), 1 ether);
    }

    function testETokenTransferOnBorrow() public {
        // try mint()
        _prepareBALRETH(user1, 1 ether);
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1 ether);
        pBALRETH.deposit(1 ether, user1);
        marketManager.postCollateral(user1, address(pBALRETH), 1 ether);

        // try mint()
        _prepareDAI(user1, 1000 ether);
        dai.approve(address(eDAI), 1000 ether);
        eDAI.mint(1000 ether);

        // try borrow()
        eDAI.borrow(500 ether);

        // skip min hold period
        skip(20 minutes);

        // try full transfer
        eDAI.transfer(user2, 1000 ether);
        vm.stopPrank();

        assertEq(pBALRETH.balanceOf(user1), 1 ether);
        assertEq(pBALRETH.exchangeRateCached(), 1 ether);

        assertEq(eDAI.balanceOf(user1), 0);
        assertEq(eDAI.debtBalanceCached(user1), 500 ether);

        assertEq(eDAI.balanceOf(user2), 1000 ether);
        assertEq(eDAI.debtBalanceCached(user2), 0 ether);
        assertEq(eDAI.exchangeRateCached(), 1 ether);
    }

    function testLiquidationExact() public {
        _prepareBALRETH(user1, 1 ether);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1 ether);
        pBALRETH.deposit(1 ether, user1);
        marketManager.postCollateral(user1, address(pBALRETH), 1 ether);

        // try borrow()
        eDAI.borrow(1000 ether);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);

        (uint256 balRETHPrice, ) = oracleManager.getPrice(
            address(balRETH),
            true,
            true
        );

        mockDaiFeed.setMockAnswer(200000000);

        // try liquidate half
        _prepareDAI(user2, 250 ether);
        vm.startPrank(user2);
        dai.approve(address(eDAI), 250 ether);
        eDAI.liquidateExact(user1, 250 ether, IMToken(address(pBALRETH)));
        vm.stopPrank();

        assertApproxEqRel(
            pBALRETH.balanceOf(user1),
            1 ether - (500 ether * 1 ether) / balRETHPrice,
            0.02e18
        );
        assertEq(pBALRETH.exchangeRateCached(), 1 ether);

        assertEq(eDAI.balanceOf(user1), 0);
        assertApproxEqRel(eDAI.debtBalanceCached(user1), 750 ether, 0.01e18);
        assertApproxEqRel(eDAI.exchangeRateCached(), 1 ether, 0.01e18);
    }

    function testLiquidation1() public {
        _prepareBALRETH(user1, 1 ether);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1 ether);
        pBALRETH.deposit(1 ether, user1);
        marketManager.postCollateral(user1, address(pBALRETH), 1 ether);

        // try borrow()
        eDAI.borrow(1000 ether);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);

        (uint256 balRETHPrice, ) = oracleManager.getPrice(
            address(balRETH),
            true,
            true
        );

        mockDaiFeed.setMockAnswer(150000000);

        // try liquidate
        _prepareDAI(user2, 10000 ether);
        vm.startPrank(user2);
        dai.approve(address(eDAI), 10000 ether);
        eDAI.liquidate(user1, IMToken(address(pBALRETH)));
        vm.stopPrank();

        assertApproxEqRel(
            pBALRETH.balanceOf(user1),
            1 ether - (1550 ether * 1 ether) / balRETHPrice,
            0.06e18
        );
        assertEq(pBALRETH.exchangeRateCached(), 1 ether);

        assertEq(eDAI.balanceOf(user1), 0);
        assertEq(eDAI.debtBalanceCached(user1), 0);
        assertApproxEqRel(eDAI.exchangeRateCached(), 1 ether, 0.01e18);
    }

    function testRevertBorrowAndLiquidateWithZeroCollRatio() public {
        _deployPBALRETH();

        balRETH.approve(address(pBALRETH), 1 ether);
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

        _prepareBALRETH(user1, 1 ether);

        // try mint()
        vm.startPrank(user1);

        balRETH.approve(address(pBALRETH), 1 ether);
        pBALRETH.deposit(1 ether, user1);

        vm.expectRevert(
            MarketManager.MarketManager__CollateralCapReached.selector
        );
        marketManager.postCollateral(user1, address(pBALRETH), 1 ether);

        vm.expectRevert(
            MarketManager.MarketManager__InsufficientCollateral.selector
        );
        eDAI.borrow(1000 ether);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);

        mockDaiFeed.setMockAnswer(150000000);

        // try liquidate
        _prepareDAI(user2, 10000 ether);
        vm.startPrank(user2);
        dai.approve(address(eDAI), 10000 ether);
        vm.expectRevert(
            MarketManager.MarketManager__InvalidParameter.selector
        );
        eDAI.liquidate(user1, IMToken(address(pBALRETH)));
        vm.stopPrank();

        vm.prank(user1);
        pBALRETH.withdraw(1 ether, user1, user1);
    }
}
