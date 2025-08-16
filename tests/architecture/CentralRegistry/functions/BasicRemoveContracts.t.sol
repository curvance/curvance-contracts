// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

// Dynamically tests multiple functions in CentralRegistry that
// remove a contract from a mapping
contract BasicRemoveContractsTest is TestBaseMarketIsolated {
    event PermissionsUpdated(
        string indexed permissionsType,
        address addressUpdated,
        bool isAdded
    );

    string[] public removeFuncs;
    string[] public maps;
    string[] public expectedLogs;
    string[] public addFuncs;

    function setUp() public virtual override {
        super.setUp();

        removeFuncs = [
            "removeLockingPermissions(address)",
            "removeAuctionPermissions(address)",
            "removeMarketPermissions(address)",
            "removeHarvestPermissions(address)"
        ];
        maps = [
            "hasLockingPermissions(address)",
            "hasAuctionPermissions(address)",
            "hasMarketPermissions(address)",
            "hasHarvestPermissions(address)"
        ];
        expectedLogs = [
            "Locking",
            "Auction",
            "Market",
            "Harvest"
        ];
        addFuncs = [
            "addLockingPermissions(address)",
            "addAuctionPermissions(address)",
            "addMarketPermissions(address)",
            "addHarvestPermissions(address)"
        ];
    }

    function test_removeFunc_fail_whenCallerIsNotAuthorized() public {
        uint8 length = uint8(removeFuncs.length);
        vm.startPrank(address(0));
        for (uint256 i; i < length; i++) {
            bytes memory sig = abi.encodeWithSignature(removeFuncs[i], user1);
            (bool success, bytes memory data) = address(centralRegistry).call(
                sig
            );

            assertFalse(success);
            assertEq(
                bytes32(data),
                bytes32(CentralRegistry.CentralRegistry__Unauthorized.selector)
            );
        }
        vm.stopPrank();
    }

    function test_removeFunc_fail_whenParametersMisconfigured() public {
        uint8 length = uint8(removeFuncs.length);
        for (uint256 i; i < length; i++) {
            bytes memory sig = abi.encodeWithSignature(removeFuncs[i], user1);
            (bool success, bytes memory data) = address(centralRegistry).call(
                sig
            );

            assertFalse(success);
            assertEq(
                bytes32(data),
                bytes32(
                    CentralRegistry.CentralRegistry__InvalidParameter.selector
                )
            );
        }
    }

    function test_removeFunc_success() public {
        uint8 length = uint8(removeFuncs.length);
        for (uint256 i; i < length; i++) {
            bytes memory sig = abi.encodeWithSignature(addFuncs[i], user1);
            (bool success, bytes memory data) = address(centralRegistry).call(
                sig
            );
            assertTrue(success);

            vm.expectEmit(true, true, true, true);
            emit PermissionsUpdated(expectedLogs[i], user1, false);
            sig = abi.encodeWithSignature(removeFuncs[i], user1);
            (success, ) = address(centralRegistry).call(sig);
            assertTrue(success);

            (, data) = address(centralRegistry).call(
                abi.encodeWithSignature(maps[i], user1)
            );
            assertFalse(abi.decode(data, (bool)));
        }
    }
}
