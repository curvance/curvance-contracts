// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ICentralRegistry, ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";

contract RedstoneClassicAdaptor is ChainlinkAdaptor {
    /// CONSTRUCTOR ///

    constructor(ICentralRegistry centralRegistry_) ChainlinkAdaptor(centralRegistry_) {}

}
