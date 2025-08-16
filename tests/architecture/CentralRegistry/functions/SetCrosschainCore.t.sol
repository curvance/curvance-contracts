// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract SetCrosschainCoreTest is TestBaseMarketIsolated {
    event CoreContractUpdated(string indexed contractType, address newAddress);

    address public newCrosschainCore = makeAddr("Crosschain Core");

    function test_setCrosschainCore_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.setCrosschainCore(newCrosschainCore);
    }

    function test_setCrosschainCore_success() public {
        assertEq(address(centralRegistry.crosschainCore()), _CROSSCHAIN_CORE);

        vm.expectEmit(true, true, true, true);
        emit CoreContractUpdated("Crosschain Core", newCrosschainCore);

        centralRegistry.setCrosschainCore(newCrosschainCore);

        assertEq(address(centralRegistry.crosschainCore()), newCrosschainCore);
    }
}
