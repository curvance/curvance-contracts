// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BasePToken } from "contracts/market/token/BasePToken.sol";
import { IGaugeManager } from "contracts/interfaces/IGaugeManager.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @notice Vault Positions must have all assets ready for withdraw,
///         IE assets can NOT be locked.
///         This way assets can be easily liquidated when loans default.
/// @dev Curvance's pTokens are ERC4626 compliant. However, they follow their
///      own design flow modifying underlying mechanisms such as totalAssets
///      following a vesting mechanism in compounding vaults but a direct
///      conversion in basic or "primitive" vaults.
///
///      The "pToken" employs two different methods of engaging with the
///      Curvance protocol. Users can deposit an unlimited amount of assets,
///      which may or may not benefit from some form of auto compounded yield.
///
///      Users can at any time, choose to "post" their pTokens as collateral
///      inside the Curvance Protocol, unlocking their ability to borrow
///      against these assets. Posting collateral carries restrictions,
///      not all assets inside Curvance can be collateralized, and if they
///      can, they have a "Collateral Cap" which restricts the total amount of
///      exogeneous risk introduced by each asset into the system.
///      Rehypothecation of collateral assets has also been removed from the
///      system, reducing the likelihood of introducing systematic risk to the
///      broad DeFi landscape.
///
///      These caps can be updated as needed by the DAO and should be
///      configured based on "sticky" onchain liquidity in the corresponding
///      asset.
///
///      The vaults can have their compounding, minting, or redemption
///      functionality paused. Modifying the maximum mint, deposit,
///      withdrawal, or redemptions possible.
///
///      "Safe" versions of functions have been added that introduce
///      additional reentry and update protection logic to minimize risks
///      when integrating Curvance into external protocols.
///
///      All token deposits are recorded in the protocol "Gauge Manager"
///      facilitating the distribution of native tokens both liquid and
///      locked to users based on their contributions to the protocol over
///      time.
abstract contract BasePTokenWithGauge is BasePToken {
    /// CONSTANTS ///

    /// @notice Address of the Gauge Manager.
    IGaugeManager public immutable gaugeManager;

    /// ERRORS ///

    error BasePToken__InvalidGaugeManager();

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        IERC20 asset_,
        address marketManager_
    ) BasePToken(centralRegistry_, asset_, marketManager_) {
        address gaugeManagerAddress = centralRegistry.gaugeManager();

        // Validate Gauge Manager has been set.
        if (gaugeManagerAddress == address(0)) {
            revert BasePToken__InvalidGaugeManager();
        }
        // Set `gaugeManager`.
        gaugeManager = IGaugeManager(gaugeManagerAddress);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice An optional set of instructions to execute before processing
    ///         a deposit of `receiver`'s shares.
    /// @param receiver The account that should receive the pToken shares.
    /// @param shares The amount of pToken shares received by `receiver`.
    function _afterDepositAction(
        address receiver,
        uint256 shares
    ) internal override {
        // Update Gauge Manager values for `receiver`.
        gaugeManager.deposit(address(this), receiver, shares);
    }

    /// @notice An optional set of instructions to execute before processing
    ///         a withdrawal of `owners`'s shares.
    /// @param owner The account that will burn their shares to withdraw
    ///              assets.
    /// @param shares The amount of assets, quoted in shares received
    ///               by `receiver`.
    function _beforeWithdrawAction(
        address owner,
        uint256 shares
    ) internal override {
        // Update Gauge Manager values for `owner`.
        gaugeManager.withdraw(address(this), owner, shares);
    }

    /// @notice An optional set of instructions to execute before processing
    ///         a transfer of `from`'s shares to `to`.
    /// @param from The address of the account transferring `amount`
    ///             shares from.
    /// @param to The address of the destination account to receive `amount`
    ///           shares.
    /// @param shares The number of shares to transfer from `from` to `to`.
    function _beforeTransferAction(
        address from,
        address to,
        uint256 shares
    ) internal override {
        _checkZeroAmount(shares);
        // Update Gauge Manager values for `from`.
        gaugeManager.withdraw(address(this), from, shares);

        // Update Gauge Manager values for `to`.
        gaugeManager.deposit(address(this), to, shares);
    }

    /// @notice An optional set of instructions to execute before processing
    ///         liquidation of `account`'s collateral.
    /// @param account The account having collateral seized.
    /// @param liquidator The account receiving seized collateral.
    /// @param shares The total number of pTokens shares to seize.
    function _beforeLiquidationAction(
        address account,
        address liquidator,
        uint256 shares
    ) internal override {
        // Process virtual balance updates and accrued rewards from this
        // liquidation.
        gaugeManager.processLiquidation(
            address(this),
            account,
            liquidator,
            shares
        );
    }
}
