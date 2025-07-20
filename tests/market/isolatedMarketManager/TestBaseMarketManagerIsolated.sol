// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { console2 } from "forge-std/console2.sol";
import { ICToken, AccountSnapshot } from "contracts/interfaces/ICToken.sol";
import { IBooster } from "contracts/interfaces/external/convex/IBooster.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { IBaseRewardPool } from "contracts/interfaces/external/convex/IBaseRewardPool.sol";
import { WAD, WAD_SQUARED } from "contracts/libraries/Constants.sol";

import "forge-std/console.sol";


contract TestBaseMarketManagerIsolated is TestBaseMarketIsolated {
    MockDataFeed public mockUsdcFeed;
    MockDataFeed public mockWethFeed;
    MockDataFeed public mockRethFeed;
    MockDataFeed public mockBALFeed;
    MockDataFeed public mockAURAFeed;

    address internal _BAL_ADDRESS = 0xba100000625a3754423978a60c9317c58a424e3D;
    address internal _AURA_ADDRESS =
        0xC0c293ce456fF0ED870ADd98a0828Dd4d2903DBF;

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

    function _harvestAuraStrategyRewards() internal {

        IBooster(_AURA_BOOSTER).earmarkRewards(109);

        skip(7 days);

        _setMockRewardConfig();

        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);
        mockBALFeed.setMockUpdatedAt(block.timestamp);
        mockAURAFeed.setMockUpdatedAt(block.timestamp);

        IBaseRewardPool rewarder = IBaseRewardPool(_REWARDERS[1]);
        uint256 earnedBAL = rewarder.earned(address(strategyCBALRETH));

        uint256 protocolFee = centralRegistry.protocolHarvestFee();
        uint256 netHarvestAmount = (earnedBAL * (WAD - protocolFee)) / WAD;

        if (netHarvestAmount > 0) {

            SwapperLib.Swap[] memory swaps = new SwapperLib.Swap[](1);
            swaps[0].slippage = 0.3e18;
            swaps[0].inputToken = _BAL_ADDRESS;
            swaps[0].inputAmount = netHarvestAmount;
            swaps[0].outputToken = _WETH_ADDRESS;
            swaps[0].target = _UNISWAP_V2_ROUTER;

            address[] memory path = new address[](2);
            path[0] = _BAL_ADDRESS;
            path[1] = _WETH_ADDRESS;

            swaps[0].call = abi.encodeWithSignature(
                "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
                netHarvestAmount,
                0,
                path,
                address(strategyCBALRETH),
                block.timestamp
            );

            strategyCBALRETH.harvest(abi.encode(swaps, 1e8));

        }
    

    }

    function _setMockRewardConfig() internal {
        centralRegistry.addHarvestPermissions(address(this));
        centralRegistry.setFeeManager(address(this));

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V2_ROUTER))
        );

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

        // Initialize BAL feed
        mockBALFeed = new MockDataFeed(
            0xdF2917806E30300537aEB49A7663062F4d1F2b5F
        );
        mockBALFeed.setMockUpdatedAt(block.timestamp);
        chainlinkAdaptor.addAsset(_BAL_ADDRESS, address(mockBALFeed), 0, true);
        oracleManager.addAssetPriceFeed(
            _BAL_ADDRESS,
            address(chainlinkAdaptor)
        );

        // Initialize AURA feed
        mockAURAFeed = new MockDataFeed(
            0xdF2917806E30300537aEB49A7663062F4d1F2b5F
        );
        mockAURAFeed.setMockUpdatedAt(block.timestamp);
        chainlinkAdaptor.addAsset(
            _AURA_ADDRESS,
            address(mockAURAFeed),
            0,
            true
        );
        oracleManager.addAssetPriceFeed(
            _AURA_ADDRESS,
            address(chainlinkAdaptor)
        );

        vm.warp(gaugeManager.gaugeStartTime());
        _skipEpochDuration(1);
        vm.roll(block.number + 1000);

        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);
        mockBALFeed.setMockUpdatedAt(block.timestamp);
        mockAURAFeed.setMockUpdatedAt(block.timestamp);
    }

    
}
