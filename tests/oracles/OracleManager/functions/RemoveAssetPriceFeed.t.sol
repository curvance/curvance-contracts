// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";

contract RemoveAssetPriceFeedTest is TestBaseOracleManager {
    function test_removeAssetPriceFeed_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(1));

        vm.expectRevert(OracleManager.OracleManager__Unauthorized.selector);
        oracleManager.removeAssetPriceFeed(
            _USDC_ADDRESS,
            address(chainlinkAdaptor)
        );
    }

    function test_removeAssetPriceFeed_fail_whenNoFeedsAvailable() public {
        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        oracleManager.removeAssetPriceFeed(
            _USDC_ADDRESS,
            address(chainlinkAdaptor)
        );
    }

    function test_removeAssetPriceFeed_fail_whenSingleFeedDoesNotExist()
        public
    {
        _addSinglePriceFeed();

        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        oracleManager.removeAssetPriceFeed(_USDC_ADDRESS, address(1));
    }

    function test_removeAssetPriceFeed_fail_whenDualFeedDoesNotExist() public {
        _addDualPriceFeed();

        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        oracleManager.removeAssetPriceFeed(_USDC_ADDRESS, address(1));
    }

    function test_removeAssetPriceFeed_success_whenRemoveSingleFeed() public {
        _addSinglePriceFeed();

        assertEq(
            oracleManager.assetPriceFeeds(_USDC_ADDRESS, 0),
            address(chainlinkAdaptor)
        );

        oracleManager.removeAssetPriceFeed(
            _USDC_ADDRESS,
            address(chainlinkAdaptor)
        );

        vm.expectRevert();
        oracleManager.assetPriceFeeds(_USDC_ADDRESS, 0);
    }

    function test_removeAssetPriceFeed_success_whenRemoveDualFeed() public {
        _addDualPriceFeed();

        assertEq(
            oracleManager.assetPriceFeeds(_USDC_ADDRESS, 0),
            address(chainlinkAdaptor)
        );
        assertEq(
            oracleManager.assetPriceFeeds(_USDC_ADDRESS, 1),
            address(dualChainlinkAdaptor)
        );

        oracleManager.removeAssetPriceFeed(
            _USDC_ADDRESS,
            address(chainlinkAdaptor)
        );

        assertEq(
            oracleManager.assetPriceFeeds(_USDC_ADDRESS, 0),
            address(dualChainlinkAdaptor)
        );

        vm.expectRevert();
        oracleManager.assetPriceFeeds(_USDC_ADDRESS, 1);
    }
}
