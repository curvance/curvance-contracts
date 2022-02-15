//SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./CveCVE.sol";

// TODO: write natspec comments
// TODO: check for reentrancy vulnerabilities
contract VotingEscrow is Ownable {
    using SafeERC20 for IERC20;

    event Locked(address indexed _user, uint256 _amount);
    event RewardPaid(address indexed _user, address indexed _rewardsToken, uint256 _amount);

    struct Balance {
        uint256 amount;
        /// @dev Tracks the first unexpired lock
        uint32 nextUnlockIndex;
    }
    struct Lock {
        uint256 amount;
        uint64 unlockTime;
    }
    struct Reward {
        uint40 periodFinish;
        uint208 rewardRate;
        // TODO: implement changing reward rates
        uint40 lastUpdateTime;
        uint208 rewardPerTokenStored;
    }

    IERC20 public immutable cve;
    address public wrapperAddress;

    // TODO: potentially make multisig owner and replace this with "owner" instead?
    address public teamMultisig;
    uint256 public delegatedVotes;

    address[] public rewardTokens;
    mapping(address => Reward) public rewardData;
    mapping(address => mapping(address => uint256)) public claimableRewards;
    // reward token -> distributor -> is approved to add rewards
    mapping(address => mapping(address => bool)) public rewardDistributors;

    mapping(address => Balance) public userBalances;
    mapping(address => Lock[]) public userLocks;

    uint256 public totalLockedSupply;

    uint256 public constant REWARDS_DURATION = 86400 * 7;
    uint256 public constant LOCK_DURATION = REWARDS_DURATION * 52;

    string public name;
    string public symbol;
    uint8 public immutable decimals;

    constructor(IERC20 _cve, address _wrapperAddress) Ownable() {
        name = "Vote Escrow Curvance Token";
        symbol = "veCVE";
        decimals = 18;

        cve = _cve;
        wrapperAddress = _wrapperAddress;

        // TODO: epoch stuff
        // epochs.push(Epoch({supply: 0, date: uint32(_getCurrentEpoch())}));
    }

    function addReward(address _rewardToken, address _distributor) public onlyOwner {
        require(rewardData[_rewardToken].lastUpdateTime == 0, "exist");
        require(_rewardToken != address(cve), "!assign");
        rewardTokens.push(_rewardToken);
        rewardData[_rewardToken].lastUpdateTime = uint40(block.timestamp);
        rewardData[_rewardToken].periodFinish = uint40(block.timestamp);
        rewardDistributors[_rewardToken][_distributor] = true;
    }

    function balanceOf(address _account) external view returns (uint256) {
        if (_account == teamMultisig) {
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
        if (locksLength > 0 && uint256(locks[locksLength - 1].unlockTime) - LOCK_DURATION == _getCurrentEpoch()) {
            amount -= locks[locksLength - 1].amount;
        }

        return amount;
    }

    function deposit(address _account, uint256 _amount) external {
        updateReward(_account);

        cve.safeTransferFrom(_account, address(this), _amount);

        totalLockedSupply += _amount;
        /// @dev Deletgates votes to the team multisig
        delegatedVotes += _amount;

        CveCVE(wrapperAddress).mint(_account, _amount);
    }

    // lock for LOCK_DURATION
    function _lock(address _account, uint256 _amount) internal {
        updateReward(_account);

        Balance storage userBalance = userBalances[_account];
        userBalance.amount += _amount;
        totalLockedSupply += _amount;

        uint256 unlockTime = _getCurrentEpoch() + LOCK_DURATION;

        uint256 locksLength = userLocks[_account].length;
        if (locksLength == 0 || userLocks[_account][locksLength - 1].unlockTime < unlockTime) {
            userLocks[_account].push(Lock({ amount: _amount, unlockTime: uint64(unlockTime) }));
        } else {
            userLocks[_account][locksLength - 1].amount += _amount;
        }

        // TODO: implement update staking, allow a bit of leeway for smaller deposits to reduce gas
        // updateStakeRatio(stakeOffsetOnLock);

        emit Locked(_account, _amount);
    }

    function lock(uint256 _amount) external {
        require(_amount > 0, "invalid amount");
        cve.safeTransferFrom(msg.sender, address(this), _amount);

        _lock(msg.sender, _amount);
    }

    function lockFor(address _account, uint256 _amount) external {
        require(msg.sender == wrapperAddress, "!auth");
        // TODO: can't be just this (for transferring)
        delegatedVotes -= _amount;

        _lock(_account, _amount);
    }

    function claimAll(address _account) public {
        updateReward(_account);

        for (uint256 i; i < rewardTokens.length; i++) {
            address _rewardToken = rewardTokens[i];
            uint256 claimable = claimableRewards[_account][_rewardToken];
            if (claimable > 0) {
                claimableRewards[_account][_rewardToken] = 0;
                IERC20(_rewardToken).safeTransfer(_account, claimable);
                emit RewardPaid(_account, _rewardToken, claimable);
            }
        }
    }

    function updateReward(address _account) public {
        // for (uint256 i = 0; i < rewardTokens.length; i++) {
        //     address rewardToken = rewardTokens[i];
        //     rewardData[rewardToken].rewardPerTokenStored = _rewardPerToken(rewardToken);
        // }
    }

    function _getCurrentEpoch() internal view returns (uint256) {
        return (block.timestamp / REWARDS_DURATION) * REWARDS_DURATION;
    }
}
