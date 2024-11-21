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
            IWETH(underlying).deposit{ value: msg.value };
            // We false a sitting balance due to small gas allowance
            // on .transfer calls.
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
    /// @param isLent Whether the withdrawn wrapped native tokens should be
    ///               pulled from a user's lent position or held position
    ///               inside Curvance Protocol.
    /// @param recipient The account who will receive the underlying assets.
    function withdrawNative(
        uint256 amount,
        bool isLent,
        address recipient
    ) external {
        (amount, ) = _withdraw(amount, isLent, address(this), msg.sender);
        IWETH(underlying).withdraw(amount);
        SafeTransferLib.safeTransferETH(recipient, amount);

        emit Withdraw(msg.sender, recipient, msg.sender, amount, amount);
    }

    /// @notice Withdraws wrapped native token from `owner`'s universal
    ///         balance account, either currently held or lent out and
    ///         transfers it to the user in native form.
    /// @dev Requires that `owner` has approved the caller previously to
    ///      access their universal balance.
    ///      Emits { Withdraw } event.
    /// @param amount The amount of native token to be withdrawn.
    /// @param isLent Whether the withdrawn wrapped native tokens should be
    ///               pulled from a user's lent position or held position
    ///               inside Curvance Protocol.
    /// @param recipient The account who will receive the underlying assets.
    /// @param owner The account that will redeem from their universal balance.
    function withdrawNativeFor(
        uint256 amount,
        bool isLent,
        address recipient,
        address owner
    ) external {
        _checkDelegation(owner);

        (amount, ) = _withdraw(amount, isLent, address(this), owner);
        IWETH(underlying).withdraw(amount);
        SafeTransferLib.safeTransferETH(recipient, amount);

        emit Withdraw(msg.sender, recipient, owner, amount, amount);
    }

    /// @notice Used by Oracle Manager to fund a pull-based oracle update.
    /// @param user Which user is funding the oracle update from their universal
    ///             balance account.
    /// @param amount The amount of underlying token to be earmarked for
    ///               oracle update.
    function useBalanceForOracleUpdate(address user, uint256 amount) external {
        // Validate an approved adaptor is calling the function.
        if (
            !IOracleManager(centralRegistry.oracleManager()).isApprovedAdaptor(
                msg.sender
            )
        ) {
            revert UniversalBalance__Unauthorized();
        }

        UserBalance memory userBalance = userBalances[user];
        uint256 exchangeRate = linkedEToken.exchangeRateWithUpdate();
        uint256 pointerAmount;
        uint256 remainingAmount = amount;

        if (
            userBalance.sittingBalance +
                FixedPointMathLib.mulDiv(
                    userBalance.lentBalance,
                    exchangeRate,
                    WAD
                ) <
            amount
        ) {
            revert UniversalBalance__InsufficientBalance();
        }

        if (userBalance.sittingBalance > 0) {
            pointerAmount = userBalance.sittingBalance < amount
                ? userBalance.sittingBalance
                : amount;
            // Reduce user sitting balance.
            userBalances[user].sittingBalance -= pointerAmount;
            remainingAmount -= pointerAmount;
        }

        // Check if lent balance needs to be utilized.
        // Will natively fail if utilization is at 100%.
        if (remainingAmount > 0) {
            pointerAmount = FixedPointMathLib.mulDivUp(
                remainingAmount,
                WAD,
                exchangeRate
            );
            // Decrement user lent balance.
            userBalances[user].lentBalance -= pointerAmount;

            pointerAmount = linkedEToken.redeem(pointerAmount, address(this));

            // Make sure enough was redeemed.
            if (pointerAmount < remainingAmount) {
                revert UniversalBalance__SlippageError();
            }
        }

        // Transfer the wrapped native tokens to the Oracle Adaptor for use
        // in updating oracle feed.
        SafeTransferLib.safeTransfer(underlying, msg.sender, amount);
    }
}
