// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { VaultAggregator } from "contracts/oracles/adaptors/wrappedAggregators/VaultAggregator.sol";

import { IStakedFrax } from "contracts/interfaces/external/frax/IStakedFrax.sol";

contract StakedFraxAggregator is VaultAggregator {
    /// CONSTRUCTOR ///

    constructor(
        address sFrax,
        address frax,
        address fraxAggregator
    ) VaultAggregator(sFrax, frax, fraxAggregator) {}

    /// INTERNAL FUNCTIONS ///

    /// @notice Returns the current exchange rate between the wrapped asset
    ///         and the underlying aggregator, in `WAD`.
    /// @return result The current exchange rate between the wrapped asset
    ///                and the underlying aggregator, in `WAD`.
    function _getExchangeRate() internal view override returns (
        uint256 result
    ) {
        // Staked Frax contract returns naturally in `_vaultDecimalPrecision`
        // format, so no adjustment needed.
        result = IStakedFrax(vault).pricePerShare();
    }
}
