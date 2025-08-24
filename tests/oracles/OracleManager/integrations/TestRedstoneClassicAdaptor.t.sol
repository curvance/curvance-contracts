// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseOracleManager } from "tests/oracles/OracleManager/TestBaseOracleManager.sol";
import { IRedstone } from "contracts/interfaces/external/redstone/IRedstone.sol";
import { RedstoneClassicAdaptor } from "contracts/oracles/adaptors/redstone/RedstoneClassicAdaptor.sol";
import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";
import { IOracleAdaptor } from "contracts/interfaces/IOracleAdaptor.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { MockRedstoneClassicFeed } from "contracts/mocks/MockRedstoneClassicFeed.sol";
import { console2 } from "forge-std/console2.sol";

contract TestRedstoneClassicAdaptor is TestBaseOracleManager {

    address constant ETHX_ETH_PRICEFEED = 0xc799194cAa24E2874Efa89b4Bf5c92a530B047FF;
    address constant ETHX_USD_PRICEFEED = 0xFaBEb1474C2Ab34838081BFdDcE4132f640E7D2d;

    address constant ETHX_ADDRESS = 0xA35b1B31Ce002FBF2058D22F30f95D405200A15b;

    RedstoneClassicAdaptor internal redstoneClassicAdaptor;
    MockRedstoneClassicFeed internal mockEthxUsdPriceFeed;

    event AssetAdded(
        address asset,
        RedstoneClassicAdaptor.AssetConfig assetConfig,
        bool isUpdate
    );

    function setUp() public override {
        // Fork latest mainnet block so Redstone price feeds exist
        _fork(23141314);
        
        _deployCentralRegistry();
        _deployDAOTimelock();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployOracleManager();
        _deployGaugeManager();
        _deployMarketManager();
        _deployBorrowableCUSDC();

        vm.warp(centralRegistry.genesisEpoch());

        redstoneClassicAdaptor = new RedstoneClassicAdaptor(ICentralRegistry(address(centralRegistry)));
        oracleManager.addApprovedAdaptor(address(redstoneClassicAdaptor));

        mockEthxUsdPriceFeed = new MockRedstoneClassicFeed(8, 483704167727, "ETHx");
    }

    function test_success_AddPriceFeeds() public {
        console2.log("chain id", block.chainid);
        
        // Assert asset not supported initially
        assertFalse(redstoneClassicAdaptor.isSupportedAsset(ETHX_ADDRESS));

        redstoneClassicAdaptor.addAsset(
            ETHX_ADDRESS,
            true,
            ETHX_USD_PRICEFEED,
            0,
            "ETHx"
        );

        // Assert asset is now supported
        assertTrue(redstoneClassicAdaptor.isSupportedAsset(ETHX_ADDRESS));
        
        // Test USD configuration
        {
            (
                bool isConfigured,
                IRedstone aggregator,
                uint256 decimals,
                uint256 heartbeat
            ) = redstoneClassicAdaptor.assetConfig(ETHX_ADDRESS, true);

            assertEq(address(aggregator), ETHX_USD_PRICEFEED);
            assertTrue(isConfigured);

            assertEq(decimals, 8);
            assertEq(heartbeat, redstoneClassicAdaptor.DEFAULT_HEARTBEAT());
        }

        redstoneClassicAdaptor.addAsset(
            ETHX_ADDRESS,
            false,
            ETHX_ETH_PRICEFEED,
            0,
            "ETHx/ETH"
        );

        // Test native configuration
        {
            (
                bool nativeIsConfigured,
                IRedstone nativeAggregator,
                uint256 nativeDecimals,
                uint256 nativeHeartbeat
            ) = redstoneClassicAdaptor.assetConfig(
                ETHX_ADDRESS,
                false
            );
            
            // Assert native adaptor data
            assertEq(address(nativeAggregator), ETHX_ETH_PRICEFEED);
            assertTrue(nativeIsConfigured);

            assertEq(nativeDecimals, 8);
            assertEq(nativeHeartbeat, redstoneClassicAdaptor.DEFAULT_HEARTBEAT());
        }

        // Verify both configurations are still valid
        {
            (bool isConfigured,,,) = redstoneClassicAdaptor.assetConfig(ETHX_ADDRESS, true);
            (bool nativeIsConfigured,,,) = redstoneClassicAdaptor.assetConfig(ETHX_ADDRESS, false);
            
            assertTrue(isConfigured);
            assertTrue(nativeIsConfigured);
        }

        // Should successfully add to oracle manager
        oracleManager.addAssetPriceFeed(
            ETHX_ADDRESS,
            address(redstoneClassicAdaptor)
        );
    }

    function test_fail_UnauthorizedAddPriceFeed() public {

        vm.startPrank(user1);

        vm.expectRevert(abi.encodeWithSelector(
            BaseOracleAdaptor.BaseOracleAdaptor__Unauthorized.selector,
            address(this)
        ));

        redstoneClassicAdaptor.addAsset(
            ETHX_ADDRESS,
            true,
            ETHX_USD_PRICEFEED,
            0,
            "ETHx"
        );

        vm.stopPrank();
    }

    function test_success_RemovePriceFeeds() public {
        test_success_AddPriceFeeds();

        redstoneClassicAdaptor.removeAsset(ETHX_ADDRESS);

        // Assert USD adaptor data is cleared
        (
            bool isConfigured,
            IRedstone aggregator,
            uint256 decimals,
            uint256 heartbeat
        ) = redstoneClassicAdaptor.assetConfig(
            ETHX_ADDRESS,
            true
        );

        assertEq(address(aggregator), address(0));
        assertFalse(isConfigured);
        assertEq(decimals, 0);
        assertEq(heartbeat, 0);
    }

    function test_fail_UnauthorizedRemovePriceFeed() public {

        test_success_AddPriceFeeds();

        vm.startPrank(user1);

        vm.expectRevert(abi.encodeWithSelector(
            BaseOracleAdaptor.BaseOracleAdaptor__Unauthorized.selector,
            address(this)
        ));

        redstoneClassicAdaptor.removeAsset(ETHX_ADDRESS);

        vm.stopPrank();
    }

    function test_success_UpdateExistingAsset() public {

        redstoneClassicAdaptor.addAsset(
            ETHX_ADDRESS,
            true,
            ETHX_USD_PRICEFEED,
            3600, // custom heartbeat
            "ETHx"
        );
        
        (
            bool isConfigured,
            IRedstone aggregator,
            uint8 decimals,
            uint24 heartbeat
        ) = redstoneClassicAdaptor.assetConfig(
            ETHX_ADDRESS,
            true
        );

        // Assert initial heartbeat
        assertEq(heartbeat, 3600);

        vm.expectEmit(true, false, false, false);

        emit AssetAdded(ETHX_ADDRESS, RedstoneClassicAdaptor.AssetConfig(
            isConfigured, aggregator, decimals, heartbeat
            ), true
        );
        
        redstoneClassicAdaptor.addAsset(
            ETHX_ADDRESS,
            true,
            ETHX_USD_PRICEFEED,
            7200,
            "ETHx"
        );

        // Verify updated heartbeat
        (,,, uint256 updatedHeartbeat) = redstoneClassicAdaptor.assetConfig(
            ETHX_ADDRESS,
            true
        );
        assertEq(updatedHeartbeat, 7200);
    }

    function test_fail_InvalidHeartbeat() public {
        // Should revert when heartbeat > DEFAULT_HEARTBEAT
        uint256 invalidHeartbeat = redstoneClassicAdaptor.DEFAULT_HEARTBEAT() + 1;
        
        vm.expectRevert(abi.encodeWithSelector(
            RedstoneClassicAdaptor.RedstoneClassicAdaptor__InvalidHeartbeat.selector
        ));
        redstoneClassicAdaptor.addAsset(
            ETHX_ADDRESS,
            true,
            ETHX_USD_PRICEFEED,
            invalidHeartbeat,
            "ETHx"
        );
    }

    function testGetPriceRevertAssetNotSupported() public {
        // Should revert when asset is not supported
        vm.expectRevert(BaseOracleAdaptor.BaseOracleAdaptor__AssetIsNotSupported.selector);
        redstoneClassicAdaptor.getPrice(ETHX_ADDRESS, true, false);
    }

    function test_success_GetPriceUSD() public {

        redstoneClassicAdaptor.addAsset(
            ETHX_ADDRESS,
            true,
            ETHX_USD_PRICEFEED,
            0,
            "ETHx"
        );
        
        // Get USD price
        IOracleAdaptor.PricingResult memory result =
            redstoneClassicAdaptor.getPrice(ETHX_ADDRESS, true, false);
        
        assertFalse(result.hadError);
        assertTrue(result.inUSD);
        assertEq(result.price, 4837041677270000000000); // $4837.04167727

    }

    function test_success_GetPriceNative() public {

        redstoneClassicAdaptor.addAsset(
            ETHX_ADDRESS,
            false,
            ETHX_ETH_PRICEFEED,
            0,
            "ETHx/ETH"
        );
        
        IOracleAdaptor.PricingResult memory result =
            redstoneClassicAdaptor.getPrice(ETHX_ADDRESS, false, false);
        
        assertFalse(result.hadError);
        assertFalse(result.inUSD);
        assertEq(result.price, 1063610170000000000); // 1.06361017 ETH

    }

    function test_success_GetPriceFallbackUSDToNative() public {
        // Only add native
        redstoneClassicAdaptor.addAsset(
            ETHX_ADDRESS,
            false,
            ETHX_ETH_PRICEFEED,
            0,
            "ETHx/ETH"
        );
        
        // fallback to native
        IOracleAdaptor.PricingResult memory result =
            redstoneClassicAdaptor.getPrice(ETHX_ADDRESS, true, false);
        
        assertFalse(result.hadError);
        assertFalse(result.inUSD);
        assertEq(result.price, 1063610170000000000); // 1.06361017 ETH
    }

    function test_success_GetPriceFallbackNativeToUSD() public {
        // Only add USD feed
        redstoneClassicAdaptor.addAsset(
            ETHX_ADDRESS,
            true,
            ETHX_USD_PRICEFEED,
            0,
            "ETHx"
        );
        
        // should fallback to USD
        IOracleAdaptor.PricingResult memory result =
            redstoneClassicAdaptor.getPrice(ETHX_ADDRESS, false, false);
        
        assertFalse(result.hadError);
        assertTrue(result.inUSD);
        assertEq(result.price, 4837041677270000000000); // $4837.04167727
    }

    function test_success_GetPricePreferConfiguredFeed() public {

        redstoneClassicAdaptor.addAsset(
            ETHX_ADDRESS,
            true,
            ETHX_USD_PRICEFEED,
            0,
            "ETHx"
        );
        redstoneClassicAdaptor.addAsset(
            ETHX_ADDRESS,
            false,
            ETHX_ETH_PRICEFEED,
            0,
            "ETHx/ETH"
        );
        
        // Will use USD feed
        IOracleAdaptor.PricingResult memory usdPriceData =
            redstoneClassicAdaptor.getPrice(ETHX_ADDRESS, true, false);
        assertFalse(usdPriceData.hadError);
        assertTrue(usdPriceData.inUSD);
        assertEq(usdPriceData.price, 4837041677270000000000); // $4837.04167727
        
        // Will use native feed
        IOracleAdaptor.PricingResult memory nativePriceData =
            redstoneClassicAdaptor.getPrice(ETHX_ADDRESS, false, false);
        assertFalse(nativePriceData.hadError);
        assertFalse(nativePriceData.inUSD);
        assertEq(nativePriceData.price, 1063610170000000000); // 1.06361017 ETH
    }

    function test_success_GetMockPriceUSD() public {
        redstoneClassicAdaptor.addAsset(
            ETHX_ADDRESS,
            true,
            address(mockEthxUsdPriceFeed),
            0,
            "ETHx"
        );

        mockEthxUsdPriceFeed.updateAnswer(100e8);

        IOracleAdaptor.PricingResult memory result =
            redstoneClassicAdaptor.getPrice(ETHX_ADDRESS, true, false);

        assertFalse(result.hadError);
        assertTrue(result.inUSD);
        assertEq(result.price, 100e18); // $100
    }

    function test_fail_NegativePrice() public {

        redstoneClassicAdaptor.addAsset(
            ETHX_ADDRESS,
            true,
            address(mockEthxUsdPriceFeed),
            0,
            "ETHx"
        );

        mockEthxUsdPriceFeed.updateAnswer(-100e8);

        IOracleAdaptor.PricingResult memory result =
            redstoneClassicAdaptor.getPrice(ETHX_ADDRESS, true, false);

        assertTrue(result.hadError);
    }

    function test_fail_StalePrice() public {

        redstoneClassicAdaptor.addAsset(
            ETHX_ADDRESS,
            true,
            address(mockEthxUsdPriceFeed),
            0,
            "ETHx"
        );
        
        mockEthxUsdPriceFeed.updateRoundData(
            100e8,
            block.timestamp - redstoneClassicAdaptor.DEFAULT_HEARTBEAT() - 1,
            block.timestamp - redstoneClassicAdaptor.DEFAULT_HEARTBEAT() - 1
        );

        IOracleAdaptor.PricingResult memory result =
            redstoneClassicAdaptor.getPrice(ETHX_ADDRESS, true, false);

        assertTrue(result.hadError);
        
    }

    function test_fail_ZeroPrice() public {

        redstoneClassicAdaptor.addAsset(
            ETHX_ADDRESS,
            true,
            address(mockEthxUsdPriceFeed),
            0,
            "ETHx"
        );

        mockEthxUsdPriceFeed.updateAnswer(0);

        IOracleAdaptor.PricingResult memory result =
            redstoneClassicAdaptor.getPrice(ETHX_ADDRESS, true, false);

        assertTrue(result.hadError);
    }
}