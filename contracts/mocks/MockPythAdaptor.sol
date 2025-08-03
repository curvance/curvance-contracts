// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { PythAdaptor } from "contracts/oracles/adaptors/pyth/PythAdaptor.sol";

contract MockPythAdaptor is PythAdaptor {
    bool skipHeartBeatCheck = true;
    
    constructor(
        ICentralRegistry centralRegistry_,
        address universalBalance_,
        address pyth_,
        address weth_,
        uint256 MAXIMUM_INCREASE_PER_YEAR,
        uint256 MINIMUM_INCREASE_PER_YEAR,
        uint256 MAXIMUM_TIMESTAMP_BUFFER,
        uint256 MINIMUM_TIMESTAMP_BUFFER
    ) PythAdaptor(
        centralRegistry_,
        universalBalance_,
        pyth_,
        weth_,
        MAXIMUM_INCREASE_PER_YEAR,
        MINIMUM_INCREASE_PER_YEAR,
        MAXIMUM_TIMESTAMP_BUFFER,
        MINIMUM_TIMESTAMP_BUFFER
    ) {}

    function setSkipHeartBeatCheck(bool skip) external {
        skipHeartBeatCheck = skip;
    }

    /// @notice Validates the feed data based on various constraints.
    /// @dev Checks if the value is within a specific range
    ///      and if the data is not outdated.
    /// @param value The value that is retrieved from the feed data.
    /// @param timestamp The time at which the value was last updated.
    /// @param max The maximum limit of the value.
    /// @param min The minimum limit of the value.
    /// @param heartbeat The maximum allowed time difference between
    ///                  current time and 'timestamp'.
    /// @return A boolean indicating whether the feed data had an error
    ///         (true = error, false = no error).
    function _verifyData(
        uint256 value,
        uint256 timestamp,
        uint256 max,
        uint256 min,
        uint256 heartbeat
    ) internal view override returns (bool) {
        // Validate `value` is not below the buffered min value allowed.
        if (value < min) {
            return true;
        }

        // Validate `value` is not above the buffered maximum value allowed.
        if (value > max) {
            return true;
        }

        // Validate the price returned is not stale.
        if (!skipHeartBeatCheck && block.timestamp - timestamp > heartbeat) {
            return true;
        }

        return false;
    }
}
