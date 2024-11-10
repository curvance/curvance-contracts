//SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";
import { WAD } from "contracts/libraries/Constants.sol";
import { ReentrancyGuard } from "contracts/libraries/external/ReentrancyGuard.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IMToken } from "contracts/interfaces/market/IMToken.sol";
import { IGaugeManager } from "contracts/interfaces/IGaugeManager.sol";
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
        uint256 outputAmount
    );

    /// @dev Emitted during a withdraw call.
    event Withdraw(
        address indexed by,
        address indexed to,
        address indexed owner,
        uint256 assets,
        uint256 redeemedAmount
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
    /// @param isLent Whether the deposited underlying tokens should be lent
    ///               out inside Curvance Protocol.
    function deposit(uint256 amount, bool isLent) external {
        SafeTransferLib.safeTransferFrom(
            underlying,
            msg.sender,
            address(this),
            amount
        );
        _deposit(amount, isLent);
    }

    /// @notice Withdraws underlying token from user's universal balance
    ///         account, either currently held or lent out.
    /// @dev Emits { Withdraw } event.
    /// @param amount The amount of underlying token to be withdrawn.
    /// @param isLent Whether the withdrawn underlying tokens should be pulled
    ///               from a user's lent position or held position inside
    ///               Curvance Protocol.
    /// @param recipient The account who will receive the underlying assets.
    function withdraw(
        uint256 amount,
        bool isLent,
        address receiver
    ) external {
        _withdraw(amount, isLent, receiver);
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
    /// @param isLent Whether the deposited underlying tokens should be lent
    ///               out inside Curvance Protocol.
    function _deposit(uint256 amount, bool isLent) internal {
        if (isLent) {
            // Will natively fail if amount == 0 on gaugeManager call.
            // Records balance in tokens (shares).
            uint256 tokensReceived = linkedEToken.mint(amount);
            userBalances[msg.sender].lentBalance += tokensReceived;
            emit Deposit(msg.sender, msg.sender, amount, tokensReceived);
            return;
        }

        if (amount == 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        userBalances[msg.sender].sittingBalance += amount;
        emit Deposit(msg.sender, msg.sender, amount, amount);
    }

    /// @notice Withdraws underlying token from user's universal balance
    ///         account, either currently held or lent out.
    /// @dev Emits { Withdraw } event.
    /// @param amount The amount of underlying token to be withdrawn.
    /// @param isLent Whether the withdrawn underlying tokens should be pulled
    ///               from a user's lent position or held position inside
    ///               Curvance Protocol.
    /// @param recipient The account who will receive the underlying assets.
    function _withdraw(
        uint256 amount,
        bool isLent,
        address recipient
    ) internal returns (uint256) {
        if (isLent) {
            uint256 exchangeRate = linkedEToken.exchangeRateWithUpdate();
            // Will natively fail if amount == 0 on gaugeManager call.
            // Records balance in tokens (shares).
            // We round up to make sure the user gets at least `amount` back.
            uint256 tokensToRedeem = FixedPointMathLib.mulDivUp(
                amount,
                WAD,
                exchangeRate
            );
            userBalances[msg.sender].lentBalance -= tokensToRedeem;

            uint256 tokensReceived = linkedEToken.redeem(
                tokensToRedeem,
                recipient
            );

            emit Withdraw(
                msg.sender,
                recipient,
                msg.sender,
                tokensReceived,
                tokensToRedeem
            );
            return tokensReceived;
        }

        // We don't need the amount == 0 check for lent redemption as gauge
        // withdrawal blocks amount == 0 redemptions.
        if (amount == 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        userBalances[msg.sender].sittingBalance -= amount;
        SafeTransferLib.safeTransfer(underlying, recipient, amount);

        emit Withdraw(msg.sender, recipient, msg.sender, amount, amount);
        return amount;
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
