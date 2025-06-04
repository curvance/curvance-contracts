// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import "tests/market/TestBaseMarket.sol";

contract TestDynamicLiquidations is TestBaseMarket {
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
            dai.approve(address(eDAI), 200000e18);
            marketManager.listToken(address(eDAI));
            // add MToken support on oracle manager
            oracleManager.addMTokenSupport(address(eDAI));
        }

        // deploy PBALRETH
        {
            // support market
            _prepareBALRETH(owner, 1 ether);
            balRETH.approve(address(pBALRETH), 1 ether);
            marketManager.listToken(address(pBALRETH));
            // set collateral factor
            marketManager.updatePositionToken(
                address(pBALRETH),
                7000,
                4000,
                3000,
                200,
                400,
                1000
            );
            address[] memory tokens = new address[](1);
            tokens[0] = address(pBALRETH);
            uint256[] memory caps = new uint256[](1);
            caps[0] = 100_000e18;
            marketManager.setCollateralCaps(tokens, caps);
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

    // function testLiquidateRevertWhenBelowColReqA() public {
    //     _prepareBALRETH(user1, 1 ether);

    //     // try mint()
    //     vm.startPrank(user1);
    //     balRETH.approve(address(pBALRETH), 1 ether);
    //     pBALRETH.deposit(1 ether, user1);
    //     pBALRETH.postCollateral(1 ether - 1);

    //     // try borrow()
    //     eDAI.borrow(1000 ether);
    //     vm.stopPrank();

    //     // skip min hold period
    //     skip(900);

    //     (uint256 balRETHPrice, ) = oracleManager.getPrice(
    //         address(balRETH),
    //         true,
    //         true
    //     );

    //     // adjust dai price, a bit lower than colReqA
    //     // 1000 dai > 1 pBALRETH / colReqA
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

    //     eDAI.liquidateExact(
    //         accounts,
    //         debtAmounts, 
    //         address(pBALRETH));
    // }

    // function testLiquidateWorksWhenAboveColReqA() public {
    //     _prepareBALRETH(user1, 1 ether);

    //     // try mint()
    //     vm.startPrank(user1);
    //     balRETH.approve(address(pBALRETH), 1 ether);
    //     pBALRETH.deposit(1 ether, user1);
    //     pBALRETH.postCollateral(1 ether - 1);

    //     // try borrow()
    //     eDAI.borrow(1000 ether);
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
    //     dai.approve(address(eDAI), 250 ether);

    //     address[] memory accounts = new address[](1);
    //     accounts[0] = user1;
    //     uint256[] memory debtAmounts = new uint256[](1);
    //     debtAmounts[0] = 250 ether;
        
    //     eDAI.liquidateExact(
    //         accounts,
    //         debtAmounts,
    //         address(pBALRETH)
    //     );
    //     vm.stopPrank();

    //     assertApproxEqRel(
    //         pBALRETH.balanceOf(user1),
    //         1 ether - (500 ether * 1 ether) / balRETHPrice,
    //         0.02e18
    //     );
    //     assertEq(pBALRETH.exchangeRateCached(), 1 ether);

    //     assertEq(eDAI.balanceOf(user1), 0);
    //     assertApproxEqRel(eDAI.debtBalanceCached(user1), 750 ether, 0.01e18);
    //     assertApproxEqRel(eDAI.exchangeRateCached(), 1 ether, 0.01e18);
    // }
}
