// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import { FeeManager, ICentralRegistry } from "contracts/architecture/FeeManager.sol";
import { BlastYieldDelegable } from "contracts/libraries/BlastYieldDelegable.sol";

contract BlastFeeManager is FeeManager, BlastYieldDelegable {
    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_
    ) FeeManager(centralRegistry_) BlastYieldDelegable(centralRegistry_) {}
}
