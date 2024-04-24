// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { RewardManager, ICentralRegistry } from "contracts/architecture/RewardManager.sol";
import { BlastYieldDelegable } from "contracts/libraries/BlastYieldDelegable.sol";

contract BlastRewardManager is RewardManager, BlastYieldDelegable {

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_, 
        address rewardToken_
    ) RewardManager(centralRegistry_, rewardToken_) BlastYieldDelegable (centralRegistry_) {}

}
