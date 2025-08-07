// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseOracleManager } from "tests/oracles/OracleManager/TestBaseOracleManager.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";
import { IOracleAdaptor } from "contracts/interfaces/IOracleAdaptor.sol";

contract TestChainlinkAdaptor is TestBaseOracleManager {

    address constant SNX_ETH_PRICEFEED = 0x79291A9d692Df95334B1a0B3B4AE6bC606782f8c;
    address constant SNX_USD_PRICEFEED = 0xDC3EA94CD0AC27d9A86C180091e7f78C683d3699;

    address constant SNX_ADDRESS = 0xC011a73ee8576Fb46F5E1c5751cA3B9Fe0af2a6F;

    MockV3Aggregator internal snxEthPriceFeed;
    MockV3Aggregator internal snxUsdPriceFeed;

    event AssetAdded(
        address asset,
        ChainlinkAdaptor.AssetConfig assetConfig,
        bool isUpdate
    );

    function setUp() public override {
        super.setUp();
        
        snxEthPriceFeed = new MockV3Aggregator(8, 1e8, 1e11, 1e6);
        snxUsdPriceFeed = new MockV3Aggregator(8, 1e8, 1e11, 1e6);

        // Reinitialized because we're forking a different block than the base test
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
    }

    function test_success_AddPriceFeeds() public {
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
        
        // Test USD configuration
        {
            (
                bool isConfigured,
                IChainlink aggregator,
                uint256 decimals,
                uint256 heartbeat,
                uint256 reportedMax,
                uint256 reportedMin
            ) = chainlinkAdaptor.assetConfig(SNX_ADDRESS, true);

            assertEq(address(aggregator), address(snxUsdPriceFeed));
            assertTrue(isConfigured);

            assertEq(decimals, 8);
            assertEq(heartbeat, chainlinkAdaptor.DEFAULT_HEART_BEAT());

            // Assert USD adaptor data
            // buffered max: 1e11 * 9/10
            // buffered min: 1e6 * 11/10
            assertEq(reportedMax, (1e11 * 9) / 10);
            assertEq(reportedMin, (1e6 * 11) / 10);
        }

        // Add native feed
        chainlinkAdaptor.addAsset(
            SNX_ADDRESS,
            address(snxEthPriceFeed),
            0,
            false
        );

        // Test native configuration
        {
            (
                bool nativeIsConfigured,
                IChainlink nativeAggregator,
                uint256 nativeDecimals,
                uint256 nativeHeartbeat,
                uint256 nativeReportedMax,
                uint256 nativeReportedMin
            ) = chainlinkAdaptor.assetConfig(
                SNX_ADDRESS,
                false
            );
            
            // Assert native adaptor data
            assertEq(address(nativeAggregator), address(snxEthPriceFeed));
            assertTrue(nativeIsConfigured);

            assertEq(nativeDecimals, 8);
            assertEq(nativeHeartbeat, chainlinkAdaptor.DEFAULT_HEART_BEAT());

            assertEq(nativeReportedMax, (1e11 * 9) / 10);
            assertEq(nativeReportedMin, (1e6 * 11) / 10);
        }

        // Verify both configurations are still valid
        {
            (bool isConfigured,,,,,) = chainlinkAdaptor.assetConfig(SNX_ADDRESS, true);
            (bool nativeIsConfigured,,,,,) = chainlinkAdaptor.assetConfig(SNX_ADDRESS, false);
            
            assertTrue(isConfigured);
            assertTrue(nativeIsConfigured);
        }

        // Should successfully add to oracle manager
        oracleManager.addAssetPriceFeed(
            SNX_ADDRESS,
            address(chainlinkAdaptor)
        );
    }

    function test_fail_UnauthorizedAddPriceFeed() public {

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

    function test_success_RemovePriceFeeds() public {
        test_success_AddPriceFeeds();

        chainlinkAdaptor.removeAsset(SNX_ADDRESS);

        // Assert USD adaptor data is cleared
        (
            bool isConfigured,
            IChainlink aggregator,
            uint256 decimals,
            uint256 heartbeat,
            uint256 reportedMax,
            uint256 reportedMin
        ) = chainlinkAdaptor.assetConfig(
            SNX_ADDRESS,
            true
        );

        assertEq(address(aggregator), address(0));
        assertFalse(isConfigured);
        assertEq(decimals, 0);
        assertEq(heartbeat, 0);
        assertEq(reportedMax, 0);
        assertEq(reportedMin, 0);
    }

    function test_fail_UnauthorizedRemovePriceFeed() public {

        test_success_AddPriceFeeds();

        vm.startPrank(user1);

        vm.expectRevert(abi.encodeWithSelector(
            BaseOracleAdaptor.BaseOracleAdaptor__Unauthorized.selector,
            address(this)
        ));

        chainlinkAdaptor.removeAsset(SNX_ADDRESS);

        vm.stopPrank();
    }

    function test_success_UpdateExistingAsset() public {

        chainlinkAdaptor.addAsset(
            SNX_ADDRESS,
            address(snxUsdPriceFeed),
            3600, // custom heartbeat
            true
        );
        
        (
            bool isConfigured,
            IChainlink aggregator,
            uint8 decimals,
            uint24 heartbeat,
            uint256 reportedMax,
            uint256 reportedMin
        ) = chainlinkAdaptor.assetConfig(
            SNX_ADDRESS,
            true
        );

        // Assert initial heartbeat
        assertEq(heartbeat, 3600);

        vm.expectEmit(true, false, false, false);

        emit AssetAdded(SNX_ADDRESS, ChainlinkAdaptor.AssetConfig(
            isConfigured, aggregator, decimals, heartbeat, reportedMax, reportedMin
            ), true
        );
        
        chainlinkAdaptor.addAsset(
            SNX_ADDRESS,
            address(snxUsdPriceFeed),
            7200,
            true
        );

        // Verify updated heartbeat
        (,,, uint256 updatedHeartbeat,,) = chainlinkAdaptor.assetConfig(
            SNX_ADDRESS,
            true
        );
        assertEq(updatedHeartbeat, 7200);
    }

    function test_fail_InvalidHeartbeat() public {
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
    function test_fail_InvalidMinMaxConfig() public {

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
        vm.expectRevert(BaseOracleAdaptor.BaseOracleAdaptor__AssetIsNotSupported.selector);
        chainlinkAdaptor.getPrice(SNX_ADDRESS, true, false);
    }

    function test_success_GetPriceUSD() public {

        snxUsdPriceFeed.updateAnswer(150e8);
        snxUsdPriceFeed.updateRoundData(1, 150e8, block.timestamp, block.timestamp);
        
        chainlinkAdaptor.addAsset(SNX_ADDRESS, address(snxUsdPriceFeed), 0, true);
        
        // Get USD price
        IOracleAdaptor.PricingResult memory result =
            chainlinkAdaptor.getPrice(SNX_ADDRESS, true, false);
        
        assertFalse(result.hadError);
        assertTrue(result.inUSD);

        assertEq(result.price, 150e18);
    }

    function test_success_GetPriceNative() public {

        snxEthPriceFeed.updateAnswer(0.1e8); // 0.1 ETH
        snxEthPriceFeed.updateRoundData(1, 0.1e8, block.timestamp, block.timestamp);
        
        chainlinkAdaptor.addAsset(SNX_ADDRESS, address(snxEthPriceFeed), 0, false);
        
        IOracleAdaptor.PricingResult memory result =
            chainlinkAdaptor.getPrice(SNX_ADDRESS, false, false);
        
        assertFalse(result.hadError);
        assertFalse(result.inUSD);

        assertEq(result.price, 1e17);
    }

    function test_success_GetPriceFallbackUSDToNative() public {
        // Only add native
        snxEthPriceFeed.updateAnswer(0.1e8); // 0.1 ETH
        snxEthPriceFeed.updateRoundData(1, 0.1e8, block.timestamp, block.timestamp);
        chainlinkAdaptor.addAsset(SNX_ADDRESS, address(snxEthPriceFeed), 0, false);
        
        // fallback to native
        IOracleAdaptor.PricingResult memory result =
            chainlinkAdaptor.getPrice(SNX_ADDRESS, true, false);
        
        assertFalse(result.hadError);
        assertFalse(result.inUSD);

        assertEq(result.price, 1e17);
    }

    function test_success_GetPriceFallbackNativeToUSD() public {
        // Only add USD feed
        snxUsdPriceFeed.updateAnswer(150e8);
        snxUsdPriceFeed.updateRoundData(1, 150e8, block.timestamp, block.timestamp);
        chainlinkAdaptor.addAsset(SNX_ADDRESS, address(snxUsdPriceFeed), 0, true);
        
        // should fallback to USD
        IOracleAdaptor.PricingResult memory result =
            chainlinkAdaptor.getPrice(SNX_ADDRESS, false, false);
        
        assertFalse(result.hadError);
        assertTrue(result.inUSD);

        assertEq(result.price, 150e18);
    }

    function test_success_GetPricePreferConfiguredFeed() public {

        snxUsdPriceFeed.updateAnswer(150e8);
        snxUsdPriceFeed.updateRoundData(1, 150e8, block.timestamp, block.timestamp);
        snxEthPriceFeed.updateAnswer(0.1e8);
        snxEthPriceFeed.updateRoundData(1, 0.1e8, block.timestamp, block.timestamp);
        
        chainlinkAdaptor.addAsset(SNX_ADDRESS, address(snxUsdPriceFeed), 0, true);
        chainlinkAdaptor.addAsset(SNX_ADDRESS, address(snxEthPriceFeed), 0, false);
        
        // Will use USD feed
        IOracleAdaptor.PricingResult memory usdPriceData =
            chainlinkAdaptor.getPrice(SNX_ADDRESS, true, false);
        assertFalse(usdPriceData.hadError);
        assertTrue(usdPriceData.inUSD);

        assertGt(usdPriceData.price, 0);
        
        // Will use native feed
        IOracleAdaptor.PricingResult memory nativePriceData =
            chainlinkAdaptor.getPrice(SNX_ADDRESS, false, false);
        assertFalse(nativePriceData.hadError);
        assertFalse(nativePriceData.inUSD);
        
        assertGt(nativePriceData.price, 0);
    }

    function test_fail_NegativePrice() public {

        chainlinkAdaptor.addAsset(SNX_ADDRESS, address(snxUsdPriceFeed), 0, true);

        // Test negative price
        snxUsdPriceFeed.updateAnswer(-100e8);
        snxUsdPriceFeed.updateRoundData(1, -100e8, block.timestamp, block.timestamp);
        IOracleAdaptor.PricingResult memory result =
            chainlinkAdaptor.getPrice(SNX_ADDRESS, true, false);

        assertTrue(result.hadError);
    }

    function test_fail_StalePrice() public {

        chainlinkAdaptor.addAsset(SNX_ADDRESS, address(snxUsdPriceFeed), 0, true);

        // Test stale price
        snxUsdPriceFeed.updateAnswer(150e8);
        snxUsdPriceFeed.updateRoundData(
            1, 
            150e8, 
            block.timestamp - chainlinkAdaptor.DEFAULT_HEART_BEAT() - 1
            , block.timestamp - chainlinkAdaptor.DEFAULT_HEART_BEAT() - 1);
        
        IOracleAdaptor.PricingResult memory result =
            chainlinkAdaptor.getPrice(SNX_ADDRESS, true, false);

        assertTrue(result.hadError);
    }

    function test_fail_ZeroPrice() public {

        chainlinkAdaptor.addAsset(SNX_ADDRESS, address(snxUsdPriceFeed), 0, true);

        // Test zero price
        snxUsdPriceFeed.updateAnswer(0);
        snxUsdPriceFeed.updateRoundData(1, 0, block.timestamp, block.timestamp);
        IOracleAdaptor.PricingResult memory result =
            chainlinkAdaptor.getPrice(SNX_ADDRESS, true, false);

        assertTrue(result.hadError);
    }

    function test_fail_AboveBufferedMax() public {

        chainlinkAdaptor.addAsset(SNX_ADDRESS, address(snxUsdPriceFeed), 0, true);

        // Test above buffered max
        snxUsdPriceFeed.updateAnswer(1e11);
        snxUsdPriceFeed.updateRoundData(1, 1e11, block.timestamp, block.timestamp);
        IOracleAdaptor.PricingResult memory result =
            chainlinkAdaptor.getPrice(SNX_ADDRESS, true, false);

        assertTrue(result.hadError);
    }

    function test_fail_BelowBufferedMin() public {

        chainlinkAdaptor.addAsset(SNX_ADDRESS, address(snxUsdPriceFeed), 0, true);

        // Test below buffered min
        snxUsdPriceFeed.updateAnswer(1e6);
        snxUsdPriceFeed.updateRoundData(1, 1e6, block.timestamp, block.timestamp);

        IOracleAdaptor.PricingResult memory result =
            chainlinkAdaptor.getPrice(SNX_ADDRESS, true, false);

        assertTrue(result.hadError);
    }
}