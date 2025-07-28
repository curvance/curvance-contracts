// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseWrappedAggregator, WAD } from "contracts/oracles/adaptors/wrappedAggregators/BaseWrappedAggregator.sol";

import { ICToken } from "contracts/interfaces/ICToken.sol";

contract VaultAggregator is BaseWrappedAggregator {
    /// STORAGE ///

    /// @notice The address of the vault token.
    address public vault;
    /// @notice The address of the underlying asset token.
    address public asset;
    /// @notice The address of the underlying asset aggregator.
    address public assetAggregator;

    /// CONSTRUCTOR ///
    
    constructor(address _vault, address _asset, address _assetAggregator) {
        // We can use ICToken since its an erc4626 vault itself.
        if (ICToken(_vault).asset() != _asset) {
            revert BaseWrappedAggregator__InvalidConfig();
        }
        
        vault = _vault;
        asset = _asset;
        assetAggregator = _assetAggregator;
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Returns the underlying aggregator address.
    /// @return result The underlying aggregator address.
    function underlyingAggregator()
        public
        view
        override
        returns (address result)
    {
        result = assetAggregator;
    }

    /// @notice Returns the current exchange rate between the wrapped asset
    ///         and the underlying aggregator, in `WAD`.
    /// @return result The current exchange rate between the wrapped asset
    ///                and the underlying aggregator, in `WAD`.
    function getExchangeRate() public view virtual override returns (
        uint256 result
    ) {
        // Return exchange rate in `WAD` format directly.
        // We can use ICToken since its an erc4626 vault itself.
        result = ICToken(vault).convertToAssets(WAD);
    }
}
