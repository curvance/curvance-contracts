// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { EthereumRedstoneCoreAdaptor } from "contracts/oracles/adaptors/redstone/EthereumRedstoneCoreAdaptor.sol";

contract MockEthereumRedstoneCoreAdaptor is EthereumRedstoneCoreAdaptor {
    constructor(
        ICentralRegistry centralRegistry_
    ) EthereumRedstoneCoreAdaptor(centralRegistry_) {}

    function getUniqueSignersThreshold() public pure override returns (uint8) {
        return 1;
    }

    function getAuthorisedSignerIndex(
        address signerAddress
    ) public view virtual override returns (uint8) {
        // authorize everyone
        return 0;
    }

    function validateTimestamp(
        uint256 receivedTimestampMilliseconds
    ) public view override {
        // allow any timestamp
    }
}
