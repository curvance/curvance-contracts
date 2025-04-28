// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { WAD, DENOMINATOR, NO_ERROR, CAUTION, BAD_SOURCE } from "contracts/libraries/Constants.sol";
import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IMToken, AccountSnapshot } from "contracts/interfaces/IMToken.sol";
import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";
import { IOracleAdaptor, PriceReturnData } from "contracts/interfaces/IOracleAdaptor.sol";

/// @title Curvance Dynamic Pessimistic Dual Oracle Manager.
/// @notice Provides a universal interface allowing contracts
///         to retrieve secure pricing data based on various price feeds.
/// @dev The Curvance Oracle Manager acts as a unified hub for pricing anything.
///      The Oracle Manager can support up to two oracle adaptors, returning
///      a maximum of two prices for any asset.
///
///      Finalized prices can be returned in USD or
///      a chain's native gas token. Either the higher or lower of the two
///      prices can returned, based on what is desired. For Curvance protocol,
///      the more advantageous of both prices is used. For user collateral
///      assets, the lower of the two prices is used. For user debt positions,
///      the higher of the two prices is used.
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
///      - An error code of 1 will be triggered by a 5% or greater price
///        divergence.
///      - An error code of 2 will be triggered by a 10% or greater price
///        divergence.
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
contract OracleManager {
    /// TYPES ///

    /// @title Oracle Feed Data
    /// @notice Data retrieved from a price feed.
    /// @dev The price is stored as a uint240 to avoid precision loss.
    ///      The hadError flag is used to indicate if the price feed
    ///      had an error.
    /// @dev The FeedData struct is used to store the price and hadError flag for a price feed.
    struct FeedData {
        /// @notice price of the asset in some asset, either the chain's
        ///         native token or USD.
        uint240 price;
        /// @notice message return data, true if adaptor couldnt price asset.
        bool hadError;
    }

    /// @title mToken Data
    /// @notice Stored data for an mToken.
    /// @dev The isMToken flag is used to indicate if the provided address is an MToken or not.
    ///      The underlying address is the address of the underlying asset for the MToken.
    struct MTokenData {
        /// @notice Whether the provided address is an MToken or not.
        bool isMToken;
        /// @notice Token address of underlying asset for MToken.
        address underlying;
    }

    /// CONSTANTS ///

    /// @notice Address identifying a chain's native token.
    address public constant native =
        0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;
    /// @notice Time to pass before accepting answers when sequencer
    ///         comes back up.
    uint256 public constant GRACE_PERIOD_TIME = 3600;

    /// @dev `bytes4(keccak256(bytes("OracleManager__NotSupported()")))`.
    uint256 internal constant _NOT_SUPPORTED_SELECTOR = 0x37ccbfb5;
    /// @dev `bytes4(keccak256(bytes("OracleManager__InvalidParameter()")))`.
    uint256 internal constant _INVALID_PARAMETER_SELECTOR = 0x3e1a10b2;
    /// @dev `bytes4(keccak256(bytes("OracleManager__ErrorCodeFlagged()")))`.
    uint256 internal constant _ERROR_CODE_FLAGGED_SELECTOR = 0x7c70f82f;

    /// STORAGE ///

    /// @notice The maximum allowed divergence between prices
    ///         before CAUTION is flipped, in `DENOMINATOR`.
    ///         10500 = 5% deviation.
    uint256 public cautionDivergenceFlag = 10500;
    /// @notice The maximum allowed divergence between prices
    ///         before BAD_SOURCE is flipped, in `DENOMINATOR`.
    ///         11000 = 10% deviation.
    uint256 public badSourceDivergenceFlag = 11000;

    // Address => Adaptor approval status
    mapping(address => bool) public isApprovedAdaptor;
    // Address => Price Feed addresses
    mapping(address => address[]) public assetPriceFeeds;
    // Address => MToken metadata
    mapping(address => MTokenData) public mTokenAssets;

    /// ERRORS ///

    error OracleManager__Unauthorized();
    error OracleManager__NotSupported();
    error OracleManager__InvalidParameter();
    error OracleManager__ErrorCodeFlagged();
    error OracleManager__AdaptorIsNotApproved();

    /// CONSTRUCTOR ///

    constructor(ICentralRegistry centralRegistry_) {
        if (
            !ERC165Checker.supportsInterface(
                address(centralRegistry_),
                type(ICentralRegistry).interfaceId
            )
        ) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        centralRegistry = centralRegistry_;
    }

    /// FUNCTIONS ///

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
            _revert(_INVALID_PARAMETER_SELECTOR);
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

    /// @notice Adds a new mToken to the Oracle Manager.
    /// @dev Requires that `newMToken` isn't already supported.
    /// @param newMToken The address of the mToken to support.
    function addMTokenSupport(address newMToken) external {
        _checkElevatedPermissions();

        if (mTokenAssets[newMToken].isMToken) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // We call a Curvance specific MToken function as a sanity check.
        IMToken(newMToken).isPToken();

        mTokenAssets[newMToken].isMToken = true;
        mTokenAssets[newMToken].underlying = IMToken(newMToken).underlying();
    }

    /// @notice Removes a mToken's support in the Oracle Manager.
    /// @dev Requires that the mToken is supported.
    /// @param mTokenToRemove The address of the mToken to remove support for.
    function removeMTokenSupport(address mTokenToRemove) external {
        _checkElevatedPermissions();

        if (!mTokenAssets[mTokenToRemove].isMToken) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        delete mTokenAssets[mTokenToRemove];
    }

    /// @notice Adds `newAdaptor` as an approved adaptor.
    /// @dev Requires that the adaptor isn't already approved.
    /// @param adaptorToAdd The address of the adaptor to approve.
    function addApprovedAdaptor(address adaptorToAdd) external {
        _checkElevatedPermissions();

        // Validate `adaptorToAdd` is not already supported.
        if (isApprovedAdaptor[adaptorToAdd]) {
            _revert(_INVALID_PARAMETER_SELECTOR);
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
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate `adaptorToRemove` is currently supported.
        _checkIsApprovedAdaptor(adaptorToRemove);

        // Validate that the adaptors are not identical as there would be no
        // point to replace an adaptor with itself.
        if (adaptorToAdd == adaptorToRemove) {
            _revert(_INVALID_PARAMETER_SELECTOR);
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
    ///         before CAUTION or BAD_SOURCE is activated.
    /// @dev Requires that the new divergences is greater than
    ///      or equal to 10200 aka 2% and less than or equal to 12000 aka 20%.
    /// @param maxCautionDivergence The new maximum divergence
    ///                             for a caution flag to be returned.
    /// @param maxBadSourceDivergence The new maximum divergence
    ///                               for a bad source flag to be returned.
    function setDivergenceFlags(
        uint256 maxCautionDivergence,
        uint256 maxBadSourceDivergence
    ) external {
        _checkElevatedPermissions();

        // Validate that the caution divergence flag does not occur after
        // the bad source divergence flag as bad source is a more
        // significant error than caution.
        if (maxCautionDivergence >= maxBadSourceDivergence) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        if (maxCautionDivergence < 10200 || maxCautionDivergence > 12000) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        if (maxBadSourceDivergence < 10200 || maxBadSourceDivergence > 12000) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        cautionDivergenceFlag = maxCautionDivergence;
        badSourceDivergenceFlag = maxBadSourceDivergence;
    }

    /// @notice Returns the types of adaptors pricing `asset` uses.
    /// @dev Used by frontends to determine how to properly interact
    ///      with a supported asset.
    /// @param  asset The asset whose adaptor types should be returned.
    /// @return A tuple containing the types of adaptors pricing `asset`
    ///         uses, a value of 0 indicates an unsupported or empty
    ///         adaptor slot.
    function getAdaptorTypes(
        address asset
    ) external view returns (uint256, uint256) {
        bool isMToken = mTokenAssets[asset].isMToken;
        if (isMToken) {
            asset = mTokenAssets[asset].underlying;
        }

        uint256 numFeeds = assetPriceFeeds[asset].length;
        if (numFeeds == 0) {
            return (0, 0);
        }

        address adaptor;

        // If the asset only has one price feed, we know it will be in
        // feed slot 0 so get both prices and return
        if (numFeeds < 2) {
            adaptor = assetPriceFeeds[asset][0];
            if (!isApprovedAdaptor[adaptor]) {
                return (0, 0);
            }

            return (IOracleAdaptor(adaptor).adaptorType(), 0);
        }

        uint256 adaptorTypeA;
        uint256 adaptorTypeB;

        adaptor = assetPriceFeeds[asset][0];
        adaptorTypeA = isApprovedAdaptor[adaptor]
            ? IOracleAdaptor(adaptor).adaptorType()
            : 0;

        adaptor = assetPriceFeeds[asset][1];
        adaptorTypeB = isApprovedAdaptor[adaptor]
            ? IOracleAdaptor(adaptor).adaptorType()
            : 0;

        return (adaptorTypeA, adaptorTypeB);
    }

    /// @notice Checks if a given asset is supported by the Oracle Manager.
    /// @dev An asset is considered supported if it has one
    ///      or more associated price feeds.
    /// @param asset The address of the asset to check.
    /// @return True if the asset is supported, false otherwise.
    function isSupportedAsset(address asset) external view returns (bool) {
        if (mTokenAssets[asset].isMToken) {
            return assetPriceFeeds[mTokenAssets[asset].underlying].length > 0;
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
    /// @return price The price of the asset.
    /// @return errorCode An error code related to fetching the price.
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
            return (0, 2);
        }

        address mAsset;
        
        // Check whether asset is an mToken.
        if (mTokenAssets[asset].isMToken) {
            mAsset = asset;
            asset = mTokenAssets[asset].underlying;
        }

        uint256 numFeeds = _checkHasSupportedFeeds(asset);

        // Route pricing to a single feed source or dual feed source.
        if (numFeeds < 2) {
            bool hadError;
            (price, hadError) = _getPriceFromFeed(asset, 0, inUSD, getLower);
            if (hadError) {
                errorCode = BAD_SOURCE;
            }
        } else {
            (price, errorCode) = _getPriceDualFeed(asset, inUSD, getLower);
        }

        // If somehow a feed returns a price of 0,
        // make sure we trigger the BAD_SOURCE flag.
        if (price == 0 && errorCode < BAD_SOURCE) {
            errorCode = BAD_SOURCE;
        }

        // Query the exchange rate for underlying token vs mToken and offset.
        if (mAsset != address(0)) {
            uint256 exchangeRate = IMToken(mAsset).exchangeRateCached();
            price = (price * exchangeRate) / WAD;
        }
    }

    /// @notice Retrieves the prices of multiple assets.
    /// @param assets An array of asset addresses to retrieve the prices for.
    /// @param inUSD An array indicating whether the price format should be in
    ///              USD (true) or a chain's native token (false).
    /// @param getLower An array of bools indicating whether the lower
    ///                 or higher price should be returned if two feeds
    ///                 are available.
    /// @return Two arrays. The first one contains prices for each asset,
    ///         and the second one contains corresponding error
    ///         flags (if any).
    function getPrices(
        address[] calldata assets,
        bool[] calldata inUSD,
        bool[] calldata getLower
    ) external view returns (uint256[] memory, uint256[] memory) {
        uint256 numAssets = assets.length;
        // Validate we are not trying to price zero assets.
        if (numAssets == 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate that each array is properly structured.
        if (numAssets != inUSD.length || numAssets != getLower.length) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        uint256[] memory prices = new uint256[](numAssets);
        uint256[] memory hadError = new uint256[](numAssets);

        for (uint256 i; i < numAssets; ++i) {
            (prices[i], hadError[i]) = getPrice(
                assets[i],
                inUSD[i],
                getLower[i]
            );
        }

        return (prices, hadError);
    }

    /// @notice Retrieves the prices of a eToken underlying and pToken.
    /// @param eToken The earning token to price the underlying of.
    /// @param pToken The position token to price.
    /// @param errorCodeBreakpoint The error code that will cause liquidity
    ///                            operations to revert.
    /// @return eTokenUnderlyingPrice Contains the price of `eToken` underlying.
    /// @return pTokenPrice Contains the price of `pToken`.
    function getPriceIsolatedPair(
        address eToken,
        address pToken,
        uint256 errorCodeBreakpoint
    )
        external
        view
        returns (uint256 eTokenUnderlyingPrice, uint256 pTokenPrice)
    {
        uint256 errorCode;

        // We get the eToken's underlying price here as getPriceIsolatedPair
        // is for getting prices needed for an isolated market which is a
        // pToken and eToken debt.
        (eTokenUnderlyingPrice, errorCode) = getPrice(
            mTokenAssets[eToken].underlying,
            true,
            false
        );
        if (errorCode >= errorCodeBreakpoint) {
            _revert(_ERROR_CODE_FLAGGED_SELECTOR);
        }

        (pTokenPrice, errorCode) = getPrice(pToken, true, true);
        if (errorCode >= errorCodeBreakpoint) {
            _revert(_ERROR_CODE_FLAGGED_SELECTOR);
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
        IMToken[] calldata assets,
        uint256 errorCodeBreakpoint
    )
        external
        view
        returns (AccountSnapshot[] memory, uint256[] memory, uint256)
    {
        uint256 numAssets = assets.length;

        AccountSnapshot[] memory snapshots = new AccountSnapshot[](numAssets);
        uint256[] memory underlyingPrices = new uint256[](numAssets);
        uint256 errorCode;

        for (uint256 i; i < numAssets; ++i) {
            snapshots[i] = assets[i].getSnapshotPacked(account);
            (underlyingPrices[i], errorCode) = getPrice(
                assets[i].underlying(),
                true,
                snapshots[i].isPToken
            );

            if (errorCode >= errorCodeBreakpoint) {
                _revert(_ERROR_CODE_FLAGGED_SELECTOR);
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
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        uint256 numPriceFeeds = assetPriceFeeds[asset].length;

        // Validate that we do not already have 2 or more feeds for `asset`.
        if (numPriceFeeds >= 2) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate that the feed proposed is not a duplicate
        // of a supported feed for `asset`.
        if (numPriceFeeds != 0 && assetPriceFeeds[asset][0] == feed) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate that the feed returns a usable price for us with a sample
        // query.
        PriceReturnData memory sampleData = IOracleAdaptor(feed).getPrice(
            asset,
            true,
            true
        );

        if (sampleData.price == 0 || sampleData.hadError) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        assetPriceFeeds[asset].push(feed);
    }

    /// @notice Removes a price feed for a specific asset.
    /// @dev Requires that the feed exists for `asset`.
    /// @param asset The address of the asset.
    /// @param feed The address of the feed to be removed.
    function _removeFeed(address asset, address feed) internal {
        uint256 numFeeds = _checkHasSupportedFeeds(asset);

        // If theres two feeds, figure out which to remove,
        // otherwise we know the feed to remove is the first entry.
        if (numFeeds > 1) {
            // Check whether `feed` is a currently supported feed for `asset`.
            if (
                assetPriceFeeds[asset][0] != feed &&
                assetPriceFeeds[asset][1] != feed
            ) {
                _revert(_NOT_SUPPORTED_SELECTOR);
            }

            // We want to remove the first feed of two,
            // so move the second feed to slot one.
            if (assetPriceFeeds[asset][0] == feed) {
                assetPriceFeeds[asset][0] = assetPriceFeeds[asset][1];
            }
        } else {
            if (assetPriceFeeds[asset][0] != feed) {
                _revert(_NOT_SUPPORTED_SELECTOR);
            }
        }
        // we know the feed exists, cant use isApprovedAdaptor as
        // we could have removed it as an approved adaptor prior

        assetPriceFeeds[asset].pop();
    }

    /// @notice Retrieves the price of a specified asset from two specific
    ///         price feeds.
    /// @param asset The address of the asset to retrieve the price for.
    /// @param inUSD Specifies whether the price format should be in USD (true)
    ///              or a chain's native token (false).
    /// @param getLower Whether the lower or higher price should be returned
    ///                 if two feeds are available.
    /// @return A tuple containing the asset's price and an error flag
    ///         (if any).
    ///         If both price feeds return an error, it returns
    ///         (0, BAD_SOURCE).
    ///         If one of the price feeds return an error, it returns the
    ///         price from the working feed along with a CAUTION flag.
    ///         Otherwise, it returns (price, NO_ERROR).
    function _getPriceDualFeed(
        address asset,
        bool inUSD,
        bool getLower
    ) internal view returns (uint256, uint256) {
        (uint256 feed0Price, bool feed0Error) = _getPriceFromFeed(
            asset, 0, inUSD, getLower
        );
        (uint256 feed1Price, bool feed1Error)= _getPriceFromFeed(
            asset, 1, inUSD, getLower
        );

        // Check if we had any working price feeds,
        // if not we need to block any market operations.
        if (feed0Error && feed1Error){
            return (0, BAD_SOURCE);
        }
        // Check if we had an error in either price that should block borrowing.
        if (feed0Error || feed1Error) {
            // We know based on context of when this if statement block is called that
            // one but not both feeds have an error.
            // So, if feed0 had the error, feed1 is okay, and vice versa.
            if (feed0Error) {
                return (feed1Price, CAUTION);
            }

            return (feed0Price, CAUTION);
        }

        uint256 errorCode = _checkBounds(feed0Price, feed1Price);
        if (getLower) {
            return (feed1Price < feed0Price
                ? feed1Price : feed0Price, errorCode);
        }

        return (feed1Price > feed0Price ? feed1Price : feed0Price, errorCode);
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
    /// @return An instance of FeedData containing the asset's price
    ///         and an error flag (if any).
    ///         If the price feed returns an error, it returns feedData
    ///         with price 0 and hadError set to true.
    function _getPriceFromFeed(
        address asset,
        uint256 feedNumber,
        bool inUSD,
        bool getLower
    ) internal view returns (uint256, bool) {
        address adaptor = assetPriceFeeds[asset][feedNumber];
        _checkIsApprovedAdaptor(adaptor);

        PriceReturnData memory data = IOracleAdaptor(adaptor).getPrice(
            asset,
            inUSD,
            getLower
        );

        // If we had an error pricing the asset, bubble up we had a error.
        if (data.hadError) {
            return (0, true);
        }

        // If the feed denomination is not in the proper form, modify it.
        if (data.inUSD != inUSD) {
            uint256 newPrice;
            bool nativeUsdLower = inUSD ? getLower : !getLower;
            (newPrice, data.hadError) = _getNativeUSD(nativeUsdLower);
            if (data.hadError) {
                return (0, true);
            }

            data.price = uint240(
                _convertNativeUSD(data.price, newPrice, data.inUSD)
            );
        }

        return (uint256(data.price), data.hadError);
    }

    /// @notice Queries the current price of a chain's native token in USD
    ///         using the Oracle Manager.
    /// @dev The price is deemed valid if the data from the Oracle Manager
    ///      is fresh and a positive value.
    /// @param getLower Whether the lower or higher price should be returned
    ///                 if two feeds are available.
    /// @return A tuple containing the price of the chain's native token
    ///         in USD and an error flag.
    ///         If the Oracle Manager data is stale or negative,
    ///         it returns (answer, true).
    ///         Where true corresponds to hasError = true.
    function _getNativeUSD(
        bool getLower
    ) internal view returns (uint256, bool) {
        uint256 numFeeds = _checkHasSupportedFeeds(native);
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
    ///                       If true, it will convert the price from
    ///                       USD to native token.
    ///                       If false, it will convert the price from
    ///                       native token to USD.
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
            // Check if both feeds are within `cautionDivergenceFlag`
            // of each other.
            if (((a * cautionDivergenceFlag) / DENOMINATOR) < b) {
                // Notify that the price is dangerous and to treat data as a
                // bad source because we are outside the accepted range of
                // divergence.
                if (((a * badSourceDivergenceFlag) / DENOMINATOR) < b) {
                    return BAD_SOURCE;
                }

                // Notify that the price should be taken with caution because
                // we are outside the accepted range of divergence.
                return CAUTION;
            }

            return NO_ERROR;
        }

        // Check if both feeds are within `cautionDivergenceFlag`
        // of each other.
        if (((b * cautionDivergenceFlag) / DENOMINATOR) < a) {
            // Notify that the price is dangerous and to treat data as a
            // bad source because we are outside the accepted range of
            // divergence.
            if (((b * badSourceDivergenceFlag) / DENOMINATOR) < a) {
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
    /// @return numFeeds The number of supported feeds for `asset`.
    function _checkHasSupportedFeeds(
        address asset
    ) internal view returns (uint256 numFeeds) {
        numFeeds = assetPriceFeeds[asset].length;
        // Validate we have a feed or feeds to price `asset`.
        if (numFeeds == 0) {
            _revert(_NOT_SUPPORTED_SELECTOR);
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

    /// @notice Internal helper for reverting efficiently.
    /// @param s Selector to revert with.
    function _revert(uint256 s) internal pure {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, s)
            revert(0x1c, 0x04)
        }
    }

    /// @dev Checks whether the caller has sufficient permissioning.
    function _checkElevatedPermissions() internal view {
        if (!centralRegistry.hasElevatedPermissions(msg.sender)) {
            revert OracleManager__Unauthorized();
        }
    }
}
