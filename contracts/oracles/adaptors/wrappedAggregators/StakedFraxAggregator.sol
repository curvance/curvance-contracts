// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { VaultAggregator } from "contracts/oracles/adaptors/wrappedAggregators/VaultAggregator.sol";

import { IStakedFrax } from "contracts/interfaces/external/frax/IStakedFrax.sol";

contract StakedFraxAggregator is VaultAggregator {

    /// CONSTRUCTOR ///

    constructor(
        address sFrax,
        address frax,
        address fraxAggregator
    ) VaultAggregator(sFrax, frax, fraxAggregator) {}

    /// @notice Returns the current exchange rate between the wrapped asset
    ///         and the underlying aggregator, in `WAD`.
    /// @return The current exchange rate between the wrapped asset
    ///         and the underlying aggregator, in `WAD`.
    function getExchangeRate() public view override returns (uint256) {
        // Staked Frax contract returns naturally in `WAD` format,
        // so no adjustment needed to return decimals.
        return IStakedFrax(vault).pricePerShare();
    }
}
