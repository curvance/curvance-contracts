// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { console2 } from "forge-std/console2.sol";
import { ICToken, AccountSnapshot } from "contracts/interfaces/ICToken.sol";
import "forge-std/console.sol";

contract TestBaseMarketManagerIsolated is TestBaseMarketIsolated {
    MockDataFeed public mockUsdcFeed;
    MockDataFeed public mockWethFeed;
    MockDataFeed public mockRethFeed;

    function setUp() public virtual override {
        super.setUp();

        _prepareUSDC(address(this), _ONE);
        _prepareDAI(address(this), _ONE);
        _prepareBALRETH(address(this), _ONE);

        oracleManager.addCTokenSupport(address(borrowableCDAI));

        SafeTransferLib.safeApprove(_USDC_ADDRESS, address(borrowableCUSDC), _ONE);
        SafeTransferLib.safeApprove(_DAI_ADDRESS, address(borrowableCDAI), _ONE);
        SafeTransferLib.safeApprove(
            _BAL_WETH_RETH_ADDRESS,
            address(strategyCBALRETH),
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

        _prepareBALRETH(user1, _ONE + 77777);
        _prepareUSDC(address(this), _ONE); // possibly not needed

        vm.prank(user1);
        usdc.approve(address(borrowableCUSDC), _ONE);
        balRETH.approve(address(strategyCBALRETH), _ONE + 77777);

        console2.log("balRETH address:", address(balRETH));
        address balRETHUnderlying = strategyCBALRETH.asset();
        console2.log("strategyCBALRETH underlying:", balRETHUnderlying); 

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);

        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 200000e6);
        _prepareBALRETH(liquidityProvider, 10e18);
        // Mint borrowable cUSDC.
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 200000e6);
        borrowableCUSDC.deposit(200000e6, liquidityProvider);
        // Mint cBALETH.
        balRETH.approve(address(strategyCBALRETH), 10e18);
        strategyCBALRETH.deposit(10e18, liquidityProvider);
        vm.stopPrank();

        _prepareBALRETH(user1, _ONE);

        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);

        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.deposit(_ONE, user1);
        strategyCBALRETH.postCollateral(_ONE - 1);

        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);

        borrowableCUSDC.borrow(1000e6, user1);
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

    //     balRETH.approve(address(simpleCBALRETH), _ONE);
    //     simpleCBALRETH.deposit(_ONE, user1);

    //     marketManagerIsolated.postCollateral(user1, address(simpleCBALRETH), _ONE - 1);

    //     _prepareUSDC(address(this), 1000e6);   

    //     vm.stopPrank();

    //     // Create a lender with USDC
    //     deal(address(_USDC_ADDRESS), user2, 10_000e6);

    //     vm.startPrank(user2);

    //     usdc.approve(address(borrowableCUSDC), 10_000e6);

    //     // Deposit USDC to get eTokens

    //     borrowableCUSDC.mint(10_000e6);
    //     vm.stopPrank();

    //     vm.startPrank(user1);

    //     borrowableCUSDC.borrow(1000e6, user1);
    //     vm.stopPrank();
        
    //     skip(20 minutes);

    //     mockUsdcFeed.setMockAnswer(2e8);
    // }
}
