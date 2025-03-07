// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev A fixed key to use in transient storage for the dynamic penalty.
bytes32 constant TRANSIENT_PENALTY_KEY = 0xd033e44c9f2a65a460c9f878712895054941eb772c7716e6dee8b66c21be9561;

/// @title PenaltyFeed using transient storage for dynamic penalty updates
contract PenaltyFeed is Ownable {
    // --- Persistent parameters ---
    uint256 public defaultPenalty = 10000;
    uint256 public minPenalty = 10;
    uint256 public maxPenalty = 10000;

    // Whitelisted updater of penalties only for duration of a transaction.
    // When address(0) that would produce a static penalty
    address public dAppControl;

    error PenaltyOutOfRange();
    error OnlyDAppControl();

    constructor() {}

    function setDAppControl(address newDAppControl) external onlyOwner {
        dAppControl = newDAppControl;
    }

    modifier onlyDAppControl() {
        if (msg.sender != dAppControl) {
            revert OnlyDAppControl();
        }
        _;
    }

    function setDefaultPenalty(uint256 newDefaultPenalty) external onlyOwner {
        if (newDefaultPenalty < minPenalty || newDefaultPenalty > maxPenalty) {
            revert PenaltyOutOfRange();
        }
        defaultPenalty = newDefaultPenalty;
    }

    function setMinPenalty(uint256 newMinPenalty) external onlyOwner {
        if (newMinPenalty > maxPenalty || defaultPenalty < newMinPenalty) {
            revert PenaltyOutOfRange();
        }
        minPenalty = newMinPenalty;
    }


    function setMaxPenalty(uint256 newMaxPenalty) external onlyOwner {
        if (newMaxPenalty < minPenalty || defaultPenalty > newMaxPenalty) {
            revert PenaltyOutOfRange();
        }
        maxPenalty = newMaxPenalty;
    }


    /// @notice Sets a new dynamic penalty value in transient storage.
    /// Transient storage enforces any liquidator not using dappcontrol/auction uses the default penalty.
    /// @param newPenalty The new penalty value.
    function setPenalty(uint256 newPenalty) external onlyDAppControl {
        // make sure new penalty is within configured allowed penalty
        if (newPenalty < minPenalty || newPenalty > maxPenalty) {
            revert PenaltyOutOfRange();
        }

        // Write newPenalty to transient storage.
        // Note: This inline assembly uses pseudocode for the new transient storage opcodes.
        assembly {
            // tstore(key, value): store `newPenalty` under TRANSIENT_PENALTY_KEY.
            tstore(TRANSIENT_PENALTY_KEY, newPenalty)
        }
    }

    /// @notice Resets the dynamic penalty value in transient storage to zero.
    function resetPenalty() external onlyDAppControl {
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
}