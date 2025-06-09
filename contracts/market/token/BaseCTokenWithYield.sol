// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseCToken, FixedPointMathLib, WAD, IERC20, ICentralRegistry } from "contracts/market/token/BaseCToken.sol";

abstract contract BaseCTokenWithYield is BaseCToken {
    /// TYPES ///

    /// @notice Storage format of _vestingData bitshifted data structure.
    /// @param rewardRate The rate that the vault vests fresh yield.
    /// @param vestingPeriodEnd When the current vesting period ends.
    /// @param lastVestClaim Last time vesting yield was claimed.
    struct VestingData {
        uint176 rewardRate;
        uint40 vestingPeriodEnd;
        uint40 lastVestClaim;
    }

    /// @notice Storage configuration for pending vesting update.
    /// @param updateNeeded Whether there is a pending update to vault
    ///                     vesting schedule.
    /// @param newVestingPeriod The pending new compounding vesting schedule.
    struct NewVestingData {
        bool updateNeeded;
        uint248 newVestingPeriod;
    }

    /// CONSTANTS ///

    /// @notice The maximum length of time between vesting periods.
    uint256 internal constant _MAXIMUM_VEST_PERIOD = 3 days;
    /// @dev Mask of reward rate entry in packed vault data.
    uint256 internal constant _BITMASK_REWARD_RATE = (1 << 176) - 1;
    /// @dev Mask of a timestamp entry in packed vault data.
    uint256 internal constant _BITMASK_TIMESTAMP = (1 << 40) - 1;
    /// @dev Mask of all bits in packed vault data except the 40 bits
    ///      for `lastVestClaim`.
    uint256 internal constant _BITMASK_LAST_CLAIM_COMPLEMENT = (1 << 216) - 1;
    /// @dev The bit position of `vestingPeriodEnd` in packed vault data.
    uint256 internal constant _BITPOS_VEST_END = 176;
    /// @dev The bit position of `lastVestClaim` in packed vault data.
    uint256 internal constant _BITPOS_LAST_VEST = 216;

    /// STORAGE ///

    /// @notice The period of time harvested rewards are vested over,
    ///         in seconds.
    uint256 public vestingPeriod;
    /// @notice Whether there is a pending update to vesting period,
    ///         after this vesting period ends.
    NewVestingData public pendingVestingPeriodUpdate;

    /// @dev Internal packed vault accounting data.
    ///      Bits Layout:
    ///      - [0..127]   `rewardRate`.
    ///      - [128..191] `vestingPeriodEnd`.
    ///      - [192..255] `lastVestClaim`.
    uint256 internal _vestingData;

    /// ERRORS ///

    error BaseCTokenWithYield__InvalidVestingPeriod();

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        IERC20 asset_,
        address marketManager_,
        uint256 vestingPeriod_
    ) BaseCToken(centralRegistry_, asset_, marketManager_) {
        if (
            vestingPeriod_ > _MAXIMUM_VEST_PERIOD &&
            vestingPeriod_ != 0
            ) {
            revert BaseCTokenWithYield__InvalidVestingPeriod();
        }
        
        vestingPeriod = vestingPeriod_;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Returns the current pToken yield status information.
    /// @return result A VestingData struct containing:
    ///         rewardRate: Yield per second in `asset()`.
    ///         vestingPeriodEnd: When the current vesting period ends and
    ///                           a new harvest can execute.
    ///         lastVestClaim: Last time pending vested yield was claimed.
    function getVestingYieldData() external view nonReadReentrant returns (
        VestingData memory result
    ) {
        result =  _unpackedVestingData(_vestingData);
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
    ) external override nonReentrant virtual returns (bool) {
        _startMarket(by);
        _setlastVestClaim(uint40(block.timestamp));
        return true;
    }

    /// @notice Permissioned function to set a new compounding vesting period.
    /// @dev Requires dao authority, `newVestingPeriod` cannot be longer
    ///      than a week (7 days).
    /// @param newVestingPeriod New vesting period, in seconds.
    function setVestingPeriod(uint256 newVestingPeriod) external {
        _checkDaoPermissions();

        if (
            newVestingPeriod > _MAXIMUM_VEST_PERIOD &&
            newVestingPeriod != 0
            ) {
            revert BaseCTokenWithYield__InvalidVestingPeriod();
        }

        pendingVestingPeriodUpdate.updateNeeded = true;
        pendingVestingPeriodUpdate.newVestingPeriod = uint248(
            newVestingPeriod
        );
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Returns the total amount of the underlying asset in the vault,
    ///         including pending rewards that are vested.
    /// @return result The total number of underlying assets.
    function _getTotalAssets() internal view override returns (
        uint256 result
    ) {
        result = (_totalAssets + _calculatePendingYield());
    }

    /// @notice Sets a new `_vestingData` invariant based on `yieldToVest`,
    ///         and `periodToVest` parameters together with the current
    ///         block timestamp.
    /// @param yieldToVest The yield to vest over `periodToVest`.
    /// @param periodToVest The period in which `yieldToVest` is vested
    ///                     over to users.
    function _setNewVestingData(
        uint256 yieldToVest,
        uint256 periodToVest
    ) internal {
        // Set rewardRate equal to prorated `yieldToVest` over `periodToVest`,
        // in `WAD` (1e18).
        _vestingData = _packVestingData(
            FixedPointMathLib.mulDiv(yieldToVest, WAD, periodToVest),
            block.timestamp + periodToVest
        );
    }

    /// @notice Sets the last vest claim data for the vault.
    /// @param newVestClaim The new timestamp to record as
    ///                     the last vesting claim.
    function _setlastVestClaim(uint40 newVestClaim) internal {
        // Cache vault data.
        uint256 packedVestingData = _vestingData;
        uint256 lastVestClaimCasted;
        // Cast `newVestClaim` with assembly to avoid redundant masking.
        assembly {
            lastVestClaimCasted := newVestClaim
        }
        // Calculate new packed vault data.
        packedVestingData =
            (packedVestingData & _BITMASK_LAST_CLAIM_COMPLEMENT) |
            (lastVestClaimCasted << _BITPOS_LAST_VEST);

        // Update `_vestingData` invariant.
        _vestingData = packedVestingData;
    }

    /// @notice Packs parameters together with current block timestamp to
    ///         calculate the new packed vault data value.
    /// @param newRewardRate The new rate, per second, that the vault vests
    ///                      fresh rewards.
    /// @param newVestingPeriod The timestamp of when the new vesting period
    ///                      ends, which is block.timestamp + `vestingPeriod`.
    /// @return result The new packed vault data value.
    function _packVestingData(
        uint256 newRewardRate,
        uint256 newVestingPeriod
    ) internal view returns (uint256 result) {
        assembly {
            // Mask `newRewardRate` to the lower 176 bits,
            // in case the upper bits somehow aren't clean.
            newRewardRate := and(newRewardRate, _BITMASK_REWARD_RATE)
            // Equals `newRewardRate | (newVestingPeriod << _BITPOS_VEST_END) |
            //          block.timestamp`.
            result := or(
                newRewardRate,
                or(
                    shl(_BITPOS_VEST_END, newVestingPeriod),
                    shl(_BITPOS_LAST_VEST, timestamp())
                )
            )
        }
    }

    /// @notice Returns the unpacked `VestingData` struct
    ///         from `packedVestingData`.
    /// @param packedVestingData The current packed vesting data value.
    /// @return result The current vesting data, but unpacked into
    ///                a VestingData struct.
    function _unpackedVestingData(
        uint256 packedVestingData
    ) internal pure returns (VestingData memory result) {
        result.rewardRate = uint176(packedVestingData);
        result.vestingPeriodEnd = uint40(
            packedVestingData >> _BITPOS_VEST_END
        );
        result.lastVestClaim = uint40(packedVestingData >> _BITPOS_LAST_VEST);
    }

    /// @notice Returns whether the current vesting period has ended,
    ///         based on the last vest timestamp.
    /// @param packedVestingData Current packed vault data value.
    /// @return result Boolean value indicating whether the current
    ///                vesting period has ended or not.
    function _checkVestStatus(
        uint256 packedVestingData
    ) internal pure returns (bool result) {
        result = 
            uint40(packedVestingData >> _BITPOS_LAST_VEST) >=
            uint40(packedVestingData >> _BITPOS_VEST_END);
    }

    /// @notice Calculates pending yield that have been vested.
    /// @dev If there are no pending yield or the vesting period has ended,
    ///      it returns 0.
    /// @return pendingYield The calculated pending yield.
    function _calculatePendingYield()
        internal
        view
        returns (uint256 pendingYield)
    {
        VestingData memory vestingData = _unpackedVestingData(_vestingData);
        // Check whether there are pending yield vesting.
        if (
            vestingData.rewardRate > 0 &&
            vestingData.lastVestClaim < vestingData.vestingPeriodEnd
        ) {
            // When calculating pending yield:
            // pendingYield =
            // If the vesting period has not ended:
            // PR = rewardRate * (block.timestamp - lastTimeVestClaimed).
            // If the vesting period has ended:
            // PR = rewardRate * (vestingPeriodEnd - lastTimeVestClaimed)).
            // Then in either case:
            // Divide the pending yield by `WAD` (1e18) for precision.
            pendingYield =
                (
                    block.timestamp < vestingData.vestingPeriodEnd
                        ? (vestingData.rewardRate *
                            (block.timestamp - vestingData.lastVestClaim))
                        : (vestingData.rewardRate *
                            (vestingData.vestingPeriodEnd -
                                vestingData.lastVestClaim))
                ) /
                WAD;
        }
    }

    /// @notice Vests pending yield, and updates last vest timestamp.
    /// @param newTotalAssets The current assets of the vault, this is called
    ///                       with the previous total amount plus pending
    ///                       yield to recognize from time based vesting.
    function _vestYield(uint256 newTotalAssets) internal {
        // Update the lastVestClaim timestamp.
        _setlastVestClaim(uint40(block.timestamp));

        // Set internal _totalAssets balance to `currentAssets` which is the
        // current _totalAssets values plus pending yield.
        _totalAssets = newTotalAssets;
    }

    /// @notice Vests pending rewards, and updates vault data.
    function _vestIfNeeded() internal override {
        // Vest pending rewards.
        uint256 pendingYieldToVest = _calculatePendingYield();
        if (pendingYieldToVest > 0) {
            _vestYield(pendingYieldToVest);
        }
    }

    /// @notice Updates the vesting period, if needed.
    /// @dev If there a pending vesting update,
    ///      and prior vest is done then `vestingPeriod` is updated.
    function _updateVestingPeriodIfNeeded() internal {
        // Check whether there is a pending update to reward vesting schedule.
        if (pendingVestingPeriodUpdate.updateNeeded) {
            // Update vesting period.
            vestingPeriod = pendingVestingPeriodUpdate.newVestingPeriod;
            // Remove pending vesting update flag.
            delete pendingVestingPeriodUpdate.updateNeeded;
        }
    }
}
