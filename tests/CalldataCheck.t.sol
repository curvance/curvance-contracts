// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";

contract CalldataCheck is Test {
    function setUp() public {
        vm.createSelectFork(vm.envString("MON_NODE_URI_MONAD_MAINNET"));
    }

    function test_simulateTransaction() public {
        address from = 0xabcC624483F559413753d9993f3fD257423576a0;
        address to = 0xa206D51C02c0202a2Eed8E6A757b49Ab13930227;

        vm.prank(from);
        (bool success,) = to.call(
            hex"4b3fd148000000000000000000000000000000000000000000000000001184ebac15370a000000000000000000000000abcc624483f559413753d9993f3fd257423576a0"
        );
        require(success, "call failed");
    }
}
