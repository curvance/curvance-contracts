// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { AccountSnapshot } from "contracts/interfaces/ICToken.sol";

interface IOracleManager {
    /// TYPES ///

    /// @notice Stored data to facilitate pricing Curvance tokens (cTokens).
    /// @param isCToken Used to indicate if the provided address is a
    ///                 Curvance token or not.
    /// @param underlying Address of the underlying asset for the Curvance
    ///                   token.
    struct CToken {
        bool isCToken;
        address underlying;
    }

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
    ) external view returns (uint256, uint256);

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
    )
        external
        view
        returns (AccountSnapshot[] memory, uint256[] memory, uint256);

    /// @notice Removes a price feed for a specific asset
    ///         triggered by an adaptors notification.
    /// @dev Requires that the feed exists for the asset.
    /// @param asset The address of the asset.
    function notifyFeedRemoval(address asset) external;

    /// @notice Returns the price feeds for `asset`.
    /// @param asset The address of the asset to get price feeds of.
    function getPriceFeeds(
        address asset
    ) external view returns(address[] memory);

    /// @notice Returns the token data of `cToken`.
    /// @param cToken The address of the cToken to get data of.
    function getCToken(address cToken) external view returns(CToken memory);

    /// @notice Address => Adaptor approval status.
    /// @param adaptor The address of the adaptor to check.
    /// @return True if the adaptor is supported, false otherwise.
    function isApprovedAdaptor(address adaptor) external view returns (bool);

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
