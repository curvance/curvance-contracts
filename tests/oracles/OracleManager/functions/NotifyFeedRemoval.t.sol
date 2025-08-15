// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";

contract NotifyFeedRemovalTest is TestBaseOracleManager {
    function test_notifyFeedRemoval_fail_whenCallerIsNotApprovedAdaptor()
        public
    {
        vm.expectRevert(OracleManager.OracleManager__AdaptorIsNotApproved.selector);
        oracleManager.notifyFeedRemoval(_USDC_ADDRESS);
    }

    function test_notifyFeedRemoval_fail_whenNoFeedsAvailable() public {
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        vm.prank(address(chainlinkAdaptor));

        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        oracleManager.notifyFeedRemoval(_USDC_ADDRESS);
    }

    function test_notifyFeedRemoval_fail_whenSingleFeedDoesNotExist() public {
        _addSinglePriceFeed();

        oracleManager.addApprovedAdaptor(address(dualChainlinkAdaptor));

        vm.prank(address(dualChainlinkAdaptor));

        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        oracleManager.notifyFeedRemoval(_USDC_ADDRESS);
    }

    function test_notifyFeedRemoval_fail_whenDualFeedDoesNotExist() public {
        _addDualPriceFeed();

        oracleManager.addApprovedAdaptor(address(1));

        vm.prank(address(1));

        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        oracleManager.notifyFeedRemoval(_USDC_ADDRESS);
    }

    function test_notifyFeedRemoval_success_whenRemoveSingleFeed() public {
        _addSinglePriceFeed();

        assertEq(
            oracleManager.assetPriceFeeds(_USDC_ADDRESS, 0),
            address(chainlinkAdaptor)
        );

        vm.prank(address(chainlinkAdaptor));
        oracleManager.notifyFeedRemoval(_USDC_ADDRESS);

        vm.expectRevert();
        oracleManager.assetPriceFeeds(_USDC_ADDRESS, 0);
    }

    function test_notifyFeedRemoval_success_whenRemoveDualFeed() public {
        _addDualPriceFeed();

        assertEq(
            oracleManager.assetPriceFeeds(_USDC_ADDRESS, 0),
            address(chainlinkAdaptor)
        );
        assertEq(
            oracleManager.assetPriceFeeds(_USDC_ADDRESS, 1),
            address(dualChainlinkAdaptor)
        );

        vm.prank(address(chainlinkAdaptor));
        oracleManager.notifyFeedRemoval(_USDC_ADDRESS);

        assertEq(
            oracleManager.assetPriceFeeds(_USDC_ADDRESS, 0),
            address(dualChainlinkAdaptor)
        );

        vm.expectRevert();
        oracleManager.assetPriceFeeds(_USDC_ADDRESS, 1);
    }
}
