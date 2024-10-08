// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract BasicSettersTest is TestBaseMarket {
    event CoreContractSet(string indexed contractType, address newAddress);

    string[] public setters;
    string[] public getters;
    string[] public expectedLogs;

    function setUp() public virtual override {
        super.setUp();

        centralRegistry = new CentralRegistry(
            _ZERO_ADDRESS,
            _ZERO_ADDRESS,
            _ZERO_ADDRESS,
            block.timestamp,
            address(0),
            _USDC_ADDRESS
        );

        setters = [
            "setCVE(address)",
            "setVeCVE(address)",
            "setRewardManager(address)",
            "setMessagingHub(address)",
            "setOracleManager(address)",
            "setFeeManager(address)"
        ];
        getters = [
            "cve()",
            "veCVE()",
            "rewardManager()",
            "messagingHub()",
            "oracleManager()",
            "feeManager()"
        ];
        expectedLogs = [
            "CVE",
            "VeCVE",
            "Reward Manager",
            "Messaging Hub",
            "Oracle Manager",
            "Fee Manager"
        ];
    }

    function test_setter_fail_whenUnauthorized() public {
        uint8 length = uint8(setters.length);
        vm.startPrank(address(0));
        for (uint256 i; i < length; i++) {
            bytes memory sig = abi.encodeWithSignature(setters[i], user1);
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

    function test_setter_success() public {
        uint8 length = uint8(setters.length);
        for (uint256 i; i < length; i++) {
            address newAddr = user1;

            vm.expectEmit(true, true, true, true);
            emit CoreContractSet(expectedLogs[i], newAddr);

            bytes memory setterSig = abi.encodeWithSignature(
                setters[i],
                user1
            );
            (bool success, ) = address(centralRegistry).call(setterSig);
            assertTrue(success);

            bytes memory getterSig = abi.encodeWithSignature(
                getters[i],
                user1
            );
            (, bytes memory result) = address(centralRegistry).call(getterSig);
            address resultAddr = abi.decode(result, (address));

            assertEq(resultAddr, newAddr);
        }
    }
}
