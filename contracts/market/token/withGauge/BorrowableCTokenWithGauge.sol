// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

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

    /// @param centralRegistry_ The address of the Protocol Central Registry.
    /// @param asset_ The address of the underlying asset for this cToken.
    /// @param marketManager_ The address of the MarketManager which manages
    ///                       liquidity positions between linked cTokens
    ///                       inside a joint market.
    /// @param interestRateModel_ The address of the interest rate model to
    ///                           manage outstanding loans.
    constructor(
        ICentralRegistry centralRegistry_,
        IERC20 asset_,
        address marketManager_,
        address interestRateModel_
    )
        BorrowableCToken(
            centralRegistry_,
            asset_,
            marketManager_,
            interestRateModel_
        )
    {
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
        // Update Gauge Manager values for `from`.
        gaugeManager.withdraw(address(this), from, shares);

        // Update Gauge Manager values for `to`.
        gaugeManager.deposit(address(this), to, shares);
    }
}
