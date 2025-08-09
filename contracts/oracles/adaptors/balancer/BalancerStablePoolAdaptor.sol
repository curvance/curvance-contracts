// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BalancerBaseAdaptor } from "contracts/oracles/adaptors/balancer/BalancerBaseAdaptor.sol";

import { CommonLib } from "contracts/libraries/CommonLib.sol";
import { WAD } from "contracts/libraries/ConstantsLib.sol";

import { IVault } from "contracts/interfaces/external/balancer/IVault.sol";
import { IBalancerPool } from "contracts/interfaces/external/balancer/IBalancerPool.sol";
import { IRateProvider } from "contracts/interfaces/external/balancer/IRateProvider.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";

contract BalancerStablePoolAdaptor is BalancerBaseAdaptor {
    /// TYPES ///

    /// @title Balancer Stable Pool Adaptor Data
    /// @notice Stores configuration data for Balance BPT pricing.
    /// @dev Only use the underlying asset, if the underlying is correlated
    ///      to the pools virtual base.
    /// @param poolId The pool id of the BPT being priced.
    /// @param poolDecimals The decimals of the BPT being priced.
    /// @param rateProviders Array of rate providers for each constituent,
    ///        a zero address rate provider means we are using an underlying
    ///        correlated to the pools virtual base.
    /// @param underlyingOrConstituent The ERC20 underlying asset or
    ///                                the constituent in the pool.
    struct AssetConfig {
        bytes32 poolId;
        uint8 poolDecimals;
        uint8[8] rateProviderDecimals;
        address[8] rateProviders;
        address[8] underlyingOrConstituent;
    }

    /// STORAGE ///

    /// @notice Price feed configuration data for an asset.
    /// @dev Token address => Price feed configuration for `asset`.
    mapping(address => AssetConfig) public assetConfig;

    /// EVENTS ///

    event AssetAdded(address asset, AssetConfig config, bool isUpdate);

    /// ERRORS ///

    error BalancerStablePoolAdaptor__ConfigurationError();

    /// CONSTRUCTOR ///

    /// @param cr The address of central registry.
    constructor(
        ICentralRegistry cr,
        IVault vault
    ) BalancerBaseAdaptor(cr, vault) {
        balancerVault = vault;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Retrieves the price of a given BPT.
    /// @dev Price is returned in USD or a chain's native token depending on
    ///      'inUSD' parameter.
    /// @param asset The address of the asset for which the price is needed.
    /// @param inUSD Specifies whether the price format should be in USD (true)
    ///              or a chain's native token (false).
    /// @param getLower A boolean to determine if lower of two oracle prices
    ///                 should be retrieved.
    /// @return result Return data for a priced asset containing:
    ///                price The price of the asset.
    ///                inUSD Boolean indicating whether `price` is denominated
    ///                      in USD (true) or native token (false).
    ///                hadError Boolean indicating whether the asset was priced
    ///                         without running into any issues or not.
    function getPrice(
        address asset,
        bool inUSD,
        bool getLower
    ) external view override returns (PricingResult memory result) {
        _checkSupportedAsset(asset);

        // Validate that the vault is not being reentered.
        _ensureNotInVaultContext(balancerVault);

        // Cache pricing asset config.
        AssetConfig memory config = assetConfig[asset];
        IBalancerPool pool = IBalancerPool(asset);

        result.inUSD = inUSD;
        IOracleManager om = CommonLib._oracleManager(centralRegistry);

        // Find the minimum price of all the pool tokens.
        uint256 numUnderlyingOrConstituent = config
            .underlyingOrConstituent
            .length;
        uint256 averagePrice;
        uint256 numPrices;

        uint256 price;
        uint256 errorCode;
        for (uint256 i; i < numUnderlyingOrConstituent; ++i) {
            // Break when a zero address is found.
            if (address(config.underlyingOrConstituent[i]) == address(0)) {
                break;
            }

            (price, errorCode) = om.getPrice(
                config.underlyingOrConstituent[i],
                inUSD,
                getLower
            );

            // If we had an error pricing the quote asset, bubble up an error.
            if (errorCode > 0) {
                result.hadError = true;
                return result;
            }

            // We must first normalize the price using the rate from the RateProvider.
            // If there is no RateProvider, assume a rate of 1
            // (note that `rateProviderDecimals` is unreliable in this case).
            address rateProvider = config.rateProviders[i];
            uint256 normalizedPrice;
            if (rateProvider == address(0)) {
                normalizedPrice = price;
            } else {
                normalizedPrice =
                    (price * (10 ** config.rateProviderDecimals[i])) /
                    IRateProvider(rateProvider).getRate();
            }
            averagePrice += normalizedPrice;
            ++numPrices;
        }

        // If we were not able to price anything, bubble up an error.
        if (averagePrice == 0) {
            result.hadError = true;
            return result;
        }

        averagePrice = ((averagePrice / numPrices) * pool.getRate()) / WAD;

        // Validate price will not overflow on conversion to uint240.
        if (_checkOverflow(averagePrice)) {
            result.hadError = true;
            return result;
        }

        result.price = uint240(averagePrice);
    }

    /// @notice Adds pricing support for `asset`, a new Balancer BPT.
    /// @dev Should be called before `OracleManager:addAssetPriceFeed`
    ///      is called.
    /// @param asset The address of the BPT to add pricing support for.
    /// @param config The adaptor data needed to add `asset`.
    function addAsset(address asset, AssetConfig memory config) external {
        _checkElevatedPermissions();

        IBalancerPool pool = IBalancerPool(asset);

        // Query the poolId and decimals from the pool contract.
        config.poolId = pool.getPoolId();
        config.poolDecimals = pool.decimals();

        uint256 numUnderlyingOrConstituent = config
            .underlyingOrConstituent
            .length;

        // Make sure we can price all underlying tokens.
        for (uint256 i; i < numUnderlyingOrConstituent; ++i) {
            // Continue when a zero address is found.
            if (address(config.underlyingOrConstituent[i]) == address(0)) {
                continue;
            }

            if (!CommonLib._oracleManager(centralRegistry)
                    .isSupportedAsset(config.underlyingOrConstituent[i])
            ) {
                revert BalancerStablePoolAdaptor__ConfigurationError();
            }

            if (config.rateProviders[i] != address(0)) {
                // Make sure decimals were provided.
                if (config.rateProviderDecimals[i] == 0) {
                    revert BalancerStablePoolAdaptor__ConfigurationError();
                }

                // Make sure we can call it and get a non zero value.
                if (IRateProvider(config.rateProviders[i]).getRate() == 0) {
                    revert BalancerStablePoolAdaptor__ConfigurationError();
                }
            }
        }

        // Save `config` and update mapping that we support `asset` now.
        assetConfig[asset] = config;

        // Check whether this is new or updated support for `asset`.
        bool isUpdate;
        if (isSupportedAsset[asset]) {
            isUpdate = true;
        }

        isSupportedAsset[asset] = true;
        emit AssetAdded(asset, config, isUpdate);
    }

    /// @notice Returns the adaptor's type.
    /// @dev Used by frontends to determine how to properly interact
    ///      with a supported asset.
    /// @return The adaptor's type.
    function adaptorType() external pure override returns (uint256) {
        return 13;
    }

    /// INTERNAL FUNCTIONS TO OVERRIDE ///

    /// @notice Retrieves the price of a given asset in `inUSD` price form.
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
    ) internal view virtual override returns (PricingResult memory result) {}

    /// @notice Wipes supported asset pricing configs from an adaptor.
    function _wipeAssetConfigs(address asset) internal override {
        delete assetConfig[asset];
    }
}