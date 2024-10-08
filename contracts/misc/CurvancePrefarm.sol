// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { CommonLib } from "contracts/libraries/CommonLib.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IMToken } from "contracts/interfaces/market/IMToken.sol";

contract CurvancePrefarm {
    /// TYPES ///

    /// @notice Stores information relating a prefarm token to the Curvance
    ///         Protocol.
    /// @param isApproved Whether a token is approved for deposit inside the
    ///                   prefarm.
    /// @param mTokenAddress The protocol linked mToken address for a token
    ///                      deposited inside the prefarm, configured on
    ///                      protocol deployment.
    /// @param isPToken Whether protocol linked mToken address is a pToken or
    ///                 not, configured on protocol deployment.
    struct TokenData {
        bool isApproved;
        address mTokenAddress;
        bool isPToken;
    }

    /// CONSTANTS ///

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;

    /// @notice The administrator of the prefarm, should be a multisig
    ///         made up of several parties.
    address public immutable prefarmManager;

    /// @notice The token DAOs bond from into CVE position, in unix time.
    uint256 public immutable prefarmEndTimestamp;

    /// STORAGE ///

    /// @notice The amount of a token that a user has deposited into the
    ///         prefarm.
    /// @dev User => Token => User Balance.
    mapping(address => mapping(address => uint256)) public balanceOf;

    /// @notice Stores information relating a prefarm token to the Curvance
    ///         Protocol.
    /// @dev Prefarm Token => Protocol Data.
    mapping(address => TokenData) public tokenData;

    /// ERRORS ///

    error CurvancePrefarm__InvalidCentralRegistry();
    error CurvancePrefarm__MigrationNotPossible();
    error CurvancePrefarm__PrefarmDepositsBlocked();
    error CurvancePrefarm__Unauthorized();
    error CurvancePrefarm__InvalidParameters();
    error CurvancePrefarm__InvalidSwapData();
    error CurvancePrefarm__InvalidSwapOutput();

    /// EVENTS ///

    event Deposited(address user, address token, uint256 amount);
    event Migrated(address user, address token, uint256 amount);
    event WithdrawnWithPenalty(address user);
    event MigrationTokenConfigured(address token, address protocolToken);
    event PrefarmTokenApproved(address token);

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address manager,
        uint256 endTimestamp
    ) {
        if (
            !ERC165Checker.supportsInterface(
                address(centralRegistry_),
                type(ICentralRegistry).interfaceId
            )
        ) {
            revert CurvancePrefarm__InvalidCentralRegistry();
        }

        centralRegistry = centralRegistry_;

        prefarmManager = manager;
        prefarmEndTimestamp = endTimestamp;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Deposits approved tokens into the prefarm contract,
    ///         and emits events to be consumed offchain.
    /// @dev Can emit {Deposited} events.
    /// @param tokens An array containing the addresses of the prefarm tokens
    ///               to be deposited.
    /// @param amounts An array containing the amount of each token to be
    ///                deposited.
    function multiDeposit(
        address[] calldata tokens,
        uint256[] calldata amounts
    ) external {
        // Validate that prefarm deposit window has not ended.
        if (block.timestamp > prefarmEndTimestamp) {
            revert CurvancePrefarm__PrefarmDepositsBlocked();
        }

        uint256 numTokens = tokens.length;
        // Validate that parameters are configured properly.
        if (numTokens != amounts.length) {
            revert CurvancePrefarm__InvalidParameters();
        }

        address token;

        for (uint256 i; i < numTokens; ++i) {
            token = tokens[i];

            // Validate that `token` is approved for prefarm.
            if (!tokenData[token].isApproved) {
                revert CurvancePrefarm__InvalidParameters();
            }

            // Transfer prefarm token in.
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

    /// @notice Deposits an approved token into the prefarm contract,
    ///         and emits an event to be consumed offchain.
    /// @dev Emits a {Deposited} event.
    /// @param token The address of the prefarm token to be deposited.
    /// @param amount The amount of `token` to be deposited.
    function deposit(address token, uint256 amount) external {
        // Validate that prefarm deposit window has not ended.
        if (block.timestamp > prefarmEndTimestamp) {
            revert CurvancePrefarm__PrefarmDepositsBlocked();
        }

        // Validate that `token` is approved for prefarm.
        if (!tokenData[token].isApproved) {
            revert CurvancePrefarm__InvalidParameters();
        }

        // Transfer prefarm token in.
        SafeTransferLib.safeTransferFrom(
            token,
            msg.sender,
            address(this),
            amount
        );

        // Record user deposit.
        _recordDeposit(token, amount, msg.sender);
    }

    function zapAndDeposit(
        SwapperLib.Swap memory swapData,
        uint256 depositAmount
    ) external payable {
        address token = swapData.outputToken;

        // Validate that prefarm deposit window has not ended.
        if (block.timestamp > prefarmEndTimestamp) {
            revert CurvancePrefarm__PrefarmDepositsBlocked();
        }

        // Validate that `token` is approved for prefarm.
        if (!tokenData[token].isApproved) {
            revert CurvancePrefarm__InvalidParameters();
        }

        if (CommonLib.isETH(swapData.inputToken)) {
            // Validate message has gas token attached.
            if (swapData.inputAmount != msg.value) {
                revert CurvancePrefarm__InvalidSwapData();
            }
        } else {
            SafeTransferLib.safeTransferFrom(
                swapData.inputToken,
                msg.sender,
                address(this),
                swapData.inputAmount
            );
        }

        // Execute swap into eToken underlying.
        uint256 amount = SwapperLib.swapUnsafe(centralRegistry, swapData);

        if (amount < depositAmount) {
            revert CurvancePrefarm__InvalidSwapOutput();
        }

        if (amount > depositAmount) {
            // Refund remaining payment token
            SafeTransferLib.safeTransfer(
                token,
                msg.sender,
                amount - depositAmount
            );
        }

        // Record user deposit.
        _recordDeposit(token, depositAmount, msg.sender);
    }

    /// @notice Withdraws a prefarm deposit from the prefarm and emits a
    ///         penalty event to be consumed offchain.
    /// @dev Emits a {WithdrawnWithPenalty} event.
    /// @param token The address of the prefarm token to be withdrawn.
    /// @param amount The amount of `token` to be withdrawn.
    function withdraw(address token, uint256 amount) external {
        // Validate that user has sufficient deposited balance to withdraw
        // `amount`.
        if (balanceOf[msg.sender][token] < amount) {
            revert CurvancePrefarm__InvalidParameters();
        }

        // Document user withdrawal.
        balanceOf[msg.sender][token] -= amount;

        // Transfer prefarm assets back to user.
        SafeTransferLib.safeTransfer(token, msg.sender, amount);

        emit WithdrawnWithPenalty(msg.sender);
    }

    /// @notice Migrates a prefarm deposit into a corresponding Curvance
    ///         protocol mToken position.
    /// @dev Emits a {Migrated} event.
    /// @param token The address of the prefarm token to be migrated.
    /// @param amount The amount of `token` to be migrated.
    /// @param collateralize Whether the mToken deposit should be
    ///                      collateralized or not, only used in cases where
    ///                      the prefarm token is being deposited into a
    ///                      pToken position.
    function migrate(
        address token,
        uint256 amount,
        bool collateralize
    ) external {
        // Validate that migration has started.
        if (block.timestamp < prefarmEndTimestamp) {
            revert CurvancePrefarm__MigrationNotPossible();
        }

        // Validate that user has sufficient deposited balance to migrate
        // `amount`.
        if (balanceOf[msg.sender][token] < amount) {
            revert CurvancePrefarm__InvalidParameters();
        }

        // Document user deposit migration.
        balanceOf[msg.sender][token] -= amount;

        // Cache protocol token data being migrated to.
        TokenData memory migrationToken = tokenData[token];
        address mToken = migrationToken.mTokenAddress;

        // Validate that protocol token has been configured.
        if (mToken == address(0)) {
            revert CurvancePrefarm__MigrationNotPossible();
        }

        // Approve tokens to be pulled by mToken.
        SwapperLib._approveTokenIfNeeded(token, mToken, amount);

        // Migrate prefarm asset into Curvance protocol.
        if (migrationToken.isPToken) {
            // Migrate a collateral token.
            if (collateralize) {
                // Migrate to a collateral token and immediately
                // collateralize it.
                IMToken(mToken).depositAsCollateralFor(amount, msg.sender);
            } else {
                // Migrate to a collateral token and just deposit it.
                IMToken(mToken).deposit(amount, msg.sender);
            }
        } else {
            // Migrate a debt token to be lent to users.
            IMToken(mToken).mintFor(amount, msg.sender);
        }

        // Remove any excess approval.
        SwapperLib._removeApprovalIfNeeded(token, mToken);

        emit Migrated(msg.sender, token, amount);
    }

    /// @notice Adds deposit support for a token inside the prefarm.
    /// @dev Can emit {PrefarmTokenApproved} events.
    /// @param tokens An array containing the tokens to be enabled inside
    ///               the prefarm.
    function addPrefarmTokens(address[] calldata tokens) external {
        _isPrefarmManager();

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
            emit PrefarmTokenApproved(cachedToken);
        }
    }

    /// PERMISSIONED FUNCTIONS ///

    /// @notice Configures a links prefarm token and a deployed Curvance
    ///         mToken so that user's can migrate deposits into the Curvance
    ///         Protocol.
    /// @dev Emits a {MigrationTokenConfigured} event.
    /// @param prefarmToken The address of the prefarm token to be configured.
    /// @param protocolToken The address of the protocol mToken to be
    ///                      configured.
    function setMigrationConfig(
        address prefarmToken,
        address protocolToken
    ) external {
        _isPrefarmManager();

        // Validate that `prefarmToken` is actually supported inside the
        // prefarm.
        if (!tokenData[prefarmToken].isApproved) {
            revert CurvancePrefarm__InvalidParameters();
        }

        // Validate the protocol token has the prefarm token as its
        // underlying.
        if (IMToken(protocolToken).underlying() != prefarmToken) {
            revert CurvancePrefarm__InvalidParameters();
        }

        // Validate the protocol token has a market manager and is listed.
        if (!IMToken(protocolToken).marketManager().isListed(protocolToken)) {
            revert CurvancePrefarm__InvalidParameters();
        }

        // Pull the data directly from the contract rather than from parameter
        // input.
        tokenData[prefarmToken].isPToken = IMToken(protocolToken).isPToken();
        tokenData[prefarmToken].mTokenAddress = protocolToken;

        emit MigrationTokenConfigured(prefarmToken, protocolToken);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Records a prefarm deposit by incrementing a receivers balance,
    ///      and emitting an event for offchain indexing system.
    /// @dev Emits a {Deposited} event.
    /// @param prefarmToken The address of the prefarm token being deposited.
    /// @param amount The `amount` of prefarm token being deposited.
    /// @param receiver The user account receiving the deposit benefit.
    function _recordDeposit(
        address prefarmToken,
        uint256 amount,
        address receiver
    ) internal {
        // Record balance for future redemption/migration.
        balanceOf[receiver][prefarmToken] += amount;

        // Emit deposit event for offchain indexing.
        emit Deposited(receiver, prefarmToken, amount);
    }

    /// @notice Validates whether the current caller is the `prefarmManager`.
    function _isPrefarmManager() internal view {
        // Validate proper function authority.
        if (msg.sender != prefarmManager) {
            revert CurvancePrefarm__Unauthorized();
        }
    }
}
