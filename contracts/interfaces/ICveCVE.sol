// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface ICveCVE {
    function addReward(address _rewardToken, address _distributor) external;

    function approveRewardDistributor(
        address _rewardsToken,
        address _distributor,
        bool _approved
    ) external;

    function mint(address _account, uint256 _amount) external;

    function unwrap(uint256 _amount) external;

    function notifyRewardAmount(address _rewardsToken, uint256 _amount) external;

    function getReward(address _account) external;

    function recoverToken(address _token, uint256 _amount) external;

    function getDepositedBalance(address _account) external view returns (uint256);

    function rewardLength() external view returns (uint256);

    function rewardPerToken(address _rewardToken) external view returns (uint256);

    function earned(address _user) external view returns (uint256);

    function lastTimeRewardApplicable(address _rewardsToken) external view returns (uint256);
}
