// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { DENOMINATOR, RAY } from "contracts/libraries/Constants.sol";
import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";
import { ReentrancyGuard } from "contracts/libraries/external/ReentrancyGuard.sol";
import { ERC165 } from "contracts/libraries/external/ERC165.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IGaugeManager } from "contracts/interfaces/IGaugeManager.sol";
import { RewardsData } from "contracts/interfaces/IRewardManager.sol";
import { IMarketManager } from "contracts/interfaces/market/IMarketManager.sol";
import { IMToken } from "contracts/interfaces/market/IMToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { ICVE } from "contracts/interfaces/ICVE.sol";
import { IVeCVE } from "contracts/interfaces/IVeCVE.sol";

/// @title Curvance Gauge Manager.
/// @notice A market specific system for distributing rewards to Curvance
///        market users inside the Curvance Protocol.
/// @dev A Curvance Gauge Manager manages rewards associated with a particular
///      Market Manager. Tokens are not actually "deposited" inside the
///      Gauge Manager, but rather information is documented. This creates an
///      incredibly efficient method of measuring and distributing rewards
///      as no secondary deposit/withdrawal execution is required by users
///      utilizing Curvance Protocol.
///
///      A Gauge Manager is built to support an infinite number of rewards in
///      any supported asset. The base level of CVE gauge emissions are
///      distributed through a markets corresponding Gauge Manager. CVE emissions
///      can be claimed directly, or locked in a 1 year voting escrow position
///      for an additional reward boost. This mechanism was built to better
///      align the duration exposure between Curvance users and the Curvance
///      DAO. The Curvance DAO has a long time horizon, and users who align
///      with that time horizon should be rewarded more greatly than users
///      with a short time horizon, which has a duration mismatch between
///      parties. Additional reward tokens can be streamed to users through
///      our "Partner Gauges" these act as additional reward layers on top of
///      the base CVE reward system. This allows protocols or chains to
///      directly incentivize their ecosystem without building any additional
///      technology on top. The partner gauge system works for any token
///      without writing any additional code.
///
///      Gauge rewards, and by extension the Partner Gauges, can distribute
///      rewards to collateral depositors, or lenders, in a market.
///      Borrowers intentionally do not have the ability to receive rewards
///      as this could create looped delta hedged strategies that do not
///      add value to the Curvance Protocol to receive essentially risk free
///      rewards.
///
///      The introduction of the ability to incentivize lenders creates an
///      opportunity not only for ecosystem to create attractive terms to
///      lend their ecosystem tokens. But to allow Curvance collateral
///      depositors the ability to incentivize external parties to
///      permissionlessly lend to them. This could, in theory, reduce the
///      interest rate that borrowers pay by attractive additional lenders to
///      their market of course, potentially minimizing their net expenses
///      borrowing inside a particular market.
///
contract GaugeManager is PluginDelegable, ERC165, ReentrancyGuard, IGaugeManager {
    /// TYPES ///

    /// @param totalWeights The total weight value of all tokens, inside
    ///                     the pool, for this epoch.
    /// @param tokenWeight The weight value of a token, inside the pool,
    ///                    for this epoch.
    /// @dev token => pool weight value.
    struct Epoch {
        uint256 totalWeights;
        mapping(address => uint256) tokenWeight;
    }

    struct UserRewardInfo {
        uint256 rewardDebt;
        uint256 rewardPending;
    }
    /// CONSTANTS ///

    uint256 constant SIX_MONTH_IN_EPOCH = 12;

    /// @notice CVE contract address.
    address public immutable cve;
    /// @notice VeCVE contract address.
    IVeCVE public immutable veCVE;
    /// @notice The length of one protocol epoch, in seconds.
    uint256 public immutable epochDuration;

    /// @dev `bytes4(keccak256(bytes("GaugeManager__Unauthorized()")))`.
    uint256 internal constant _UNAUTHORIZED_SELECTOR = 0x38b10c24;

    /// STORAGE ///

    /// @notice Start time that gauge controller starts, in unix time.
    uint256 public startTime;

    /// @notice Gauge emission values for the entire Gauge Manager,
    ///         and contained tokens, by epoch.
    /// @dev Epoch Number => Epoch information.
    mapping(uint256 => Epoch) internal _epochInfo;

    /// @notice Mapping for approved reward token
    /// @dev rewardToken => bool
    mapping(address => bool) public approvedRewardTokens;

    /// @dev mToken => index
    mapping(address => uint256) public lastRewardTokenIndex;

    /// @dev mToken => rewardToken => index
    mapping(address => mapping(address => uint256)) public rewardTokenToIndex;

    mapping(address => uint256) public rewardTokenToMinDistribution;

    /// @dev mToken => rewardTokens
    mapping(address => address[]) public rewardTokens;

    /// @dev mToken => rewardToken => last epoch
    mapping(address => mapping(address => uint256)) public lastEpochOf;

    /// @notice The total supply of a token deposited.
    /// @dev mToken => total supply.
    mapping(address => uint256) public totalSupply;
    /// @notice The total balance of a token deposited by a user.
    /// @dev mToken => user => balance.
    mapping(address => mapping(address => uint256)) public balanceOf;
    /// @notice The timestamp of the last time rewards were updated
    ///         for a particular token.
    /// @dev mToken => lastRewardTimestamp.
    mapping(address => uint256) public poolLastRewardTimestamp;
    /// @notice The amount of reward token accumulated per share
    ///         for a token.
    /// @notice mToken => rewardToken index => accRewardPerShare.
    mapping(address => mapping(uint256 => uint256))
        public poolAccRewardPerShare;
    /// @notice Information corresponding to rewards pending/debt pending
    ///         for a reward token, for a particular user, for a particular
    ///         deposited token.
    /// @dev mToken => user => rewardToken index => info.
    mapping(address => mapping(address => mapping(uint256 => UserRewardInfo)))
        public userDebtInfo;

    /// @notice The amount of rewards streamed per second, of a particular
    ///         reward token, during an epoch, for a specific token.
    /// @dev mToken => epoch => rewardToken index => rewardPerSec.
    mapping(address => mapping(uint256 => mapping(uint256 => uint256)))
        internal _epochRewardPerSec;

    /// ERRORS ///

    error GaugeManager__InvalidAddress();
    error GaugeManager__Unauthorized();
    error GaugeManager__NotStarted();
    error GaugeManager__InvalidEpoch();
    error GaugeManager__InvalidLength();
    error GaugeManager__InvalidToken();
    error GaugeManager__InvalidAmount();
    error GaugeManager__NoReward();
    error GaugeManager__InvalidRewardToken();

    /// EVENTS ///

    event SetMinDistributionAmount(address newReward, uint256 amount);
    event GaugeWeightsSet(uint256 epoch, address[] tokens, uint256[] weights);
    event AddExtraRewardToken(address newReward);
    event RemoveExtraRewardToken(address newReward);
    event Deposit(address user, address token, uint256 amount);
    event Withdraw(address user, address token, uint256 amount);
    event Claim(address user, address token);

    constructor(
        ICentralRegistry centralRegistry_
    ) PluginDelegable(centralRegistry_) {
        // Query epoch and token configuration directly to minimize potential
        // human error.
        cve = centralRegistry.cve();
        veCVE = IVeCVE(centralRegistry.veCVE());
        epochDuration = centralRegistry.EPOCH_DURATION();
        startTime = veCVE.nextEpochStartTime();

        approvedRewardTokens[cve] = true;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Returns gauge weight of given epoch and token.
    /// @param epoch The epoch to pull weights for.
    /// @param token The address of the gauge token to query weights for.
    function gaugeWeight(
        uint256 epoch,
        address token
    ) external view returns (uint256, uint256) {
        return (
            _epochInfo[epoch].totalWeights,
            _epochInfo[epoch].tokenWeight[token]
        );
    }

    /// @notice Sets emission rates of tokens of current epoch.
    /// @dev Only the messaging hub can call this.
    /// @param epoch The epoch to set emission rates for, should be the next
    ///              epoch.
    /// @param tokens Array containing all tokens to set emission rates for.
    /// @param weights Gauge weights corresponding to DAO voted emission
    ///                rates.
    function setEmissionRates(
        uint256 epoch,
        address[] calldata tokens,
        uint256[] calldata weights
    ) external override {
        if (
            msg.sender != centralRegistry.messagingHub() &&
            msg.sender != centralRegistry.votingHub()
        ) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        // Validate that Gauge system is fully active and only the current
        // epoch can have emissions set.
        if (
            !(epoch == 0 && (startTime == 0 || block.timestamp < startTime)) &&
            epoch != currentEpoch()
        ) {
            revert GaugeManager__InvalidEpoch();
        }

        uint256 numTokens = tokens.length;

        // Validate that tokens and weights are properly configured.
        if (numTokens != weights.length) {
            revert GaugeManager__InvalidLength();
        }

        Epoch storage info = _epochInfo[epoch];
        address priorAddress;
        bool poolUpdated;

        for (uint256 i; i < numTokens; ) {
            address token = tokens[i];

            // We sort the token addresses offchain from smallest to largest
            // to validate there are no duplicates.
            if (priorAddress >= token) {
                revert GaugeManager__InvalidToken();
            }

            if (info.tokenWeight[token] > 0) {
                poolUpdated = true;
                updatePool(token);
            }  else {
                poolUpdated = false;
            }

            info.totalWeights = info.totalWeights + weights[i];
            info.tokenWeight[token] = info.tokenWeight[token] + weights[i];

            if (rewardTokenToIndex[token][cve] == 0) {
                rewardTokens[token].push(cve);
                rewardTokenToIndex[token][cve] = ++lastRewardTokenIndex[token];
            }

            if (!poolUpdated) {
                updatePool(token);
            }

            unchecked {
                /// Update prior to current token, then increment i.
                priorAddress = tokens[i++];
            }
        }

        emit GaugeWeightsSet(epoch, tokens, weights);
    }

    /// @notice Update reward variables for all pools.
    /// @param tokens Array containing all tokens to update pools for.
    function massUpdatePools(address[] calldata tokens) external {
        uint256 numTokens = tokens.length;
        for (uint256 i; i < numTokens; ) {
            unchecked {
                /// Update pool for current token then increment i.
                updatePool(tokens[i++]);
            }
        }
    }

    function setMinDistributionAmount(
        address rewardToken,
        uint256 minAmount
    ) external {
        _checkDaoPermissions();

        if (approvedRewardTokens[rewardToken] == false) {
            revert GaugeManager__InvalidRewardToken();
        }

        rewardTokenToMinDistribution[rewardToken] = minAmount;

        emit SetMinDistributionAmount(rewardToken, minAmount);
    }

    /// @notice Adds a new reward to the gauge system.
    /// @param newReward The address of new reward token to be added.
    function addExtraRewardToken(
        address newReward,
        uint256 minAmount
    ) external {
        _checkDaoPermissions();

        if (newReward == address(0) || approvedRewardTokens[newReward]) {
            revert GaugeManager__InvalidAddress();
        }

        approvedRewardTokens[newReward] = true;
        rewardTokenToMinDistribution[newReward] = minAmount;

        emit AddExtraRewardToken(newReward);
    }

    /// @notice Removes an extra reward from the gauge system.
    /// @param newReward The address of the extra reward to be removed.
    function removeExtraRewardToken(address newReward) external {
        _checkDaoPermissions();

        // Cannot remove CVE as a reward token.
        if (newReward == cve) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        approvedRewardTokens[newReward] = false;
        rewardTokenToMinDistribution[newReward] = 0;

        emit RemoveExtraRewardToken(newReward);
    }

    /// @notice Returns the active reward tokens on the Gauge Manager,
    ///         for ease of integration by third parties.
    function getRewardTokens(
        address token
    ) external view returns (address[] memory) {
        return rewardTokens[token];
    }

    /// @notice Returns the number of active reward tokens on the Gauge Manager,
    ///         for ease of integration by third parties.
    function getRewardTokensLength(
        address token
    ) external view returns (uint256) {
        return rewardTokens[token].length;
    }

    /// @notice Used to update Gauge Manager rewards for `rewardToken`,
    ///         during `epoch` with `newRewardPerSec`.
    /// @dev This is only be used for updating partner gauge rewards.
    /// @param token The token to set rewards for.
    /// @param epoch The epoch to set rewards for, should be the next epoch.
    /// @param rewardToken The address of reward token to be updated.
    /// @param amount The additional rewards amount for distribution
    function addExtraRewards(
        address token,
        uint256 epoch,
        address rewardToken,
        uint256 amount
    ) external {
        // CVE rewards are only updated through the gauge system by
        // the messaging hub in setEmissionRates().
        if (rewardToken == cve) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        if (approvedRewardTokens[rewardToken] == false) {
            revert GaugeManager__InvalidRewardToken();
        }

        if (!(epoch == 0 && startTime == 0) && epoch != currentEpoch() + 1) {
            revert GaugeManager__InvalidEpoch();
        }

        address[] memory rewardTokenForMToken = rewardTokens[token];
        uint256 rewardTokensLength = rewardTokenForMToken.length;
        for (uint256 i; i < rewardTokensLength; ) {
            address _rewardToken = rewardTokenForMToken[i++];
            if (_rewardToken == cve || _rewardToken == rewardToken) {
                continue;
            }
            uint256 lastEpoch = lastEpochOf[token][_rewardToken];
            if (currentEpoch() > lastEpoch + SIX_MONTH_IN_EPOCH) {
                uint256 indexToRemove = rewardTokenToIndex[token][
                    _rewardToken
                ];
                if (indexToRemove != (rewardTokensLength - 1)) {
                    rewardTokens[token][indexToRemove] = rewardTokens[token][
                        rewardTokensLength - 1
                    ];
                }
                rewardTokens[token].pop();
                rewardTokenToIndex[token][_rewardToken] = 0;
            }
        }

        uint256 index = rewardTokenToIndex[token][rewardToken];
        if (index == 0) {
            rewardTokens[token].push(rewardToken);
            rewardTokenToIndex[token][rewardToken] = ++lastRewardTokenIndex[
                token
            ];
            index = lastRewardTokenIndex[token];
        }

        if (amount < rewardTokenToMinDistribution[rewardToken]) {
            revert GaugeManager__InvalidAmount();
        }

        updatePool(token);

        SafeTransferLib.safeTransferFrom(
            rewardToken,
            msg.sender,
            address(this),
            amount
        );

        _epochRewardPerSec[token][epoch][index] += amount / epochDuration;

        if (lastEpochOf[token][rewardToken] < epoch) {
            lastEpochOf[token][rewardToken] = epoch;
        }
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Returns current epoch number.
    function currentEpoch() public view returns (uint256) {
        return epochOfTimestamp(block.timestamp);
    }

    /// @notice Returns epoch number of `timestamp`.
    /// @param timestamp Timestamp in seconds.
    function epochOfTimestamp(
        uint256 timestamp
    ) public view returns (uint256) {
        _checkGaugeHasStarted();
        return
            timestamp < startTime
                ? 0
                : (timestamp - startTime) / epochDuration;
    }

    /// @notice Returns start time of `epoch`.
    /// @param epoch Epoch number to return start time for.
    function epochStartTime(uint256 epoch) public view returns (uint256) {
        _checkGaugeHasStarted();
        return startTime + epoch * epochDuration;
    }

    /// @notice Returns end time of `epoch`.
    /// @param epoch Epoch number to return end time for.
    function epochEndTime(uint256 epoch) public view returns (uint256) {
        _checkGaugeHasStarted();
        return startTime + (epoch + 1) * epochDuration;
    }

    /// @notice Returns if given gauge token is enabled in `epoch`.
    /// @param epoch Epoch number to check for gauge activity.
    /// @param token Gauge token address.
    function isGaugeEnabled(
        uint256 epoch,
        address token
    ) public view returns (bool) {
        return _epochInfo[epoch].tokenWeight[token] > 0;
    }

    /// @notice Returns reward emissions of a token.
    /// @param token Pool token address that receives `rewardToken` overtime.
    /// @param epoch The epoch number.
    /// @param rewardToken The reward token address.
    function rewardAllocation(
        address token,
        uint256 epoch,
        address rewardToken
    ) public view returns (uint256) {
        if (rewardToken == cve) {
            return _epochInfo[epoch].tokenWeight[token];
        }

        uint256 index = rewardTokenToIndex[token][rewardToken];
        if (index == 0 || approvedRewardTokens[rewardToken] == false) {
            revert GaugeManager__InvalidRewardToken();
        }

        return (epochDuration * _epochRewardPerSec[token][epoch][index]);
    }

    /// @notice Returns pending reward of user.
    /// @param token Pool token address.
    /// @param user User address.
    /// @param rewardToken Reward token address.
    function pendingRewards(
        address token,
        address user,
        address rewardToken
    ) public view returns (uint256) {
        uint256 index = rewardTokenToIndex[token][rewardToken];
        if (index == 0 || approvedRewardTokens[rewardToken] == false) {
            revert GaugeManager__InvalidRewardToken();
        }

        uint256 accRewardPerShare = poolAccRewardPerShare[token][index];
        uint256 lastRewardTimestamp = poolLastRewardTimestamp[token];
        uint256 totalDeposited = totalSupply[token];
        if (lastRewardTimestamp == 0) {
            lastRewardTimestamp = startTime;
        }

        if (block.timestamp > lastRewardTimestamp && totalDeposited != 0) {
            uint256 lastEpoch = epochOfTimestamp(lastRewardTimestamp);
            uint256 cachedCurrentEpoch = currentEpoch();
            uint256 reward;
            while (lastEpoch < cachedCurrentEpoch) {
                uint256 endTimestamp = epochEndTime(lastEpoch);

                // update rewards from lastRewardTimestamp to endTimestamp.
                reward =
                    ((endTimestamp - lastRewardTimestamp) *
                        rewardAllocation(token, lastEpoch, rewardToken)) /
                    epochDuration;
                accRewardPerShare =
                    accRewardPerShare +
                    (reward * RAY) /
                    totalDeposited;

                ++lastEpoch;
                lastRewardTimestamp = endTimestamp;
            }

            // update rewards from lastRewardTimestamp to current timestamp.
            reward =
                ((block.timestamp - lastRewardTimestamp) *
                    rewardAllocation(token, lastEpoch, rewardToken)) /
                epochDuration;
            accRewardPerShare =
                accRewardPerShare +
                (reward * RAY) /
                totalDeposited;
        }

        UserRewardInfo memory info = userDebtInfo[token][user][index];
        return
            info.rewardPending +
            (balanceOf[token][user] * accRewardPerShare) /
            RAY -
            info.rewardDebt;
    }

    /// @notice Returns pending rewards of user.
    /// @param token Pool token address.
    /// @param user User address.
    function pendingRewards(
        address token,
        address user
    ) external view returns (uint256[] memory results) {
        uint256 rewardTokensLength = rewardTokens[token].length;
        address[] memory rewardTokensForMToken = rewardTokens[token];
        results = new uint256[](rewardTokensLength);

        for (uint256 i; i < rewardTokensLength; ++i) {
            results[i] = pendingRewards(token, user, rewardTokensForMToken[i]);
        }
    }

    /// @notice Deposit into Gauge Manager.
    /// @param token Pool token address.
    /// @param user User address.
    /// @param amount Amounts to deposit.
    function deposit(
        address token,
        address user,
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) {
            revert GaugeManager__InvalidAmount();
        }

        // Make sure the token is listed inside this market,
        // and that the token is executing the deposit call.
        IMarketManager marketManager = IMToken(token).marketManager();
        if (
            msg.sender != token ||
            !marketManager.isListed(token) ||
            !centralRegistry.isMarketManager(address(marketManager))
        ) {
            revert GaugeManager__InvalidToken();
        }

        updatePool(token);

        _calcPending(user, token);

        balanceOf[token][user] += amount;
        totalSupply[token] += amount;

        _calcDebt(user, token);

        emit Deposit(user, token, amount);
    }

    /// @notice Registers a withdrawal of `token` deposits by `user`
    ///         from the Gauge Manager.
    /// @dev This does not actually include any token transfers as tokens
    ///      are permissionlessly escrowed by PToken/EToken contracts and
    ///      we simply record deposits/withdraws here.
    /// @param token Pool token address.
    /// @param user The user address.
    /// @param amount Amounts to withdraw.
    function withdraw(
        address token,
        address user,
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) {
            revert GaugeManager__InvalidAmount();
        }

        // Make sure the token is listed inside this market,
        // and that the token is executing the withdraw call.
        IMarketManager marketManager = IMToken(token).marketManager();
        if (
            msg.sender != token ||
            !marketManager.isListed(token) ||
            !centralRegistry.isMarketManager(address(marketManager))
        ) {
            revert GaugeManager__InvalidToken();
        }

        if (balanceOf[token][user] < amount) {
            revert GaugeManager__InvalidAmount();
        }

        updatePool(token);
        _calcPending(user, token);

        balanceOf[token][user] -= amount;
        totalSupply[token] -= amount;

        _calcDebt(user, token);

        emit Withdraw(user, token, amount);
    }

    /// @notice Claim all pending rewards for `tokens` from the Gauge Manager.
    /// @param tokens Array containing pool token addresses to claim
    ///               rewards for.
    /// @param user The user address that gauge rewards should be claimed for,
    ///             is the user is not the caller, delegation will be checked
    ///             instead.
    function claim(
        address[] calldata tokens,
        address user
    ) external nonReentrant {
        if (block.timestamp < startTime) {
            revert GaugeManager__NotStarted();
        }

        if (user != msg.sender) {
            if (!_checkIsDelegate(user, msg.sender)) {
                _revert(_UNAUTHORIZED_SELECTOR);
            }
        }

        uint256 cveRewards;
        uint256 numTokens = tokens.length;
        for (uint256 i; i < numTokens; ) {
            cveRewards += _claim(tokens[i++]);
        }

        if (cveRewards == 0) {
            return;
        }

        SafeTransferLib.safeTransfer(cve, msg.sender, cveRewards);
    }

    function _claim(address token) internal returns (uint256 cveRewards) {
        updatePool(token);
        _calcPending(msg.sender, token);

        address[] memory rewardTokensForMToken = rewardTokens[token];
        uint256 numTokens = rewardTokensForMToken.length;

        for (uint256 i; i < numTokens; ) {
            // Query rewardToken then increment i.
            address rewardToken = rewardTokensForMToken[i++];
            uint256 index = rewardTokenToIndex[token][rewardToken];
            uint256 rewards = userDebtInfo[token][msg.sender][index]
                .rewardPending;
            // If the caller has rewards, send them,
            // and prevent transaction reversion.
            if (rewards > 0) {
                if (rewardToken == cve) {
                    cveRewards = rewards;
                } else {
                    SafeTransferLib.safeTransfer(
                        rewardToken,
                        msg.sender,
                        rewards
                    );
                }
            }

            // Update pending rewards to zero.
            userDebtInfo[token][msg.sender][index].rewardPending = 0;
        }

        _calcDebt(msg.sender, token);

        emit Claim(msg.sender, token);
    }

    /// @notice Claim rewards from Gauge Manager and compound any CVE rewards
    ///         into `lockIndex`.
    /// @dev Users who choose to lock emissions may potentially receive an
    ///      emission boost based on `lockBoostMultiplier` stored inside the
    ///      DAO Central Registry.
    /// @param tokens Array containing pool token addresses to claim
    ///               rewards for.
    /// @param lockIndex The index of the lock to extend.
    /// @param continuousLock Whether the lock should be continuous or not.
    /// @param rewardsData Rewards data for desired Reward Manager action.
    /// @param params Parameters for rewards claim function.
    /// @param aux Auxiliary data.
    function claimAndExtendLock(
        address[] calldata tokens,
        uint256 lockIndex,
        bool continuousLock,
        RewardsData memory rewardsData,
        bytes calldata params,
        uint256 aux
    ) external nonReentrant {
        // If gauge emissions have not started yet,
        // theres nothing to claim and lock.
        if (block.timestamp < startTime) {
            revert GaugeManager__NotStarted();
        }

        uint256 cveRewards;
        uint256 numTokens = tokens.length;
        for (uint256 i; i < numTokens; ) {
            cveRewards += _claim(tokens[i++]);
        }

        if (cveRewards == 0) {
            revert GaugeManager__NoReward();
        }

        uint256 currentLockBoost = centralRegistry.lockBoostMultiplier();

        // If theres a current lock boost, recognize their bonus rewards.
        if (currentLockBoost > 0) {
            uint256 boostedRewards = (cveRewards * currentLockBoost) /
                DENOMINATOR;
            // We know this will never underflow due to `currentLockBoost`
            // needing to be greater than 1.
            ICVE(cve).mintLockBoost(boostedRewards - cveRewards);
            cveRewards = boostedRewards;
        }

        // Approve veCVE to take necessary cve to extend the lock.
        SafeTransferLib.safeApprove(cve, address(veCVE), cveRewards);
        veCVE.increaseAmountAndExtendLockFor(
            msg.sender,
            cveRewards,
            lockIndex,
            continuousLock,
            rewardsData,
            params,
            aux
        );
    }

    /// @notice Claim rewards from Gauge Manager and compound any CVE rewards
    ///         into a new veCVE lock.
    /// @dev Users who choose to lock emissions may potentially receive an
    ///      emission boost based on `lockBoostMultiplier` stored inside the
    ///      DAO Central Registry.
    /// @param token Pool token address.
    /// @param continuousLock Indicator of whether the lock should be continuous.
    /// @param rewardsData Rewards data for desired Reward Manager action.
    /// @param params Parameters for rewards claim function.
    /// @param aux Auxiliary data.
    function claimAndLock(
        address token,
        bool continuousLock,
        RewardsData memory rewardsData,
        bytes memory params,
        uint256 aux
    ) external nonReentrant {
        // If gauge emissions have not started yet,
        // theres nothing to claimAndLock.
        if (block.timestamp < startTime) {
            revert GaugeManager__NotStarted();
        }

        updatePool(token);
        _calcPending(msg.sender, token);

        // Check user pending rewards.
        uint256 index = rewardTokenToIndex[token][cve];
        uint256 rewards = userDebtInfo[token][msg.sender][index].rewardPending;
        if (rewards == 0) {
            revert GaugeManager__NoReward();
        }

        // Update pending rewards to zero.
        userDebtInfo[token][msg.sender][index].rewardPending = 0;

        uint256 currentLockBoost = centralRegistry.lockBoostMultiplier();
        // If theres a current lock boost, recognize their bonus rewards.
        if (currentLockBoost > 0) {
            uint256 boostedRewards = (rewards * currentLockBoost) /
                DENOMINATOR;
            // We know this will never underflow due to `currentLockBoost`
            // needing to be greater than 1.
            ICVE(cve).mintLockBoost(boostedRewards - rewards);
            rewards = boostedRewards;
        }

        // Approve veCVE to take necessary cve to create the new lock.
        SafeTransferLib.safeApprove(cve, address(veCVE), rewards);
        veCVE.createLockFor(
            msg.sender,
            rewards,
            continuousLock,
            rewardsData,
            params,
            aux
        );

        _calcDebt(msg.sender, token);

        emit Claim(msg.sender, token);
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Update reward variables of the given pool to be up-to-date.
    /// @param token Pool token address.
    function updatePool(address token) public {
        // If rewards have not started yet, there is nothing to update.
        if (startTime == 0 || block.timestamp <= startTime) {
            return;
        }

        uint256 _lastRewardTimestamp = poolLastRewardTimestamp[token];
        // If nobody has updated reward timestamp, time to set it up to startTime.
        if (_lastRewardTimestamp == 0) {
            _lastRewardTimestamp = startTime;
        }

        // Make sure time has passed since the last update.
        if (block.timestamp <= _lastRewardTimestamp) {
            return;
        }

        // Is there are no deposits, there is nothing to update.
        uint256 totalDeposited = totalSupply[token];
        if (totalDeposited == 0) {
            return;
        }

        // Cache rewardTokens length.
        address[] memory rewardTokensForMToken = rewardTokens[token];
        uint256 rewardTokensLength = rewardTokensForMToken.length;
        for (uint256 i; i < rewardTokensLength; ) {
            uint256 lastRewardTimestamp = _lastRewardTimestamp;

            // Query rewardToken then increment i.
            address rewardToken = rewardTokensForMToken[i++];
            uint256 index = rewardTokenToIndex[token][rewardToken];
            uint256 accRewardPerShare = poolAccRewardPerShare[token][index];
            uint256 lastEpoch = epochOfTimestamp(lastRewardTimestamp);
            uint256 cachedCurrentEpoch = currentEpoch();
            uint256 reward;

            // Step through epochs and apply rewards.
            while (lastEpoch < cachedCurrentEpoch) {
                uint256 endTimestamp = epochEndTime(lastEpoch);

                // Update rewards from lastRewardTimestamp to endTimestamp.
                reward =
                    (RAY *
                        (endTimestamp - lastRewardTimestamp) *
                        rewardAllocation(token, lastEpoch, rewardToken)) /
                    epochDuration;
                accRewardPerShare =
                    accRewardPerShare +
                    (reward / totalDeposited);

                ++lastEpoch;
                lastRewardTimestamp = endTimestamp;
            }

            // Update rewards from lastRewardTimestamp to current timestamp.
            reward =
                (RAY *
                    (block.timestamp - lastRewardTimestamp) *
                    rewardAllocation(token, lastEpoch, rewardToken)) /
                epochDuration;
            accRewardPerShare = accRewardPerShare + reward / totalDeposited;

            poolAccRewardPerShare[token][index] = accRewardPerShare;
        }

        // Update pool storage.
        poolLastRewardTimestamp[token] = block.timestamp;
    }

    /// @inheritdoc ERC165
    function supportsInterface(
        bytes4 interfaceId
    ) public view override returns (bool) {
        return
            interfaceId == type(IGaugeManager).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// INTERNAL FUNCTIONS ///

    /// @dev Checks whether the caller has sufficient permissioning.
    function _checkDaoPermissions() internal view {
        if (!centralRegistry.hasDaoPermissions(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }
    }

    /// @dev Checks whether the gauge controller has started or not.
    function _checkGaugeHasStarted() internal view {
        if (startTime == 0) {
            revert GaugeManager__NotStarted();
        }
    }

    /// @notice Calculate user's pending rewards.
    /// @param user User address.
    /// @param token Pool token address.
    function _calcPending(address user, address token) internal {
        address[] memory rewardTokensForMToken = rewardTokens[token];
        uint256 rewardTokensLength = rewardTokensForMToken.length;

        for (uint256 i; i < rewardTokensLength; ) {
            // Query rewardToken then increment i.
            address rewardToken = rewardTokensForMToken[i++];
            uint256 index = rewardTokenToIndex[token][rewardToken];
            UserRewardInfo storage info = userDebtInfo[token][user][index];
            info.rewardPending +=
                (balanceOf[token][user] *
                    poolAccRewardPerShare[token][index]) /
                RAY -
                info.rewardDebt;
        }
    }

    /// @notice Calculate user's debt amount for reward calculation.
    /// @param user User address.
    /// @param token Pool token address.
    function _calcDebt(address user, address token) internal {
        address[] memory rewardTokensForMToken = rewardTokens[token];
        uint256 rewardTokensLength = rewardTokensForMToken.length;

        for (uint256 i; i < rewardTokensLength; ) {
            // Query rewardToken then increment i.
            address rewardToken = rewardTokensForMToken[i++];
            uint256 index = rewardTokenToIndex[token][rewardToken];
            UserRewardInfo storage info = userDebtInfo[token][user][index];
            info.rewardDebt =
                (balanceOf[token][user] *
                    poolAccRewardPerShare[token][index]) /
                RAY;
        }
    }

    /// @dev Internal helper for reverting efficiently.
    function _revert(uint256 s) internal pure {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, s)
            revert(0x1c, 0x04)
        }
    }
}
