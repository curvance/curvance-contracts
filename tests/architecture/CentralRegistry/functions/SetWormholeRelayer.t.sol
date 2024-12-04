// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract SetWormholeRelayerTest is TestBaseMarket {
    event WormholeRelayerSet(address newAddress);

    address public newWormholeRelayer = makeAddr("Wormhole Relayer");

    function test_setWormholeRelayer_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.setWormholeRelayer(newWormholeRelayer);
    }

    function test_setWormholeRelayer_success() public {
        assertEq(
            address(centralRegistry.wormholeRelayer()),
            _WORMHOLE_RELAYER
        );

        vm.expectEmit(true, true, true, true);
        emit WormholeRelayerSet(newWormholeRelayer);

        centralRegistry.setWormholeRelayer(newWormholeRelayer);

        assertEq(
            address(centralRegistry.wormholeRelayer()),
            newWormholeRelayer
        );
    }
}
