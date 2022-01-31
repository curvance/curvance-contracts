// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./interfaces/IStakingProxy.sol";
import "./interfaces/IRewardStaking.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// CVE Locking contract for https://www.convexfinance.com/
// CVE locked in this contract will be entitled to voting rights for the Convex Finance platform
// Based on EPS Staking contract for http://ellipsis.finance/
// Based on SNX MultiRewards by iamdefinitelyahuman - https://github.com/iamdefinitelyahuman/multi-rewards
contract CvxLocker is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    struct Reward {
        bool useBoost;
        uint40 periodFinish;
        uint208 rewardRate;
        uint40 lastUpdateTime;
        uint208 rewardPerTokenStored;
    }
    struct Balances {
        uint112 shortLocked;
        uint112 longLocked;
        uint32 nextUnlockIndex;
    }
    struct LockedBalance {
        uint112 amount;
        uint32 unlockTime;
        LockDuration lockType;
    }
    struct EarnedData {
        address token;
        uint256 amount;
    }
    struct Epoch {
        uint224 supply; //epoch boosted supply
        uint32 date; //epoch start date
    }

    enum LockDuration {
        DURATION_SHORT_LOCK,
        DURATION_LONG_LOCK
    }

    //token constants
    IERC20 public immutable stakingToken; //cve

    //rewards
    address[] public rewardTokens;
    Reward public rewardData;
    //mapping(address => Reward) public rewardData;

    // Duration that rewards are streamed over
    uint256 public constant rewardsDuration = 86400 * 7;

    // Duration of lock/earned penalty period
    uint256 public constant lockDuration = rewardsDuration * 17;
    uint256 public constant shortLockDuration = rewardsDuration * 4; // 1 month
    uint256 public constant longLockDuration = rewardsDuration * 52; // 1 year

    // reward token -> distributor -> is approved to add rewards
    mapping(address => bool) public rewardDistributors;

    // user -> amount
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    //supplies and epochs
    uint256 public lockedSupply;
    uint256 public boostedSupply;
    Epoch[] public epochs;

    //mappings for balance data
    mapping(address => Balances) public balances;
    mapping(address => LockedBalance[]) public userLocks;

    uint256 public constant denominator = 10000;
    uint256 public constant shortLockRewardMultiplier = 2000;
    uint256 public constant longLockRewardMultiplier = 10000;
    uint256 public constant lockRewardDenominator = 10000;

    //staking
    uint256 public minimumStake = 10000;
    uint256 public maximumStake = 10000;
    uint256 public constant stakeOffsetOnLock = 500; //allow broader range for staking when depositing
    address public stakingProxy;
    address public rewardToken;

    //management
    uint256 public kickRewardPerEpoch = 100;
    uint256 public kickRewardEpochDelay = 4;

    //erc20-like interface
    string private _name;
    string private _symbol;
    uint8 private immutable _decimals;

    //shutdown
    bool public isShutdown = false;

    /* ========== EVENTS ========== */
    event RewardAdded(address indexed _token, uint256 _reward);
    event Staked(address indexed _user, uint256 _paidAmount, uint256 _lockedAmount);
    event Withdrawn(address indexed _user, uint256 _amount, bool _relocked);
    event KickReward(address indexed _user, address indexed _kicked, uint256 _reward);
    event RewardPaid(address indexed _user, address indexed _rewardsToken, uint256 _reward);
    event Recovered(address _token, uint256 _amount);

    /* ========== CONSTRUCTOR ========== */

    constructor(IERC20 _stakingToken) {
        _name = "Vote Locked Curvance Token";
        _symbol = "vlCVE";
        _decimals = 18;
        stakingToken = _stakingToken;
        uint256 currentEpoch = (block.timestamp / rewardsDuration) * rewardsDuration;
        epochs.push(Epoch({ supply: 0, date: uint32(currentEpoch) }));
    }

    function decimals() public view returns (uint8) {
        return _decimals;
    }

    function name() public view returns (string memory) {
        return _name;
    }

    function symbol() public view returns (string memory) {
        return _symbol;
    }

    /* ========== ADMIN CONFIGURATION ========== */

    // Add a new reward token to be distributed to stakers
    function addReward(
        address _rewardToken,
        address _distributor,
        bool _useBoost
    ) public onlyOwner {
        require(rewardData.lastUpdateTime == 0, "invalid lastUpdateTime");
        require(_rewardToken != address(0), "address zero");
        require(_rewardToken != address(stakingToken), "rewardtoken is stakingtoken");
        rewardData.lastUpdateTime = uint40(block.timestamp);
        rewardData.periodFinish = uint40(block.timestamp);
        rewardData.useBoost = _useBoost;
        rewardDistributors[_distributor] = true;
        rewardToken = _rewardToken;
    }

    // Modify approval for an address to call notifyRewardAmount
    function approveRewardDistributor(address _distributor, bool _approved) external onlyOwner {
        require(rewardData.lastUpdateTime > 0, "invalid lastUpdateTime");
        require(_distributor != address(0), "address 0");
        rewardDistributors[_distributor] = _approved;
    }

    //Set the staking contract for the underlying cvx. only allow change if nothing is currently staked
    function setStakingContract(address _staking) external onlyOwner {
        require(stakingProxy == address(0) || (minimumStake == 0 && maximumStake == 0), "!assign");

        stakingProxy = _staking;
    }

    //set staking limits. will stake the mean of the two once either ratio is crossed
    function setStakeLimits(uint256 _minimum, uint256 _maximum) external onlyOwner {
        require(_minimum <= denominator, "min range");
        require(_maximum <= denominator, "max range");
        minimumStake = _minimum;
        maximumStake = _maximum;
        updateStakeRatio(0);
    }

    //set kick incentive
    function setKickIncentive(uint256 _rate, uint256 _delay) external onlyOwner {
        require(_rate <= 500, "over max rate"); //max 5% per epoch
        require(_delay >= 2, "min delay"); //minimum 2 epochs of grace
        kickRewardPerEpoch = _rate;
        kickRewardEpochDelay = _delay;
    }

    //shutdown the contract. unstake all tokens. release all locks
    function shutdown() external onlyOwner {
        if (stakingProxy != address(0)) {
            uint256 stakeBalance = IStakingProxy(stakingProxy).getBalance();
            IStakingProxy(stakingProxy).withdraw(stakeBalance);
        }
        isShutdown = true;
    }

    //set approvals for staking cvx and cvxcrv
    function setApprovals() external {
        IERC20(stakingToken).safeIncreaseAllowance(stakingProxy, type(uint256).max);
    }

    /* ========== VIEWS ========== */

    function _userRewardsPerLock(address _user)
        internal
        view
        returns (uint256 rewardShortLock, uint256 rewardLongLock)
    {
        rewardShortLock = (balances[_user].shortLocked * shortLockRewardMultiplier) / lockRewardDenominator;
        rewardLongLock = (balances[_user].longLocked * longLockRewardMultiplier) / lockRewardDenominator;
    }

    function _userRewards(address _user) internal view returns (uint256) {
        (uint256 short, uint256 long) = _userRewardsPerLock(_user);
        return short + long;
    }

    // get total balance locked for user
    function _userLockedBalance(address _account) internal view returns (uint256) {
        return balances[_account].shortLocked + balances[_account].longLocked;
    }

    function _rewardPerToken() internal view returns (uint256) {
        if (lockedSupply == 0) {
            return rewardData.rewardPerTokenStored;
        }
        return
            ((uint256(rewardData.rewardPerTokenStored) +
                _lastTimeRewardApplicable(rewardData.periodFinish) -
                rewardData.lastUpdateTime) *
                rewardData.rewardRate *
                1e18) / lockedSupply;
    }

    function _earned(address _user, uint256 _balance) internal view returns (uint256) {
        return ((_balance * (_rewardPerToken() - userRewardPerTokenPaid[_user])) / 1e18) + _userRewards(_user);
    }

    function _lastTimeRewardApplicable(uint256 _finishTime) internal view returns (uint256) {
        return Math.min(block.timestamp, _finishTime);
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return _lastTimeRewardApplicable(rewardData.periodFinish);
    }

    function rewardPerToken() external view returns (uint256) {
        return _rewardPerToken();
    }

    function getRewardForDuration() external view returns (uint256) {
        return uint256(rewardData.rewardRate) * rewardsDuration;
    }

    function getLockDuration(uint8 _type) public pure returns (uint256 duration) {
        if (_type == uint8(LockDuration.DURATION_LONG_LOCK)) {
            duration = longLockDuration;
        } else if (_type == uint8(LockDuration.DURATION_SHORT_LOCK)) {
            duration = shortLockDuration;
        }
    }

    // Address and claimable amount of all reward tokens for the given account
    function claimableRewards(address _account) external view returns (uint256 userRewards) {
        userRewards = _earned(_account, _userLockedBalance(_account));

        return userRewards;
    }

    // total token balance of an account, including unlocked but not withdrawn tokens
    function lockedBalanceOf(address _user) external view returns (uint256 amount) {
        return _userLockedBalance(_user);
    }

    //find an epoch index based on timestamp
    function findEpochId(uint256 _time) external view returns (uint256 epoch) {
        uint256 max = epochs.length - 1;
        uint256 min = 0;

        //convert to start point
        _time = (_time / rewardsDuration) * rewardsDuration;

        for (uint256 i = 0; i < 128; i++) {
            if (min >= max) break;

            uint256 mid = (min + max + 1) / 2;
            uint256 midEpochBlock = epochs[mid].date;
            if (midEpochBlock == _time) {
                //found
                return mid;
            } else if (midEpochBlock < _time) {
                min = mid;
            } else {
                max = mid - 1;
            }
        }
        return min;
    }

    // Information on a user's locked balances
    function lockedBalances(address _user)
        external
        view
        returns (
            uint256 total,
            uint256 unlockable,
            uint256 locked,
            LockedBalance[] memory lockData
        )
    {
        LockedBalance[] storage locks = userLocks[_user];
        Balances storage userBalance = balances[_user];
        uint256 nextUnlockIndex = userBalance.nextUnlockIndex;
        uint256 idx;
        for (uint256 i = nextUnlockIndex; i < locks.length; i++) {
            if (locks[i].unlockTime > block.timestamp) {
                if (idx == 0) {
                    lockData = new LockedBalance[](locks.length - i);
                }
                lockData[idx] = locks[i];
                idx++;
                locked = locked + locks[i].amount;
            } else {
                unlockable = unlockable + locks[i].amount;
            }
        }
        return (userBalance.shortLocked + userBalance.longLocked, unlockable, locked, lockData);
    }

    //number of epochs
    function epochCount() external view returns (uint256) {
        return epochs.length;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function checkpointEpoch() external {
        _checkpointEpoch();
    }

    //insert a new epoch if needed. fill in any gaps
    function _checkpointEpoch() internal {
        uint256 currentEpoch = (block.timestamp / rewardsDuration) * rewardsDuration;
        uint256 epochindex = epochs.length;

        //first epoch add in constructor, no need to check 0 length

        //check to add
        if (epochs[epochindex - 1].date < currentEpoch) {
            //fill any epoch gaps
            while (epochs[epochs.length - 1].date != currentEpoch) {
                uint256 nextEpochDate = uint256(epochs[epochs.length - 1].date) + rewardsDuration;
                epochs.push(Epoch({ supply: 0, date: uint32(nextEpochDate) }));
            }
        }
    }

    // Locked tokens cannot be withdrawn for lockDuration and are eligible to receive stakingReward rewards
    function lock(
        address _account,
        uint8 _lockPeriodType,
        uint256 _amount
    ) external nonReentrant updateReward(_account) {
        //pull tokens
        stakingToken.safeTransferFrom(msg.sender, address(this), _amount);

        //lock
        _lock(_account, _lockPeriodType, uint112(_amount));
    }

    //lock tokens
    function _lock(
        address _account,
        uint8 _lockPeriodType,
        uint112 _amount
    ) internal {
        require(_amount > 0, "Cannot stake 0");
        require(!isShutdown, "shutdown");
        uint256 accountLockDuration = getLockDuration(_lockPeriodType);
        require(accountLockDuration > 0, "invalid lock duration");

        LockDuration lockD;
        Balances storage bal = balances[_account];

        //must try check pointing epoch first
        _checkpointEpoch();

        //add user balances
        if (_lockPeriodType == uint8(LockDuration.DURATION_SHORT_LOCK)) {
            lockD = LockDuration.DURATION_SHORT_LOCK;
            bal.shortLocked += _amount;
        } else if (_lockPeriodType == uint8(LockDuration.DURATION_LONG_LOCK)) {
            lockD = LockDuration.DURATION_LONG_LOCK;
            bal.longLocked += _amount;
        }

        //add to total supplies
        lockedSupply += _amount;

        // add user lock records or add to current
        uint256 currentEpoch = (block.timestamp / rewardsDuration) * rewardsDuration;
        uint256 unlockTime = currentEpoch + accountLockDuration;
        uint256 idx = userLocks[_account].length;
        if (idx == 0 || userLocks[_account][idx - 1].unlockTime < unlockTime) {
            userLocks[_account].push(
                LockedBalance({ amount: _amount, unlockTime: uint32(unlockTime), lockType: lockD })
            );
        } else {
            LockedBalance storage userL = userLocks[_account][idx - 1];
            userL.amount = userL.amount + _amount;
        }

        //update epoch supply, epoch checkpointed above so safe to add to latest
        Epoch storage e = epochs[epochs.length - 1];
        e.supply = e.supply + uint224(_amount);

        //update staking, allow a bit of leeway for smaller deposits to reduce gas
        updateStakeRatio(stakeOffsetOnLock);

        emit Staked(_account, _amount, _amount);
    }

    // Withdraw all currently locked tokens where the unlock time has passed
    function _processExpiredLocks(
        address _account,
        bool _relock,
        uint8 _lockType,
        address _withdrawTo,
        address _rewardAddress,
        uint256 _checkDelay
    ) internal updateReward(_account) {
        LockedBalance[] storage locks = userLocks[_account];
        Balances storage userBalance = balances[_account];
        uint256 length = locks.length;
        uint256 reward = 0;
        uint112 shortLocked;
        uint112 longLocked;

        if (isShutdown || locks[length - 1].unlockTime <= block.timestamp - _checkDelay) {
            //if time is beyond last lock, can just bundle everything together
            //locked = userBalance.locked;
            //locked = userBalance.shortLocked + userBalance.longLocked;
            shortLocked = userBalance.shortLocked;
            longLocked = userBalance.longLocked;

            //dont delete, just set next index
            userBalance.nextUnlockIndex = uint32(length);

            //check for kick reward
            //this wont have the exact reward rate that you would get if looped through
            //but this section is supposed to be for quick and easy low gas processing of all locks
            //we'll assume that if the reward was good enough someone would have processed at an earlier epoch
            if (_checkDelay > 0) {
                uint256 currentEpoch = ((block.timestamp - _checkDelay) / rewardsDuration) * rewardsDuration;
                uint256 epochsover = (currentEpoch - uint256(locks[length - 1].unlockTime)) / rewardsDuration;
                uint256 rRate = Math.min(kickRewardPerEpoch * (epochsover + 1), denominator);
                reward = (uint256(locks[length - 1].amount) * rRate) / (denominator);
            }
        } else {
            //use a processed index(nextUnlockIndex) to not loop as much
            //deleting does not change array length
            uint32 nextUnlockIndex = userBalance.nextUnlockIndex;
            for (uint256 i = nextUnlockIndex; i < length; i++) {
                //unlock time must be less or equal to time
                if (locks[i].unlockTime > block.timestamp - _checkDelay) break;

                //add to cumulative amounts
                if (locks[i].lockType == LockDuration.DURATION_LONG_LOCK) {
                    longLocked += locks[i].amount;
                } else if (locks[i].lockType == LockDuration.DURATION_SHORT_LOCK) {
                    shortLocked += locks[i].amount;
                }

                //check for kick reward
                //each epoch over due increases reward
                if (_checkDelay > 0) {
                    uint256 currentEpoch = ((block.timestamp - _checkDelay) / rewardsDuration) * rewardsDuration;
                    uint256 epochsover = (currentEpoch - uint256(locks[i].unlockTime)) / rewardsDuration;
                    uint256 rRate = Math.min(kickRewardPerEpoch * (epochsover + 1), denominator);
                    reward = reward + ((uint256(locks[i].amount) * rRate) / denominator);
                }
                //set next unlock index
                nextUnlockIndex++;
            }
            //update next unlock index
            userBalance.nextUnlockIndex = nextUnlockIndex;
        }
        require(shortLocked > 0 || longLocked > 0, "no exp locks");

        // stack too deep
        uint112 locked;
        {
            //update user balances and total supplies
            userBalance.shortLocked -= shortLocked;
            userBalance.longLocked -= longLocked;
            locked = shortLocked + longLocked;
            lockedSupply -= locked;

            emit Withdrawn(_account, locked, _relock);

            //send process incentive
            if (reward > 0) {
                //if theres a reward(kicked), it will always be a withdraw only
                //preallocate enough cvx from stake contract to pay for both reward and withdraw
                allocateCVEForTransfer(uint256(locked));

                //reduce return amount by the kick reward
                locked -= uint112(reward);

                //transfer reward
                transferCVE(_rewardAddress, reward, false);

                emit KickReward(_rewardAddress, _account, reward);
            }

            //relock or return to user
            if (_relock) {
                _lock(_withdrawTo, _lockType, locked);
            } else {
                transferCVE(_withdrawTo, locked, true);
            }
        }
    }

    // Withdraw/relock all currently locked tokens where the unlock time has passed
    function processExpiredLocks(
        bool _relock,
        uint8 _lockType,
        address _withdrawTo
    ) external nonReentrant {
        _processExpiredLocks(msg.sender, _relock, _lockType, _withdrawTo, msg.sender, 0);
    }

    // Withdraw/relock all currently locked tokens where the unlock time has passed
    function processExpiredLocks(bool _relock, uint8 _lockType) external nonReentrant {
        _processExpiredLocks(msg.sender, _relock, _lockType, msg.sender, msg.sender, 0);
    }

    function kickExpiredLocks(address _account) external nonReentrant {
        //allow kick after grace period of 'kickRewardEpochDelay'
        _processExpiredLocks(_account, false, 0, _account, msg.sender, rewardsDuration * kickRewardEpochDelay);
    }

    //pull required amount of cvx from staking for an upcoming transfer
    function allocateCVEForTransfer(uint256 _amount) internal {
        uint256 balance = stakingToken.balanceOf(address(this));
        if (_amount > balance) {
            IStakingProxy(stakingProxy).withdraw(_amount - balance);
        }
    }

    //transfer helper: pull enough from staking, transfer, updating staking ratio
    function transferCVE(
        address _account,
        uint256 _amount,
        bool _updateStake
    ) internal {
        //allocate enough cvx from staking for the transfer
        allocateCVEForTransfer(_amount);
        //transfer
        stakingToken.safeTransfer(_account, _amount);

        //update staking
        if (_updateStake) {
            updateStakeRatio(0);
        }
    }

    //calculate how much cve should be staked. update if needed
    function updateStakeRatio(uint256 _offset) internal {
        if (isShutdown) return;

        //get balances
        uint256 local = stakingToken.balanceOf(address(this));
        uint256 staked = IStakingProxy(stakingProxy).getBalance();
        uint256 total = local + staked;

        if (total == 0) return;

        //current staked ratio
        uint256 ratio = (staked * denominator) / total;
        //mean will be where we reset to if unbalanced
        uint256 mean = (maximumStake + minimumStake) / 2; //10000
        uint256 max = maximumStake + _offset; // 10500
        uint256 min = Math.min(minimumStake, minimumStake - _offset); //9500
        if (ratio > max) {
            //remove
            uint256 remove = staked - ((total * mean) / denominator);
            IStakingProxy(stakingProxy).withdraw(remove);
        } else if (ratio < min) {
            //add
            uint256 increase = ((total * mean) / denominator) - staked;
            stakingToken.safeTransfer(stakingProxy, increase);
            IStakingProxy(stakingProxy).stake();
        }
    }

    // Claim all pending rewards
    function getReward(address _account) public updateReward(_account) {
        uint256 reward = rewards[_account];
        if (reward > 0) {
            rewards[_account] = 0;
            IERC20(rewardToken).safeTransfer(_account, reward);
            emit RewardPaid(_account, rewardToken, reward);
        }
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function _notifyReward(uint256 _reward) internal {
        Reward storage rdata = rewardData;

        if (block.timestamp >= rdata.periodFinish) {
            rdata.rewardRate = uint208(_reward / rewardsDuration);
        } else {
            uint256 remaining = uint256(rdata.periodFinish) - block.timestamp;
            uint256 leftover = remaining * rdata.rewardRate;
            rdata.rewardRate = uint208((_reward + leftover) / rewardsDuration);
        }

        rdata.lastUpdateTime = uint40(block.timestamp);
        rdata.periodFinish = uint40(block.timestamp + rewardsDuration);
    }

    function notifyRewardAmount(uint256 _reward) external updateReward(address(0)) {
        require(rewardDistributors[msg.sender], "not distributor");
        require(_reward > 0, "No reward");

        _notifyReward(_reward);

        // handle the transfer of reward tokens via `transferFrom` to reduce the number
        // of transactions required and ensure correctness of the _reward amount
        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), _reward);

        emit RewardAdded(rewardToken, _reward);
    }

    // Added to support recovering LP Rewards from other systems such as BAL to be distributed to holders
    function recoverERC20(address _tokenAddress, uint256 _tokenAmount) external onlyOwner {
        require(_tokenAddress != address(stakingToken), "Cannot withdraw staking token");
        require(_tokenAddress != address(rewardToken), "Cannot withdraw reward token");
        IERC20(_tokenAddress).safeTransfer(owner(), _tokenAmount);
        emit Recovered(_tokenAddress, _tokenAmount);
    }

    /* ========== MODIFIERS ========== */

    modifier updateReward(address _account) {
        {
            //stack too deep
            rewardData.rewardPerTokenStored = uint208(_rewardPerToken());
            rewardData.lastUpdateTime = uint40(_lastTimeRewardApplicable(rewardData.periodFinish));
            if (_account != address(0)) {
                //check if reward is boostable or not. use boosted or locked balance accordingly
                rewards[_account] = _earned(_account, _userLockedBalance(_account));
                userRewardPerTokenPaid[_account] = rewardData.rewardPerTokenStored;
            }
        }
        _;
    }
}
