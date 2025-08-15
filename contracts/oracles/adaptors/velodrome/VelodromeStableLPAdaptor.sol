// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { BaseStableLPAdaptor } from "contracts/oracles/adaptors/stableswapBase/BaseStableLPAdaptor.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IVeloPool } from "contracts/interfaces/external/velodrome/IVeloPool.sol";

contract VelodromeStableLPAdaptor is BaseStableLPAdaptor {
    /// CONSTRUCTOR ///

    /// @param cr The address of central registry.
    constructor(ICentralRegistry cr) BaseStableLPAdaptor(cr) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Returns the adaptor's type.
    /// @dev Used by frontends to determine how to properly interact
    ///      with a supported asset.
    /// @return The adaptor's type.
    function adaptorType() external pure override returns (uint256) {
        return 10;
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Checks whether `asset` is the proper type of LP to try
    ///         to support.
    function _checkLPType(IVeloPool asset) internal view override {
        if (!asset.stable()) {
            revert BaseStableLPAdaptor__InvalidAssetType();
        }
    }
}