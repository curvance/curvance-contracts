// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";
import { ERC20 } from "contracts/libraries/external/ERC20.sol";

import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IStaticOracle } from "contracts/interfaces/external/uniswap/IStaticOracle.sol";
import { UniswapV3Pool } from "contracts/interfaces/external/uniswap/UniswapV3Pool.sol";

contract UniswapV3Adaptor is BaseOracleAdaptor {
    /// TYPES ///

    /// @title Uniswap V3 Adaptor Data
    /// @notice Stores configuration data for Uniswap V3 twap price sources.
    /// @param priceSource The address location where you query
    ///                    the associated assets twap price.
    /// @param secondsAgo Period used for twap calculation.
    /// @param baseDecimals The decimals of base asset you want to price.
    /// @param quoteDecimals The decimals asset price is quoted in.
    /// @param quoteToken The asset twap calulation denominates in.
    struct AssetConfig {
        address priceSource;
        uint32 secondsAgo;
        uint8 baseDecimals;
        uint8 quoteDecimals;
        address quoteToken;
    }

    /// CONSTANTS ///

    /// @notice The smallest possible twap that can be used.
    ///         900 = 15 minutes.
    uint32 public constant MINIMUM_SECONDS_AGO = 900;

    /// @notice The address of wrapped native token on this chain.
    address public immutable wrappedNative;

    /// @notice Static uniswap Oracle Manager address.
    IStaticOracle public immutable uniswapOracleManager;

    /// STORAGE ///

    /// @notice Price feed configuration data for an asset.
    /// @dev Token address => Price feed configuration for `asset`.
    mapping(address => AssetConfig) public assetConfig;

    /// EVENTS ///

    event AssetAdded(address asset, AssetConfig config, bool isUpdate);

    /// ERRORS ///

    error UniswapV3Adaptor__ChainIsNotSupported();
    error UniswapV3Adaptor__AssetIsNotSupported();
    error UniswapV3Adaptor__SecondsAgoIsLessThanMinimum();

    /// CONSTRUCTOR ///

    /// @param centralRegistry_ The address of central registry.
    constructor(
        ICentralRegistry centralRegistry_,
        IStaticOracle oracleAddress_,
        address wrappedNative_,
        uint256 MAXIMUM_INCREASE_PER_YEAR,
        uint256 MINIMUM_INCREASE_PER_YEAR,
        uint256 MAXIMUM_TIMESTAMP_BUFFER,
        uint256 MINIMUM_TIMESTAMP_BUFFER
    ) BaseOracleAdaptor(
        centralRegistry_,
        MAXIMUM_INCREASE_PER_YEAR,
        MINIMUM_INCREASE_PER_YEAR,
        MAXIMUM_TIMESTAMP_BUFFER,
        MINIMUM_TIMESTAMP_BUFFER
    ) {
        if (block.chainid != 1) {
            revert UniswapV3Adaptor__ChainIsNotSupported();
        }

        uniswapOracleManager = oracleAddress_;
        wrappedNative = wrappedNative_;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Retrieves the price of `asset` using a Univ3 pool.
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

        AssetConfig memory config = assetConfig[asset];

        address[] memory pools = new address[](1);
        pools[0] = config.priceSource;
        uint256 twapPrice;

        // Pull twap price via a staticcall.
        (bool success, bytes memory returnData) = address(uniswapOracleManager)
            .staticcall(
                abi.encodePacked(
                    uniswapOracleManager
                        .quoteSpecificPoolsWithTimePeriod
                        .selector,
                    abi.encode(
                        10 ** config.baseDecimals,
                        asset,
                        config.quoteToken,
                        pools,
                        config.secondsAgo
                    )
                )
            );

        if (success) {
            // Extract the twap price from returned calldata.
            twapPrice = abi.decode(returnData, (uint256));
        } else {
            // Uniswap twap check reverted, bubble up an error.
            result.hadError = true;
            return result;
        }

        IOracleManager OracleManager = IOracleManager(
            centralRegistry.oracleManager()
        );
        result.inUSD = inUSD;

        // We want the asset price in USD which uniswap cant do,
        // so find out the price of the quote token in USD then divide
        // so its in USD.
        if (inUSD) {
            if (!OracleManager.isSupportedAsset(config.quoteToken)) {
                // Our Oracle Manager does not know how to value this quote
                // token, so, we cant use the twap data, bubble up an error.
                result.hadError = true;
                return result;
            }

            (uint256 quoteTokenDenominator, uint256 errorCode) = OracleManager
                .getPrice(config.quoteToken, true, getLower);

            // Validate we did not run into any errors pricing the quote asset.
            if (errorCode > 0) {
                result.hadError = true;
                return result;
            }

            // We have a route to USD pricing so we can convert
            // the quote token price to USD and return.
            uint256 newPrice = (twapPrice * quoteTokenDenominator) /
                (10 ** config.quoteDecimals);

            // Validate price will not overflow on conversion to uint240.
            if (_checkOverflow(newPrice)) {
                result.hadError = true;
                return result;
            }

            result.price = uint240(newPrice);
            return result;
        }

        if (config.quoteToken != wrappedNative) {
            if (!OracleManager.isSupportedAsset(config.quoteToken)) {
                // Our Oracle Manager does not know how to value this quote
                // token so we cant use the twap data.
                result.hadError = true;
                return result;
            }

            (uint256 quoteTokenDenominator, uint256 errorCode) = OracleManager
                .getPrice(config.quoteToken, false, getLower);

            // Validate we did not run into any errors pricing the quote asset.
            if (errorCode > 0) {
                result.hadError = true;
                return result;
            }

            // Adjust decimals if necessary.
            uint256 newPrice = (twapPrice * quoteTokenDenominator) /
                (10 ** config.quoteDecimals);

            // Validate price will not overflow on conversion to uint240.
            if (_checkOverflow(newPrice)) {
                result.hadError = true;
                return result;
            }

            // We have a route to ETH pricing so we can convert
            // the quote token price to ETH and return.
            result.price = uint240(newPrice);
            return result;
        }

        // Validate price will not overflow on conversion to uint240.
        if (_checkOverflow(twapPrice)) {
            result.hadError = true;
            return result;
        }

        result.price = uint240(twapPrice);
    }

    /// @notice Adds pricing support for `asset`, a token inside a Univ3 lp.
    /// @dev Should be called before `OracleManager:addAssetPriceFeed`
    ///      is called.
    /// @param asset The address of the token to add pricing support for.
    /// @param config The adaptor data needed to add `asset`.
    function addAsset(address asset, AssetConfig memory config) external {
        _checkElevatedPermissions();

        // Verify twap time sample is reasonable.
        if (config.secondsAgo < MINIMUM_SECONDS_AGO) {
            revert UniswapV3Adaptor__SecondsAgoIsLessThanMinimum();
        }

        UniswapV3Pool pool = UniswapV3Pool(config.priceSource);

        // Query tokens from pool directly to minimize misconfiguration.
        address token0 = pool.token0();
        address token1 = pool.token1();
        if (token0 == asset) {
            config.baseDecimals = ERC20(asset).decimals();
            config.quoteDecimals = ERC20(token1).decimals();
            config.quoteToken = token1;
        } else if (token1 == asset) {
            config.baseDecimals = ERC20(asset).decimals();
            config.quoteDecimals = ERC20(token0).decimals();
            config.quoteToken = token0;
        } else revert UniswapV3Adaptor__AssetIsNotSupported();

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
        return 7;
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