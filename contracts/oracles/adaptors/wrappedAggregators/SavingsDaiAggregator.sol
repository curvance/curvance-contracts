// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { VaultAggregator } from "contracts/oracles/adaptors/wrappedAggregators/VaultAggregator.sol";

import { IPotLike } from "contracts/interfaces/external/maker/IPotLike.sol";
import { ISavingsDai } from "contracts/interfaces/external/maker/ISavingsDai.sol";

contract SavingsDaiAggregator is VaultAggregator {

    /// CONSTRUCTOR ///

    constructor(
        address _sDai,
        address _dai,
        address _daiAggregator
    ) VaultAggregator(_sDai, _dai, _daiAggregator) {}

    /// @notice Returns the current exchange rate between the wrapped asset
    ///         and the underlying aggregator, in `WAD`.
    /// @return The current exchange rate between the wrapped asset
    ///         and the underlying aggregator, in `WAD`.
    function getExchangeRate() public view override returns (uint256) {
        // We divide by 1e9 since chi returns in 1e27 format,
        // so we need to offset by 1e9 to get to standard `WAD` format.
        return IPotLike(ISavingsDai(vault).pot()).chi() / 1e9;
    }
}
