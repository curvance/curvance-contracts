// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { RedstoneCoreAdaptor, PricingResult } from "contracts/oracles/adaptors/redstone/RedstoneCoreAdaptor.sol";

contract MockRedstoneCoreAdaptor is RedstoneCoreAdaptor {

    constructor(
        ICentralRegistry centralRegistry_,
        address[] memory signers,
        uint256 _uniqueSignersThreshold,
        string memory nativeTokenSymbol,
        uint256 MAXIMUM_INCREASE_PER_YEAR,
        uint256 MINIMUM_INCREASE_PER_YEAR,
        uint256 MAXIMUM_TIMESTAMP_BUFFER,
        uint256 MINIMUM_TIMESTAMP_BUFFER
    ) RedstoneCoreAdaptor(
        centralRegistry_,
        signers,
        _uniqueSignersThreshold,
        nativeTokenSymbol,
        MAXIMUM_INCREASE_PER_YEAR,
        MINIMUM_INCREASE_PER_YEAR,
        MAXIMUM_TIMESTAMP_BUFFER,
        MINIMUM_TIMESTAMP_BUFFER
    ) {}

    function validateTimestamp(
        uint256 receivedTimestampMilliseconds
    ) public view override {
        // allow any timestamp
    }

    /// @notice Retrieves the price of a given asset in `inUSD` price form.
    /// @dev Extracts price from Redstone Core attached msg.data to get
    ///      the latest data. Natively validates staleness.
    /// @param asset The address of the asset for which the price is needed.
    /// @param inUSD Whether `asset` should be priced in USD or native tokens.
    /// @return result Return data for a priced asset containing:
    ///                price The price of the asset.
    ///                inUSD Boolean indicating whether `price` is denominated
    ///                      in USD (true) or native token (false).
    ///                hadError Boolean indicating whether the asset was priced
    ///                         without running into any issues or not.
    function _getPrice(
        address asset,
        bool inUSD
    ) internal view override returns (PricingResult memory result) {
        // Parse data from the format you want if its configured, otherwise
        // price in the other format and manually convert in Oracle Manager.
        if (!assetConfig[asset][inUSD].isConfigured) {
            inUSD = !inUSD; 
        }

        StoredPrice memory storedPrice = _storedPrice[asset][inUSD];
        result.inUSD = inUSD;
        // Validate the price returned is not stale.
        uint256 timestampInSeconds = storedPrice.redstoneTimestamp / 1000;
        if (
            timestampInSeconds < block.timestamp &&
            block.timestamp - timestampInSeconds > assetConfig[asset][inUSD].heartbeat
        ) {
            result.hadError = true;
            return result;
        }

        result.price = uint240(storedPrice.price);
    }

    /// @notice Wipes supported asset pricing configs from an adaptor.
    function _wipeAssetConfigs(address asset) internal override {
        delete assetConfig[asset][true];
        delete assetConfig[asset][false];
    }
}
