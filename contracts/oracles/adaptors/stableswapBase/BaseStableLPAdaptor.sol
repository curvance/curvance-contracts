// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";

import { WAD } from "contracts/libraries/Constants.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { PriceReturnData } from "contracts/interfaces/IOracleAdaptor.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";
import { IVeloPool } from "contracts/interfaces/external/velodrome/IVeloPool.sol";

abstract contract BaseStableLPAdaptor is BaseOracleAdaptor {
    /// TYPES ///

    /// @notice Stores configuration data for stableSwap style
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

    /// ERRORS ///

    error BaseStableLPAdaptor__AssetIsNotSupported();
    error BaseStableLPAdaptor__InvalidAssetType();

    /// CONSTRUCTOR ///

    /// @param centralRegistry_ The address of central registry.
    constructor(
        ICentralRegistry centralRegistry_,
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
    ) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Retrieves the price of `asset`, an lp token,
    ///         for a Univ2 style stable pool.
    /// @dev Price is returned in USD or a chain's native token depending on
    ///      'inUSD' parameter.
    /// @param asset The address of the asset for which the price is needed.
    /// @param inUSD Specifies whether the price format should be in USD (true)
    ///              or a chain's native token (false).
    /// @param getLower A boolean to determine if lower of two oracle prices
    ///                 should be retrieved.
    /// @return A structure containing the price, error status,
    ///         and the quote format of the price.
    function getPrice(
        address asset,
        bool inUSD,
        bool getLower
    ) external view virtual override returns (PriceReturnData memory) {
        return _getPrice(asset, inUSD, getLower);
    }

    /// @notice Adds pricing support for `asset`, an lp token for
    ///         a Univ2 style stable liquidity pool.
    /// @dev Should be called before `OracleManager:addAssetPriceFeed`
    ///      is called.
    /// @param asset The address of the lp token to support pricing for.
    function addAsset(address asset) external virtual {}

    /// @notice Removes a supported asset from the adaptor.
    /// @dev Calls back into Oracle Manager to notify it of its removal.
    ///      Requires that `asset` is currently supported.
    /// @param asset The address of the supported asset to remove from
    ///              the adaptor.
    function removeAsset(address asset) external virtual override {}

    /// INTERNAL FUNCTIONS ///

    /// @notice Retrieves the price of `asset`, an lp token,
    ///         for a Stableswap stable pool.
    /// @dev Prices stable pairs NOT volatile pairs.
    ///      Logic source: https://blog.alphaventuredao.io/fair-lp-token-pricing/
    ///      NOTE: Values are different since stable pairs use constant
    ///            product k >= x^3 * y + x * y^3. Instead of the standard
    ///            AMM formula.
    /// @param asset The address of the asset for which the price is needed.
    /// @param inUSD A boolean to determine if the price should be returned in
    ///              USD or not.
    /// @param getLower A boolean to determine if lower of two oracle prices
    ///                 should be retrieved.
    /// @return pData A structure containing the price, error status,
    ///               and the quote format of the price.
    function _getPrice(
        address asset,
        bool inUSD,
        bool getLower
    ) internal view returns (PriceReturnData memory pData) {
        // Validate we support pricing `asset`.
        if (!isSupportedAsset[asset]) {
            revert BaseStableLPAdaptor__AssetIsNotSupported();
        }

        // Read Adaptor storage and grab pool tokens.
        AssetConfig memory data = assetConfig[asset];
        IVeloPool pool = IVeloPool(asset);

        // Query LP reserves.
        (uint256 reserve0, uint256 reserve1, ) = pool.getReserves();

        // Standardize reserve values to 18 decimals.
        if (data.decimals0 != 18) {
            reserve0 = (reserve0 * WAD) / (10 ** data.decimals0);
        }

        if (data.decimals1 != 18) {
            reserve1 = (reserve1 * WAD) / (10 ** data.decimals1);
        }

        uint256 totalSupply = pool.totalSupply();
        uint256 price0;
        uint256 price1;
        uint256 errorCode;

        IOracleManager oracleManager = IOracleManager(
            centralRegistry.oracleManager()
        );
        (price0, errorCode) = oracleManager.getPrice(
            data.token0,
            inUSD,
            getLower
        );

        // Validate we did not run into any errors pricing token0.
        if (errorCode > 0) {
            pData.hadError = true;
            return pData;
        }

        (price1, errorCode) = oracleManager.getPrice(
            data.token1,
            inUSD,
            getLower
        );

        // Validate we did not run into any errors pricing token1.
        if (errorCode > 0) {
            pData.hadError = true;
            return pData;
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
            pData.hadError = true;
            return pData;
        }

        pData.inUSD = inUSD;
        pData.price = uint240(finalPrice);
    }

    /// @notice Helper function for pricing support for `asset`,
    ///         an lp token for a stableSwap style stable liquidity pool.
    /// @dev Should be called before `OracleManager:addAssetPriceFeed`
    ///      is called.
    /// @param asset The address of the lp token to add pricing support for.
    /// @return data The adaptor data for `asset`, returning the underlying tokens and decimals.
    function _addAsset(
        address asset
    ) internal returns (AssetConfig memory data) {
        IVeloPool pool = IVeloPool(asset);
        if (!pool.stable()) {
            revert BaseStableLPAdaptor__InvalidAssetType();
        }

        data.token0 = pool.token0();
        data.token1 = pool.token1();
        data.decimals0 = IERC20(data.token0).decimals();
        data.decimals1 = IERC20(data.token1).decimals();

        // Save adaptor data and update mapping that we support `asset` now.
        assetConfig[asset] = data;
        isSupportedAsset[asset] = true;
        return data;
    }

    /// @notice Helper function to remove a supported asset from the adaptor.
    /// @dev Calls back into Oracle Manager to notify it of its removal.
    ///      Requires that `asset` is currently supported.
    /// @param asset The address of the supported asset to remove from
    ///              the adaptor.
    function _removeAsset(address asset) internal {
        // Validate that `asset` is currently supported.
        if (!isSupportedAsset[asset]) {
            revert BaseStableLPAdaptor__AssetIsNotSupported();
        }

        // Wipe config mapping entries for a gas refund.
        // Notify the adaptor to stop supporting the asset.
        delete isSupportedAsset[asset];
        delete assetConfig[asset];

        // Notify the Oracle Manager that we are going to stop supporting
        // the asset.
        IOracleManager(centralRegistry.oracleManager()).notifyFeedRemoval(
            asset
        );
    }

    /// @notice Helper function in calculating the price of an lp token.
    ///         Uses reserves, and pricing of each underlying token versus
    ///         the total supply of lp tokens making up the pool.
    /// @dev Prices stable pairs NOT volatile pairs.
    ///      Logic source: https://blog.alphaventuredao.io/fair-lp-token-pricing/
    ///      NOTE: Values are different since stable pairs use constant
    ///            product k >= x^3 * y + x * y^3. Instead of the standard
    ///            AMM formula.
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
        // k = x^3 * y + x * y^3. Where x = reserve0, y = reserve1.
        uint256 sqrtK = FixedPointMathLib.sqrt(
            FixedPointMathLib.sqrt(reserve0 * reserve1) *
                FixedPointMathLib.sqrt(
                    reserve0 * reserve0 + reserve1 * reserve1
                )
        );

        uint256 ratio = (WAD * price0) / price1;
        uint256 sqrtPrice = _sqrt(
            _sqrt(WAD * ratio) *
            _sqrt(1e36 + ratio * ratio)
        );
        return (2 * sqrtK * price0 * WAD) / (sqrtPrice * totalSupply);
    }

    function _sqrt(uint256 x) internal pure returns (uint256) {
        return FixedPointMathLib.sqrt(x);
    }
}
