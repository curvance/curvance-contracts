// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { Multicall } from "contracts/libraries/Multicall.sol";

struct AccountSnapshot {
    address asset;
    bool isPToken;
    uint8 decimals;
    uint256 exchangeRate;
    uint256 collateralPosted;
    uint256 debtBalance;
}

interface IMToken {
    /// @notice Starts a mToken market, executed via marketManager.
    /// @dev This initial mint is a failsafe against rounding exploits,
    ///      although, we protect against them in many ways,
    ///      better safe than sorry.
    /// @param by The account initializing the market.
    function startMarket(address by) external returns (bool);

    /// @notice Returns the address of the underlying asset.
    function asset() external view returns (address);

    /// @notice Returns the decimals of the mToken.
    /// @dev We pull directly from underlying incase its a proxy contract,
    ///      and changes decimals on us.
    /// @return The number of decimals for this mToken,
    ///         matching the underlying token.
    function decimals() external view returns (uint8);

    /// @notice Returns the type of Curvance token.
    /// @dev true = Collateral token; false = Debt token.
    /// @return Whether this token is a pToken or not.
    function isCollateralizable() external view returns (bool);

    /// @notice Returns whether the underlying token can be borrowed.
    /// @dev true = Borrowable; false = Not Borrowable.
    /// @return Whether this token is borrowable or not.
    function isBorrowable() external view returns (bool);

    /// @notice The eToken balance of an account.
    /// @dev Account address => account token balance.
    /// @param user User to query eToken balance for.
    function balanceOf(address user) external view returns (uint256);

    /// @notice Returns a snapshot of the pToken and `account` data.
    /// @dev Used by MarketManager to efficiently perform liquidity checks.
    /// @return Snapshot struct containing packed information.
    function getSnapshot(
        address account
    ) external view returns (AccountSnapshot memory);

    /// @notice Total number of mTokens in circulation.
    function totalSupply() external view returns (uint256);

    /// @notice Address of the Market Manager linked to this contract.
    function marketManager() external view returns (IMarketManager);

    /// @notice Returns the amount of assets that would be exchanged
    ///         by the vault for `shares` provided.
    /// @param shares The number of shares to theoretically use
    ///               for conversion to assets.
    /// @return The number of assets a user would receive for converting
    ///         `shares`.
    function convertToAssets(
        uint256 shares
    ) external view returns (uint256);

    /// @notice Returns share -> asset exchange rate, in `WAD`.
    /// @dev Oracle Manager calculates mToken value from this exchange rate.
    function exchangeRate() external view returns (uint256);

    function exchangeRateCached() external view returns (uint256);

    /// @notice Executes multiple calls in a single transaction.
    ///         This can be used to update oracle prices before
    ///         a liquidity dependent action.
    function multicall(
        Multicall.MulticallData[] memory calls
    ) external returns (bytes[] memory results);
}
