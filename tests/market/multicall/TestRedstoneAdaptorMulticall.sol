// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPendlePTOracle } from "contracts/interfaces/external/pendle/IPendlePtOracle.sol";
import { PricingResult } from "contracts/interfaces/IOracleAdaptor.sol";
import { IUniswapV3Router } from "contracts/interfaces/external/uniswap/IUniswapV3Router.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { Multicall } from "contracts/libraries/Multicall.sol";
import { SimpleCToken } from "contracts/market/token/SimpleCToken.sol";
import { BaseMulticallChecker } from "contracts/calldata-checker/multicall-checker/BaseMulticallChecker.sol";
import { RedstoneAdaptorMulticallChecker } from "contracts/calldata-checker/multicall-checker/RedstoneAdaptorMulticallChecker.sol";
import { SimplePositionManager } from "contracts/market/position-management/SimplePositionManager.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MockRedstoneCoreAdaptor } from "contracts/mocks/MockRedstoneCoreAdaptor.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";

contract TestRedstoneAdaptorMulticall is TestBaseMarketIsolated {
    address internal _UNISWAP_V3_SWAP_ROUTER =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;

    address public owner;

    MockRedstoneCoreAdaptor public adapter;
    RedstoneAdaptorMulticallChecker public multicallChecker;

    SimpleCToken public simpleCWBTC;
    SimplePositionManager public positionManager;

    receive() external payable {}

    fallback() external payable {}

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

        adapter = new MockRedstoneCoreAdaptor(
            ICentralRegistry(address(centralRegistry)),
            redstoneSigners,
            3,
            "ETH",
            .1e18,
            0,
            30 days,
            7 days
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
            "writePrice(address,bool,uint128)",
            _WBTC_ADDRESS,
            true,
            uint128(block.timestamp * 1000)
        );
        bytes memory encodedFunctionWithRedstonePayload = abi.encodePacked(
            encodedFunction,
            redstonePayload
        );

        // Securely get oracle value
        (bool success, ) = address(adapter).call(
            encodedFunctionWithRedstonePayload
        );
        assertTrue(success);

       // remove WBTC pricefeed made in base market setup
        oracleManager.removeAssetPriceFeed(
            _WBTC_ADDRESS,
            address(chainlinkAdaptor)
        );

        oracleManager.addAssetPriceFeed(_WBTC_ADDRESS, address(adapter));

        // Start gauge system epoch
        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        (success, ) = address(adapter).call(
            encodedFunctionWithRedstonePayload
        );
        assertTrue(success);

        // Setup borrowableCUSDC.
        {
            _deployBorrowableCUSDC();

            _prepareUSDC(owner, 200000e6);
            usdc.approve(address(borrowableCUSDC), 200000e6);
            // Add cToken support on Oracle Manager.
            oracleManager.addCTokenSupport(address(borrowableCUSDC));
            address[] memory markets = new address[](1);
            markets[0] = address(borrowableCUSDC);
        }

        // Setup simpleCWBTC.
        {
            simpleCWBTC = new SimpleCToken(
                ICentralRegistry(address(centralRegistry)),
                wbtc,
                address(marketManagerIsolated)
            );

            _prepareWBTC(owner, 1e8);
            wbtc.approve(address(simpleCWBTC), 1e8);
            // add CToken support on oracle manager
            oracleManager.addCTokenSupport(address(simpleCWBTC));
        }

        marketManagerIsolated.listTokens(address(simpleCWBTC),address(borrowableCUSDC));

        _setCTokenConfigBasic(address(simpleCWBTC), 100e8, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 100e8, 100_000e6);

        // Provide enough liquidity for leveraging.
        provideEnoughLiquidityForLeverage();

        // Setup position manager
        {
            positionManager = new SimplePositionManager(
                ICentralRegistry(address(centralRegistry)),
                address(marketManagerIsolated),
                _WETH_ADDRESS
            );
            marketManagerIsolated.addPositionManager(address(positionManager));
        }

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V3_SWAP_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V3_SWAP_ROUTER))
        );

        address[] memory multicallProviders = new address[](3);
        multicallProviders[0] = address(simpleCWBTC);
        multicallProviders[1] = address(positionManager);
        multicallProviders[2] = address(borrowableCUSDC);
        centralRegistry.setMulticallProviders(multicallProviders, true);
    }

    function provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = address(user2);
        _prepareUSDC(liquidityProvider, 200000e6);
        _prepareWBTC(liquidityProvider, 10 ether);

        // Mint borrowable cUSDC.
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 200000e6);
        borrowableCUSDC.deposit(200000e6, liquidityProvider);

        // Mint cBALETH.
        wbtc.approve(address(simpleCWBTC), 10 ether);
        simpleCWBTC.deposit(10 ether, liquidityProvider);
        vm.stopPrank();
    }

    function testCTokenMintMulticall() public {
        vm.warp(block.timestamp + 60); // advance by 1 minute

        _prepareWBTC(user1, 2 ether);

        vm.prank(user1);
        wbtc.approve(address(simpleCWBTC), 1e8);

        Multicall.MulticallData[] memory calls = new Multicall.MulticallData[](
            2
        );
        calls[0].target = address(adapter);
        bytes memory redstonePayload = getRedstonePayload(
            "WBTC:61000:8",
            redstoneSignerKeys
        );
        bytes memory encodedFunction = abi.encodeWithSignature(
            "writePrice(address,bool,uint128)",
            _WBTC_ADDRESS,
            true,
            uint128(block.timestamp * 1000)
        );
        bytes memory encodedFunctionWithRedstonePayload = abi.encodePacked(
            encodedFunction,
            redstonePayload
        );
        calls[0].data = encodedFunctionWithRedstonePayload;
        calls[0].isPriceUpdate = true;

        calls[1].target = address(simpleCWBTC);
        calls[1].data = abi.encodeWithSelector(
            simpleCWBTC.deposit.selector,
            1e8,
            user1
        );

        // try mint()
        vm.prank(user1);
        simpleCWBTC.multicall(calls);

        assertEq(simpleCWBTC.balanceOf(user1), 1e8);
        PricingResult memory priceData = adapter.getPrice(
            _WBTC_ADDRESS,
            true,
            true
        );
        assertEq(priceData.price, 61000e18);
    }

    function testBorrowableCTokenMintWithMulticall() public {
        
        vm.warp(block.timestamp + 60); // advance by 1 minute

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
            "writePrice(address,bool,uint128)",
            _WBTC_ADDRESS,
            true,
            uint128(block.timestamp * 1000)
        );
        bytes memory encodedFunctionWithRedstonePayload = abi.encodePacked(
            encodedFunction,
            redstonePayload
        );

        // check if writePrice works
        // vm.prank(user1);
        // (bool success, ) = address(adapter).call(encodedFunctionWithRedstonePayload);
        // assertTrue(success, "writePrice should work");

        calls[0].data = encodedFunctionWithRedstonePayload;
        calls[0].isPriceUpdate = true;

        calls[1].target = address(borrowableCUSDC);
        calls[1].data = abi.encodeWithSelector(borrowableCUSDC.deposit.selector, 1e6, user1);

        // try mint()
        vm.prank(user1);
        borrowableCUSDC.multicall(calls);

        assertEq(borrowableCUSDC.balanceOf(user1), 1e6);
        PricingResult memory priceData = adapter.getPrice(
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
        wbtc.approve(address(simpleCWBTC), 0.1e8);

        vm.prank(user1);
        assertGt(simpleCWBTC.deposit(0.1e8, user1), 0);
        vm.prank(user1);
        simpleCWBTC.postCollateral(0.1e8);
        assertEq(simpleCWBTC.balanceOf(user1), 0.1e8);

        uint256 amountForLeverage = (positionManager.maxRemainingLeverageOf(
            user1,
            address(borrowableCUSDC)
        ) * 50) / 100;

        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCUSDC));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(simpleCWBTC));
        leverageAction.swapAction.inputToken = _USDC_ADDRESS;
        leverageAction.swapAction.inputAmount = amountForLeverage;
        leverageAction.swapAction.outputToken = _WBTC_ADDRESS;
        leverageAction.swapAction.target = address(_UNISWAP_V3_SWAP_ROUTER);
        leverageAction.swapAction.slippage = 2e18;
        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _USDC_ADDRESS;
        params.tokenOut = _WBTC_ADDRESS;
        params.fee = 3000;
        params.recipient = address(positionManager);
        params.deadline = block.timestamp;
        params.amountIn = amountForLeverage;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        leverageAction.swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector,
            params
        );
        leverageAction.auxData = bytes("");

        Multicall.MulticallData[] memory calls = new Multicall.MulticallData[](
            2
        );
        calls[0].target = address(adapter);
        bytes memory redstonePayload = getRedstonePayload(
            "WBTC:61000:8",
            redstoneSignerKeys
        );
        bytes memory encodedFunction = abi.encodeWithSignature(
            "writePrice(address,bool,uint128)",
            _WBTC_ADDRESS,
            true,
            uint128(block.timestamp * 1000)
        );
        bytes memory encodedFunctionWithRedstonePayload = abi.encodePacked(
            encodedFunction,
            redstonePayload
        );
        calls[0].data = encodedFunctionWithRedstonePayload;
        calls[0].isPriceUpdate = true;

        calls[1].target = address(positionManager);
        calls[1].data = abi.encodeWithSelector(
            positionManager.leverage.selector,
            leverageAction
        );

        // try leverage()
        vm.prank(user1);
        positionManager.multicall(calls);
    }

    function testCheckCalldata() public {
        {
            bytes memory redstonePayload = getRedstonePayload(
                "WBTC:61000:8",
                redstoneSignerKeys
            );
            bytes memory encodedFunction = abi.encodeWithSignature(
                "writePrice(address,bool,uint128)",
                _WBTC_ADDRESS,
                true,
                uint128(block.timestamp * 1000)
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
