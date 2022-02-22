//SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

interface IRewards {
    function stake(address, uint256) external;

    function stakeFor(address, uint256) external;

    function withdraw(address, uint256) external;

    function exit(address) external;

    function getReward(address) external;

    function queueNewRewards(uint256) external;

    function notifyRewardAmount(uint256) external;

    function addExtraReward(address) external;

    function stakingToken() external returns (address);
}

contract BaseStaking {
    using SafeERC20 for IERC20;

    address public owner;
    address public operator;
    address public rewardManager;

    IERC20 public rewardToken;
    IERC20 public stakingToken;

    uint256 public constant rewardsDuration = 7 days;
    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public historicalRewards;
    uint256 private _totalSupply;

    address[] public extraRewards;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public userRewards;
    mapping(address => uint256) private _balances;

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event Recovered(address token, uint256 amount);

    constructor(
        IERC20 _stakingToken,
        IERC20 _rewardToken,
        address _operator,
        address _rewardManager
    ) {
        owner = msg.sender;
        stakingToken = _stakingToken;
        rewardToken = _rewardToken;
        operator = _operator;
        rewardManager = _rewardManager;
    }

    /**
     * @notice add an extra reward token with which staked users will be rewarded
     * @param _reward reward token
     */
    function addExtraReward(address _reward) external returns (bool) {
        require(msg.sender == rewardManager, "!auth");
        require(_reward != address(0), "!reward setting");

        extraRewards.push(_reward);
        return true;
    }

    // TODO: redistribute expired rewards
    //function redistributeExpiredReward() external {
    //   require(msg.sender == rewardManager, "!auth");
    //
    //}

    /**
     * @notice pre and post token transfer hook to update user reward
     * @param _account user
     */
    function preAndPostTransfer(address _account) external onlyOwner updateReward(_account) returns (bool) {
        return true;
    }

    /**
     * @notice stake for a user
     * @param _account user for whom to stake
     * @param _amount amount of tokens to stake
     */
    function stakeFor(address _account, uint256 _amount) external onlyOwner updateReward(_account) returns (bool) {
        require(_amount > 0, "Cannot stake 0");

        // take away from sender
        stakingToken.safeTransferFrom(msg.sender, address(this), _amount);

        // also stake to linked rewards
        for (uint256 i = 0; i < extraRewards.length; i++) {
            IRewards(extraRewards[i]).stake(_account, _amount);
        }

        // give to _account
        _totalSupply += _amount;
        _balances[_account] += _amount;

        emit Staked(_account, _amount);

        return true;
    }

    /**
     * @dev notify reward amount for new reward duration
     * @param _amount amount of rewards
     */
    function notifyRewardAmount(uint256 _amount) external updateReward(address(0)) {
        require(msg.sender == rewardManager, "unauthorized");
        require(_amount > 0, "No reward");

        _notifyReward(_amount);

        // handle the transfer of reward tokens via `transferFrom` to reduce the number
        // of transactions required and ensure correctness of the _reward amount
        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), _amount);

        emit RewardAdded(_amount);
    }

    /**
     * @notice get size of extra rewards added
     */
    function extraRewardsLength() external view returns (uint256) {
        return extraRewards.length;
    }

    /**
     * @dev recover tokens accidentally sent here which are not rewards
     *      reward tokens can be retrieved through other means
     * @param _token token to recover
     * @param _amount amount of token to recover
     */
    function recoverToken(address _token, uint256 _amount) external onlyOperator {
        require(periodFinish == 0, "can't recover reward token this way");
        IERC20(_token).safeTransfer(operator, _amount);
        emit Recovered(_token, _amount);
    }

    /**
     * @notice notify reward amount internal
     * @param _amount amount of rewards
     */
    function _notifyReward(uint256 _amount) internal {
        historicalRewards += _amount;
        if (block.timestamp >= periodFinish) {
            rewardRate = uint208(_amount / rewardsDuration);
        } else {
            uint256 remaining = uint256(periodFinish - block.timestamp);
            uint256 leftover = remaining * rewardRate;
            rewardRate = uint208((_amount + leftover) / rewardsDuration);
        }

        lastUpdateTime = uint40(block.timestamp);
        periodFinish = uint40(block.timestamp + rewardsDuration);
    }

    /**
     * @notice get the last time reward was applicable
     * @param _finishTime last finish time
     */
    function _lastTimeRewardApplicable(uint256 _finishTime) internal view returns (uint256) {
        return Math.min(block.timestamp, _finishTime);
    }

    /**
     * @notice withdraw staked tokens for user
     * @param _account user for whom to withdraw
     * @param _amount amount of tokens to withdraw
     * @param _claim whether to claim rewards or not
     */
    function withdrawFor(
        address _account,
        uint256 _amount,
        bool _claim
    ) public onlyOwner updateReward(_account) returns (bool) {
        require(_amount > 0, "Cannot withdraw 0");

        // also withdraw from linked rewards
        // rewards can be sent directly to user
        for (uint256 i = 0; i < extraRewards.length; i++) {
            IRewards(extraRewards[i]).withdraw(_account, _amount);
        }

        _totalSupply -= _amount;
        _balances[_account] -= _amount;

        // note: withdraw cve to wrapped contract instead. as tokens will be automatically locked
        stakingToken.safeTransfer(msg.sender, _amount);
        emit Withdrawn(_account, _amount);

        // ok to send reward directly to user
        if (_claim) {
            getReward(_account, true);
        }

        return true;
    }

    /**
     * @notice get (claim) rewards for an account
     * @param _account account for which rewards are claimed
     */
    function getReward(address _account, bool _claimExtras) public updateReward(_account) {
        uint256 reward = userRewards[_account];
        if (reward > 0) {
            userRewards[_account] = 0;
            IERC20(rewardToken).safeTransfer(_account, reward);

            emit RewardPaid(_account, reward);
        }

        //also get rewards from linked rewards
        if (_claimExtras && extraRewards.length > 0) {
            for (uint256 i = 0; i < extraRewards.length; i++) {
                IRewards(extraRewards[i]).getReward(_account);
            }
        }
    }

    /**
     * @notice get total supply
     */
    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function earned(address account) public view returns (uint256) {
        return
            ((balanceOf(account) * (rewardPerToken() - userRewardPerTokenPaid[account])) / 1e18) + userRewards[account];
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalSupply() == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored +
            (((_lastTimeRewardApplicable(periodFinish) - lastUpdateTime) * rewardRate * 1e18) / totalSupply());
    }

    /////////////////////////////////////////////////////
    // MODIFIERS                                        /
    /////////////////////////////////////////////////////

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = _lastTimeRewardApplicable(periodFinish);
        if (account != address(0)) {
            userRewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    modifier onlyOperator() {
        require(msg.sender == operator, "!auth");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "!auth");
        _;
    }
}
