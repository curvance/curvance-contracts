// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";

import { ERC165 } from "contracts/libraries/external/ERC165.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { ITimelock } from "contracts/interfaces/ITimelock.sol";

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
/// - Stays in sync with permissioned addresses changes through the
///   CentralRegistry.
/// - Grants permissioned protocol addresses roles
///   (proposer/executor/canceller) inside the timelock executor.
///
contract DAOTimelock is TimelockController, ERC165 {
    /// CONSTANTS ///

    /// @notice Minimum delay for timelock transaction proposals to execute.
    uint256 public constant MINIMUM_DELAY = 5 days;

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;

    /// STORAGE ///

    /// @notice Curvance DAO address.
    address internal _DAO_ADDRESS;
    /// @notice Curvance Emergency Council address.
    address internal _EMERGENCY_COUNCIL;

    /// CONSTRUCTOR ///

    constructor(ICentralRegistry cr) TimelockController(
        MINIMUM_DELAY,
        new address[](0),
        new address[](0),
        address(0)
    ) {
        CentralRegistryLib._isCentralRegistry(cr);
        centralRegistry = cr;

        // Grant proposer/executor/canceller role to DAO operator.
        _DAO_ADDRESS = cr.daoAddress();
        _grantRole(PROPOSER_ROLE, _DAO_ADDRESS);
        _grantRole(EXECUTOR_ROLE, _DAO_ADDRESS);
        _grantRole(CANCELLER_ROLE, _DAO_ADDRESS);

        // Grant canceller role to DAO Emergency Council.
        _EMERGENCY_COUNCIL = cr.emergencyCouncil();
        _grantRole(CANCELLER_ROLE, _EMERGENCY_COUNCIL);
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Permissionlessly update roles if it has been changed
    ///         through the Protocol Central Registry.
    function updateRoles() external {
        address registryDaoAddress = centralRegistry.daoAddress();
        address timelockDaoAddress = _DAO_ADDRESS;

        if (registryDaoAddress != timelockDaoAddress) {
            _revokeRole(PROPOSER_ROLE, timelockDaoAddress);
            _revokeRole(EXECUTOR_ROLE, timelockDaoAddress);
            _revokeRole(CANCELLER_ROLE, timelockDaoAddress);

            _grantRole(PROPOSER_ROLE, registryDaoAddress);
            _grantRole(EXECUTOR_ROLE, registryDaoAddress);
            _grantRole(CANCELLER_ROLE, registryDaoAddress);
            _DAO_ADDRESS = registryDaoAddress;
            _grantRole(PROPOSER_ROLE, registryDaoAddress);
            _grantRole(EXECUTOR_ROLE, registryDaoAddress);
            _grantRole(CANCELLER_ROLE, registryDaoAddress);
            _DAO_ADDRESS = registryDaoAddress;
        }

        address registryEC = centralRegistry.emergencyCouncil();
        address timelockEC = _EMERGENCY_COUNCIL;
        if (registryEC != timelockEC) {
            _revokeRole(CANCELLER_ROLE, timelockEC);

            _grantRole(CANCELLER_ROLE, registryEC);
            _EMERGENCY_COUNCIL = registryEC;
        }
    }

    /// @return result The minimum delay before a proposal can be executed,
    ///        in `seconds`.
    function getMinDelay() public view override returns (uint256 result) {
        uint256 currentDelay = super.getMinDelay();
        result = currentDelay < MINIMUM_DELAY ? MINIMUM_DELAY : currentDelay;
    }

    /// @notice Returns true if this contract implements the interface defined
    ///         by `interfaceId`.
    /// @param interfaceId The interface to check for implementation.
    /// @return Whether `interfaceId` is implemented or not.
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override (ERC165, TimelockController) returns (bool) {
        return
            interfaceId == type(ITimelock).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}