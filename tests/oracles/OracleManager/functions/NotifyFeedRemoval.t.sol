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
        // No-op call
        oracleManager.notifyFeedRemoval(_USDC_ADDRESS);
    }

    // No longer reverts
    function test_notifyFeedRemoval_fail_whenNoFeedsAvailable() public {
        vm.prank(address(chainlinkAdaptor));

        // No-op call
        oracleManager.notifyFeedRemoval(_USDC_ADDRESS);
     }

    function test_notifyFeedRemoval_noop_whenSingleFeedDoesNotExist() public {
        _addSinglePriceFeed();

        address[] memory adaptorsBefore = oracleManager.getPricingAdaptors(_USDC_ADDRESS);
        address feed0Before = adaptorsBefore[0];

        vm.prank(address(dualChainlinkAdaptor));
        oracleManager.notifyFeedRemoval(_USDC_ADDRESS);

        // does not change
        address[] memory adaptorsAfter = oracleManager.getPricingAdaptors(_USDC_ADDRESS);
        assertEq(adaptorsAfter.length, 1);
        assertEq(adaptorsAfter[0], feed0Before);
        vm.expectRevert();
        address shouldRevert1 = adaptorsAfter[1];
    }

    function test_notifyFeedRemoval_noop_whenDualFeedDoesNotExist() public {
        _addDualPriceFeed();

        oracleManager.addApprovedAdaptor(address(1));

        address[] memory adaptorsBefore = oracleManager.getPricingAdaptors(_USDC_ADDRESS);
        address feed0Before = adaptorsBefore[0];
        address feed1Before = adaptorsBefore[1];

        vm.prank(address(1));
        oracleManager.notifyFeedRemoval(_USDC_ADDRESS);

        // does not change
        address[] memory adaptorsAfter = oracleManager.getPricingAdaptors(_USDC_ADDRESS);
        assertEq(adaptorsAfter.length, 2);
        assertEq(adaptorsAfter[0], feed0Before);
        assertEq(adaptorsAfter[1], feed1Before);
    }

    function test_notifyFeedRemoval_success_whenRemoveSingleFeed() public {
        _addSinglePriceFeed();

        address[] memory adaptorsBefore = oracleManager.getPricingAdaptors(_USDC_ADDRESS);
        assertEq(adaptorsBefore.length, 1);
        assertEq(adaptorsBefore[0], address(chainlinkAdaptor));

        vm.prank(address(chainlinkAdaptor));
        oracleManager.notifyFeedRemoval(_USDC_ADDRESS);

        address[] memory adaptorsAfter = oracleManager.getPricingAdaptors(_USDC_ADDRESS);
        assertEq(adaptorsAfter.length, 0);
        vm.expectRevert();
        address shouldRevert0 = adaptorsAfter[0];
    }

    function test_notifyFeedRemoval_success_whenRemoveDualFeed() public {
        _addDualPriceFeed();

        address[] memory adaptorsBefore = oracleManager.getPricingAdaptors(_USDC_ADDRESS);
        assertEq(adaptorsBefore.length, 2);
        assertEq(adaptorsBefore[0], address(chainlinkAdaptor));
        assertEq(adaptorsBefore[1], address(dualChainlinkAdaptor));

        vm.prank(address(chainlinkAdaptor));
        oracleManager.notifyFeedRemoval(_USDC_ADDRESS);

        address[] memory adaptorsAfter = oracleManager.getPricingAdaptors(_USDC_ADDRESS);
        assertEq(adaptorsAfter.length, 1);
        assertEq(adaptorsAfter[0], address(dualChainlinkAdaptor));

        vm.expectRevert();
        address shouldRevert2 = adaptorsAfter[1];
    }

    function test_notifyFeedRemoval_whenThirdAdaptorSupportsAsset() public {
        _addDualPriceFeed();

        ChainlinkAdaptor thirdAdaptor = new ChainlinkAdaptor(ICentralRegistry(address(centralRegistry)));
        oracleManager.addApprovedAdaptor(address(thirdAdaptor));
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

        address[] memory adaptorsBefore = oracleManager.getPricingAdaptors(_USDC_ADDRESS);
        address feed0Before = adaptorsBefore[0];
        address feed1Before = adaptorsBefore[1];

        vm.prank(address(thirdAdaptor));
        oracleManager.notifyFeedRemoval(_USDC_ADDRESS);

        // assert that the feeds are not changed
        address[] memory adaptorsAfter = oracleManager.getPricingAdaptors(_USDC_ADDRESS);
        assertEq(adaptorsAfter.length, 2);
        assertEq(adaptorsAfter[0], feed0Before);
        assertEq(adaptorsAfter[1], feed1Before);
    }

}
