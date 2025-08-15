// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { TestVariables } from "./TestVariables.sol";
import { Test } from "forge-std/Test.sol";

contract TestBase is TestVariables, Test {
    function _fork() internal returns (uint256) {
        uint256 forkId = vm.createSelectFork(
            vm.envString("ETH_NODE_URI_MAINNET")
        );

        _initMainConstantVariables();

        return forkId;
    }

    function _fork(string memory rpc) internal returns (uint256) {
        uint256 forkId = vm.createSelectFork(vm.envString(rpc));

        _initMainConstantVariables();

        return forkId;
    }

    function _fork(uint256 blocknumber) internal returns (uint256) {
        uint256 forkId = vm.createSelectFork(
            vm.envString("ETH_NODE_URI_MAINNET"),
            blocknumber
        );

        _initMainConstantVariables();

        return forkId;
    }

    function _fork(
        string memory rpc,
        uint256 blocknumber
    ) internal returns (uint256) {
        uint256 forkId = vm.createSelectFork(vm.envString(rpc), blocknumber);

        _initMainConstantVariables();

        return forkId;
    }
}
