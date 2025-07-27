// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseWrappedAggregator, WAD } from "contracts/oracles/adaptors/wrappedAggregators/BaseWrappedAggregator.sol";

import { IWstETH } from "contracts/interfaces/external/wsteth/IWstETH.sol";

contract WstETHAggregator is BaseWrappedAggregator {
    /// STORAGE ///

    /// @notice The address of the wstETH token.
    address public wstETH;
    /// @notice The address of the stETH token.
    address public stETH;
    /// @notice The address of the stETH aggregator.
    address public stETHAggregator;

    /// CONSTRUCTOR ///
    
    constructor(address _wstETH, address _stETH, address _stETHAggregator) {
        wstETH = _wstETH;
        stETH = _stETH;
        stETHAggregator = _stETHAggregator;
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Returns the underlying aggregator address.
    /// @return The underlying aggregator address.
    function underlyingAssetAggregator()
        public
        view
        override
        returns (address)
    {
        return stETHAggregator;
    }

    /// @notice Returns the current exchange rate between the wrapped asset
    ///         and the underlying aggregator, in `WAD`.
    /// @return The current exchange rate between the wrapped asset
    ///         and the underlying aggregator, in `WAD`.
    function getExchangeRate() public view override returns (uint256) {
        // Return exchange rate in `WAD` format directly.
        return IWstETH(wstETH).getStETHByWstETH(WAD);
    }
}
