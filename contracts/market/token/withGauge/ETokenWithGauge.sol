// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { EToken } from "contracts/market/token/EToken.sol";

import { IGaugeManager } from "contracts/interfaces/IGaugeManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @title Curvance's Earn Token Contract.
/// @dev Curvance's eTokens are ERC20 compliant with a close relation
///      to ERC4626. However, they follow their own design flow, without an
///      inherited base contract. This is done intentionally, to maximize
///      security in an age of rapidly developing security attack vectors.
///
///      The "eToken" employs a share/asset structure with slightly different
///      configuration, and terminology (to prevent confusion). The variable
///      terms "tokens", and "amount" are used to refer to eTokens values,
///      and underlying asset values. When you see "Tokens" that is associated
///      with eTokens, when you see "amount" that is associated with
///      underlying assets.
///
///      Users who have active positions inside a eToken are referred to
///      as accounts. For actions that can be performed by an external party,
///      that will not result in active positions for themselves, more general
///      terms are used such as "Liquidator", "Minter", or "Payer".
///
///      "Safe" versions of functions have been added that introduce
///      additional reentry and update protection logic to minimize risks
///      when integrating Curvance into external protocols.
///
///      All token deposits are recorded in the protocol "Gauge Manager"
///      facilitating the distribution of native tokens both liquid and
///      locked to users based on their contributions to the protocol over
///      time.
contract ETokenWithGauge is EToken {
    /// CONSTANTS ///

    /// @notice Address of the Gauge Manager.
    IGaugeManager public immutable gaugeManager;

    /// ERRORS ///

    error EToken__InvalidGaugeManager();

    /// CONSTRUCTOR ///

    /// @param centralRegistry_ The address of Curvances Central Registry.
    /// @param underlying_ The address of the underlying asset
    ///                    for this eToken.
    /// @param marketManager_ The address of the MarketManager.
    /// @param interestRateModel_ The address of the interest rate model.
    constructor(
        ICentralRegistry centralRegistry_,
        address underlying_,
        address marketManager_,
        address interestRateModel_
    )
        EToken(
            centralRegistry_,
            underlying_,
            marketManager_,
            interestRateModel_
        )
    {
        address gaugeManagerAddress = centralRegistry.gaugeManager();

        // Validate Gauge Manager has been set.
        if (gaugeManagerAddress == address(0)) {
            revert EToken__InvalidGaugeManager();
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
