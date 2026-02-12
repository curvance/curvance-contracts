// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Interface for adaptors that use Chainlink-style aggregator configurations.
/// @dev Works with ChainlinkAdaptor, RedstoneClassicAdaptor, and similar
///      adaptors that have the assetConfig(address, bool) mapping pattern.
interface IChainlinkStyleAdaptor {
    function assetConfig(
        address asset,
        bool inUSD
    )
        external
        view
        returns (
            bool isConfigured,
            address aggregator,
            uint8 decimals,
            uint24 heartbeat
        );
}
