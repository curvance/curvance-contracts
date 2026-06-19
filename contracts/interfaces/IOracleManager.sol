// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { AccountSnapshot } from "contracts/interfaces/ICToken.sol";

interface IOracleManager {
    /// @notice Retrieves the price of a specified asset from either single
    ///         or dual oracles.
    /// @dev If the asset has one oracle, it fetches the price from a single feed.
    ///      If it has two or more oracles, it fetches the price from both feeds.
    /// @param asset The address of the asset to retrieve the price for.
    /// @param inUSD Whether the price should be returned in USD or ETH.
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
    ) external view returns (uint256 price, uint256 errorCode);

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
    ) external returns (uint256, uint256);

    /// @notice Retrieves the prices and account data of multiple assets
    ///         inside a Curvance Market.
    /// @param account The account to retrieve data for.
    /// @param assets An array of asset addresses to retrieve the prices for.
    /// @param errorCodeBreakpoint The error code that will cause liquidity
    ///                            operations to revert.
    /// @dev Zero-collateral and zero-debt rows are returned without oracle
    ///      validation and keep their price entry at zero.
    /// @return AccountSnapshot[] Contains `assets` data for `account`
    /// @return uint256[] Contains prices for `assets`.
    /// @return uint256 The number of assets `account` is in.
    function getPricesForMarket(
        address account,
        address[] calldata assets,
        uint256 errorCodeBreakpoint
    )
        external
        returns (AccountSnapshot[] memory, uint256[] memory, uint256);

    /// @notice Potentially removes the dependency on pricing from `adaptor`
    ///         for `asset`, triggered by an adaptor's notification of a price
    ///         feed's removal.
    /// @notice Removes a pricing adaptor for `asset` triggered by an
    ///         adaptor's notification of a price feed's removal.
    /// @dev Requires that the adaptor is currently being used for pricing
    ///      for `asset`.
    ///      NOTE: This intentionally does not modify asset deviation values
    ///            because they simply wont be used if there are less than two
    ///            pricing adaptors in use, so no reason to delete data as
    ///            when a second pricing adaptor is configured the deviation
    ///            has the opportunity be to reconfigured anyway.
    /// @param asset The address of the asset to potentially remove the
    ///              pricing adaptor dependency from depending on current
    ///              `asset` configuration.
    function notifyFeedRemoval(address asset) external;

    /// @notice Returns the adaptors used for pricing `asset`.
    /// @param asset The address of the asset to get pricing adaptors for.
    /// @return The current adaptor(s) used for pricing `asset`.
    function getPricingAdaptors(
        address asset
    ) external view returns(address[] memory);

    /// @notice Address => Adaptor approval status.
    /// @param adaptor The address of the adaptor to check.
    /// @return True if the adaptor is supported, false otherwise.
    function isApprovedAdaptor(address adaptor) external view returns (bool);

    /// @notice Whether a token is recognized as a Curvance token or not,
    ///         if it is, will return its underlying asset address instead
    ///         of address (0).
    /// @return The cToken's underlying asset, or address(0) if not a cToken.
    function cTokens(address cToken) external view returns (address);

    /// @notice Checks if a given asset is supported by the Oracle Manager.
    /// @dev An asset is considered supported if it has one
    ///      or more associated price feeds.
    /// @param asset The address of the asset to check.
    /// @return True if the asset is supported, false otherwise.
    function isSupportedAsset(address asset) external view returns (bool);

    /// @notice Check whether L2 sequencer is valid or down.
    /// @return True if sequencer is valid.
    function isSequencerValid() external view returns (bool);
}