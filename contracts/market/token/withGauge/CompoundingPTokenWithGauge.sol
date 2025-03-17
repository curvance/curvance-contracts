// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { CompoundingPToken } from "contracts/market/token/CompoundingPToken.sol";

import { IGaugeManager } from "contracts/interfaces/IGaugeManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

/// @notice Vault Positions must have all assets ready for withdraw,
///         IE assets can NOT be locked.
///         This way assets can be easily liquidated when loans default.
/// @dev The PToken vaults run must be a LOSSLESS position, since totalAssets
///      is not actually using the balances stored in the contract,
///      rather it only uses an internal balance.
///
///      All token deposits are recorded in the protocol "Gauge Manager"
///      facilitating the distribution of native tokens both liquid and
///      locked to users based on their contributions to the protocol over
///      time.
abstract contract CompoundingPTokenWithGauge is CompoundingPToken {
    /// CONSTANTS ///

    /// @notice Address of the Gauge Manager.
    IGaugeManager public immutable gaugeManager;

    /// ERRORS ///

    error CompoundingPTokenWithGauge__InvalidGaugeManager();

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        IERC20 asset_,
        address marketManager_
    ) CompoundingPToken(centralRegistry_, asset_, marketManager_) {
        address gaugeManagerAddress = centralRegistry.gaugeManager();

        // Validate Gauge Manager has been set.
        if (gaugeManagerAddress == address(0)) {
            revert CompoundingPTokenWithGauge__InvalidGaugeManager();
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
