//SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";

import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

import { IWETH } from "contracts/interfaces/IWETH.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";
import { IMToken } from "contracts/interfaces/IMToken.sol";

/// @title Curvance Universal Balance for Native Gas Tokens
/// @notice A specialized system for managing native gas tokens within the Curvance Protocol
/// @dev NativeUniversalBalance extends the Universal Balance system to provide native 
///      gas token support (ETH, MATIC, etc.) with automatic wrapping/unwrapping:
///      
///      1. Native Token Operations:
///         - Seamlessly handles deposits of native gas tokens with auto-wrapping
///         - Provides native withdrawal functionality with automatic unwrapping
///         - Supports receiving native tokens directly via the receive() function
///      
///      2. Enhanced Functionality:
///         - All core Universal Balance features (sitting/lent balances)
///         - Specialized native token deposit/withdraw methods with recipient specification
///         - Multi-user batch operations for gas-efficient management
///      
///      3. Integration Points:
///         - Coordinates with wrapped native token contracts (WETH, WMATIC, etc.)
///         - Supports Oracle Manager for on-demand funding of oracle updates
///         - Validates that EToken underlying matches the wrapped native token
///      
///      Implementation carefully handles the wrapping/unwrapping of native tokens while
///      maintaining the full feature set of the standard Universal Balance system.
///      Refunds unused deposit amounts when processing batch operations.
///
contract NativeUniversalBalance is UniversalBalance {
    /// ERRORS ///

    error NativeUniversalBalance__UnderlyingTokenMismatch();

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address eToken,
        address nativeWrappedToken
    ) UniversalBalance(centralRegistry_, eToken) {
        // Validate that eToken underlying and native wrapped token
        // contract match addresses.
        if (IMToken(eToken).asset() != nativeWrappedToken) {
            revert NativeUniversalBalance__UnderlyingTokenMismatch();
        }
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Allows contract to receive native gas tokens.
    receive() external payable {
        if (msg.sender != underlying) {
            IWETH(underlying).deposit{ value: msg.value }();
            // We default to a sitting balance deposit due to small gas
            // allowance on .transfer calls.
            _deposit(msg.value, false, msg.sender);
        }
    }

    /// @notice Deposits native gas token into user's Universal Balance
    ///         account, either to be held or lent out.
    /// @dev Emits { Deposit } event. The amount of native token to be
    ///      deposited is attached to the transaction.
    /// @param isLent Whether the deposited native tokens should be lent
    ///               out inside Curvance Protocol (as wrapped native).
    function depositNative(bool isLent) external payable {
        IWETH(underlying).deposit{ value: msg.value }();
        _deposit(msg.value, isLent, msg.sender);
    }

    /// @notice Deposits native gas token into `recipient`'s Universal Balance
    ///         account, either to be held or lent out.
    /// @dev Requires that `recipient` has approved the caller previously to
    ///      access their Universal Balance. The amount of native token to be
    ///      deposited is attached to the transaction.
    ///      Emits { Deposit } event.
    /// @param isLent Whether the deposited native tokens should be lent
    ///               out inside Curvance Protocol (as wrapped native).
    /// @param recipient The account who will receive the deposit.
    function depositNativeFor(
        bool isLent,
        address recipient
    ) external payable {
        _checkDelegate(recipient, msg.sender);

        IWETH(underlying).deposit{ value: msg.value }();
        _deposit(msg.value, isLent, recipient);
    }

    /// @notice Deposits native gas token into `recipient`'s Universal Balance
    ///         account, either to be held or lent out.
    /// @dev Requires that all `recipients` has approved the caller previously
    ///      to access their Universal Balance. The amount of native token to be
    ///      deposited is attached to the transaction.
    ///      Emits one or more { Deposit } event(s).
    /// @param amounts An array containing the amount of native token to
    ///                be deposited to each account.
    /// @param willLend An array containing whether the deposited native
    ///                 tokens should be lent out inside Curvance Protocol for
    ///                 each account.
    /// @param recipients An array containing the accounts who will receive a
    ///                   deposit based on their matching `amounts` value.
    function multiDepositNativeFor(
        uint256[] calldata amounts,
        bool[] calldata willLend,
        address[] calldata recipients
    ) external payable {
        IWETH(underlying).deposit{ value: msg.value }();

        uint256 unusedDeposit = _multiDepositFor(
            msg.value,
            amounts,
            willLend,
            recipients
        );

        // Reimburse any unused deposit amount.
        if (unusedDeposit > 0) {
            IWETH(underlying).withdraw(unusedDeposit);
            SafeTransferLib.safeTransferETH(msg.sender, unusedDeposit);
        }
    }

    /// @notice Withdraws wrapped native token from user's Universal Balance
    ///         account, either currently held or lent out and transfers it
    ///         to the user in native form.
    /// @dev Emits { Withdraw } event.
    /// @param amount The amount of native token to be withdrawn.
    /// @param forceLentRedemption Whether the withdrawn underlying tokens
    ///                            should be pulled only from `owner`'s lent
    ///                            position or the full account.
    /// @param recipient The account who will receive the underlying assets.
    /// @return amountWithdrawn The amount of underlying token withdrawn.
    /// @return lendingBalanceUsed Whether the withdrawn underlying tokens
    ///                            were pulled from the lent balance.
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
    ///      access their Universal Balance.
    ///      Emits { Withdraw } event.
    /// @param amount The amount of native token to be withdrawn.
    /// @param forceLentRedemption Whether the withdrawn underlying tokens
    ///                            should be pulled only from `owner`'s lent
    ///                            position or the full account.
    /// @param recipient The account who will receive the native token.
    /// @param owner The account that will redeem from their universal
    ///              balance.
    /// @return amountWithdrawn The amount of native token withdrawn.
    /// @return lendingBalanceUsed Whether the withdrawn underlying tokens
    ///                            were pulled from the lent balance.
    function withdrawNativeFor(
        uint256 amount,
        bool forceLentRedemption,
        address recipient,
        address owner
    ) external returns (uint256 amountWithdrawn, bool lendingBalanceUsed) {
        _checkDelegate(owner, msg.sender);
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

    /// @notice Withdraws native gas token from `owners` Universal Balance
    ///         accounts, currently held or lent out.
    /// @dev Requires that each `owners` has approved the caller previously to
    ///      access their Universal Balance.
    ///      Emits one or more { Withdraw } event(s).
    /// @param amounts An array containing the amount of native token to
    ///                be withdrawn from each account.
    /// @param forceLentRedemption An array containing whether the withdrawn
    ///                            underlying tokens should be pulled only
    ///                            from an `owners` lent position or the full
    ///                            account.
    /// @param recipient The account who will receive the native assets.
    /// @param owners An array containing the accounts that will redeem from
    ///               their Universal Balance.
    function multiWithdrawNativeFor(
        uint256[] calldata amounts,
        bool[] calldata forceLentRedemption,
        address recipient,
        address[] calldata owners
    ) external {
        uint256 withdrawSum = _multiWithdrawFor(
            amounts,
            forceLentRedemption,
            recipient,
            owners
        );

        // No need to transfer wrapped native tokens out as we need to
        // withdraw them from wrapper contract and then transfer native
        // tokens to `recipient`.
        IWETH(underlying).withdraw(withdrawSum);
        SafeTransferLib.safeTransferETH(recipient, withdrawSum);
    }

    /// @notice Used by Oracle Manager to fund a pull-based oracle update.
    /// @param owner Which user is funding the oracle update from their
    ///              Universal Balance account.
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

        // Withdraw from `owner`'s Universal Balance and transfer the wrapped
        // native tokens to the Oracle Adaptor for use in updating oracle
        // feed.
        (amount, ) = _withdraw(amount, false, owner);

        // Transfer the withdrawn tokens to the oracle adaptor.
        SafeTransferLib.safeTransfer(underlying, msg.sender, amount);
    }
}
