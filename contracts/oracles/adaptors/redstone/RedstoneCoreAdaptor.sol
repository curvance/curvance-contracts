// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";

import { Bytes32Helper } from "contracts/libraries/Bytes32Helper.sol";
import { PrimaryProdDataServiceConsumerBase } from "contracts/libraries/external/redstone/PrimaryProdDataServiceConsumerBase.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";
import { PriceReturnData } from "contracts/interfaces/IOracleAdaptor.sol";

contract RedstoneCoreAdaptor is
    BaseOracleAdaptor,
    PrimaryProdDataServiceConsumerBase
{
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

    /// @notice Stores cached data for Redstone core prices pulled
    ///         from msg.data.
    /// @param price The price recorded for an asset, in `WAD`.
    /// @param redstoneTimestamp The price timestamp reported by Redstone
    ///                          signers, in milliseconds.
    /// @param blockTimestamp The block timestamp when `price` was stored,
    ///                       in seconds.
    struct StoredData {
        uint256 price;
        uint128 redstoneTimestamp;
        uint128 blockTimestamp;
    }

    /// CONSTANTS ///

    /// @notice If zero is specified for an asset heartbeat,
    ///         `DEFAULT_HEART_BEAT` is used instead.
    /// @dev    10 minutes = 600 seconds.
    uint256 public constant DEFAULT_HEART_BEAT = 10 minutes;
    /// @notice The smallest value that Redstone Core unique signer threshold
    ///         can be inside Curvance.
    uint256 public constant MINIMUM_SIGNERS_THRESHOLD_ALLOWED = 3;
    /// @notice The maximum number of signers allowed inside this adaptor.
    /// @dev 1.002e4 = 0.2%.
    uint256 public constant MAXIMUM_SIGNERS_ALLOWED = 255;
    /// @notice The maximum timestamp delay from block.timestamp that is
    ///         acceptable.
    uint256 constant DEFAULT_MAX_DATA_TIMESTAMP_DELAY_SECONDS = 3 minutes;
    /// @notice The maximum timestamp ahead from block.timestamp that is
    ///         acceptable.
    uint256 constant DEFAULT_MAX_DATA_TIMESTAMP_AHEAD_SECONDS = 1 minutes;

    /// STORAGE ///

    /// @notice Array containing a list of all authorised signers
    ///         inside Redstone Core.
    address[] public authorisedSigners;

    /// @notice The minimum number of unique signers required to accept
    ///          a Redstone Core price.
    uint256 internal _uniqueSignersThreshold;

    /// @notice Adaptor configuration data for pricing an asset.
    /// @dev Token address => inUSD => Adaptor Data.
    mapping(address => mapping(bool => AdaptorData)) public adaptorData;

    mapping(address => mapping(bool => StoredData)) private storedData;

    /// @dev A fixed key to use in transient storage for validating that the
    ///      timestamp provided on price write is accurate.
    bytes32 internal constant _TRANSIENT_REDSTONE_TIMESTAMP_KEY
        = 0x4567890123456789012345678901234567890123456789012345678901234567;

    /// EVENTS ///

    event AssetAdded(address asset, AdaptorData assetConfig, bool isUpdate);
    event AssetRemoved(address asset);
    event SignerUpdated(address signer, bool addPerms);
    /// ERRORS ///

    error RedstoneCoreAdaptor__InvalidConfiguration();
    error RedstoneCoreAdaptor__AssetIsNotSupported();
    error RedstoneCoreAdaptor__InvalidPrice();
    error RedstoneCoreAdaptor__StalePrice();

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address[] memory signers,
        uint256 uniqueSignersThreshold_
    )
        BaseOracleAdaptor(centralRegistry_)
        PrimaryProdDataServiceConsumerBase(signers)
    {
        // Validate that unique signer threshold is within acceptable limits.
        if (MINIMUM_SIGNERS_THRESHOLD_ALLOWED > uniqueSignersThreshold_) {
            revert RedstoneCoreAdaptor__InvalidConfiguration();
        }

        uint256 numSigners = signers.length;

        // Validate unique signer threshold is possible to reach based
        // on signers authorised.
        if (uniqueSignersThreshold_ > numSigners) {
            revert RedstoneCoreAdaptor__InvalidConfiguration();
        }

        // Validate that the number of signers is below the maximum allowed.
        if (MAXIMUM_SIGNERS_ALLOWED < numSigners) {
            revert RedstoneCoreAdaptor__InvalidConfiguration();
        }

        _uniqueSignersThreshold = uniqueSignersThreshold_;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Retrieves the price of a given asset.
    /// @dev Uses Redstone Core oracles to fetch the price data.
    ///      Price is returned in USD or a chain's native token depending on
    ///      'inUSD' parameter.
    /// @param asset The address of the asset for which the price is needed.
    /// @param inUSD Specifies whether the price format should be in USD (true)
    ///              or a chain's native token (false).
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

        return _getPrice(asset, inUSD);
    }

    /// @notice Writes a Redstone Core price to this adaptor contract to be
    ///         queried later by Curvance Protocol or external users.
    /// @param asset The address of the supported asset to write a price for.
    /// @param inUSD Whether the price is being written in USD,
    ///              or the chain's native token.
    function writePrice(
        address asset,
        bool inUSD,
        uint128 redstoneTimestamp
    ) external {
        AdaptorData memory data = adaptorData[asset][inUSD];
        if (!data.isConfigured) {
            revert RedstoneCoreAdaptor__AssetIsNotSupported();
        }

        StoredData storage assetData = storedData[asset][inUSD];
        if (assetData.redstoneTimestamp >= redstoneTimestamp) {
            return; // Can skip storing the data since the data is stale.
        }

        _validateTimestamp(redstoneTimestamp);
        /// @solidity memory-safe-assembly
        assembly {
            tstore(_TRANSIENT_REDSTONE_TIMESTAMP_KEY, redstoneTimestamp)
        }

        uint256 price = getOracleNumericValueFromTxMsg(data.symbolHash);

        // Cache price feed decimals format.
        uint256 quoteDecimals = data.decimals;
        if (quoteDecimals != 18) {
            price = _normalizePrice(price, quoteDecimals);
        }

        // Validate `price` is not at or above the maximum value allowed.
        if (price >= data.max) {
            revert RedstoneCoreAdaptor__InvalidPrice();
        }

        // Validate `price` is not truncated or misreported with a 0 value.
        if (price == 0) {
            revert RedstoneCoreAdaptor__InvalidPrice();
        }

        assetData = StoredData({
            price: price,
            blockTimestamp: uint128(block.timestamp),
            redstoneTimestamp: redstoneTimestamp
        });

        /// @solidity memory-safe-assembly
        assembly {
            tstore(_TRANSIENT_REDSTONE_TIMESTAMP_KEY, 0)
        }
    }

    /// @notice Validate the timestamp of a Redstone signed price data
    ///         package.
    /// @param receivedTimestampMilliseconds Data package timestamp in
    ///                                      milliseconds.
    /// @dev Internally called in `updatePrice` for every signed data package
    ///      in the payload.
    function validateTimestamp(
        uint256 receivedTimestampMilliseconds
    ) public view virtual override {
        uint256 redstoneTimestampProposed;
        assembly {
            redstoneTimestampProposed := tload(_TRANSIENT_REDSTONE_TIMESTAMP_KEY)
        }

        if (receivedTimestampMilliseconds != redstoneTimestampProposed){
            revert RedstoneCoreAdaptor__StalePrice();
        }
    }

    /// @notice Add a Redstone Core Price Feed as an asset.
    /// @dev Should be called before `OracleManager:addAssetPriceFeed`
    ///      is called.
    /// @param asset The address of the token to add pricing support for.
    /// @param inUSD Whether the price feed is in USD (inUSD = true)
    ///              or native token (inUSD = false).
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
                revert RedstoneCoreAdaptor__InvalidConfiguration();
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

        AdaptorData storage data = adaptorData[asset][inUSD];

        // If decimals == 0 we use default 8 decimals that
        // Redstone typically provides prices in.
        if (decimals == 0) {
            data.decimals = 8;
        } else {
            // Otherwise, coerce uint8 to uint256 for cheaper
            // runtime conversion.
            data.decimals = uint256(decimals);
        }

        // We need to make sure casting to a uint240 will not truncate
        // the reported price.
        data.max = type(uint240).max;
        data.symbolHash = symbolHash;
        data.heartbeat = heartbeat;
        data.isConfigured = true;

        // Check whether this is new or updated support for `asset`.
        bool isUpdate;
        if (isSupportedAsset[asset]) {
            isUpdate = true;
        }

        isSupportedAsset[asset] = true;
        emit AssetAdded(asset, data, isUpdate);
    }

    /// @notice Removes a supported asset from the adaptor.
    /// @dev Calls back into Oracle Manager to notify it of its removal.
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
        delete adaptorData[asset][true];
        delete adaptorData[asset][false];

        // Notify the Oracle Manager that we are going to stop supporting
        // the asset.
        IOracleManager(centralRegistry.oracleManager()).notifyFeedRemoval(
            asset
        );

        emit AssetRemoved(asset);
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
        // Its not intended to ever get close to 255 signers but this is
        // theoretically the maximum for the uint8 storage value, so a
        // sanity check is made.
        if (signerIndex >= MAXIMUM_SIGNERS_ALLOWED) {
            revert RedstoneCoreAdaptor__InvalidConfiguration();
        }

        // Add `newSigner` to quick access address mapping.
        _isAuthorisedSigner[newSigner] = signerIndex + 1;
        // Add `newSigner` to authorised signer list.
        authorisedSigners.push(newSigner);

        if (incrementSignerThreshold) {
            _uniqueSignersThreshold++;
        }

        emit SignerUpdated(newSigner, true);
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
        delete _isAuthorisedSigner[currentSigner];
        uint256 lastSignerIndex = authorisedSigners.length;

        // Switch array locations on authorised signer so we can pop
        // `currentSigner` from the end.
        if (index != lastSignerIndex) {
            _isAuthorisedSigner[
                authorisedSigners[lastSignerIndex - 1]
            ]= index;
            authorisedSigners[index - 1] = authorisedSigners[
                lastSignerIndex - 1
            ];
        }

        // Remove `currentSigner` from authorised signer list.
        authorisedSigners.pop();

        if (decrementSignerThreshold) {
            // Make sure that decreasing the signer threshold would not pushed
            // signer requirement below minimum allowed inside the Curvance
            // Protocol.
            if (_uniqueSignersThreshold == MINIMUM_SIGNERS_THRESHOLD_ALLOWED) {
                revert RedstoneCoreAdaptor__InvalidConfiguration();
            }

            _uniqueSignersThreshold--;
        } else {
            if (authorisedSigners.length < _uniqueSignersThreshold) {
                revert RedstoneCoreAdaptor__InvalidConfiguration();
            }
        }

        emit SignerUpdated(currentSigner, false);
    }

    /// @notice Returns the adaptor's type.
    /// @dev Used by frontends to determine how to properly interact
    ///      with a supported asset.
    function adaptorType() external pure override returns (uint256) {
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
    function _getPrice(
        address asset,
        bool inUSD
    ) internal view returns (PriceReturnData memory) {
        // Parse data from the format you want if its configured, otherwise
        // price in the other format and manually convert in Oracle Manager.
        if (adaptorData[asset][inUSD].isConfigured) {
            return _parseData(asset, adaptorData[asset][inUSD].heartbeat, inUSD);
        }

        return _parseData(asset, adaptorData[asset][!inUSD].heartbeat, !inUSD);
    }

    /// @notice Extracts the Redstone Core feed data for pricing of an asset.
    /// @dev Extracts price from Redstone Core attached msg.data to get
    ///      the latest data. Natively validates staleness.
    /// @param asset The address of the asset to parse data for.
    /// @param heartbeat The max amount of time allowed between price updates.
    /// @param inUSD A boolean to denote if the price is in USD.
    /// @return pData A structure containing the price, error status,
    ///               and the currency of the price.
    function _parseData(
        address asset,
        uint256 heartbeat,
        bool inUSD
    ) internal view returns (PriceReturnData memory pData) {
        pData.inUSD = inUSD;
        StoredData memory assetData = storedData[asset][inUSD];
        // Validate the price returned is not stale.
        if (block.timestamp - assetData.blockTimestamp > heartbeat) {
            pData.hadError;
            return;
        }

        uint256 price = uint240(assetData.price);
    }

    /// @dev This logic replicates RedstoneDefaultsLib.validateTimestamp
    ///      which we've replaced in the Redstone library for more
    ///      efficient timestamp validation.
    function _validateTimestamp(
        uint256 receivedTimestampMilliseconds
    ) internal view {
        // Getting data timestamp from future seems quite unlikely
        // But we've already spent too much time with different cases
        // Where block.timestamp was less than dataPackage.timestamp.
        // Some blockchains may case this problem as well.
        // That's why we add MAX_BLOCK_TIMESTAMP_DELAY
        // and allow data "from future" but with a small delay
        uint256 receivedTimestampSeconds = receivedTimestampMilliseconds /
            1000;

        if (block.timestamp < receivedTimestampSeconds) {
            if (
                (receivedTimestampSeconds - block.timestamp) >
                DEFAULT_MAX_DATA_TIMESTAMP_AHEAD_SECONDS
            ) {
                revert RedstoneCoreAdaptor__StalePrice();
            }
        } else if (
            (block.timestamp - receivedTimestampSeconds) >
            DEFAULT_MAX_DATA_TIMESTAMP_DELAY_SECONDS
        ) {
            revert RedstoneCoreAdaptor__StalePrice();
        }
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
            /// Validate that `signer` is not already authorised.
            if (_isAuthorisedSigner[signer] != 0) {
                revert RedstoneCoreAdaptor__InvalidConfiguration();
            }

            _isAuthorisedSigner[signer] = i + 1;
            authorisedSigners.push(signer);

            emit SignerUpdated(signer, true);
        }
    }
}
