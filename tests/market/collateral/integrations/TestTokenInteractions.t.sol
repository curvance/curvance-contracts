// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { IMToken } from "contracts/interfaces/market/IMToken.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";

import "tests/market/TestBaseMarket.sol";

contract TestTokenInteractions is TestBaseMarket {
    address public owner;

    receive() external payable {}

    fallback() external payable {}

    MockDataFeed public mockDaiFeed;
    MockDataFeed public mockWethFeed;
    MockDataFeed public mockRethFeed;

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

        // setup dDAI
        {
            _prepareDAI(owner, 200000e18);
            dai.approve(address(dDAI), 200000e18);
            marketManager.listToken(address(dDAI));
            // add MToken support on price router
            oracleRouter.addMTokenSupport(address(dDAI));
        }

        // setup CBALRETH
        {
            // support market
            _prepareBALRETH(owner, 1 ether);
            balRETH.approve(address(cBALRETH), 1 ether);
            marketManager.listToken(address(cBALRETH));
            // set collateral factor
            marketManager.updateCollateralToken(
                IMToken(address(cBALRETH)),
                7000,
                4000,
                3000,
                200,
                400,
                10,
                1000
            );
            address[] memory tokens = new address[](1);
            tokens[0] = address(cBALRETH);
            uint256[] memory caps = new uint256[](1);
            caps[0] = 100_000e18;
            marketManager.setCTokenCollateralCaps(tokens, caps);
        }

        // provide enough liquidity
        provideEnoughLiquidityForLeverage();
    }

    function provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareDAI(liquidityProvider, 200000e18);
        _prepareBALRETH(liquidityProvider, 10 ether);
        // mint dDAI
        vm.startPrank(liquidityProvider);
        dai.approve(address(dDAI), 200000 ether);
        dDAI.mint(200000 ether);
        // mint cBALETH
        balRETH.approve(address(cBALRETH), 10 ether);
        cBALRETH.deposit(10 ether, liquidityProvider);
        vm.stopPrank();
    }

    function testInitialize() public {
        assertEq(cBALRETH.isCToken(), true);
        assertEq(dDAI.isCToken(), false);
    }

    function testCTokenMintRedeem() public {
        _prepareBALRETH(user1, 2 ether);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(cBALRETH), 1 ether);
        cBALRETH.deposit(1 ether, user1);
        assertEq(cBALRETH.balanceOf(user1), 1 ether);

        // try mintFor()
        balRETH.approve(address(cBALRETH), 1 ether);
        cBALRETH.deposit(1 ether, user2);
        assertEq(cBALRETH.balanceOf(user1), 1 ether);
        assertEq(cBALRETH.balanceOf(user2), 1 ether);

        // try redeem()
        cBALRETH.redeem(1 ether, user1, user1);
        vm.stopPrank();
        assertEq(cBALRETH.balanceOf(user1), 0);
    }

    function testDTokenMintRedeem() public {
        _prepareDAI(user1, 2 ether);

        // try mint()
        vm.startPrank(user1);
        dai.approve(address(dDAI), 1 ether);
        dDAI.mint(1 ether);
        assertEq(dDAI.balanceOf(user1), 1 ether);

        // try mintFor()
        dai.approve(address(dDAI), 1 ether);
        dDAI.mintFor(1 ether, user2);
        assertEq(dDAI.balanceOf(user1), 1 ether);
        assertEq(dDAI.balanceOf(user2), 1 ether);

        // try redeem()
        dDAI.redeem(1 ether);
        vm.stopPrank();
        assertEq(dDAI.balanceOf(user1), 0);
    }

    function testDTokenBorrowRepay() public {
        _prepareBALRETH(user1, 1 ether);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(cBALRETH), 1 ether);
        cBALRETH.deposit(1 ether, user1);
        marketManager.postCollateral(user1, address(cBALRETH), 1 ether);

        assertEq(cBALRETH.balanceOf(user1), 1 ether);
        assertEq(cBALRETH.exchangeRateCached(), 1 ether);

        // try borrow()
        dDAI.borrow(500 ether);

        assertEq(dDAI.balanceOf(user1), 0);
        assertEq(dDAI.debtBalanceCached(user1), 500 ether);
        assertEq(dDAI.exchangeRateCached(), 1 ether);

        // try borrow()
        skip(1200);
        dDAI.borrow(100 ether);

        assertEq(dDAI.balanceOf(user1), 0);
        assertGt(dDAI.debtBalanceCached(user1), 600 ether);
        assertGt(dDAI.exchangeRateCached(), 1 ether);

        // skip min hold period
        skip(20 minutes);

        // try partial repay
        uint256 borrowBalanceBefore = dDAI.debtBalanceCached(user1);
        uint256 exchangeRateBefore = dDAI.exchangeRateCached();
        _prepareDAI(user1, 200 ether);
        dai.approve(address(dDAI), 200 ether);
        dDAI.repay(200 ether);

        assertEq(dDAI.balanceOf(user1), 0);
        assertGt(
            dDAI.debtBalanceCached(user1),
            borrowBalanceBefore - 200 ether
        );
        assertGt(dDAI.exchangeRateCached(), exchangeRateBefore);

        // skip some period
        skip(1200);

        // try repay full
        borrowBalanceBefore = dDAI.debtBalanceCached(user1);
        exchangeRateBefore = dDAI.exchangeRateCached();
        _prepareDAI(user1, borrowBalanceBefore);
        dai.approve(address(dDAI), borrowBalanceBefore);
        dDAI.repay(borrowBalanceBefore);
        vm.stopPrank();

        assertEq(dDAI.balanceOf(user1), 0);
        assertGt(dDAI.debtBalanceCached(user1), 0);
        assertGt(dDAI.exchangeRateCached(), exchangeRateBefore);
    }

    function testCTokenRedeemOnBorrow() public {
        _prepareBALRETH(user1, 1 ether);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(cBALRETH), 1 ether);
        cBALRETH.deposit(1 ether, user1);
        marketManager.postCollateral(user1, address(cBALRETH), 1 ether);

        // try borrow()
        dDAI.borrow(500 ether);

        // skip min hold period
        skip(20 minutes);

        // can't redeem full
        vm.expectRevert(
            bytes4(keccak256("MarketManager__InsufficientCollateral()"))
        );
        cBALRETH.redeem(1 ether, user1, user1);

        // can redeem partially
        cBALRETH.redeem(0.2 ether, user1, user1);
        vm.stopPrank();

        assertEq(cBALRETH.balanceOf(user1), 0.8 ether);
        assertEq(cBALRETH.exchangeRateCached(), 1 ether);
    }

    function testDTokenRedeemOnBorrow() public {
        // try mint()
        _prepareBALRETH(user1, 1 ether);
        vm.startPrank(user1);
        balRETH.approve(address(cBALRETH), 1 ether);
        cBALRETH.deposit(1 ether, user1);
        marketManager.postCollateral(user1, address(cBALRETH), 1 ether);

        // try mint()
        _prepareDAI(user1, 1000 ether);
        dai.approve(address(dDAI), 1000 ether);
        dDAI.mint(1000 ether);

        // try borrow()
        dDAI.borrow(500 ether);

        // fail to redeem before minimum hold time pass
        vm.expectRevert(
            MarketManager.MarketManager__MinimumHoldPeriod.selector
        );
        dDAI.redeem(1000 ether);

        // skip min hold period
        skip(20 minutes);

        // can redeem fully
        dDAI.redeem(1000 ether);
        vm.stopPrank();

        assertEq(cBALRETH.balanceOf(user1), 1 ether);
        assertEq(cBALRETH.exchangeRateCached(), 1 ether);

        assertEq(dDAI.balanceOf(user1), 0);
        assertGt(dDAI.debtBalanceCached(user1), 500 ether);
        assertGt(dDAI.exchangeRateCached(), 1 ether);
    }

    function testCTokenTransferOnBorrow() public {
        _prepareBALRETH(user1, 1 ether);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(cBALRETH), 1 ether);
        cBALRETH.deposit(1 ether, user1);
        marketManager.postCollateral(user1, address(cBALRETH), 1 ether);

        // try borrow()
        dDAI.borrow(500 ether);

        // skip min hold period
        skip(20 minutes);

        // can't transfer full
        vm.expectRevert(
            bytes4(keccak256("MarketManager__InsufficientCollateral()"))
        );
        cBALRETH.transfer(user2, 1 ether);

        // can redeem partially
        cBALRETH.transfer(user2, 0.2 ether);
        vm.stopPrank();

        assertEq(cBALRETH.balanceOf(user1), 0.8 ether);
        assertEq(cBALRETH.balanceOf(user2), 0.2 ether);
        assertEq(cBALRETH.exchangeRateCached(), 1 ether);
    }

    function testDTokenTransferOnBorrow() public {
        // try mint()
        _prepareBALRETH(user1, 1 ether);
        vm.startPrank(user1);
        balRETH.approve(address(cBALRETH), 1 ether);
        cBALRETH.deposit(1 ether, user1);
        marketManager.postCollateral(user1, address(cBALRETH), 1 ether);

        // try mint()
        _prepareDAI(user1, 1000 ether);
        dai.approve(address(dDAI), 1000 ether);
        dDAI.mint(1000 ether);

        // try borrow()
        dDAI.borrow(500 ether);

        // skip min hold period
        skip(20 minutes);

        // try full transfer
        dDAI.transfer(user2, 1000 ether);
        vm.stopPrank();

        assertEq(cBALRETH.balanceOf(user1), 1 ether);
        assertEq(cBALRETH.exchangeRateCached(), 1 ether);

        assertEq(dDAI.balanceOf(user1), 0);
        assertEq(dDAI.debtBalanceCached(user1), 500 ether);

        assertEq(dDAI.balanceOf(user2), 1000 ether);
        assertEq(dDAI.debtBalanceCached(user2), 0 ether);
        assertEq(dDAI.exchangeRateCached(), 1 ether);
    }

    function testLiquidationExact() public {
        _prepareBALRETH(user1, 1 ether);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(cBALRETH), 1 ether);
        cBALRETH.deposit(1 ether, user1);
        marketManager.postCollateral(user1, address(cBALRETH), 1 ether);

        // try borrow()
        dDAI.borrow(1000 ether);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);

        (uint256 balRETHPrice, ) = oracleRouter.getPrice(
            address(balRETH),
            true,
            true
        );

        mockDaiFeed.setMockAnswer(200000000);

        // try liquidate half
        _prepareDAI(user2, 250 ether);
        vm.startPrank(user2);
        dai.approve(address(dDAI), 250 ether);
        dDAI.liquidateExact(user1, 250 ether, IMToken(address(cBALRETH)));
        vm.stopPrank();

        assertApproxEqRel(
            cBALRETH.balanceOf(user1),
            1 ether - (500 ether * 1 ether) / balRETHPrice,
            0.02e18
        );
        assertEq(cBALRETH.exchangeRateCached(), 1 ether);

        assertEq(dDAI.balanceOf(user1), 0);
        assertApproxEqRel(dDAI.debtBalanceCached(user1), 750 ether, 0.01e18);
        assertApproxEqRel(dDAI.exchangeRateCached(), 1 ether, 0.01e18);
    }

    function testLiquidation1() public {
        _prepareBALRETH(user1, 1 ether);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(cBALRETH), 1 ether);
        cBALRETH.deposit(1 ether, user1);
        marketManager.postCollateral(user1, address(cBALRETH), 1 ether);

        // try borrow()
        dDAI.borrow(1000 ether);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);

        (uint256 balRETHPrice, ) = oracleRouter.getPrice(
            address(balRETH),
            true,
            true
        );

        mockDaiFeed.setMockAnswer(150000000);

        // try liquidate
        _prepareDAI(user2, 10000 ether);
        vm.startPrank(user2);
        dai.approve(address(dDAI), 10000 ether);
        dDAI.liquidate(user1, IMToken(address(cBALRETH)));
        vm.stopPrank();

        assertApproxEqRel(
            cBALRETH.balanceOf(user1),
            1 ether - (1550 ether * 1 ether) / balRETHPrice,
            0.06e18
        );
        assertEq(cBALRETH.exchangeRateCached(), 1 ether);

        assertEq(dDAI.balanceOf(user1), 0);
        assertEq(dDAI.debtBalanceCached(user1), 0);
        assertApproxEqRel(dDAI.exchangeRateCached(), 1 ether, 0.01e18);
    }

    function testRevertBorrowAndLiquidateWithZeroCollRatio() public {
        _deployCBALRETH();

        balRETH.approve(address(cBALRETH), 1 ether);
        marketManager.listToken(address(cBALRETH));

        oracleRouter.addMTokenSupport(address(cBALRETH));

        // set collateral factor
        marketManager.updateCollateralToken(
            IMToken(address(cBALRETH)),
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

        balRETH.approve(address(cBALRETH), 1 ether);
        cBALRETH.deposit(1 ether, user1);

        vm.expectRevert(
            MarketManager.MarketManager__CollateralCapReached.selector
        );
        marketManager.postCollateral(user1, address(cBALRETH), 1 ether);

        vm.expectRevert(
            MarketManager.MarketManager__InsufficientCollateral.selector
        );
        dDAI.borrow(1000 ether);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);

        mockDaiFeed.setMockAnswer(150000000);

        // try liquidate
        _prepareDAI(user2, 10000 ether);
        vm.startPrank(user2);
        dai.approve(address(dDAI), 10000 ether);
        vm.expectRevert(
            MarketManager.MarketManager__InvalidParameter.selector
        );
        dDAI.liquidate(user1, IMToken(address(cBALRETH)));
        vm.stopPrank();

        vm.prank(user1);
        cBALRETH.withdraw(1 ether, user1, user1);
    }
}
