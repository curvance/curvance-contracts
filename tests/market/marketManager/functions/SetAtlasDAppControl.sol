// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManager } from "../TestBaseMarketManager.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";

contract SetBundlerTest is TestBaseMarketManager {
    event AuthorizedAtlasDAppControlChanged(
        address indexed authorizedAtlasDAppControl
    );

    function test_setAuthorizedAtlasDAppControl_fail_whenCallerIsNotCentralRegistry() public {
        vm.expectRevert(MarketManager.MarketManager__Unauthorized.selector);
        marketManager.setAuthorizedAtlasDAppControl(address(1));
    }

    function test_setAuthorizedAtlasDAppControl_success() public {
        vm.startPrank(address(centralRegistry));

        assertEq(marketManager.authorizedAtlasDAppControl(), address(0));

        vm.expectEmit(true, true, true, true, address(marketManager));
        emit AuthorizedAtlasDAppControlChanged(address(1));

        marketManager.setAuthorizedAtlasDAppControl(address(1));

        assertEq(marketManager.authorizedAtlasDAppControl(), address(1));

        vm.expectEmit(true, true, true, true, address(marketManager));
        emit AuthorizedAtlasDAppControlChanged(address(0));

        marketManager.setAuthorizedAtlasDAppControl(address(0));

        assertEq(marketManager.authorizedAtlasDAppControl(), address(0));

        vm.stopPrank();
    }
}
