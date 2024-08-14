// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

import { IMToken } from "contracts/interfaces/market/IMToken.sol";

contract CurvancePrefarm {
    /// TYPES ///

    /// @notice Stores information relating a prefarm token to the Curvance
    ///         Protocol.
    struct TokenData {
        bool isApproved;
        address mTokenAddress;
        bool isCToken;
    }

    /// CONSTANTS ///

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

    error CurvancePrefarm__MigrationNotPossible();
    error CurvancePrefarm__PrefarmDepositsBlocked();
    error CurvancePrefarm__Unauthorized();
    error CurvancePrefarm__InvalidParameters();

    /// EVENTS ///

    event Deposited(address user, address token, uint256 amount);
    event Migrated(address user, address token, uint256 amount);
    event WithdrawnWithPenalty(address user);
    event MigrationTokenConfigured(address token, address protocolToken);
    event PrefarmTokenApproved(address token);

    /// CONSTRUCTOR ///

    constructor(address manager, uint256 endTimestamp) {
        prefarmManager = manager;
        prefarmEndTimestamp = endTimestamp;
    }

    /// EXTERNAL FUNCTIONS ///

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
        if (migrationToken.isCToken) {
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
        SwapperLib._removeApprovalIfNeeded(token,mToken);

        emit Migrated(msg.sender, token, amount);
    }

    function addPrefarmTokens(address[] calldata tokens) external {
        _isPrefarmManager();

        uint256 numTokens = tokens.length;
        address cachedToken;

        for (uint256 i; i < numTokens; ++i) {
            cachedToken = tokens[i];
            if (tokenData[cachedToken].isApproved) {
                continue;
            }

            tokenData[cachedToken].isApproved = true;
            emit PrefarmTokenApproved(cachedToken);
        }
    }

    /// PERMISSIONED FUNCTIONS ///

    function setMigrationConfig(
        address prefarmToken,
        address protocolToken
    ) external {
        _isPrefarmManager();

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
        tokenData[prefarmToken].isCToken = IMToken(protocolToken).isCToken();
        tokenData[prefarmToken].mTokenAddress = protocolToken;

        emit MigrationTokenConfigured(prefarmToken, protocolToken);
    }

    /// INTERNAL FUNCTIONS ///

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

    function _isPrefarmManager() internal view {
        // Validate proper function authority.
        if (msg.sender != prefarmManager) {
            revert CurvancePrefarm__Unauthorized();
        }
    }
}
