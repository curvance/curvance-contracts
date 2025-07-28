// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { VaultAggregator } from "contracts/oracles/adaptors/wrappedAggregators/VaultAggregator.sol";

import { IStakedFrax } from "contracts/interfaces/external/frax/IStakedFrax.sol";

contract StakedFraxAggregator is VaultAggregator {

    /// CONSTRUCTOR ///

    constructor(
        address _sFrax,
        address _frax,
        address _fraxAggregator
    ) VaultAggregator(_sFrax, _frax, _fraxAggregator) {}

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
