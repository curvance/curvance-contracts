// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

import { IMToken } from "contracts/interfaces/market/IMToken.sol";
import { IMarketManager } from "contracts/interfaces/market/IMarketManager.sol";

contract CurvancePrefarm {
    /// TYPES ///

    /// @notice Stores information relating a prefarm token to the Curvance
    ///         Protocol.
    struct mToken {
        bool isCToken;
        address mTokenAddress;
    }

    /// CONSTANTS ///

    /// @notice The address receiving DAO bonding proceeds on
    ///         Ethereum Mainnet.
    address public immutable prefarmManager;
    /// @notice The token DAOs bond from into CVE position, in unix time.
    uint256 public immutable prefarmEndTimestamp;

    /// STORAGE ///

    /// @notice The amount of a token that a user has deposited into the
    ///         prefarm.
    /// @notice User => Token => User Balance.
    mapping(address => mapping(address => uint256)) public balanceOf;
    /// @notice Stores information relating a prefarm token to the Curvance
    ///         Protocol.
    /// @notice Prefarm Token => Protocol Data.
    mapping(address => mToken) public tokenData;

    /// ERRORS ///

    error CurvancePrefarm__MigrationNotPossible();
    error CurvancePrefarm__PrefarmDepositsBlocked();
    error CurvancePrefarm__Unauthorized();
    error CurvancePrefarm__InvalidParameters();

    /// EVENTS ///

    event Deposited(address user, address token, uint256 amount);
    event Migrated(address user, address token, uint256 amount);
    event WithdrawnWithPenalty(address user);

    /// CONSTRUCTOR ///

    constructor(address manager, uint256 endTimestamp) {
        prefarmManager = manager;
        prefarmEndTimestamp = endTimestamp;
    }

    /// EXTERNAL FUNCTIONS ///

    function multiDeposit(
        address[] calldata prefarmTokens,
        uint256[] calldata amounts
    ) external {
        if (block.timestamp > prefarmEndTimestamp) {
            revert CurvancePrefarm__PrefarmDepositsBlocked();
        }

        uint256 numTokens = prefarmTokens.length;
        if (numTokens != amounts.length) {
            revert CurvancePrefarm__InvalidParameters();
        }

        for (uint256 i; i < numTokens; ++i) {
            SafeTransferLib.safeTransferFrom(
                prefarmTokens[i],
                msg.sender,
                address(this),
                amounts[i]
            );

            _recordDeposit(prefarmTokens[i], amounts[i], msg.sender);
        }
    }

    function deposit(address prefarmToken, uint256 amount) external {
        if (block.timestamp > prefarmEndTimestamp) {
            revert CurvancePrefarm__PrefarmDepositsBlocked();
        }

        SafeTransferLib.safeTransferFrom(
            prefarmToken,
            msg.sender,
            address(this),
            amount
        );

        _recordDeposit(prefarmToken, amount, msg.sender);
    }

    function withdraw(address prefarmToken, uint256 amount) external {
        if (balanceOf[msg.sender][prefarmToken] < amount) {
            revert CurvancePrefarm__InvalidParameters();
        }

        // Record user balance decrease.
        balanceOf[msg.sender][prefarmToken] -= amount;

        // Transfer prefarm assets back to user.
        SafeTransferLib.safeTransferFrom(
            prefarmToken,
            msg.sender,
            address(this),
            amount
        );

        emit WithdrawnWithPenalty(msg.sender);
    }

    function migrate(
        address prefarmToken,
        uint256 amount,
        bool collateralize
    ) external {
        // Validate that migration has started.
        if (block.timestamp < prefarmEndTimestamp) {
            revert CurvancePrefarm__MigrationNotPossible();
        }

        if (balanceOf[msg.sender][prefarmToken] < amount) {
            revert CurvancePrefarm__InvalidParameters();
        }

        // Record user balance decrease.
        balanceOf[msg.sender][prefarmToken] -= amount;

        // Cache protocol token data being migrated to.
        mToken memory migrationToken = tokenData[prefarmToken];
        
        // Validate that protocol token has been configured.
        if (migrationToken.mTokenAddress == address(0)) {
            revert CurvancePrefarm__MigrationNotPossible();
        }

        // Migrate prefarm asset into Curvance protocol.
        if (migrationToken.isCToken) {
            // Migrate a collateral token.
            if (collateralize) {
                // Migrate to a collateral token and immediately
                // collateralize it.
                IMToken(migrationToken.mTokenAddress).depositAsCollateralFor(
                    amount,
                    msg.sender
                );
            } else {
                // Migrate to a collateral token and just deposit it.
                IMToken(migrationToken.mTokenAddress).deposit(
                    amount,
                    msg.sender
                );
            }
        } else {
            // Migrate a debt token to be lent to users.
            IMToken(migrationToken.mTokenAddress).mintFor(amount, msg.sender);
        }

        emit Migrated(msg.sender, prefarmToken, amount);
    }

    function setMigrationConfig(
        address prefarmToken,
        address protocolToken
    ) external {
        // Validate proper function authority.
        if (msg.sender != prefarmManager) {
            revert CurvancePrefarm__Unauthorized();
        }

        // Validate the protocol token has the prefarm token as its
        // underlying.
        if (IMToken(protocolToken).underlying() == prefarmToken) {
            revert CurvancePrefarm__InvalidParameters();
        }

        // Validate the protocol token has a market manager and is listed.
        if (IMToken(protocolToken).marketManager().isListed(protocolToken)) {
            revert CurvancePrefarm__InvalidParameters();
        }

        // Pull the data directly from the contract rather than from parameter
        // input.
        tokenData[prefarmToken].isCToken = IMToken(protocolToken).isCToken();
        tokenData[prefarmToken].mTokenAddress = protocolToken;
    }

    /// INTERNAL FUNCTIONS ///

    function _recordDeposit(
        address prefarmToken,
        uint256 amount,
        address receiver
    ) internal {
        // Record balance for future redemption/migration
        balanceOf[receiver][prefarmToken] += amount;
        // Emit deposit event for offchain system.
        emit Deposited(receiver, prefarmToken, amount);
    }
}
