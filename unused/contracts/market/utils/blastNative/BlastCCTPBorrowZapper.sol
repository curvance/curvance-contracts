// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { CCTPBorrowZapper, ICentralRegistry } from "contracts/plugins/market/crosschain/CCTPBorrowZapper.sol";
import { BlastYieldDelegable } from "contracts/libraries/BlastYieldDelegable.sol";

contract BlastCCTPBorrowZapper is CCTPBorrowZapper, BlastYieldDelegable {
    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_
    ) CCTPBorrowZapper(centralRegistry_) BlastYieldDelegable(centralRegistry_) {}
}
