// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { CTokenCompounding } from "contracts/market/collateral/CTokenCompounding.sol";
import { DToken } from "contracts/market/collateral/DToken.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";

import { WAD, DENOMINATOR } from "contracts/libraries/Constants.sol";
import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";

import { IMarketManager } from "contracts/interfaces/market/IMarketManager.sol";
import { IMToken } from "contracts/interfaces/market/IMToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IGaugePool } from "contracts/interfaces/IGaugePool.sol";
import { IFeeAccumulator } from "contracts/interfaces/IFeeAccumulator.sol";
import { IOracleRouter } from "contracts/interfaces/IOracleRouter.sol";
import { ICVELocker } from "contracts/interfaces/ICVELocker.sol";
import { IVeCVE } from "contracts/interfaces/IVeCVE.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

import "forge-std/console.sol";

/// @notice An auxiliary contract for querying nuanced data
///         inside the Curvance ecosystem.
contract CurvanceAuxiliaryData {
    /// TYPES ///
    struct AccountMarketPosition {
        uint256 debt;
        uint256 collateral;
        uint256 maxDebt;
    }

    struct MarketData {
        address marketAddress;
        uint256 totalTVL;
        uint256 collateralTVL;
        uint256 lendingTVL;
        uint256 borrows;
        uint256 borrowsAvailable;
        uint256 collateralPostedByUsd;
        address[] tokensListed;
        AccountMarketPosition userMarketPosition;
    }

    struct AccountAssetPosition {
        bool hasPosition;
        uint256 tokenAmount;
        uint256 collateralOrDebtAmount;
    }

    struct MarketDTokenData {
        address assetAddress;
        address marketAddress;
        address underlyingAddress;
        uint256 underlyingBalance;
        string underlyingName;
        string underlyingSymbol;
        uint8 underlyingDecimal;
        uint256 tvl;
        uint256 borrows;
        uint256 supplyRatePerYear;
        uint256 borrowRatePerYear;
        uint256 predictedBorrowRatePerYear;
        uint256 utilizationRate;
        uint256 liquidityAvailable;
        uint256 price;
        AccountAssetPosition userTokenPosition;
    }

    struct MarketCTokenData {
        address assetAddress;
        address marketAddress;
        address underlyingAddress;
        uint256 underlyingBalance;
        string underlyingName;
        string underlyingSymbol;
        uint8 underlyingDecimal;
        uint256 totalCollateralTokens;
        uint256 totalCollateralPosted;
        uint256 collateralCap;
        uint256 price;
        AccountAssetPosition userTokenPosition;
    }

    struct AllMarketData {
        MarketData marketData;
        MarketDTokenData[] dTokenData;
        MarketCTokenData[] cTokenData;
    }

    /// CONSTANTS ///
    uint256 public constant MARKET_ASSET_RESERVE = 42069;

    /// STORAGE ///

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;

    /// ERRORS ///

    error CurvanceAuxiliaryData__ParametersMisconfigured();
    error CurvanceAuxiliaryData__InvalidCentralRegistry();
    error CurvanceAuxiliaryData__Unauthorized();

    /// CONSTRUCTOR ///

    constructor(ICentralRegistry centralRegistry_) {
        if (
            !ERC165Checker.supportsInterface(
                address(centralRegistry_),
                type(ICentralRegistry).interfaceId
            )
        ) {
            revert CurvanceAuxiliaryData__InvalidCentralRegistry();
        }

        centralRegistry = centralRegistry_;
    }

    /// EXTERNAL FUNCTIONS ///

    /// CHAIN-WIDE FUNCTIONS ///

    /// @notice Returns the current TVL inside Curvance.
    /// @return result The current TVL inside Curvance, in `WAD`.
    function getTotalTVL() external view returns (uint256 result) {
        address[] memory markets = this.getMarketManagers();
        uint256 numMarkets = markets.length;

        for (uint256 i; i < numMarkets; ) {
            result += getMarketTVL(markets[i++]);
        }
    }

    /// @notice Returns the current collateral TVL inside Curvance.
    /// @return result The current collateral TVL inside Curvance, in `WAD`.
    function getTotalCollateralTVL() external view returns (uint256 result) {
        address[] memory markets = this.getMarketManagers();
        uint256 numMarkets = markets.length;

        for (uint256 i; i < numMarkets; ) {
            result += getMarketCollateralTVL(markets[i++]);
        }
    }

    /// @notice Returns the current lending TVL inside Curvance.
    /// @return result The current lending TVL inside Curvance, in `WAD`.
    function getTotalLendingTVL() external view returns (uint256 result) {
        address[] memory markets = this.getMarketManagers();
        uint256 numMarkets = markets.length;

        for (uint256 i; i < numMarkets; ) {
            result += getMarketLendingTVL(markets[i++]);
        }
    }

    /// @notice Returns the current outstanding borrows inside Curvance.
    /// @return result The current outstanding borrows inside Curvance, in `WAD`.
    function getTotalBorrows() external view returns (uint256 result) {
        address[] memory markets = this.getMarketManagers();
        uint256 numMarkets = markets.length;

        for (uint256 i; i < numMarkets; ) {
            result += getMarketBorrows(markets[i++]);
        }
    }

    function getMarketManagers() external view returns (address[] memory) {
        return centralRegistry.queryMarketManagers();
    }

    /// EXTERNAL ACCOUNT-SPECIFIC FUNCTIONS ///

    /// EXTERNAL TOKEN-SPECIFIC FUNCTIONS ///

    /// @notice Returns if an account has an active position in `token`,
    ///         and any user balances or collateral posted in `token`.
    /// @param account The address of the account to check token data of.
    /// @param token The address of the market token.
    function getAccountTokenData(
        address account,
        address token
    )
        external
        view
        returns (
            bool hasPosition,
            uint256 balanceOf,
            uint256 collateralOrDebtAmount
        )
    {
        IMarketManager marketManager = IMarketManager(
            IMToken(token).marketManager()
        );
        bool isCToken = IMToken(token).isCToken();

        (hasPosition, balanceOf, collateralOrDebtAmount) = marketManager
            .tokenDataOf(account, token);
        collateralOrDebtAmount = isCToken
            ? collateralOrDebtAmount
            : IMToken(token).debtBalanceCached(account);
    }

    /// @notice Return the debt balance of `account` based on stored data.
    /// @param account The address whose debt balance should be calculated.
    /// @return `account`'s cached balance index for `token`.
    function getAccountDebtData(
        address account,
        address token
    ) external view returns (uint256) {
        return IMToken(token).debtBalanceCached(account);
    }

    /// @notice Calculates `token` utilization rate.
    /// @return The utilization rate, in `WAD`.
    function getUtilizationRate(
        address token
    ) external view returns (uint256) {
        return IMToken(token).utilizationRate();
    }

    /// @notice Returns `token` borrow interest rate per year.
    /// @return The borrow interest rate per year, in `WAD`.
    function getBorrowRatePerYear(
        address token
    ) external view returns (uint256) {
        return IMToken(token).borrowRatePerYear();
    }

    /// @notice Returns `token` borrow interest rate per year.
    /// @return The borrow interest rate per year, in `WAD`.
    function getPredictedBorrowRatePerYear(
        address token
    ) external view returns (uint256) {
        return IMToken(token).predictedBorrowRatePerYear();
    }

    /// @notice Returns `token` supply interest rate per year.
    /// @return The supply interest rate per year, in `WAD`.
    function getSupplyRatePerYear(
        address token
    ) external view returns (uint256) {
        return IMToken(token).supplyRatePerYear();
    }

    function getBaseRewards(address token) external view returns (uint256) {}

    function getCVERewards(address token) external view returns (uint256) {}

    /// ORACLE ROUTER FUNCTIONS ///

    function getPrices(
        address[] calldata assets,
        bool[] calldata inUSD,
        bool[] calldata getLower
    ) external view returns (uint256[] memory, uint256[] memory) {
        return _getOracleRouter().getPrices(assets, inUSD, getLower);
    }

    function hasRewards(address user) external view returns (bool) {
        return _getCVELocker().hasRewardsToClaim(user);
    }

    /// PUBLIC FUNCTIONS ///

    /// MARKET-SPECIFIC FUNCTIONS ///
    function getAllMarketData(
        address account
    ) external view returns (AllMarketData[] memory) {
        address[] memory markets = this.getMarketManagers();
        uint256 numMarkets = markets.length;
        AllMarketData[] memory results = new AllMarketData[](numMarkets);

        for (uint256 i; i < numMarkets; i++) {
            (
                MarketDTokenData[] memory dTokenData,
                MarketCTokenData[] memory cTokenData
            ) = this.getMarketAssetData(markets[i], account);
            results[i] = AllMarketData(
                this.getMarketData(markets[i], account),
                dTokenData,
                cTokenData
            );
        }

        return results;
    }

    function getMarketData(
        address market,
        address account
    ) external view returns (MarketData memory result) {
        if (account != address(0)) {
            try MarketManager(market).statusOf(account) returns (
                uint256 collateral,
                uint256 maxDebt,
                uint256 debt
            ) {
                result.userMarketPosition.collateral = collateral;
                result.userMarketPosition.maxDebt = maxDebt;
                result.userMarketPosition.debt = debt;
            } catch {}
        }

        result.marketAddress = market;
        result.totalTVL = getMarketTVL(market);
        result.collateralTVL = getMarketCollateralTVL(market);
        result.lendingTVL = getMarketLendingTVL(market);
        result.borrows = getMarketBorrows(market);
        result.borrowsAvailable = result.lendingTVL - result.borrows;
        result.collateralPostedByUsd = getMarketCollateralPostedByUsd(market);
        result.tokensListed = getMarketAssets(market);
    }

    function getMarketAssetData(
        address market,
        address account
    )
        external
        view
        returns (MarketDTokenData[] memory, MarketCTokenData[] memory)
    {
        address[] memory cTokens = getMarketCollateralAssets(market);
        MarketCTokenData[] memory cResults = new MarketCTokenData[](
            cTokens.length
        );
        for (uint256 i = 0; i < cTokens.length; i++) {
            IERC20 token = IERC20(IMToken(cTokens[i]).underlying());
            MarketCTokenData memory cTokenData;

            if (account != address(0)) {
                cTokenData.underlyingBalance = token.balanceOf(account);

                (
                    cTokenData.userTokenPosition.hasPosition,
                    cTokenData.userTokenPosition.tokenAmount,
                    cTokenData.userTokenPosition.collateralOrDebtAmount
                ) = this.getAccountTokenData(account, cTokens[i]);
            }

            cTokenData.assetAddress = cTokens[i];
            cTokenData.marketAddress = market;
            cTokenData.underlyingAddress = address(token);
            cTokenData.underlyingName = token.name();
            cTokenData.underlyingSymbol = token.symbol();
            cTokenData.underlyingDecimal = token.decimals();
            cTokenData.totalCollateralTokens =
                IMToken(cTokens[i]).totalSupply() -
                MARKET_ASSET_RESERVE;
            cTokenData.totalCollateralPosted = MarketManager(market)
                .collateralPosted(cTokens[i]);
            cTokenData.collateralCap = MarketManager(market).collateralCaps(
                cTokens[i]
            );
            cTokenData.price = _getTokenPrice(cTokens[i], true);

            cResults[i] = cTokenData;
        }

        address[] memory dTokens = getMarketDebtAssets(market);
        MarketDTokenData[] memory dResults = new MarketDTokenData[](
            dTokens.length
        );
        for (uint256 i = 0; i < dTokens.length; i++) {
            IERC20 token = IERC20(IMToken(dTokens[i]).underlying());
            MarketDTokenData memory dTokenData;

            if (account != address(0)) {
                dTokenData.underlyingBalance = token.balanceOf(account);
                (
                    dTokenData.userTokenPosition.hasPosition,
                    dTokenData.userTokenPosition.tokenAmount,
                    dTokenData.userTokenPosition.collateralOrDebtAmount
                ) = this.getAccountTokenData(account, dTokens[i]);
            }

            dTokenData.assetAddress = dTokens[i];
            dTokenData.marketAddress = market;
            dTokenData.underlyingAddress = address(token);
            dTokenData.underlyingName = token.name();
            dTokenData.underlyingSymbol = token.symbol();
            dTokenData.underlyingDecimal = token.decimals();
            dTokenData.tvl = this.getTokenTVL(dTokens[i], false);
            dTokenData.borrows = this.getTokenBorrows(dTokens[i]);
            dTokenData.supplyRatePerYear = this.getSupplyRatePerYear(
                dTokens[i]
            );
            dTokenData.borrowRatePerYear = this.getBorrowRatePerYear(
                dTokens[i]
            );
            dTokenData.predictedBorrowRatePerYear = this
                .getPredictedBorrowRatePerYear(dTokens[i]);
            dTokenData.utilizationRate = this.getUtilizationRate(dTokens[i]);
            dTokenData.liquidityAvailable =
                dTokenData.tvl -
                dTokenData.borrows;
            dTokenData.price = _getTokenPrice(dTokens[i], false);

            dResults[i] = dTokenData;
        }

        return (dResults, cResults);
    }

    /// @notice Returns the current TVL inside a Curvance market.
    /// @param market The market to query TVL for.
    /// @return result The current TVL inside `market`, in `WAD`.
    function getMarketTVL(
        address market
    ) public view returns (uint256 result) {
        address[] memory assets = getMarketAssets(market);
        uint256 numAssets = assets.length;
        address token;
        bool getLower;

        for (uint256 i; i < numAssets; ) {
            token = assets[i++];
            getLower = IMToken(token).isCToken() ? true : false;
            result += getTokenTVL(token, getLower);
        }
    }

    /// @notice Returns the current collateral TVL inside a Curvance market.
    /// @param market The market to query collateral TVL for.
    /// @return result The current collateral TVL inside `market`, in `WAD`.
    function getMarketCollateralTVL(
        address market
    ) public view returns (uint256 result) {
        address[] memory assets = getMarketCollateralAssets(market);
        uint256 numAssets = assets.length;

        for (uint256 i; i < numAssets; ) {
            result += getTokenTVL(assets[i++], true);
        }
    }

    function getMarketCollateralPostedByUsd(
        address market
    ) public view returns (uint256 result) {
        address[] memory assets = getMarketCollateralAssets(market);
        uint256 numAssets = assets.length;

        for (uint256 i; i < numAssets; ) {
            address assetAddress = assets[i++];
            uint256 price = _getTokenPrice(assetAddress, true);
            result +=
                (price *
                    MarketManager(market).collateralPosted(assetAddress)) /
                10 ** IMToken(assetAddress).decimals();
        }
    }

    /// @notice Returns the current lending TVL inside a Curvance market.
    /// @param market The market to query lending TVL for.
    /// @return result The current lending TVL inside `market`, in `WAD`.
    function getMarketLendingTVL(
        address market
    ) public view returns (uint256 result) {
        address[] memory assets = getMarketDebtAssets(market);
        uint256 numAssets = assets.length;

        for (uint256 i; i < numAssets; ) {
            result += getTokenTVL(assets[i++], false);
        }
    }

    /// @notice Returns the current outstanding borrows inside a Curvance market.
    /// @param market The market to query outstanding borrows for.
    /// @return result The current outstanding borrows inside `market`, in `WAD`.
    function getMarketBorrows(
        address market
    ) public view returns (uint256 result) {
        address[] memory assets = getMarketDebtAssets(market);
        uint256 numAssets = assets.length;

        for (uint256 i; i < numAssets; ) {
            result += getTokenBorrows(assets[i++]);
        }
    }

    /// @notice Returns listed collateral assets inside `market`.
    /// @return The listed collateral assets.
    function getMarketCollateralAssets(
        address market
    ) public view returns (address[] memory) {
        address[] memory assets = getMarketAssets(market);
        uint256 numAssets = assets.length;

        address asset;
        uint256 numCollateralAssets;

        for (uint256 i; i < numAssets; ++i) {
            asset = assets[i];
            if (IMToken(asset).isCToken()) {
                ++numCollateralAssets;
            }
        }

        address[] memory collateralAssets = new address[](numCollateralAssets);
        uint256 collateralAssetsIndex = 0;

        for (uint256 i; i < numAssets; ++i) {
            asset = assets[i];
            if (IMToken(asset).isCToken()) {
                collateralAssets[collateralAssetsIndex++] = asset;
            }
        }

        return collateralAssets;
    }

    /// @notice Returns listed debt assets inside `market`.
    /// @return The listed debt assets.
    function getMarketDebtAssets(
        address market
    ) public view returns (address[] memory) {
        address[] memory assets = getMarketAssets(market);
        uint256 numAssets = assets.length;

        address asset;
        uint256 numDebtAssets;

        for (uint256 i; i < numAssets; ++i) {
            asset = assets[i];
            if (!IMToken(asset).isCToken()) {
                ++numDebtAssets;
            }
        }

        address[] memory debtAssets = new address[](numDebtAssets);
        uint256 debtAssetsIndex = 0;

        for (uint256 i; i < numAssets; ++i) {
            asset = assets[i];
            if (!IMToken(asset).isCToken()) {
                debtAssets[debtAssetsIndex++] = asset;
            }
        }

        return debtAssets;
    }

    /// @notice Returns all listed market assets inside `market`.
    /// @return The listed market assets.
    function getMarketAssets(
        address market
    ) public view returns (address[] memory) {
        return IMarketManager(market).queryTokensListed();
    }

    /// PUBLIC ACCOUNT-SPECIFIC FUNCTIONS ///

    function getUserLocks(
        address account
    ) public view returns (uint256[] memory, uint256[] memory) {
        return IVeCVE(centralRegistry.veCVE()).queryUserLocks(account);
    }

    function getUserLockLength(address account) public view returns (uint256) {
        (uint256[] memory lockAmounts, ) = getUserLocks(account);
        return lockAmounts.length;
    }

    function getUserLockIndexExists(
        address account,
        uint256 lockIndex
    ) public view returns (bool) {
        return lockIndex >= getUserLockLength(account);
    }

    /// PUBLIC TOKEN-SPECIFIC FUNCTIONS ///

    /// @notice Returns the current TVL inside an MToken token.
    /// @param token The token to query TVL for.
    /// @return result The current TVL inside `token`, in `WAD`.
    function getTokenTVL(
        address token,
        bool getLower
    ) public view returns (uint256 result) {
        // Get current shares total supply then query price and return.
        result =
            (_getTokenPrice(token, getLower) *
                (IMToken(token).totalSupply() - MARKET_ASSET_RESERVE)) /
            10 ** IMToken(token).decimals();
    }

    /// @notice Returns the outstanding underlying tokens borrowed from a DToken market.
    /// @param token The token to query outstanding borrows for.
    /// @return result The outstanding underlying tokens, in `WAD`.
    function getTokenBorrows(
        address token
    ) public view returns (uint256 result) {
        IMToken mToken = IMToken(token);

        // Get outstanding borrows then query price and return.
        result =
            (_getTokenPrice(mToken.underlying(), false) *
                mToken.totalBorrows()) /
            10 ** mToken.decimals();
    }

    function getTokenPrice(address token) public view returns (uint256) {
        return _getTokenPrice(token, IMToken(token).isCToken() ? true : false);
    }

    /// INTERNAL FUNCTIONS ///

    function _getCVELocker() internal view returns (ICVELocker) {
        return ICVELocker(centralRegistry.cveLocker());
    }

    function _getOracleRouter() internal view returns (IOracleRouter) {
        return IOracleRouter(centralRegistry.oracleRouter());
    }

    function _getTokenPrice(
        address mToken,
        bool getLower
    ) internal view returns (uint256 price) {
        uint256 errorCode;
        (price, errorCode) = _getOracleRouter().getPrice(
            mToken,
            true,
            getLower
        );
        // If we could not price the asset, bubble up a price of 0.
        if (errorCode == 2) {
            price = 0;
            return price;
        }
    }
}
