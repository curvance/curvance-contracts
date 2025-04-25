// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseWrappedAggregator } from "contracts/oracles/adaptors/wrappedAggregators/BaseWrappedAggregator.sol";
import { IPotLike } from "contracts/interfaces/external/maker/IPotLike.sol";
import { ISavingsDai } from "contracts/interfaces/external/maker/ISavingsDai.sol";

contract SavingsDaiAggregator is BaseWrappedAggregator {
    /// STORAGE ///

    /// @notice The address of the savings dai token.
    address public sDai;
    /// @notice The address of the dai token.
    address public dai;
    /// @notice The address of the dai aggregator.
    address public daiAggregator;

    constructor(address _sDai, address _dai, address _daiAggregator) {
        sDai = _sDai;
        dai = _dai;
        daiAggregator = _daiAggregator;
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
        return daiAggregator;
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Returns the current exchange rate between the wrapped asset
    ///         and the underlying aggregator, in `WAD`.
    /// @return The current exchange rate between the wrapped asset
    ///         and the underlying aggregator, in `WAD`.
    function getWrappedAssetWeight() public view override returns (uint256) {
        // We divide by 1e9 since chi returns in 1e27 format,
        // so we need to offset by 1e9 to get to standard `WAD` format.
        return IPotLike(ISavingsDai(sDai).pot()).chi() / 1e9;
    }
}
