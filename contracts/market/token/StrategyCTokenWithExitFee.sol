// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { StrategyCToken, ICentralRegistry, IERC20 } from "contracts/market/token/StrategyCToken.sol";

import { WAD } from "contracts/libraries/Constants.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { IPositionManager } from "contracts/interfaces/IPositionManager.sol";

/// @dev `Asset()` Positions must have all assets ready for withdraw,
///      IE assets can NOT be locked.
///      This way assets can be easily liquidated when loans default.
///
///      Each Curvance strategy run must be a LOSSLESS position, since
///      totalAssets is not actually using the balances stored in the
///      contract, rather it only uses an internal balance.
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

    /// @param cr The address of the Protocol Central Registry.
    /// @param asset_ The address of the underlying asset for this cToken.
    /// @param mm The address of the MarketManager which manages liquidity
    ///           positions between linked cTokens inside a joint market.
    /// @param vestingPeriod_ The length of time a vesting period will last,
    ///                       in seconds.
    /// @param exitFee_ The exit fee paid by users when withdrawing from the
    ///                 strategyCToken position, in basis points.
    constructor(
        ICentralRegistry cr,
        IERC20 asset_,
        address mm,
        uint256 vestingPeriod_,
        uint256 exitFee_
    ) StrategyCToken(cr, asset_, mm, vestingPeriod_) {
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

    /// @notice Used by a Position Manager contract to redeem assets from
    ///         collateralized shares by `account` to perform a complex
    ///         action.
    /// @param assets The amount of the underlying assets to redeem.
    /// @param shares The amount of the shares to redeem.
    /// @param owner The owner address of assets to redeem.
    /// @param balancePrior The balance of shares `owner` has before this
    ///                     redemption. 
    /// @param action Instructions for a deleverage action containing:
    ///               cToken Address of the cToken that will be redeemed from
    ///                      and assets swapped into `borrowableCToken` asset.
    ///               collateralAssets The amount of `cToken` that will be
    ///                                deleveraged, in assets.
    ///               borrowableCToken Address of the borrowableCToken that
    ///                                will have its debt paid.
    ///               repayAssets The amount of `borrowableCToken` asset that
    ///                           will be repaid to lenders.
    ///               swapAction Swap actions instructions converting
    ///                          collateral asset into debt asset to
    ///                          facilitate deleveraging.
    ///               auxData Optional auxiliary data for execution of a
    ///                       deleverage action.
    function _processPositionManagerRedemption(
        uint256 assets,
        uint256 shares,
        address owner,
        uint256 balancePrior,
        IPositionManager.DeleverageAction memory action
    ) internal override {
        assets = _removeExitFeeFromAssets(assets);
        action.collateralAssets = assets;
        super._processPositionManagerRedemption(
            assets,
            shares,
            owner,
            balancePrior,
            action
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
    ///         `exitFee` to `receiver`, then  decreases `ta` by post exit fee
    ///         `assets`, and vests rewards if `pending` > 0.
    /// @param assets The amount of the underlying asset to withdraw,
    ///               prior to exit fee being applied.
    /// @param shares The amount of shares redeemed from `owner`.
    /// @param by The account that is executing the withdrawal.
    /// @param receiver The account that should receive `assets`.
    /// @param owner The account that will have `shares` burned to withdraw
    ///              `assets`.
    function _processWithdraw(
        uint256 assets,
        uint256 shares,
        address by,
        address receiver,
        address owner
    ) internal override {
        // We remove the fees directly from the assets a user,
        // will receive distributing fee paid to all users.
        assets = _removeExitFeeFromAssets(assets);
        super._processWithdraw(assets, shares, by, receiver, owner);
    }

    /// @notice Helper function for setting the exit fee on redemption
    ///         of shares for assets.
    /// @dev Parameter passed in basis points and converted to `WAD`.
    ///      Has a maximum value of `MAXIMUM_EXIT_FEE`.
    /// @param newExitFee The new exit fee to set for redemption of assets,
    ///                   in basis points.
    function _setExitFee(uint256 newExitFee) internal {
        // Convert `newExitFee` parameter from `basis points` to `WAD`.
        newExitFee = newExitFee * 1e14;

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
}
