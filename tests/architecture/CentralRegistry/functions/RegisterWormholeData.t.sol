// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { WormholeData } from "contracts/interfaces/ICentralRegistry.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { IWormholeRelayer } from "contracts/interfaces/external/wormhole/IWormholeRelayer.sol";

contract RegisterWormholeDataTest is TestBaseMarket {
    event WormholeDataSet(uint256[] chainIds, WormholeData[] newData);

    uint256[] public chainIds;
    WormholeData[] public newWormholeData;

    function setUp() public override {
        super.setUp();

        chainIds.push(1);
        newWormholeData.push(WormholeData(2, makeAddr("Wormhole Relayer1")));
        chainIds.push(42161);
        newWormholeData.push(WormholeData(23, makeAddr("Wormhole Relayer2")));
        chainIds.push(43114);
        newWormholeData.push(WormholeData(6, makeAddr("Wormhole Relayer3")));
    }

    function test_registerWormholeData_fail_whenUnauthorized() public {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.registerWormholeData(chainIds, newWormholeData);
    }

    function test_registerWormholeData_success() public {
        for (uint256 i = 0; i < chainIds.length; i++) {
            (, address wormholeRelayer) = centralRegistry.wormholeData(
                chainIds[i]
            );
            assertNotEq(wormholeRelayer, newWormholeData[i].relayer);
        }

        vm.expectEmit(true, true, true, true);
        emit WormholeDataSet(chainIds, newWormholeData);

        centralRegistry.registerWormholeData(chainIds, newWormholeData);

        for (uint256 i = 0; i < chainIds.length; i++) {
            (uint16 wormholeChainId, address wormholeRelayer) = centralRegistry
                .wormholeData(chainIds[i]);

            assertEq(wormholeChainId, newWormholeData[i].chainId);
            assertEq(wormholeRelayer, newWormholeData[i].relayer);
        }
    }
}
