// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { SimpleRewardZapper, ICentralRegistry } from "contracts/plugins/rewards/SimpleRewardZapper.sol";
import { BlastYieldDelegable } from "contracts/libraries/BlastYieldDelegable.sol";

contract BlastSimpleRewardZapper is SimpleRewardZapper, BlastYieldDelegable {
    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address WETH_
    )
        SimpleRewardZapper(centralRegistry_, WETH_)
        BlastYieldDelegable(centralRegistry_)
    {}
}
