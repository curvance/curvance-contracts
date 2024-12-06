//SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";
import { WAD } from "contracts/libraries/Constants.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { ReentrancyGuard } from "contracts/libraries/external/ReentrancyGuard.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IVeCVE } from "contracts/interfaces/IVeCVE.sol";
import { RewardsData } from "contracts/interfaces/IRewardManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @title Curvance Reward Manager.
/// @notice A system for managing rewards within the Curvance Protocol.
/// @dev The RewardManager acts a unified interface for distributing rewards to
///      Curvance DAO users. This system works in collaboration with the VeCVE
///      smart contract. Rewards are distributed biweekly and pile up for each
///      user, allowing them to claim rewards whenever they want. Rewards can
///      be routed directly into other tokens. CVE can be directly routed to,
///      other tokens can be routed into through the delegation system.
///
///      Rewards are distributed pro-rata to each chain's Reward Manager every
///      two weeks. Fees are moved to some unified chain (can change) along
///      with information corresponding to the number of veCVE locked on a
///      chain. This means, for example, if 10 million reward tokens are to
///      be distributed during an epoch that had 100 million veCVE locked,
///      every user would receive 0.1 reward tokens for each veCVE they had
///      locked during that period. This creates a direct incentive for chains
///      to provide exogenous rewards to Curvance DAO users to move their
///      locks over to their chain, increases the rewards to be distributed
///      on that chain.
///
///      Currently rewards/fees are distributed as USDC and are moved through
///      either Circle's CCTP or Wormhole's automatic relayer, other solutions
///      may also be integrated to facilitate a wider range of chain support.
///      Such as routing a distributed reward token into a chain specific
///      stablecoin after a Wormhole message is delivered.
///
contract RewardManager is PluginDelegable, ReentrancyGuard {
    /// CONSTANTS ///

    /// @notice Reward Manager Reward token.
    address public immutable rewardToken;
    /// @notice The length of one protocol epoch, in seconds.
    uint256 public immutable epochDuration;

    /// @dev `bytes4(keccak256(bytes("RewardManager__Unauthorized()")))`.
    uint256 internal constant _UNAUTHORIZED_SELECTOR = 0xd55eef72;
    /// @dev `bytes4(keccak256(bytes("RewardManager__NoEpochRewards()")))`.
    uint256 internal constant _NO_EPOCH_REWARDS_SELECTOR = 0x0a2e9ede;
    uint256 internal constant _EPOCH_REWARDS_OVERRIDE_BUFFER = 1 hours;

    /// STORAGE ///

    /// @notice The address of the veCVE contract.
    IVeCVE public veCVE;
    /// @notice Whether the Reward Manager has been started or not.
    /// @dev 2 = yes; 1 = no.
    uint256 public rewardManagerStarted = 1;
    /// @notice Whether the Reward Manager is shut down or not.
    /// @dev 2 = yes; 1 = no.
    uint256 public isShutdown = 1;

    /// @notice The next undelivered epoch index.
    /// @dev Records the last epoch rewards delivered + 1, this can lag behind
    ///      if crosschain systems are strained. This will result in all lock
    ///      state changes being blocked until the system catches up.
    uint256 public nextEpochToDeliver;

    /// @notice The next epoch index to claim for a user.
    /// @dev User => Reward Next Claim Index.
    mapping(address => uint256) public userNextClaimIndex;

    /// @notice The rewards alloted to 1 vote escrowed CVE point for an epoch,
    ///         in `WAD`.
    /// @dev Epoch # => Rewards per veCVE.
    mapping(uint256 => uint256) public epochRewardsPerPoint;

    /// EVENTS ///

    event RewardPaid(address user, address rewardToken, uint256 amount);
    event EpochRewardsSet(
        uint256 epochDelivered,
        uint256 rewardsPerPoint,
        uint256 rewardAmount
    );

    /// ERRORS ///

    error RewardManager__RewardTokenIsZeroAddress();
    error RewardManager__SwapDataIsInvalid();
    error RewardManager__Unauthorized();
    error RewardManager__NoEpochRewards();
    error RewardManager__RewardManagerIsAlreadyStarted();
    error RewardManager__EpochDeliveryOverrideUnavailable();

    receive() external payable {}

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address rewardToken_
    ) PluginDelegable(centralRegistry_) {
        if (rewardToken_ == address(0)) {
            revert RewardManager__RewardTokenIsZeroAddress();
        }

        // Query epoch and token configuration directly to minimize potential
        // human error.
        epochDuration = centralRegistry.EPOCH_DURATION();

        rewardToken = rewardToken_;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Permissioned function for overriding an epoch rewards incase
    ///         the crosschain message can not be delivered for some reason
    ///         by the Messaging Hub.
    /// @dev Only callable on by an entity with DAO permissions or higher,
    ///      once the time buffer has passed without rewards being delivered
    ///      properly.
    function overrideRecordEpochRewards() external {
        _checkDaoPermissions();

        // Cache next epoch to deliver value to save on storage reads.
        uint256 epoch = nextEpochToDeliver;

        uint256 nextEpochToDeliverStartTime = epoch == 0 ?
            centralRegistry.genesisEpoch() :
            centralRegistry.genesisEpoch() + (epoch * epochDuration);

        // Add the time buffer required for overriding an epoch's reward
        // value.
        nextEpochToDeliverStartTime += _EPOCH_REWARDS_OVERRIDE_BUFFER;

        // Check that time buffer for overriding has passed.
        if (block.timestamp < nextEpochToDeliverStartTime) {
            revert RewardManager__EpochDeliveryOverrideUnavailable();
        }

        // We can skip updating `epochRewardsPerPoint` as uint256 values
        // default to a value of 0 already, so we can just emit the
        // expected event and increment the `nextEpochToDeliver` invariant.

        emit EpochRewardsSet(
            nextEpochToDeliver++,
            0,
            0
        );
    }

    /// @notice Called by the Messaging Hub to record rewards allocated to
    ///         an epoch.
    /// @dev Only callable on by the Messaging Hub.
    /// @param rewardsPerPoint The rewards allocated to 1 veCVE point for
    ///                        the next reward epoch delivered, in WAD.
    function recordEpochRewards(uint256 rewardsPerPoint) external {
        // Validate the caller reporting epoch data is the messaging hub,
        // or messaging hub.
        if (msg.sender != centralRegistry.messagingHub()) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        // Cache next epoch to deliver value to save on storage reads.
        uint256 epoch = nextEpochToDeliver;

        if (veCVE.chainUnlocksByEpoch(epoch) > 0) {
            // If the chain has tokens unlocking this epoch we need to
            // decrease chainPoints.
            veCVE.updateChainPoints(epoch);
        }

        // Record rewards per token for the epoch.
        epochRewardsPerPoint[epoch] = rewardsPerPoint;

        // Emit an event indicating rewards were set, then update
        // `nextEpochToDeliver` invariant.
        emit EpochRewardsSet(
            nextEpochToDeliver++,
            rewardsPerPoint,
            rewardsPerPoint * veCVE.chainPoints()
        );
    }

    /// @notice Starts the Reward Manager, called by the DAO after setting up
    ///         both RewardManager and veCVE contracts.
    /// @dev Only callable on by an entity with DAO permissions or higher.
    function startRewardManager() external {
        _checkDaoPermissions();

        if (rewardManagerStarted == 2) {
            revert RewardManager__RewardManagerIsAlreadyStarted();
        }

        veCVE = IVeCVE(centralRegistry.veCVE());
        nextEpochToDeliver = veCVE.currentEpoch(block.timestamp);
        rewardManagerStarted = 2;
    }

    /// @notice Rescue any token sent by mistake.
    /// @param token token to rescue.
    /// @param amount amount of `token` to rescue, 0 indicates to rescue all.
    function rescueToken(address token, uint256 amount) external {
        _checkDaoPermissions();
        address daoOperator = centralRegistry.daoAddress();

        if (token == address(0)) {
            if (amount == 0) {
                amount = address(this).balance;
            }

            SafeTransferLib.safeTransferETH(daoOperator, amount);
        } else {
            if (token == rewardToken) {
                _revert(_UNAUTHORIZED_SELECTOR);
            }

            if (amount == 0) {
                amount = IERC20(token).balanceOf(address(this));
            }

            SafeTransferLib.safeTransfer(token, daoOperator, amount);
        }
    }

    /// @notice Shuts down the RewardManager and prevents future reward
    /// distributions.
    /// @dev Should only be used to facilitate migration to a new system.
    function notifyShutdown() external {
        if (
            msg.sender != address(veCVE) &&
            !centralRegistry.hasElevatedPermissions(msg.sender)
        ) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        isShutdown = 2;
    }

    /// @notice Returns the current epoch for the given time.
    /// @param time The timestamp for which to calculate the epoch.
    /// @return The current epoch.
    function currentEpoch(uint256 time) external view returns (uint256) {
        uint256 genesisEpoch = _genesisEpoch();

        if (time < genesisEpoch) {
            return 0;
        }

        return ((time - genesisEpoch) / epochDuration);
    }

    /// @notice Checks if a user has any rewards to claim.
    /// @dev Even if a users lock is expiring the next lock resulting
    ///      in 0 points, we want their data updated so data is properly
    ///      adjusted on unlock.
    /// @param user The address of the user to check for reward claims.
    /// @return A boolean value indicating if the user has any rewards
    ///         to claim.
    function hasRewardsToClaim(address user) external view returns (bool) {
        if (
            nextEpochToDeliver > userNextClaimIndex[user] &&
            veCVE.userPoints(user) > 0
        ) {
            return true;
        }

        return false;
    }

    /// @notice Calculates a hypothetical rewards claim by `user`.
    ///         Returns 0 if there are no rewards to claim.
    /// @param user The user who should have their hypothetical rewards
    ///             calculated.
    /// @return The amount of `rewardToken` that `user` would receive if they
    ///         tried claiming their rewards right now.
    function hypotheticalRewardsClaim(
        address user
    ) external view returns (uint256) {
        uint256 epochs = epochsToClaim(user);
        if (epochs == 0) {
            return 0;
        }

        uint256 startEpoch = userNextClaimIndex[user];
        uint256 startPoints = veCVE.userPoints(user);
        uint256 rewards;
        uint256 pointsOffset;

        for (uint256 i; i < epochs; ++i) {
            pointsOffset = veCVE.userUnlocksByEpoch(user, startEpoch + i);
            // If they have tokens unlocking this epoch we need to offset
            // their cached points.
            if (pointsOffset > 0) {
                // Offset points by how many points would unlock this epoch.
                startPoints -= pointsOffset;
            }

            // If all points have unlocked we can stop early.
            if (startPoints == 0) {
                break;
            }

            // Increment points for this epoch.
            // Rewards for Epoch = (User Points * Reward Per Point) / WAD Precision
            rewards += FixedPointMathLib.fullMulDiv(
                startPoints,
                epochRewardsPerPoint[startEpoch + i],
                WAD
            );
        }

        // Removes the `WAD` precision offset for proper reward value.
        return rewards / WAD;
    }

    /// CLAIM INDEX FUNCTIONS ///

    /// @notice Updates `user`'s claim index.
    /// @dev Updates the claim index of a user.
    ///      Can only be called by the VeCVE contract.
    /// @param user The address of the user.
    /// @param index The new claim index.
    function updateUserClaimIndex(address user, uint256 index) external {
        _checkIsVeCVE();
        userNextClaimIndex[user] = index;
    }

    /// @notice Resets `user`'s claim index.
    /// @dev Deletes the claim index of a user.
    ///      Can only be called by the VeCVE contract.
    /// @param user The address of the user.
    function resetUserClaimIndex(address user) external {
        _checkIsVeCVE();
        delete userNextClaimIndex[user];
    }

    /// REWARD FUNCTIONS ///

    /// @notice Claims rewards for multiple epochs.
    /// @param rewardsData Rewards data for desired Reward Manager action.
    /// @param params Swap data for token swapping rewards to
    ///               desiredRewardToken.
    /// @param aux Auxiliary data for wrapped assets such as veCVE.
    function claimRewards(
        RewardsData calldata rewardsData,
        bytes calldata params,
        uint256 aux
    ) external nonReentrant {
        uint256 epochs = epochsToClaim(msg.sender);

        // If there are no epoch rewards to claim, revert.
        assembly {
            if iszero(epochs) {
                mstore(0x00, _NO_EPOCH_REWARDS_SELECTOR)
                // Return bytes 29-32 for the selector.
                revert(0x1c, 0x04)
            }
        }

        _claimRewards(
            msg.sender,
            msg.sender,
            epochs,
            rewardsData,
            params,
            aux
        );
    }

    /// @notice Claims rewards for multiple epochs.
    /// @param user The address of the user claiming rewards.
    /// @param epochs The number of epochs for which to claim rewards.
    /// @param rewardsData Rewards data for desired Reward Manager action.
    /// @param params Swap data for token swapping rewards to cve,
    ///               if necessary.
    /// @param aux Auxiliary data for veCVE.
    function claimRewardsFor(
        address user,
        uint256 epochs,
        RewardsData calldata rewardsData,
        bytes calldata params,
        uint256 aux
    ) external nonReentrant {
        _checkIsVeCVE();

        // We check whether there are epochs to claim in veCVE
        // so we do not need to check here like in claimRewards.
        _claimRewards(user, user, epochs, rewardsData, params, aux);
    }

    /// @notice Manages rewards for `user`, used at the beginning
    ///         of some external strategy for `user`.
    /// @dev Be extremely careful giving this authority to anyone, the
    ///      intention is to allow delegate claim functionality to hot wallets
    ///      or strategies that make sure of rewards directly without
    ///      distributing rewards to a user directly.
    ///      Emits a {ClaimApproval} event.
    /// @param user The address of the user having rewards managed.
    /// @return How much rewards were claimed for `user` from the
    ///         Reward Manager.
    function manageRewardsFor(
        address user
    ) external nonReentrant returns (uint256) {
        if (!isDelegate(user, msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        uint256 epochs = epochsToClaim(user);

        // If there are no epoch rewards to claim, revert.
        assembly {
            if iszero(epochs) {
                mstore(0x00, _NO_EPOCH_REWARDS_SELECTOR)
                // Return bytes 29-32 for the selector.
                revert(0x1c, 0x04)
            }
        }

        // We check whether there are epochs to claim in reward manager
        // modules so we do not need to check here like in claimRewards.
        return _claimRewardsDirect(user, epochs);
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Checks if a user has any rewards to claim.
    /// @dev Even if a users lock is expiring the next lock resulting
    ///      in 0 points, we want their data updated so data is properly
    ///      adjusted on unlock.
    /// @param user The address of the user to check for reward claims.
    /// @return A value indicating if the user has any rewards to claim.
    function epochsToClaim(address user) public view returns (uint256) {
        if (nextEpochToDeliver > userNextClaimIndex[user]) {
            unchecked {
                return nextEpochToDeliver - (userNextClaimIndex[user]);
            }
        }

        return 0;
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Claims rewards for multiple epochs.
    /// @dev May emit a {RewardPaid} event.
    /// @param user The address of the user claiming rewards.
    /// @param recipient The address receiving rewards.
    /// @param epochs The number of epochs for which to claim rewards.
    /// @param rewardsData Rewards data for desired Reward Manager action.
    /// @param params Swap data for token swapping rewards to cve,
    ///               if necessary.
    /// @param aux Auxiliary data for veCVE.
    function _claimRewards(
        address user,
        address recipient,
        uint256 epochs,
        RewardsData calldata rewardsData,
        bytes calldata params,
        uint256 aux
    ) internal {
        uint256 rewards = _calculateRewards(user, epochs);

        // Process rewards and bubble up the amount of rewards received in
        // `rewardsData.desiredRewardToken`.
        uint256 rewardAmount = _processRewards(
            recipient,
            rewards,
            rewardsData,
            params,
            aux
        );

        // Only emit an event if they actually had rewards,
        // do not wanna revert to maintain composability.
        if (rewardAmount > 0) {
            emit RewardPaid(
                user,
                rewardsData.asCVE ? _getCVE() : rewardToken,
                rewardAmount
            );
        }
    }

    /// @notice Claims rewards for `epochs` directly without rewards
    ///         adjustment checks for `user`.
    /// @dev May emit a {RewardPaid} event.
    /// @param user The address of the user claiming rewards.
    /// @param epochs The number of epochs for which to claim rewards.
    /// @return rewards How much rewards were claimed for `user` from the
    ///                 Reward Manager.
    function _claimRewardsDirect(
        address user,
        uint256 epochs
    ) internal returns (uint256 rewards) {
        rewards = _calculateRewards(user, epochs);

        // Only emit an event if they actually had rewards,
        // do not wanna revert to maintain composability.
        if (rewards > 0) {
            // Transfer rewards directly to reward manager for strategy
            // execution.
            SafeTransferLib.safeTransfer(rewardToken, msg.sender, rewards);

            emit RewardPaid(user, rewardToken, rewards);
        }
    }

    /// @notice Calculates the rewards over `epochs`.
    /// @dev Updates userNextClaimIndex, documenting rewards claimed
    ///      by `user`. This is done prior to distribution to maintain
    ///      check effects.
    /// @param user The address of the user to calculate rewards for.
    /// @param epochs The epochs for which to calculate the rewards.
    /// @return The calculated reward amount.
    ///         This is calculated based on the user's token points
    ///         for the given epoch.
    function _calculateRewards(
        address user,
        uint256 epochs
    ) internal returns (uint256) {
        uint256 startEpoch = userNextClaimIndex[user];
        uint256 rewards;

        for (uint256 i; i < epochs; ) {
            unchecked {
                rewards += _calculateRewardsForEpoch(user, startEpoch + i++);
            }
        }

        // We do not need to worry about over/underflows here because
        // `userNextClaimIndex` only goes up by 1 every 2 weeks.
        unchecked {
            userNextClaimIndex[user] += epochs;
        }

        // Removes the `WAD` precision offset for proper reward value.
        return rewards / WAD;
    }

    /// @notice Calculate the rewards for a given epoch.
    /// @param user The address of the user to calculate rewards for.
    /// @param epoch The epoch for which to calculate the rewards.
    /// @return The calculated reward amount.
    ///         This is calculated based on the user's token points
    ///         for the given epoch.
    function _calculateRewardsForEpoch(
        address user,
        uint256 epoch
    ) internal returns (uint256) {
        if (veCVE.userUnlocksByEpoch(user, epoch) > 0) {
            // If they have tokens unlocking this epoch we need to decrease
            // their tokenPoints.
            veCVE.updateUserPoints(user, epoch);
        }

        // Reward for Epoch = (User Points * Reward Per Point) / WAD Precision
        return
            FixedPointMathLib.fullMulDiv(
                veCVE.userPoints(user),
                epochRewardsPerPoint[epoch],
                WAD
            );
    }

    /// @notice Processes the rewards and distributes to `recipient`, if any.
    ///         If the recipient wishes to receive rewards in a token other than
    ///         the base reward token, a swap is performed.
    ///         If the desired reward token is CVE and the user opts for lock,
    ///         the rewards are locked as VeCVE.
    /// @param recipient The address receiving processed rewards.
    /// @param rewards The amount of rewards to process for `recipient`.
    /// @param rewardsData Rewards data for desired Reward Manager action.
    /// @param params Swap data for token swapping rewards to cve,
    ///               if necessary.
    /// @param aux Auxiliary data for veCVE.
    /// @return The amount of reward token received by `recipient`,
    ///         in either `rewardToken` or CVE.
    function _processRewards(
        address recipient,
        uint256 rewards,
        RewardsData calldata rewardsData,
        bytes calldata params,
        uint256 aux
    ) internal returns (uint256) {
        // If there are no rewards we can return immediately.
        if (rewards == 0) {
            return 0;
        }

        // Check if `recipient` wants to route their rewards into another token.
        if (rewardsData.asCVE) {
            SwapperLib.Swap memory swapData = abi.decode(
                params,
                (SwapperLib.Swap)
            );

            // Swap into their desired reward token.
            if (
                swapData.call.length == 0 ||
                swapData.inputToken != rewardToken ||
                swapData.outputToken != _getCVE() ||
                swapData.inputAmount != rewards
            ) {
                revert RewardManager__SwapDataIsInvalid();
            }

            // Swap to CVE and update reward amount based on CVE received.
            uint256 adjustedRewards = SwapperLib.swapUnsafe(
                centralRegistry,
                swapData
            );

            // Check if the claimer wants to compound their rewards
            // into a lock.
            if (rewardsData.shouldLock) {
                return
                    _compoundRewardsIntoLock(
                        recipient,
                        rewardsData.isFreshLock,
                        rewardsData.isFreshLockContinuous,
                        aux
                    );
            }

            // Transfer them CVE then return.
            SafeTransferLib.safeTransfer(
                _getCVE(),
                recipient,
                adjustedRewards
            );
            return adjustedRewards;
        }

        // Transfer rewards then return.
        SafeTransferLib.safeTransfer(rewardToken, recipient, rewards);
        return rewards;
    }

    /// @notice Locks claimed fees as veCVE, in an old or fresh lock.
    /// @param user The address of the user locking fees as veCVE.
    /// @param isFreshLock A boolean to indicate if a new lock is being
    ///                    created or not.
    /// @param isContinuousLock A boolean to indicate if the lock should be
    ///                       continuous.
    /// @param lockIndex The index of the lock in the user's lock array.
    ///                  This parameter is only required if it is not a fresh
    ///                  lock.
    /// @return The amount of CVE locked for `user`.
    function _compoundRewardsIntoLock(
        address user,
        bool isFreshLock,
        bool isContinuousLock,
        uint256 lockIndex
    ) internal returns (uint256) {
        address cve = _getCVE();

        // The reward manager never custodies CVE so we can use the pure
        // balance here and if anyone ever sends cve to this constant it
        // acts as a two in one token skimmer and locker.
        uint256 lockAmount = IERC20(cve).balanceOf(address(this));

        // Approve veCVE contract to lock `lockAmount` CVE for `user`.
        SafeTransferLib.safeApprove(cve, address(veCVE), lockAmount);

        veCVE.compoundRewardsIntoLock(
            user,
            lockAmount,
            lockIndex,
            isFreshLock,
            isContinuousLock
        );

        return lockAmount;
    }

    /// @notice Returns the genesis epoch.
    /// @return The genesis epoch.
    function _genesisEpoch() internal view returns (uint256) {
        return centralRegistry.genesisEpoch();
    }

    /// @notice Returns the current CVE address.
    function _getCVE() internal view returns (address) {
        return centralRegistry.cve();
    }

    /// @dev Internal helper for reverting efficiently.
    function _revert(uint256 s) internal pure {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, s)
            revert(0x1c, 0x04)
        }
    }

    /// @dev Checks whether the caller has sufficient permissioning.
    function _checkDaoPermissions() internal view {
        if (!centralRegistry.hasDaoPermissions(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }
    }

    /// @dev Checks whether the caller is the veCVE contract.
    function _checkIsVeCVE() internal view {
        address _veCVE = address(veCVE);
        assembly {
            if iszero(eq(caller(), _veCVE)) {
                mstore(0x00, _UNAUTHORIZED_SELECTOR)
                // Return bytes 29-32 for the selector.
                revert(0x1c, 0x04)
            }
        }
    }
}
