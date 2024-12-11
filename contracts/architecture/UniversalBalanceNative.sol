//SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";

import { WAD } from "contracts/libraries/Constants.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { IWETH } from "contracts/interfaces/IWETH.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";
import { IMToken } from "contracts/interfaces/IMToken.sol";

/// @title Curvance Universal Balance for a chain's native gas token.
/// @notice A system for managing a Universal Balance within the Curvance
///         Protocol.
contract UniversalBalanceNative is UniversalBalance {
    receive() external payable {
        if (msg.sender != underlying) {
            IWETH(underlying).deposit{ value: msg.value }();
            // We default to a sitting balance deposit due to small gas
            // allowance on .transfer calls.
            _deposit(msg.value, false, msg.sender);
        }
    }

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address eToken,
        address underlying_
    ) UniversalBalance(centralRegistry_, eToken) {
        // Validate that eToken underlying and native wrapped token
        // contract match addresses.
        if (IMToken(eToken).underlying() != underlying_) {
            revert UniversalBalance__UnderlyingTokenMismatch();
        }
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Deposits native gas token into user's universal balance
    ///         account, either to be held or lent out.
    /// @dev Emits { Deposit } event. The amount of native token to be
    ///      deposited is attached to the transaction.
    /// @param isLent Whether the deposited native tokens should be lent
    ///               out inside Curvance Protocol (as wrapped native).
    function depositNative(bool isLent) external payable {
        IWETH(underlying).deposit{ value: msg.value }();
        _deposit(msg.value, isLent, msg.sender);
    }

    /// @notice Deposits native gas token into `recipient`'s universal balance
    ///         account, either to be held or lent out.
    /// @dev Requires that `recipient` has approved the caller previously to
    ///      access their universal balance. The amount of native token to be
    ///      deposited is attached to the transaction.
    ///      Emits { Deposit } event.
    /// @param isLent Whether the deposited native tokens should be lent
    ///               out inside Curvance Protocol (as wrapped native).
    /// @param recipient The account who will receive the deposit.
    function depositNativeFor(
        bool isLent,
        address recipient
    ) external payable {
        _checkDelegation(recipient);

        IWETH(underlying).deposit{ value: msg.value }();
        _deposit(msg.value, isLent, recipient);
    }

    /// @notice Withdraws wrapped native token from user's universal balance
    ///         account, either currently held or lent out and transfers it
    ///         to the user in native form.
    /// @dev Emits { Withdraw } event.
    /// @param amount The amount of native token to be withdrawn.
    /// @param forceLentRedemption Whether the withdrawn underlying tokens
    ///                            should be pulledonly from `owner`'s lent
    ///                            position or the full account.
    /// @param recipient The account who will receive the underlying assets.
    function withdrawNative(
        uint256 amount,
        bool forceLentRedemption,
        address recipient
    ) external returns (uint256 amountWithdrawn, bool lendingBalanceUsed) {
        (amountWithdrawn, lendingBalanceUsed) = _withdraw(
            amount,
            forceLentRedemption,
            msg.sender
        );

        // No need to transfer wrapped native tokens out as we need to
        // withdraw them from wrapper contract and then transfer native
        // tokens to `recipient`.
        IWETH(underlying).withdraw(amountWithdrawn);
        SafeTransferLib.safeTransferETH(recipient, amountWithdrawn);

        emit Withdraw(
            msg.sender,
            recipient,
            msg.sender,
            amountWithdrawn,
            lendingBalanceUsed
        );
    }

    /// @notice Withdraws wrapped native token from `owner`'s universal
    ///         balance account, either currently held or lent out and
    ///         transfers it to the user in native form.
    /// @dev Requires that `owner` has approved the caller previously to
    ///      access their universal balance.
    ///      Emits { Withdraw } event.
    /// @param amount The amount of native token to be withdrawn.
    /// @param forceLentRedemption Whether the withdrawn underlying tokens
    ///                            should be pulledonly from `owner`'s lent
    ///                            position or the full account.
    /// @param recipient The account who will receive the underlying assets.
    /// @param owner The account that will redeem from their universal
    ///              balance.
    function withdrawNativeFor(
        uint256 amount,
        bool forceLentRedemption,
        address recipient,
        address owner
    ) external returns (uint256 amountWithdrawn, bool lendingBalanceUsed) {
        _checkDelegation(owner);
        (amountWithdrawn, lendingBalanceUsed) = _withdraw(
            amount,
            forceLentRedemption,
            owner
        );

        // No need to transfer wrapped native tokens out as we need to
        // withdraw them from wrapper contract and then transfer native
        // tokens to `recipient`.
        IWETH(underlying).withdraw(amountWithdrawn);
        SafeTransferLib.safeTransferETH(recipient, amountWithdrawn);

        emit Withdraw(
            msg.sender,
            recipient,
            owner,
            amountWithdrawn,
            lendingBalanceUsed
        );
    }

    /// @notice Used by Oracle Manager to fund a pull-based oracle update.
    /// @param owner Which user is funding the oracle update from their
    ///              universal balance account.
    /// @param amount The amount of underlying token to be earmarked for
    ///               oracle update.
    function useBalanceForOracleUpdate(
        address owner,
        uint256 amount
    ) external {
        // Validate an approved adaptor is calling the function.
        if (
            !IOracleManager(centralRegistry.oracleManager()).isApprovedAdaptor(
                msg.sender
            )
        ) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        // Withdraw from `owner`'s universal balance and transfer the wrapped
        // native tokens to the Oracle Adaptor for use in updating oracle
        // feed.
        (amount, ) = _withdraw(amount, false, owner);

        // Transfer the withdrawn tokens to the oracle adaptor.
        SafeTransferLib.safeTransfer(underlying, msg.sender, amount);
    }
}
