// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { CallDataCheckerBase, SwapperLib } from "contracts/market/swap-checker/CallDataCheckerBase.sol";

contract MockCallDataChecker is CallDataCheckerBase {
    constructor(address _target) CallDataCheckerBase(_target) {}

    function checkCallData(
        SwapperLib.Swap memory _swapData,
        address _recipient
    ) external view override {}
}
