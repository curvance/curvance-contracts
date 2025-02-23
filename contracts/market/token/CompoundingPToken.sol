// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { BasePToken, FixedPointMathLib, SafeTransferLib, WAD } from "contracts/market/token/BasePToken.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @notice Vault Positions must have all assets ready for withdraw,
///         IE assets can NOT be locked.
///         This way assets can be easily liquidated when loans default.
/// @dev The PToken vaults run must be a LOSSLESS position, since totalAssets
///      is not actually using the balances stored in the contract,
///      rather it only uses an internal balance.
abstract contract CompoundingPToken is BasePToken {
    /// TYPES ///

    /// @notice Storage format of _vaultData bitshifted data structure.
    /// @param rewardRate The rate that the vault vests fresh rewards.
    /// @param vestingPeriodEnd When the current vesting period ends.
    /// @param lastVestClaim Last time vesting rewards were claimed.
    struct VaultData {
        uint176 rewardRate;
        uint40 vestingPeriodEnd;
        uint40 lastVestClaim;
    }

    /// @notice Storage configuration for pending vesting update.
    /// @param updateNeeded Whether there is a pending update to vault
    ///                     vesting schedule.
    /// @param newVestPeriod The pending new compounding vesting schedule.
    struct NewVestingData {
        bool updateNeeded;
        uint248 newVestPeriod;
    }

    /// CONSTANTS ///

    /// @dev Mask of reward rate entry in packed vault data.
    uint256 private constant _BITMASK_REWARD_RATE = (1 << 176) - 1;
    /// @dev Mask of a timestamp entry in packed vault data.
    uint256 private constant _BITMASK_TIMESTAMP = (1 << 40) - 1;
    /// @dev Mask of all bits in packed vault data except the 40 bits
    ///      for `lastVestClaim`.
    uint256 private constant _BITMASK_LAST_CLAIM_COMPLEMENT = (1 << 216) - 1;
    /// @dev The bit position of `vestingPeriodEnd` in packed vault data.
    uint256 private constant _BITPOS_VEST_END = 176;
    /// @dev The bit position of `lastVestClaim` in packed vault data.
    uint256 private constant _BITPOS_LAST_VEST = 216;

    /// STORAGE ///

    /// @notice The period of time harvested rewards are vested over,
    ///         in seconds.
    uint256 public vestPeriod = 1 days;
    /// @notice Whether there is a pending update to vesting period,
    ///         after this vesting period ends.
    NewVestingData public pendingVestUpdate;
    /// @notice Whether compounding is currently paused.
    /// @dev Starts paused until market started, 1 = unpaused; 2 = paused.
    uint256 public compoundingPaused = 2;

    /// @dev Internal packed vault accounting data.
    ///      Bits Layout:
    ///      - [0..127]   `rewardRate`.
    ///      - [128..191] `vestingPeriodEnd`.
    ///      - [192..255] `lastVestClaim`.
    uint256 internal _vaultData;

    /// @dev Approved assets for swap input.
    mapping(address => bool) public isApprovedAsset;

    /// EVENTS ///

    event CompoundingPaused(bool pauseState);

    /// ERRORS ///

    error CompoundingPToken__InvalidVestPeriod();
    error CompoundingPToken__CompoundingPaused();
    error CompoundingPToken__UnapprovedAssetSwap();

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        IERC20 asset_,
        address marketManager_
    ) BasePToken(centralRegistry_, asset_, marketManager_) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Returns the current pToken yield status information.
    /// @return rewardRate: Yield per second in underlying asset.
    ///         vestingPeriodEnd: When the current vesting period ends and
    ///                           a new harvest can execute.
    ///         lastVestClaim: Last time pending vested yield was claimed.
    function getVaultYieldStatus() external view returns (VaultData memory) {
        return _unpackedVaultData(_vaultData);
    }

    /// @notice Starts a pToken market, executed via marketManager.
    /// @dev This initial mint is a failsafe against rounding exploits,
    ///      although, we protect against them in many ways,
    ///      better safe than sorry.
    ///      NOTE: ONLY CALLED ONCE DURING TOKEN LISTING BY DAO AUTHORIZED
    ///            ADDRESS FROM THE MARKET MANAGER.
    /// @param by The account initializing the pToken market.
    /// @return Returns with true when successful.
    function startMarket(
        address by
    ) external override nonReentrant returns (bool) {
        _startMarket(by);
        _setlastVestClaim(uint40(block.timestamp));
        compoundingPaused = 1;
        return true;
    }

    /// @notice Permissioned function to set a new compounding vesting period.
    /// @dev Requires dao authority, `newVestingPeriod` cannot be longer
    ///      than a week (7 days).
    /// @param newVestingPeriod New vesting period, in seconds.
    function setVestingPeriod(uint256 newVestingPeriod) external {
        _checkDaoPermissions();

        if (newVestingPeriod > 7 days) {
            revert CompoundingPToken__InvalidVestPeriod();
        }

        pendingVestUpdate.updateNeeded = true;
        pendingVestUpdate.newVestPeriod = uint248(newVestingPeriod);
    }

    /// @notice Permissioned function to set compounding paused.
    /// @dev Requires elevated authority if unpausing.
    /// @param state Whether compounded should be paused or unpaused.
    function setCompoundingPaused(bool state) external {
        // If the market has not been started,
        // do not allow compounding changes.
        if (lastVestClaim() == 0) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        if (state) {
            _checkDaoPermissions();
        } else {
            _checkElevatedPermissions();
        }

        // Pause state is stored as a uint256 to minimize gas overhead.
        compoundingPaused = state ? 2 : 1;
        emit CompoundingPaused(state);
    }

    // EXTERNAL POSITION LOGIC TO OVERRIDE

    function harvest(bytes calldata) external virtual returns (uint256 yield);

    /// PUBLIC FUNCTIONS ///

    // ACCOUNTING LOGIC

    /// @notice Returns the current per second yield of the vault.
    /// @return The yield received per second in this vault,
    ///         in assets with `WAD` precision.
    function rewardRate() public view returns (uint256) {
        return _vaultData & _BITMASK_REWARD_RATE;
    }

    /// @notice Returns the timestamp when the current vesting period ends.
    /// @return The timestamp when the current vesting period ends,
    ///         in Unix time.
    function vestingPeriodEnd() public view returns (uint256) {
        return (_vaultData >> _BITPOS_VEST_END) & _BITMASK_TIMESTAMP;
    }

    /// @notice Returns the timestamp of the last claim during
    ///         the current vesting period.
    /// @return The timestamp when the last claim occurred,
    ///         in Unix time.
    function lastVestClaim() public view returns (uint256) {
        return uint40(_vaultData >> _BITPOS_LAST_VEST);
    }

    /// @notice Returns the total amount of the underlying asset in the vault,
    ///         including pending rewards that are vested, safely.
    /// @return The total number of underlying assets.
    function totalAssetsSafe()
        public
        view
        override
        nonReadReentrant
        returns (uint256)
    {
        return _totalAssets + _calculatePendingRewards();
    }

    /// @notice Returns the total amount of the underlying asset in the vault,
    ///         including pending rewards that are vested.
    /// @return The total number of underlying assets.
    function totalAssets() public view override returns (uint256) {
        return _totalAssets + _calculatePendingRewards();
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Returns total assets invariant and any pending rewards for
    ///         depositors.
    function _calculateTotalAssetsWithRewards() internal view override returns (
        uint256,
        uint256
    ) {
        // Cache _totalAssets and pendingRewards.
        uint256 pending = _calculatePendingRewards();
        return (_totalAssets + pending, pending);
    }

    /// @notice Updates asset values for a pending deposit request.
    /// @param assets The amount of the underlying asset to deposit.
    /// @param ta The current total number of assets for assets to shares
    ///           conversion.
    /// @param pending The current rewards that are pending and will be vested
    ///                during this deposit.
    function _updateAssetsForDeposit(
        uint256 assets,
        uint256 ta,
        uint256 pending
    ) internal override {
        unchecked {
            // We know that this will not overflow as rewards are partly vested,
            // and assets added and have not overflown from those operations.
            ta = ta + assets;
        }

        // Vest rewards, if there are any, then update `_totalAssets`
        // invariant.
        if (pending > 0) {
            _vestRewards(ta);
        } else {
            _totalAssets = ta;
        }

        // Deposit into strategy, shares parameter is unused so we can just
        // pass 0.
        _afterDeposit(assets, 0);
    }

    /// @notice Updates asset values for a pending withdrawal request.
    /// @param assets The amount of the underlying asset to withdraw.
    /// @param ta The current total number of assets for assets to shares
    ///           conversion.
    /// @param pending The current rewards that are pending and will be vested
    ///                during this withdrawal.
    function _updateAssetsForWithdrawal(
        uint256 assets,
        uint256 ta,
        uint256 pending
    ) internal override {
        // Document removal of `assets` from `ta` due to withdrawal.
        ta = ta - assets;

        // Vest rewards, if there are any, then update `_totalAssets`
        // invariant.
        if (pending > 0) {
            _vestRewards(ta);
        } else {
            _totalAssets = ta;
        }

        // Prepare underlying assets, shares parameter is unused so we can
        // just pass 0.
        _beforeWithdraw(assets, 0);
    }

    /// @notice Starts a pToken market, executed via marketManager.
    /// @dev This initial mint is a failsafe against rounding exploits,
    ///      although, we protect against them in many ways,
    ///      better safe than sorry.
    /// @dev Emits a {Deposit} event.
    /// @param by The account initializing the pToken market.
    function _startMarket(address by) internal override {
        super._startMarket(by);

        // Deposit into strategy, shares parameter is unused so we can just
        // pass 0.
        _afterDeposit(_BASE_UNDERLYING_RESERVE, 0);
    }

    /// @notice Sets a new `_vaultData` invariant based on `yieldToVest`,
    ///         and `periodToVest` parameters together with the current
    ///         block timestamp.
    /// @param yieldToVest The yield to vest over `periodToVest`.
    /// @param periodToVest The period in which `yieldToVest` is vested
    ///                     over to users.
    function _setNewVaultData(
        uint256 yieldToVest,
        uint256 periodToVest
    ) internal {
        // Set rewardRate equal to prorated `yieldToVest` over `periodToVest`,
        // in `WAD` (1e18).
        _vaultData = _packVaultData(
            FixedPointMathLib.mulDiv(yieldToVest, WAD, periodToVest),
            block.timestamp + periodToVest
        );
    }

    /// @notice Packs parameters together with current block timestamp to
    ///         calculate the new packed vault data value.
    /// @param newRewardRate The new rate, per second, that the vault vests
    ///                      fresh rewards.
    /// @param newVestPeriod The timestamp of when the new vesting period
    ///                      ends, which is block.timestamp + `vestPeriod`.
    function _packVaultData(
        uint256 newRewardRate,
        uint256 newVestPeriod
    ) internal view returns (uint256 result) {
        assembly {
            // Mask `newRewardRate` to the lower 176 bits,
            // in case the upper bits somehow aren't clean.
            newRewardRate := and(newRewardRate, _BITMASK_REWARD_RATE)
            // Equal to `newRewardRate | (newVestPeriod << _BITPOS_VEST_END) |
            //          block.timestamp`.
            result := or(
                newRewardRate,
                or(
                    shl(_BITPOS_VEST_END, newVestPeriod),
                    shl(_BITPOS_LAST_VEST, timestamp())
                )
            )
        }
    }

    /// @notice Returns the unpacked `VaultData` struct
    ///         from `packedVaultData`.
    /// @param packedVaultData The current packed vault data value.
    /// @return vault The current vault data value, but unpacked into
    ///               a VaultData struct.
    function _unpackedVaultData(
        uint256 packedVaultData
    ) internal pure returns (VaultData memory vault) {
        vault.rewardRate = uint176(packedVaultData);
        vault.vestingPeriodEnd = uint40(packedVaultData >> _BITPOS_VEST_END);
        vault.lastVestClaim = uint40(packedVaultData >> _BITPOS_LAST_VEST);
    }

    /// @notice Returns whether the current vesting period has ended,
    ///         based on the last vest timestamp.
    /// @param packedVaultData Current packed vault data value.
    /// @return Bool of whether the current vesting period has ended or not.
    function _checkVestStatus(
        uint256 packedVaultData
    ) internal pure returns (bool) {
        return
            uint40(packedVaultData >> _BITPOS_LAST_VEST) >=
            uint40(packedVaultData >> _BITPOS_VEST_END);
    }

    /// @notice Sets the last vest claim data for the vault.
    /// @param newVestClaim The new timestamp to record as
    ///                     the last vesting claim.
    function _setlastVestClaim(uint40 newVestClaim) internal {
        // Cache vault data.
        uint256 packedVaultData = _vaultData;
        uint256 lastVestClaimCasted;
        // Cast `newVestClaim` with assembly to avoid redundant masking.
        assembly {
            lastVestClaimCasted := newVestClaim
        }
        // Calculate new packed vault data.
        packedVaultData =
            (packedVaultData & _BITMASK_LAST_CLAIM_COMPLEMENT) |
            (lastVestClaimCasted << _BITPOS_LAST_VEST);

        // Update `_vaultData` invariant.
        _vaultData = packedVaultData;
    }

    // REWARD AND HARVESTING LOGIC

    /// @notice Calculates pending rewards that have been vested.
    /// @dev If there are no pending rewards or the vesting period has ended,
    ///      it returns 0.
    /// @return pendingRewards The calculated pending rewards.
    function _calculatePendingRewards()
        internal
        view
        returns (uint256 pendingRewards)
    {
        VaultData memory vaultData = _unpackedVaultData(_vaultData);
        // Check whether there are pending rewards vesting.
        if (
            vaultData.rewardRate > 0 &&
            vaultData.lastVestClaim < vaultData.vestingPeriodEnd
        ) {
            // When calculating pending rewards:
            // pendingRewards =
            // If the vesting period has not ended:
            // PR = rewardRate * (block.timestamp - lastTimeVestClaimed).
            // If the vesting period has ended:
            // PR = rewardRate * (vestingPeriodEnd - lastTimeVestClaimed)).
            // Then in either case:
            // Divide the pending rewards by `WAD` (1e18) for precision.
            pendingRewards =
                (
                    block.timestamp < vaultData.vestingPeriodEnd
                        ? (vaultData.rewardRate *
                            (block.timestamp - vaultData.lastVestClaim))
                        : (vaultData.rewardRate *
                            (vaultData.vestingPeriodEnd -
                                vaultData.lastVestClaim))
                ) /
                WAD;
        }
    }

    /// @notice Checks if the caller can compound pending vaults rewards.
    function _canCompound() internal view {
        if (!centralRegistry.isHarvester(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        if (compoundingPaused == 2) {
            revert CompoundingPToken__CompoundingPaused();
        }
    }

    /// @notice Applies a fee in `rewardToken` based on `strategyFee` applied
    ///         to pending `reward`, and sending the fee to `feeManager`.
    /// @param reward The pending reward in `rewardToken` to take strategy
    ///               fee from.
    /// @param rewardToken The token that the pending reward is in and that
    ///                    fee will be taken in.
    /// @param strategyFee The percent fee to take from `reward`.
    /// @param feeManager The fee manager address that will receive the fee
    ///                   collected.
    function _applyFee(
        uint256 reward,
        address rewardToken,
        uint256 strategyFee,
        address feeManager
    ) internal returns (uint256) {
        // Calculate protocol fee for token lockers and strategy bot.
        uint256 fee = FixedPointMathLib.mulDivUp(reward, strategyFee, WAD);
        // Take fee.
        SafeTransferLib.safeTransfer(
            rewardToken,
            feeManager,
            fee
        );
        // Return remaining reward after fee was taken.
        return (reward - fee);
    }

    /// @notice Vests pending rewards, and updates vault data.
    /// @param currentAssets The current assets of the vault.
    function _vestRewards(uint256 currentAssets) internal {
        // Update the lastVestClaim timestamp.
        _setlastVestClaim(uint40(block.timestamp));

        // Set internal _totalAssets balance to `currentAssets`.
        _totalAssets = currentAssets;
    }

    /// @notice Vests pending rewards, and updates vault data.
    function _vestIfNeeded() internal {
        // Vest pending rewards.
        _vestRewards(_totalAssets + _calculatePendingRewards());
    }

    /// @notice Updates the vesting period, if needed.
    /// @dev If there a pending vesting update,
    ///      and prior vest is done then `vestPeriod` is updated.
    function _updateVestingPeriodIfNeeded() internal {
        // Check whether there is a pending update to reward vesting schedule.
        if (pendingVestUpdate.updateNeeded) {
            // Update vesting period.
            vestPeriod = pendingVestUpdate.newVestPeriod;
            // Remove pending vesting update flag.
            delete pendingVestUpdate.updateNeeded;
        }
    }
}
