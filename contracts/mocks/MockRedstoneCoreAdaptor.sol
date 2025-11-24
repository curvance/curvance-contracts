// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { RedstoneCoreAdaptor } from "contracts/oracles/adaptors/redstone/RedstoneCoreAdaptor.sol";

contract MockRedstoneCoreAdaptor is RedstoneCoreAdaptor {

    constructor(
        ICentralRegistry cr,
        address[] memory signers,
        uint256 signersThreshold,
        string memory nativeTokenSymbol,
        uint256 defaultHeartbeat
    ) RedstoneCoreAdaptor(cr, signers, signersThreshold, nativeTokenSymbol, defaultHeartbeat) {}

    function validateTimestamp(
        uint256 receivedTimestampMilliseconds
    ) public view override {
        // allow any timestamp
    }
}
