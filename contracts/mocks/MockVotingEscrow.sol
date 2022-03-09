pragma solidity ^0.8.4;
// SPDX-License-Identifier: GPL-3.0-or-later

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// mock CVE for testing
contract MockVotingEscrow {
    struct Reward {
        uint40 periodFinish;
        uint216 rewardRate;
        uint40 lastUpdateTime;
        uint216 rewardPerTokenStored;
    }
    mapping(address => Reward) public rewardData;

    constructor(address _token) {
        rewardData[_token].periodFinish = uint32(block.timestamp);
        rewardData[_token].lastUpdateTime = uint32(block.timestamp);
    }

    function notifyRewardAmount(address _token, uint256 _amount) external pure returns (bool) {
        _token;
        _amount;
        return true;
    }
}
