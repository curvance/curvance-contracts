// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPendlePTOracle } from "contracts/interfaces/external/pendle/IPendlePtOracle.sol";
import { PriceReturnData } from "contracts/interfaces/IOracleAdaptor.sol";
import { IUniswapV3Router } from "contracts/interfaces/external/uniswap/IUniswapV3Router.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";

import { Multicall } from "contracts/libraries/Multicall.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { SimpleCToken } from "contracts/market/token/SimpleCToken.sol";
import { MockRedstoneCoreAdaptor } from "contracts/mocks/MockRedstoneCoreAdaptor.sol";
import { BaseMulticallChecker } from "contracts/calldata-checker/multicall-checker/BaseMulticallChecker.sol";
import { RedstoneAdaptorMulticallChecker } from "contracts/calldata-checker/multicall-checker/RedstoneAdaptorMulticallChecker.sol";
import { SimplePositionManager } from "contracts/market/position-management/SimplePositionManager.sol";

import "tests/market/TestBaseMarketIsolated.sol";

contract TestRedstoneAdaptorMulticall is TestBaseMarketIsolated {
    address internal _UNISWAP_V3_SWAP_ROUTER =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;

    address public owner;

    MockRedstoneCoreAdaptor public adapter;
    RedstoneAdaptorMulticallChecker public multicallChecker;

    MockDataFeed public mockUsdcFeed;
    MockDataFeed public mockWethFeed;
    MockDataFeed public mockStethFeed;

    SimpleCToken public cWBTC;
    SimplePositionManager public positionManagement;

    receive() external payable {}

    fallback() external payable {}

    address private PYTH = 0x4305FB66699C3B2702D4d05CF36551390A4c69C6;

    function getRedstonePayload(
        // dataFeedId:value:decimals
        string memory priceFeed,
        bytes32[] memory redstoneSignerKeys
    ) public returns (bytes memory) {
        uint256 privateKeysLength = redstoneSignerKeys.length;
        string[] memory args = new string[](4 + privateKeysLength);
        args[0] = "node";
        args[1] = "getRedstonePayload.js";
        args[2] = priceFeed;
        args[3] = vm.toString(privateKeysLength);
        for (uint256 i = 0; i < privateKeysLength; i++) {
            args[4 + i] = vm.toString(redstoneSignerKeys[i]);
        }

        return vm.ffi(args);
    }

    function setUp() public override {
        super.setUp();

        owner = address(this);

        // use mock pricing for testing
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

        adapter = new MockRedstoneCoreAdaptor(
            ICentralRegistry(address(centralRegistry)),
            redstoneSigners,
            3,
            "ETH"
        );

        adapter.addAsset(_WBTC_ADDRESS, true, 8, 10 minutes);
        adapter.addAsset(_WBTC_ADDRESS, false, 18, 10 minutes);

        multicallChecker = new RedstoneAdaptorMulticallChecker(
            address(centralRegistry)
        );
        centralRegistry.setMulticallChecker(
            address(adapter),
            address(multicallChecker)
        );

        oracleManager.addApprovedAdaptor(address(adapter));

        bytes memory redstonePayload = getRedstonePayload(
            "WBTC:60000:8",
            redstoneSignerKeys
        );
        bytes memory encodedFunction = abi.encodeWithSignature(
            "writePrice(address,bool)",
            _WBTC_ADDRESS,
            true
        );
        bytes memory encodedFunctionWithRedstonePayload = abi.encodePacked(
            encodedFunction,
            redstonePayload
        );

        // Securely getting oracle value
        (bool success, ) = address(adapter).call(
            encodedFunctionWithRedstonePayload
        );
        assertTrue(success);

        oracleManager.addAssetPriceFeed(_WBTC_ADDRESS, address(adapter));

        // start epoch
        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        (success, ) = address(adapter).call(
            encodedFunctionWithRedstonePayload
        );
        assertTrue(success);

        // Deploy borrowableCUSDC
        {
            _deployBorrowableCUSDC();
            // support market
            _prepareUSDC(owner, 200000e6);
            usdc.approve(address(borrowableCUSDC), 200000e6);
            // Add cToken support on Oracle Manager.
            oracleManager.addCTokenSupport(address(borrowableCUSDC));
            address[] memory markets = new address[](1);
            markets[0] = address(borrowableCUSDC);
        }

        // Deploy cWBTC
        {
            cWBTC = new SimpleCToken(
                ICentralRegistry(address(centralRegistry)),
                wbtc,
                address(marketManagerIsolated)
            );

            // support market
            _prepareWBTC(owner, 1e8);
            wbtc.approve(address(cWBTC), 1e8);
            // add CToken support on oracle manager
            oracleManager.addCTokenSupport(address(cWBTC));
            // set position token configuration


            // address[] memory markets = new address[](1);
            // markets[0] = address(cWBTC);
            // vm.prank(user1);
            // marketManager.enterMarkets(markets);
            // vm.prank(user2);
            // marketManager.enterMarkets(markets);
        }

        marketManagerIsolated.listTokens(address(cWBTC),address(borrowableCUSDC));

        MarketManagerIsolated.TokenConfig memory tokenConfigs;
        tokenConfigs.cToken = address(cWBTC);
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

        tokenConfigs.cToken = address(borrowableCUSDC);
        tokenConfigs.debtCap = 100_000e6;

        marketManagerIsolated.updateTokenConfig(tokenConfigs);

        // provide enough liquidity
        provideEnoughLiquidityForLeverage();

        // setup position management
        {
            positionManagement = new SimplePositionManager(
                ICentralRegistry(address(centralRegistry)),
                address(marketManagerIsolated),
                _WETH_ADDRESS
            );
            marketManagerIsolated.addPositionManager(address(positionManagement));
        }

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V3_SWAP_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V3_SWAP_ROUTER))
        );

        address[] memory multicallProviders = new address[](3);
        multicallProviders[0] = address(cWBTC);
        multicallProviders[1] = address(positionManagement);
        multicallProviders[2] = address(borrowableCUSDC);
        centralRegistry.setMulticallProviders(multicallProviders, true);
    }

    function provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = address(user2);
        _prepareUSDC(liquidityProvider, 200000e6);
        _prepareWBTC(liquidityProvider, 10 ether);
        // mint eUSDC
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 200000e6);
        borrowableCUSDC.deposit(200000e6, liquidityProvider);
        // mint cBALETH
        wbtc.approve(address(cWBTC), 10 ether);
        cWBTC.deposit(10 ether, liquidityProvider);
        vm.stopPrank();
    }

    function testCTokenMintMulticall() public {
        _prepareWBTC(user1, 2 ether);

        vm.prank(user1);
        wbtc.approve(address(cWBTC), 1e8);

        Multicall.MulticallData[] memory calls = new Multicall.MulticallData[](
            2
        );
        calls[0].target = address(adapter);
        bytes memory redstonePayload = getRedstonePayload(
            "WBTC:61000:8",
            redstoneSignerKeys
        );
        bytes memory encodedFunction = abi.encodeWithSignature(
            "writePrice(address,bool)",
            _WBTC_ADDRESS,
            true
        );
        bytes memory encodedFunctionWithRedstonePayload = abi.encodePacked(
            encodedFunction,
            redstonePayload
        );
        calls[0].data = encodedFunctionWithRedstonePayload;
        calls[0].isPriceUpdate = true;

        calls[1].target = address(cWBTC);
        calls[1].data = abi.encodeWithSelector(
            cWBTC.deposit.selector,
            1e8,
            user1
        );

        // try mint()
        vm.prank(user1);
        cWBTC.multicall(calls);

        assertEq(cWBTC.balanceOf(user1), 1e8);
        PriceReturnData memory priceData = adapter.getPrice(
            _WBTC_ADDRESS,
            true,
            true
        );
        assertEq(priceData.price, 61000e18);
    }

    function testBorrowableCTokenMintWithMulticall() public {
        _prepareUSDC(user1, 2e6);

        vm.prank(user1);
        usdc.approve(address(borrowableCUSDC), 1e6);

        Multicall.MulticallData[] memory calls = new Multicall.MulticallData[](
            2
        );
        calls[0].target = address(adapter);
        bytes memory redstonePayload = getRedstonePayload(
            "WBTC:61000:8",
            redstoneSignerKeys
        );
        bytes memory encodedFunction = abi.encodeWithSignature(
            "writePrice(address,bool)",
            _WBTC_ADDRESS,
            true
        );
        bytes memory encodedFunctionWithRedstonePayload = abi.encodePacked(
            encodedFunction,
            redstonePayload
        );
        calls[0].data = encodedFunctionWithRedstonePayload;
        calls[0].isPriceUpdate = true;

        calls[1].target = address(borrowableCUSDC);
        calls[1].data = abi.encodeWithSelector(borrowableCUSDC.deposit.selector, 1e6, user1);

        // try mint()
        vm.prank(user1);
        borrowableCUSDC.multicall(calls);

        assertEq(borrowableCUSDC.balanceOf(user1), 1e6);
        PriceReturnData memory priceData = adapter.getPrice(
            _WBTC_ADDRESS,
            true,
            true
        );
        assertEq(priceData.price, 61000e18);
    }

    function testPositionLeverage() public {
        centralRegistry.setSlippageLimit(6000);

        // provide fee to universal balance
        _prepareWBTC(user1, 0.1e8);
        vm.prank(user1);
        wbtc.approve(address(cWBTC), 0.1e8);

        vm.prank(user1);
        assertGt(cWBTC.deposit(0.1e8, user1), 0);
        vm.prank(user1);
        cWBTC.postCollateral(0.1e8);
        assertEq(cWBTC.balanceOf(user1), 0.1e8);

        uint256 amountForLeverage = (positionManagement.maxRemainingLeverageOf(
            user1,
            address(borrowableCUSDC)
        ) * 50) / 100;

        SimplePositionManager.LeverageStruct memory leverageData;
        leverageData.debtToken = IBorrowableCToken(address(borrowableCUSDC));
        leverageData.borrowAmount = amountForLeverage;
        leverageData.collateralToken = ICToken(address(cWBTC));
        leverageData.swapData.inputToken = _USDC_ADDRESS;
        leverageData.swapData.inputAmount = amountForLeverage;
        leverageData.swapData.outputToken = _WBTC_ADDRESS;
        leverageData.swapData.target = address(_UNISWAP_V3_SWAP_ROUTER);
        leverageData.swapData.slippage = 2e18;
        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _USDC_ADDRESS;
        params.tokenOut = _WBTC_ADDRESS;
        params.fee = 3000;
        params.recipient = address(positionManagement);
        params.deadline = block.timestamp;
        params.amountIn = amountForLeverage;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        leverageData.swapData.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector,
            params
        );
        leverageData.auxData = bytes("");

        Multicall.MulticallData[] memory calls = new Multicall.MulticallData[](
            2
        );
        calls[0].target = address(adapter);
        bytes memory redstonePayload = getRedstonePayload(
            "WBTC:61000:8",
            redstoneSignerKeys
        );
        bytes memory encodedFunction = abi.encodeWithSignature(
            "writePrice(address,bool)",
            _WBTC_ADDRESS,
            true
        );
        bytes memory encodedFunctionWithRedstonePayload = abi.encodePacked(
            encodedFunction,
            redstonePayload
        );
        calls[0].data = encodedFunctionWithRedstonePayload;
        calls[0].isPriceUpdate = true;

        calls[1].target = address(positionManagement);
        calls[1].data = abi.encodeWithSelector(
            positionManagement.leverage.selector,
            leverageData
        );

        // try leverage()
        vm.prank(user1);
        positionManagement.multicall(calls);
    }

    function testCheckCalldata() public {
        {
            bytes memory redstonePayload = getRedstonePayload(
                "WBTC:61000:8",
                redstoneSignerKeys
            );
            bytes memory encodedFunction = abi.encodeWithSignature(
                "writePrice(address,bool)",
                _WBTC_ADDRESS,
                true
            );
            bytes memory encodedFunctionWithRedstonePayload = abi.encodePacked(
                encodedFunction,
                redstonePayload
            );

            vm.expectRevert(
                BaseMulticallChecker.MulticallChecker__TargetError.selector
            );
            multicallChecker.checkCalldata(
                address(this),
                address(this),
                encodedFunctionWithRedstonePayload
            );
        }

        {
            bytes memory redstonePayload = getRedstonePayload(
                "WBTC:61000:8",
                redstoneSignerKeys
            );
            bytes memory encodedFunction = abi.encodeWithSignature(
                "writePriceSimple(address,bool)",
                _WBTC_ADDRESS,
                true
            );
            bytes memory encodedFunctionWithRedstonePayload = abi.encodePacked(
                encodedFunction,
                redstonePayload
            );
            vm.expectRevert(
                BaseMulticallChecker.MulticallChecker__InvalidFuncSig.selector
            );
            multicallChecker.checkCalldata(
                address(this),
                address(adapter),
                encodedFunctionWithRedstonePayload
            );
        }
    }
}
