// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { PythAdaptor } from "contracts/oracles/adaptors/pyth/PythAdaptor.sol";

contract MockPythAdaptor is PythAdaptor {
    bool skipHeartBeatCheck = true;
    
    constructor(
        ICentralRegistry cr,
        address universalBalance_,
        address pyth_,
        address weth_
    ) PythAdaptor(cr, universalBalance_, pyth_, weth_) {}

    function setSkipHeartBeatCheck(bool skip) external {
        skipHeartBeatCheck = skip;
    }

    /// @notice Validates the feed data based on various constraints.
    /// @dev Checks if the value is within a specific range
    ///      and if the data is not outdated.
    /// @param value The value that is retrieved from the feed data.
    /// @param timestamp The time at which the value was last updated.
    /// @param heartbeat The maximum allowed time difference between
    ///                  current time and 'timestamp'.
    /// @return A boolean indicating whether the feed data had an error
    ///         (true = error, false = no error).
    function _verifyData(
        uint256 value,
        uint256 timestamp,
        uint256 heartbeat
    ) internal view override returns (bool) {
        // Validate `value` is not at or below 0.
        if (value <= 0) {
            return true;
        }

        // Validate the price returned is not stale.
        if (!skipHeartBeatCheck && block.timestamp - timestamp > heartbeat) {
            return true;
        }

        return false;
    }
}
