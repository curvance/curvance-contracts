// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { FeeAccumulator, ICentralRegistry } from "contracts/architecture/FeeAccumulator.sol";
import { BlastYieldDelegable } from "contracts/libraries/BlastYieldDelegable.sol";

contract BlastFeeAccumulator is FeeAccumulator, BlastYieldDelegable {
    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_
    ) FeeAccumulator(centralRegistry_) BlastYieldDelegable(centralRegistry_) {}
}
