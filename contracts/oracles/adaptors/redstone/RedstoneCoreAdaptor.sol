// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BaseOracleAdaptor, ICentralRegistry } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";

import { Bytes32Helper } from "contracts/libraries/Bytes32Helper.sol";

import { PrimaryProdDataServiceConsumerBase } from "@redstone/evm-connector/contracts/data-services/PrimaryProdDataServiceConsumerBase.sol";

contract RedstoneCoreAdaptor is
    BaseOracleAdaptor,
    PrimaryProdDataServiceConsumerBase
{
    /// TYPES ///

    /// @notice Stores configuration data for Redstone price sources.
    /// @param dataFeedId bytes32 value that uniquely identifies the Redstone
    ///                   Core asset data feed.
    /// @param decimals Returns the number of decimals the Redstone price feed
    ///                 responds with.
    /// @param redstoneTimestamp The price timestamp reported by Redstone
    ///                          signers, in milliseconds.
    /// @param price The price recorded for an asset, in `WAD`.
    struct AssetConfig {
        bytes32 dataFeedId;
        uint8 decimals;
        uint48 redstoneTimestamp;
        uint200 price;
    }

    /// CONSTANTS ///

    /// @notice The smallest value that Redstone Core unique signer threshold
    ///         can be inside Curvance.
    uint256 public constant MINIMUM_SIGNERS_THRESHOLD_ALLOWED = 3;
    /// @notice The maximum number of signers allowed inside this adaptor.
    uint256 public constant MAXIMUM_SIGNERS_ALLOWED = 255;
    /// @notice The maximum possible value settable on deployment for this
    ///         Redstone Core Adaptor's maximum timestamp delay from
    ///         block.timestamp that is acceptable.
    uint256 constant MAXIMUM_DEFAULT_HEARTBEAT_ALLOWED = 1 minutes;
    /// @notice The maximum timestamp ahead from block.timestamp that is
    ///         acceptable.
    uint256 constant DEFAULT_MAX_DATA_TIMESTAMP_AHEAD_SECONDS = 1 minutes;

    /// @notice The maximum timestamp delay from block.timestamp that is
    ///         acceptable, in seconds.
    /// @dev This is one value for all assets because its tied to user sourced
    ///      offchain prices being processed in time by the blockchain not
    ///      onchain procedural/deviation updates like models like Chainlink
    ///      price feeds or Redstone classic. If theres a real argument for
    ///      different `DEFAULT_HEARTBEAT` values due to asset volatility
    ///      multiple redstone core adaptors can be deployed.
    ///      Its intentional that this is not configurable via a setter, if a
    ///      chain speeds up its block times a new adaptor version can be
    ///      deployed and updated in the Oracle Manager.
    uint256 public immutable DEFAULT_HEARTBEAT;

    /// STORAGE ///

    /// @notice Array containing a list of all authorised signers
    ///         inside Redstone Core.
    address[] public authorisedSigners;

    /// @notice The minimum number of unique signers required to accept
    ///         a Redstone Core price.
    uint256 internal _uniqueSignersThreshold;

    /// @notice Native token symbol metadata.
    string internal _nativeSymbol;

    /// @notice Price feed configuration and price storage for an asset.
    /// @dev Token address => inUSD => Price feed configuration and price
    ///      storage for `asset`.
    mapping(address => mapping(bool => AssetConfig)) public assetConfig;

    /// @notice Indicates whether an address is authorised inside the Redstone
    ///         Core system.
    /// @dev Address => index they are authorised under inside Redstone.
    mapping(address => uint256) internal _isAuthorisedSigner;

    /// @notice A fixed key to use in transient storage for validating that
    ///         the timestamp proposed on price write is accurate.
    /// @dev Key value = `uint256(keccak256(_TRANSIENT_REDSTONE_TIMESTAMP_KEY))`.
    bytes32 internal constant _TRANSIENT_REDSTONE_TIMESTAMP_KEY
        = 0x32997e75db6d43b5797d8a1d45933662e40d99f3c30ca7b506f8782429b6da8e;

    /// EVENTS ///

    event AssetAdded(address asset, AssetConfig config, bool isUpdate);
    event SignerUpdated(address signer, bool addPerms);

    /// ERRORS ///

    error RedstoneCoreAdaptor__InvalidConfiguration();
    error RedstoneCoreAdaptor__AssetIsNotSupported();
    error RedstoneCoreAdaptor__InvalidPrice();
    error RedstoneCoreAdaptor__StalePrice();

    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
    /// @param signers Array containing addresses authorised inside the
    ///                Redstone Core system.
    /// @param uniqueSignersThreshold_ The minimum number of unique signers
    ///                                required to accept a Redstone Core
    ///                                price.
    /// @param nativeSymbol Native token symbol metadata.
    constructor(
        ICentralRegistry cr,
        address[] memory signers,
        uint256 uniqueSignersThreshold_,
        string memory nativeSymbol,
        uint256 defaultHeartbeat
    ) BaseOracleAdaptor(
        cr,
        "RedstoneCoreAdaptor"
    ) PrimaryProdDataServiceConsumerBase() {
        _nativeSymbol = nativeSymbol;

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

        // Validate that the attached heartbeat is not too long as this
        // potentially opens up price selection attack vectors if too long.
        if (defaultHeartbeat > MAXIMUM_DEFAULT_HEARTBEAT_ALLOWED) {
            revert RedstoneCoreAdaptor__InvalidConfiguration();
        }

        // Enforce maximum default heartbeat allowed for Ethereum L1 whereas
        // other chains can potentially be lower due to shorter block times.
        DEFAULT_HEARTBEAT = block.chainid == 1 ?
            MAXIMUM_DEFAULT_HEARTBEAT_ALLOWED : defaultHeartbeat;

        for (uint256 i; i < numSigners; ++i) {
            address signer = signers[i];

            /// Validate that `signer` is not already authorised.
            if (_isAuthorisedSigner[signer] != 0) {
                revert RedstoneCoreAdaptor__InvalidConfiguration();
            }

            _isAuthorisedSigner[signer] = i + 1;
            authorisedSigners.push(signer);

            emit SignerUpdated(signer, true);
        }

        _uniqueSignersThreshold = uniqueSignersThreshold_;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Writes a Redstone Core price to this adaptor contract to be
    ///         queried later by Curvance Protocol or external users.
    /// @param asset The address of the supported asset to write a price for.
    /// @param inUSD Whether the price is being written in USD,
    ///              or the chain's native token.
    /// @param redstoneTimestamp The proposed timestamp of the Redstone Core
    ///                          price feed data, in milliseconds.
    function writePrice(
        address asset,
        bool inUSD,
        uint48 redstoneTimestamp
    ) external {
        AssetConfig storage config = assetConfig[asset][inUSD];

        // We can check if `asset` is supposed by checking `decimals` as we
        // do not allow configuring `decimals` equal to 0.
        if (config.decimals == 0) {
            revert RedstoneCoreAdaptor__AssetIsNotSupported();
        }

        if (config.redstoneTimestamp >= redstoneTimestamp) {
            return; // Can skip storing the data since the data is stale.
        }

        _validateTimestamp(redstoneTimestamp);
        /// @solidity memory-safe-assembly
        assembly {
            tstore(_TRANSIENT_REDSTONE_TIMESTAMP_KEY, redstoneTimestamp)
        }

        uint256 price = getOracleNumericValueFromTxMsg(config.dataFeedId);

        // Validate `price` is not at or above the maximum value allowed,
        // and `price` is not truncated or misreported with a 0 value.
        // This is so people cannot write a bad price and brick other core
        // price reads due to backwards timestamp price updates being blocked.
        if (price == 0 || price > type(uint200).max) {
            revert RedstoneCoreAdaptor__InvalidPrice();
        }

        config.price = uint200(price);
        config.redstoneTimestamp = redstoneTimestamp;

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
    /// @dev Should be called before `OracleManager:addAssetPricingAdaptor`
    ///      is called.
    ///      NOTE: BE VERY CAREFUL SETTING `id`, AN INCORRECT VALUE CAN BLOCK
    ///            PRICING UNINTENTIONALLY.
    /// @param asset The address of the token to add pricing support for.
    /// @param inUSD Whether the price feed is in USD (inUSD = true)
    ///              or native token (inUSD = false).
    /// @param decimals The number of decimals the redstone core feed
    ///                 prices in.
    /// @param id The dataFeedId of the token to add pricing for,
    ///           in string form.
    function addAsset(
        address asset,
        bool inUSD,
        uint8 decimals,
        string memory id
    ) external {
        _checkElevatedPermissions();

        // Update `config` and make sure `isSupportedAsset` returns true
        // for `asset`.
        AssetConfig storage config = assetConfig[asset][inUSD];

        config.dataFeedId = Bytes32Helper.toBytes32(id);
        // If decimals == 0 we use default 8 decimals that
        // Redstone typically provides prices in.
        config.decimals = decimals != 0 ? decimals : 8;
        
        // Check whether this is new or updated support for `asset`.
        bool isUpdate;
        if (isSupportedAsset[asset]) {
            isUpdate = true;
        }

        isSupportedAsset[asset] = true;
        emit AssetAdded(asset, config, isUpdate);
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

    /// PUBLIC FUNCTIONS ///

    function getAuthorisedSignerIndex(
        address signerAddress
    ) public view override returns (uint8) {
        uint256 index = _isAuthorisedSigner[signerAddress];

        /// Validate that `signerAddress` is authorised.
        if (index == 0) {
            revert SignerNotAuthorised(signerAddress);
        }

        // Return authorised signer index.
        return uint8(index);
    }

    /// @notice The minimum number of signer messages to be validated
    ///         for onchain oracle pricing to validate a price feed.
    function getUniqueSignersThreshold() public view override returns (uint8) {
        return uint8(_uniqueSignersThreshold);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Retrieves the price of a given asset in `inUSD` price form.
    /// @dev Extracts price from Redstone Core attached msg.data to get
    ///      the latest data. Natively validates staleness.
    /// @param asset The address of the asset for which the price is needed.
    /// @param inUSD Whether `asset` should be priced in USD or native tokens.
    /// @return result Return data for a priced asset containing:
    ///                price The price of the asset.
    ///                inUSD Boolean indicating whether `price` is denominated
    ///                      in USD (true) or native token (false).
    ///                hadError Boolean indicating whether the asset was
    ///                         priced without running into any issues or not.
    function _getPrice(
        address asset,
        bool inUSD
    ) internal view override returns (PricingResult memory result) {
        // We can check if `asset` pricing in `inUSD` is supported by checking
        // `decimals` as we do not allow configuring `decimals` equal to 0.
        // If unsupported price in the other denomination and manually convert
        // in Oracle Manager.
        if (assetConfig[asset][inUSD].decimals == 0) {
            inUSD = !inUSD; 
        }

        AssetConfig memory config = assetConfig[asset][inUSD];
        result.inUSD = inUSD;

        // Adjust price pulled, if necessary.
        uint256 adjustedPrice =
            _adjustPrice(asset, inUSD, config.price, config.decimals);

        uint256 timestampInSeconds = config.redstoneTimestamp / 1000;
        // Validate the price returned is not stale, and that the price was
        // not reduced to 0 by the price guard minimum price, giving us parity
        // with BaseOracleAdaptor's `_verifyData`.
        if (
            (timestampInSeconds < block.timestamp &&
                block.timestamp - timestampInSeconds > DEFAULT_HEARTBEAT) ||
            adjustedPrice == 0
        ) {
            result.hadError = true;
        }

        result.price = adjustedPrice;
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
            (block.timestamp - receivedTimestampSeconds) > DEFAULT_HEARTBEAT
        ) {
            revert RedstoneCoreAdaptor__StalePrice();
        }
    }

    /// @notice Wipes `asset` pricing configurations from this adaptor.
    /// @param asset The address of the asset to wipe pricing support of.
    function _wipeAssetConfigs(address asset) internal override {
        delete assetConfig[asset][true];
        delete assetConfig[asset][false];
    }
}