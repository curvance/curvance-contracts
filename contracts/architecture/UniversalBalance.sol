//SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";
import { RescueLib } from "contracts/libraries/RescueLib.sol";
import { WAD } from "contracts/libraries/Constants.sol";

import { ReentrancyGuard } from "contracts/libraries/external/ReentrancyGuard.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IActionRegistry } from "contracts/interfaces/IActionRegistry.sol";
import { IPluginDelegable } from "contracts/interfaces/IPluginDelegable.sol";

/// @title Curvance Universal Balance
/// @notice A user-facing system for flexible token management within the Curvance Protocol
/// @dev Universal Balance provides a comprehensive solution for users to manage their token
///      positions with multiple options for utilization:
///      
///      1. Asset Management:
///         - Front-facing contract for users to deposit and withdraw tokens (e.g., USDC)
///         - Maintains two balance types per user: sitting (held) and lent (deployed)
///         - Token-specific implementation linked to corresponding
///           BorrowableCToken contract.
///      
///      2. Position Flexibility:
///         - Users can freely shift balances between sitting and lent states
///         - Lent balances earn yield through Curvance's lending protocols
///         - Sitting balances remain liquid and immediately available
///      
///      3. Social Features:
///         - Users can transfer portions of their balance to other users
///         - Supports delegated account operations with permission system
///         - Multi-user batch operations for efficient management
///      
///      Implementation uses a non-custodial design where users maintain full control
///      of their assets while benefiting from integrated position management.
///      Lent balances are represented as shares/tokens of the underlying
///      BorrowableCToken.
///
contract UniversalBalance is PluginDelegable, ReentrancyGuard {
    /// TYPES ///

    /// @title User Balance
    /// @notice Stores user-specific balance information within the 
    /// @notice             Universal Balance system.
    /// @param sittingBalance The amount of tokens currently held in 
    ///                     the user's Universal Balance but 
    ///                     not lent out.
    /// @param lentBalance The amount of tokens the user has lent out.
    struct UserBalance {
        uint256 sittingBalance;
        uint256 lentBalance;
    }

    /// CONSTANTS ///

    /// @notice The address of the token linked to this contract.
    IBorrowableCToken public immutable linkedToken;

    /// @notice The address of Universal Balance underlying token.
    address public immutable underlying;

    /// @dev `bytes4(keccak256(bytes("UniversalBalance__Unauthorized()")))`.
    uint256 internal constant _UNAUTHORIZED_SELECTOR = 0x439f5eb2;
    /// @dev `bytes4(keccak256(bytes("UniversalBalance__InvalidParameter()")))`.
    uint256 internal constant _INVALID_PARAMETER_SELECTOR = 0xc75f2a32;

    /// STORAGE ///

    /// @notice Manages a users sitting and lending balances inside
    ///         their Universal Balance account.
    /// @dev User => User's balance sitting and lent out.
    mapping(address => UserBalance) public userBalances;

    /// EVENTS ///

    /// @dev Emitted during a deposit call.
    event Deposit(
        address indexed by,
        address indexed owner,
        uint256 assets,
        bool lendingDeposit
    );

    /// @dev Emitted during a withdraw call.
    event Withdraw(
        address indexed by,
        address indexed to,
        address indexed owner,
        uint256 assets,
        bool lendingRedemption
    );

    /// ERRORS ///

    error UniversalBalance__InsufficientBalance();
    error UniversalBalance__InvalidParameter();
    error UniversalBalance__Unauthorized();
    error UniversalBalance__SlippageError();

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address borrowableCToken
    ) PluginDelegable(centralRegistry_) {
        // Validate `borrowableCToken` is actually lendable.
        if (!IBorrowableCToken(borrowableCToken).isBorrowable()) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        linkedToken = IBorrowableCToken(borrowableCToken);
        address underlying_ = IBorrowableCToken(borrowableCToken).asset();
        underlying = underlying_;

        IERC20(underlying_).approve(borrowableCToken, type(uint256).max);
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Deposits underlying token into user's Universal Balance
    ///         account, either to be held or lent out.
    /// @dev Emits { Deposit } event.
    /// @param amount The amount of underlying tokens to be deposited,
    ///               in assets.
    /// @param willLend Whether the deposited underlying tokens should be lent
    ///                 out inside Curvance Protocol.
    function deposit(uint256 amount, bool willLend) external {
        SafeTransferLib.safeTransferFrom(
            underlying,
            msg.sender,
            address(this),
            amount
        );

        _deposit(amount, willLend, msg.sender);
    }

    /// @notice Deposits underlying token into `recipient`'s Universal Balance
    ///         account, either to be held or lent out.
    /// @dev Requires that `recipient` has approved the caller previously to
    ///      access their Universal Balance.
    ///      Emits { Deposit } event.
    /// @param amount The amount of underlying tokens to be deposited,
    ///               in assets.
    /// @param willLend Whether the deposited underlying tokens should be lent
    ///                 out inside Curvance Protocol.
    /// @param recipient The account who will receive the deposit.
    function depositFor(
        uint256 amount,
        bool willLend,
        address recipient
    ) external {
        _checkDelegate(recipient, msg.sender);

        SafeTransferLib.safeTransferFrom(
            underlying,
            msg.sender,
            address(this),
            amount
        );
        _deposit(amount, willLend, recipient);
    }

    /// @notice Deposits underlying token into `recipients` Universal Balance
    ///         accounts, either to be held or lent out.
    /// @dev Requires that all `recipients` has approved the caller previously
    ///      to access their Universal Balance.
    ///      Emits one or more { Deposit } event(s).
    /// @param amounts An array containing the amount of underlying tokens to
    ///                be deposited to each account, in assets.
    /// @param willLend An array containing whether the deposited underlying
    ///                 tokens should be lent out inside Curvance Protocol for
    ///                 each account.
    /// @param recipients An array containing the accounts who will receive a
    ///                   deposit based on their matching `amounts` value.
    function multiDepositFor(
        uint256 depositSum,
        uint256[] calldata amounts,
        bool[] calldata willLend,
        address[] calldata recipients
    ) external {
        SafeTransferLib.safeTransferFrom(
            underlying,
            msg.sender,
            address(this),
            depositSum
        );

        uint256 unusedDeposit = _multiDepositFor(
            depositSum,
            amounts,
            willLend,
            recipients
        );

        // Reimburse any unused deposit amount.
        if (unusedDeposit > 0) {
            SafeTransferLib.safeTransfer(
                underlying,
                msg.sender,
                unusedDeposit
            );
        }
    }

    /// @notice Withdraws underlying token from user's Universal Balance
    ///         account, currently held or lent out.
    /// @dev Emits { Withdraw } event.
    //// @param amount The amount of underlying tokens to be withdrawn,
    ///                in assets.
    /// @param forceLentRedemption Whether the withdrawn underlying tokens
    ///                            should be pulled only from `owner`'s lent
    ///                            position or the full account.
    /// @param recipient The account who will receive the underlying assets.
    /// @return amountWithdrawn The amount of underlying token withdrawn.
    /// @return lendingBalanceUsed Whether the withdrawn underlying tokens
    ///                            were pulled from the lent balance.
    function withdraw(
        uint256 amount,
        bool forceLentRedemption,
        address recipient
    ) external returns (uint256 amountWithdrawn, bool lendingBalanceUsed) {
        (amountWithdrawn, lendingBalanceUsed) = _withdraw(
            amount,
            forceLentRedemption,
            msg.sender
        );

        // Transfer the withdrawn tokens.
        SafeTransferLib.safeTransfer(underlying, recipient, amountWithdrawn);

        emit Withdraw(
            msg.sender,
            recipient,
            msg.sender,
            amountWithdrawn,
            lendingBalanceUsed
        );
    }

    /// @notice Withdraws underlying token from `owner`'s Universal Balance
    ///         account, currently held or lent out.
    /// @dev Requires that `owner` has approved the caller previously to
    ///      access their Universal Balance.
    ///      Emits { Withdraw } event.
    /// @param amount The amount of underlying tokens to be withdrawn,
    ///               in assets.
    /// @param forceLentRedemption Whether the withdrawn underlying tokens
    ///                            should be pulled only from `owner`'s lent
    ///                            position or the full account.
    /// @param recipient The account who will receive the underlying assets.
    /// @param owner The account that will redeem from their universal
    ///              balance.
    /// @return amountWithdrawn The amount of underlying token withdrawn.
    /// @return lendingBalanceUsed Whether the withdrawn underlying tokens
    ///                            were pulled from the lent balance.
    function withdrawFor(
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

        // Transfer the withdrawn tokens.
        SafeTransferLib.safeTransfer(underlying, recipient, amountWithdrawn);

        emit Withdraw(
            msg.sender,
            recipient,
            owner,
            amountWithdrawn,
            lendingBalanceUsed
        );
    }

    /// @notice Withdraws underlying token from `owners` Universal Balance
    ///         accounts, currently held or lent out.
    /// @dev Requires that each `owners` has approved the caller previously to
    ///      access their Universal Balance.
    ///      Emits one or more { Withdraw } event(s).
    /// @param amounts An array containing the amount of underlying token to
    ///                be withdrawn from each account.
    /// @param forceLentRedemption An array containing whether the withdrawn
    ///                            underlying tokens should be pulled only
    ///                            from an `owners` lent position or the full
    ///                            account.
    /// @param recipient The account who will receive the underlying assets.
    /// @param owners An array containing the accounts that will redeem from
    ///               their Universal Balance.
    function multiWithdrawFor(
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

        // Transfer the withdrawn tokens.
        SafeTransferLib.safeTransfer(underlying, recipient, withdrawSum);
    }

    /// @notice Moves a user's Universal Balance between lent and sitting
    ///         mode.
    /// @dev Emits a { Withdraw } and { Deposit } event.
    /// @param amount The amount of underlying tokens to be shifted, in assets.
    /// @param fromLent Whether the shifted underlying tokens should be pulled
    ///                 from the user's lent balance or the full balance.
    /// @return amountWithdrawn The amount of underlying token withdrawn.
    /// @return lendingBalanceUsed Whether the withdrawn underlying tokens
    ///                            were pulled from the lent balance.
    function shiftBalance(
        uint256 amount,
        bool fromLent
    ) external returns (uint256 amountWithdrawn, bool lendingBalanceUsed) {
        // If deposited balance is shifted from sitting balance, the typical
        // workflow would be to dip into lent balance if necessary, but then
        // we'd be withdrawing and then immediately re-depositing, minimizing
        // the efficacy of shifting balance's intended functionality.
        // Therefore, a more strict check is done prior to _withdraw.
        if (!fromLent) {
            if (userBalances[msg.sender].sittingBalance < amount) {
                revert UniversalBalance__InsufficientBalance();
            }
        }

        (amountWithdrawn, lendingBalanceUsed) = _transfer(
            amount,
            fromLent,
            !fromLent,
            msg.sender,
            msg.sender
        );
    }

    /// @notice Transfers `amount` from caller's Universal Balance, currently
    ///         held or lent out to `recipient`.
    /// @dev Emits { Withdraw } and { Deposit } events.
    /// @param amount The amount of underlying token to be transferred.
    /// @param forceLentRedemption Whether the transferred underlying tokens
    ///                            should be pulled only from the caller's
    ///                            lent position or the full account.
    /// @param willLend Whether the deposited underlying tokens should be lent
    ///                 out inside Curvance Protocol.
    /// @param recipient The account who will receive the transferred balance.
    /// @return amountTransferred The amount of underlying token transferred.
    /// @return lendingBalanceUsed Whether the transferred underlying tokens
    ///                            were pulled from the lent balance.
    function transfer(
        uint256 amount,
        bool forceLentRedemption,
        bool willLend,
        address recipient
    ) external returns (uint256 amountTransferred, bool lendingBalanceUsed) {
        if (recipient == msg.sender) {
            revert UniversalBalance__InvalidParameter();
        }
        
        (amountTransferred, lendingBalanceUsed) = _transfer(
            amount,
            forceLentRedemption,
            willLend,
            recipient,
            msg.sender
        );
    }

    /// @notice Withdraws underlying token from `owner`'s Universal Balance
    ///         account, currently held or lent out.
    /// @dev Requires that `owner` has approved the caller previously to
    ///      access their Universal Balance.
    ///      Emits { Withdraw } and { Deposit } events.
    ///      Owner cannot delegate themselves so we can skip the check.
    /// @param amount The amount of underlying token to be withdrawn.
    /// @param forceLentRedemption Whether the withdrawn underlying tokens
    ///                            should be pulled only from `owner`'s lent
    ///                            position or the full account.
    /// @param willLend Whether the deposited underlying tokens should be lent
    ///                 out inside Curvance Protocol.
    /// @param recipient The account who will receive the underlying assets.
    /// @param owner The account that will redeem from their universal
    ///              balance.
    /// @return amountTransferred The amount of underlying token transferred.
    /// @return lendingBalanceUsed Whether the transferred underlying tokens
    ///                            were pulled from the lent balance.
    function transferFor(
        uint256 amount,
        bool forceLentRedemption,
        bool willLend,
        address recipient,
        address owner
    ) external returns (uint256 amountTransferred, bool lendingBalanceUsed) {
        if (owner == recipient) {
            revert UniversalBalance__InvalidParameter();
        }
        
        _checkDelegate(owner, msg.sender);

        (amountTransferred, lendingBalanceUsed) = _transfer(
            amount,
            forceLentRedemption,
            willLend,
            recipient,
            owner
        );
    }

    /// @notice Rescue any token sent by mistake.
    /// @dev Restricts the ability to rescue underlying tokens inside the
    ///      market since Curvance is non-custodial. Universal Balance has no
    ///      intention of supporting duel-entry point tokens so extra
    ///      validation for pre-post balances is not necessary.
    /// @param token The token to rescue.
    /// @param amount The amount of `token` to rescue, 0 indicates to
    ///               rescue all.
    function rescueToken(address token, uint256 amount) external {
        _checkDaoPermissions();

        if (token == underlying || token == address(linkedToken)) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        RescueLib._rescueToken(centralRegistry, token, amount);
    }

    /// @notice Updating delegated access to gauge emissions to the current
    ///         DAO.
    /// @dev This is allowed to be permissionless as there is no potential
    ///      to steal funds.
    function updateRewardDelegation() external {
        centralRegistry.incrementApprovalIndex();
        IPluginDelegable(centralRegistry.gaugeManager()).setDelegateApproval(
            centralRegistry.daoAddress(),
            true
        );
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Deposits underlying token into user's Universal Balance
    ///         account, either to be held or lent out.
    /// @dev Emits { Deposit } event.
    /// @param amount The amount of underlying tokens to be deposited,
    ///               in assets.
    /// @param willLend Whether the deposited underlying tokens should be lent
    ///                 out inside Curvance Protocol.
    /// @param recipient The account that should receive the deposit.
    function _deposit(
        uint256 amount,
        bool willLend,
        address recipient
    ) internal {
        _checkZeroAmount(amount);

        if (willLend) {
            // Records balance in shares.
            uint256 tokensReceived = linkedToken.deposit(amount, address(this));
            userBalances[recipient].lentBalance += tokensReceived;

            emit Deposit(msg.sender, recipient, amount, willLend);
            return;
        }

        userBalances[recipient].sittingBalance += amount;
        emit Deposit(msg.sender, recipient, amount, willLend);
    }

    /// @notice Deposits underlying token into `recipients` Universal Balance
    ///         accounts, either to be held or lent out.
    /// @dev Requires that all `recipients` has approved the caller previously
    ///      to access their Universal Balance.
    ///      Emits one or more { Deposit } event(s).
    /// @param amounts An array containing the amount of underlying token to
    ///                be deposited to each account.
    /// @param willLend An array containing whether the deposited underlying
    ///                 tokens should be lent out inside Curvance Protocol for
    ///                 each account.
    /// @param recipients An array containing the accounts who will receive a
    ///                   deposit based on their matching `amounts` value.
    /// @return The total amount of unused underlying token to deposit.
    function _multiDepositFor(
        uint256 depositSum,
        uint256[] calldata amounts,
        bool[] calldata willLend,
        address[] calldata recipients
    ) internal returns (uint256) {
        uint256 userLength = recipients.length;
        if (userLength != amounts.length || userLength != willLend.length) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        for (uint256 i; i < userLength; ++i) {
            _checkDelegate(recipients[i], msg.sender);

            // If the inputted deposit sum is invalid this will natively
            // panic preventing invariant manipulation.
            depositSum -= amounts[i];

            _deposit(amounts[i], willLend[i], recipients[i]);
        }

        return depositSum;
    }

    /// @notice Withdraws underlying token from user's Universal Balance
    ///         account, either currently held or lent out.
    /// @param amount The amount of underlying tokens to be withdrawn,
    ///               in assets.
    /// @param forceLentRedemption Whether the withdrawn underlying tokens
    ///                            should be pulled only from `owner`'s lent
    ///                            position or the full account.
    /// @param owner The account that will redeem from their universal
    ///              balance.
    /// @return amountWithdrawn The amount of underlying token withdrawn.
    /// @return lendingBalanceUsed Whether the withdrawn underlying tokens
    ///                            were pulled from the lent balance.
    function _withdraw(
        uint256 amount,
        bool forceLentRedemption,
        address owner
    ) internal returns (uint256, bool) {
        _checkZeroAmount(amount);

        if (
            IActionRegistry(address(centralRegistry)).checkTransfersDisabled(
                owner
            )
        ) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        UserBalance memory ownerBalance = userBalances[owner];
        uint256 exchangeRate = linkedToken.exchangeRateUpdated();

        // If it's a forced lending redemption only check their lent balance,
        // otherwise look at both sitting and lent balances.
        uint256 pointerAmount = forceLentRedemption
            ? FixedPointMathLib.mulDiv(
                ownerBalance.lentBalance,
                exchangeRate,
                WAD
            )
            : ownerBalance.sittingBalance +
                FixedPointMathLib.mulDiv(
                    ownerBalance.lentBalance,
                    exchangeRate,
                    WAD
                );
        uint256 remainingAmount = amount;

        // Validate that `owner` has enough deposited to process
        // withdrawing `amount`.
        if (pointerAmount < amount) {
            revert UniversalBalance__InsufficientBalance();
        }

        // If it's not a forced lent redemption, pull from sitting balance
        // first before pulling from balance being lent.
        if (!forceLentRedemption) {
            if (ownerBalance.sittingBalance > 0) {
                pointerAmount = ownerBalance.sittingBalance < amount
                    ? ownerBalance.sittingBalance
                    : amount;

                // Reduce user sitting balance.
                userBalances[owner].sittingBalance -= pointerAmount;
                remainingAmount -= pointerAmount;
            }
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
            userBalances[owner].lentBalance -= pointerAmount;

            pointerAmount = linkedToken.redeem(
                pointerAmount,
                address(this),
                address(this)
            );

            // Make sure enough was redeemed.
            if (pointerAmount < remainingAmount) {
                revert UniversalBalance__SlippageError();
            }
        }

        // If lent balance was used at all,
        // remainingAmount will be greater than 0.
        return (amount, remainingAmount > 0);
    }

    /// @notice Withdraws underlying token from `owners` Universal Balance
    ///         accounts, currently held or lent out.
    /// @dev Requires that each `owners` has approved the caller previously to
    ///      access their Universal Balance.
    ///      Emits one or more { Withdraw } event(s).
    /// @param amounts An array containing the amount of underlying tokens to
    ///                be withdrawn from each account, in assets.
    /// @param forceLentRedemption An array containing whether the withdrawn
    ///                            underlying tokens should be pulled only
    ///                            from an `owners` lent position or the full
    ///                            account.
    /// @param recipient The account who will receive the underlying assets.
    /// @param owners An array containing the accounts that will redeem from
    ///               their Universal Balance.
    /// @return The total amount of underlying token withdrawn
    ///         from all accounts.
    function _multiWithdrawFor(
        uint256[] calldata amounts,
        bool[] calldata forceLentRedemption,
        address recipient,
        address[] calldata owners
    ) internal returns (uint256) {
        uint256 amountsLength = amounts.length;
        if (
            amountsLength != forceLentRedemption.length ||
            amountsLength != owners.length
        ) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        uint256 withdrawSum;
        uint256 amountWithdrawn;
        bool lendingBalanceUsed;

        for (uint256 i; i < amountsLength; ++i) {
            _checkDelegate(owners[i], msg.sender);
            (amountWithdrawn, lendingBalanceUsed) = _withdraw(
                amounts[i],
                forceLentRedemption[i],
                owners[i]
            );

            emit Withdraw(
                msg.sender,
                recipient,
                owners[i],
                amountWithdrawn,
                lendingBalanceUsed
            );

            withdrawSum += amountWithdrawn;
        }

        // Validate that tokens were actually redeemed.
        _checkZeroAmount(withdrawSum);

        return withdrawSum;
    }

    /// @notice Transfers `amount` from owner's universal balance, currently
    ///         held or lent out to `recipient`.
    /// @dev Requires that `owner` has approved the caller previously to
    ///      access their universal balance.
    ///      Emits { Withdraw } and { Deposit } events.
    /// @param amount The amount of underlying tokens to be transferred,
    ///               in assets.
    /// @param forceLentRedemption Whether the withdrawn underlying tokens
    ///                            should be pulled only from `owner`'s lent
    ///                            position or the full account.
    /// @param willLend Whether the deposited underlying tokens should be lent
    ///                 out inside Curvance Protocol.
    /// @param recipient The account who will receive the underlying assets.
    /// @param owner The account that will redeem from their universal balance.
    /// @return amountTransferred The amount of underlying token transferred.
    /// @return lendingBalanceUsed Whether the transferred underlying tokens
    ///                            were pulled from the lent balance.
    function _transfer(
        uint256 amount,
        bool forceLentRedemption,
        bool willLend,
        address recipient,
        address owner
    ) internal returns (uint256 amountTransferred, bool lendingBalanceUsed) {
        (amountTransferred, lendingBalanceUsed) = _withdraw(
            amount,
            forceLentRedemption,
            owner
        );

        emit Withdraw(
            msg.sender,
            msg.sender,
            owner,
            amountTransferred,
            lendingBalanceUsed
        );

        _deposit(amountTransferred, willLend, recipient);
    }

    /// @notice Checks to make sure an action is not an empty action.
    function _checkZeroAmount(uint256 amount) internal pure {
        /// @solidity memory-safe-assembly
        assembly {
            if iszero(amount) {
                mstore(0x00, _INVALID_PARAMETER_SELECTOR)
                // Return bytes 29-32 for the selector.
                revert(0x1c, 0x04)
            }
        }
    }

    /// @dev Checks whether the caller has sufficient permissioning.
    function _checkDaoPermissions() internal view {
        if (!centralRegistry.hasDaoPermissions(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }
    }

    /// @dev Internal helper for reverting efficiently.
    function _revert(uint256 s) internal pure {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, s)
            revert(0x1c, 0x04)
        }
    }
}
