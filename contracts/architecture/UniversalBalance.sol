//SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";
import { WAD } from "contracts/libraries/Constants.sol";
import { ReentrancyGuard } from "contracts/libraries/external/ReentrancyGuard.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IMToken } from "contracts/interfaces/IMToken.sol";
import { ILockableRegistry } from "contracts/interfaces/ILockableRegistry.sol";
import { IPluginDelegable } from "contracts/interfaces/IPluginDelegable.sol";

/// @title Curvance Universal Balance.
/// @notice A system for managing a Universal Balance within the Curvance
///         Protocol.
contract UniversalBalance is PluginDelegable, ReentrancyGuard {
    /// TYPES ///

    struct UserBalance {
        uint256 sittingBalance;
        uint256 lentBalance;
    }

    /// CONSTANTS ///

    /// @notice The address of the eToken linked to this contract.
    IMToken public immutable linkedEToken;

    /// @notice The address of universal balance underlying token.
    address public immutable underlying;

    /// @dev `bytes4(keccak256(bytes("UniversalBalance__Unauthorized()")))`.
    uint256 internal constant _UNAUTHORIZED_SELECTOR = 0x439f5eb2;
    /// @dev `bytes4(keccak256(bytes("UniversalBalance__InvalidParameter()")))`.
    uint256 internal constant _INVALID_PARAMETER_SELECTOR = 0xc75f2a32;

    /// STORAGE ///

    /// @notice Manages a users sitting and lending balances inside
    ///         their universe balance account.
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
    error UniversalBalance__UnderlyingTokenMismatch();
    error UniversalBalance__InvalidParameter();
    error UniversalBalance__Unauthorized();
    error UniversalBalance__SlippageError();

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address eToken
    ) PluginDelegable(centralRegistry_) {
        // Validate inputted eToken is actually an eToken.
        if (IMToken(eToken).isPToken()) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        linkedEToken = IMToken(eToken);
        address underlying_ = IMToken(eToken).underlying();
        underlying = underlying_;

        IERC20(underlying_).approve(eToken, type(uint256).max);
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Deposits underlying token into user's universal balance
    ///         account, either to be held or lent out.
    /// @dev Emits { Deposit } event.
    /// @param amount The amount of underlying token to be deposited.
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

    /// @notice Deposits underlying token into `recipient`'s universal balance
    ///         account, either to be held or lent out.
    /// @dev Requires that `recipient` has approved the caller previously to
    ///      access their universal balance.
    ///      Emits { Deposit } event.
    /// @param amount The amount of underlying token to be deposited.
    /// @param willLend Whether the deposited underlying tokens should be lent
    ///                 out inside Curvance Protocol.
    /// @param recipient The account who will receive the deposit.
    function depositFor(
        uint256 amount,
        bool willLend,
        address recipient
    ) external {
        _checkDelegation(recipient);

        SafeTransferLib.safeTransferFrom(
            underlying,
            msg.sender,
            address(this),
            amount
        );
        _deposit(amount, willLend, recipient);
    }

    /// @notice Deposits underlying token into `recipients` universal balance
    ///         accounts, either to be held or lent out.
    /// @dev Requires that all `recipients` has approved the caller previously
    ///      to access their universal balance.
    ///      Emits one or more { Deposit } event(s).
    /// @param amounts An array containing the amount of underlying token to
    ///                be deposited to each account.
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
        uint256 userLength = recipients.length;
        if (userLength != amounts.length || userLength != willLend.length) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        SafeTransferLib.safeTransferFrom(
            underlying,
            msg.sender,
            address(this),
            depositSum
        );

        for (uint256 i; i < userLength; ++i) {
            _checkDelegation(recipients[i]);

            // If the inputted deposit sum is invalid this will natively
            // panic preventing invariant manipulation.
            depositSum -= amounts[i];

            _deposit(amounts[i], willLend[i], recipients[i]);
        }

        // Reimburse any unused deposit amount.
        if (depositSum > 0) {
            SafeTransferLib.safeTransfer(underlying, msg.sender, depositSum);
        }
    }

    /// @notice Withdraws underlying token from user's universal balance
    ///         account, currently held or lent out.
    /// @dev Emits { Withdraw } event.
    /// @param amount The amount of underlying token to be withdrawn.
    /// @param forceLentRedemption Whether the withdrawn underlying tokens
    ///                            should be pulled only from `owner`'s lent
    ///                            position or the full account.
    /// @param recipient The account who will receive the underlying assets.
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

    /// @notice Withdraws underlying token from `owner`'s universal balance
    ///         account, currently held or lent out.
    /// @dev Requires that `owner` has approved the caller previously to
    ///      access their universal balance.
    ///      Emits { Withdraw } event.
    /// @param amount The amount of underlying token to be withdrawn.
    /// @param forceLentRedemption Whether the withdrawn underlying tokens
    ///                            should be pulled only from `owner`'s lent
    ///                            position or the full account.
    /// @param recipient The account who will receive the underlying assets.
    /// @param owner The account that will redeem from their universal balance.
    function withdrawFor(
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

    /// @notice Withdraws underlying token from `owners` universal balance
    ///         accounts, currently held or lent out.
    /// @dev Requires that each `owners` has approved the caller previously to
    ///      access their universal balance.
    ///      Emits one or more { Withdraw } event(s).
    /// @param amounts An array containing the amount of underlying token to
    ///                be withdrawn from each account.
    /// @param forceLentRedemption An array containing whether the withdrawn
    ///                            underlying tokens should be pulled only
    ///                            from an `owners` lent position or the full
    ///                            account.
    /// @param recipient The account who will receive the underlying assets.
    /// @param owners An array containing the accounts that will redeem from
    ///               their universal balance.
    function multiWithdrawFor(
        uint256[] calldata amounts,
        bool[] calldata forceLentRedemption,
        address recipient,
        address[] calldata owners
    ) external {
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
            _checkDelegation(owners[i]);
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
        if (withdrawSum == 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Transfer the withdrawn tokens.
        SafeTransferLib.safeTransfer(underlying, recipient, withdrawSum);
    }

    /// @notice Transfers `amount` from caller's universal balance, currently
    ///         held or lent out to `recipient`.
    /// @dev Emits { Deposit } and { Withdraw } events.
    /// @param amount The amount of underlying token to be transferred.
    /// @param forceLentRedemption Whether the transferred underlying tokens
    ///                            should be pulled only from the caller's
    ///                            lent position or the full account.
    /// @param willLend Whether the deposited underlying tokens should be lent
    ///                 out inside Curvance Protocol.
    /// @param recipient The account who will receive the transferred balance.
    function transfer(
        uint256 amount,
        bool forceLentRedemption,
        bool willLend,
        address recipient
    ) external returns (uint256 amountTransferred, bool lendingBalanceUsed) {
        (amountTransferred, lendingBalanceUsed) = _withdraw(
            amount,
            forceLentRedemption,
            msg.sender
        );

        _deposit(amountTransferred, willLend, recipient);
    }

    /// @notice Withdraws underlying token from `owner`'s universal balance
    ///         account, currently held or lent out.
    /// @dev Requires that `owner` has approved the caller previously to
    ///      access their universal balance.
    ///      Emits { Withdraw } event.
    /// @param amount The amount of underlying token to be withdrawn.
    /// @param forceLentRedemption Whether the withdrawn underlying tokens
    ///                            should be pulled only from `owner`'s lent
    ///                            position or the full account.
    /// @param willLend Whether the deposited underlying tokens should be lent
    ///                 out inside Curvance Protocol.
    /// @param recipient The account who will receive the underlying assets.
    /// @param owner The account that will redeem from their universal balance.
    function transferFor(
        uint256 amount,
        bool forceLentRedemption,
        bool willLend,
        address recipient,
        address owner
    ) external returns (uint256 amountTransferred, bool lendingBalanceUsed) {
        _checkDelegation(owner);

        (amountTransferred, lendingBalanceUsed) = _withdraw(
            amount,
            forceLentRedemption,
            owner
        );

        _deposit(amountTransferred, willLend, recipient);
    }

    /// @notice Rescue any token sent by mistake.
    /// @dev Restricts the ability to rescue underlying tokens inside the
    ///      market since Curvance is non-custodial.
    /// @param token The token to rescue.
    /// @param amount The amount of `token` to rescue, 0 indicates to
    ///               rescue all.
    function rescueToken(address token, uint256 amount) external {
        _checkDaoPermissions();
        address daoOperator = centralRegistry.daoAddress();

        if (token == address(0)) {
            if (amount == 0) {
                amount = address(this).balance;
            }

            SafeTransferLib.safeTransferETH(daoOperator, amount);
        } else {
            if (token == underlying || token == address(linkedEToken)) {
                _revert(_INVALID_PARAMETER_SELECTOR);
            }

            if (amount == 0) {
                amount = IERC20(token).balanceOf(address(this));
            }

            SafeTransferLib.safeTransfer(token, daoOperator, amount);
        }
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

    /// @notice Deposits underlying token into user's universal balance
    ///         account, either to be held or lent out.
    /// @dev Emits { Deposit } event.
    /// @param amount The amount of underlying token to be deposited.
    /// @param willLend Whether the deposited underlying tokens should be lent
    ///                 out inside Curvance Protocol.
    /// @param recipient The account that should receive the deposit.
    function _deposit(
        uint256 amount,
        bool willLend,
        address recipient
    ) internal {
        if (willLend) {
            // Will natively fail if amount == 0 on gaugeManager call.
            // Records balance in tokens (shares).
            uint256 tokensReceived = linkedEToken.mint(amount);
            userBalances[recipient].lentBalance += tokensReceived;

            emit Deposit(msg.sender, recipient, amount, willLend);
            return;
        }

        if (amount == 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        userBalances[recipient].sittingBalance += amount;
        emit Deposit(msg.sender, recipient, amount, willLend);
    }

    /// @notice Withdraws underlying token from user's universal balance
    ///         account, either currently held or lent out.
    /// @dev Emits { Withdraw } event.
    /// @param amount The amount of underlying token to be withdrawn.
    /// @param forceLentRedemption Whether the withdrawn underlying tokens
    ///                            should be pulledonly from `owner`'s lent
    ///                            position or the full account.
    /// @param owner The account that will redeem from their universal
    ///              balance.
    function _withdraw(
        uint256 amount,
        bool forceLentRedemption,
        address owner
    ) internal returns (uint256, bool) {
        // Validate caller is not trying to withdraw nothing, though this
        // technically double checks amount in cases of lending balance
        // redemption, we want an efficient non-panic check here.
        if (amount == 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        if (
            ILockableRegistry(address(centralRegistry)).checkTransfersDisabled(
                owner
            )
        ) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        UserBalance memory ownerBalance = userBalances[owner];
        uint256 exchangeRate = linkedEToken.exchangeRateWithUpdate();

        // If its a forced lending redemption only check their lent balance,
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

        // If its not a forced lent redemption, pull from sitting balance
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

            pointerAmount = linkedEToken.redeem(pointerAmount, address(this));

            // Make sure enough was redeemed.
            if (pointerAmount < remainingAmount) {
                revert UniversalBalance__SlippageError();
            }
        }

        // If lent balance was used at all, remainingAmount will be greater than 0.
        return (amount, remainingAmount > 0);
    }

    /// @dev Checks whether the caller has sufficient permissioning.
    function _checkDaoPermissions() internal view {
        if (!centralRegistry.hasDaoPermissions(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }
    }

    /// @notice Validates whether a user or contract has the ability to act
    ///         on behalf of an account.
    /// @param user The address to check whether caller has delegation
    ///             permissions.
    function _checkDelegation(address user) internal view {
        if (!isDelegate(user, msg.sender)) {
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
