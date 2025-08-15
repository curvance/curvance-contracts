// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { VaultAggregator, WAD } from "contracts/oracles/adaptors/wrappedAggregators/VaultAggregator.sol";

import { IWstETH, IStETH } from "contracts/interfaces/external/lido/IWstETH.sol";

contract WstETHAggregator is VaultAggregator {

    /// CONSTRUCTOR ///
    
    constructor(
        address wstETH,
        address stETH,
        address stETHAggregator
    ) VaultAggregator(wstETH, stETH, stETHAggregator) {}

    /// @notice Returns the current exchange rate between the wrapped asset
    ///         and the underlying aggregator, in `WAD`.
    /// @return The current exchange rate between the wrapped asset
    ///         and the underlying aggregator, in `WAD`.
    function getExchangeRate() public view override returns (uint256) {
        // Return exchange rate in `WAD` format directly.
        return IWstETH(vault).getStETHByWstETH(WAD);
    }

    /// INTERNAL FUNCTIONS ///

    function _checkVaultAsset(
        address _vault,
        address _asset
    ) internal view override {
        if (address(IWstETH(_vault).stETH()) != _asset) {
            revert BaseWrappedAggregator__InvalidConfig();
        }
    }
}
