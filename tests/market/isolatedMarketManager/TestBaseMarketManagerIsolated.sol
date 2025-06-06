// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";

contract TestBaseMarketManagerIsolated is TestBaseMarketIsolated {
    MockDataFeed public mockUsdcFeed;
    MockDataFeed public mockWethFeed;
    MockDataFeed public mockRethFeed;

    function setUp() public virtual override {
        super.setUp();

        _prepareUSDC(address(this), _ONE);
        _prepareDAI(address(this), _ONE);
        _prepareBALRETH(address(this), _ONE);

        oracleManager.addMTokenSupport(address(eDAI));

        SafeTransferLib.safeApprove(_USDC_ADDRESS, address(eUSDC), _ONE);
        SafeTransferLib.safeApprove(_DAI_ADDRESS, address(eDAI), _ONE);
        SafeTransferLib.safeApprove(
            _BAL_WETH_RETH_ADDRESS,
            address(pBALRETH),
            _ONE
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
        mockRethFeed = new MockDataFeed(_CHAINLINK_ETH_USD);
        chainlinkAdaptor.addAsset(
            _RETH_ADDRESS,
            address(mockRethFeed),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _RETH_ADDRESS,
            address(mockRethFeed),
            0,
            true
        );
    }

    function _prepareLiquidation() internal {
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

        // use mock pricing for testing
        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        chainlinkEthUsd.updateAnswer(1500e8);
        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);

        _prepareUSDC(user1, _ONE);
        _prepareUSDC(address(this), _ONE);

        _prepareBALRETH(user1, _ONE + 42069);
        _prepareUSDC(address(this), _ONE); // possibly not needed

        vm.prank(user1);
        usdc.approve(address(eUSDC), _ONE);
        balRETH.approve(address(pBALRETH), _ONE + 42069);

        marketManager.listTokens(address(pBALRETH), address(eUSDC));

        eUSDC.depositReserves(1000e6);
        // _prepareBALRETH(address(this), 10e18);
        // balRETH.approve(address(pBALRETH), 10e18);

        marketManager.updatePositionToken(
            7000,    // collRatio 70%
            4000,    // collReqSoft 40%
            3000,    // collReqHard 25%
            1000,    // liqIncBase 10%
            1500,    // liqIncHard 15%
            500,     // liqIncMin 5%
            2000,    // liqIncMax 20%
            2000,    // minEffectiveCFactor 20%
            3000,    // maxEffectiveCFactor 30%
            2000     // baseCFactor 20%
        );

        address[] memory tokens = new address[](1);
        tokens[0] = address(pBALRETH);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManager.setPTokenCollateralCaps(tokens, caps);

        // pBALRETH.mint(_ONE, address(this));

        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 200000e6);
        _prepareBALRETH(liquidityProvider, 10e18);
        // mint eUSDC
        vm.startPrank(liquidityProvider);
        usdc.approve(address(eUSDC), 200000e6);
        eUSDC.mint(200000e6);
        // mint cBALETH
        balRETH.approve(address(pBALRETH), 10e18);
        pBALRETH.deposit(10e18, liquidityProvider);
        vm.stopPrank();

        _prepareBALRETH(user1, _ONE);

        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), _ONE);
        pBALRETH.deposit(_ONE, user1);
        marketManager.postCollateral(user1, address(pBALRETH), _ONE - 1);

        eUSDC.borrow(1000e6);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);

        mockUsdcFeed.setMockAnswer(2e8);

        _prepareUSDC(user2, 1000e6);
    }

    // function _prepareLiquidationIsolated() internal {
    //     mockUsdcFeed = new MockDataFeed(_CHAINLINK_USDC_USD);
    //     chainlinkAdaptor.addAsset(
    //         _USDC_ADDRESS,
    //         address(mockUsdcFeed),
    //         0,
    //         true
    //     );

    //     dualChainlinkAdaptor.addAsset(
    //         _USDC_ADDRESS,
    //         address(mockUsdcFeed),
    //         0,
    //         true
    //     );

    //     // use mock pricing for testing
    //     vm.warp(gaugeManager.gaugeStartTime());
    //     vm.roll(block.number + 1000);

    //     chainlinkEthUsd.updateAnswer(1500e8);
    //     mockUsdcFeed.setMockUpdatedAt(block.timestamp);
    //     mockWethFeed.setMockUpdatedAt(block.timestamp);
    //     mockRethFeed.setMockUpdatedAt(block.timestamp);

    //     _prepareBALRETH(user1, _ONE);

    //     vm.startPrank(user1);

    //     balRETH.approve(address(pBALRETH), _ONE);
    //     pBALRETHIsolated.deposit(_ONE, user1);

    //     marketManagerIsolated.postCollateral(user1, address(pBALRETHIsolated), _ONE - 1);

    //     _prepareUSDC(address(this), 1000e6);   

    //     vm.stopPrank();

    //     // Create a lender with USDC
    //     deal(address(_USDC_ADDRESS), user2, 10_000e6);

    //     vm.startPrank(user2);

    //     usdc.approve(address(eUSDCIsolated), 10_000e6);

    //     // Deposit USDC to get eTokens

    //     eUSDCIsolated.mint(10_000e6);
    //     vm.stopPrank();

    //     vm.startPrank(user1);

    //     eUSDCIsolated.borrow(1000e6);
    //     vm.stopPrank();
        
    //     skip(20 minutes);

    //     mockUsdcFeed.setMockAnswer(2e8);
    // }
}
