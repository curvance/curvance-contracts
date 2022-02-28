//SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./interfaces/ICveCVE.sol";
import "./interfaces/IStakingProxy.sol";

interface CToken {
    function totalAdminFees() external view returns (uint256);

    function _withdrawAdminFees(uint256 withdrawAmount) external returns (uint256);
}

interface IComptroller {
    function getAllMarkets() external view returns (CToken[] memory);
}

contract VotingEscrow is Ownable {
    using SafeERC20 for IERC20;

    event Locked(address indexed _user, uint256 _amount);
    event Withdrawn(address indexed _user, uint256 _amount, bool _relocked);
    event Unwrap(address indexed _to, uint256 _amount);
    event RewardPaid(address indexed _user, address indexed _rewardsToken, uint256 _amount);
    event KickReward(address indexed _user, address indexed _kicked, uint256 _amount);
    event FundedReward(address indexed _token, uint256 _amount);

    struct Balance {
        uint224 amount;
        /// @dev Tracks the first unexpired lock
        uint32 nextUnlockIndex;
    }
    struct Lock {
        uint224 amount;
        uint32 unlockTime;
    }
    struct Reward {
        uint40 periodFinish;
        uint216 rewardRate;
        uint40 lastUpdateTime;
        uint216 rewardPerTokenStored;
    }

    IERC20 public immutable cve;
    address public immutable wrapper;

    address public staking;
    bool public isShutdown;
    uint8 public immutable decimals;

    uint256 public minimumStake = 10_000;
    uint256 public maximumStake = 10_000;
    uint256 public constant stakeOffsetOnLock = 500;

    uint256 public delegatedVotes;

    address[] public rewardTokens;
    address[] public pools;

    uint256 public totalLockedSupply;

    uint256 public constant REWARDS_DURATION = 86_400 * 7;
    uint256 public constant LOCK_DURATION = REWARDS_DURATION * 52;

    uint256 public constant DENOMINATOR = 10_000;
    uint256 public kickRewardPerWeek = 100;
    uint256 public gracePeriod = REWARDS_DURATION * 4;

    mapping(address => Reward) public rewardData;
    mapping(address => mapping(address => uint256)) public claimableRewards;
    /// @dev reward token -> distributor -> is approved to add rewards
    mapping(address => mapping(address => bool)) public rewardDistributors;

    mapping(address => Balance) public userBalances;
    mapping(address => Lock[]) public userLocks;

    string public name;
    string public symbol;

    /// @dev Owner should be the Curvance team's multisig
    constructor(
        IERC20 _cve,
        address _wrapper,
        address _staking
    ) Ownable() {
        name = "Vote Escrow Curvance Token";
        symbol = "veCVE";
        decimals = 18;

        cve = _cve;
        wrapper = _wrapper;
        staking = _staking;
    }

    function deposit(address _account, uint256 _amount) external {
        updateReward(_account);

        cve.safeTransferFrom(msg.sender, address(this), _amount);

        totalLockedSupply += _amount;
        /// @dev Deletgates votes to the team multisig
        delegatedVotes += _amount;

        ICveCVE(wrapper).mint(_account, _amount);
    }

    function lock(uint224 _amount) external {
        require(_amount > 0, "invalid amount");
        cve.safeTransferFrom(msg.sender, address(this), _amount);
        _lock(msg.sender, _amount);
    }

    function unwrap(uint224 _amount) external {
        ICveCVE(wrapper).burn(msg.sender, _amount);
        totalLockedSupply -= _amount;
        delegatedVotes -= _amount;
        _lock(msg.sender, _amount);

        emit Unwrap(msg.sender, _amount);
    }

    /// @dev Should be called immediately after deployment
    function setApprovals() external {
        cve.safeIncreaseAllowance(staking, type(uint256).max);
    }

    function withdraw(address _account, uint256 _amount) external onlyOwner {
        _withdraw(_account, _amount, true);
    }

    /// @notice Set the staking contract for the underlying CVE
    function setStakingContract(address _staking) external onlyOwner {
        // TODO: withdraw
        staking = _staking;
    }

    function addPool(address _comptroller) external {
        // TODO: require statement
        pools.push(_comptroller);
    }

    function claimAll(address _account) external {
        updateReward(_account);

        for (uint256 i; i < rewardTokens.length; i++) {
            address _rewardToken = rewardTokens[i];
            uint256 claimable = claimableRewards[_account][_rewardToken];
            if (claimable > 0) {
                claimableRewards[_account][_rewardToken] = 0;
                IERC20(_rewardToken).safeTransferFrom(msg.sender, _account, claimable);
                emit RewardPaid(_account, _rewardToken, claimable);
            }
        }
    }

    /// @notice Withdraw/relock all currently locked tokens where the unlock time has passed
    function processExpiredLocks(bool _relock, address _withdrawTo) external {
        _processExpiredLocks(msg.sender, _relock, _withdrawTo, msg.sender, false);
    }

    /// @notice Withdraw/relock all currently locked tokens where the unlock time has passed
    function processExpiredLocks(bool _relock) external {
        _processExpiredLocks(msg.sender, _relock, msg.sender, msg.sender, false);
    }

    function kickExpiredLocks(address _account) external {
        /// @dev Allow kick after grace period
        _processExpiredLocks(_account, false, _account, msg.sender, true);
    }

    function setStakeLimits(uint256 _minimum, uint256 _maximum) external onlyOwner {
        require(_minimum <= DENOMINATOR, "out of range");
        require(_maximum <= DENOMINATOR, "out of range");
        minimumStake = _minimum;
        maximumStake = _maximum;
        updateStakeRatio(0);
    }

    function setKickIncentive(uint256 _rate, uint256 _delay) external onlyOwner {
        require(_rate <= 500, "over max rate"); /// @dev Max 5% per epoch
        require(_delay >= 2, "min delay"); /// @dev Minimum 2 weeks of grace
        kickRewardPerWeek = _rate;
        gracePeriod = REWARDS_DURATION * _delay;
    }

    /// @dev Shuts down the contract, unstakes all tokens, releases all locks
    function shutdown() external onlyOwner {
        if (staking != address(0)) {
            uint256 stakedBalance = IStakingProxy(staking).getBalance();
            IStakingProxy(staking).withdraw(stakedBalance);
        }
        isShutdown = true;
    }

    function approveRewardDistributor(
        address _rewardsToken,
        address _distributor,
        bool _approved
    ) external onlyOwner {
        require(rewardData[_rewardsToken].lastUpdateTime > 0, "!exist");
        rewardDistributors[_rewardsToken][_distributor] = _approved;
    }

    function addReward(address _rewardToken, address _distributor) external onlyOwner {
        require(rewardData[_rewardToken].lastUpdateTime == 0, "exist");
        require(_rewardToken != address(cve), "!assign");
        rewardTokens.push(_rewardToken);
        rewardData[_rewardToken].lastUpdateTime = uint40(block.timestamp);
        rewardData[_rewardToken].periodFinish = uint40(block.timestamp);
        rewardDistributors[_rewardToken][_distributor] = true;
    }

    function recoverToken(address _token, address _to) external onlyOwner {
        uint256 balance = IERC20(_token).balanceOf(address(this));
        recoverToken(_token, _to, balance);
    }

    /// @dev Total token balance of an account, including unlocked but not withdrawn tokens
    function lockedBalanceOf(address _user) external view returns (uint256) {
        return userBalances[_user].amount;
    }

    function balanceOf(address _account) external view returns (uint256) {
        if (_account == owner()) {
            return delegatedVotes;
        }

        Lock[] storage locks = userLocks[_account];
        uint256 locksLength = locks.length;
        uint256 nextUnlockIndex = userBalances[_account].nextUnlockIndex;
        /// @dev Start with user's current locked balance
        uint256 amount = userBalances[_account].amount;
        /// @dev Removing old records is more gas efficient than adding up
        for (uint256 i = nextUnlockIndex; i < locksLength; i++) {
            if (locks[i].unlockTime <= block.timestamp) {
                amount -= locks[i].amount;
            } else {
                /// @dev Stop now as no futher checks are needed
                break;
            }
        }

        /// @dev Also remove amount in the current epoch
        uint256 currentEpoch = (block.timestamp / REWARDS_DURATION) * REWARDS_DURATION;
        if (locksLength > 0 && uint256(locks[locksLength - 1].unlockTime) - LOCK_DURATION == currentEpoch) {
            amount -= locks[locksLength - 1].amount;
        }

        return amount;
    }

    function updateReward(address _account) public {
        // TODO: implement
    }

    function harvestFees() public {
        for (uint256 i; i < pools.length; i++) {
            CToken[] memory markets = IComptroller(pools[i]).getAllMarkets();
            for (uint256 j; j < markets.length; j++) {
                uint256 totalFees = markets[j].totalAdminFees();
                markets[j]._withdrawAdminFees(totalFees);
            }
        }
    }

    function recoverToken(
        address _token,
        address _to,
        uint256 _amount
    ) public onlyOwner {
        require(_token != address(cve), "cannot withdraw staking token");
        require(rewardData[_token].lastUpdateTime == 0, "cannot withdraw reward token");
        IERC20(_token).safeTransferFrom(msg.sender, _to, _amount);
    }

    function _lock(address _account, uint224 _amount) internal {
        require(!isShutdown, "shutdown");
        require(_amount > 0, "invalid amount");

        updateReward(_account);

        Balance storage balance = userBalances[_account];
        balance.amount += _amount;
        totalLockedSupply += _amount;

        uint256 currentEpoch = (block.timestamp / REWARDS_DURATION) * REWARDS_DURATION;
        uint256 unlockTime = currentEpoch + LOCK_DURATION;

        uint256 locksLength = userLocks[_account].length;
        if (locksLength == 0 || userLocks[_account][locksLength - 1].unlockTime < unlockTime) {
            userLocks[_account].push(Lock({ amount: _amount, unlockTime: uint32(unlockTime) }));
        } else {
            userLocks[_account][locksLength - 1].amount += _amount;
        }

        updateStakeRatio(500);

        emit Locked(_account, _amount);
    }

    function _processExpiredLocks(
        address _account,
        bool _relock,
        address _withdrawTo,
        address _rewardAddress,
        bool _useGracePeriod
    ) internal {
        updateReward(_account);

        Lock[] storage locks = userLocks[_account];
        Balance storage balance = userBalances[_account];
        uint224 locked;
        uint256 length = locks.length;
        uint256 reward;
        uint256 checkTime = _useGracePeriod ? block.timestamp - gracePeriod : block.timestamp;

        if (isShutdown || locks[length - 1].unlockTime <= checkTime) {
            locked = balance.amount;

            balance.nextUnlockIndex = uint32(length);

            if (_useGracePeriod) {
                uint256 currentEpoch = (checkTime / REWARDS_DURATION) * REWARDS_DURATION;
                uint256 weeksPast = (currentEpoch - uint256(locks[length - 1].unlockTime)) / REWARDS_DURATION;
                uint256 rewardRate = Math.min(kickRewardPerWeek * (weeksPast + 1), DENOMINATOR);

                reward = (uint256(locks[length - 1].amount) * rewardRate) / DENOMINATOR;
            }
        } else {
            uint32 nextUnlockIndex = balance.nextUnlockIndex;
            for (uint256 i = nextUnlockIndex; i < length; i++) {
                if (locks[i].unlockTime > checkTime) break;

                locked += locks[i].amount;

                if (_useGracePeriod) {
                    uint256 currentEpoch = (checkTime / REWARDS_DURATION) * REWARDS_DURATION;
                    uint256 weeksPast = (currentEpoch - uint256(locks[length - 1].unlockTime)) / REWARDS_DURATION;
                    uint256 rewardRate = Math.min(kickRewardPerWeek * (weeksPast + 1), DENOMINATOR);

                    reward += (uint256(locks[i].amount) * rewardRate) / DENOMINATOR;
                }

                nextUnlockIndex++;
            }
            balance.nextUnlockIndex = nextUnlockIndex;
        }
        require(locked > 0, "no exp locks");

        balance.amount -= locked;
        totalLockedSupply -= locked;

        emit Withdrawn(_account, locked, _relock);

        if (reward > 0) {
            /// @dev Preallocate enough CVE from stake contract to pay for both reward and withdraw
            allocateForWithdrawal(uint256(locked));

            locked -= uint224(reward);

            _withdraw(_rewardAddress, reward, false);

            emit KickReward(_rewardAddress, _account, reward);
        }

        if (_relock) {
            _lock(_withdrawTo, locked);
        } else {
            _withdraw(_withdrawTo, locked, true);
        }
    }

    function _withdraw(
        address _account,
        uint256 _amount,
        bool _updateStake
    ) internal {
        allocateForWithdrawal(_amount);

        cve.safeTransferFrom(msg.sender, _account, _amount);

        if (_updateStake) {
            updateStakeRatio(0);
        }
    }

    function allocateForWithdrawal(uint256 _amount) internal {
        uint256 balance = cve.balanceOf(address(this));
        if (_amount > balance) {
            IStakingProxy(staking).withdraw(_amount - balance);
        }
    }

    function updateStakeRatio(uint256 _offset) internal {
        if (isShutdown) return;

        uint256 localBalance = cve.balanceOf(address(this));
        uint256 stakedBalance = IStakingProxy(staking).getBalance();
        uint256 total = localBalance + stakedBalance;

        if (total == 0) return;

        uint256 ratio = (stakedBalance * DENOMINATOR) / total;
        uint256 mean = (maximumStake + minimumStake) / 2;
        uint256 max = maximumStake + _offset;
        uint256 min = minimumStake - _offset;

        if (ratio < min) {
            uint256 addAmount = ((total * mean) / DENOMINATOR) - stakedBalance;
            cve.safeTransferFrom(msg.sender, staking, addAmount);
            IStakingProxy(staking).stake();
        } else if (ratio > max) {
            uint256 removeAmount = stakedBalance - ((total * mean) / DENOMINATOR);
            IStakingProxy(staking).withdraw(removeAmount);
        }
    }
}
