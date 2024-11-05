// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { BaseCalldataChecker, SwapperLib } from "contracts/market/swap-checker/BaseCalldataChecker.sol";

contract MockCalldataChecker is BaseCalldataChecker {
    constructor(address _target) BaseCalldataChecker(_target) {}

    function checkCalldata(
        SwapperLib.Swap memory _swapData,
        address _recipient
    ) external view override {}
}
