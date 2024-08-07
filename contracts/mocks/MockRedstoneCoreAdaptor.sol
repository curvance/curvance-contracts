// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { RedstoneCoreAdaptor } from "contracts/oracles/adaptors/redstone/RedstoneCoreAdaptor.sol";

contract MockRedstoneCoreAdaptor is RedstoneCoreAdaptor {

    constructor(
        ICentralRegistry centralRegistry_
    ) {
        address[] memory signers = new address[](4);
        signers[0] = 0x8BB8F32Df04c8b654987DAaeD53D6B6091e3B774;
        signers[1] = 0xdEB22f54738d54976C4c0fe5ce6d408E40d88499;
        signers[2] = 0x51Ce04Be4b3E32572C4Ec9135221d0691Ba7d202;
        signers[3] = 0xDD682daEC5A90dD295d14DA4b0bec9281017b5bE;
        RedstoneCoreAdaptor(centralRegistry_, signers, 3);
    }

    function getUniqueSignersThreshold() public pure override returns (uint8) {
        return 1;
    }

    function getAuthorisedSignerIndex(
        address /* signerAddress */
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
