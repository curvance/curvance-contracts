// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";

import { CommonLib } from "contracts/libraries/CommonLib.sol";
import { WAD } from "contracts/libraries/ConstantsLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";
import { IReader } from "contracts/interfaces/external/gmx/IReader.sol";

contract GMAdaptor is BaseOracleAdaptor {
    /// TYPES ///

    /// @notice Holds information regarding synthetic asset data
    ///         for synthetic-asset denominated GM tokens.
    /// @param asset The address of synthetic asset for native token.
    /// @param decimals The decimals of synthetic asset.
    struct SyntheticAsset {
        address asset;
        uint256 decimals;
    }

    /// CONSTANTS ///

    /// @dev keccak256(abi.encode("MAX_PNL_FACTOR_FOR_TRADERS"));
    bytes32 public constant PNL_FACTOR_TYPE =
        0xab15365d3aa743e766355e2557c230d8f943e195dc84d9b2b05928a07b635ee1;

    /// STORAGE ///

    /// @notice GMX Reader address.
    IReader public gmxReader;

    /// @notice GMX DataStore address.
    address public gmxDataStore;

    /// @notice GMX GM Token Market Data in array.
    /// @dev [alteredToken, longToken, shortToken, indexToken].
    ///      alteredToken is the address of altered token for synthetic token.
    ///      e.g. WBTC address for BTC.
    mapping(address => address[]) public marketData;

    /// @notice Underlying token address => Denomination for token
    ///         inside the GMX Reader.
    mapping(address => uint256) internal _priceUnit;

    /// EVENTS ///

    event AssetAdded(
        address asset,
        address[] marketTokens,
        bool isSynthetic,
        address alteredToken,
        bool isUpdate
    );

    /// ERRORS ///

    error GMAdaptor__ChainIsNotSupported();
    error GMAdaptor__GMXReaderIsZeroAddress();
    error GMAdaptor__GMXDataStoreIsZeroAddress();
    error GMAdaptor__MarketIsInvalid();
    error GMAdaptor__AlteredTokenIsInvalid();
    error GMAdaptor__MarketTokenIsNotSupported(address token);

    /// CONSTRUCTOR ///

    /// @dev Only deployable on Arbitrum.
    /// @param cr The address of central registry.
    /// @param gmxReader_ The address of GMX Reader.
    /// @param gmxDataStore_ The address of GMX DataStore.
    constructor(
        ICentralRegistry cr,
        address gmxReader_,
        address gmxDataStore_
    ) BaseOracleAdaptor(cr) {
        if (block.chainid != 42161) {
            revert GMAdaptor__ChainIsNotSupported();
        }

        _setGMXReader(gmxReader_);
        _setGMXDataStore(gmxDataStore_);
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Retrieves the price of a given GMX GM token.
    /// @dev Uses oracles (mostly Chainlink), can price both direct
    ///      and synthetic GM Tokens.
    /// @param asset The address of the asset for which the price is needed.
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
        bool /* inUSD */,
        bool getLower
    ) external view override returns (PricingResult memory result) {
        _checkSupportedAsset(asset);

        // Cache the Oracle Manager.
        IOracleManager om = CommonLib._oracleManager(centralRegistry);

        uint256[] memory prices = new uint256[](3);
        address[] memory tokens = marketData[asset];
        uint256 errorCode;
        address token;

        // Pull the prices for each underlying (constituent) token
        // making up the GMX GM token.
        for (uint256 i; i < 3; ++i) {
            token = tokens[i];

            (prices[i], errorCode) = om.getPrice(token, true, getLower);
            if (errorCode > 0) {
                result.hadError = true;
                return result;
            }

            prices[i] = (prices[i] * 1e30) / _priceUnit[token];
        }

        // Pull token pricing data from gmxReader.
        (int256 price, ) = gmxReader.getMarketTokenPrice(
            gmxDataStore,
            IReader.MarketProps(asset, tokens[3], tokens[1], tokens[2]),
            IReader.PriceProps(prices[0], prices[0]),
            IReader.PriceProps(prices[1], prices[1]),
            IReader.PriceProps(prices[2], prices[2]),
            PNL_FACTOR_TYPE,
            !getLower
        );

        // Make sure we got a positive price, bubble up an error,
        // if we got 0 or a negative number.
        if (price <= 0) {
            result.hadError = true;
            return result;
        }

        // Convert from 30 decimals to standardized 18.
        uint256 newPrice = uint256(price) / 1e12;

        // Validate price will not overflow on conversion to uint240.
        if (_checkOverflow(newPrice)) {
            result.hadError = true;
            return result;
        }

        result.inUSD = true;
        result.price = uint240(newPrice);
    }

    /// @notice Adds pricing support for `asset`, a GMX GM token.
    /// @dev Should be called before `OracleManager:addAssetPriceFeed`
    ///      is called.
    /// @param asset The address of the GMX GM token to add pricing
    ///              support for.
    /// @param alteredToken The address of the token to use to price
    ///                     a GM token synthetically.
    function addAsset(address asset, address alteredToken) external {
        _checkElevatedPermissions();

        IReader.MarketProps memory market = gmxReader.getMarket(
            gmxDataStore,
            asset
        );
        // Check whether the GM token needs to be synthetically priced.
        bool isSynthetic = market.indexToken.code.length == 0;

        // Validate the market is configured inside gmxReader.
        if (
            market.indexToken == address(0) ||
            market.longToken == address(0) ||
            market.shortToken == address(0)
        ) {
            revert GMAdaptor__MarketIsInvalid();
        }

        // Make sure both `asset` and `alteredToken` parameters
        // are configured properly.
        if (
            (isSynthetic && alteredToken == address(0)) ||
            (!isSynthetic && alteredToken != address(0))
        ) {
            revert GMAdaptor__AlteredTokenIsInvalid();
        }

        IOracleManager om = CommonLib._oracleManager(centralRegistry);

        address[] memory tokens = new address[](4);
        tokens[0] = isSynthetic ? alteredToken : market.indexToken;
        tokens[1] = market.longToken;
        tokens[2] = market.shortToken;
        tokens[3] = market.indexToken;

        address token;

        // Configure pricing denomination based on underlying tokens decimals.
        for (uint256 i; i < 3; ++i) {
            token = tokens[i];

            if (!om.isSupportedAsset(token)) {
                revert GMAdaptor__MarketTokenIsNotSupported(token);
            }

            if (_priceUnit[token] == 0) {
                _priceUnit[token] = WAD * 10 ** IERC20(token).decimals();
            }
        }

        // Save `tokens` and update mapping that we support `asset` now.
        marketData[asset] = tokens;

        // Check whether this is new or updated support for `asset`.
        bool isUpdate;
        if (isSupportedAsset[asset]) {
            isUpdate = true;
        }

        isSupportedAsset[asset] = true;
        emit AssetAdded(
            asset,
            tokens,
            isSynthetic,
            alteredToken,
            isUpdate
        );
    }

    /// @notice Returns the adaptor's type.
    /// @dev Used by frontends to determine how to properly interact
    ///      with a supported asset.
    /// @return The adaptor's type.
    function adaptorType() external pure override returns (uint256) {
        return 14;
    }

    /// PERMISSIONED FUNCTIONS ///

    /// @notice Permissioned function to set a new GMX Reader address.
    /// @param newReader The address to set as the new GMX Reader.
    function setGMXReader(address newReader) external {
        _checkMarketPermissions();

        _setGMXReader(newReader);
    }

    /// @notice Permissioned function to set a new GMX DataStore address.
    /// @param newDataStore The address to set as the new GMX DataStore.
    function setGMXDataStore(address newDataStore) external {
        _checkMarketPermissions();

        _setGMXDataStore(newDataStore);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Helper function to set a new GMX Reader address.
    /// @param newReader The address to set as the new GMX Reader.
    function _setGMXReader(address newReader) internal {
        if (newReader == address(0)) {
            revert GMAdaptor__GMXReaderIsZeroAddress();
        }

        gmxReader = IReader(newReader);
    }

    /// @notice Helper function to set a new GMX DataStore address.
    /// @param newDataStore The address to set as the new GMX DataStore.
    function _setGMXDataStore(address newDataStore) internal {
        if (newDataStore == address(0)) {
            revert GMAdaptor__GMXDataStoreIsZeroAddress();
        }

        gmxDataStore = newDataStore;
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
        delete marketData[asset];
    }
}