// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseWrappedAggregator, WAD } from "contracts/oracles/adaptors/wrappedAggregators/BaseWrappedAggregator.sol";

import { ICToken } from "contracts/interfaces/ICToken.sol";

contract VaultAggregator is BaseWrappedAggregator {
    /// STORAGE ///

    /// @notice The address of the vault token.
    address public vaultToken;
    /// @notice The address of the underlying asset token.
    address public assetToken;
    /// @notice The address of the underlying asset aggregator.
    address public assetAggregator;

    /// CONSTRUCTOR ///
    
    constructor(
        address _vaultToken,
        address _assetToken,
        address _assetAggregator
    ) {
        vaultToken = _vaultToken;
        assetToken = _assetToken;
        assetAggregator = _assetAggregator;
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Returns the underlying aggregator address.
    /// @return result The underlying aggregator address.
    function underlyingAssetAggregator()
        public
        view
        override
        returns (address result)
    {
        result = assetAggregator;
    }

    /// @notice Returns the current exchange rate between the wrapped asset
    ///         and the underlying aggregator, in `WAD`.
    /// @return The current exchange rate between the wrapped asset
    ///         and the underlying aggregator, in `WAD`.
    function getExchangeRate() public view override returns (uint256 result) {
        // Return exchange rate in `WAD` format directly.
        // We can use ICToken since we just need to call convertToAssets.
        result = ICToken(vaultToken).convertToAssets(WAD);
    }
}
