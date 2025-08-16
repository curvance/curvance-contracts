// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BaseCalldataChecker } from "contracts/calldata-checker/BaseCalldataChecker.sol";

contract BaseCalldataCheckerWrapper is BaseCalldataChecker {

    function slice(
        bytes memory sliceData,
        uint256 sliceStartPoint,
        uint256 sliceLength
    ) external pure returns (bytes memory) {
        return _slice(sliceData, sliceStartPoint, sliceLength);
    }
}