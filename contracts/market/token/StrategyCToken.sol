// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseCTokenWithYield, FixedPointMathLib, WAD, IERC20, ICentralRegistry } from "contracts/market/token/BaseCTokenWithYield.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

/// @notice Vault Positions must have all assets ready for withdraw,
///         IE assets can NOT be locked.
///         This way assets can be easily liquidated when loans default.
/// @dev Each Curvance token vault run must be a LOSSLESS position, since
///      totalAssets is not actually using the balances stored in the
///      contract, rather it only uses an internal balance.
abstract contract StrategyCToken is BaseCTokenWithYield {
    /// CONSTANTS ///

    /// @dev Mask of vesting rate entry in `_vestingData`.
    uint256 internal constant _BITMASK_VESTING_RATE = (1 << 176) - 1;
    /// @dev Mask of a timestamp entry in `_vestingData`.
    uint256 internal constant _BITMASK_TIMESTAMP = (1 << 40) - 1;
    /// @dev Mask of all bits in `_vestingData` except the 40 bits for
    ///      `lastVestingClaim`.
    uint256 internal constant _BITMASK_LAST_CLAIM_COMPLEMENT = (1 << 216) - 1;
    /// @dev The bit position of `vestingPeriodEnd` in `_vestingData`.
    uint256 internal constant _BITPOS_VEST_END = 176;
    /// @dev The bit position of `lastVestingClaim` in `_vestingData`.
    uint256 internal constant _BITPOS_LAST_VEST = 216;

    /// STORAGE ///

    /// @notice Whether harvesting is currently paused.
    /// @dev Starts paused until market started, 1 = unpaused; 2 = paused.
    uint256 public harvestingPaused = 2;

    /// @notice Whether a particular token is an approved asset for swapping.
    /// @dev Token => Is approved swap token.
    mapping(address => bool) internal _isApprovedAsset;
    /// @notice Whether a particular token is an underlying token
    ///         of this strategy.
    /// @dev Token => Is underlying token.
    mapping(address => bool) internal _isUnderlyingToken;

    /// EVENTS ///

    event Harvest(uint256 yield);
    event HarvestingPaused(bool pauseState);

    /// ERRORS ///

    error StrategyCToken__HarvestingPaused();
    error StrategyCToken__UnapprovedAssetSwap();

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        IERC20 asset_,
        address marketManager_,
        uint256 vestPeriod_
    ) BaseCTokenWithYield(centralRegistry_, asset_, marketManager_, vestPeriod_) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Permissioned function to set harvesting paused.
    /// @dev Requires elevated authority if unpausing.
    /// @param state Whether compounded should be paused or unpaused.
    function setHarvestingPaused(bool state) external {
        // If the market has not been started,
        // do not allow harvesting changes.
        if ((_vestingData >> _BITPOS_LAST_VEST) == 0) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        if (state) {
            _checkDaoPermissions();
        } else {
            _checkElevatedPermissions();
        }

        // Pause state is stored as a uint256 to minimize gas overhead.
        harvestingPaused = state ? 2 : 1;
        emit HarvestingPaused(state);
    }

    /// @notice Returns the current cToken yield status information.
    /// @return vestingRate Yield per second in `asset()`.
    /// @return vestingPeriodEnd When the current vesting period ends and
    ///                          a new harvest can execute.
    /// @return lastVestingClaim Last time pending vested yield was claimed.
    function getVestingYieldData() external view nonReadReentrant returns (
        uint256 vestingRate,
        uint256 vestingPeriodEnd,
        uint256 lastVestingClaim
    ) {
        uint256 vestingData = _vestingData;
        vestingRate = uint176(vestingData);
        vestingPeriodEnd = uint40(vestingData >> _BITPOS_VEST_END);
        lastVestingClaim = uint40(vestingData >> _BITPOS_LAST_VEST);
    }

    /// @notice Virtual function to harvest yield from the vault.
    /// @return yield The yield harvested from the vault.
    function harvest(bytes calldata) external virtual returns (uint256 yield);

    /// PUBLIC FUNCTIONS ///

    /// @notice Vests pending rewards, and updates vesting data.
    function accrueIfNeeded() public override {
        uint256 pendingYieldToVest = _getPendingYield();
        
        // Vest pending yield, if there is any.
        if (pendingYieldToVest > 0) {
            // Update the lastVestingClaim timestamp.
            _setlastVestingClaim(uint40(block.timestamp));
            
            // Update _totalAssets invariant with pending yield added.
            _totalAssets = _totalAssets + pendingYieldToVest;
        }
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Calculates pending yield that have been vested.
    /// @dev If there are no pending yield or the vesting period has ended,
    ///      it returns 0.
    /// @return pendingYield The calculated pending yield.
    function _getPendingYield() internal view override returns (
        uint256 pendingYield
    ) {
        // Cache vesting data.
        uint256 vestingData = _vestingData;
        pendingYield =  _getPendingYield(
            uint176(vestingData),
            uint40(vestingData >> _BITPOS_VEST_END),
            uint40(vestingData >> _BITPOS_LAST_VEST)
        );
    }

    /// @notice Sets a new `_vestingData` invariant based on `yieldToVest`,
    ///         calculated from the yield generated by a strategy.
    /// @param yieldToVest The yield to vest over `vestingPeriod`.
    function _setVestingData(uint256 yieldToVest) internal {
        uint256 cachedVestingData = vestingPeriod;

        // Set vestingRate equal to `yieldToVest` prorated over
        // `periodToVest`, in `WAD` (1e18).
        uint256 newVestingRate =
            FixedPointMathLib.mulDiv(yieldToVest, WAD, cachedVestingData);
        uint256 newVestingEnd = block.timestamp + cachedVestingData;
        
        // Reuse cachedVestingData as a temporary variable.
        assembly {
            // Mask `newVestingRate` to the lower 176 bits,
            // in case the upper bits somehow aren't clean.
            newVestingRate := and(newVestingRate, _BITMASK_VESTING_RATE)
            // Equals `newVestingRate | (newVestingEnd << _BITPOS_VEST_END) |
            //          block.timestamp`.
            cachedVestingData := or(
                newVestingRate,
                or(
                    shl(_BITPOS_VEST_END, newVestingEnd),
                    shl(_BITPOS_LAST_VEST, timestamp())
                )
            )
        }

        _vestingData = cachedVestingData;
    }

    /// @notice Sets the last vest claim data for the vault.
    /// @param newVestClaim The new timestamp to record as
    ///                     the last vesting claim.
    function _setlastVestingClaim(uint40 newVestClaim) internal {

        uint256 lastVestingClaimCasted;
        // Cast `newVestClaim` with assembly to avoid redundant masking.
        assembly {
            lastVestingClaimCasted := newVestClaim
        }

        // Calculate and update `_vestingData` invariant.
        _vestingData = (_vestingData & _BITMASK_LAST_CLAIM_COMPLEMENT) |
            (lastVestingClaimCasted << _BITPOS_LAST_VEST);
    }

    /// @notice Returns whether the current vesting period has ended,
    ///         based on the last vest timestamp.
    /// @param vestingData Current packed vault data value.
    /// @return result Boolean value indicating whether the current
    ///                vesting period has ended or not.
    function _checkVestingFinished(
        uint256 vestingData
    ) internal pure override returns (bool result) {
        result = 
            uint40(vestingData >> _BITPOS_LAST_VEST) >=
            uint40(vestingData >> _BITPOS_VEST_END);
    }

    /// @notice Updates asset values for a pending deposit.
    /// @param assets The amount of `asset()` to deposit.
    function _updateAssetsForDeposit(uint256 assets) internal override {
        super._updateAssetsForDeposit(assets);

        // Deposit into strategy, shares parameter is unused so we can just
        // pass 0.
        _afterDeposit(assets, 0);
    }

    /// @notice Updates asset values for a pending withdrawal.
    /// @param assets The amount of `asset()` to withdraw.
    function _updateAssetsForWithdrawal(uint256 assets) internal override {
        super._updateAssetsForWithdrawal(assets);

        // Prepare underlying assets, shares parameter is unused so we can
        // just pass 0.
        _beforeWithdraw(assets, 0);
    }

    /// @notice Starts a cToken market, executed via marketManager.
    /// @dev This initial mint is a failsafe against rounding exploits,
    ///      although, we protect against them in many ways,
    ///      better safe than sorry.
    /// @dev Emits a {Deposit} event.
    /// @param by The account initializing the cToken market.
    function _startMarket(address by) internal override {
        super._startMarket(by);

        // Deposit into strategy, shares parameter is unused so we can just
        // pass 0.
        _afterDeposit(_BASE_UNDERLYING_RESERVE, 0);

        _setlastVestingClaim(uint40(block.timestamp));
        harvestingPaused = 1;

    }

    /// @notice Checks if the caller can harvest pending strategy yield.
    function _canHarvest() internal view {
        if (!centralRegistry.hasHarvestPermissions(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        if (harvestingPaused == 2) {
            revert StrategyCToken__HarvestingPaused();
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
    /// @return The remaining reward after the fee was taken.
    function _applyFee(
        uint256 reward,
        address rewardToken,
        uint256 strategyFee,
        address feeManager
    ) internal returns (uint256) {
        // Calculate protocol fee for token lockers and strategy bot.
        uint256 fee = FixedPointMathLib.mulDivUp(reward, strategyFee, WAD);
        // Take fee.
        SafeTransferLib.safeTransfer(rewardToken, feeManager, fee);
        // Return remaining reward after fee was taken.
        return (reward - fee);
    }
}
