// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC20Gauges} from "fei-protocol/flywheel-v2/token/ERC20Gauges.sol";
import {FlywheelCore} from "fei-protocol/flywheel-v2/FlywheelCore.sol";
import {IFlywheelRewards} from "solmate/interfaces/IFlywheelRewards.sol";
import {IFlywheelBooster} from "solmate/interfaces/IFlywheelBooster.sol";
import {Authority} from "solmate/auth/Auth.sol";
import {MultiOwnable} from "./common/MultiOwnable.sol";
import {IERC20} from "./common/IERC20.sol";
import {RewardsPool} from "./RewardsPool.sol";

contract RewardsController is FlywheelCore, MultiOwnable {

    constructor(RewardsPool rewardsPool, RewardsBooster rewardsBooster, Authority authority)
        FlywheelCore(
            ERC20(address(rewardsPool.rewardsToken())), // Rewards token
            IFlywheelRewards(address(rewardsPool)),     // Rewards pool
            IFlywheelBooster(address(rewardsBooster)),  // Rewards booster
            address(0),                                 // Owner
            authority                                   // Authority
        )
    {}

    function addVault(ERC4626 vault) external requiresAuth {
        FlywheelCore.addStrategyForRewards(vault);
    }

    function vaults() external view returns (ERC4626[] memory) {
        return FlywheelCore.getAllStrategies();
    }

    function claimRewards(address vault) public returns (uint256 amount) {
        amount = FlywheelCore.accrue(ERC20(vault), msg.sender);
        FlywheelCore.claimRewards(msg.sender);
        return amount;
    }
}
