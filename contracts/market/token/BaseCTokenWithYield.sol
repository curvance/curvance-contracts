// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseCToken, FixedPointMathLib, WAD, IERC20, ICentralRegistry } from "contracts/market/token/BaseCToken.sol";

abstract contract BaseCTokenWithYield is BaseCToken {
    /// TYPES ///

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

    /// STORAGE ///

    /// @notice The period of time harvested rewards are vested over,
    ///         in seconds.
    uint256 public vestingPeriod;
    /// @notice Whether there is a pending update to vesting period,
    ///         after this vesting period ends.
    NewVestingData public pendingVestingPeriodUpdate;

    /// @dev Internal packed vesting data:
    ///      StrategyCToken Bits Layout:
    ///      - [0..127]   `vestingRate`.
    ///      - [128..191] `vestingPeriodEnd`.
    ///      - [192..255] `lastVestingClaim`.
    ///
    ///      BorrowableCToken Bits Layout:
    ///      - [0..95]   `vestingRate`.
    ///      - [96..135] `vestingPeriodEnd`.
    ///      - [136..175] `lastVestingClaim`.
    ///      - [176..255] `marketDebtIndex`.
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
        result = _totalAssets + _getPendingYield();
    }

    /// @notice Calculates pending yield that has been vested.
    /// @dev If there are no pending yield or the vesting period has ended,
    ///      it returns 0.
    /// @return pendingYield The calculated pending yield, in assets.
    function _getPendingYield(
        uint256 vestingRate,
        uint256 lastVestingClaim,
        uint256 vestingPeriodEnd
    )
        internal
        view
        returns (uint256 pendingYield)
    {
        // Check whether there are pending yield vesting.
        if (vestingRate > 0 && lastVestingClaim < vestingPeriodEnd) {
            // When calculating pending yield:
            // pendingYield =
            // If the vesting period has not ended:
            // PY = vestingRate * (block.timestamp - lastTimeVestClaimed).
            // If the vesting period has ended:
            // PY = vestingRate * (vestingPeriodEnd - lastTimeVestClaimed)).
            // Then in either case:
            // Divide the pending yield by `WAD` (1e18) for precision.
            pendingYield =
                (
                    block.timestamp < vestingPeriodEnd
                        ? vestingRate * (block.timestamp - lastVestingClaim)
                        : vestingRate * (vestingPeriodEnd - lastVestingClaim)
                ) /
                WAD;
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

    /// @notice Calculates pending yield that have been vested.
    /// @dev If there are no pending yield or the vesting period has ended,
    ///      it returns 0.
    /// @return The calculated pending yield.
    function _getPendingYield() internal view virtual returns (uint256);

    /// @notice Returns whether the current vesting period has ended,
    ///         based on the last vest timestamp.
    /// @param packedVestingData Current packed vault data value.
    /// @return result Boolean value indicating whether the current
    ///                vesting period has ended or not.
    function _checkVestingFinished(
        uint256 packedVestingData
    ) internal pure virtual returns (bool result) {}
}
