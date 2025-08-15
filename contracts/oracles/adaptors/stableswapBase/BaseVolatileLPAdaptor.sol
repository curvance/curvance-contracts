// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";

import { CommonLib } from "contracts/libraries/CommonLib.sol";
import { WAD } from "contracts/libraries/ConstantsLib.sol";

import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";
import { IVeloPool } from "contracts/interfaces/external/velodrome/IVeloPool.sol";

abstract contract BaseVolatileLPAdaptor is BaseOracleAdaptor {
    /// TYPES ///

    /// @notice Stores configuration data for Uniswap V2 volatile style
    ///         Twap price sources.
    /// @param token0 Underlying token0 address.
    /// @param decimals0 Underlying decimals for token0.
    /// @param token1 Underlying token1 address.
    /// @param decimals1 Underlying decimals for token1.
    struct AssetConfig {
        address token0;
        uint8 decimals0;
        address token1;
        uint8 decimals1;
    }

    /// STORAGE ///

    /// @notice Price feed configuration data for an asset.
    /// @dev Token address => Price feed configuration for `asset`.
    mapping(address => AssetConfig) public assetConfig;

    /// EVENTS ///

    event AssetAdded(address asset, AssetConfig config, bool isUpdate);

    /// ERRORS ///

    error BaseVolatileLPAdaptor__InvalidAssetType();

    /// CONSTRUCTOR ///

    /// @param cr The address of central registry.
    constructor(ICentralRegistry cr) BaseOracleAdaptor(cr) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Retrieves the price of `asset`, an lp token,
    ///         for a Univ2 style volatile pool.
    /// @dev Price is returned in USD or a chain's native token depending on
    ///      'inUSD' parameter.
    ///      Prices volatile pairs NOT stable pairs.
    ///      Math source: https://blog.alphaventuredao.io/fair-lp-token-pricing/
    ///      NOTE: Uses standard volatile asset AMM formula using constant
    ///            product k >= x * y.
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
    ) external view virtual override returns (PricingResult memory result) {
        _checkSupportedAsset(asset);

        // Cache asset config and grab pool tokens.
        AssetConfig memory config = assetConfig[asset];
        IVeloPool pool = IVeloPool(asset);

        // Query LP reserves.
        (uint256 reserve0, uint256 reserve1, ) = pool.getReserves();

        // Standardize reserve values to 18 decimals.
        if (config.decimals0 != 18) {
            reserve0 = (reserve0 * WAD) / (10 ** config.decimals0);
        }

        if (config.decimals1 != 18) {
            reserve1 = (reserve1 * WAD) / (10 ** config.decimals1);
        }

        uint256 totalSupply = pool.totalSupply();
        uint256 price0;
        uint256 price1;
        uint256 errorCode;

        IOracleManager om = CommonLib._oracleManager(centralRegistry);
        (price0, errorCode) = om.getPrice(config.token0, inUSD, getLower);

        // Validate we did not run into any errors pricing token0.
        if (errorCode > 0) {
            result.hadError = true;
            return result;
        }

        (price1, errorCode) = om.getPrice(config.token1, inUSD, getLower);

        // Validate we did not run into any errors pricing token1.
        if (errorCode > 0) {
            result.hadError = true;
            return result;
        }

        uint256 finalPrice = _getFairPrice(
            reserve0,
            reserve1,
            price0,
            price1,
            totalSupply
        );

        // Validate price will not overflow on conversion to uint240.
        if (_checkOverflow(finalPrice)) {
            result.hadError = true;
            return result;
        }

        result.inUSD = inUSD;
        result.price = uint240(finalPrice);
    }

    /// @notice Adds pricing support for `asset`, an lp token for
    ///         a stable swap style stable liquidity pool.
    /// @dev Should be called before `OracleManager:addAssetPriceFeed`
    ///      is called.
    /// @param asset The address of the lp token to add pricing support for.
    function addAsset(address asset) external {
        _checkElevatedPermissions();

        IVeloPool pool = IVeloPool(asset);
        _checkLPType(pool);

        // Check whether this is new or updated support for `asset`.
        bool isUpdate;
        if (isSupportedAsset[asset]) {
            isUpdate = true;
        }

        AssetConfig memory config;
        config.token0 = pool.token0();
        config.token1 = pool.token1();
        config.decimals0 = IERC20(config.token0).decimals();
        config.decimals1 = IERC20(config.token1).decimals();

        // Save asset config and update mapping that we support `asset` now.
        assetConfig[asset] = config;
        isSupportedAsset[asset] = true;

        emit AssetAdded(asset, config, isUpdate);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Helper function in calculating the price of an lp token.
    ///         Uses reserves, and pricing of each underlying token versus
    ///         the total supply of lp tokens making up the pool.
    /// @dev Prices volatile pairs NOT stable pairs.
    ///      Math source: https://blog.alphaventuredao.io/fair-lp-token-pricing/
    ///      NOTE: Uses standard volatile asset AMM formula using constant
    ///            product k >= x * y.
    /// @param reserve0 The amount of underlying token0 inside the liquidity pool.
    /// @param reserve1 The amount of underlying token1 inside the liquidity pool.
    /// @param price0 The price of token0 according to the Oracle Manager.
    /// @param price0 The price of token1 according to the Oracle Manager.
    /// @param totalSupply The total supply of lp tokens inside the lp.
    /// @return Fair value pricing for the lp token.
    function _getFairPrice(
        uint256 reserve0,
        uint256 reserve1,
        uint256 price0,
        uint256 price1,
        uint256 totalSupply
    ) internal pure returns (uint256) {
        // k >= x * y. Where x = reserve0, y = reserve1.
        uint256 sqrtK = FixedPointMathLib.sqrt(reserve0 * reserve1);

        // price = 2 * (x * y) * sqrt(price0 * price1) / totalSupply.
        return (2 * sqrtK * _sqrt(price0 * price1)) / totalSupply;
    }

    function _sqrt(uint256 x) internal pure returns (uint256) {
        return FixedPointMathLib.sqrt(x);
    }

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

    /// @notice Wipes `asset` pricing configurations from this adaptor.
    /// @param asset The address of the asset to wipe pricing support of.
    function _wipeAssetConfigs(address asset) internal override {
        delete assetConfig[asset];
    }

    /// INTERNAL FUNCTIONS TO OVERRIDE ///

    /// @notice Checks whether `asset` is the proper type of LP to try
    ///         to support.
    function _checkLPType(IVeloPool /* asset */) internal view virtual;
}