// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { MessagingHub, ICentralRegistry } from "contracts/architecture/MessagingHub.sol";
import { BlastYieldDelegable } from "contracts/libraries/BlastYieldDelegable.sol";

contract BlastMessagingHub is MessagingHub, BlastYieldDelegable {
    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_
    ) MessagingHub(centralRegistry_) BlastYieldDelegable(centralRegistry_) {}
}
