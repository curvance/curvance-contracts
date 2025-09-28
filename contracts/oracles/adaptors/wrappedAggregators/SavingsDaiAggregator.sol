// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { VaultAggregator } from "contracts/oracles/adaptors/wrappedAggregators/VaultAggregator.sol";

import { IPotLike } from "contracts/interfaces/external/maker/IPotLike.sol";
import { ISavingsDai } from "contracts/interfaces/external/maker/ISavingsDai.sol";

contract SavingsDaiAggregator is VaultAggregator {
    /// CONSTRUCTOR ///

    constructor(
        address sDai,
        address dai,
        address daiAggregator
    ) VaultAggregator(sDai, dai, daiAggregator) {}

    /// INTERNAL FUNCTIONS ///

    /// @notice Returns the current exchange rate between the wrapped asset
    ///         and the underlying aggregator, in `WAD`.
    /// @return result The current exchange rate between the wrapped asset
    ///                and the underlying aggregator, in `WAD`.
    function _getExchangeRate() internal view override returns (
        uint256 result
    ) {
        // We divide by 1e9 since chi returns in 1e27 format, so we need to
        // offset by 1e9 to get to proper dai `_vaultDecimalPrecision` format.
        result = IPotLike(ISavingsDai(vault).pot()).chi() / 1e9;
    }
}
