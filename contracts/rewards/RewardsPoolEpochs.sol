// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {Authority} from "solmate/auth/Auth.sol";
import {ERC20Gauges} from "fei-protocol/flywheel-v2/token/ERC20Gauges.sol";
import {IRewardsStream} from "fei-protocol/flywheel-v2/rewards/FlywheelGaugeRewards.sol";
import {MultiOwnable} from "./common/MultiOwnable.sol";
import {IERC20} from "./common/IERC20.sol";
import {RewardsAccounting} from "./RewardsAccounting.sol";

// Tokens are added into the rewards pool by admins/governance and sit here until RewardsAccounting
// calls `getRewards`, which should transfer the appropriate number of tokens into that contract.
contract RewardsPoolEpochs is IRewardsStream, MultiOwnable {
    using SafeTransferLib for IERC20;

    IERC20               public rewardsToken;
    RewardsAccounting    public rewardsAccounting;
    ERC20Gauges          public gaugeWeights;

    uint256 public startTime;
    mapping(uint256 => uint256) public rewardsForEpoch;

    constructor(
        IERC20 _rewardsToken,
        FlywheelGaugeRewards _rewardsAccounting,
        ERC20Gauges _gaugeWeights,
        Authority _authority,
        uint256 _startTime
    )
    {
        rewardsToken = _rewardsToken;
        rewardsAccounting = _rewardsAccounting;
        gaugeWeights = _gaugeWeights;
        startTime = _startTime;
    }

    error EpochAlreadyFunded();

    function addRewards(uint256 epoch, uint256 amount) public onlyOwners {
        if (rewardsForEpoch[epoch] > 0) revert EpochAlreadyFunded();

        rewardsForEpoch[epoch] = amount;
        rewardsToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    error Forbidden();

    // Implements `IRewardsStream` from `FlywheelGaugeRewards`
    function getRewards() public returns (uint256 amount) {
        if (msg.sender != address(rewardsAccounting)) revert Forbidden();
        uint256 epoch = currentEpoch();
        amount = rewardsForEpoch[epoch];
        delete rewardsForEpoch[epoch];
        rewardsToken.safeTransfer(address(rewardsAccounting), amount);
        return amount;
    }

    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - startTime) % gaugeWeights.gaugeCycleLength();
    }
}

