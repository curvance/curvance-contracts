// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract SetWormholeRelayersTest is TestBaseMarket {
    event WormholeRelayersSet(uint256[] chainIds, address[] newAddresses);

    uint256[] chainIds;
    address[] newWormholeRelayers;

    function setUp() public override {
        super.setUp();

        chainIds.push(137);
        chainIds.push(42161);

        newWormholeRelayers.push(makeAddr("Wormhole Relayer1"));
        newWormholeRelayers.push(makeAddr("Wormhole Relayer2"));
    }

    function test_setWormholeRelayers_fail_whenUnauthorized() public {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.setWormholeRelayers(chainIds, newWormholeRelayers);
    }

    function test_setWormholeRelayers_success() public {
        assertEq(address(centralRegistry.wormholeRelayers(137)), address(0));
        assertEq(address(centralRegistry.wormholeRelayers(42161)), address(0));

        vm.expectEmit(true, true, true, true);
        emit WormholeRelayersSet(chainIds, newWormholeRelayers);

        centralRegistry.setWormholeRelayers(chainIds, newWormholeRelayers);

        assertEq(
            address(centralRegistry.wormholeRelayers(137)),
            newWormholeRelayers[0]
        );
        assertEq(
            address(centralRegistry.wormholeRelayers(42161)),
            newWormholeRelayers[1]
        );
    }
}
