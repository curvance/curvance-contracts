// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

// Dynamically tests multiple functions in CentralRegistry that
// remove a contract from a mapping
contract BasicRemoveContractsTest is TestBaseMarketIsolated {
    event RemovedCurvanceContract(
        string indexed contractType,
        address removedAddress
    );

    string[] public removeFuncs;
    string[] public maps;
    string[] public expectedLogs;
    string[] public addFuncs;

    function setUp() public virtual override {
        super.setUp();

        removeFuncs = [
            "removeLockingPermissions(address)",
            "removeHarvester(address)"
        ];
        maps = ["hasLockingPermissions(address)", "isHarvester(address)"];
        expectedLogs = ["Locking Permissions", "Harvestor"];
        addFuncs = ["addLockingPermissions(address)", "addHarvester(address)"];
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
                    CentralRegistry
                        .CentralRegistry__ParametersMisconfigured
                        .selector
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
            emit RemovedCurvanceContract(expectedLogs[i], user1);
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
