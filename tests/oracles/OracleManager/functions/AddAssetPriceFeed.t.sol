// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";

contract AddAssetPriceFeedTest is TestBaseOracleManager {
    function test_addAssetPriceFeed_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(OracleManager.OracleManager__Unauthorized.selector);
        oracleManager.addAssetPriceFeed(
            _USDC_ADDRESS,
            address(chainlinkAdaptor)
        );
    }

    function test_addAssetPriceFeed_fail_whenAdaptorIsNotApproved() public {
        vm.expectRevert(
            OracleManager.OracleManager__AdaptorIsNotApproved.selector
        );
        oracleManager.addAssetPriceFeed(
            _USDC_ADDRESS,
            address(chainlinkAdaptor)
        );
    }

    function test_addAssetPriceFeed_fail_whenDualFeedIsAlreadyConfigured()
        public
    {
        _addDualPriceFeed();

        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.addAssetPriceFeed(
            _USDC_ADDRESS,
            address(dualChainlinkAdaptor)
        );
    }

    function test_addAssetPriceFeed_fail_whenFeedAlreadyAdded() public {
        _addSinglePriceFeed();

        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.addAssetPriceFeed(
            _USDC_ADDRESS,
            address(chainlinkAdaptor)
        );
    }

    function test_addAssetPriceFeed_fail_whenAssetIsNotSupported() public {
        _addSinglePriceFeed();

        chainlinkAdaptor.removeAsset(_USDC_ADDRESS);

        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.addAssetPriceFeed(
            _USDC_ADDRESS,
            address(chainlinkAdaptor)
        );
    }

    function test_addAssetPriceFeed_success() public {
        vm.expectRevert();
        oracleManager.assetPriceFeeds(_USDC_ADDRESS, 0);

        vm.expectRevert();
        oracleManager.assetPriceFeeds(_USDC_ADDRESS, 1);

        _addDualPriceFeed();

        assertEq(
            oracleManager.assetPriceFeeds(_USDC_ADDRESS, 0),
            address(chainlinkAdaptor)
        );
        assertEq(
            oracleManager.assetPriceFeeds(_USDC_ADDRESS, 1),
            address(dualChainlinkAdaptor)
        );

        assertTrue(oracleManager.isSupportedAsset(_USDC_ADDRESS));
    }
}
