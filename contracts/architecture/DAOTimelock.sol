// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

import { ERC165 } from "contracts/libraries/external/ERC165.sol";
import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { ITimelock } from "contracts/interfaces/ITimelock.sol";

///
/// @title Curvance DAO Timelock
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
contract DAOTimelock is TimelockController, ERC165 {
    /// CONSTANTS ///

    /// @notice Minimum delay for timelock transaction proposals to execute.
    uint256 public constant MINIMUM_DELAY = 5 days;
    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;
    /// @notice Internally stored Curvance DAO address.
    address internal _DAO_ADDRESS;

    /// ERRORS ///

    error Timelock__InvalidCentralRegistry(address invalidCentralRegistry);

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
            revert Timelock__InvalidCentralRegistry(address(centralRegistry_));
        }

        centralRegistry = centralRegistry_;

        // grant admin/proposer/executor role to DAO.
        _DAO_ADDRESS = centralRegistry.daoAddress();
        _grantRole(PROPOSER_ROLE, _DAO_ADDRESS);
        _grantRole(EXECUTOR_ROLE, _DAO_ADDRESS);
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Permissionlessly update DAO address if it has been changed.
    ///         through the Curvance Central Registry.
    function updateDaoAddress() external {
        address daoAddress = centralRegistry.daoAddress();
        if (daoAddress != _DAO_ADDRESS) {
            _revokeRole(PROPOSER_ROLE, _DAO_ADDRESS);
            _revokeRole(EXECUTOR_ROLE, _DAO_ADDRESS);

            _grantRole(PROPOSER_ROLE, daoAddress);
            _grantRole(EXECUTOR_ROLE, daoAddress);
            _DAO_ADDRESS = daoAddress;
        }
    }

    /// @notice Returns true if this contract implements the interface defined
    ///         by `interfaceId`.
    /// @param interfaceId The interface to check for implementation.
    /// @return Whether `interfaceId` is implemented or not.
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC165, TimelockController) returns (bool) {
        return
            interfaceId == type(ITimelock).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
