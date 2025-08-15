// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract SetCrosschainRelayerTest is TestBaseMarketIsolated {
    event CoreContractUpdated(string indexed contractType, address newAddress);

    address public newCrosschainRelayer = makeAddr("Wormhole Relayer");

    function test_setCrosschainRelayer_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.setCrosschainRelayer(newCrosschainRelayer);
    }

    function test_setCrosschainRelayer_success() public {
        assertEq(
            address(centralRegistry.crosschainRelayer()),
            _CROSSCHAIN_RELAYER
        );

        vm.expectEmit(true, true, true, true);
        emit CoreContractUpdated("Crosschain Relayer", newCrosschainRelayer);

        centralRegistry.setCrosschainRelayer(newCrosschainRelayer);

        assertEq(
            address(centralRegistry.crosschainRelayer()),
            newCrosschainRelayer
        );
    }
}
