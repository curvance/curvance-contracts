// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BaseVolatileLPAdaptor, ICentralRegistry } from "contracts/oracles/adaptors/stableswapBase/BaseVolatileLPAdaptor.sol";

import { IVeloPool } from "contracts/interfaces/external/velodrome/IVeloPool.sol";

contract VelodromeVolatileLPAdaptor is BaseVolatileLPAdaptor {
    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
    constructor(
        ICentralRegistry cr
    ) BaseVolatileLPAdaptor(cr, "VelodromeVolatileLPAdaptor") {}

    /// INTERNAL FUNCTIONS ///

    /// @notice Checks whether `asset` is the proper type of LP to try
    ///         to support.
    function _checkLPType(IVeloPool asset) internal view override {
        if (asset.stable()) {
            revert BaseVolatileLPAdaptor__InvalidAssetType();
        }
    }
}