// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { StrategyCToken, ICentralRegistry, IERC20 } from "contracts/market/token/StrategyCToken.sol";

import { WAD } from "contracts/libraries/Constants.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { IPositionManager } from "contracts/interfaces/IPositionManager.sol";

/// @notice Vault Positions must have all assets ready for withdraw,
///         IE assets can NOT be locked.
///         This way assets can be easily liquidated when loans default.
/// @dev The PToken vaults run must be a LOSSLESS position, since totalAssets
///      is not actually using the balances stored in the position,
///      rather it only uses an internal balance.
abstract contract StrategyCTokenWithExitFee is StrategyCToken {
    /// CONSTANTS ///

    /// @notice Maximum exit fee configurable by DAO.
    ///         .02e18 = 2%.
    uint256 public constant MAXIMUM_EXIT_FEE = .02e18;

    /// STORAGE ///

    /// @notice Fee for exiting a vault position, in `WAD`.
    uint256 public exitFee;

    /// EVENTS ///

    event ExitFeeSet(uint256 oldExitFee, uint256 newExitFee);

    /// ERRORS ///

    error StrategyCTokenWithExitFee__InvalidExitFee();

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        IERC20 asset_,
        address marketManager_,
        uint256 exitFee_,
        uint256 vestPeriod_
    ) StrategyCToken(
        centralRegistry_,
        asset_,
        marketManager_,
        vestPeriod_
    ) {
        _setExitFee(exitFee_);
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Permissioned function for setting the exit fee on redemption
    ///         of shares for assets.
    /// @dev Parameter passed in basis points and converted to `WAD`.
    ///      Has a maximum value of `MAXIMUM_EXIT_FEE`.
    /// @param newExitFee The new exit fee to set for redemption of assets,
    ///                   in basis points.
    function setExitFee(uint256 newExitFee) external {
        _checkElevatedPermissions();
        _setExitFee(newExitFee);
    }

    /// PUBLIC FUNCTIONS ///

    function previewWithdraw(
        uint256 assets
    ) public view override returns (uint256 shares) {
        // Exit fee is base WAD so we can substract apples to apples to get
        // how many shares need to be withdrawn to receive `assets`.
        assets = FixedPointMathLib.mulDivUp(assets, WAD, WAD - exitFee);
        shares = super.previewWithdraw(assets);
    }

    function previewRedeem(
        uint256 shares
    ) public view override returns (uint256 assets) {
        assets = super.previewRedeem(shares);
        assets = _removeExitFeeFromAssets(assets);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Helper function for Position Management contract to
    ///         redeem assets.
    /// @param owner The owner address of assets to redeem.
    /// @param assets The amount of the underlying assets to redeem.
    /// @param shares The amount of the shares to redeem.
    /// @param balancePrior The balance of shares `owner` has before this
    ///                     redemption. 
    /// @param deleverageData Struct containing information on the desired
    ///                       deleverage action to execute. Containing values:
    ///                       1. Address of pToken that will be routed into
    ///                          eToken underlying to repay outstanding debt.
    ///                       2. The amount of pTokens that will be
    ///                          deleveraged.
    ///                       3. Address of eToken that will have its underlying
    ///                          token debt repaid.
    ///                       4. Optional struct containing instructions on how
    ///                          to handle swapping into eToken underlying to
    ///                          facilitate deleveraging.
    ///                       5. The amount of underlying tokens that will be
    ///                          repaid to the eToken lenders.
    ///                       6. Optional auxiliary data for execution of a
    ///                          deleverage action.
    function _processPositionManagerRedemption(
        address owner,
        uint256 assets,
        uint256 shares,
        uint256 balancePrior,
        IPositionManager.DeleverageStruct memory deleverageData
    ) internal override {
        assets = _removeExitFeeFromAssets(assets);
        deleverageData.collateralAmount = assets;
        super._processPositionManagerRedemption(
            owner,
            assets,
            shares,
            balancePrior,
            deleverageData
        );
    }

    /// @notice Efficient internal calculation of `assets`
    ///         with corresponding exit fee removed.
    /// @param assets The number of assets to remove exit fee from.
    /// @return The number of assets remaining after removing the exit fee.
    function _removeExitFeeFromAssets(
        uint256 assets
    ) internal view returns (uint256) {
        // Rounds up with an enforced minimum of assets = 1,
        // so this can never underflow.
        return assets - FixedPointMathLib.mulDivUp(exitFee, assets, WAD);
    }

    /// @notice Processes a withdrawal of `shares` from the market by burning
    ///         `owner` shares and transferring `assets` minus proportional
    ///         `exitFee` to `to`, then  decreases `ta` by post exit fee
    ///         `assets`, and vests rewards if `pending` > 0.
    /// @param by The account that is executing the withdrawal.
    /// @param to The account that should receive `assets`.
    /// @param owner The account that will have `shares` burned to withdraw `assets`.
    /// @param assets The amount of the underlying asset to withdraw,
    ///               prior to exit fee being applied.
    /// @param shares The amount of shares redeemed from `owner`.
    function _processWithdraw(
        address by,
        address to,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        // We remove the fees directly from the assets a user,
        // will receive distributing fee paid to all users.
        assets = _removeExitFeeFromAssets(assets);
        super._processWithdraw(by, to, owner, assets, shares);
    }

    /// @notice Helper function for setting the exit fee on redemption
    ///         of shares for assets.
    /// @dev Parameter passed in basis points and converted to `WAD`.
    ///      Has a maximum value of `MAXIMUM_EXIT_FEE`.
    /// @param newExitFee The new exit fee to set for redemption of assets,
    ///                   in basis points.
    function _setExitFee(uint256 newExitFee) internal {
        // Convert `newExitFee` parameter from `basis points` to `WAD`.
        newExitFee = _bpToWad(newExitFee);

        // Check if the proposed exit fee is above the allowed maximum.
        if (newExitFee > MAXIMUM_EXIT_FEE) {
            revert StrategyCTokenWithExitFee__InvalidExitFee();
        }

        // Cache the old exit fee for event emission.
        uint256 oldExitFee = exitFee;

        // Set new exit fee.
        exitFee = newExitFee;
        emit ExitFeeSet(oldExitFee, newExitFee);
    }

    /// @notice Multiplies `value` by 1e14 to convert it from `basis points`
    ///         to WAD.
    /// @dev Internal helper function for easily converting between scalars.
    /// @param value The value to convert from basis points to WAD.
    /// @return The value in WAD.
    function _bpToWad(uint256 value) internal pure returns (uint256) {
        return value * 1e14;
    }
}
