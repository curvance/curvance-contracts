// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { CommonLib } from "contracts/libraries/CommonLib.sol";

import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";

contract Predeposit {
    /// TYPES ///

    /// @notice Stores information relating a predeposit token to the Curvance
    ///         Protocol.
    /// @param isApproved Whether a token is approved for deposit inside the
    ///                   predeposit.
    /// @param cTokenAddress The protocol linked cToken address for a token
    ///                      deposited inside the predeposit, configured on
    ///                      protocol deployment.
    struct TokenData {
        bool isApproved;
        address cTokenAddress;
    }

    /// CONSTANTS ///

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;

    /// @notice The administrator of the predeposit, should be a multisig
    ///         made up of several parties.
    address public immutable predepositManager;

    /// @notice The timestamp when predeposit campaign ends, in unix time.
    uint256 public immutable predepositEndTimestamp;

    /// STORAGE ///

    /// @notice The amount of a token that a user has deposited into the
    ///         predeposit.
    /// @dev User => Token => User Balance.
    mapping(address => mapping(address => uint256)) public balanceOf;

    /// @notice Stores information relating a predeposit token to the Curvance
    ///         Protocol.
    /// @dev Predeposit Token => Protocol Data.
    mapping(address => TokenData) public tokenData;

    /// ERRORS ///

    error Predeposit__MigrationNotPossible();
    error Predeposit__PredepositDepositsBlocked();
    error Predeposit__Unauthorized();
    error Predeposit__InvalidParameters();
    error Predeposit__InvalidSwapAction();
    error Predeposit__InvalidSwapOutput();

    /// EVENTS ///

    event Deposited(address user, address token, uint256 amount);
    event Migrated(address user, address token, uint256 amount);
    event WithdrawnWithPenalty(address user);
    event MigrationTokenConfigured(address token, address protocolToken);
    event PredepositTokenApproved(address token);

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address manager,
        uint256 endTimestamp
    ) {
        CentralRegistryLib._isCentralRegistry(centralRegistry_);
        centralRegistry = centralRegistry_;

        predepositManager = manager;
        predepositEndTimestamp = endTimestamp;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Deposits approved tokens into the predeposit contract,
    ///         and emits events to be consumed offchain.
    /// @dev Can emit {Deposited} events.
    /// @param tokens An array containing the addresses of the predeposit tokens
    ///               to be deposited.
    /// @param amounts An array containing the amount of each token to be
    ///                deposited.
    function multiDeposit(
        address[] calldata tokens,
        uint256[] calldata amounts
    ) external {
        // Validate that predeposit deposit window has not ended.
        if (block.timestamp > predepositEndTimestamp) {
            revert Predeposit__PredepositDepositsBlocked();
        }

        uint256 numTokens = tokens.length;
        // Validate that parameters are configured properly.
        if (numTokens != amounts.length) {
            revert Predeposit__InvalidParameters();
        }

        address token;

        for (uint256 i; i < numTokens; ++i) {
            token = tokens[i];

            // Validate that `token` is approved for predeposit.
            if (!tokenData[token].isApproved) {
                revert Predeposit__InvalidParameters();
            }

            // Transfer predeposit token in.
            SafeTransferLib.safeTransferFrom(
                token,
                msg.sender,
                address(this),
                amounts[i]
            );

            // Record user deposit.
            _recordDeposit(token, amounts[i], msg.sender);
        }
    }

    /// @notice Deposits an approved token into the predeposit contract,
    ///         and emits an event to be consumed offchain.
    /// @dev Emits a {Deposited} event.
    /// @param token The address of the predeposit token to be deposited.
    /// @param amount The amount of `token` to be deposited.
    function deposit(address token, uint256 amount) external {
        // Validate that predeposit deposit window has not ended.
        if (block.timestamp > predepositEndTimestamp) {
            revert Predeposit__PredepositDepositsBlocked();
        }

        // Validate that `token` is approved for predeposit.
        if (!tokenData[token].isApproved) {
            revert Predeposit__InvalidParameters();
        }

        // Transfer predeposit token in.
        SafeTransferLib.safeTransferFrom(
            token,
            msg.sender,
            address(this),
            amount
        );

        // Record user deposit.
        _recordDeposit(token, amount, msg.sender);
    }

    function swapAndDeposit(
        SwapperLib.Swap memory swapAction,
        uint256 depositAmount
    ) external payable {
        address token = swapAction.outputToken;

        // Validate that predeposit deposit window has not ended.
        if (block.timestamp > predepositEndTimestamp) {
            revert Predeposit__PredepositDepositsBlocked();
        }

        // Validate that `token` is approved for predeposit.
        if (!tokenData[token].isApproved) {
            revert Predeposit__InvalidParameters();
        }

        if (CommonLib._isNative(swapAction.inputToken)) {
            // Validate message has gas token attached.
            if (swapAction.inputAmount != msg.value) {
                revert Predeposit__InvalidSwapAction();
            }
        } else {
            SafeTransferLib.safeTransferFrom(
                swapAction.inputToken,
                msg.sender,
                address(this),
                swapAction.inputAmount
            );
        }

        // Execute swap into cToken underlying.
        uint256 amount = SwapperLib._swapUnsafe(centralRegistry, swapAction);

        if (amount < depositAmount) {
            revert Predeposit__InvalidSwapOutput();
        }

        if (amount > depositAmount) {
            // Refund excess `token`.
            SafeTransferLib.safeTransfer(
                token,
                msg.sender,
                amount - depositAmount
            );
        }

        // Record user deposit.
        _recordDeposit(token, depositAmount, msg.sender);
    }

    /// @notice Withdraws a predeposit deposit from the predeposit and emits a
    ///         penalty event to be consumed offchain.
    /// @dev Emits a {WithdrawnWithPenalty} event.
    /// @param token The address of the predeposit token to be withdrawn.
    /// @param amount The amount of `token` to be withdrawn.
    function withdraw(address token, uint256 amount) external {
        // Validate that user has sufficient deposited balance to withdraw
        // `amount`.
        if (balanceOf[msg.sender][token] < amount) {
            revert Predeposit__InvalidParameters();
        }

        // Document user withdrawal.
        balanceOf[msg.sender][token] -= amount;

        // Transfer predeposit assets back to user.
        SafeTransferLib.safeTransfer(token, msg.sender, amount);

        emit WithdrawnWithPenalty(msg.sender);
    }

    /// @notice Migrates a predeposit deposit into a corresponding Curvance
    ///         protocol cToken position.
    /// @dev Emits a {Migrated} event.
    /// @param token The address of the predeposit token to be migrated.
    /// @param amount The amount of `token` to be migrated.
    /// @param collateralize Whether the cToken deposit should be
    ///                      collateralized or not, only used in cases where
    ///                      the predeposit token is being deposited into a
    ///                      pToken position.
    function migrate(
        address token,
        uint256 amount,
        bool collateralize
    ) external {
        // Validate that migration has started.
        if (block.timestamp < predepositEndTimestamp) {
            revert Predeposit__MigrationNotPossible();
        }

        // Validate that user has sufficient deposited balance to migrate
        // `amount`.
        if (balanceOf[msg.sender][token] < amount) {
            revert Predeposit__InvalidParameters();
        }

        // Document user deposit migration.
        balanceOf[msg.sender][token] -= amount;

        // Cache protocol token data being migrated to.
        TokenData memory migrationToken = tokenData[token];
        address cToken = migrationToken.cTokenAddress;

        // Validate that protocol token has been configured.
        if (cToken == address(0)) {
            revert Predeposit__MigrationNotPossible();
        }

        // Approve tokens to be pulled by cToken.
        SwapperLib._approveIfNeeded(token, cToken, amount);

        // Migrate predeposit asset into Curvance protocol.
        if (collateralize) {
            // Migrate, deposit, and collateralize.
            ICToken(cToken).depositAsCollateralFor(amount, msg.sender);
        } else {
            // Migrate then deposit.
            ICToken(cToken).deposit(amount, msg.sender);
        }

        // Remove any excess approval.
        SwapperLib._removeApprovalIfNeeded(token, cToken);

        emit Migrated(msg.sender, token, amount);
    }

    /// @notice Adds deposit support for a token inside the predeposit.
    /// @dev Can emit {PredepositTokenApproved} events.
    /// @param tokens An array containing the tokens to be enabled inside
    ///               the predeposit.
    function addPredepositTokens(address[] calldata tokens) external {
        _isPredepositManager();

        uint256 numTokens = tokens.length;
        address cachedToken;

        for (uint256 i; i < numTokens; ++i) {
            cachedToken = tokens[i];
            // If the token is already supported we can just skip approving,
            // and emitting approval event.
            if (tokenData[cachedToken].isApproved) {
                continue;
            }

            tokenData[cachedToken].isApproved = true;
            emit PredepositTokenApproved(cachedToken);
        }
    }

    /// PERMISSIONED FUNCTIONS ///

    /// @notice Configures a links predeposit token and a deployed Curvance
    ///         cToken so that user's can migrate deposits into the Curvance
    ///         Protocol.
    /// @dev Emits a {MigrationTokenConfigured} event.
    /// @param predepositToken The address of the predeposit token to be configured.
    /// @param protocolToken The address of the protocol cToken to be
    ///                      configured.
    function setMigrationConfig(
        address predepositToken,
        address protocolToken
    ) external {
        _isPredepositManager();

        // Validate that `predepositToken` is actually supported inside the
        // predeposit.
        if (!tokenData[predepositToken].isApproved) {
            revert Predeposit__InvalidParameters();
        }

        // Validate the protocol token has the predeposit token as its
        // underlying.
        if (ICToken(protocolToken).asset() != predepositToken) {
            revert Predeposit__InvalidParameters();
        }

        // Validate the protocol token has a market manager and is listed.
        if (!ICToken(protocolToken).marketManager().isListed(protocolToken)) {
            revert Predeposit__InvalidParameters();
        }

        // Pull the data directly from the contract rather than from parameter
        // input.
        tokenData[predepositToken].cTokenAddress = protocolToken;

        emit MigrationTokenConfigured(predepositToken, protocolToken);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Records a predeposit deposit by incrementing a receivers balance,
    ///      and emitting an event for offchain indexing system.
    /// @dev Emits a {Deposited} event.
    /// @param predepositToken The address of the predeposit token being deposited.
    /// @param amount The `amount` of predeposit token being deposited.
    /// @param receiver The user account receiving the deposit benefit.
    function _recordDeposit(
        address predepositToken,
        uint256 amount,
        address receiver
    ) internal {
        // Record balance for future redemption/migration.
        balanceOf[receiver][predepositToken] += amount;

        // Emit deposit event for offchain indexing.
        emit Deposited(receiver, predepositToken, amount);
    }

    /// @notice Validates whether the current caller is the `predepositManager`.
    function _isPredepositManager() internal view {
        // Validate proper function authority.
        if (msg.sender != predepositManager) {
            revert Predeposit__Unauthorized();
        }
    }
}
