// SPDX-License-Identifier: MIT
pragma solidity 0.8.9;

/**
 * TODO Update with our VoteEscrow parameters
 */

interface IVoteEscrow {
    struct LockedBalance {
        uint112 amount;
        uint32 unlockTime;
    }

    function lockedSupply() external view returns (uint256);

    function lock(
        address _account,
        uint256 _amount,
        uint256 _spendRatio
    ) external;

    function processExpiredLocks(
        bool _relock,
        uint256 _spendRatio,
        address _withdrawTo
    ) external;

    function getReward(address _account, bool _stake) external;

    function balanceOf(address _account) external view returns (uint256);

    function totalSupply() external view returns (uint256 supply);

    function lockedBalances(address _user)
        external
        view
        returns (
            uint256 total,
            uint256 unlockable,
            uint256 locked,
            LockedBalance[] memory lockData
        );

    function addReward(address _rewardsToken, address _distributor) external;

    function approveRewardDistributor(
        address _rewardsToken,
        address _distributor,
        bool _approved
    ) external;

    function setStakeLimits(uint256 _minimum, uint256 _maximum) external;

    function setKickIncentive(uint256 _rate, uint256 _delay) external;

    function shutdown() external;

    function recoverERC20(address _tokenAddress, uint256 _tokenAmount) external;
}
