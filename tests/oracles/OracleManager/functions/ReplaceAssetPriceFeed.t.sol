// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";

contract ReplaceAssetPriceFeedTest is TestBaseOracleManager {
    function test_replaceAssetPriceFeed_fail_whenCallerIsNotAuthorized()
        public
    {
        _addSinglePriceFeed();

        vm.prank(address(1));

        vm.expectRevert(OracleManager.OracleManager__Unauthorized.selector);
        oracleManager.replaceAssetPriceFeed(
            _USDC_ADDRESS,
            address(chainlinkAdaptor),
            address(dualChainlinkAdaptor)
        );
    }

    function test_replaceAssetPriceFeed_fail_whenAdaptorIsNotApproved()
        public
    {
        _addSinglePriceFeed();

        vm.expectRevert(
            OracleManager.OracleManager__AdaptorIsNotApproved.selector
        );
        oracleManager.replaceAssetPriceFeed(
            _USDC_ADDRESS,
            address(chainlinkAdaptor),
            address(dualChainlinkAdaptor)
        );
    }

    function test_replaceAssetPriceFeed_fail_whenNoFeedIsConfigured() public {
        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        oracleManager.replaceAssetPriceFeed(
            _USDC_ADDRESS,
            address(chainlinkAdaptor),
            address(dualChainlinkAdaptor)
        );
    }

    function test_replaceAssetPriceFeed_fail_whenFeedsAreIdentical() public {
        _addSinglePriceFeed();

        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.replaceAssetPriceFeed(
            _USDC_ADDRESS,
            address(chainlinkAdaptor),
            address(chainlinkAdaptor)
        );
    }

    function test_replaceAssetPriceFeed_fail_whenAssetIsNotSupported() public {
        _addDualPriceFeed();

        dualChainlinkAdaptor.removeAsset(_USDC_ADDRESS);

        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.replaceAssetPriceFeed(
            _USDC_ADDRESS,
            address(chainlinkAdaptor),
            address(dualChainlinkAdaptor)
        );
    }

    function test_replaceAssetPriceFeed_success() public {
        vm.expectRevert();
        oracleManager.assetPriceFeeds(_USDC_ADDRESS, 0);

        vm.expectRevert();
        oracleManager.assetPriceFeeds(_USDC_ADDRESS, 1);

        _addSinglePriceFeed();

        assertEq(
            oracleManager.assetPriceFeeds(_USDC_ADDRESS, 0),
            address(chainlinkAdaptor)
        );

        assertTrue(oracleManager.isSupportedAsset(_USDC_ADDRESS));

        oracleManager.addApprovedAdaptor(address(dualChainlinkAdaptor));

        oracleManager.replaceAssetPriceFeed(
            _USDC_ADDRESS,
            address(chainlinkAdaptor),
            address(dualChainlinkAdaptor)
        );

        assertEq(
            oracleManager.assetPriceFeeds(_USDC_ADDRESS, 0),
            address(dualChainlinkAdaptor)
        );
        assertTrue(oracleManager.isSupportedAsset(_USDC_ADDRESS));
    }
}
