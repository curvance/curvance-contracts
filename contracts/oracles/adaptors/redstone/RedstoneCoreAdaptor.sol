// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";

import { Bytes32Helper } from "contracts/libraries/Bytes32Helper.sol";
import { PrimaryProdDataServiceConsumerBase } from "contracts/libraries/external/redstone/PrimaryProdDataServiceConsumerBase.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IOracleRouter } from "contracts/interfaces/IOracleRouter.sol";
import { PriceReturnData } from "contracts/interfaces/IOracleAdaptor.sol";

contract RedstoneCoreAdaptor is BaseOracleAdaptor, PrimaryProdDataServiceConsumerBase {
    /// TYPES ///

    /// @notice Stores configuration data for Redstone price sources.
    /// @param isConfigured Whether the asset is configured or not.
    ///                     false = unconfigured; true = configured.
    /// @param symbolHash The bytes32 encoded hash of the price feed.
    /// @param max The max valid price of the asset.
    /// @param decimals Returns the number of decimals the Redstone price feed
    ///                 responds with. We save this as a uint256 so we do not
    ///                 need to convert from uint8 -> uint256 at runtime.
    struct AdaptorData {
        bool isConfigured;
        bytes32 symbolHash;
        uint256 max;
        uint256 decimals;
        uint256 heartbeat;
    }

    /// CONSTANTS ///

    /// @notice If zero is specified for a Pyth asset heartbeat,
    ///         this value is used instead.
    /// @dev    1 days = 24 hours = 1,440 minutes = 86,400 seconds.
    uint256 public constant DEFAULT_HEART_BEAT = 1 days;
    /// @notice The smallest value that Redstone Core unique signer threshold
    ///         can be inside Curvance.
    /// TODO: Update tests to use 2 minimum and change this back
    uint256 public constant MINIMUM_SIGNER_THRESHOLD_ALLOWED = 1;

    /// STORAGE ///

    /// @notice Array containing a list of all authorised signers
    ///         inside Redstone Core.
    address[] public authorisedSigners;

    /// @notice The minimum number of unique signers required to accept
    ///          a Redstone Core price.
    uint256 internal _uniqueSignersThreshold;

    /// @notice Adaptor configuration data for pricing an asset in gas token.
    /// @dev Redstone Adaptor Data for pricing in gas token.
    mapping(address => AdaptorData) public adaptorDataNonUSD;

    /// @notice Adaptor configuration data for pricing an asset in USD.
    /// @dev Redstone Adaptor Data for pricing in USD.
    mapping(address => AdaptorData) public adaptorDataUSD;

    mapping(address => mapping(bool => uint256)) private overriddenPrice;
    mapping(address => mapping(bool => uint256))
        private overriddenPriceUpdatedAt;

    /// EVENTS ///

    event RedstoneCoreAssetAdded(
        address asset,
        AdaptorData assetConfig,
        bool isUpdate
    );
    event RedstoneCoreAssetRemoved(address asset);
    event RedstoneCoreSignerAdded(address signer);
    event RedstoneCoreSignerRemoved(address signer);

    /// ERRORS ///

    error RedstoneCoreAdaptor__InvalidConfiguration();
    error RedstoneCoreAdaptor__AssetIsNotSupported();
    error RedstoneCoreAdaptor__SymbolHashError();
    error RedstoneCoreAdaptor__InvalidHeartbeat();

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address[] memory signers,
        uint256 uniqueSignersThreshold_
    ) BaseOracleAdaptor(
        centralRegistry_
    ) PrimaryProdDataServiceConsumerBase(signers) {
        // Validate that unique signer threshold is within acceptable limits.
        if (MINIMUM_SIGNER_THRESHOLD_ALLOWED > uniqueSignersThreshold_) {
            revert RedstoneCoreAdaptor__InvalidConfiguration();
        }

        // Validate unique signer threshold is possible to reach based
        // on signers authorised.
        if (uniqueSignersThreshold_ > signers.length) {
            revert RedstoneCoreAdaptor__InvalidConfiguration();
        }

        _uniqueSignersThreshold = uniqueSignersThreshold_;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Retrieves the price of a given asset.
    /// @dev Uses Redstone Core oracles to fetch the price data.
    ///      Price is returned in USD or ETH depending on 'inUSD' parameter.
    /// @param asset The address of the asset for which the price is needed.
    /// @param inUSD A boolean to determine if the price should be returned in
    ///              USD or not.
    /// @return PriceReturnData A structure containing the price, error status,
    ///                         and the quote format of the price.
    function getPrice(
        address asset,
        bool inUSD,
        bool
    ) external view override returns (PriceReturnData memory) {
        // Validate we support pricing `asset`.
        if (!isSupportedAsset[asset]) {
            revert RedstoneCoreAdaptor__AssetIsNotSupported();
        }

        if (inUSD) {
            return _getPriceInUSD(asset);
        }

        return _getPriceInETH(asset);
    }

    /// @notice Add a Redstone Core Price Feed as an asset.
    /// @dev Should be called before `OracleRouter:addAssetPriceFeed`
    ///      is called.
    /// @param asset The address of the token to add pricing support for.
    /// @param inUSD Whether the price feed is in USD (inUSD = true)
    ///              or ETH (inUSD = false).
    /// @param decimals The number of decimals the redstone core feed
    ///                 prices in.
    function addAsset(
        address asset,
        bool inUSD,
        uint8 decimals,
        uint256 heartbeat
    ) external {
        _checkElevatedPermissions();

        if (heartbeat != 0) {
            if (heartbeat > DEFAULT_HEART_BEAT) {
                revert RedstoneCoreAdaptor__InvalidHeartbeat();
            }
        }

        bytes32 symbolHash;
        if (inUSD) {
            // Redstone Core does not append anything at the end of USD
            // denominated feeds, so we use toBytes32 here.
            symbolHash = Bytes32Helper._toBytes32(asset);
        } else {
            // Redstone Core appends "/ETH" at the end of ETH denominated
            // feeds, so we use toBytes32WithETH here.
            symbolHash = Bytes32Helper._toBytes32WithETH(asset);
        }

        AdaptorData storage data;

        if (inUSD) {
            data = adaptorDataUSD[asset];
        } else {
            data = adaptorDataNonUSD[asset];
        }

        // If decimals == 0 we want default 8 decimals that
        // redstone typically returns in.
        if (decimals == 0) {
            data.decimals = 8;
        } else {
            // Otherwise coerce uint8 to uint256 for cheaper
            // runtime conversion.
            data.decimals = uint256(decimals);
        }

        // Add a ~10% buffer to maximum price allowed from redstone can stop
        // updating its price before/above the min/max price.
        // We use a maximum buffered price of 2^192 - 1 since redstone core
        // reports pricing in 8 decimal format, requiring multiplication by
        // 10e10 to standardize to 18 decimal format, which could overflow
        // when trying to save the final value into an uint240.
        data.max = uint192((uint256(type(uint192).max) * 9) / 10);
        data.symbolHash = symbolHash;
        data.heartbeat = heartbeat;
        data.isConfigured = true;

        // Check whether this is new or updated support for `asset`.
        bool isUpdate;
        if (isSupportedAsset[asset]) {
            isUpdate = true;
        }

        isSupportedAsset[asset] = true;
        emit RedstoneCoreAssetAdded(asset, data, isUpdate);
    }

    /// @notice Removes a supported asset from the adaptor.
    /// @dev Calls back into Oracle Router to notify it of its removal.
    ///      Requires that `asset` is currently supported.
    /// @param asset The address of the supported asset to remove from
    ///              the adaptor.
    function removeAsset(address asset) external override {
        _checkElevatedPermissions();

        // Validate that `asset` is currently supported.
        if (!isSupportedAsset[asset]) {
            revert RedstoneCoreAdaptor__AssetIsNotSupported();
        }

        // Wipe config mapping entries for a gas refund.
        // Notify the adaptor to stop supporting the asset.
        delete isSupportedAsset[asset];
        delete adaptorDataUSD[asset];
        delete adaptorDataNonUSD[asset];

        // Notify the Oracle Router that we are going to stop supporting
        // the asset.
        IOracleRouter(centralRegistry.oracleRouter()).notifyFeedRemoval(asset);

        emit RedstoneCoreAssetRemoved(asset);
    }

    /// @notice Writes a Redstone Core price to this adaptor contract to be
    ///         queried later by Curvance Protocol or external users.
    /// @param asset The address of the supported asset to write a price for.
    /// @param inUSD Whether the price is being written in USD,
    ///              or the chain's native token.
    function writePrice(address asset, bool inUSD) external {
        if (inUSD) {
            if (!adaptorDataUSD[asset].isConfigured) {
                revert RedstoneCoreAdaptor__AssetIsNotSupported();
            }
            overriddenPrice[asset][inUSD] = _extractPrice(
                adaptorDataUSD[asset].symbolHash
            );
            overriddenPriceUpdatedAt[asset][inUSD] = block.timestamp;
        } else {
            if (!adaptorDataNonUSD[asset].isConfigured) {
                revert RedstoneCoreAdaptor__AssetIsNotSupported();
            }
            overriddenPrice[asset][inUSD] = _extractPrice(
                adaptorDataNonUSD[asset].symbolHash
            );
            overriddenPriceUpdatedAt[asset][inUSD] = block.timestamp;
        }
    }

    /// @notice Adds a new supported signer for redstone core msg.data
    ///         field validation.
    /// @dev Can also increase signer threshold required if necessary.
    /// @param newSigner The new address to be authorised inside
    ///                  the Redstone Core system.
    /// @param incrementSignerThreshold Whether the minimum number of signers
    ///                                 should increase alongside the new
    ///                                 signer's addition.
    function addSigner(
        address newSigner,
        bool incrementSignerThreshold
    ) external {
        _checkElevatedPermissions();

        uint256 index = _isAuthorisedSigner[newSigner];

        /// Validate that `newSigner` is not already authorised.
        if (index != 0) {
            revert RedstoneCoreAdaptor__InvalidConfiguration();
        }

        uint256 signerIndex = authorisedSigners.length;

        // Add `newSigner` to quick access address mapping.
        _isAuthorisedSigner[newSigner] = signerIndex + 1;
        // Add `newSigner` to authorised signer list.
        authorisedSigners.push(newSigner);

        if (incrementSignerThreshold) {
            _uniqueSignersThreshold++;
        } 

        emit RedstoneCoreSignerAdded(newSigner);
    }

    /// @notice Remove a current authorised signer for redstone core msg.data
    ///         field validation.
    /// @dev Can also increase signer threshold required if necessary.
    /// @param currentSigner The address to be remove from the
    ///                      Redstone Core system.
    /// @param decrementSignerThreshold Whether the minimum number of signers
    ///                                 should decrease alongside the
    ///                                 authorised signer's removal.
    function removeSigner(
        address currentSigner,
        bool decrementSignerThreshold
    ) external {
        _checkElevatedPermissions();

        uint256 index = _isAuthorisedSigner[currentSigner];

        /// Validate that `currentSigner` is authorised.
        if (index == 0) {
            revert SignerNotAuthorised(currentSigner);
        }

        // Remove `currentSigner` from quick access address mapping.
        _isAuthorisedSigner[currentSigner] == 0;

        uint256 lastSignerIndex = authorisedSigners.length - 1;

        // Switch array locations on authorised signer so we can pop
        // `currentSigner` from the end.
        if (index != lastSignerIndex) {
            authorisedSigners[index] = authorisedSigners[lastSignerIndex];
        }

        // Remove `currentSigner` from authorised signer list.
        authorisedSigners.pop();

        if (decrementSignerThreshold) {
            // Make sure that decreasing the signer threshold would not pushed
            // signer requirement below minimum allowed inside the Curvance
            // Protocol.
            if (_uniqueSignersThreshold == MINIMUM_SIGNER_THRESHOLD_ALLOWED) {
                revert RedstoneCoreAdaptor__InvalidConfiguration();
            }

            _uniqueSignersThreshold--;
        }

        emit RedstoneCoreSignerRemoved(currentSigner);
    }

    /// @notice Returns the adaptor's type.
    /// @dev Used by frontends to determine how to properly interact
    ///      with a supported asset.
    function adaptorType() external override returns (uint256) {
        return 1;
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice The minimum number of signer messages to be validated
    ///         for onchain oracle pricing to validate a price feed.
    function getUniqueSignersThreshold() public view override returns (uint8) {
        return uint8(_uniqueSignersThreshold);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Retrieves the price of a given asset in USD.
    /// @param asset The address of the asset for which the price is needed.
    /// @return A structure containing the price, error status,
    ///         and the quote format of the price (USD).
    function _getPriceInUSD(
        address asset
    ) internal view returns (PriceReturnData memory) {
        if (adaptorDataUSD[asset].isConfigured) {
            return _parseData(asset, adaptorDataUSD[asset], true);
        }

        return _parseData(asset, adaptorDataNonUSD[asset], false);
    }

    /// @notice Retrieves the price of a given asset in ETH.
    /// @param asset The address of the asset for which the price is needed.
    /// @return A structure containing the price, error status,
    ///         and the quote format of the price (ETH).
    function _getPriceInETH(
        address asset
    ) internal view returns (PriceReturnData memory) {
        if (adaptorDataNonUSD[asset].isConfigured) {
            return _parseData(asset, adaptorDataNonUSD[asset], false);
        }

        return _parseData(asset, adaptorDataUSD[asset], true);
    }

    /// @notice Extracts the Redstone Core feed data for pricing of an asset.
    /// @dev Extracts price from Redstone Core attached msg.data to get
    ///      the latest data. Natively validates staleness.
    /// @param data Redstone Core feed details.
    /// @param inUSD A boolean to denote if the price is in USD.
    /// @return pData A structure containing the price, error status,
    ///               and the currency of the price.
    function _parseData(
        address asset,
        AdaptorData memory data,
        bool inUSD
    ) internal view returns (PriceReturnData memory pData) {
        uint256 price = overriddenPrice[asset][inUSD];
        if (price == 0) {
            revert RedstoneCoreAdaptor__AssetIsNotSupported();
        }

        // Cache decimals value.
        uint256 quoteDecimals = data.decimals;
        if (quoteDecimals != 18) {
            // Decimals are < 18 so we need to multiply up to coerce to
            // 18 decimals.
            if (quoteDecimals < 18) {
                price = price * (10 ** (18 - quoteDecimals));
            } else {
                // Decimals are > 18 so we need to multiply down to coerce to
                // 18 decimals.
                price = price / (10 ** (quoteDecimals - 18));
            }
        }

        pData.hadError = _verifyData(
            price,
            overriddenPriceUpdatedAt[asset][inUSD],
            data.max,
            data.heartbeat
        );

        if (!pData.hadError) {
            pData.inUSD = inUSD;
            pData.price = uint240(price);
        }
    }

    /// @notice Validates the feed data based on various constraints.
    /// @dev Checks if the value is within a specific range
    ///      and if the data is not outdated.
    /// @param value The value that is retrieved from the feed data.
    /// @param max The maximum limit of the value.
    /// @return A boolean indicating whether the feed data had an error
    ///         (true = error, false = no error).
    function _verifyData(
        uint256 value,
        uint256 timestamp,
        uint256 max,
        uint256 heartbeat
    ) internal view returns (bool) {
        // Validate `value` is not above the buffered maximum value allowed.
        if (value > max) {
            return true;
        }

        // If we got a price of 0, bubble up an error immediately.
        if (value == 0) {
            return true;
        }

        // Validate the price returned is not stale.
        if (block.timestamp - timestamp > heartbeat) {
            return true;
        }

        // We typically check for feed data staleness through a heartbeat
        // check, but redstone naturally checks timestamp through its msg.data
        // read, so we do not need to check again here.

        return false;
    }

    /// @notice Extracts price stored in msg.data with the transaction,
    ///         can be called multiple times in one transaction.
    function _extractPrice(
        bytes32 symbolHash
    ) internal view returns (uint256) {
        return getOracleNumericValueFromTxMsg(symbolHash);
    }

    /// @notice Adds new supported signers for redstone core msg.data
    ///         field validation.
    /// @param signers Array containing the new addresses to be authorised
    ///                inside the Redstone Core system.
    function _storeAuthorisedSigners(
        address[] memory signers
    ) internal override {
        uint256 numSigners = signers.length;
        address signer;

        for (uint256 i; i < numSigners; ++i) {
            signer = signers[i];

            _isAuthorisedSigner[signer] = i + 1;
            authorisedSigners.push(signer);
            
            emit RedstoneCoreSignerAdded(signer);
        }
    }
    
}
