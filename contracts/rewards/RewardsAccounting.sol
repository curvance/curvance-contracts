// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC20Gauges} from "fei-protocol/flywheel-v2/token/ERC20Gauges.sol";
import {FlywheelGaugeRewards, IRewardsStream} from "fei-protocol/flywheel-v2/rewards/FlywheelGaugeRewards.sol";
import {Authority} from "solmate/auth/Auth.sol";
import {MultiOwnable} from "./common/MultiOwnable.sol";
import {IERC20} from "./common/IERC20.sol";

// `RewardsAccounting` contracts determine how the tokens in `RewardsPool` contracts should be
// apportioned out when users call `accrue` or `claim` on the `RewardsController`.
contract RewardsAccounting is FlywheelGaugeRewards, MultiOwnable {
    constructor(
        RewardsController _rewardsController,
        IRewardsStream _rewardsStream,
        ERC20Gauges _gaugeWeights,
        Authority _authority
    )
        FlywheelGaugeRewards(
            FlywheelCore(address(_rewardsController)),
            msg.sender,
            _authority,
            _gaugeWeights,
            _rewardsStream
        )
    {}
}

