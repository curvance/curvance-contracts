// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";
import { WAD, BASIS_POINTS, NO_ERROR, CAUTION, BAD_SOURCE } from "contracts/libraries/ConstantsLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { ICToken, AccountSnapshot } from "contracts/interfaces/ICToken.sol";
import { IOracleAdaptor } from "contracts/interfaces/IOracleAdaptor.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";

import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";

/// @title Curvance Dynamic Pessimistic Dual Oracle Manager.
/// @notice Provides a universal interface allowing contracts
///         to retrieve secure pricing data based on various price feeds.
/// @dev The Curvance Oracle Manager acts as a unified hub for pricing anything.
///      The Oracle Manager can support up to two oracle adaptors, returning
///      a maximum of two prices for any asset.
///
///      Prices can be returned in USD or a chain's native gas token.
///      Either the higher or lower of the two prices can returned, based on
///      what is desired. For Curvance protocol, the more advantageous of both
///      prices is used. For user collateralized assets, the lower of the two
///      prices is used. For user debt positions, the higher of the two prices
///      is used.
///
///      Curvance specific voucher tokens can also be priced by the Oracle
///      Router, based on the exchange rate between the voucher token, and
///      its underlying token.
///
///      The Oracle Manager also relays feedback based on any issues that
///      occurred during pricing an asset. This takes the form of three error
///      codes that are returned on querying a price or prices:
///      - An error code of 0 corresponds to no error occurred during pricing.
///      - An error code of 1 corresponds to moderate issues occurring
///        during pricing, inside Curvance this results in new borrowing
///        queries being blocked.
///      - An error code of 2 corresponds to large issues occurring during
///        pricing, inside Curvance this results in all actions being paused
///        involving that asset.
///
///      "Circuit Breakers" have been introduced, that can be triggered based
///      on the prices returned to the Oracle Manager. If prices diverge
///      heavily, error codes can be returned. Based on current default
///      configurations:
///      - An error code of 1 will be triggered by a 50 basis point or greater
///        price divergence.
///      - An error code of 2 will be triggered by a 100 basis point or greater
///        price divergence.
///
///      Oracle Adaptors can be added or removed by the DAO which can change
///      how an asset is priced. This allows for continually improving the
///      data quality returned within the system. Oracle Adaptors handle
///      checks such as price staleness, decimal offsetting, and ecosystem
///      specific logic. All this is abstracted away from the Oracle Manager,
///      all data is returned in a standardized format of 18 decimals with a
///      minimum price of 1, and a maximum price of 2^240 - 1. Though,
///      some oracle adaptors have lower maximums, which will natively
///      restrict the maximum price returned. Such as Chainlink's uint192
///      maximum. When using the Oracle Manager, verify what oracle adaptors
///      will be used behind the scenes if you want to impose heavier
///      restrictions on minimum/maximum price.
///
///      Oracle Adaptors also can be used to introduce realtime information
///      based on offchain logic such as dynamic liquidation penalties.
///
///      The Oracle Manager was built to minimize Oracle trust by introducing
///      a decentralized model, many oracle providers all verified against
///      each other. "Don't trust, verify."
///
contract OracleManager is IOracleManager {
    /// CONSTANTS ///

    /// @notice Address identifying a chain's native token.
    address public constant native =
        0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    /// @notice Time to pass before accepting answers when sequencer
    ///         comes back up.
    uint256 public constant GRACE_PERIOD_TIME = 3600;
    /// @notice Maximum value that a price divergence flag can be set as
    ///         inside the protocol.
    /// @dev 1.03e4 = 3.0%.
    uint256 public constant MAX_DIVERGENCE_VALUE = 10300;
    /// @notice Minimum value that a price divergence flag can be set as
    ///         inside the protocol.
    /// @dev 1.002e4 = 0.2%.
    uint256 public constant MIN_DIVERGENCE_VALUE = 10020;

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;

    /// STORAGE ///

    /// @notice The maximum allowed price feed divergence between prices
    ///         before `CAUTION` error code is returned, in `BASIS_POINTS`.
    /// @dev 10050 = 0.5% = 50 basis point price feed deviation allowed.
    uint128 public cautionPriceDivergence = 10050;
    /// @notice The maximum allowed price feed divergence between prices
    ///         before `BAD_SOURCE` error code is returned, in `BASIS_POINTS`.
    /// @dev 10100 = 1% = 100 basis point price feed deviation allowed.
    uint128 public badSourcePriceDivergence = 10100;

    // Address => Adaptor approval status.
    mapping(address => bool) public isApprovedAdaptor;
    // Address => Price Feed addresses.
    mapping(address => address[]) public assetPriceFeeds;
    // Address => Curvance token metadata.
    mapping(address => CToken) public cTokens;

    /// ERRORS ///

    error OracleManager__Unauthorized();
    error OracleManager__NotSupported();
    error OracleManager__InvalidParameter();
    error OracleManager__ErrorCodeFlagged();
    error OracleManager__AdaptorIsNotApproved();

    /// CONSTRUCTOR ///

    constructor(ICentralRegistry cr) {
        CentralRegistryLib._isCentralRegistry(cr);
        centralRegistry = cr;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Adds a new price feed for a specific asset.
    /// @dev Requires that the feed address is an approved adaptor,
    ///      and that the asset doesn't already have two feeds.
    /// @param asset The address of the asset.
    /// @param feed The address of the new feed.
    function addAssetPriceFeed(address asset, address feed) external {
        _checkElevatedPermissions();
        _addFeed(asset, feed);
    }

    /// @notice Replaces one price feed with a new price feed for a specific
    ///         asset.
    /// @dev Requires that the feed address is an approved adaptor,
    ///      and that the asset has at least one feed.
    /// @param asset The address of the asset.
    /// @param feedToAdd The address of the feed to remove.
    /// @param feedToAdd The address of the new feed.
    function replaceAssetPriceFeed(
        address asset,
        address feedToRemove,
        address feedToAdd
    ) external {
        _checkElevatedPermissions();

        // Validate that the feeds are not identical as there would be no
        // point to replace a feed with itself.
        if (feedToRemove == feedToAdd) {
            revert OracleManager__InvalidParameter();
        }

        _removeFeed(asset, feedToRemove);
        _addFeed(asset, feedToAdd);
    }

    /// @notice Removes a price feed for a specific asset.
    /// @dev Requires that the feed exists for the asset.
    /// @param asset The address of the asset.
    /// @param feed The address of the feed to be removed.
    function removeAssetPriceFeed(address asset, address feed) external {
        _checkElevatedPermissions();
        _removeFeed(asset, feed);
    }

    /// @notice Removes a price feed for a specific asset
    ///         triggered by an adaptors notification.
    /// @dev Requires that the feed exists for the asset.
    /// @param asset The address of the asset.
    function notifyFeedRemoval(address asset) external {
        _checkIsApprovedAdaptor(msg.sender);
        _removeFeed(asset, msg.sender);
    }

    /// @notice Adds a new Curvance token to the Oracle Manager.
    /// @dev Requires that `newCToken` isn't already supported.
    /// @param newCToken The address of the Curvance token to support.
    function addCTokenSupport(address newCToken) external {
        _checkElevatedPermissions();

        if (cTokens[newCToken].isCToken) {
            revert OracleManager__InvalidParameter();
        }

        // We call a Curvance-specific token function as a sanity check.
        ICToken(newCToken).isBorrowable();

        cTokens[newCToken].isCToken = true;
        cTokens[newCToken].underlying = ICToken(newCToken).asset();
    }

    /// @notice Removes a Curvance token's support in the Oracle Manager.
    /// @dev Requires that the Curvance token is supported.
    /// @param cTokenToRemove The address of the Curvance token to remove
    ///                       support for.
    function removeCTokenSupport(address cTokenToRemove) external {
        _checkElevatedPermissions();

        if (!cTokens[cTokenToRemove].isCToken) {
            revert OracleManager__InvalidParameter();
        }

        delete cTokens[cTokenToRemove];
    }

    /// @notice Adds `newAdaptor` as an approved adaptor.
    /// @dev Requires that the adaptor isn't already approved.
    /// @param adaptorToAdd The address of the adaptor to approve.
    function addApprovedAdaptor(address adaptorToAdd) external {
        _checkElevatedPermissions();

        // Validate `adaptorToAdd` is not already supported.
        if (isApprovedAdaptor[adaptorToAdd]) {
            revert OracleManager__InvalidParameter();
        }

        isApprovedAdaptor[adaptorToAdd] = true;
    }

    /// @notice Removes adaptor approval for `adaptorToRemove`, then,
    ///         adds adaptor approval for `adaptorToAdd`.
    /// @dev Requires that the adaptor isn't already approved.
    /// @param adaptorToRemove The address of the adaptor to remove approval.
    /// @param adaptorToAdd The address of the adaptor to approve.
    function replaceApprovedAdaptor(
        address adaptorToRemove,
        address adaptorToAdd
    ) external {
        _checkElevatedPermissions();

        // Validate `adaptorToAdd` is not already supported.
        if (isApprovedAdaptor[adaptorToAdd]) {
            revert OracleManager__InvalidParameter();
        }

        // Validate `adaptorToRemove` is currently supported.
        _checkIsApprovedAdaptor(adaptorToRemove);

        // Validate that the adaptors are not identical as there would be no
        // point to replace an adaptor with itself.
        if (adaptorToAdd == adaptorToRemove) {
            revert OracleManager__InvalidParameter();
        }

        delete isApprovedAdaptor[adaptorToRemove];
        isApprovedAdaptor[adaptorToAdd] = true;
    }

    /// @notice Removes `adaptorToRemove` as an approved adaptor.
    /// @dev Requires that the adaptor is currently approved.
    /// @param adaptorToRemove The address of the adaptor to remove.
    function removeApprovedAdaptor(address adaptorToRemove) external {
        _checkElevatedPermissions();
        // Validate `adaptorToRemove` is currently supported.
        _checkIsApprovedAdaptor(adaptorToRemove);

        delete isApprovedAdaptor[adaptorToRemove];
    }

    /// @notice Sets a new maximum divergence for price feeds
    ///         before CAUTION or BAD_SOURCE error codes are activated.
    /// @param newCaution The new maximum price divergence before a
    ///                   `CAUTION` error code is returned.
    /// @param newBadSource The new maximum price divergence before a
    ///                     `BAD_SOURCE` error code is returned.
    function setDivergenceFlags(
        uint256 newCaution,
        uint256 newBadSource
    ) external {
        _checkElevatedPermissions();

        // Validate that the `CAUTION` error code will not occur after
        // `BAD_SOURCE`, because `BAD_SOURCE` is the more significant error
        // than `CAUTION`.
        if (newCaution >= newBadSource) {
            revert OracleManager__InvalidParameter();
        }

        // Validate divergence values are within acceptable value range.
        if (
            newCaution > MAX_DIVERGENCE_VALUE ||
            newCaution < MIN_DIVERGENCE_VALUE ||
            newBadSource > MAX_DIVERGENCE_VALUE ||
            newBadSource < MIN_DIVERGENCE_VALUE
        ) {
            revert OracleManager__InvalidParameter();
        }

        cautionPriceDivergence = uint128(newCaution);
        badSourcePriceDivergence = uint128(newBadSource);
    }

    /// @notice Returns the token data of `cToken`.
    /// @param cToken The address of the cToken to get data of.
    function getCToken(address cToken) external view returns (CToken memory) {
        return cTokens[cToken];
    }

    /// @notice Returns the price feeds for `asset`.
    /// @param asset The address of the asset to get price feeds of.
    function getPriceFeeds(
        address asset
    ) external view returns(address[] memory) {
        return assetPriceFeeds[asset];
    }

    /// @notice Checks if a given asset is supported by the Oracle Manager.
    /// @dev An asset is considered supported if it has one
    ///      or more associated price feeds.
    /// @param asset The address of the asset to check.
    /// @return True if the asset is supported, false otherwise.
    function isSupportedAsset(address asset) external view returns (bool) {
        if (cTokens[asset].isCToken) {
            return assetPriceFeeds[cTokens[asset].underlying].length > 0;
        }

        return assetPriceFeeds[asset].length > 0;
    }

    /// @notice Check whether L2 sequencer is valid or down.
    /// @return True if sequencer is valid.
    function isSequencerValid() external view returns (bool) {
        return _isSequencerValid();
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Retrieves the price of a specified asset from either single
    ///         or dual oracles.
    /// @dev If the asset has one oracle, it fetches the price from a single
    ///      feed.
    ///      If it has two or more oracles, it fetches the price from both
    ///      feeds.
    /// @param asset The address of the asset to retrieve the price for.
    /// @param inUSD Specifies whether the price format should be in USD (true)
    ///              or a chain's native token (false).
    /// @param getLower Whether the lower or higher price should be returned
    ///                 if two feeds are available.
    /// @return price The current price of `asset`.
    /// @return errorCode An error code related to fetching the price:
    ///                   '0' indicates no error fetching price.
    ///                   '1' indicates that price should be taken with
    ///                   caution.
    ///                   '2' indicates a complete failure in receiving
    ///                   a price.
    function getPrice(
        address asset,
        bool inUSD,
        bool getLower
    ) public view returns (uint256 price, uint256 errorCode) {
        if (!_isSequencerValid()) {
            return (0, BAD_SOURCE);
        }

        address cToken;
        // Check whether `asset` is Curvance token.
        if (cTokens[asset].isCToken) {
            cToken = asset;
            asset = cTokens[asset].underlying;
        }

        // Route pricing to a single feed source or dual feed source.
        if (_checkFeeds(asset) < 2) {
            bool hadError;
            (price, hadError) = _getPriceFromFeed(asset, 0, inUSD, getLower);
            if (hadError) {
                errorCode = BAD_SOURCE;
            }
        } else {
            (price, errorCode) = _getPriceDualFeed(asset, inUSD, getLower);
        }

        // Query the exchange rate between a Curvance token and its underlying
        // token and convert the price into WAD form.
        if (cToken != address(0)) {
            price = (price * ICToken(cToken).exchangeRate()) / WAD;
        }

        // If somehow a feed returns a price of 0,
        // make sure we trigger the BAD_SOURCE flag.
        if (price == 0 && errorCode < BAD_SOURCE) {
            errorCode = BAD_SOURCE;
        }
    }

    /// @notice Retrieves the prices of a collateral token and debt token
    ///         underlyings.
    /// @param collateralToken The cToken currently collateralized to price.
    /// @param debtToken The cToken borrowed from to price.
    /// @param errorCodeBreakpoint The error code that will cause liquidity
    ///                            operations to revert.
    /// @return collateralUnderlyingPrice The current price of
    ///                                   `collateralToken` underlying.
    /// @return debtUnderlyingPrice The current price of `debtToken`
    ///                             underlying.
    function getPriceIsolatedPair(
        address collateralToken,
        address debtToken,
        uint256 errorCodeBreakpoint
    ) external view returns (
        uint256 collateralUnderlyingPrice,
        uint256 debtUnderlyingPrice
    ) {
        uint256 errorCode;
        (collateralUnderlyingPrice, errorCode) = getPrice(
            cTokens[collateralToken].underlying,
            true,
            true
        );
        if (errorCode >= errorCodeBreakpoint) {
            revert OracleManager__ErrorCodeFlagged();
        }

        (debtUnderlyingPrice, errorCode) = getPrice(
            cTokens[debtToken].underlying,
            true,
            false
        );
        if (errorCode >= errorCodeBreakpoint) {
            revert OracleManager__ErrorCodeFlagged();
        }
    }

    /// @notice Retrieves the prices and account data of multiple assets
    ///         inside a Curvance Market.
    /// @param account The account to retrieve data for.
    /// @param assets An array of asset addresses to retrieve the prices for.
    /// @param errorCodeBreakpoint The error code that will cause liquidity
    ///                            operations to revert.
    /// @return AccountSnapshot[] Contains `assets` data for `account`
    /// @return uint256[] Contains prices for `assets`.
    /// @return uint256 The number of assets `account` is in.
    function getPricesForMarket(
        address account,
        address[] calldata assets,
        uint256 errorCodeBreakpoint
    ) external view returns (
        AccountSnapshot[] memory,
        uint256[] memory,
        uint256
    ) {
        uint256 numAssets = assets.length;

        AccountSnapshot[] memory snapshots = new AccountSnapshot[](numAssets);
        uint256[] memory underlyingPrices = new uint256[](numAssets);
        uint256 errorCode;

        address asset;
        for (uint256 i; i < numAssets; ++i) {
            asset = assets[i];
            snapshots[i] = ICToken(asset).getSnapshot(account);

            (underlyingPrices[i], errorCode) = getPrice(
                cTokens[asset].underlying,
                true,
                snapshots[i].isCollateral
            );

            if (errorCode >= errorCodeBreakpoint) {
                revert OracleManager__ErrorCodeFlagged();
            }
        }

        return (snapshots, underlyingPrices, numAssets);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Adds a price feed for a specific asset.
    /// @dev Requires that the feed is not supported for `asset`.
    /// @param asset The address of the asset.
    /// @param feed The address of the feed to be added.
    function _addFeed(address asset, address feed) internal {
        // Validate that the proposed feed is approved for usage.
        _checkIsApprovedAdaptor(feed);

        // Validate that the feed supports the proposed asset.
        if (!IOracleAdaptor(feed).isSupportedAsset(asset)) {
            revert OracleManager__InvalidParameter();
        }

        uint256 numPriceFeeds = assetPriceFeeds[asset].length;

        // Validate that we do not already have 2 or more feeds for `asset`.
        if (numPriceFeeds >= 2) {
            revert OracleManager__InvalidParameter();
        }

        // Validate that the feed proposed is not a duplicate
        // of a supported feed for `asset`.
        if (numPriceFeeds != 0 && assetPriceFeeds[asset][0] == feed) {
            revert OracleManager__InvalidParameter();
        }

        // Validate that the feed returns a usable price for us with a sample
        // query.
        IOracleAdaptor.PricingResult memory result = IOracleAdaptor(feed)
            .getPrice(asset, true, true);

        if (result.price == 0 || result.hadError) {
            revert OracleManager__InvalidParameter();
        }

        assetPriceFeeds[asset].push(feed);
    }

    /// @notice Removes a price feed for a specific asset.
    /// @dev Requires that the feed exists for `asset`.
    /// @param asset The address of the asset.
    /// @param feed The address of the feed to be removed.
    function _removeFeed(address asset, address feed) internal {
        uint256 numFeeds = _checkFeeds(asset);

        // If theres two feeds, figure out which to remove,
        // otherwise we know the feed to remove is the first entry.
        if (numFeeds > 1) {
            // Check whether `feed` is a currently supported feed for `asset`.
            if (
                assetPriceFeeds[asset][0] != feed &&
                assetPriceFeeds[asset][1] != feed
            ) {
                revert OracleManager__NotSupported();
            }

            // We want to remove the first feed of two,
            // so move the second feed to slot one.
            if (assetPriceFeeds[asset][0] == feed) {
                assetPriceFeeds[asset][0] = assetPriceFeeds[asset][1];
            }
        } else {
            if (assetPriceFeeds[asset][0] != feed) {
                revert OracleManager__NotSupported();
            }
        }
        // We know the feed exists, but we cannot use `isApprovedAdaptor` as
        // we could have removed it as an approved adaptor prior.

        assetPriceFeeds[asset].pop();
    }

    /// @notice Retrieves the price of a specified asset from two specific
    ///         price feeds.
    /// @dev If both price feeds return an error, it returns (0, BAD_SOURCE).
    ///      If one of the price feeds return an error, it returns the
    ///      price from the working feed along with a CAUTION flag.
    ///      Otherwise, it returns (price, NO_ERROR).
    /// @param asset The address of the asset to retrieve the price for.
    /// @param inUSD Specifies whether the price format should be in
    ///              USD (true) or a chain's native token (false).
    /// @param getLower Whether the lower or higher price should be returned
    ///                 if two feeds are available.
    /// @return uint256 The current price of `asset`.
    /// @return bool An error flag (if any).
    function _getPriceDualFeed(
        address asset,
        bool inUSD,
        bool getLower
    ) internal view returns (uint256, uint256) {
        (uint256 price0, bool error0) = _getPriceFromFeed(
            asset, 0, inUSD, getLower
        );
        (uint256 price1, bool error1)= _getPriceFromFeed(
            asset, 1, inUSD, getLower
        );

        // Check if we had any working price feeds,
        // if not we need to block any market operations.
        if (error0 && error1){
            return (0, BAD_SOURCE);
        }
        // Check if we had an error in either price that should block
        // borrowing/redemption.
        if (error0 || error1) {
            // We know based on context of when this if statement block is
            // called that one but not both feeds have an error.
            // So, if feed0 had the error, feed1 is usable, and vice versa.
            if (error0) {
                return (price1, CAUTION);
            }

            return (price0, CAUTION);
        }

        uint256 errorCode = _checkBounds(price0, price1);
        if (getLower) {
            return (price1 < price0 ? price1 : price0, errorCode);
        }

        return (price1 > price0 ? price1 : price0, errorCode);
    }

    /// @notice Retrieves the price of a specified asset from a specific
    ///         price feed.
    /// @dev Fetches the price from the nth price feed for the asset,
    ///      where n is feedNumber.
    ///      Converts the price to USD if necessary.
    /// @param asset The address of the asset to retrieve the price for.
    /// @param feedNumber The index number of the feed to use.
    /// @param inUSD Specifies whether the price format should be in
    ///              USD (true) or a chain's native token (false).
    /// @param getLower Whether the lower or higher price should be returned
    ///                 if two feeds are available.
    /// @return uint256 The current price of `asset`.
    /// @return bool Whether the adaptor ran into an error when pricing.
    function _getPriceFromFeed(
        address asset,
        uint256 feedNumber,
        bool inUSD,
        bool getLower
    ) internal view returns (uint256, bool) {
        address adaptor = assetPriceFeeds[asset][feedNumber];
        _checkIsApprovedAdaptor(adaptor);

        IOracleAdaptor.PricingResult memory result = IOracleAdaptor(adaptor)
            .getPrice(asset, inUSD, getLower);

        // If we had an error pricing the asset, bubble up we had a error.
        if (result.hadError) {
            return (0, true);
        }

        // If the feed denomination is not in the proper form, modify it.
        if (result.inUSD != inUSD) {
            uint256 newPrice;
            bool nativeUsdLower = inUSD ? getLower : !getLower;
            (newPrice, result.hadError) = _getNativeUSD(nativeUsdLower);
            if (result.hadError) {
                return (0, true);
            }

            return (
                _convertNativeUSD(result.price, newPrice, result.inUSD),
                result.hadError
            );
        }

        return (uint256(result.price), result.hadError);
    }

    /// @notice Queries the current price of a chain's native token in USD
    ///         using the Oracle Manager.
    /// @dev The price is deemed valid if the data from the Oracle Manager
    ///      is fresh and a positive value.
    /// @param getLower Whether the lower or higher price should be returned
    ///                 if two feeds are available.
    /// @return uint256 The current price of `native`.
    /// @return bool Whether the adaptor ran into an error when pricing.
    function _getNativeUSD(
        bool getLower
    ) internal view returns (uint256, bool) {
        uint256 numFeeds = _checkFeeds(native);
        uint256 price;
        uint256 errorCode;

        // Route pricing to a single feed source or dual feed source.
        if (numFeeds < 2) {
            bool hadError;
            (price, hadError) = _getPriceFromFeed(native, 0, true, getLower);
            if (hadError) {
                errorCode = BAD_SOURCE;
            }
        } else {
            (price, errorCode) = _getPriceDualFeed(native, true, getLower);
        }

        // If somehow a feed returns a price of 0,
        // make sure we trigger the BAD_SOURCE flag.
        if (price == 0 && errorCode < BAD_SOURCE) {
            errorCode = BAD_SOURCE;
        }

        return (price, errorCode != NO_ERROR);
    }

    /// @notice Check whether a sequencer is valid or down.
    /// @return True if sequencer is valid.
    function _isSequencerValid() internal view returns (bool) {
        address sequencer = centralRegistry.sequencer();

        if (sequencer != address(0)) {
            (, int256 answer, uint256 startedAt, , ) = IChainlink(sequencer)
                .latestRoundData();

            // Answer == 0: Sequencer is up.
            // Check that the sequencer is up or the grace period has passed
            // after the sequencer is back up.
            if (startedAt == 0) {
                return false;
            }

            uint256 timeSinceUp = block.timestamp - startedAt;
            if (answer != 0 || timeSinceUp <= GRACE_PERIOD_TIME) {
                return false;
            }
        }

        return true;
    }

    /// @notice Converts a given price between a chain's native token
    ///         and USD.
    /// @dev Depending on the currentFormatInUSD parameter,
    ///      this function either converts the price from native token
    ///      to USD (if true) or from USD to native (if false) using the
    ///      provided conversion rate.
    /// @param currentPrice The price to convert.
    /// @param conversionRate The rate to use for the conversion.
    /// @param currentlyInUSD Specifies whether the current format of the
    ///                       price is in USD.
    ///                       If true -> Convert the price from USD to
    ///                       native token.
    ///                       If false -> Convert the price from native token
    ///                       to USD.
    /// @return The converted price.
    function _convertNativeUSD(
        uint240 currentPrice,
        uint256 conversionRate,
        bool currentlyInUSD
    ) internal pure returns (uint256) {
        if (!currentlyInUSD) {
            // The price denomination is in native token and we want USD.
            return (currentPrice * conversionRate) / WAD;
        }

        // The price denomination is in USD and we want native token.
        return (currentPrice * WAD) / conversionRate;
    }

    /// @notice Processes the price data from two different feeds.
    /// @dev Checks for divergence between two prices.
    ///      If the divergence is more than allowed, it returns (0, CAUTION)
    ///      or (0, BAD_SOURCE) depending on the level of diversion.
    /// @param a The price from the first feed.
    /// @param b The price from the second feed.
    /// @return Returns the appropriate error code depending on price
    ///         divergence.
    function _checkBounds(
        uint256 a,
        uint256 b
    ) internal view returns (uint256) {
        if (a <= b) {
            // Check if both feeds are within `f.caution` of each other.
            if (((a * cautionPriceDivergence) / BASIS_POINTS) < b) {
                // Notify that the price is dangerous and to treat data as a
                // bad source because we are outside the accepted range of
                // divergence.
                if (((a * badSourcePriceDivergence) / BASIS_POINTS) < b) {
                    return BAD_SOURCE;
                }

                // Notify that the price should be taken with caution because
                // we are outside the accepted range of divergence.
                return CAUTION;
            }

            return NO_ERROR;
        }

        // Check if both feeds are within `f.caution` of each other.
        if (((b * cautionPriceDivergence) / BASIS_POINTS) < a) {
            // Notify that the price is dangerous and to treat data as a
            // bad source because we are outside the accepted range of
            // divergence.
            if (((b * badSourcePriceDivergence) / BASIS_POINTS) < a) {
                return BAD_SOURCE;
            }

            // Notify that the price should be taken with caution because
            // we are outside the accepted range of divergence.
            return CAUTION;
        }

        return NO_ERROR;
    }

    /// @notice Checks whether `asset` has supported adaptor feeds or not.
    ///         Reverts if `asset` is no approved feeds.
    /// @param asset The address of the asset to check.
    /// @return f The number of supported feeds for `asset`.
    function _checkFeeds(address asset) internal view returns (uint256 f) {
        f = assetPriceFeeds[asset].length;
        // Validate we have a feed or feeds to price `asset`.
        if (f == 0) {
            revert OracleManager__NotSupported();
        }
    }

    /// @notice Checks whether `adaptor` is an approved adaptor or not.
    ///         Reverts if `adaptor` is not approved.
    /// @param adaptor The address of the adaptor to check.
    function _checkIsApprovedAdaptor(address adaptor) internal view {
        if (!isApprovedAdaptor[adaptor]) {
            revert OracleManager__AdaptorIsNotApproved();
        }
    }

    /// @dev Checks whether the caller has sufficient permissioning.
    function _checkElevatedPermissions() internal view {
        if (!centralRegistry.hasElevatedPermissions(msg.sender)) {
            revert OracleManager__Unauthorized();
        }
    }
}