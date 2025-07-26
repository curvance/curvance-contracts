// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { BaseSwapChecker, SwapperLib } from "contracts/calldata-checker/swap-checker/BaseSwapChecker.sol";

contract MockCalldataChecker is BaseSwapChecker {
    constructor(address _target) BaseSwapChecker(_target) {}

    function checkCalldata(
        SwapperLib.Swap memory swapAction,
        address recipient
    ) external view override {}
}
