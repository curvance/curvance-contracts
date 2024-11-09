// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { BorrowCircleZapper, ICentralRegistry } from "contracts/plugins/market/crosschain/BorrowCircleZapper.sol";
import { BlastYieldDelegable } from "contracts/libraries/BlastYieldDelegable.sol";

contract BlastBorrowCircleZapper is BorrowCircleZapper, BlastYieldDelegable {
    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_
    ) BorrowCircleZapper(centralRegistry_) BlastYieldDelegable(centralRegistry_) {}
}
