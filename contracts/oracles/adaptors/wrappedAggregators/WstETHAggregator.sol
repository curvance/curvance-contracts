// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { VaultAggregator, WAD } from "contracts/oracles/adaptors/wrappedAggregators/VaultAggregator.sol";

import { IWstETH } from "contracts/interfaces/external/wsteth/IWstETH.sol";

contract WstETHAggregator is VaultAggregator {

    /// CONSTRUCTOR ///
    
    constructor(
        address _wstETH,
        address _stETH,
        address _stETHAggregator
    ) VaultAggregator(_wstETH, _stETH, _stETHAggregator) {}

    /// @notice Returns the current exchange rate between the wrapped asset
    ///         and the underlying aggregator, in `WAD`.
    /// @return The current exchange rate between the wrapped asset
    ///         and the underlying aggregator, in `WAD`.
    function getExchangeRate() public view override returns (uint256) {
        // Return exchange rate in `WAD` format directly.
        return IWstETH(vault).getStETHByWstETH(WAD);
    }
}
