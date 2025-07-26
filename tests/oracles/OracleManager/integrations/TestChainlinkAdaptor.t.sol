// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseOracleManager } from "tests/oracles/OracleManager/TestBaseOracleManager.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";
import { PriceReturnData } from "contracts/interfaces/IOracleAdaptor.sol";

contract TestChainlinkAdaptor is TestBaseOracleManager {

    address constant SNX_ETH_PRICEFEED = 0x79291A9d692Df95334B1a0B3B4AE6bC606782f8c;
    address constant SNX_USD_PRICEFEED = 0xDC3EA94CD0AC27d9A86C180091e7f78C683d3699;

    address constant SNX_ADDRESS = 0xC011a73ee8576Fb46F5E1c5751cA3B9Fe0af2a6F;

    MockV3Aggregator internal snxEthPriceFeed;
    MockV3Aggregator internal snxUsdPriceFeed;

    event ChainlinkAssetAdded(
        address asset,
        ChainlinkAdaptor.AdaptorData assetConfig,
        bool isUpdate
    );

    function setUp() public override {
        super.setUp();
        
        snxEthPriceFeed = new MockV3Aggregator(8, 1e8, 1e11, 1e6);
        snxUsdPriceFeed = new MockV3Aggregator(8, 1e8, 1e11, 1e6);

        // Reinitialized because we're forking a different block than the base test
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
    }

    function testAddPriceFeeds() public {
        // Assert asset not supported initially
        assertFalse(chainlinkAdaptor.isSupportedAsset(SNX_ADDRESS));
        
        // Add usd feed
        chainlinkAdaptor.addAsset(
            SNX_ADDRESS,
            address(snxUsdPriceFeed),
            0,
            true
        );

        // Assert asset is now supported
        assertTrue(chainlinkAdaptor.isSupportedAsset(SNX_ADDRESS));
        
        (
            IChainlink aggregator,
            bool isConfigured,
            uint256 decimals,
            uint256 heartbeat,
            uint256 reportedMax,
            uint256 reportedMin,
            uint256 max,
            uint256 min
        ) = chainlinkAdaptor.adaptorDataUSD(SNX_ADDRESS);

        assertEq(address(aggregator), address(snxUsdPriceFeed));
        assertTrue(isConfigured);

        assertEq(decimals, 8);
        assertEq(heartbeat, chainlinkAdaptor.DEFAULT_HEART_BEAT());

        // Assert USD adaptor data
        // buffered max: 1e11 * 9/10
        // buffered min: 1e6 * 11/10
        assertEq(reportedMax, (1e11 * 9) / 10);
        assertEq(reportedMin, (1e6 * 11) / 10);

        assertEq(max, type(uint240).max);
        assertEq(min, 0);

        // Add native feed
        chainlinkAdaptor.addAsset(
            SNX_ADDRESS,
            address(snxEthPriceFeed),
            0,
            false
        );

        (
            IChainlink nativeAggregator,
            bool nativeIsConfigured,
            uint256 nativeDecimals,
            uint256 nativeHeartbeat,
            uint256 nativeReportedMax,
            uint256 nativeReportedMin,
            uint256 nativeMax,
            uint256 nativeMin
        ) = chainlinkAdaptor.adaptorDataNonUSD(SNX_ADDRESS);
        
        // Assert native adaptor data
        assertEq(address(nativeAggregator), address(snxEthPriceFeed));
        assertTrue(nativeIsConfigured);

        assertEq(nativeDecimals, 8);
        assertEq(nativeHeartbeat, chainlinkAdaptor.DEFAULT_HEART_BEAT());


        assertEq(nativeReportedMax, (1e11 * 9) / 10);
        assertEq(nativeReportedMin, (1e6 * 11) / 10);

        assertEq(nativeMax, type(uint240).max);
        assertEq(nativeMin, 0);

        // Both usd and native should be configured
        assertTrue(isConfigured);
        assertTrue(nativeIsConfigured);

        // Should successfully add to oracle manager
        oracleManager.addAssetPriceFeed(
            SNX_ADDRESS,
            address(chainlinkAdaptor)
        );
    }

    function testUnauthorizedAddPriceFeed() public {

        vm.startPrank(user1);

        vm.expectRevert(abi.encodeWithSelector(
            BaseOracleAdaptor.BaseOracleAdaptor__Unauthorized.selector,
            address(this)
        ));

        chainlinkAdaptor.addAsset(
            SNX_ADDRESS,
            address(snxUsdPriceFeed),
            0,
            true
        );

        vm.stopPrank();
    }

    function testRemovePriceFeeds() public {
        testAddPriceFeeds();

        chainlinkAdaptor.removeAsset(SNX_ADDRESS);

        // Assert USD adaptor data is cleared
        (
            IChainlink aggregator,
            bool isConfigured,
            uint256 decimals,
            uint256 heartbeat,
            uint256 reportedMax,
            uint256 reportedMin,
            uint256 max,
            uint256 min
        ) = chainlinkAdaptor.adaptorDataUSD(SNX_ADDRESS);

        assertEq(address(aggregator), address(0));
        assertFalse(isConfigured);
        assertEq(decimals, 0);
        assertEq(heartbeat, 0);
        assertEq(reportedMax, 0);
        assertEq(reportedMin, 0);
        assertEq(max, 0);
        assertEq(min, 0);
    }

    function testUnauthorizedRemovePriceFeed() public {

        testAddPriceFeeds();

        vm.startPrank(user1);

        vm.expectRevert(abi.encodeWithSelector(
            BaseOracleAdaptor.BaseOracleAdaptor__Unauthorized.selector,
            address(this)
        ));

        chainlinkAdaptor.removeAsset(SNX_ADDRESS);

        vm.stopPrank();
    }

    function testUpdateExistingAsset() public {

        chainlinkAdaptor.addAsset(
            SNX_ADDRESS,
            address(snxUsdPriceFeed),
            3600, // custom heartbeat
            true
        );
        
        (
            IChainlink aggregator,
            bool isConfigured,
            uint256 decimals,
            uint256 heartbeat,
            uint256 reportedMax,
            uint256 reportedMin,
            uint256 max,
            uint256 min
        ) = chainlinkAdaptor.adaptorDataUSD(SNX_ADDRESS);

        // Assert initial heartbeat
        assertEq(heartbeat, 3600);

        vm.expectEmit(true, false, false, false);

        emit ChainlinkAssetAdded(SNX_ADDRESS, ChainlinkAdaptor.AdaptorData(
            aggregator, isConfigured, decimals, heartbeat, reportedMax, reportedMin, max, min
        ), true);
        
        chainlinkAdaptor.addAsset(
            SNX_ADDRESS,
            address(snxUsdPriceFeed),
            7200,
            true
        );

        // Verify updated heartbeat
        (,,, uint256 updatedHeartbeat,,,,) = chainlinkAdaptor.adaptorDataUSD(SNX_ADDRESS);
        assertEq(updatedHeartbeat, 7200);
    }

    function testRevertInvalidHeartbeat() public {
        // Should revert when heartbeat > DEFAULT_HEART_BEAT
        uint256 invalidHeartbeat = chainlinkAdaptor.DEFAULT_HEART_BEAT() + 1;
        
        vm.expectRevert(ChainlinkAdaptor.ChainlinkAdaptor__InvalidHeartbeat.selector);
        chainlinkAdaptor.addAsset(
            SNX_ADDRESS,
            address(snxUsdPriceFeed),
            invalidHeartbeat,
            true
        );
    }

    // minAnswer * 11/10 >= maxAnswer * 9/10
    // minAnswer >= maxAnswer * 9/11
    // maxAnswer = 1000, then minAnswer needs to be >= 818
    // 900 * 11/10 > 1000 * 9/10
    // 990 > 900
    // 900 * 11/10 > 1000 * 9/10
    function testRevertInvalidMinMaxConfig() public {

        MockV3Aggregator invalidFeed = new MockV3Aggregator(
            8,
            1e8,
            1000e8,
            900e8
        );

        vm.expectRevert(ChainlinkAdaptor.ChainlinkAdaptor__InvalidMinMaxConfig.selector);
        chainlinkAdaptor.addAsset(
            SNX_ADDRESS,
            address(invalidFeed),
            0,
            true
        );
    }

    function testGetPriceRevertAssetNotSupported() public {
        // Should revert when asset is not supported
        vm.expectRevert(ChainlinkAdaptor.ChainlinkAdaptor__AssetIsNotSupported.selector);
        chainlinkAdaptor.getPrice(SNX_ADDRESS, true, false);
    }

    function testGetPriceUSD() public {

        snxUsdPriceFeed.updateAnswer(150e8);
        snxUsdPriceFeed.updateRoundData(1, 150e8, block.timestamp, block.timestamp);
        
        chainlinkAdaptor.addAsset(SNX_ADDRESS, address(snxUsdPriceFeed), 0, true);
        
        // Get USD price
        PriceReturnData memory priceData = chainlinkAdaptor.getPrice(SNX_ADDRESS, true, false);
        
        assertFalse(priceData.hadError);
        assertTrue(priceData.inUSD);

        assertEq(priceData.price, 150e18);
    }

    function testGetPriceNative() public {

        snxEthPriceFeed.updateAnswer(0.1e8); // 0.1 ETH
        snxEthPriceFeed.updateRoundData(1, 0.1e8, block.timestamp, block.timestamp);
        
        chainlinkAdaptor.addAsset(SNX_ADDRESS, address(snxEthPriceFeed), 0, false);
        
        PriceReturnData memory priceData = chainlinkAdaptor.getPrice(SNX_ADDRESS, false, false);
        
        assertFalse(priceData.hadError);
        assertFalse(priceData.inUSD);

        assertEq(priceData.price, 1e17);
    }

    function testGetPriceFallbackUSDToNative() public {
        // Only add native
        snxEthPriceFeed.updateAnswer(0.1e8); // 0.1 ETH
        snxEthPriceFeed.updateRoundData(1, 0.1e8, block.timestamp, block.timestamp);
        chainlinkAdaptor.addAsset(SNX_ADDRESS, address(snxEthPriceFeed), 0, false);
        
        // fallback to native
        PriceReturnData memory priceData = chainlinkAdaptor.getPrice(SNX_ADDRESS, true, false);
        
        assertFalse(priceData.hadError);
        assertFalse(priceData.inUSD);

        assertEq(priceData.price, 1e17);
    }

    function testGetPriceFallbackNativeToUSD() public {
        // Only add USD feed
        snxUsdPriceFeed.updateAnswer(150e8);
        snxUsdPriceFeed.updateRoundData(1, 150e8, block.timestamp, block.timestamp);
        chainlinkAdaptor.addAsset(SNX_ADDRESS, address(snxUsdPriceFeed), 0, true);
        
        // should fallback to USD
        PriceReturnData memory priceData = chainlinkAdaptor.getPrice(SNX_ADDRESS, false, false);
        
        assertFalse(priceData.hadError);
        assertTrue(priceData.inUSD);

        assertEq(priceData.price, 150e18);
    }

    function testGetPricePreferConfiguredFeed() public {

        snxUsdPriceFeed.updateAnswer(150e8);
        snxUsdPriceFeed.updateRoundData(1, 150e8, block.timestamp, block.timestamp);
        snxEthPriceFeed.updateAnswer(0.1e8);
        snxEthPriceFeed.updateRoundData(1, 0.1e8, block.timestamp, block.timestamp);
        
        chainlinkAdaptor.addAsset(SNX_ADDRESS, address(snxUsdPriceFeed), 0, true);
        chainlinkAdaptor.addAsset(SNX_ADDRESS, address(snxEthPriceFeed), 0, false);
        
        // Will use USD feed
        PriceReturnData memory usdPriceData = chainlinkAdaptor.getPrice(SNX_ADDRESS, true, false);
        assertFalse(usdPriceData.hadError);
        assertTrue(usdPriceData.inUSD);

        assertGt(usdPriceData.price, 0);
        
        // Will use native feed
        PriceReturnData memory nativePriceData = chainlinkAdaptor.getPrice(SNX_ADDRESS, false, false);
        assertFalse(nativePriceData.hadError);
        assertFalse(nativePriceData.inUSD);
        
        assertGt(nativePriceData.price, 0);
    }

    function testGetPriceEdgeCaseErrors() public {
  
        chainlinkAdaptor.addAsset(SNX_ADDRESS, address(snxUsdPriceFeed), 0, true);
        
        // Test negative price
        snxUsdPriceFeed.updateAnswer(-100e8);
        snxUsdPriceFeed.updateRoundData(1, -100e8, block.timestamp, block.timestamp);
        PriceReturnData memory priceData1 = chainlinkAdaptor.getPrice(SNX_ADDRESS, true, false);

        assertTrue(priceData1.hadError);
        
        // Test zero price
        snxUsdPriceFeed.updateAnswer(0);
        snxUsdPriceFeed.updateRoundData(1, 0, block.timestamp, block.timestamp);
        PriceReturnData memory priceData2 = chainlinkAdaptor.getPrice(SNX_ADDRESS, true, false);

        assertTrue(priceData2.hadError);
        
        // Test stale price
        snxUsdPriceFeed.updateAnswer(150e8);
        snxUsdPriceFeed.updateRoundData(1, 150e8, 
        block.timestamp - chainlinkAdaptor.DEFAULT_HEART_BEAT() - 1, block.timestamp - chainlinkAdaptor.DEFAULT_HEART_BEAT() - 1);
        PriceReturnData memory priceData3 = chainlinkAdaptor.getPrice
        (SNX_ADDRESS, 
        true, 
        false);

        assertTrue(priceData3.hadError);
        
        // Test price above buffered max
        snxUsdPriceFeed.updateAnswer(1e11);
        snxUsdPriceFeed.updateRoundData(1, 1e11, block.timestamp, block.timestamp);
        PriceReturnData memory priceData4 = chainlinkAdaptor.getPrice(SNX_ADDRESS, true, false);
        
        assertTrue(priceData4.hadError);
        
        // Test price below buffered min
        snxUsdPriceFeed.updateAnswer(1e6);
        snxUsdPriceFeed.updateRoundData(1, 1e6, block.timestamp, block.timestamp);
        PriceReturnData memory priceData5 = chainlinkAdaptor.getPrice(SNX_ADDRESS, true, false);

        assertTrue(priceData5.hadError);
    }
}