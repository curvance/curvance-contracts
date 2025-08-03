// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseVolatileLPAdaptor } from "contracts/oracles/adaptors/stableswapBase/BaseVolatileLPAdaptor.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IVeloPool } from "contracts/interfaces/external/velodrome/IVeloPool.sol";

contract VelodromeVolatileLPAdaptor is BaseVolatileLPAdaptor {
    /// CONSTRUCTOR ///

    /// @param cr The address of central registry.
    constructor(ICentralRegistry cr) BaseVolatileLPAdaptor(cr) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Returns the adaptor's type.
    /// @dev Used by frontends to determine how to properly interact
    ///      with a supported asset.
    /// @return The adaptor's type.
    function adaptorType() external pure override returns (uint256) {
        return 9;
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Checks whether `asset` is the proper type of LP to try
    ///         to support.
    function _checkLPType(IVeloPool asset) internal view override {
        if (asset.stable()) {
            revert BaseVolatileLPAdaptor__InvalidAssetType();
        }
    }
}