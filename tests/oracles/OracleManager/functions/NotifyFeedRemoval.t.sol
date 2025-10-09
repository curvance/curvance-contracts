// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

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

    function test_notifyFeedRemoval_noop_whenSingleFeedDoesNotExist() public {
        _addSinglePriceFeed();

        oracleManager.addApprovedAdaptor(address(dualChainlinkAdaptor));

        address feed0Before = oracleManager.assetPriceFeeds(_USDC_ADDRESS, 0);

        vm.prank(address(dualChainlinkAdaptor));
        oracleManager.notifyFeedRemoval(_USDC_ADDRESS);

        // does not change
        assertEq(oracleManager.assetPriceFeeds(_USDC_ADDRESS, 0), feed0Before);
        vm.expectRevert();
        oracleManager.assetPriceFeeds(_USDC_ADDRESS, 1);
    }

    function test_notifyFeedRemoval_noop_whenDualFeedDoesNotExist() public {
        _addDualPriceFeed();

        oracleManager.addApprovedAdaptor(address(1));

        address feed0Before = oracleManager.assetPriceFeeds(_USDC_ADDRESS, 0);
        address feed1Before = oracleManager.assetPriceFeeds(_USDC_ADDRESS, 1);

        vm.prank(address(1));
        oracleManager.notifyFeedRemoval(_USDC_ADDRESS);

        // does not change
        assertEq(oracleManager.assetPriceFeeds(_USDC_ADDRESS, 0), feed0Before);
        assertEq(oracleManager.assetPriceFeeds(_USDC_ADDRESS, 1), feed1Before);
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

    function test_notifyFeedRemoval_whenThirdAdaptorSupportsAsset() public {
        _addDualPriceFeed();

        ChainlinkAdaptor thirdAdaptor = new ChainlinkAdaptor(ICentralRegistry(address(centralRegistry)));

        thirdAdaptor.addAsset(
            _USDC_ADDRESS,
            true,
            _CHAINLINK_USDC_USD,
            0
        );
        thirdAdaptor.addAsset(
            _USDC_ADDRESS,
            false,
            _CHAINLINK_USDC_ETH,
            0
        );

        oracleManager.addApprovedAdaptor(address(thirdAdaptor));

        address feed0Before = oracleManager.assetPriceFeeds(_USDC_ADDRESS, 0);
        address feed1Before = oracleManager.assetPriceFeeds(_USDC_ADDRESS, 1);

        vm.prank(address(thirdAdaptor));
        oracleManager.notifyFeedRemoval(_USDC_ADDRESS);

        // assert that the feeds are not changed
        assertEq(oracleManager.assetPriceFeeds(_USDC_ADDRESS, 0), feed0Before);
        assertEq(oracleManager.assetPriceFeeds(_USDC_ADDRESS, 1), feed1Before);

    }

}
