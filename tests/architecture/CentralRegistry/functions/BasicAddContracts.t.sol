// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

// Dynamically tests multiple functions in CentralRegistry that
// add a contract to a mapping
contract BasicAddContractsTest is TestBaseMarketIsolated {
    event NewCurvanceContract(string indexed contractType, address newAddress);

    string[] public addFuncs;
    string[] public maps;
    string[] public expectedLogs;

    function setUp() public virtual override {
        super.setUp();

        addFuncs = ["addLockingPermissions(address)", "addHarvester(address)"];
        maps = ["hasLockingPermissions(address)", "isHarvester(address)"];
        expectedLogs = ["Locking Permissions", "Harvestor"];
    }

    function test_addFunc_fail_whenCallerIsNotAuthorized() public {
        uint8 length = uint8(addFuncs.length);
        vm.startPrank(address(0));
        for (uint256 i; i < length; i++) {
            bytes memory sig = abi.encodeWithSignature(addFuncs[i], user1);
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

    function test_addFunc_fail_whenParametersMisconfigured() public {
        uint8 length = uint8(addFuncs.length);
        for (uint256 i; i < length; i++) {
            bytes memory sig = abi.encodeWithSignature(addFuncs[i], user1);
            (bool success, bytes memory data) = address(centralRegistry).call(
                sig
            );

            assertTrue(success);

            (success, data) = address(centralRegistry).call(sig);
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

    function test_addFunc_success() public {
        uint8 length = uint8(addFuncs.length);
        for (uint256 i; i < length; i++) {
            vm.expectEmit(true, true, true, true);
            emit NewCurvanceContract(expectedLogs[i], user1);
            bytes memory sig = abi.encodeWithSignature(addFuncs[i], user1);
            (bool success, bytes memory data) = address(centralRegistry).call(
                sig
            );
            assertTrue(success);

            (, data) = address(centralRegistry).call(
                abi.encodeWithSignature(maps[i], user1)
            );
            assertTrue(abi.decode(data, (bool)));
        }
    }
}
