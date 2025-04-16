// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManager } from "../TestBaseMarketManager.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";

contract SetSequencingStatusTest is TestBaseMarketManager {
    event SpecificSequencingStatusChanged(bool sequencingActive);

    function test_setSequencingStatus_fail_whenCallerIsNotCentralRegistry()
        public
    {
        vm.expectRevert(MarketManager.MarketManager__Unauthorized.selector);
        marketManager.setSequencingStatus(true);
    }

    function test_setSequencingStatus_success() public {
        // vm.startPrank(address(centralRegistry));

        // assertFalse(marketManager.specificSequencingActive());

        // vm.expectEmit(true, true, true, true, address(marketManager));
        // emit SpecificSequencingStatusChanged(true);

        // marketManager.setSequencingStatus(true);

        // assertTrue(marketManager.specificSequencingActive());

        // vm.expectEmit(true, true, true, true, address(marketManager));
        // emit SpecificSequencingStatusChanged(false);

        // marketManager.setSequencingStatus(false);

        // assertFalse(marketManager.specificSequencingActive());

        // vm.stopPrank();
    }
}
