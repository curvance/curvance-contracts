// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManager } from "../TestBaseMarketManager.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";

contract SetBundlerTest is TestBaseMarketManager {
    event LiquidationBundlerStatusChanged(
        address indexed liquidationBundler,
        bool isApproved
    );

    function test_setBundler_fail_whenCallerIsNotCentralRegistry() public {
        vm.expectRevert(MarketManager.MarketManager__Unauthorized.selector);
        marketManager.setBundler(address(1), true);
    }

    function test_setBundler_success() public {
        vm.startPrank(address(centralRegistry));

        assertFalse(marketManager.liquidationBundlers(address(1)));

        vm.expectEmit(true, true, true, true, address(marketManager));
        emit LiquidationBundlerStatusChanged(address(1), true);

        marketManager.setBundler(address(1), true);

        assertTrue(marketManager.liquidationBundlers(address(1)));

        vm.expectEmit(true, true, true, true, address(marketManager));
        emit LiquidationBundlerStatusChanged(address(1), false);

        marketManager.setBundler(address(1), false);

        assertFalse(marketManager.liquidationBundlers(address(1)));

        vm.stopPrank();
    }
}
