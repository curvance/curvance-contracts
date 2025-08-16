// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @title Curvance Central Registry Validation Library
/// @notice For validating that Central Registry is configured properly
///         on launch.
library CentralRegistryLib {
    /// ERRORS ///

    error CentralRegistryLib__InvalidCentralRegistry();

    /// INTERNAL FUNCTIONS ///

    /// @notice Validates that `cr` is the Protocol Central Registry.
    /// @param cr The proposed Protocol Central Registry.
    function _isCentralRegistry(ICentralRegistry cr) internal view {
        if (
            !ERC165Checker.supportsInterface(
                address(cr),
                type(ICentralRegistry).interfaceId
            )
        ) {
            revert CentralRegistryLib__InvalidCentralRegistry();
        }
    }
}
