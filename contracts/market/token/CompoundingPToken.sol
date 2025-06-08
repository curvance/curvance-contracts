// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseMTokenWithYield, FixedPointMathLib, SafeTransferLib, WAD, IERC20, ICentralRegistry } from "contracts/market/token/BaseMTokenWithYield.sol";

/// @notice Vault Positions must have all assets ready for withdraw,
///         IE assets can NOT be locked.
///         This way assets can be easily liquidated when loans default.
/// @dev The PToken vaults run must be a LOSSLESS position, since totalAssets
///      is not actually using the balances stored in the contract,
///      rather it only uses an internal balance.
abstract contract CompoundingPToken is BaseMTokenWithYield {
    /// STORAGE ///

    /// @notice Whether compounding is currently paused.
    /// @dev Starts paused until market started, 1 = unpaused; 2 = paused.
    uint256 public compoundingPaused = 2;

    /// @dev Approved assets for swap input.
    mapping(address => bool) public isApprovedAsset;

    /// EVENTS ///

    event CompoundingPaused(bool pauseState);

    /// ERRORS ///

    error CompoundingPToken__CompoundingPaused();
    error CompoundingPToken__UnapprovedAssetSwap();

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        IERC20 asset_,
        address marketManager_,
        uint256 vestPeriod_
    ) BaseMTokenWithYield(centralRegistry_, asset_, marketManager_, vestPeriod_) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Virtual function to harvest yield from the vault.
    /// @return yield The yield harvested from the vault.
    function harvest(bytes calldata) external virtual returns (uint256 yield);

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

    /// @notice Permissioned function to set compounding paused.
    /// @dev Requires elevated authority if unpausing.
    /// @param state Whether compounded should be paused or unpaused.
    function setCompoundingPaused(bool state) external {
        // If the market has not been started,
        // do not allow compounding changes.
        if ((_vaultData >> _BITPOS_LAST_VEST) == 0) {
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

    /// INTERNAL FUNCTIONS ///

    /// @notice Updates asset values for a pending deposit.
    /// @param assets The amount of `asset()` to deposit.
    /// @param ta The current asset total for assets to shares conversion
    ///           logic.
    /// @param pending The yield pending to be vested during this deposit.
    function _updateAssetsForDeposit(
        uint256 assets,
        uint256 ta,
        uint256 pending
    ) internal override {
        super._updateAssetsForDeposit(assets, ta, pending);

        // Deposit into strategy, shares parameter is unused so we can just
        // pass 0.
        _afterDeposit(assets, 0);
    }

    /// @notice Updates asset values for a pending withdrawal.
    /// @param assets The amount of `asset()` to withdraw.
    /// @param ta The current asset total for assets to shares conversion
    ///           logic.
    /// @param pending The yield pending to be vested during this withdrawal.
    function _updateAssetsForWithdrawal(
        uint256 assets,
        uint256 ta,
        uint256 pending
    ) internal override {
        super._updateAssetsForWithdrawal(assets, ta, pending);

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

    /// @notice Checks if the caller can compound pending vaults rewards.
    function _canCompound() internal view {
        if (!centralRegistry.hasHarvestPermissions(msg.sender)) {
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
