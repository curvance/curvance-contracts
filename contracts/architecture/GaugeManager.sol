// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";
import { ReentrancyGuard } from "contracts/libraries/ReentrancyGuardTransient.sol";
import { BPS, RAY } from "contracts/libraries/ConstantsLib.sol";

import { ERC165 } from "contracts/libraries/external/ERC165.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IGaugeManager } from "contracts/interfaces/IGaugeManager.sol";
import { ClaimAction } from "contracts/interfaces/IRewardManager.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { ICVE } from "contracts/interfaces/ICVE.sol";
import { IVeCVE } from "contracts/interfaces/IVeCVE.sol";

/// @dev KNOWN ISSUE - REWARD CALCULATION ROUNDING:
///      Integer division in reward distribution causes small rounding differences.
///      Example: User with 400 tokens out of 900 total should get 400/900 * 30000 = 13333.33
///      tokens, but receives either 13333 or 13334 due to truncation. Over multiple periods,
///      expected 40784 but actual 40785 (accumulated +1 rounding errors). These differences
///      can lead to unfair distribution over time. Future iterations should implement
///      improved precision handling or alternative distribution mechanisms.
///

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
///      parties.
///
///      Gauge rewards distribute rewards to collateral depositors,
///      or lenders, in a market.
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
contract GaugeManager is
    PluginDelegable,
    ERC165,
    ReentrancyGuard,
    IGaugeManager
{
    /// TYPES ///

    /// @title Epoch Information
    /// @notice Manages and tracks epoch information, including their
    ///         total weights and token weights.
    /// @param totalWeights The total weight value of all tokens, inside
    ///                     the pool, for this epoch.
    /// @param tokenWeight The weight value of a token, inside the pool,
    ///                    for this epoch.
    /// @dev token => pool weight value.
    struct Epoch {
        uint256 totalWeights;
        mapping(address => uint256) tokenWeight;
    }

    /// @notice Stores user-specific reward tracking information.
    /// @param rewardDebt The user's share of previously distributed
    ///                     rewards, used for fair reward calculation.
    /// @param rewardPending The amount of rewards the user has
    ///                     accumulated but has not yet claimed.
    struct UserRewardInfo {
        uint256 rewardDebt;
        uint256 rewardPending;
    }
    /// CONSTANTS ///

    /// @notice The length of one protocol epoch, in seconds.
    uint256 public immutable EPOCH_DURATION;

    /// @dev `bytes4(keccak256(bytes("GaugeManager__Unauthorized()")))`.
    uint256 internal constant _UNAUTHORIZED_SELECTOR = 0x38b10c24;

    /// STORAGE ///

    /// @notice Start time that gauge controller starts, in unix time.
    uint256 internal _startTime;

    /// @notice Gauge emission values for the entire Gauge Manager,
    ///         and contained tokens, by epoch.
    /// @dev Epoch Number => Epoch information.
    mapping(uint256 => Epoch) internal _epochInfo;

    /// @dev mToken => rewardToken => last epoch.
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
    /// @notice mToken => accRewardPerShare.
    mapping(address => uint256) public poolAccRewardPerShare;
    /// @notice Information corresponding to rewards pending/debt pending
    ///         for a particular user, for a particular deposited token.
    /// @dev mToken => user => info.
    mapping(address => mapping(address => UserRewardInfo)) public userDebtInfo;
    /// @notice The amount of rewards streamed per second
    /// during an epoch, for a specific token.
    /// @dev mToken => epoch => rewardPerSec.
    mapping(address => mapping(uint256 => uint256))
        internal _epochRewardPerSec;

    /// ERRORS ///

    error GaugeManager__Unauthorized();
    error GaugeManager__NotStarted();
    error GaugeManager__InvalidEpoch();
    error GaugeManager__InvalidLength();
    error GaugeManager__InvalidToken();
    error GaugeManager__InvalidAmount();
    error GaugeManager__NoReward();

    /// EVENTS ///

    event SetMinDistributionAmount(address newReward, uint256 amount);
    event GaugeWeightsSet(uint256 epoch, address[] tokens, uint256[] weights);
    event AddExtraRewardToken(address newReward);
    event RemoveExtraRewardToken(address newReward);
    event Deposit(address user, address token, uint256 amount);
    event Withdraw(address user, address token, uint256 amount);
    event Claim(address user, address token);

    /// CONSTRUCTOR ///

    constructor(ICentralRegistry cr) PluginDelegable(cr) {
        // Query epoch and token configuration directly to minimize potential
        // human error.
        EPOCH_DURATION = centralRegistry.EPOCH_DURATION();
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Sets emission rates of tokens of current epoch.
    /// @dev Only the Messaging Hub and Voting Hub can call this.
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

        // Cache Gauge System start time.
        uint256 _gaugeStartTime = gaugeStartTime();

        // Validate that Gauge system is fully active and only the current
        // epoch can have emissions set.
        if (
            !(epoch == 0 && block.timestamp < _gaugeStartTime) &&
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
            } else {
                poolUpdated = false;
            }

            info.totalWeights = info.totalWeights + weights[i];
            info.tokenWeight[token] = info.tokenWeight[token] + weights[i];

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

    /// @notice Returns gauge weight of given epoch and token.
    /// @param epoch The epoch to pull weights for.
    /// @param token The address of the gauge token to query weights for.
    /// @return tuple containing total weights and token weight.
    function gaugeWeight(
        uint256 epoch,
        address token
    ) external view returns (uint256, uint256) {
        return (
            _epochInfo[epoch].totalWeights,
            _epochInfo[epoch].tokenWeight[token]
        );
    }

    /// @notice Returns pending reward of user for their deposited `tokens`
    /// @param tokens Array of Protocol supported mToken addresses to check
    ///               rewards for.
    /// @param user User address to query pending rewards for.
    /// @return rewardAmounts Array of pending rewards for each token.
    function pendingRewards(
        address[] calldata tokens,
        address user
    ) external view returns (uint256[] memory rewardAmounts) {
        uint256 numMTokens = tokens.length;
        rewardAmounts = new uint256[](numMTokens);

        for (uint256 i; i < numMTokens; ++i) {
            rewardAmounts[i] = pendingRewards(tokens[i], user);
        }
    }

    /// @notice Registers an `amount` deposit of `token` for `user` inside
    ///         the Gauge System.
    /// @dev This does not actually include any token transfers as tokens
    ///      are permissionlessly escrowed by pToken/eToken contracts and
    ///      we simply record deposits/withdraws as virtual balances here.
    /// @param token Protocol supported mToken address to deposit for `user`.
    /// @param user User address to deposit `amount` of `token` for.
    /// @param amount The amount of `token` to deposit.
    function deposit(
        address token,
        address user,
        uint256 amount
    ) external nonReentrant {
        _validateAndUpdatePool(token, user, amount);

        balanceOf[token][user] += amount;
        totalSupply[token] += amount;

        _calcDebt(user, token);

        emit Deposit(user, token, amount);
    }

    /// @notice Registers an `amount` withdrawal of `token` for `user` from
    ///         the Gauge System.
    /// @dev This does not actually include any token transfers as tokens
    ///      are permissionlessly escrowed by pToken/eToken contracts and
    ///      we simply record deposits/withdraws as virtual balances here.
    /// @param token Protocol supported mToken address to withdraw from
    ///              `user`'s virtual balance.
    /// @param user User address to withdraw `amount` of `token` from.
    /// @param amount The amount of `token` to withdraw.
    function withdraw(
        address token,
        address user,
        uint256 amount
    ) external nonReentrant {
        _validateAndUpdatePool(token, user, amount);

        if (balanceOf[token][user] < amount) {
            revert GaugeManager__InvalidAmount();
        }

        balanceOf[token][user] -= amount;
        totalSupply[token] -= amount;

        _calcDebt(user, token);

        emit Withdraw(user, token, amount);
    }

    /// @notice Registers an `amount` deposit of `token` for `user` inside
    ///         the Gauge System.
    /// @dev This does not actually include any token transfers as tokens
    ///      are permissionlessly escrowed by pToken/eToken contracts and
    ///      we simply record deposits/withdraws as virtual balances here.
    /// @param token Protocol supported mToken address to withdraw for
    ///              `user`.
    /// @param user Address to withdraw `amount` of `token` for, on
    ///             liquidation.
    /// @param liquidator Address to deposit `amount` of `token` for, on
    ///                   liquidation.
    /// @param amount The amount of `token` to move from `user` and
    ///               `liquidator` on liquidation.
    function processLiquidation(
        address token,
        address user,
        address liquidator,
        uint256 amount
    ) external nonReentrant {
        // This also calculates pending rewards for `user` which is why
        // its missing from code below.
        _validateAndUpdatePool(token, user, amount);

        balanceOf[token][user] -= amount;
        // `totalSupply` does not need to be updated since we call updatePool
        // prior to balance shift which is the only value that uses
        // `totalSupply` and by the end of the liquidation balance shift
        // totalSupply ends up being the same as before, allowing us to avoid
        // two storage loads.

        _calcDebt(user, token);

        emit Withdraw(user, token, amount);

        _calcPending(liquidator, token);
        balanceOf[token][liquidator] += amount;
        _calcDebt(liquidator, token);

        emit Deposit(liquidator, token, amount);
    }

    /// @notice Claim all pending rewards for `tokens` from the Gauge Manager.
    /// @param tokens Array containing pool token addresses to claim
    ///               rewards for.
    /// @param user The user address that gauge rewards should be claimed for,
    ///             if `user` is not the caller, plugin delegation status is
    ///             checked.
    function claim(
        address[] calldata tokens,
        address user
    ) external nonReentrant {
        _checkGaugeHasStarted();

        if (user != msg.sender) {
            _checkDelegate(user, msg.sender);
        }

        uint256 cveRewards = _claimRewards(tokens, user);

        if (cveRewards == 0) {
            return;
        }

        SafeTransferLib.safeTransfer(_getCVE(), msg.sender, cveRewards);
    }

    /// @notice Claim rewards from Gauge Manager and compound any CVE rewards
    ///         into a new or existing veCVE lock.
    /// @dev Users who choose to lock emissions may potentially receive an
    ///      emission boost based on `lockBoostMultiplier` stored inside the
    ///      DAO Central Registry.
    /// @param tokens Array containing pool token addresses to claim rewards for.
    /// @param isNewLock True if creating a new lock, false if extending existing.
    /// @param lockIndex The index of the lock to extend (ignored if isNewLock is true).
    /// @param continuousLock Whether the lock should be continuous or not.
    /// @param action Rewards data for desired Reward Manager action.
    /// @param params Parameters for rewards claim function.
    /// @param aux Auxiliary data.
    function claimAndLock(
        address[] calldata tokens,
        bool isNewLock,
        bool continuousLock,
        uint256 lockIndex,
        ClaimAction memory action,
        bytes calldata params,
        uint256 aux
    ) external nonReentrant {
        _checkGaugeHasStarted();

        uint256 cveRewards = _claimRewards(tokens, msg.sender);

        if (cveRewards == 0) {
            revert GaugeManager__NoReward();
        }

        address cve = _getCVE();
        IVeCVE veCVE = _getVeCVE();
        uint256 currentLockBoost = centralRegistry.lockBoostMultiplier();

        // If theres a current lock boost, recognize their bonus rewards.
        if (currentLockBoost > 0) {
            uint256 boostedRewards = (cveRewards * currentLockBoost) / BPS;
            // We know this will never underflow due to `currentLockBoost`
            // needing to be greater than 1.
            ICVE(cve).mintLockBoost(boostedRewards - cveRewards);
            cveRewards = boostedRewards;
        }

        // Approve veCVE to take necessary cve to extend/create the lock.
        SafeTransferLib.safeApprove(cve, address(veCVE), cveRewards);

        if (isNewLock) {
            veCVE.createLockFor(
                msg.sender,
                cveRewards,
                continuousLock,
                action,
                params,
                aux
            );
        } else {
            veCVE.increaseAmountAndExtendLockFor(
                msg.sender,
                cveRewards,
                lockIndex,
                continuousLock,
                action,
                params,
                aux
            );
        }
    }

    /// @notice Locks in `startTime` once the gauge system has formally started
    ///         and `genesisEpoch` cannot change.
    /// @dev Purpose of this function is to reduce startTime computation cost
    ///      once we know its locked in and can directly query `startTime`.
    function lockInStartTime() external {
        if (!centralRegistry.hasDaoPermissions(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        uint256 genesisEpoch = _genesisEpoch();

        // If the gauge system has not started yet, `startTime`
        // cannot be locked in.
        if (block.timestamp < genesisEpoch) {
            revert GaugeManager__NotStarted();
        }

        // If its currently during the genesis epoch, epochOfTimestamp will
        // round down by dividing then multiplying by `EPOCH_DURATION`, setting
        // startTime equal to `genesisEpoch` otherwise,
        // it will append on additional epochs if this is a fresh chain
        // deployment starting after the genesis epoch.
        _startTime =
            genesisEpoch +
            (((block.timestamp - genesisEpoch) / EPOCH_DURATION) *
                EPOCH_DURATION);
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Returns current epoch number.
    /// @return The current epoch number.
    function currentEpoch() public view returns (uint256) {
        return epochOfTimestamp(block.timestamp);
    }

    /// @notice Returns epoch number of `timestamp`.
    /// @param timestamp Timestamp in seconds.
    /// @return The epoch number of the timestamp.
    function epochOfTimestamp(
        uint256 timestamp
    ) public view returns (uint256) {
        _checkGaugeHasStarted();
        uint256 cachedGenesisEpoch = _genesisEpoch();

        // Rounds down intentionally.
        return
            timestamp < cachedGenesisEpoch
                ? 0
                : (timestamp - cachedGenesisEpoch) / EPOCH_DURATION;
    }

    /// @notice Returns the timestamp of when the gauge system begins.
    /// @return The calculated gauge start timestamp.
    function gaugeStartTime() public view returns (uint256) {
        if (_startTime != 0) {
            return _startTime;
        }

        uint256 genesisEpoch = _genesisEpoch();

        // If the gauge system has not started yet, the gauge start time
        // is the Genesis Epoch itself.
        if (block.timestamp < genesisEpoch) {
            return genesisEpoch;
        }

        // If its currently during the genesis epoch, epochOfTimestamp will
        // round down by dividing then multiplying by `EPOCH_DURATION`, setting
        // startTime equal to `genesisEpoch` otherwise,
        // it will append on additional epochs if this is a fresh chain
        // deployment starting after the genesis epoch.
        return
            genesisEpoch +
            (((block.timestamp - genesisEpoch) / EPOCH_DURATION) *
                EPOCH_DURATION);
    }

    /// @notice Returns start time of `epoch`.
    /// @param epoch Epoch number to return start time for.
    /// @return The start time of the epoch.
    function epochStartTime(uint256 epoch) public view returns (uint256) {
        _checkGaugeHasStarted();
        return _genesisEpoch() + (epoch * EPOCH_DURATION);
    }

    /// @notice Returns end time of `epoch`.
    /// @param epoch Epoch number to return end time for.
    /// @return The end time of the epoch.
    function epochEndTime(uint256 epoch) public view returns (uint256) {
        _checkGaugeHasStarted();
        return _genesisEpoch() + ((epoch + 1) * EPOCH_DURATION);
    }

    /// @notice Returns if given gauge token is enabled in `epoch`.
    /// @param epoch Epoch number to check for gauge activity.
    /// @param token Gauge token address.
    /// @return True if the gauge token is enabled in the epoch, false otherwise.
    function isGaugeEnabled(
        uint256 epoch,
        address token
    ) public view returns (bool) {
        return _epochInfo[epoch].tokenWeight[token] > 0;
    }

    /// @notice Returns CVE emissions of `token`.
    /// @param token Pool token address that receives CVE overtime.
    /// @param epoch The epoch number to check CVE allocation for.
    /// @return The CVE emissions of the token in the epoch.
    function rewardAllocation(
        address token,
        uint256 epoch
    ) public view returns (uint256) {
        return _epochInfo[epoch].tokenWeight[token];
    }

    /// @notice Returns pending reward of user for their deposited `token`
    /// @param token Protocol supported mToken address to check rewards for.
    /// @param user User address to query pending rewards for.
    /// @return The pending reward of the user for the token.
    function pendingRewards(
        address token,
        address user
    ) public view returns (uint256) {
        // Cache storage values.
        uint256 accRewardPerShare = poolAccRewardPerShare[token];
        uint256 lastRewardTimestamp = poolLastRewardTimestamp[token];
        uint256 totalDeposited = totalSupply[token];
        if (lastRewardTimestamp == 0) {
            lastRewardTimestamp = gaugeStartTime();
        }

        if (block.timestamp > lastRewardTimestamp && totalDeposited != 0) {
            accRewardPerShare = _calcAccRewardPerShare(
                token,
                accRewardPerShare,
                lastRewardTimestamp,
                totalDeposited
            );
        }

        UserRewardInfo memory info = userDebtInfo[token][user];
        return
            info.rewardPending +
            (balanceOf[token][user] * accRewardPerShare) /
            RAY -
            info.rewardDebt;
    }

    /// @notice Update reward variables for `token` to be up to date as
    ///         of the current block timestamp.
    /// @param token Pool token address.
    function updatePool(address token) public {
        {
            // Scope variable to avoid stack too deep error.
            // Cache Gauge System start time.
            uint256 _gaugeStartTime = gaugeStartTime();
            // If rewards have not started yet, there is nothing to update.
            if (block.timestamp < _gaugeStartTime) {
                return;
            }
        }

        uint256 lastRewardTimestamp = poolLastRewardTimestamp[token];
        // If nobody has updated reward timestamp, set it to current timestamp.
        if (lastRewardTimestamp == 0) {
            poolLastRewardTimestamp[token] = block.timestamp;
            return;
        }

        // Make sure time has passed since the last update.
        if (block.timestamp <= lastRewardTimestamp) {
            return;
        }

        // Is there are no deposits, there is nothing to update.
        uint256 totalDeposited = totalSupply[token];
        if (totalDeposited == 0) {
            return;
        }

        uint256 accRewardPerShare = poolAccRewardPerShare[token];

        poolAccRewardPerShare[token] = _calcAccRewardPerShare(
            token,
            accRewardPerShare,
            lastRewardTimestamp,
            totalDeposited
        );

        // Update pool storage.
        poolLastRewardTimestamp[token] = block.timestamp;
    }

    /// @inheritdoc ERC165
    /// @return True if the interface is supported, false otherwise.
    function supportsInterface(
        bytes4 interfaceId
    ) public view override returns (bool) {
        return
            interfaceId == type(IGaugeManager).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Calculates accumulated rewards per share across multiple epochs.
    /// @param token Protocol supported mToken address to check rewards for.
    /// @param accRewardPerShare Current accumulated reward per share.
    /// @param lastRewardTimestamp Timestamp when rewards were last calculated.
    /// @param totalDeposited Total amount of token deposited in the pool.
    /// @return Updated accumulated reward per share value.
    function _calcAccRewardPerShare(
        address token,
        uint256 accRewardPerShare,
        uint256 lastRewardTimestamp,
        uint256 totalDeposited
    ) internal view returns (uint256) {
        uint256 lastEpoch = epochOfTimestamp(lastRewardTimestamp);
        uint256 cachedCurrentEpoch = currentEpoch();
        uint256 reward;

        // Step through epochs and apply rewards.
        while (lastEpoch < cachedCurrentEpoch) {
            uint256 endTimestamp = epochEndTime(lastEpoch);

            // update rewards from lastRewardTimestamp to endTimestamp.
            reward =
                (RAY *
                    (endTimestamp - lastRewardTimestamp) *
                    rewardAllocation(token, lastEpoch)) /
                EPOCH_DURATION;
            accRewardPerShare = accRewardPerShare + (reward / totalDeposited);

            ++lastEpoch;
            lastRewardTimestamp = endTimestamp;
        }

        // update rewards from lastRewardTimestamp to current timestamp.
        reward =
            (RAY *
                (block.timestamp - lastRewardTimestamp) *
                rewardAllocation(token, lastEpoch)) /
            EPOCH_DURATION;

        return accRewardPerShare + reward / totalDeposited;
    }

    /// @notice Claim all pending rewards for `tokens` from the Gauge Manager.
    /// @param tokens Array containing pool token addresses to claim
    ///               rewards for.
    /// @param user The user address that gauge rewards should be claimed for.
    /// @return cveRewards The total amount of CVE token rewards claimed across all specified tokens.
    function _claimRewards(
        address[] calldata tokens,
        address user
    ) internal returns (uint256) {
        uint256 cveRewards;
        uint256 numTokens = tokens.length;
        for (uint256 i; i < numTokens; ) {
            cveRewards += _claim(tokens[i++], user);
        }

        return cveRewards;
    }

    /// @notice Claim pending rewards for `token` from the Gauge Manager.
    /// @param token Pool token address to claim rewards for.
    /// @param user The user address that gauge rewards should be claimed for.
    /// @return cveRewards The amount of CVE token rewards claimed for the specified token.
    function _claim(
        address token,
        address user
    ) internal returns (uint256 cveRewards) {
        updatePool(token);
        _calcPending(user, token);

        cveRewards = userDebtInfo[token][user].rewardPending;

        // Update pending rewards to zero.
        userDebtInfo[token][user].rewardPending = 0;
        _calcDebt(user, token);

        emit Claim(user, token);
    }

    /// @notice Returns the genesis epoch timestamp.
    /// @return The genesis epoch timestamp.
    function _genesisEpoch() internal view returns (uint256) {
        return centralRegistry.genesisEpoch();
    }

    /// @notice Returns the current CVE address.
    /// @return The current CVE address.
    function _getCVE() internal view returns (address) {
        return centralRegistry.cve();
    }

    /// @notice Returns the current VeCVE address to call.
    /// @return The current VeCVE contract.
    function _getVeCVE() internal view returns (IVeCVE) {
        return IVeCVE(centralRegistry.veCVE());
    }

    /// @dev Checks whether the gauge controller has started or not.
    function _checkGaugeHasStarted() internal view {
        if (block.timestamp < gaugeStartTime()) {
            revert GaugeManager__NotStarted();
        }
    }

    /// @param token Protocol supported mToken address.
    /// @param user User address to calculate pending rewards.
    /// @param amount The amount of `token`.
    function _validateAndUpdatePool(
        address token,
        address user,
        uint256 amount
    ) internal {
        if (amount == 0) {
            revert GaugeManager__InvalidAmount();
        }

        // Make sure the token is listed inside this market,
        // and that the token is executing the deposit call.
        IMarketManager marketManager = ICToken(token).marketManager();
        if (
            msg.sender != token ||
            !marketManager.isListed(token) ||
            !centralRegistry.isMarketManager(address(marketManager))
        ) {
            revert GaugeManager__InvalidToken();
        }

        updatePool(token);
        _calcPending(user, token);
    }

    /// @notice Calculate user's pending rewards.
    /// @param user User address.
    /// @param token Pool token address.
    function _calcPending(address user, address token) internal {
        UserRewardInfo storage info = userDebtInfo[token][user];
        info.rewardPending +=
            (balanceOf[token][user] * poolAccRewardPerShare[token]) /
            RAY -
            info.rewardDebt;
    }

    /// @notice Calculate user's debt amount for reward calculation.
    /// @param user User address.
    /// @param token Pool token address.
    function _calcDebt(address user, address token) internal {
        UserRewardInfo storage info = userDebtInfo[token][user];
        info.rewardDebt =
            (balanceOf[token][user] * poolAccRewardPerShare[token]) /
            RAY;
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
