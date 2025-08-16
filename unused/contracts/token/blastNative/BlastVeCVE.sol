// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import { VeCVE, ICentralRegistry } from "contracts/token/VeCVE.sol";
import { BlastYieldDelegable } from "contracts/libraries/BlastYieldDelegable.sol";

contract BlastVeCVE is VeCVE, BlastYieldDelegable {
    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_
    ) VeCVE(centralRegistry_) BlastYieldDelegable(centralRegistry_) {}
}
