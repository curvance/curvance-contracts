// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

import { ERC165 } from "contracts/libraries/external/ERC165.sol";
import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { ITimelock } from "contracts/interfaces/ITimelock.sol";

///
/// @title DAO Timelock
/// @notice A timelock controller for the Curvance DAO that enforces a delay
///         period before administrative operations can be executed.
/// @dev This contract extends OpenZeppelin's TimelockController with
///      Curvance-specific functionality. It enforces a minimum delay of
///      5-days for all timelock transaction proposals.
///
/// The timelock serves as a security mechanism that:
/// - Creates transparency by making governance actions visible before
///   execution.
/// - Provides a window for token holders to exit if they disagree with
///   proposed changes.
/// - Protects the protocol from immediate execution of potentially malicious
///   proposals.
///
/// This implementation:
/// - Stays in sync with DAO address changes through the CentralRegistry.
/// - Grants the DAO address both proposer and executor roles.
/// - Supports interface detection via ERC165.
///
contract DAOTimelock is TimelockController, ERC165, ITimelock {
    /// CONSTANTS ///

    /// @notice Minimum delay for timelock transaction proposals to execute.
    uint256 public constant MINIMUM_DELAY = 5 days;

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;

    /// STORAGE ///

    /// @notice Internally stored Curvance DAO address.
    address internal _DAO_ADDRESS;

    /// ERRORS ///

    error DAOTimelock__InvalidParameter();
    error DAOTimelock__Unauthorized();

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_
    )
        TimelockController(
            MINIMUM_DELAY,
            new address[](0),
            new address[](0),
            address(0)
        )
    {
        if (
            !ERC165Checker.supportsInterface(
                address(centralRegistry_),
                type(ICentralRegistry).interfaceId
            )
        ) {
            revert DAOTimelock__InvalidParameter();
        }

        centralRegistry = centralRegistry_;

        // grant admin/proposer/executor/canceller role to DAO.
        _DAO_ADDRESS = centralRegistry.daoAddress();
        _grantRole(PROPOSER_ROLE, _DAO_ADDRESS);
        _grantRole(EXECUTOR_ROLE, _DAO_ADDRESS);
        _grantRole(CANCELLER_ROLE, _DAO_ADDRESS);
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Cancels a queued action.
    /// @dev Only callable by `CANCELLER_ROLE` or the Emergency Council.
    ///      May emit a {Cancelled} event.
    /// @param id The queued action to cancel.
    function cancel(bytes32 id) public override {
        _checkCanCancel();

        if (!isOperationPending(id)) {
            revert DAOTimelock__InvalidParameter();
        }

        delete _timestamps[id];
        emit Cancelled(id);
    }

    /// @notice Permissionlessly update DAO address if it has been changed.
    ///         through the Protocol Central Registry.
    function updateDaoAddress() external {
        address registryDaoAddress = centralRegistry.daoAddress();
        address timelockDaoAddress = _DAO_ADDRESS;

        if (daoAddress != timelockDaoAddress) {
            _revokeRole(PROPOSER_ROLE, timelockDaoAddress);
            _revokeRole(EXECUTOR_ROLE, timelockDaoAddress);
            _revokeRole(CANCELLER_ROLE, timelockDaoAddress);

            _grantRole(PROPOSER_ROLE, registryDaoAddress);
            _grantRole(EXECUTOR_ROLE, registryDaoAddress);
            _grantRole(CANCELLER_ROLE, registryDaoAddress);
            _DAO_ADDRESS = registryDaoAddress;
        }
    }

    /// @notice Updates the minimum delay between an action queue and
    ///         execution.
    /// @dev `newDelay` cannot be less than `MINIMUM_DELAY`.
    ///      May emit a {MinDelayChange} event.
    /// @param newDelay The new minimum delay between action queue and
    ///                 execution.
    function updateDelay(uint256 newDelay) external override {
        if (newDelay < MINIMUM_DELAY) {
            revert DAOTimelock__InvalidParameter();
        }
        
        super.updateDelay(newDelay);
    }

    /// @notice Returns true if this contract implements the interface defined
    ///         by `interfaceId`.
    /// @param interfaceId The interface to check for implementation.
    /// @return Whether `interfaceId` is implemented or not.
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC165, TimelockController) returns (
        bool
    ) {
        return
            interfaceId == type(ITimelock).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// @dev Checks whether the caller has sufficient permissions
    ///      to cancel a queued action.
    function _checkCanCancel() internal view {
        if (
            _msgSender() != centralRegistry.emergencyCouncil() &&
            !hasRole(role, _msgSender())
            ) {
                revert DAOTimelock__Unauthorized();
        }
    }
}
