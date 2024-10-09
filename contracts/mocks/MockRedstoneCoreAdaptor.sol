// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { RedstoneCoreAdaptor } from "contracts/oracles/adaptors/redstone/RedstoneCoreAdaptor.sol";

contract MockRedstoneCoreAdaptor is RedstoneCoreAdaptor {

    constructor(
        ICentralRegistry centralRegistry_,
        address[] memory signers,
        uint256 _uniqueSignersThreshold
    ) RedstoneCoreAdaptor(centralRegistry_, signers, _uniqueSignersThreshold) {}

    function validateTimestamp(
        uint256 receivedTimestampMilliseconds
    ) public view override {
        // allow any timestamp
    }
}
