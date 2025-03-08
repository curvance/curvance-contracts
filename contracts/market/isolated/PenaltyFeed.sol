// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";

/// @dev A fixed key to use in transient storage for the dynamic penalty.
bytes32 constant TRANSIENT_PENALTY_KEY = 0xd033e44c9f2a65a460c9f878712895054941eb772c7716e6dee8b66c21be9561;

/// @title PenaltyFeed using transient storage for dynamic penalty updates
abstract contract PenaltyFeed {
    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;

    // --- Persistent parameters ---
    uint256 public defaultPenalty = 10000;
    uint256 public minPenalty = 10;
    uint256 public maxPenalty = 10000;

    // Whitelisted updater of penalties only for duration of a transaction.
    // When address(0) that would produce a static penalty
    address public dAppControl;

    /// ERRORS ///
    error PenaltyFeed__Unauthorized();
    error PenaltyFeed__PenaltyOutOfRange();

    /// @dev `bytes4(keccak256(bytes("PenaltyFeed__InvalidParameter()")))`.
    uint256 internal constant _INVALID_PARAMETER_SELECTOR = 0xd6f8c48a;

    constructor(ICentralRegistry centralRegistry_) {
        if (
            !ERC165Checker.supportsInterface(
                address(centralRegistry_),
                type(ICentralRegistry).interfaceId
            )
        ) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        centralRegistry = centralRegistry_;
    }

    function setDAppControl(address newDAppControl) external {
        _checkElevatedPermissions();
        dAppControl = newDAppControl;
    }

    function setDefaultPenalty(uint256 newDefaultPenalty) external {
        _checkElevatedPermissions();
        if (newDefaultPenalty < minPenalty || newDefaultPenalty > maxPenalty) {
            revert PenaltyFeed__PenaltyOutOfRange();
        }
        defaultPenalty = newDefaultPenalty;
    }

    function setMinPenalty(uint256 newMinPenalty) external {
        _checkElevatedPermissions();
        if (newMinPenalty > maxPenalty || defaultPenalty < newMinPenalty) {
            revert PenaltyFeed__PenaltyOutOfRange();
        }
        minPenalty = newMinPenalty;
    }


    function setMaxPenalty(uint256 newMaxPenalty) external {
        _checkElevatedPermissions();
        if (newMaxPenalty < minPenalty || defaultPenalty > newMaxPenalty) {
            revert PenaltyFeed__PenaltyOutOfRange();
        }
        maxPenalty = newMaxPenalty;
    }


    /// @notice Sets a new dynamic penalty value in transient storage.
    /// Transient storage enforces any liquidator not using dappcontrol/auction uses the default penalty.
    /// @param newPenalty The new penalty value.
    function setPenalty(uint256 newPenalty) external {
        _checkDappControl();
        // make sure new penalty is within configured allowed penalty
        if (newPenalty < minPenalty || newPenalty > maxPenalty) {
            revert PenaltyFeed__PenaltyOutOfRange();
        }

        // Write newPenalty to transient storage.
        // Note: This inline assembly uses pseudocode for the new transient storage opcodes.
        assembly {
            // tstore(key, value): store `newPenalty` under TRANSIENT_PENALTY_KEY.
            tstore(TRANSIENT_PENALTY_KEY, newPenalty)
        }
    }

    /// @notice Resets the dynamic penalty value in transient storage to zero.
    function resetPenalty() external {
        _checkDappControl();
        assembly {
            // Clear the transient storage slot by writing zero. 
            tstore(TRANSIENT_PENALTY_KEY, 0)
        }
    }

    /// @notice Returns the current penalty.
    /// If a dynamic penalty is set in transient storage, that value is returned;
    /// otherwise, the default penalty is returned.
    function getLatestPenalty() external view returns (uint256 result) {
        assembly {
            // Load dynamic penalty from transient storage.
            result := tload(TRANSIENT_PENALTY_KEY)
        }
        // If no dynamic penalty is set (assumed to be zero), return the defaultPenalty.
        // Note that this renders 0 as an invalid dynamic penalty value
        if (result == 0) {
            return defaultPenalty;
        }
        return result;
    }

    /// @notice Internal helper for reverting efficiently.
    /// @param s Selector to revert with.
    function _revert(uint256 s) internal pure {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, s)
            revert(0x1c, 0x04)
        }
    }

    /// @dev Checks whether the caller has sufficient permissioning.
    function _checkDappControl() internal view {
        if (msg.sender != dAppControl) {
            revert PenaltyFeed__Unauthorized();
        }
    }

    /// @notice Returns the Protocol Central Registry contract in interface
    ///         form.
    /// @dev MUST be overridden in every multicallable contract's
    ///      implementation.
    function _getCentralRegistry()
        internal
        view
        virtual
        returns (ICentralRegistry);
}