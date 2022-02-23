//SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IStakingProxy.sol";
import "./interfaces/IRewardStaking.sol";

// TODO Shouldn't need these -- verify handling of math operations
import "./interfaces/BoringMath.sol";
import "./interfaces/MathUtil.sol";

/**
* @title Curvance Vote Escrow
* @author Created by Curvance Team based on:
    - Convex Finance CvxLocker - http://www.convexfinance.com/
    - Based on EPS Staking contract - http://ellipsis.finance/
    - Based on SNX MultiRewards by iamdefinitelyahuman - https://github.com/iamdefinitelyahuman/multi-rewards
* @notice Designed to handle multiple rewards, allows for kicking unlocked CVE. 
*/
contract VotingEscrow is Ownable {
    using SafeERC20 for IERC20;

    event Locked(address indexed _user, uint256 _amount);
    event RewardPaid(address indexed _user, address indexed _rewardsToken, uint256 _amount);
    event TeamAddressUpdated(address indexed _multisig, uint256 blockheight);

    /// @notice Tracks user balances.
    struct Balance {
        uint256 amount;
        /// @dev Tracks the first unexpired lock
        uint32 nextUnlockIndex;
    }

    /// @notice Tracks lock amounts & unlock times.
    struct Lock {
        uint256 amount;
        uint64 unlockTime;
    }

    /// @notice Tracks reward token data.
    struct Reward {
        uint40 periodFinish;
        uint208 rewardRate;
        // TODO: implement changing reward rates
        uint40 lastUpdateTime;
        uint208 rewardPerTokenStored;
    }

    /// @notice Defines the addresses used for tokens & contracts
    IERC20 public immutable cve;
    address public wrapper;
    address public staking;

    /// @notice Vote delegation tracking.
    address public teamMultisig;
    uint256 public delegatedVotes;

    /// @notice Allows for specified contracts to lock & unlock as needed (the wrapper)
    mapping(address => bool) public anytimeLockers; // can lock and unlock/withdraw anytime

    uint256 public totalLockedSupply;

    uint256 public constant rewardsDuration = 86400 * 7; // 7 days
    uint256 public constant lockDuration = rewardsDuration * 52; // 1 year

    /// @notice Reward token tracking
    address[] public rewardTokens;
    mapping(address => Reward) public rewardData;
    mapping(address => mapping(address => uint256)) public claimableRewards;
    mapping(address => mapping(address => uint256)) public userRewardPerTokenPaid;
    mapping(address => mapping(address => uint256)) public rewards;
    // reward token -> distributor -> is approved to add rewards
    mapping(address => mapping(address => bool)) public rewardDistributors;

    /// @notice User balances tracking.
    mapping(address => Balance) public userBalances;
    mapping(address => Lock[]) public userLocks;

    /// @notice Locked token name, symbol & decimals.
    string public name;
    string public symbol;
    uint8 public immutable decimals;

    /// @notice Variables used for math within contract.
    uint256 public denominator = 10000;
    uint256 public kickRewardPerWeek = 100;
    uint256 public kickRewardDelay = 4 * rewardsDuration;
    uint256 public minimumStake;
    uint256 public maximumStake;

    /// @notice Contract shutdown status.
    bool public isShutdown = false; // <-- didn't need to be defined as false

    /// @notice Creates the Vote Escrow contract
    /// @param _cve Address of the CVE token interface
    /// @param _wrapper Address of the wrapper TODO (interface?)
    constructor(IERC20 _cve, address _wrapper) {
        name = "Vote Escrow Curvance Token";
        symbol = "veCVE";
        decimals = 18;

        cve = _cve;
        wrapper = _wrapper;

        anytimeLockers[_wrapper] = true;
    }

    ////////////////////////////////////////////
    //                Modifiers                //
    ////////////////////////////////////////////

    /**
     * @dev Used for functions callable only by the wrapper contract
     * @notice wrapper is the address of CveCVE.sol
     */
    modifier onlyWrapper() {
        require(msg.sender == wrapper, "!wrapper");
        _;
    }

    /// @notice Verifies that the caller is allowed to unlock any time, that it is the wrapper.
    modifier onlyAnytimeLocker() {
        require(anytimeLockers[msg.sender], "!auth");
        _;
    }

    /// TODO Is this needed or is it more efficient to call this the updateReward as a function from within?
    modifier updateReward(address _account) {
        {
            //stack too deep
            Balances storage userBalance = balances[_account];
            uint256 boostedBal = userBalance.boosted;
            for (uint256 i = 0; i < rewardTokens.length; i++) {
                address token = rewardTokens[i];
                rewardData[token].rewardPerTokenStored = _rewardPerToken(token).to208(); // reward token cvxCRV
                rewardData[token].lastUpdateTime = _lastTimeRewardApplicable(rewardData[token].periodFinish).to40(); // set's claim time to now
                if (_account != address(0)) {
                    //check if reward is boostable or not. use boosted or locked balance accordingly
                    rewards[_account][token] = _earned(
                        _account,
                        token,
                        rewardData[token].useBoost ? boostedBal : userBalance.locked
                    ); // the amount of cvxCRV user gets
                    userRewardPerTokenPaid[_account][token] = rewardData[token].rewardPerTokenStored;
                }
            }
        }
        _;
    }

    ////////////////////////////////////////////
    //             Administrative             //
    ////////////////////////////////////////////

    /** TODO Could the wrapper just have a special function like wrapperLock & wrapperUnlock with
     *        a modifier that says onlyWrapper?
     * @notice Set the contract allowed to lock & unlock without time restrictions.
     * @dev Callable only by the Owner.
     * @param _locker Address of CveCVE.sol.
     */
    function toggleAnytimeLocker(address _locker) external onlyOwner {
        require(_locker != wrapper, "wrapper is permanent");
        require(_locker != address(0), "invalid locker");
        anytimeLockers[_locker] = !anytimeLockers[_locker];
    }

    /** TODO Not needed if not doing a staking contract... Or just set these as fixed values like Convex does...
     * TODO EITHER WAY, THIS CAN PROBABLY GO AWAY
     * @notice Set the minimum & maximum CVE stake amounts.
     * @dev Needed for setStakingContract()
     * @param _minimum Minimum amount staked.
     * @param _maximum Maximum amount staked.
     */
    function setStakingMinMax(uint256 _minimum, uint256 _maximum) external onlyOwner {
        minimumStake = _minimum;
        maximumStake = _maximum;
    }

    /**
     * @notice Set the staking contract address for CVX.
     * @dev Staking contract must have a zero balance to change this.
     * @param _staking Address of the staking contract.
     */
    //Set the staking contract for the underlying cvx. only allow change if nothing is currently staked
    function setStakingContract(address _staking) external onlyOwner {
        require(staking == address(0) || (minimumStake == 0 && maximumStake == 0), "!assign");

        staking = _staking;
    }

    /// @notice Set the incentive rate for the kick rewards.
    /// @dev The percent is 100 for 1%; delay is the number of weeks until kick.
    /// @param _ratePercent Percentage of the tokens given as rewards per week (100 == 1%).
    /// @param _weeksDelay Number of weeks until an unlock is eligible to be kicked.
    function setKickIncentive(uint256 _ratePercent, uint256 _weeksDelay) external onlyOwner {
        require(_rate <= 500, "over max rate"); //max 5% per epoch
        require(_delay >= 2, "min delay"); //minimum 2 epochs of grace
        kickRewardPerWeek = _ratePercent;
        kickRewardDelay = _weeksDelay * rewardsDuration;
    }

    /// @notice Sets the team multisig for vote delegation.
    /// @param _multisigAddress The multisig for delegated votes.
    function setTeamMultisig(address payable _multisigAddress) external onlyOwner {
        teamMultisig = _multisigAddress;
        emit TeamAddressUpdated(_multisigAddress, block.number);
    }

    //shutdown the contract. unstake all tokens. release all locks
    /** TODO Update this to match our parameters */
    /// @notice Shuts down the contract, unstakes all tokens, releases all locks.
    function shutdown() external onlyOwner {
        if (stakingProxy != address(0)) {
            uint256 stakeBalance = IStakingProxy(stakingProxy).getBalance();
            IStakingProxy(stakingProxy).withdraw(stakeBalance);
        }
        isShutdown = true;
    }

    ////////////////////////////////////////////
    //                 Rewards                //
    ////////////////////////////////////////////

    // TODO: not mixing delegated votes (cve) with cve rewards. aka avoiding cve.balanceOf(address(this));
    /// @notice Adds a new reward token.
    /// @param _rewardToken The address for the reward token
    /// @param _distributor The address for the distribution contract.
    function addReward(address _rewardToken, address _distributor) external onlyOwner {
        require(rewardData[_rewardToken].lastUpdateTime == 0, "exist");
        //require(_rewardToken != address(cve), "!assign");
        rewardTokens.push(_rewardToken);
        rewardData[_rewardToken].lastUpdateTime = uint40(block.timestamp);
        rewardData[_rewardToken].periodFinish = uint40(block.timestamp);
        rewardDistributors[_rewardToken][_distributor] = true;
    }

    /// @notice Allows claiming of all available rewards for the caller.
    /// @param _account Address of the caller seeking rewards claims.
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

    /// @notice Updates the rewards available for claiming
    /// @param _account Address of the caller seeking rewards claims.
    function updateReward(address _account) public {
        Balance memory userBalance = userBalances[_account];

        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address token = rewardTokens[i];
            rewardData[token].rewardPerTokenStored = uint208(_rewardPerToken(token));
            rewardData[token].lastUpdateTime = uint40(_lastTimeRewardApplicable(rewardData[token].periodFinish));
            if (_account != address(0)) {
                // use locked balance
                claimableRewards[_account][token] = _earned(_account, token, userBalance.amount);
                userRewardPerTokenPaid[_account][token] = rewardData[token].rewardPerTokenStored;
            }
        }
    }

    /// @notice Checks the most recent time a user claimed rewards.
    /// @param _rewardToken The token being claimed.
    function lastTimeRewardApplicable(address _rewardToken) public view returns (uint256) {
        return _lastTimeRewardApplicable(rewardData[_rewardToken].periodFinish);
    }

    ////////////////////////////////////////////
    //            Internal Checks             //
    ////////////////////////////////////////////

    /// @notice Gives reward rate per token locked.
    /// @param _rewardToken Token being claimed.
    /// @return Rate of rewardsToken per locked token per unit time.
    /// @dev Needs to be called for each reward token.
    function _rewardPerToken(address _rewardToken) internal view returns (uint256) {
        if (totalLockedSupply == 0) {
            return rewardData[_rewardToken].rewardPerTokenStored;
        }
        return
            ((uint256(rewardData[_rewardToken].rewardPerTokenStored) +
                _lastTimeRewardApplicable(rewardData[_rewardToken].periodFinish) -
                rewardData[_rewardToken].lastUpdateTime) *
                rewardData[_rewardToken].rewardRate *
                1e18) / totalLockedSupply;
    }

    /// @notice Calculates the amount of _rewardsToken earned by an account.
    /// @param _user The address that owns the locked CVE.
    /// @param _rewardsToken Reward token being claimed.
    /// @param _balance Balance of locked tokens.
    /// @return Reward claimable.
    /// @dev Needs to be checked for each reward token.
    function _earned(
        address _user,
        address _rewardsToken,
        uint256 _balance
    ) internal view returns (uint256) {
        return
            ((_balance * (_rewardPerToken(_rewardsToken) - userRewardPerTokenPaid[_user][_rewardsToken])) / 1e18) +
            rewards[_user][_rewardsToken];
    }

    /// @notice Called by lastTimeRewardApplicable
    function _lastTimeRewardApplicable(uint256 _finishTime) internal view returns (uint256) {
        return Math.min(block.timestamp, _finishTime);
    }

    ////////////////////////////////////////////
    //            Token Transfers             //
    ////////////////////////////////////////////

    /// @notice Set allowance.
    function setCveApproval() external {
        cve.safeIncreaseAllowance(staking, type(uint256).max);
    }

    /// @notice Deposit CVE into contract.
    /// TODO SHOULD THIS BE CALLED BY `lock` RATHER THAN USING CVE.SAFETRANSFERFROM ???
    function deposit(address _account, uint256 _amount) external {
        updateReward(_account);

        cve.safeTransferFrom(_account, address(this), _amount);

        totalLockedSupply += _amount;
        /// @dev Deletgates votes to the team multisig
        delegatedVotes += _amount;

        ICveCVE(wrapper).mint(_account, _amount);

        // TODO: stake on behalf of team delegate
    }

    /// @notice Initiates the CVE lock.
    /// @param _amount Amount of CVE to lock
    /// @param _listed True if called by the wrapper so it can unlock any time.
    function lock(uint256 _amount, bool _listed) external {
        require(_amount > 0, "invalid amount");
        if (_listed) {
            require(anytimeLockers[msg.sender], "not listed");
        }
        cve.safeTransferFrom(msg.sender, address(this), _amount);
        // TODO: consider anytime lockers

        _lock(msg.sender, _amount, _listed);
    }

    /// TODO Function for the wrapper to unlock the CVE and re-lock it at any time.
    function unlock(uint256 _amount, bool _listed) external onlyAnytimeLocker {
        ///TODO Add removal from wrapper and re-lock.
    }

    function lockFor(address _account, uint256 _amount) external onlyWrapper {
        // TODO: can't be just this (for transferring)
        delegatedVotes -= _amount;

        _lock(_account, _amount, anytimeLockers[_account]);
    }

    /**
     * TODO implement staking buffer for small fish
     * @notice Lock CVE for lockDuration.
     * @dev
     * @param _account Address of the staking contract.
     * @param _amount Amount of CVE to lock
     * @param _listed ??? TODO... Is this whether to use as collateral or not?
     */
    function _lock(
        address _account,
        uint256 _amount,
        bool _listed
    ) internal {
        updateReward(_account);

        Balance storage userBalance = userBalances[_account];
        userBalance.amount += _amount;
        totalLockedSupply += _amount;

        uint256 unlockTime;
        if (_listed) {
            unlockTime = type(uint64).max; /// TODO What is this doing?
        } else {
            unlockTime = block.timestamp + lockDuration;
        }

        uint256 locksLength = userLocks[_account].length;
        if (locksLength == 0 || userLocks[_account][locksLength - 1].unlockTime < unlockTime) {
            userLocks[_account].push(Lock({ amount: _amount, unlockTime: uint64(unlockTime) }));
        } else {
            userLocks[_account][locksLength - 1].amount += _amount;
        }

        // TODO: implement update staking, allow a bit of leeway for smaller deposits to reduce gas
        // updateStakeRatio(stakeOffsetOnLock);

        // OR stake directly?? @TODO I'd vote for this, if we actually need to have tokens sent to a staking contract

        emit Locked(_account, _amount);
    }

    // total token balance of an account, including unlocked but not withdrawn tokens
    /// @notice Provides the total balance of locked tokens held by an address.
    function lockedBalanceOf(address _user) external view returns (uint256) {
        return userBalances[_user].amount;
    }

    /** TODO Which of these is needed ? lockedBalanceOf vs. balanceOf */

    /// @notice Provides the total balance of a users locks.
    /// @dev Used for VotingStrategy.sol .
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

        /// @dev Also remove amount in the current epoch.
        /// TODO - remove Epoch & use block.timestamp compared to user unlock time.
        /// TODO - locks removed from user storage if removed after the lockDuration also (so: unlockTime >= block.timestamp)
        if (locksLength > 0 && uint256(locks[locksLength - 1].unlockTime) - lockDuration >= block.timestamp) {
            amount -= locks[locksLength - 1].amount;
        }

        return amount;
    }

    /// @notice Returns the balance of CVE locked.
    /// @dev used for VotingStrategy.sol
    function getTotalLockedSupply() external view returns (uint256) {
        return totalLockedSupply;
    }

    ////////////////////////////////////////////
    //                The Kick                //
    ////////////////////////////////////////////

    /** TODO Why does the Convex Locker have three? Seems like 2 would be OK. Is withdrawTo needed as a separate fxn? */

    // Withdraw/relock all currently locked tokens where the unlock time has passed
    /**
     * @notice Allows withdrawal to a different account than the sender.
     * @dev `0` used for `_checkDelay` since token owner is activating this.
     * @param _relock Boolean engaged by UI if user wants to relock CVE.
     * @param _withdrawTo Address where CVE should be withdrawn to.
     */
    function processExpiredLocks(bool _relock, address _withdrawTo) external nonReentrant {
        _processExpiredLocks(msg.sender, _relock, _withdrawTo, msg.sender, 0);
    }

    /**
     * @notice Allows user to unlock CVE and receive it back at their address.
     * @dev `0` used for `_checkDelay` since token owner is activating this.
     * @param _relock Boolean engaged by UI if user wants to relock CVE.
     */
    // Withdraw/relock all currently locked tokens where the unlock time has passed
    function processExpiredLocks(bool _relock) external nonReentrant {
        _processExpiredLocks(msg.sender, _relock, msg.sender, msg.sender, 0);
    }

    /**
     * @notice Expulsion of another's unlocked CVE from the locker.
     * @notice Removes tokens and sends back to owner, minus a fee.
     * @dev The kickRewardDelay is used here.
     * @param _account Address where CVE should be withdrawn to - entered by kickooooor.
     */
    function kickExpiredLocks(address _account) external nonReentrant {
        //allow kick after grace period of 'kickRewardWeekDelay'
        _processExpiredLocks(_account, false, _account, msg.sender, kickRewardDelay);
    }

    // Withdraw all currently locked tokens where the unlock time has passed
    /**
     * @notice Accounting for exipred locks processing.
     * @param _account Account with expired locks.
     * @param _relock boolean whether to relock or not.
     * @param _withdrawTo Address where CVE is to be withdrawn to.
     * @param _rewardAddress Address receiving the Rewards.
     * @param _checkDelay `0` if token owner initiates, otherwise, use `kickRewardDelay`.
     */
    function _processExpiredLocks(
        address _account,
        bool _relock,
        address _withdrawTo,
        address _rewardAddress,
        uint256 _checkDelay
    ) internal updateReward(_account) {
        LockedBalance[] storage locks = userLocks[_account];
        Balances storage userBalance = balances[_account];
        uint112 locked;
        uint112 boostedAmount;
        uint256 length = locks.length;
        uint256 reward = 0;

        if (isShutdown || locks[length - 1].unlockTime <= block.timestamp.sub(_checkDelay)) {
            //if time is beyond last lock, can just bundle everything together
            locked = userBalance.locked;

            ///TODO get rid of this.
            //boostedAmount = userBalance.boosted;

            //dont delete, just set next index
            userBalance.nextUnlockIndex = length.to32();

            //check for kick reward
            //this wont have the exact reward rate that you would get if looped through
            //but this section is supposed to be for quick and easy low gas processing of all locks
            //we'll assume that if the reward was good enough someone would have processed at an earlier epoch
            if (_checkDelay > 0) {
                /** @notice if > 0, then a `kick` is taking place */

                /** TODO The goal is to give the kickoooor 1% per week after delay times out
                    * denominator was used as 10,000. So, 100/10000 = 1% or 0.1 
                    TODO CHECK THE MATHS!!! 
                    Alternate calculation option down in the next `else` section to compare & evaluate! */

                // Determines the amount of time since the end of the kickRewardsDelay
                uint256 timeSinceOver = block.timestamp.sub(_checkDelay).sub(uint256(locks[length - 1].unlockTime));
                // Determines the rewards for the kickoooor
                reward = uint256(locks[length - 1].amount).mul(kickRewardPerWeek).mul(timeSinceOver).div(denominator);
            }
        } else {
            /** @notice checkDelay == 0, then this is the token owner managing their assets */
            //use a processed index(nextUnlockIndex) to not loop as much
            //deleting does not change array length
            uint32 nextUnlockIndex = userBalance.nextUnlockIndex;
            for (uint256 i = nextUnlockIndex; i < length; i++) {
                //unlock time must be less or equal to time
                if (locks[i].unlockTime > block.timestamp.sub(_checkDelay)) break;

                //add to cumulative amounts
                locked = locked.add(locks[i].amount);
                //boostedAmount = boostedAmount.add(locks[i].boosted);

                //check for kick reward
                //each epoch over due increases reward
                if (_checkDelay > 0) {
                    /** TODO This is a different option for how to calculate the Rewards for the kickooooor. Compare them for accuracy & gas efficiency! */
                    uint256 timeSinceOver = block.timestamp.sub(_checkDelay).sub(uint256(locks[length - 1].unlockTime)); //TODO is this needed? .div(rewardsDuration);
                    uint256 rRate = MathUtil.min(kickRewardPerWeek.mul(rewardsDuration), denominator);
                    reward = uint256(locks[length - 1].amount).mul(rRate).div(denominator);
                }

                //set next unlock index
                nextUnlockIndex++;
            }
            //update next unlock index
            userBalance.nextUnlockIndex = nextUnlockIndex;
        }
        require(locked > 0, "no exp locks");

        //update user balances and total supplies
        userBalance.locked = userBalance.locked.sub(locked);
        //userBalance.boosted = userBalance.boosted.sub(boostedAmount);
        lockedSupply = lockedSupply.sub(locked);
        //boostedSupply = boostedSupply.sub(boostedAmount);

        emit Withdrawn(_account, locked, _relock);

        //send process incentive
        if (reward > 0) {
            //if theres a reward(kicked), it will always be a withdraw only
            //preallocate enough cvx from stake contract to pay for both reward and withdraw
            allocateCVEForTransfer(uint256(locked));

            //reduce return amount by the kick reward
            locked = locked.sub(reward.to112());

            //transfer reward
            transferCVE(_rewardAddress, reward, false);

            emit KickReward(_rewardAddress, _account, reward);
        }

        //relock or return to user
        if (_relock) {
            _lock(_withdrawTo, locked, _spendRatio);
        } else {
            transferCVE(_withdrawTo, locked, true);
        }
    }

    ////////////////////////////////////////////
    //      Needed if CVE to be staked        //
    ////////////////////////////////////////////

    /** 
    * TODO If this is something we want to include, this needs updating & adding the needed variables
    *
    * Such as these: 
    uint256 public minimumStake = 10000;
    uint256 public maximumStake = 10000;
    address public stakingProxy;
    address public constant cvxcrvStaking = address(0x3Fe65692bfCD0e6CF84cB1E7d24108E434A7587e);
    uint256 public constant stakeOffsetOnLock = 500; //allow broader range for staking when depositing
    //token constants
    IERC20 public constant stakingToken = IERC20(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B); //cvx
    address public constant cvxCrv = address(0x62B9c7356A2Dc64a1969e19C23e4f579F9810Aa7);

    */

    //pull required amount of cvx from staking for an upcoming transfer
    function allocateCVEForTransfer(uint256 _amount) internal {
        uint256 balance = stakingToken.balanceOf(address(this));
        if (_amount > balance) {
            IStakingProxy(stakingProxy).withdraw(_amount.sub(balance));
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

    //calculate how much cvx should be staked. update if needed
    function updateStakeRatio(uint256 _offset) internal {
        if (isShutdown) return;

        //get balances
        uint256 local = stakingToken.balanceOf(address(this)); // how much cvx is in here
        uint256 staked = IStakingProxy(stakingProxy).getBalance(); // how much cvx is staked
        uint256 total = local.add(staked);

        if (total == 0) return;

        //current staked ratio
        uint256 ratio = staked.mul(denominator).div(total);
        //mean will be where we reset to if unbalanced
        uint256 mean = maximumStake.add(minimumStake).div(2);
        uint256 max = maximumStake.add(_offset);
        uint256 min = Math.min(minimumStake, minimumStake - _offset);
        if (ratio > max) {
            //remove
            uint256 remove = staked.sub(total.mul(mean).div(denominator)); // amount to remove from staker
            IStakingProxy(stakingProxy).withdraw(remove); // execute the unstaking
        } else if (ratio < min) {
            //add
            uint256 increase = total.mul(mean).div(denominator).sub(staked); // amount to send to staker
            stakingToken.safeTransfer(stakingProxy, increase);
            IStakingProxy(stakingProxy).stake(); // execute the staking
        }
    }
}
