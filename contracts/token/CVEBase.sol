// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";

import { ERC20 } from "contracts/libraries/external/ERC20.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IMessagingHub } from "contracts/interfaces/IMessagingHub.sol";

/// @title CVEBase
/// @notice Base contract to be inherited by Curvance Collective Token (CVE) implementations.
/// @dev This abstract contract provides core functionality for the Curvance ecosystem token:
///      1. Cross-chain bridging capabilities via the MessagingHub
///      2. Gauge emission minting for protocol incentives
///      3. Lock boost token minting for veCVE staking rewards
///      4. Security controls for authorized operations
///
///      The contract is meant to be extended by:
///      - CVE.sol: The canonical implementation with vesting and allocation logic
///      - RemoteCVE.sol: Simplified implementation for non-canonical chains
///
///      All CVE implementations interact with the following key components:
///      - CentralRegistry: Central authority for permissions and protocol configuration
///      - MessagingHub: Handles cross-chain messaging for bridging operations
///      - VeCVE: Vote-escrow contract for locking CVE tokens
///
abstract contract CVEBase is ERC20 {
    /// CONSTANTS ///

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;

    /// @dev `bytes4(keccak256(bytes("CVE__Unauthorized()")))`.
    uint256 internal constant _UNAUTHORIZED_SELECTOR = 0x15f37077;

    /// EVENTS ///

    event BridgeTokens(
        address user,
        uint256 chainId,
        uint256 dstChainId,
        uint256 amount
    );
    event BridgeTokensComplete(address user, uint256 chainId, uint256 amount);
    event BridgeLock(
        address user,
        uint256 chainId,
        uint256 dstChainId,
        uint256 amount
    );
    event BridgeLockComplete(address user, uint256 chainId, uint256 amount);

    /// ERRORS ///

    error CVE__Unauthorized();
    error CVE__ParametersAreInvalid();

    /// CONSTRUCTOR ///

    constructor(ICentralRegistry cr) {
        CentralRegistryLib._isCentralRegistry(cr);
        centralRegistry = cr;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Mints gauge emissions for the desired gauge pool.
    /// @dev Only callable by the MessagingHub.
    /// @param gaugeManager The address of the gauge pool where emissions will be
    ///                  configured.
    /// @param amount The amount of gauge emissions to be minted.
    function mintGaugeEmissions(
        address gaugeManager,
        uint256 amount
    ) external {
        if (
            msg.sender != _getMessagingHub() && msg.sender != _getVotingHub()
        ) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        _mint(gaugeManager, amount);
    }

    /// @notice Mints CVE to the calling gauge pool to fund the users
    ///         lock boost.
    /// @param amount The amount of tokens to be minted.
    function mintLockBoost(uint256 amount) external {
        if (!centralRegistry.hasLockingPermissions(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        _mint(msg.sender, amount);
    }

    /// BRIDGING FUNCTIONS ///

    /// @notice Mint CVE to msg.sender,
    ///         which will always be the VeCVE contract.
    /// @dev Only callable by the MessagingHub.
    ///      This function is used only for creating a bridged VeCVE lock.
    /// @param amount The amount of token to mint for the new veCVE lock.
    function mintLockedTokens(address recipient, uint256 amount) external {
        if (msg.sender != _getMessagingHub()) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        _mint(msg.sender, amount);
        emit BridgeLockComplete(recipient, block.chainid, amount);
    }

    /// @notice Burn CVE from msg.sender,
    ///         which will always be the VeCVE contract.
    /// @dev Only callable by VeCVE.
    ///      This function is used only for bridging VeCVE lock.
    /// @param amount The amount of token to burn for a bridging veCVE lock.
    function burnLockedTokens(
        address recipient,
        uint256 dstChainId,
        uint256 amount
    ) external {
        if (msg.sender != centralRegistry.veCVE()) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        _burn(msg.sender, amount);
        emit BridgeLock(
            recipient,
            block.chainid,
            centralRegistry.messagingToGETHChainId(uint16(dstChainId)),
            amount
        );
    }

    /// @notice Send wormhole message to bridge CVE.
    /// @param recipient The address of recipient on destination chain.
    /// @param dstChainId Chain ID of the target blockchain.
    /// @param amount The amount of token to bridge.
    /// @param gasLimit Gas limit with which to call on destination chain.
    function bridge(
        address recipient,
        uint256 dstChainId,
        uint256 amount,
        uint256 gasLimit
    ) external payable {
        _burn(msg.sender, amount);

        IMessagingHub(_getMessagingHub()).bridgeToken{ value: msg.value }(
            dstChainId,
            recipient,
            amount,
            gasLimit,
            5,
            false
        );

        emit BridgeTokens(recipient, block.chainid, dstChainId, amount);
    }

    /// @notice Finalizes bridging of CVE by minting `amount` CVE
    ///         to `recipient`.
    /// @param recipient The address of CVE recipient.
    /// @param amount The amount of token to receive.
    function completeBridge(address recipient, uint256 amount) external {
        if (msg.sender != _getMessagingHub()) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        _mint(recipient, amount);
        emit BridgeTokensComplete(recipient, block.chainid, amount);
    }

    /// @notice Returns required amount of native asset for message fee.
    /// @param dstChainId Chain ID of the target blockchain.
    /// @param gasLimit Gas limit with which to call on destination chain.
    /// @return Required fee.
    function bridgeFee(
        uint256 dstChainId,
        uint256 gasLimit
    ) external view returns (uint256) {
        return
            IMessagingHub(_getMessagingHub()).quoteMessageFee(
                dstChainId,
                gasLimit
            );
    }

    /// PUBLIC FUNCTIONS ///

    /// @dev Returns the name of the token.
    /// @return The name of the token.
    function name() public pure override returns (string memory) {
        return "Curvance Collective";
    }

    /// @dev Returns the symbol of the token.
    /// @return The symbol of the token.
    function symbol() public pure override returns (string memory) {
        return "CVE";
    }

    /// INTERNAL FUNCTIONS ///

    /// @dev Returns the current Messaging Hub address.
    /// @return The current Messaging Hub address.
    function _getMessagingHub() internal view returns (address) {
        return centralRegistry.messagingHub();
    }

    /// @dev Returns the current Voting Hub address.
    /// @return The current Voting Hub address.
    function _getVotingHub() internal view returns (address) {
        return centralRegistry.votingHub();
    }

    /// @dev Internal helper for reverting efficiently.
    /// @param s The selector to revert with.
    function _revert(uint256 s) internal pure {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, s)
            revert(0x1c, 0x04)
        }
    }

    /// @dev Checks whether the caller has sufficient permissioning.
    function _checkDaoPermissions() internal view {
        if (!centralRegistry.hasDaoPermissions(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }
    }
}
