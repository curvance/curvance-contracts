// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { IMToken } from "contracts/interfaces/market/IMToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPendlePTOracle } from "contracts/interfaces/external/pendle/IPendlePtOracle.sol";
import { PriceReturnData } from "contracts/interfaces/IOracleAdaptor.sol";

import { Multicall } from "contracts/libraries/Multicall.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { PTokenPrimitive } from "contracts/market/token/PTokenPrimitive.sol";
import { MockRedstoneCoreAdaptor } from "contracts/mocks/MockRedstoneCoreAdaptor.sol";
import { MulticallDataCheckerBase } from "contracts/market/multicall-checker/MulticallDataCheckerBase.sol";
import { MulticallDataCheckerForRedstoneAdaptor } from "contracts/market/multicall-checker/MulticallDataCheckerForRedstoneAdaptor.sol";

import "tests/market/TestBaseMarket.sol";

contract User {}

contract TestMulticallWithRedstoneAdaptor is TestBaseMarket {
    address public owner;

    MockRedstoneCoreAdaptor public adapter;
    MulticallDataCheckerForRedstoneAdaptor public multicallDataChecker;

    MockDataFeed public mockUsdcFeed;
    MockDataFeed public mockWethFeed;
    MockDataFeed public mockStethFeed;

    PTokenPrimitive public cWBTC;

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
            1
        );
        adapter.addAsset(_WBTC_ADDRESS, true, 8, 12 hours);
        adapter.addAsset(_WBTC_ADDRESS, false, 18, 12 hours);

        multicallDataChecker = new MulticallDataCheckerForRedstoneAdaptor(
            address(centralRegistry)
        );
        centralRegistry.setMulticallDataChecker(
            address(adapter),
            address(multicallDataChecker)
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

        // deploy cWBTC
        {
            // deploy aura position vault
            cWBTC = new PTokenPrimitive(
                ICentralRegistry(address(centralRegistry)),
                wbtc,
                address(marketManager)
            );

            // support market
            _prepareWBTC(owner, 1e8);
            wbtc.approve(address(cWBTC), 1e8);
            marketManager.listToken(address(cWBTC));
            // add MToken support on oracle manager
            oracleManager.addMTokenSupport(address(cWBTC));
            // set collateral token configuration
            marketManager.updatePositionToken(
                IMToken(address(cWBTC)),
                7000,
                4000, // liquidate at 71%
                3000,
                200, // 2% liq incentive
                400,
                0,
                1000
            );

            address[] memory mTokens = new address[](1);
            mTokens[0] = address(cWBTC);
            uint256[] memory caps = new uint256[](1);
            caps[0] = 100e8;
            marketManager.setPTokenCollateralCaps(mTokens, caps);

            // address[] memory markets = new address[](1);
            // markets[0] = address(cWBTC);
            // vm.prank(user1);
            // marketManager.enterMarkets(markets);
            // vm.prank(user2);
            // marketManager.enterMarkets(markets);
        }

        // provide enough liquidity
        provideEnoughLiquidityForLeverage();
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
        wbtc.approve(address(cWBTC), 10 ether);
        cWBTC.mint(10 ether, liquidityProvider);
        vm.stopPrank();
    }

    function testInitialize() public {
        assertTrue(cWBTC.isPToken());
        assertFalse(eUSDC.isPToken());
    }

    function testPTokenMintMulticall() public {
        _prepareWBTC(user1, 2 ether);

        vm.prank(user1);
        wbtc.approve(address(cWBTC), 1e8);

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

        calls[1].target = address(cWBTC);
        calls[1].data = abi.encodeWithSelector(
            cWBTC.mint.selector,
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

    function testCheckCallData() public {
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
                MulticallDataCheckerBase
                    .MulticallDataChecker__TargetError
                    .selector
            );
            multicallDataChecker.checkCallData(
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
                MulticallDataCheckerBase
                    .MulticallDataChecker__InvalidFuncSig
                    .selector
            );
            multicallDataChecker.checkCallData(
                address(this),
                address(adapter),
                encodedFunctionWithRedstonePayload
            );
        }
    }
}
