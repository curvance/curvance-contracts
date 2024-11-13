// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { IMToken } from "contracts/interfaces/IMToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPendlePTOracle } from "contracts/interfaces/external/pendle/IPendlePtOracle.sol";
import { PriceReturnData } from "contracts/interfaces/IOracleAdaptor.sol";
import { IUniswapV3Router } from "contracts/interfaces/external/uniswap/IUniswapV3Router.sol";

import { Multicall } from "contracts/libraries/Multicall.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { SimplePToken } from "contracts/market/token/SimplePToken.sol";
import { MockRedstoneCoreAdaptor } from "contracts/mocks/MockRedstoneCoreAdaptor.sol";
import { BaseMulticallChecker } from "contracts/calldata-checker/multicall-checker/BaseMulticallChecker.sol";
import { RedstoneAdaptorMulticallChecker } from "contracts/calldata-checker/multicall-checker/RedstoneAdaptorMulticallChecker.sol";
import { PositionManagementSimple } from "contracts/market/position-management/PositionManagementSimple.sol";

import "tests/market/TestBaseMarket.sol";

contract User {}

contract TestRedstoneAdaptorMulticall is TestBaseMarket {
    address internal _UNISWAP_V3_SWAP_ROUTER =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;

    address public owner;

    MockRedstoneCoreAdaptor public adapter;
    RedstoneAdaptorMulticallChecker public multicallChecker;

    MockDataFeed public mockUsdcFeed;
    MockDataFeed public mockWethFeed;
    MockDataFeed public mockStethFeed;

    SimplePToken public pWBTC;
    PositionManagementSimple public positionManagement;

    receive() external payable {}

    fallback() external payable {}

    address private PYTH = 0x4305FB66699C3B2702D4d05CF36551390A4c69C6;

    function getRedstonePayload(
        // dataFeedId:value:decimals
        string memory priceFeed
    ) public returns (bytes memory) {
        string[] memory args = new string[](3);
        args[0] = "node";
        args[1] = "getRedstonePayload.js";
        args[2] = priceFeed;

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
            2
        );
        adapter.addAsset(_WBTC_ADDRESS, true, 8, 12 hours);
        adapter.addAsset(_WBTC_ADDRESS, false, 18, 12 hours);

        multicallChecker = new RedstoneAdaptorMulticallChecker(
            address(centralRegistry)
        );
        centralRegistry.setMulticallChecker(
            address(adapter),
            address(multicallChecker)
        );

        oracleManager.addApprovedAdaptor(address(adapter));

        bytes memory redstonePayload = getRedstonePayload("WBTC:60000:8");
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
        vm.warp(gaugeManager.startTime());
        vm.roll(block.number + 1000);

        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        (success, ) = address(adapter).call(
            encodedFunctionWithRedstonePayload
        );
        assertTrue(success);

        // deploy eUSDC
        {
            _deployEUSDC();
            // support market
            _prepareUSDC(owner, 200000e6);
            usdc.approve(address(eUSDC), 200000e6);
            marketManager.listToken(address(eUSDC));
            // add MToken support on oracle manager
            oracleManager.addMTokenSupport(address(eUSDC));
            address[] memory markets = new address[](1);
            markets[0] = address(eUSDC);
            // vm.prank(user1);
            // marketManager.enterMarkets(markets);
            // vm.prank(user2);
            // marketManager.enterMarkets(markets);
        }

        // deploy pWBTC
        {
            // deploy aura position vault
            pWBTC = new SimplePToken(
                ICentralRegistry(address(centralRegistry)),
                wbtc,
                address(marketManager)
            );

            // support market
            _prepareWBTC(owner, 1e8);
            wbtc.approve(address(pWBTC), 1e8);
            marketManager.listToken(address(pWBTC));
            // add MToken support on oracle manager
            oracleManager.addMTokenSupport(address(pWBTC));
            // set position token configuration
            marketManager.updatePositionToken(
                IMToken(address(pWBTC)),
                7000,
                4000, // liquidate at 71%
                3000,
                200, // 2% liq incentive
                400,
                0,
                1000
            );

            address[] memory mTokens = new address[](1);
            mTokens[0] = address(pWBTC);
            uint256[] memory caps = new uint256[](1);
            caps[0] = 100e8;
            marketManager.setPTokenCollateralCaps(mTokens, caps);

            // address[] memory markets = new address[](1);
            // markets[0] = address(pWBTC);
            // vm.prank(user1);
            // marketManager.enterMarkets(markets);
            // vm.prank(user2);
            // marketManager.enterMarkets(markets);
        }

        // provide enough liquidity
        provideEnoughLiquidityForLeverage();

        // setup position management
        {
            positionManagement = new PositionManagementSimple(
                ICentralRegistry(address(centralRegistry)),
                address(marketManager)
            );
            marketManager.setPositionManagement(address(positionManagement));
        }

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V3_SWAP_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V3_SWAP_ROUTER))
        );
    }

    function _prepareWBTC(address user, uint256 amount) internal {
        deal(_WBTC_ADDRESS, user, amount);
    }

    function provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = address(new User());
        _prepareUSDC(liquidityProvider, 200000e6);
        _prepareWBTC(liquidityProvider, 10 ether);
        // mint eUSDC
        vm.startPrank(liquidityProvider);
        usdc.approve(address(eUSDC), 200000e6);
        eUSDC.mint(200000e6);
        // mint cBALETH
        wbtc.approve(address(pWBTC), 10 ether);
        pWBTC.mint(10 ether, liquidityProvider);
        vm.stopPrank();
    }

    function testInitialize() public {
        assertTrue(pWBTC.isPToken());
        assertFalse(eUSDC.isPToken());
    }

    function testPTokenMintMulticall() public {
        _prepareWBTC(user1, 2 ether);

        vm.prank(user1);
        wbtc.approve(address(pWBTC), 1e8);

        Multicall.MulticallData[] memory calls = new Multicall.MulticallData[](
            2
        );
        calls[0].target = address(adapter);
        bytes memory redstonePayload = getRedstonePayload("WBTC:61000:8");
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

        calls[1].target = address(pWBTC);
        calls[1].data = abi.encodeWithSelector(
            pWBTC.mint.selector,
            1e8,
            user1
        );

        // try mint()
        vm.prank(user1);
        pWBTC.multicall(calls);

        assertEq(pWBTC.balanceOf(user1), 1e8);
        PriceReturnData memory priceData = adapter.getPrice(
            _WBTC_ADDRESS,
            true,
            true
        );
        assertEq(priceData.price, 61000e18);
    }

    function testETokenMintWithMulticall() public {
        _prepareUSDC(user1, 2e6);

        vm.prank(user1);
        usdc.approve(address(eUSDC), 1e6);

        Multicall.MulticallData[] memory calls = new Multicall.MulticallData[](
            2
        );
        calls[0].target = address(adapter);
        bytes memory redstonePayload = getRedstonePayload("WBTC:61000:8");
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

        calls[1].target = address(eUSDC);
        calls[1].data = abi.encodeWithSelector(eUSDC.mint.selector, 1e6);

        // try mint()
        vm.prank(user1);
        eUSDC.multicall(calls);

        assertEq(eUSDC.balanceOf(user1), 1e6);
        PriceReturnData memory priceData = adapter.getPrice(
            _WBTC_ADDRESS,
            true,
            true
        );
        assertEq(priceData.price, 61000e18);
    }

    function testPositionLeverage() public {
        centralRegistry.setSlippageLimit(60000);

        // provide fee to universal balance
        deal(_WBTC_ADDRESS, user1, 0.1e8);
        vm.prank(user1);
        wbtc.approve(address(pWBTC), 0.1e8);

        vm.prank(user1);
        assertGt(pWBTC.deposit(0.1e8, user1), 0);
        vm.prank(user1);
        marketManager.postCollateral(user1, address(pWBTC), 0.1e8);
        assertEq(pWBTC.balanceOf(user1), 0.1e8);

        uint256 amountForLeverage = (positionManagement
            .queryAmountToBorrowForLeverageMax(user1, address(eUSDC)) * 50) /
            100;

        PositionManagementSimple.LeverageStruct memory leverageData;
        leverageData.borrowToken = eUSDC;
        leverageData.borrowAmount = amountForLeverage;
        leverageData.positionToken = SimplePToken(address(pWBTC));
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
        bytes memory redstonePayload = getRedstonePayload("WBTC:61000:8");
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
            bytes memory redstonePayload = getRedstonePayload("WBTC:61000:8");
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
            bytes memory redstonePayload = getRedstonePayload("WBTC:61000:8");
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
