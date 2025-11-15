// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";
import { WAD, BPS, NO_ERROR, CAUTION, BAD_SOURCE } from "contracts/libraries/ConstantsLib.sol";

import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

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
///      - An error code of 0 (NO_ERROR) corresponds to no error occurred
///        during pricing.
///      - An error code of 1 (CAUTION) corresponds to moderate issues
///        occurring during pricing, inside Curvance this results in new
///        borrowing, repayment, and redemption actions being blocked.
///      - An error code of 2 (BAD_SOURCE) corresponds to large issues
///        occurring during pricing, inside Curvance this results in new
///        borrowing, repayment, redemptions, and liquidation actions being
///        blocked.
///
///      "Circuit Breakers" have been introduced, that can be triggered based
///      on the prices returned to the Oracle Manager by adaptors. If prices
///      deviate heavily, error codes can be returned.
///      - An error code of 1 will be triggered by a deviation between pricing
///        adaptors of >= `cautionBound` for the corresponding asset.
///      - An error code of 2 will be triggered by a deviation between pricing
///        adaptors of >= `badSourceBound` for the corresponding asset.
///
///      Oracle Adaptors can be added or removed by the DAO which can change
///      how an asset is priced. This allows for continually improving the
///      data quality returned within the system. Oracle Adaptors handle
///      checks such as price staleness, decimal offsetting, and ecosystem
///      specific logic. All this is abstracted away from the Oracle Manager,
///      all data is returned in a standardized format of 18 decimals. Prices
///      must be positive (> 0). When PriceGuards are configured on an adaptor,
///      minimum and maximum prices are enforced via the guard's `minPrice`
///      (uint88) and `basePrice` (uint88) parameters respectively. When no
///      PriceGuard is configured, prices can range up to uint256.max with no
///      upper constraint beyond what the underlying oracle feed supports.
///      When using the Oracle Manager, verify what PriceGuard configurations
///      are active for the oracle adaptors to understand the effective
///      minimum/maximum price constraints.
///
///      Oracle Adaptors also can be used to introduce realtime information
///      based on offchain logic such as dynamic liquidation penalties.
///
///      The Oracle Manager was built to minimize Oracle trust by introducing
///      a decentralized model, many oracle providers all verified against
///      each other. "Don't trust, verify."
///
contract OracleManager is IOracleManager {
    /// TYPES ///

    /// @notice Storage structure for asset pricing configuration from various
    ///         oracle pricing adaptors.
    /// @param badSourceBoundUSD The bound value allowed between adaptor
    ///                          prices before `BAD_SOURCE` error code is
    ///                          returned, in `BPS`. An additional `BPS` is
    ///                          added to the value to save runtime gas costs
    ///                          during `_checkBounds` call. Used when pricing
    ///                          in USD denomination.
    /// @param cautionBoundUSD The bound value allowed between adaptor prices
    ///                        before `CAUTION` error code is returned, in
    ///                        `BPS`. An additional `BPS` is added to the
    ///                        value to save runtime gas costs during
    ///                        `_checkBounds` call. Used when pricing in USD
    ///                        denomination.
    /// @param badSourceBoundNative The bound value allowed between adaptor
    ///                             prices before `BAD_SOURCE` error code is
    ///                             returned, in `BPS`. An additional `BPS` is
    ///                             added to the value to save runtime gas
    ///                             costs during `_checkBounds` call. Used
    ///                             when pricing in native chain token
    ///                             denomination.
    /// @param cautionBoundNative The bound value allowed between adaptor
    ///                           prices before `CAUTION` error code is
    ///                           returned, in `BPS`. An additional `BPS`
    ///                           is added to the value to save runtime gas
    ///                           costs during `_checkBounds` call. Used when
    ///                           pricing in native chain token denomination.
    /// @dev 10050 = 0.5% = 50 basis point price feed deviation allowed.
    /// @param adaptors Array containing all pricing adaptors an asset is
    ///                 dependent on, maximum 2, 0 dependencies means the
    ///                 asset is not.
    struct PricingConfig {
        uint16 badSourceBoundUSD;
        uint16 cautionBoundUSD;
        uint16 badSourceBoundNative;
        uint16 cautionBoundNative;
        address[] adaptors;
    }

    /// CONSTANTS ///

    /// @notice Address identifying a chain's native token.
    address public constant native =
        0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    /// @notice Time to pass before accepting answers when sequencer
    ///         comes back up, in seconds.
    uint256 public constant GRACE_PERIOD_TIME = 300;
    /// @notice Maximum value that a price deviation bound can be set as
    ///         inside the protocol, in `BPS`.
    /// @dev 300 = 3.0%, in `BPS`.
    uint256 public constant MAX_DEVIATION_BOUND = 350;
    /// @notice Minimum value that a price deviation bound can be set as
    ///         inside the protocol.
    /// @dev 20 = 0.2%.
    uint256 public constant MIN_DEVIATION_BOUND = 20;
    /// @notice The minimum buffer between `CAUTION` bound and `BAD_SOURCE`
    ///         bound when configuring bound values, in `BPS`.
    /// @dev 20 = 0.2% minimum buffer before `BAD_SOURCE` value can
    ///      be triggered.
    uint256 public constant MIN_CAUTION_TO_BAD_SOURCE_DELTA = 20;

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;

    /// STORAGE ///

    /// @notice Whether an address is an approved Curvance price feed adaptor.
    /// @dev Adaptor address => Approved for usage.
    // Address => Adaptor approval status.
    mapping(address => bool) public isApprovedAdaptor;
    /// @notice Pricing configuration data for an asset.
    /// @dev Token address => Pricing configuration for `asset`.
    mapping(address => PricingConfig) public assetPricingConfig;
    // Address => Curvance token underlying asset address.
    mapping(address => address) public cTokens;

    /// EVENTS ///

    event AdaptorDependencyAdded(address asset, address adaptor);
    event AdaptorDependencyRemoved(address asset, address adaptor);
    event AssetDeviationBoundsSet(
        address asset,
        uint256 badSourceBound,
        uint256 cautionBound
    );

    /// ERRORS ///

    error OracleManager__Unauthorized();
    error OracleManager__NotSupported();
    error OracleManager__InvalidParameter();
    error OracleManager__ErrorCodeFlagged();
    error OracleManager__AdaptorIsNotApproved();

    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
    constructor(ICentralRegistry cr) {
        CentralRegistryLib._isCentralRegistry(cr);
        centralRegistry = cr;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Adds a new dependency for pricing `asset` on `adaptor`. If
    ///         this is the second adaptor dependency, set deviation values
    ///         too, validating they are safe based on price feed deviation.
    /// @dev Requires that `adaptor` is an approved adaptor, and that `asset`
    ///      does not already have two adaptor dependencies.
    ///      May emit an {AssetDeviationBoundsSet} event.
    /// @param asset The address of the asset to add a new pricing adaptor
    ///              dependency for.
    /// @param adaptor The address of the new adaptor to add dependency to.
    /// @param inUSD Whether the deviation bounds for `asset` is for
    ///              pricing in USD (inUSD = true) or native
    ///              token (inUSD = false).
    /// @param badSourceBound The new maximum price deviation before a
    ///                       `BAD_SOURCE` error code is returned, only
    ///                       used when adding a second adaptor dependency.
    /// @param cautionBound The new maximum price deviation before a
    ///                     `CAUTION` error code is returned, only used when
    ///                     adding a second adaptor dependency.
    function addAssetPricingAdaptor(
        address asset,
        address adaptor,
        bool inUSD,
        uint256 badSourceBound,
        uint256 cautionBound
    ) external {
        _checkElevatedPermissions();
        _addAssetPricingAdaptor(asset, adaptor);

        // Pull `asset` pricing config data after the new adaptor has been
        // added.
        PricingConfig storage config = assetPricingConfig[asset];

        // If there are not two adaptor dependencies we can skip this logic.
        if (config.adaptors.length > 1) {
            _setDeviationBounds(asset, config, inUSD, badSourceBound, cautionBound);
        }
    }

    /// @notice Replaces the dependency on pricing from `adaptorToRemove` for
    ///         `asset` in favor of adding dependency on pricing to
    ///         `adaptorToAdd`.
    /// @dev Requires that `adaptorToAdd` is an approved adaptor, and that
    ///      `asset` currently has at least one adaptor configured. Which
    ///      should include `adaptorToRemove`.
    ///      May emit an {AssetDeviationBoundsSet} event.
    /// @param asset The address of the asset to adjust pricing adaptors for.
    /// @param adaptorToRemove The address of the adaptor to remove dependency
    ///                        from.
    /// @param adaptorToAdd The address of the new adaptor to add dependency
    ///                     to.
    /// @param inUSD Whether the deviation bounds for `asset` is for
    ///              pricing in USD (inUSD = true) or native
    ///              token (inUSD = false).
    /// @param badSourceBound The new maximum price deviation before a
    ///                       `BAD_SOURCE` error code is returned, only
    ///                       used when replacing a second adaptor dependency.
    /// @param cautionBound The new maximum price deviation before a
    ///                     `CAUTION` error code is returned, only used when
    ///                     replacing a second adaptor dependency.
    function replaceAssetPricingAdaptor(
        address asset,
        address adaptorToRemove,
        address adaptorToAdd,
        bool inUSD,
        uint256 badSourceBound,
        uint256 cautionBound
    ) external {
        _checkElevatedPermissions();

        // Validate that the feeds are not identical as there would be no
        // point to replace a feed with itself.
        if (adaptorToRemove == adaptorToAdd) {
            revert OracleManager__InvalidParameter();
        }

        _removeAssetPricingAdaptor(asset, adaptorToRemove);
        _addAssetPricingAdaptor(asset, adaptorToAdd);

        // Pull `asset` pricing config data after the new adaptor has been
        // added.
        PricingConfig storage config = assetPricingConfig[asset];

        // If there are not two adaptor dependencies we can skip this logic.
        if (config.adaptors.length > 1) {
            _setDeviationBounds(asset, config, inUSD, badSourceBound, cautionBound);
        }
    }

    /// @notice Removes the dependency on pricing from `adaptor` for `asset`.
    /// @dev Requires that `adaptor` is currently being used for pricing
    ///      `asset`.
    ///      NOTE: This intentionally does not modify asset deviation values
    ///            because they simply wont be used if there are less than two
    ///            pricing adaptors in use, so no reason to delete data as
    ///            when a second pricing adaptor is configured the deviation
    ///            has the opportunity be to reconfigured anyway.
    /// @param asset The address of the asset to remove pricing adaptor
    ///              dependency from.
    /// @param adaptor The address of the adaptor to remove dependency from.
    function removeAssetPricingAdaptor(address asset, address adaptor) external {
        _checkElevatedPermissions();
        _removeAssetPricingAdaptor(asset, adaptor);
    }

    /// @notice Potentially removes the dependency on pricing from `adaptor`
    ///         for `asset`, triggered by an adaptor's notification of a price
    ///         feed's removal.
    /// @notice Removes a pricing adaptor for `asset` triggered by an
    ///         adaptor's notification of a price feed's removal.
    /// @dev Requires that the adaptor is currently being used for pricing
    ///      for `asset`.
    ///      NOTE: This intentionally does not modify deviation bound values
    ///            because they simply wont be used if there are less than two
    ///            pricing adaptors in use, so no reason to delete data as
    ///            when a second pricing adaptor is configured the deviation
    ///            has the opportunity be to reconfigured anyway.
    /// @param asset The address of the asset to potentially remove the
    ///              pricing adaptor dependency from depending on current
    ///              `asset` configuration.
    function notifyFeedRemoval(address asset) external {
        if (!isApprovedAdaptor[msg.sender]) {
            return;
        }

        address[] memory adaptors = assetPricingConfig[asset].adaptors;
        uint256 numAdaptors = adaptors.length;

        // Validate calling adaptor is a currently supported used for `asset`.
        // If unused can return immediately.
        if (numAdaptors > 1) {
            if (adaptors[0] != msg.sender && adaptors[1] != msg.sender) {
                return;
            }
        } else {
            if (numAdaptors == 0) {
                return;
            }

            if (adaptors[0] != msg.sender) {
                return;
            }
        }
        _removeAssetPricingAdaptor(asset, msg.sender);
    }

    /// @notice Returns the adaptors used for pricing `asset`.
    /// @param asset The address of the asset to get pricing adaptors for.
    /// @return result The current adaptor(s) used for pricing `asset`.
    function getPricingAdaptors(
        address asset
    ) external view returns(address[] memory result) {
        result = assetPricingConfig[asset].adaptors;
    }

    /// @notice Adds a new Curvance token to the Oracle Manager.
    /// @dev Requires that `newCToken` is not already supported.
    ///      The cToken's underlying CANNOT be equal to address(0).
    /// @param newCToken The address of the Curvance token to support.
    function addCTokenSupport(address newCToken) external {
        _checkElevatedPermissions();

        // We call a Curvance-specific token function as a sanity check.
        ICToken(newCToken).isBorrowable();

        // Validate `newCToken` has not already been registered as a cToken,
        // and that `newUnderlying` is not address(0) as that is how we check
        // whether a token is a cToken or not.
        address newUnderlying = ICToken(newCToken).asset();
        if (cTokens[newCToken] != address(0) || newUnderlying == address(0)) {
            revert OracleManager__InvalidParameter();
        }

        cTokens[newCToken]= newUnderlying;
    }

    /// @notice Removes a Curvance token's support in the Oracle Manager.
    /// @dev Requires that the Curvance token is supported.
    /// @param cTokenToRemove The address of the Curvance token to remove
    ///                       support for.
    function removeCTokenSupport(address cTokenToRemove) external {
        _checkElevatedPermissions();

        // Validate `newCToken` has already been registered as a cToken.
        if (cTokens[cTokenToRemove] == address(0)) {
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

    /// @notice Sets new maximum deviation bound values for pricing adaptors
    ///         before `CAUTION` or `BAD_SOURCE` error codes are activated
    ///         for `asset`.
    /// @dev Only allowed if there are two adaptor dependencies configured
    ///      already. Emits an {AssetDeviationBoundsSet} event.
    /// @param asset The address of the asset to set pricing deviation bound
    ///              values for.
    /// @param inUSD Whether the deviation bounds for `asset` is for
    ///              pricing in USD (inUSD = true) or native
    ///              token (inUSD = false).
    /// @param badSourceBound The new maximum price deviation before a
    ///                       `BAD_SOURCE` error code is returned.
    /// @param cautionBound The new maximum price deviation before a
    ///                     `CAUTION` error code is returned.
    function setDeviationBounds(
        address asset,
        bool inUSD,
        uint256 badSourceBound,
        uint256 cautionBound
    ) external {
        _checkElevatedPermissions();
        PricingConfig storage config = assetPricingConfig[asset];

        // If there are not two adaptor dependencies we can skip this logic.
        if (config.adaptors.length < 2) {
            revert OracleManager__InvalidParameter();
        }

        _setDeviationBounds(asset, config, inUSD, badSourceBound, cautionBound);
    }

    /// @notice Checks if a given asset is supported by the Oracle Manager.
    /// @dev An asset is considered supported if it has one
    ///      or more associated price feeds.
    /// @param asset The address of the asset to check.
    /// @return True if the asset is supported, false otherwise.
    function isSupportedAsset(address asset) external view returns (bool) {
        address cTokenUnderlying = cTokens[asset];
        if (cTokenUnderlying != address(0)) {
            return assetPricingConfig[cTokenUnderlying].adaptors.length > 0;
        }

        return assetPricingConfig[asset].adaptors.length > 0;
    }

    /// @notice Check whether L2 sequencer is valid or down.
    /// @dev Uses Chainlink sequencer check if available, regardless of
    ///      linked oracle adaptor.
    /// @return True if sequencer is valid.
    function isSequencerValid() external view returns (bool) {
        return _isSequencerValid();
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Retrieves the price of a specified asset from either single
    ///         or dual oracles.
    /// @dev If the asset has one oracle, it fetches the price from a single
    ///      feed. If it has two or more oracles, it fetches the price from both
    ///      feeds. Additionally, also checks Chainlink L2 sequencer via
    ///      `_isSequencerValid()`
    ///      and returns `(0, BAD_SOURCE)` if down, even for non-Chainlink
    ///      adaptors. This is by design.
    /// @param asset The address of the asset to retrieve the price for.
    /// @param inUSD Specifies whether the price format should be in
    ///              USD (true) or a chain's native token (false).
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
        address cTokenUnderlying = cTokens[asset];
        // Check whether `asset` is Curvance token.
        if (cTokenUnderlying != address(0)) {
            cToken = asset;
            asset = cTokenUnderlying;
        }

        (price, errorCode) = _getPrice(asset, inUSD, getLower);

        // Query the exchange rate between a Curvance token and its underlying
        // token and convert the price into WAD form.
        if (cToken != address(0)) {
            if (getLower) {
                price = FixedPointMathLib.mulDiv(
                    price,
                    ICToken(cToken).exchangeRate(),
                    WAD
                );
            } else {
                price = FixedPointMathLib.mulDivUp(
                    price,
                    ICToken(cToken).exchangeRate(),
                    WAD
                );
            }
        }
    }

    /// @notice Retrieves the prices of a collateral token, and debt token
    ///         underlying.
    /// @param collateralToken The cToken currently collateralized to price.
    /// @param debtToken The borrowableCToken borrowed from to price
    ///                  underlying of.
    /// @param errorCodeBreakpoint The error code that will cause liquidity
    ///                            operations to revert.
    /// @return collateralSharesPrice The current price of `collateralToken`.
    /// @return debtUnderlyingPrice The current price of `debtToken`
    ///                             underlying.
    function getPriceIsolatedPair(
        address collateralToken,
        address debtToken,
        uint256 errorCodeBreakpoint
    ) external returns (
        uint256 collateralSharesPrice,
        uint256 debtUnderlyingPrice
    ) {
        if (!_isSequencerValid()) {
            revert OracleManager__ErrorCodeFlagged();
        }

        uint256 errorCode;
        address underlying = cTokens[collateralToken];
        if (underlying == address(0)) {
            revert OracleManager__NotSupported();
        }

        (collateralSharesPrice, errorCode) = _getPrice(
            underlying,
            true,
            true
        );

        if (errorCode >= errorCodeBreakpoint) {
            revert OracleManager__ErrorCodeFlagged();
        }
        collateralSharesPrice = FixedPointMathLib.mulDiv(
            collateralSharesPrice,
            ICToken(collateralToken).exchangeRateUpdated(),
            WAD
        );

        underlying = cTokens[debtToken];
        if (underlying == address(0)) {
            revert OracleManager__NotSupported();
        }

        (debtUnderlyingPrice, errorCode) = _getPrice(
            underlying,
            true,
            false
        );
        if (errorCode >= errorCodeBreakpoint) {
            revert OracleManager__ErrorCodeFlagged();
        }
    }

    /// @notice Retrieves the prices and account data of multiple assets
    ///         inside a Curvance Market.
    /// @dev If the asset is being used as collateral the users liquidity is
    ///      priced in shares, if theyre borrowing the outstanding debt is
    ///      measured in assets (underlying).
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
    ) external returns (
        AccountSnapshot[] memory,
        uint256[] memory,
        uint256
    ) {
        if (!_isSequencerValid()) {
            revert OracleManager__ErrorCodeFlagged();
        }

        uint256 numAssets = assets.length;
        AccountSnapshot[] memory snapshots = new AccountSnapshot[](numAssets);
        uint256[] memory prices = new uint256[](numAssets);
        uint256 errorCode;

        address asset;
        for (uint256 i; i < numAssets; ++i) {
            asset = assets[i];
            snapshots[i] = ICToken(asset).getSnapshotUpdated(account);

            if (snapshots[i].isCollateral) {
                // If the asset is being used as collateral the users liquidity is
                // priced in shares using _getPrice multiplied by exchange rate.
                (prices[i], errorCode) = _getPrice(
                    snapshots[i].underlying,
                    true,
                    true
                );
                // `getSnapshotUpdated` already accrues any pending assets so
                // we can call `exchangeRate` directly.
                prices[i] = FixedPointMathLib.mulDiv(
                    prices[i],
                    ICToken(asset).exchangeRate(),
                    WAD
                );
            } else {
                // If the asset is being borrowed the outstanding debt is
                // measured in assets (underlying) using _getPrice.
                (prices[i], errorCode) = _getPrice(
                    snapshots[i].underlying,
                    true,
                    false
                );
            }

            if (errorCode >= errorCodeBreakpoint) {
                revert OracleManager__ErrorCodeFlagged();
            }
        }

        return (snapshots, prices, numAssets);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Retrieves the price of a specified asset from either single
    ///         or dual oracles.
    /// @dev If the asset has one oracle, it fetches the price from a single
    ///      feed.
    ///      If it has two or more oracles, it fetches the price from both
    ///      feeds.
    /// @param asset The address of the asset to retrieve the price for.
    /// @param inUSD Specifies whether the price format should be in
    ///              USD (true) or a chain's native token (false).
    /// @param getLower Whether the lower or higher price should be returned
    ///                 if two feeds are available.
    /// @return price The current price of `asset`.
    /// @return errorCode An error code related to fetching the price:
    ///                   '0' indicates no error fetching price.
    ///                   '1' indicates that price should be taken with
    ///                   caution.
    ///                   '2' indicates a complete failure in receiving
    ///                   a price.
    function _getPrice(
        address asset,
        bool inUSD,
        bool getLower
    ) internal view returns (uint256 price, uint256 errorCode) {
        if (asset == address(0)) {
            revert OracleManager__NotSupported();
        }

        PricingConfig memory config = assetPricingConfig[asset];
        uint256 numAdaptors = config.adaptors.length;
        if (numAdaptors == 0) {
            revert OracleManager__NotSupported();
        }

        // Get price from a single adaptor source or dual adaptor source.
        if (numAdaptors > 1) {
            (price, errorCode) =
                _getPriceDualAdaptor(asset, config, inUSD, getLower);
        } else {
            bool hadError;
            (price, hadError) =
                _getPriceFromAdaptor(asset, config.adaptors[0], inUSD, getLower);
            if (hadError) {
                errorCode = BAD_SOURCE;
            }
        }

        // If somehow an adaptor returns a price of 0, make sure a BAD_SOURCE
        // flag is bubbled up.
        if (price == 0 && errorCode < BAD_SOURCE) {
            errorCode = BAD_SOURCE;
        }
    }

    /// @notice Adds a new dependency for pricing `asset` on `adaptor`. If
    ///         this is the second adaptor dependency, set deviation values
    ///         too, validating they are safe based on adaptor's price feed
    ///         deviation threshold.
    /// @dev Requires that `adaptor` is an approved adaptor, and that `asset`
    ///      does not already have two adaptor dependencies.
    /// @param asset The address of the asset to add a new pricing adaptor
    ///              dependency for.
    /// @param adaptor The address of the new adaptor to add dependency to.
    function _addAssetPricingAdaptor(address asset, address adaptor) internal {
        // Validate that `adaptor` is approved for pricing usage.
        _checkIsApprovedAdaptor(adaptor);

        // Validate that the adaptor supports pricing `asset`.
        if (!IOracleAdaptor(adaptor).isSupportedAsset(asset)) {
            revert OracleManager__InvalidParameter();
        }

        address[] storage adaptors = assetPricingConfig[asset].adaptors;
        uint256 numAdaptors = adaptors.length;

        // Validate that we do not already have 2 pricing adaptors configured
        // for `asset`.
        if (numAdaptors > 1) {
            revert OracleManager__InvalidParameter();
        }

        // If there is already an adaptor dependency for `asset` make sure
        // that it is not `adaptor`, which would duplicate the dependency.
        // Validate that the adaptor proposed is not a duplicate of the
        // current adaptor of a supported feed for `asset`.
        if (numAdaptors != 0 && adaptors[0] == adaptor) {
            revert OracleManager__InvalidParameter();
        }

        // Validate that the adaptor returns an acceptable price for `asset`
        // by sampling a price call with `getLower` = true.
        IOracleAdaptor.PricingResult memory result = IOracleAdaptor(adaptor)
            .getPrice(asset, true, true);

        if (result.price == 0 || result.hadError) {
            revert OracleManager__InvalidParameter();
        }

        // Validate that the adaptor returns an acceptable price for `asset`
        // by sampling a price call with `getLower` = false.
        result = IOracleAdaptor(adaptor).getPrice(asset, true, false);

        if (result.price == 0 || result.hadError) {
            revert OracleManager__InvalidParameter();
        }

        adaptors.push(adaptor);
        emit AdaptorDependencyAdded(asset, adaptor);
    }

    /// @notice Removes the dependency on pricing from `adaptor` for `asset`.
    /// @dev Requires that `adaptor` is currently being used for pricing
    ///      `asset`.
    ///      NOTE: This intentionally does not modify asset deviation values
    ///            because they simply wont be used if there are less than two
    ///            pricing adaptors in use, so no reason to delete data as
    ///            when a second pricing adaptor is configured the deviation
    ///            has the opportunity be to reconfigured anyway.
    /// @param asset The address of the asset to remove pricing adaptor
    ///              dependency from.
    /// @param adaptor The address of the adaptor to remove dependency from.
    function _removeAssetPricingAdaptor(
        address asset,
        address adaptor
    ) internal {
        // If theres two adaptor dependencies, figure out which to remove,
        // otherwise we know the adaptor to remove is the first entry.
        address[] storage adaptors = assetPricingConfig[asset].adaptors;
        uint256 numAdaptors = adaptors.length;
        if (numAdaptors == 0) {
            revert OracleManager__NotSupported();
        }

        if (numAdaptors > 1) {
            // Check whether `adaptor` is a currently dependency for pricing
            // `asset`.
            if (adaptors[0] != adaptor && adaptors[1] != adaptor) {
                revert OracleManager__NotSupported();
            }

            // We want to remove the first adaptor dependency of the two,
            // so move the second adaptor dependency to slot one.
            if (adaptors[0] == adaptor) {
                adaptors[0] = adaptors[1];
            }
        } else {
            if (adaptors[0] != adaptor) {
                revert OracleManager__NotSupported();
            }
        }
        // We know the adaptor exists, but we cannot use `isApprovedAdaptor`
        // as we could have removed it as an approved adaptor prior to this
        // function call.
        adaptors.pop();
        emit AdaptorDependencyRemoved(asset, adaptor);
    }

    /// @notice Retrieves the price of a specified asset from two specific
    ///         price feeds.
    /// @dev If both price feeds return an error, it returns (0, BAD_SOURCE).
    ///      If one of the price feeds return an error, it returns the
    ///      price from the working feed along with a CAUTION flag.
    ///      Otherwise, it returns (price, NO_ERROR).
    /// @param asset The address of the asset to retrieve the price for.
    /// @param config The current pricing configuration of `asset`.
    /// @param inUSD Specifies whether the price format should be in
    ///              USD (true) or a chain's native token (false).
    /// @param getLower Whether the lower or higher price should be returned
    ///                 if two feeds are available.
    /// @return uint256 The current price of `asset`.
    /// @return bool An error flag (if any).
    function _getPriceDualAdaptor(
        address asset,
        PricingConfig memory config,
        bool inUSD,
        bool getLower
    ) internal view returns (uint256, uint256) {
        (uint256 price0, bool error0) = _getPriceFromAdaptor(
            asset, config.adaptors[0], inUSD, getLower
        );
        (uint256 price1, bool error1)= _getPriceFromAdaptor(
            asset, config.adaptors[1], inUSD, getLower
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
            // called that one but not both adaptors have an error. So, if
            // adaptor0 had the error, adaptor1 is usable, and vice versa.
            if (error0) {
                return (price1, CAUTION);
            }

            return (price0, CAUTION);
        }

        uint256 badSourceBound = inUSD ?
            config.badSourceBoundUSD : config.badSourceBoundNative;
        uint256 cautionBound = inUSD ?
            config.cautionBoundUSD : config.cautionBoundNative;

        uint256 errorCode =
            _checkBounds(price0, price1, badSourceBound, cautionBound);
        if (getLower) {
            return (price1 < price0 ? price1 : price0, errorCode);
        }

        return (price1 > price0 ? price1 : price0, errorCode);
    }

    /// @notice Retrieves the price of `asset` from `adaptor`.
    /// @dev Converts the price received to `inUSD` if necessary.
    /// @param asset The address of the asset to retrieve the price for.
    /// @param adaptor The address of the pricing adaptor to use for pricing
    ///                `asset`.
    /// @param inUSD Specifies whether the price format should be in
    ///              USD (true) or a chain's native token (false).
    /// @param getLower Whether the lower or higher price should be returned
    ///                 if there are two adaptor dependencies.
    /// @return uint256 The current price of `asset`.
    /// @return bool Whether the adaptor ran into an error when pricing.
    function _getPriceFromAdaptor(
        address asset,
        address adaptor,
        bool inUSD,
        bool getLower
    ) internal view returns (uint256, bool) {
        _checkIsApprovedAdaptor(adaptor);

        IOracleAdaptor.PricingResult memory result = IOracleAdaptor(adaptor)
            .getPrice(asset, inUSD, getLower);

        // If we had an error pricing the asset, bubble up we had a error.
        if (result.hadError) {
            return (0, true);
        }

        // If the adaptor's price denomination is not in the proper form,
        // modify it.
        if (result.inUSD != inUSD) {
            uint256 newPrice;
            (newPrice, result.hadError) =
                _getNativeUSD(inUSD ? getLower : !getLower);
            if (result.hadError) {
                return (0, true);
            }

            return (
                _convertNativeUSD(result.price, newPrice, result.inUSD, getLower),
                result.hadError
            );
        }

        return (result.price, result.hadError);
    }

    /// @notice Queries the current price of a chain's native token in USD
    ///         using the Oracle Manager.
    /// @dev The price is deemed valid if the data from the Oracle Manager
    ///      is fresh and a positive value.
    /// @param getLower Whether the lower or higher price should be returned
    ///                 if there are two adaptor dependencies.
    /// @return price The current price of `native`.
    /// @return hadError Whether the adaptor ran into an error when pricing
    ///                  `native`.
    function _getNativeUSD(
        bool getLower
    ) internal view returns (uint256 price, bool hadError) {
        uint256 errorCode;
        (price, errorCode) = _getPrice(native, true, getLower);

        // If there was any error while querying native token price,
        // bubble up an error.
        hadError = errorCode != NO_ERROR;
    }

    /// @notice Check whether a sequencer is valid or down.
    /// @return True if sequencer is valid.
    function _isSequencerValid() internal view returns (bool) {
        address sequencerUptimeFeed = centralRegistry.SEQUENCER_ORACLE();

        if (sequencerUptimeFeed != address(0)) {
            (, int256 answer, uint256 startedAt, , ) =
                IChainlink(sequencerUptimeFeed).latestRoundData();

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
    /// @param getLower Whether the lower or higher price should be returned.
    /// @return The converted price.
    function _convertNativeUSD(
        uint256 currentPrice,
        uint256 conversionRate,
        bool currentlyInUSD,
        bool getLower
    ) internal pure returns (uint256) {
        if (!currentlyInUSD) {
            // The price denomination is in native token and we want USD.
            if (getLower) {
                return FixedPointMathLib.mulDiv(currentPrice, conversionRate, WAD);
            }

            return FixedPointMathLib.mulDivUp(currentPrice, conversionRate, WAD);
        }

        // The price denomination is in USD and we want native token.
        if (getLower) {
            return FixedPointMathLib.mulDiv(currentPrice, WAD, conversionRate);
        }
        
        return FixedPointMathLib.mulDivUp(currentPrice, WAD, conversionRate);
    }

    /// @notice Sets a new maximum deviation for pricing adaptors before
    ///         CAUTION or BAD_SOURCE error codes are activated for `asset`.
    /// @dev Only allowed if there are two adaptor dependencies configured
    ///      already.
    /// @param asset The address of the asset to set pricing deviation values
    ///              for.
    /// @param inUSD Whether the deviation bounds for `asset` is for
    ///              pricing in USD (inUSD = true) or native
    ///              token (inUSD = false).
    /// @param badSourceBound The new maximum price deviation before a
    ///                     `BAD_SOURCE` error code is returned.
    /// @param cautionBound The new maximum price deviation before a
    ///                   `CAUTION` error code is returned.
    function _setDeviationBounds(
        address asset,
        PricingConfig storage config,
        bool inUSD,
        uint256 badSourceBound,
        uint256 cautionBound
    ) internal {
        // Validate that the `CAUTION` error code will not trigger too
        // closely to `BAD_SOURCE` error code, because `BAD_SOURCE` is
        // a more significant error than `CAUTION`.
        if (badSourceBound < cautionBound + MIN_CAUTION_TO_BAD_SOURCE_DELTA) {
            revert OracleManager__InvalidParameter();
        }

        // Validate bound values are within acceptable value range.
        if (
            cautionBound < MIN_DEVIATION_BOUND ||
            badSourceBound > MAX_DEVIATION_BOUND
        ) {
            revert OracleManager__InvalidParameter();
        }

        // Add `BPS` to the value to save converting to a BPS premium
        // e.g. 10200 for 2% at runtime.
        badSourceBound = badSourceBound + BPS;
        cautionBound = cautionBound + BPS;
        if (inUSD) {
            config.badSourceBoundUSD = uint16(badSourceBound);
            config.cautionBoundUSD = uint16(cautionBound);
        } else {
            config.badSourceBoundNative = uint16(badSourceBound);
            config.cautionBoundNative = uint16(cautionBound);
        }
        
        emit AssetDeviationBoundsSet(asset, badSourceBound, cautionBound);
    }

    /// @notice Reviews the report prices from both pricing adaptors,
    ///         returning an appropriate error code if the deviation between
    ///         prices is significant enough.
    /// @dev If the deviation is less than `cautionBound`, returns `NO_ERROR`.
    ///      If the deviation is more than `cautionBound` but less than
    ///      `badSourceBound`, returns `CAUTION`.
    ///      If the deviation is more than `badSourceBound`, returns
    ///      `BAD_SOURCE`.
    /// @param a The price reported by the first adaptor.
    /// @param b The price reported by the second adaptor.
    /// @param badSourceBound The bound value where deviation in price
    ///                       between `a` and `b` should return the
    ///                       `BAD_SOURCE` error code.
    /// @param cautionBound The bound value where deviation in price between
    ///                     `a` and `b` should return the `CAUTION` error
    ///                     code.
    /// @return Returns the appropriate error code depending on deviation
    ///         between adaptor's reported prices.
    function _checkBounds(
        uint256 a,
        uint256 b,
        uint256 badSourceBound,
        uint256 cautionBound
    ) internal pure returns (uint256) {
        if (a <= b) {
            // Check if both adaptor are within `cautionBound` of each other.
            if (((a * cautionBound) / BPS) < b) {
                // Notify that the price is dangerous and to treat data as
                // invalid because we are outside the accepted range of
                // deviation.
                if (((a * badSourceBound) / BPS) < b) {
                    return BAD_SOURCE;
                }

                // Notify that the price should be taken with caution because
                // we are outside the accepted range of deviation.
                return CAUTION;
            }

            return NO_ERROR;
        }

        // Check if both feeds are within `cautionBound` of each other.
        if (((b * cautionBound) / BPS) < a) {
            // Notify that the price is dangerous and to treat data as invalid
            // because we are outside the accepted range of deviation.
            if (((b * badSourceBound) / BPS) < a) {
                return BAD_SOURCE;
            }

            // Notify that the price should be taken with caution because
            // we are outside the accepted range of deviation.
            return CAUTION;
        }

        return NO_ERROR;
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