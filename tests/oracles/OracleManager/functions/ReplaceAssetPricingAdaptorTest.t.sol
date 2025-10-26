// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";

contract ReplaceAssetPricingAdaptorTest is TestBaseOracleManager {
    function test_replaceAssetPriceFeed_fail_whenCallerIsNotAuthorized()
        public
    {
        _addSinglePriceFeed();

        vm.prank(address(1));

        vm.expectRevert(OracleManager.OracleManager__Unauthorized.selector);
        oracleManager.replaceAssetPricingAdaptor(
            _USDC_ADDRESS,
            address(chainlinkAdaptor),
            address(dualChainlinkAdaptor),
            100,
            50
        );
    }

    function test_replaceAssetPriceFeed_fail_whenAdaptorIsNotApproved()
        public
    {
        _addSinglePriceFeed();

        vm.expectRevert(
            OracleManager.OracleManager__AdaptorIsNotApproved.selector
        );
        oracleManager.replaceAssetPricingAdaptor(
            _USDC_ADDRESS,
            address(chainlinkAdaptor),
            address(dualChainlinkAdaptor),
            100,
            50
        );
    }

    function test_replaceAssetPriceFeed_fail_whenNoFeedIsConfigured() public {
        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        oracleManager.replaceAssetPricingAdaptor(
            _USDC_ADDRESS,
            address(chainlinkAdaptor),
            address(dualChainlinkAdaptor),
            100,
            50
        );
    }

    function test_replaceAssetPriceFeed_fail_whenFeedsAreIdentical() public {
        _addSinglePriceFeed();

        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.replaceAssetPricingAdaptor(
            _USDC_ADDRESS,
            address(chainlinkAdaptor),
            address(chainlinkAdaptor),
            100,
            50
        );
    }

    function test_replaceAssetPriceFeed_fail_whenAssetIsNotSupported() public {
        _addDualPriceFeed();

        dualChainlinkAdaptor.removeAsset(_USDC_ADDRESS);

        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.replaceAssetPricingAdaptor(
            _USDC_ADDRESS,
            address(chainlinkAdaptor),
            address(dualChainlinkAdaptor),
            100,
            50
        );
    }

    function test_replaceAssetPriceFeed_success() public {
        vm.expectRevert();
        address[] memory adaptors = oracleManager.getPricingAdaptors(_USDC_ADDRESS);
        assertEq(adaptors.length, 0);

        _addSinglePriceFeed();

        assertEq(
            oracleManager.getPricingAdaptors(_USDC_ADDRESS)[0],
            address(chainlinkAdaptor)
        );

        assertTrue(oracleManager.isSupportedAsset(_USDC_ADDRESS));

        oracleManager.addApprovedAdaptor(address(dualChainlinkAdaptor));

        oracleManager.replaceAssetPricingAdaptor(
            _USDC_ADDRESS,
            address(chainlinkAdaptor),
            address(dualChainlinkAdaptor),
            100,
            50
        );

        assertEq(
            oracleManager.getPricingAdaptors(_USDC_ADDRESS)[0],
            address(dualChainlinkAdaptor)
        );
        assertTrue(oracleManager.isSupportedAsset(_USDC_ADDRESS));
    }
}
