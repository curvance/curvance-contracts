// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import "tests/market/TestBaseMarket.sol";

contract TestPTokenWithExitFeeReserves is TestBaseMarket {
    address public owner;
    address public dao;

    MockDataFeed public mockDaiFeed;
    MockDataFeed public mockWethFeed;
    MockDataFeed public mockRethFeed;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        super.setUp();

        owner = address(this);
        dao = address(this);

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
            balRETH.approve(address(pBALRETHWithExitFee), 1 ether);
            marketManager.listToken(address(pBALRETHWithExitFee));
            // set collateral factor
            marketManager.updatePositionToken(
                address(pBALRETHWithExitFee),
                7000,
                4000, // liquidate at 71%
                3000,
                200, // 2% liq incentive
                400,
                10,
                1000
            );
            address[] memory tokens = new address[](1);
            tokens[0] = address(pBALRETHWithExitFee);
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
        balRETH.approve(address(pBALRETHWithExitFee), 10 ether);
        pBALRETHWithExitFee.deposit(10 ether, liquidityProvider);
        vm.stopPrank();
    }

    function testInitialize() public {
        assertEq(centralRegistry.daoAddress(), dao);
    }

    function testSeizeProtocolFee() public {
        _prepareBALRETH(user1, 1 ether);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETHWithExitFee), 1 ether);
        pBALRETHWithExitFee.deposit(1 ether, user1);
        marketManager.postCollateral(
            user1,
            address(pBALRETHWithExitFee),
            1 ether - 1
        );

        // try borrow()
        eDAI.borrow(1000 ether);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);

        mockDaiFeed.setMockAnswer(130000000);

        (
            uint256 repayAmount,
            uint256 liquidatedTokens,
            uint256 protocolTokens
        ) = marketManager.canLiquidate(
                address(eDAI),
                address(pBALRETHWithExitFee),
                user1,
                0,
                false
            );
        uint256 daoBalanceBefore = pBALRETHWithExitFee.balanceOf(dao);

        // try liquidate half
        _prepareDAI(user2, repayAmount);
        vm.startPrank(user2);
        dai.approve(address(eDAI), repayAmount);
        eDAI.liquidateExact(user1, repayAmount, address(pBALRETHWithExitFee));
        vm.stopPrank();

        assertApproxEqRel(
            pBALRETHWithExitFee.balanceOf(user1),
            1 ether - liquidatedTokens,
            0.01e18
        );
        assertEq(pBALRETHWithExitFee.exchangeRateCached(), 1 ether);

        assertEq(eDAI.balanceOf(user1), 0);
        assertApproxEqRel(
            eDAI.debtBalanceCached(user1),
            1000e18 - repayAmount,
            0.01e18
        );
        assertApproxEqRel(eDAI.exchangeRateCached(), 1 ether, 0.01e18);

        assertApproxEqRel(
            pBALRETHWithExitFee.balanceOf(dao),
            daoBalanceBefore + protocolTokens,
            0.01e18
        );
        assertApproxEqRel(
            gaugeManager.balanceOf(address(pBALRETHWithExitFee), dao),
            daoBalanceBefore + protocolTokens,
            0.01e18
        );
    }

    function testDaoCanRedeemProtocolFee() public {
        testSeizeProtocolFee();

        uint256 amountToRedeem = pBALRETHWithExitFee.balanceOf(dao);
        uint256 daoBalanceBefore = balRETH.balanceOf(dao);

        vm.prank(dao);
        pBALRETHWithExitFee.redeem(amountToRedeem, dao, dao);

        assertEq(pBALRETHWithExitFee.balanceOf(dao), 0);
        assertEq(gaugeManager.balanceOf(address(pBALRETHWithExitFee), dao), 0);
        assertEq(
            balRETH.balanceOf(dao),
            daoBalanceBefore +
                amountToRedeem -
                FixedPointMathLib.mulDivUp(
                    pBALRETHWithExitFee.exitFee(),
                    amountToRedeem,
                    1e18
                )
        );
    }

    function testDaoCanTransferProtocolFee() public {
        testSeizeProtocolFee();

        uint256 amountToTransfer = pBALRETHWithExitFee.balanceOf(dao);

        address user = makeAddr("user");
        vm.prank(dao);
        pBALRETHWithExitFee.transfer(user, amountToTransfer);

        assertEq(pBALRETHWithExitFee.balanceOf(dao), 0);
        assertEq(gaugeManager.balanceOf(address(pBALRETHWithExitFee), dao), 0);
        assertEq(pBALRETHWithExitFee.balanceOf(user), amountToTransfer);
        assertEq(
            gaugeManager.balanceOf(address(pBALRETHWithExitFee), user),
            amountToTransfer
        );
    }
}
