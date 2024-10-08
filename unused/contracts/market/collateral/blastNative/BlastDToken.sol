// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { EToken, ICentralRegistry } from "contracts/market/token/EToken.sol";
import { BlastYieldDelegable } from "contracts/libraries/BlastYieldDelegable.sol";

abstract contract BlastEToken is EToken, BlastYieldDelegable {
    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address underlying_,
        address marketManager_,
        address interestRateModel_
    )
        EToken(
            centralRegistry_,
            underlying_,
            marketManager_,
            interestRateModel_
        )
        BlastYieldDelegable(centralRegistry_)
    {}
}
