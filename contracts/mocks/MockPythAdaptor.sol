// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { PythAdaptor, PricingResult } from "contracts/oracles/adaptors/pyth/PythAdaptor.sol";

contract MockPythAdaptor is PythAdaptor {
    bool skipHeartBeatCheck = true;
    
    constructor(
        ICentralRegistry centralRegistry_,
        address universalBalance_,
        address pyth_,
        address weth_,
        uint256 MAXIMUM_INCREASE_PER_YEAR,
        uint256 MINIMUM_INCREASE_PER_YEAR,
        uint256 MAXIMUM_TIMESTAMP_BUFFER,
        uint256 MINIMUM_TIMESTAMP_BUFFER
    ) PythAdaptor(
        centralRegistry_,
        universalBalance_,
        pyth_,
        weth_,
        MAXIMUM_INCREASE_PER_YEAR,
        MINIMUM_INCREASE_PER_YEAR,
        MAXIMUM_TIMESTAMP_BUFFER,
        MINIMUM_TIMESTAMP_BUFFER
    ) {}

    function setSkipHeartBeatCheck(bool skip) external {
        skipHeartBeatCheck = skip;
    }

    /// @notice Validates the feed data based on various constraints.
    /// @dev Checks if the value is within a specific range
    ///      and if the data is not outdated.
    /// @param value The value that is retrieved from the feed data.
    /// @param timestamp The time at which the value was last updated.
    /// @param max The maximum limit of the value.
    /// @param min The minimum limit of the value.
    /// @param heartbeat The maximum allowed time difference between
    ///                  current time and 'timestamp'.
    /// @return A boolean indicating whether the feed data had an error
    ///         (true = error, false = no error).
    function _verifyData(
        uint256 value,
        uint256 timestamp,
        uint256 max,
        uint256 min,
        uint256 heartbeat
    ) internal view override returns (bool) {
        // Validate `value` is not below the buffered min value allowed.
        if (value < min) {
            return true;
        }

        // Validate `value` is not above the buffered maximum value allowed.
        if (value > max) {
            return true;
        }

        // Validate the price returned is not stale.
        if (!skipHeartBeatCheck && block.timestamp - timestamp > heartbeat) {
            return true;
        }

        return false;
    }

    /// @notice Retrieves the price of a given asset in `inUSD` price form.
    /// @dev Calls getPriceUnsafe() from Pyth to get the latest data
    ///      for pricing and staleness.
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

        AssetConfig memory config = assetConfig[asset][inUSD];
        result.inUSD = inUSD;

        PythStructs.Price memory price = IPyth(pyth).getPriceUnsafe(
            config.priceId
        );

        // If we got a price of 0 or less, bubble up an error immediately.
        if (price.price <= 0) {
            result.hadError = true;
            return result;
        }

        uint256 adjustedPrice = _adjustPrice(
            asset,
            inUSD,
            uint256(int256(price.price)),
            uint256(int256(-1 * int8(price.expo)))
        );

        result.hadError = _verifyData(
            adjustedPrice,
            price.publishTime,
            config.max,
            config.min,
            config.heartbeat
        );

        result.price = uint240(adjustedPrice);
    }

    /// @notice Wipes supported asset pricing configs from an adaptor.
    function _wipeAssetConfigs(address asset) internal override {
        delete assetConfig[asset][true];
        delete assetConfig[asset][false];
    }
}
