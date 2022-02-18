//SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

interface IVotingEscrow {
    function lockFor(address _account, uint256 _amount) external;
}

// TODO: whitelisted pools to distribute to
// TODO: kick incentive
contract CveCVE is ERC20, Ownable {
    using SafeERC20 for IERC20;

    struct EarnedData {
        address token;
        uint256 amount;
    }

    struct RewardData {
        uint40 periodFinish;
        uint208 rewardRate;
        uint40 lastUpdateTime;
        uint208 rewardPerTokenStored;
    }

    address public locker;

    uint256 private constant MAX_SUPPLY = 400000069 * 1e18;
    // Duration that rewards are streamed over
    uint256 public constant rewardsDuration = 86400 * 7;

    address[] public rewardTokens;

    mapping(address => mapping(address => bool)) public rewardDistributors;
    mapping(address => RewardData) public rewardData;
    mapping(address => mapping(address => uint256)) public userRewards; // user -> reward_token -> amount
    mapping(address => mapping(address => uint256)) public userRewardsPerTokenPaid; // user -> reward_token -> paid

    // emitted when a user unwraps cveCVE for CVE at 1:1 ratio
    event Unwrap(address indexed to, uint256 amount);
    event RewardPaid(address account, address rewardsToken, uint256 reward);
    event Recovered(address token, uint256 amount);
    event RewardAdded(address token, uint256 amount);

    constructor(address _locker) ERC20("Curvance CVE", "cveCVE") {
        locker = _locker;
    }

    /**
     * @notice add reward for future distribution to holders
     * @param _rewardToken reward token to add
     * @param _distributor from whom rewards will be sent for distribution
     */
    function addReward(address _rewardToken, address _distributor) external onlyOwner {
        require(rewardData[_rewardToken].lastUpdateTime == 0, "exist");
        //require(_rewardToken != address(cve), "!assign");
        rewardTokens.push(_rewardToken);
        rewardData[_rewardToken].lastUpdateTime = uint40(block.timestamp);
        rewardData[_rewardToken].periodFinish = uint40(block.timestamp);
        rewardDistributors[_rewardToken][_distributor] = true;
    }

    /**
     * @dev Modify approval for an address to call notifyRewardAmount
     * @param _rewardsToken reward token
     * @param _distributor from whom rewards will be sent for distribution
     * @param _approved approval state
     */
    function approveRewardDistributor(
        address _rewardsToken,
        address _distributor,
        bool _approved
    ) external onlyOwner {
        require(rewardData[_rewardsToken].lastUpdateTime > 0, "reward does not exist");
        rewardDistributors[_rewardsToken][_distributor] = _approved;
    }

    /**
     * @notice mint cveCVE
     * @param _account address of user to credit with tokens
     * @param _amount amount of cveCVE tokens to deposit
     */
    function mint(address _account, uint256 _amount) external onlyLocker {
        require(totalSupply() + _amount <= MAX_SUPPLY, "max supply");
        _mint(_account, _amount);
    }

    /**
     * @notice unwrap cveCVE for CVE at 1:1 ratio
     * @param _amount amount of cveCVE tokens to unwrap
     */
    function unwrap(uint256 _amount) external {
        require(_amount > 0, "amount must be greater than 0");
        _burn(msg.sender, _amount);

        IVotingEscrow(locker).lockFor(msg.sender, _amount);

        emit Unwrap(msg.sender, _amount);
    }

    /**
     * @dev notify reward amount for new reward duration
     * @param _rewardsToken rewards token
     * @param _amount amount of rewards
     */
    function notifyRewardAmount(address _rewardsToken, uint256 _amount) external updateReward(address(0)) {
        require(rewardDistributors[_rewardsToken][msg.sender], "unauthorized");
        require(_amount > 0, "No reward");

        _notifyReward(_rewardsToken, _amount);

        // handle the transfer of reward tokens via `transferFrom` to reduce the number
        // of transactions required and ensure correctness of the _reward amount
        IERC20(_rewardsToken).safeTransferFrom(msg.sender, address(this), _amount);

        emit RewardAdded(_rewardsToken, _amount);
    }

    /**
     * @notice get (claim) rewards for an account
     * @param _account account for which rewards are claimed
     */
    function getReward(address _account) external updateReward(_account) {
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address _rewardsToken = rewardTokens[i];
            uint256 reward = userRewards[_account][_rewardsToken];
            if (reward > 0) {
                userRewards[_account][_rewardsToken] = 0;
                IERC20(_rewardsToken).safeTransfer(_account, reward);

                emit RewardPaid(_account, _rewardsToken, reward);
            }
        }
    }

    /**
     * @dev recover tokens accidentally sent here which are not rewards
     *      reward tokens can be retrieved through other means
     * @param _token token to recover
     * @param _amount amount of token to recover
     */
    function recoverToken(address _token, uint256 _amount) external onlyOwner {
        require(rewardData[_token].periodFinish == 0, "can't recover reward token this way");
        IERC20(_token).safeTransfer(owner(), _amount);
        emit Recovered(_token, _amount);
    }

    /**
     * @notice get balance of cveCVE holder
     * @param _account account in question
     */
    function getDepositedBalance(address _account) external view returns (uint256) {
        return balanceOf(_account);
    }

    /**
     * @notice get number of reward tokens
     */
    function rewardLength() external view returns (uint256) {
        return rewardTokens.length;
    }

    /**
     * @notice get reward per token stored
     * @param _rewardToken reward token
     */
    function rewardPerToken(address _rewardToken) external view returns (uint256) {
        return _rewardPerToken(_rewardToken);
    }

    /**
     * @notice get earned rewards of a user
     * @param _user user for whom to get earned rewards
     */
    function earned(address _user) external view returns (uint256) {
        uint256 amount;
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            amount += _earned(_user, rewardTokens[i], balanceOf(_user));
        }

        return amount;
    }

    /**
     * @notice last time reward applicable
     * @param _rewardsToken rewards token
     */
    function lastTimeRewardApplicable(address _rewardsToken) external view returns (uint256) {
        return _lastTimeRewardApplicable(rewardData[_rewardsToken].periodFinish);
    }

    //////////////////////////////////////////////////////
    // INTERNAL FUNCTIONS                                /
    //////////////////////////////////////////////////////

    /**
     * @notice notify reward amount internal
     * @param _rewardsToken rewards token
     * @param _amount amount of rewards
     */
    function _notifyReward(address _rewardsToken, uint256 _amount) internal {
        RewardData storage rdata = rewardData[_rewardsToken];

        if (block.timestamp >= rdata.periodFinish) {
            rdata.rewardRate = uint208(_amount / rewardsDuration);
        } else {
            uint256 remaining = uint256(rdata.periodFinish - block.timestamp);
            uint256 leftover = remaining * rdata.rewardRate;
            rdata.rewardRate = uint208((_amount + leftover) / rewardsDuration);
        }

        rdata.lastUpdateTime = uint40(block.timestamp);
        rdata.periodFinish = uint40(block.timestamp + rewardsDuration);
    }

    function _lastTimeRewardApplicable(uint256 _finishTime) internal view returns (uint256) {
        return Math.min(block.timestamp, _finishTime);
    }

    function _earned(
        address _user,
        address _rewardsToken,
        uint256 _balance
    ) internal view returns (uint256) {
        return
            ((_balance * (_rewardPerToken(_rewardsToken) - userRewardsPerTokenPaid[_user][_rewardsToken])) / 1e18) +
            userRewards[_user][_rewardsToken];
    }

    function _rewardPerToken(address _rewardToken) internal view returns (uint256) {
        if (totalSupply() == 0) {
            return rewardData[_rewardToken].rewardPerTokenStored;
        }
        return
            ((uint256(rewardData[_rewardToken].rewardPerTokenStored) +
                _lastTimeRewardApplicable(rewardData[_rewardToken].periodFinish) -
                rewardData[_rewardToken].lastUpdateTime) *
                rewardData[_rewardToken].rewardRate *
                1e18) / totalSupply();
    }

    /**
     * @dev Hook that is called after any transfer of tokens. This includes
     * minting and burning.
     * @param _from address from which tokens are transferred
     * @param _to address to which tokens are transferred
     */
    function _afterTokenTransfer(
        address _from,
        address _to,
        uint256
    ) internal override updateReward(_from) updateReward(_to) {}

    function _beforeTokenTransfer(
        address _from,
        address _to,
        uint256
    ) internal override updateReward(_from) updateReward(_to) {}

    /////////////////////////////////////////////////////
    // MODIFIERS                                        /
    /////////////////////////////////////////////////////

    modifier updateReward(address _account) {
        {
            //stack too deep
            for (uint256 i = 0; i < rewardTokens.length; i++) {
                address token = rewardTokens[i];
                rewardData[token].rewardPerTokenStored = uint208(_rewardPerToken(token));
                rewardData[token].lastUpdateTime = uint40(_lastTimeRewardApplicable(rewardData[token].periodFinish));
                if (_account != address(0)) {
                    userRewards[_account][token] = _earned(_account, token, balanceOf(_account));
                    userRewardsPerTokenPaid[_account][token] = rewardData[token].rewardPerTokenStored;
                }
            }
        }
        _;
    }

    modifier onlyLocker() {
        require(msg.sender == locker, "!auth");
        _;
    }
}
