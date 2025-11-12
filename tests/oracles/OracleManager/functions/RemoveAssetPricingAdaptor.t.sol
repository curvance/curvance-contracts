// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";

contract RemoveAssetPricingAdaptorTest is TestBaseOracleManager {
    function test_removeAssetPricingAdaptor_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(1));

        vm.expectRevert(OracleManager.OracleManager__Unauthorized.selector);
        oracleManager.removeAssetPricingAdaptor(
            _USDC_ADDRESS,
            address(chainlinkAdaptor)
        );
    }

    function test_removeAssetPricingAdaptor_fail_whenNoFeedsAvailable() public {
        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        oracleManager.removeAssetPricingAdaptor(
            _USDC_ADDRESS,
            address(chainlinkAdaptor)
        );
    }

    function test_removeAssetPricingAdaptor_fail_whenSingleFeedDoesNotExist()
        public
    {
        _addSinglePriceFeed();

        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        oracleManager.removeAssetPricingAdaptor(_USDC_ADDRESS, address(1));
    }

    function test_removeAssetPricingAdaptor_fail_whenDualFeedDoesNotExist() public {
        _addDualPriceFeed();

        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        oracleManager.removeAssetPricingAdaptor(_USDC_ADDRESS, address(1));
    }

    function test_removeAssetPricingAdaptor_success_whenRemoveSingleFeed() public {
        _addSinglePriceFeed();

        address[] memory adaptorsBefore = oracleManager.getPricingAdaptors(_USDC_ADDRESS);
        assertEq(adaptorsBefore.length, 1);
        assertEq(adaptorsBefore[0], address(chainlinkAdaptor));

        oracleManager.removeAssetPricingAdaptor(
            _USDC_ADDRESS,
            address(chainlinkAdaptor)
        );

        address[] memory adaptorsAfter = oracleManager.getPricingAdaptors(_USDC_ADDRESS);
        assertEq(adaptorsAfter.length, 0);
        vm.expectRevert();
        address shouldRevert0 = adaptorsAfter[0];
    }

    function test_removeAssetPricingAdaptor_success_whenRemoveDualFeed() public {
        _addDualPriceFeed();

        address[] memory adaptorsBefore = oracleManager.getPricingAdaptors(_USDC_ADDRESS);
        assertEq(adaptorsBefore.length, 2);
        assertEq(adaptorsBefore[0], address(chainlinkAdaptor));
        assertEq(adaptorsBefore[1], address(dualChainlinkAdaptor));

        oracleManager.removeAssetPricingAdaptor(
            _USDC_ADDRESS,
            address(chainlinkAdaptor)
        );

        address[] memory adaptorsAfter = oracleManager.getPricingAdaptors(_USDC_ADDRESS);
        assertEq(adaptorsAfter.length, 1);
        assertEq(adaptorsAfter[0], address(dualChainlinkAdaptor));

        vm.expectRevert();
        address shouldRevert1 = adaptorsAfter[1];
    }
}
