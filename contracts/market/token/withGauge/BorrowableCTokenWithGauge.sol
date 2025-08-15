// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

import { IGaugeManager } from "contracts/interfaces/IGaugeManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @dev All token deposits are recorded in the protocol "Gauge Manager"
///      facilitating the distribution of native tokens both liquid and
///      locked to users based on their contributions to the protocol over
///      time.
contract BorrowableCTokenWithGauge is BorrowableCToken {
    /// CONSTANTS ///

    /// @notice Address of the Gauge Manager.
    IGaugeManager public immutable gaugeManager;

    /// ERRORS ///

    error BorrowableCTokenWithGauge__InvalidGaugeManager();

    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
    /// @param asset_ The address of the underlying asset for this cToken.
    /// @param mm The address of the MarketManager which manages liquidity
    ///           positions between linked cTokens inside a joint market.
    /// @param IRM_ The interest rate model to determine interest
    ///             paid by borrowers to lenders for outstanding debt.
    constructor(
        ICentralRegistry cr,
        IERC20 asset_,
        address mm,
        address IRM_
    ) BorrowableCToken(cr, asset_, mm, IRM_) {
        address gaugeManagerAddress = centralRegistry.gaugeManager();

        // Validate Gauge Manager has been set.
        if (gaugeManagerAddress == address(0)) {
            revert BorrowableCTokenWithGauge__InvalidGaugeManager();
        }
        // Set `gaugeManager`.
        gaugeManager = IGaugeManager(gaugeManagerAddress);
    }

    /// @notice An optional set of instructions to execute before processing
    ///         a deposit of `receiver`'s shares.
    /// @param shares The amount of cToken shares received by `receiver`.
    /// @param receiver The account that should receive the cToken shares.
    function _afterDepositAction(
        uint256 shares,
        address receiver
    ) internal override {
        // Update Gauge Manager values for `receiver`.
        gaugeManager.deposit(address(this), receiver, shares);
    }

    /// @notice An optional set of instructions to execute before processing
    ///         a withdrawal of `owners`'s shares.
    /// @param shares The amount of assets, quoted in shares received
    ///               by `receiver`.
    /// @param owner The account that will burn their shares to withdraw
    ///              assets.
    function _beforeWithdrawAction(
        uint256 shares,
        address owner
    ) internal override {
        // Update Gauge Manager values for `owner`.
        gaugeManager.withdraw(address(this), owner, shares);
    }

    /// @notice An optional set of instructions to execute before processing
    ///         a transfer of `from`'s shares to `to`.
    /// @param shares The number of shares to transfer from `owner` to
    ///               `receiver`.
    /// @param receiver The address of the destination account to receive
    ///                 `shares` shares.
    /// @param owner The address of the account transferring `shares`
    ///             shares from.
    function _beforeTransferAction(
        uint256 shares,
        address receiver,
        address owner
    ) internal override {
        // Update Gauge Manager values for `owner`.
        gaugeManager.withdraw(address(this), owner, shares);

        // Update Gauge Manager values for `receiver`.
        gaugeManager.deposit(address(this), receiver, shares);
    }

    /// @notice An optional set of instructions to execute before processing
    ///         liquidation of `account`'s collateral.
    /// @param account The account having collateral seized.
    /// @param liquidator The account receiving seized collateral.
    /// @param shares The total number of cTokens shares to seize.
    function _beforeLiqAction(
        uint256 shares,
        address liquidator,
        address account
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
