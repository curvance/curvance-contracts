// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import "tests/market/TestBaseMarketIsolated.sol";

contract TestDynamicLiquidations is TestBaseMarketIsolated {
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

        // deploy eDAI
        {
            _prepareDAI(owner, 200000e18);
            dai.approve(address(borrowableCDAI), 200000e18);
            // Add cToken support on Oracle Manager.
            oracleManager.addCTokenSupport(address(borrowableCDAI));
        }

        // deploy PBALRETH
        {
            // support market
            _prepareBALRETH(owner, 1 ether);
            balRETH.approve(address(strategyCBALRETH), 1 ether);

        }

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCDAI));

        MarketManagerIsolated.TokenConfig memory tokenConfigs;
        tokenConfigs.cToken = address(strategyCBALRETH);
        tokenConfigs.collRatio = 7000;
        tokenConfigs.collReqSoft = 4000;
        tokenConfigs.collReqHard = 3000;
        tokenConfigs.liqIncBase = 1000;
        tokenConfigs.liqIncHard = 1500;
        tokenConfigs.liqIncMin = 500;
        tokenConfigs.liqIncMax = 2000;
        tokenConfigs.minEffectiveCloseFactor = 2000;
        tokenConfigs.maxEffectiveCloseFactor = 3000;
        tokenConfigs.baseCFactor = 1000;
        tokenConfigs.collateralCap = 100e8;
        tokenConfigs.debtCap = 0;

        marketManagerIsolated.updateTokenConfig(tokenConfigs);

        tokenConfigs.cToken = address(borrowableCDAI);
        tokenConfigs.debtCap = 100_000e6;

        marketManagerIsolated.updateTokenConfig(tokenConfigs);

        // provide enough liquidity
        provideEnoughLiquidityForLeverage();
    }

    function provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareDAI(liquidityProvider, 200000e18);
        _prepareBALRETH(liquidityProvider, 10 ether);
        // mint eDAI
        vm.startPrank(liquidityProvider);
        dai.approve(address(borrowableCDAI), 200000 ether);
        borrowableCDAI.mint(200000 ether, liquidityProvider);
        // mint cBALETH
        balRETH.approve(address(strategyCBALRETH), 10 ether);
        strategyCBALRETH.deposit(10 ether, liquidityProvider);
        vm.stopPrank();
    }

    // function testLiquidateRevertWhenBelowColReqA() public {
    //     _prepareBALRETH(user1, 1 ether);

    //     // try mint()
    //     vm.startPrank(user1);
    //     balRETH.approve(address(strategyCBALRETH), 1 ether);
    //     strategyCBALRETH.deposit(1 ether, user1);
    //     strategyCBALRETH.postCollateral(1 ether - 1);

    //     // try borrow()
    //     borrowableCDAI.borrow(1000 ether);
    //     vm.stopPrank();

    //     // skip min hold period
    //     skip(900);

    //     (uint256 balRETHPrice, ) = oracleManager.getPrice(
    //         address(balRETH),
    //         true,
    //         true
    //     );

    //     // adjust dai price, a bit lower than colReqA
    //     // 1000 dai > 1 strategyCBALRETH / colReqA
    //     mockDaiFeed.setMockAnswer(
    //         int256(
    //             (balRETHPrice * 1 ether * 1e8) / 1000 ether / 1.4 ether - 100
    //         )
    //     );

    //     vm.expectRevert(
    //         MarketManager.MarketManager__NoLiquidationAvailable.selector
    //     );

    //     address[] memory accounts = new address[](1);
    //     accounts[0] = user1;
    //     uint256[] memory debtAmounts = new uint256[](1);
    //     debtAmounts[0] = 250 ether;

    //     borrowableCDAI.liquidateExact(
    //         accounts,
    //         debtAmounts, 
    //         address(strategyCBALRETH));
    // }

    // function testLiquidateWorksWhenAboveColReqA() public {
    //     _prepareBALRETH(user1, 1 ether);

    //     // try mint()
    //     vm.startPrank(user1);
    //     balRETH.approve(address(strategyCBALRETH), 1 ether);
    //     strategyCBALRETH.deposit(1 ether, user1);
    //     strategyCBALRETH.postCollateral(1 ether - 1);

    //     // try borrow()
    //     borrowableCDAI.borrow(1000 ether);
    //     vm.stopPrank();

    //     // skip min hold period
    //     skip(20 minutes);

    //     (uint256 balRETHPrice, ) = oracleManager.getPrice(
    //         address(balRETH),
    //         true,
    //         true
    //     );

    //     mockDaiFeed.setMockAnswer(200000000);

    //     // try liquidate half
    //     _prepareDAI(user2, 250 ether);
    //     vm.startPrank(user2);
    //     dai.approve(address(borrowableCDAI), 250 ether);

    //     address[] memory accounts = new address[](1);
    //     accounts[0] = user1;
    //     uint256[] memory debtAmounts = new uint256[](1);
    //     debtAmounts[0] = 250 ether;
        
    //     borrowableCDAI.liquidateExact(
    //         accounts,
    //         debtAmounts,
    //         address(strategyCBALRETH)
    //     );
    //     vm.stopPrank();

    //     assertApproxEqRel(
    //         strategyCBALRETH.balanceOf(user1),
    //         1 ether - (500 ether * 1 ether) / balRETHPrice,
    //         0.02e18
    //     );
    //     assertEq(strategyCBALRETH.exchangeRateCached(), 1 ether);

    //     assertEq(borrowableCDAI.balanceOf(user1), 0);
    //     assertApproxEqRel(borrowableCDAI.debtBalance(user1), 750 ether, 0.01e18);
    //     assertApproxEqRel(borrowableCDAI.exchangeRateCached(), 1 ether, 0.01e18);
    // }
}
