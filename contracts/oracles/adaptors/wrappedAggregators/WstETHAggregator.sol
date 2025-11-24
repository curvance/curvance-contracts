// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { VaultAggregator, WAD } from "contracts/oracles/adaptors/wrappedAggregators/VaultAggregator.sol";

import { IWstETH, IStETH } from "contracts/interfaces/external/lido/IWstETH.sol";

contract WstETHAggregator is VaultAggregator {
    /// CONSTRUCTOR ///
    
    constructor(
        address wstETH,
        address stETH,
        address stETHAggregator,
        string memory id
    ) VaultAggregator(wstETH, stETH, stETHAggregator, id) {}

    /// INTERNAL FUNCTIONS ///

    /// @notice Returns the current exchange rate between the wrapped asset
    ///         and the underlying aggregator, in `WAD`.
    /// @return result The current exchange rate between the wrapped asset
    ///                and the underlying aggregator, in `WAD`.
    function _getExchangeRate() internal view override returns (uint256 result) {
        // Return exchange rate in `WAD` format directly to get return value
        // in `_vaultDecimalPrecision` format.
        result = IWstETH(vault).getStETHByWstETH(WAD);
    }

    function _checkAssetConfig(
        address _vault,
        address _asset
    ) internal view override {
        if (address(IWstETH(_vault).stETH()) != _asset) {
            revert BaseWrappedAggregator__InvalidConfig();
        }
    }
}
