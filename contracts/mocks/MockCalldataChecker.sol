// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { BaseSwapChecker, SwapperLib } from "contracts/calldata-checker/swap-checker/BaseSwapChecker.sol";

contract MockCalldataChecker is BaseSwapChecker {
    constructor(address _target) BaseSwapChecker(_target) {}

    function checkCalldata(
        SwapperLib.Swap memory swapAction,
        address recipient
    ) external view override returns (uint256) {
        return 0; // update if we ever need to return a min amount out
        // for now it's only used as a placeholder for tests.
    }
}
