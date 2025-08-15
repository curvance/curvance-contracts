// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { BaseCTokenWithYield, FixedPointMathLib, WAD, IERC20, ICentralRegistry } from "contracts/market/token/BaseCTokenWithYield.sol";

import { BPS } from "contracts/libraries/ConstantsLib.sol";

import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

/// @dev `Asset()` Positions must have all assets ready for withdraw,
///      IE assets can NOT be locked.
///      This way assets can be easily liquidated when loans default.
///
///      Each Curvance strategy run must be a LOSSLESS position, since
///      totalAssets is not actually using the balances stored in the
///      contract, rather it only uses an internal balance.
abstract contract StrategyCToken is BaseCTokenWithYield {
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

    /// @dev Mask of vesting rate in `_vestingData`.
    uint256 internal constant _BITMASK_VESTING_RATE = (1 << 176) - 1;
    /// @dev Mask of all bits in `_vestingData` except the 40 bits for
    ///      last vesting claim.
    uint256 internal constant _BITMASK_LAST_CLAIM_COMPLEMENT = (1 << 216) - 1;
    /// @dev The bit position of vesting period end in `_vestingData`.
    uint256 internal constant _BITPOS_VEST_END = 176;
    /// @dev The bit position of last vesting claim in `_vestingData`.
    uint256 internal constant _BITPOS_LAST_VEST = 216;

    /// STORAGE ///

    /// @notice Whether harvesting is currently paused.
    /// @dev Starts paused until market started, 1 = unpaused; 2 = paused.
    uint256 public harvestingPaused = 2;

    /// @notice Whether there is a pending update to vesting period,
    ///         after this vesting period ends.
    NewVestingData public pendingVestingPeriodUpdate;

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

    /// @param cr The address of the Protocol Central Registry.
    /// @param asset_ The address of the underlying asset for this cToken.
    /// @param mm The address of the MarketManager which manages liquidity
    ///           positions between linked cTokens inside a joint market.
    /// @param vestingPeriod_ The length of time a vesting period will last,
    ///                       in seconds.
    constructor(
        ICentralRegistry cr,
        IERC20 asset_,
        address mm,
        uint256 vestingPeriod_
    ) BaseCTokenWithYield(cr, asset_, mm, vestingPeriod_) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Permissioned function to set a new compounding vesting period.
    /// @dev Requires dao authority, `newVestingPeriod` cannot be longer
    ///      than `_MAXIMUM_VESTING_PERIOD` (3 days).
    /// @param newPeriod New vesting period, in seconds.
    function setVestingPeriod(uint256 newPeriod) external {
        _checkDaoPermissions();
        _checkVestingPeriod(newPeriod);

        pendingVestingPeriodUpdate.updateNeeded = true;
        pendingVestingPeriodUpdate.newVestingPeriod = uint248(newPeriod);
    }

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

    /// @notice Returns the current vesting yield information.
    /// @return vestingRate % per second in `asset()`.
    /// @return vestingEnd When the current vesting period ends and a new
    ///                    harvest can execute.
    /// @return lastVestingClaim Last time pending vested yield was claimed.
    function getYieldInformation() external view nonReadReentrant returns (
        uint256 vestingRate,
        uint256 vestingEnd,
        uint256 lastVestingClaim
    ) {
        uint256 vestingData = _vestingData;
        vestingRate = uint176(vestingData);
        vestingEnd = uint40(vestingData >> _BITPOS_VEST_END);
        lastVestingClaim = uint40(vestingData >> _BITPOS_LAST_VEST);
    }

    /// @notice Virtual function to harvest yield from the vault.
    /// @return yield The yield harvested from the vault.
    function harvest(bytes calldata) external virtual returns (uint256 yield);

    /// INTERNAL FUNCTIONS ///

    /// @notice Vests pending rewards, and updates vesting data.
    function _accrueIfNeeded() internal override {
        uint256 assetsToVest = _assetsToVest();
        
        // Vest pending assets, if there is any.
        if (assetsToVest > 0) {
            // Update the lastVestingClaim timestamp.
            _setlastVestingClaim(uint40(block.timestamp));
            
            // Update _totalAssets invariant with vested assets added.
            _totalAssets = _totalAssets + assetsToVest;
        }
    }

    /// @notice Calculates pending assets that have been vested.
    /// @dev If there are no pending assets or the vesting period has ended,
    ///      it returns 0.
    /// @return assets The calculated pending assets to vest.
    function _assetsToVest() internal view override returns (uint256 assets) {
        // Cache vesting data.
        uint256 vestingData = _vestingData;
        assets =  _assetsToVest(
            uint176(vestingData),
            uint40(vestingData >> _BITPOS_VEST_END),
            uint40(vestingData >> _BITPOS_LAST_VEST)
        );
    }

    /// @notice Calculates pending assets that have been vested.
    /// @dev If there are no pending assets or the vesting period has ended,
    ///      it returns 0.
    /// @return assets The calculated pending assets to vest.
    function _assetsToVest(
        uint256 vestingRate,
        uint256 vestingEnd,
        uint256 lastVestingClaim
    ) internal view returns (uint256 assets) {
        // Check whether there are pending yield vesting.
        if (vestingRate > 0 && lastVestingClaim < vestingEnd) {
            // When calculating pending yield:
            // assets =
            // If the vesting period has not ended:
            // PY = vestingRate * (block.timestamp - lastTimeVestClaimed).
            // If the vesting period has ended:
            // PY = vestingRate * (vestingEnd - lastTimeVestClaimed)).
            // Then in either case:
            // Divide the pending yield by `WAD` (1e18) for precision.
            assets =
                (
                    block.timestamp < vestingEnd
                        ? vestingRate * (block.timestamp - lastVestingClaim)
                        : vestingRate * (vestingEnd - lastVestingClaim)
                ) / WAD;
        }
    }

    /// @notice Sets a new `_vestingData` invariant based on `assetsToVest`,
    ///         calculated from the yield generated by a strategy.
    /// @param assetsToVest The yield to vest over `vestingPeriod`.
    function _setVestingData(uint256 assetsToVest) internal {
        uint256 cachedVestingPeriod = vestingPeriod;

        // Set yield vesting rate equal to `assetsToVest` prorated over
        // `vestingPeriod`, in `WAD` (1e18).
        uint256 newVestingRate =
            FixedPointMathLib.mulDiv(assetsToVest, WAD, cachedVestingPeriod);
        uint256 newVestingEnd = block.timestamp + cachedVestingPeriod;
        
        // Reuse `cachedVestingPeriod` as a temporary variable to store the
        // new packed `_vestingData`.
        assembly {
            // Mask `newVestingRate` to the lower 176 bits,
            // in case the upper bits somehow aren't clean.
            newVestingRate := and(newVestingRate, _BITMASK_VESTING_RATE)
            // Equals `newVestingRate | (newVestingEnd << _BITPOS_VEST_END) |
            //          block.timestamp`.
            cachedVestingPeriod := or(
                newVestingRate,
                or(
                    shl(_BITPOS_VEST_END, newVestingEnd),
                    shl(_BITPOS_LAST_VEST, timestamp())
                )
            )
        }

        _vestingData = cachedVestingPeriod;
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
        result =  uint40(vestingData >> _BITPOS_LAST_VEST) >=
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
    /// @param by The account initializing deposits.
    function _initializeDeposits(address by) internal override {
        super._initializeDeposits(by);

        // Deposit into strategy, shares parameter is unused so we can just
        // pass 0.
        _afterDeposit(_BASE_UNDERLYING_RESERVE, 0);

        _setlastVestingClaim(uint40(block.timestamp));
        harvestingPaused = 1;
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
        uint256 fee = FixedPointMathLib.mulDivUp(reward, strategyFee, BPS);
        // Take fee.
        SafeTransferLib.safeTransfer(rewardToken, feeManager, fee);
        // Return remaining reward after fee was taken.
        return (reward - fee);
    }
}
