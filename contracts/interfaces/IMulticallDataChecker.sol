// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

interface IMulticallDataChecker {
    function checkCallData(
        address caller,
        address target,
        bytes memory data
    ) external;
}
