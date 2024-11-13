// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { EToken } from "contracts/market/token/EToken.sol";
import { BasePToken } from "contracts/market/token/BasePToken.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";

import { WAD } from "contracts/libraries/Constants.sol";
import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";

import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { IMToken } from "contracts/interfaces/IMToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";
import { IRewardManager } from "contracts/interfaces/IRewardManager.sol";
import { IVeCVE } from "contracts/interfaces/IVeCVE.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";

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
        uint256 shareAmount;
        uint256 collateralOrDebtAmount;
    }

    struct MarketAssetConfig {
        bool isListed;
        uint256 collRatio;
        uint256 collReqSoft;
        uint256 collReqHard;
        uint256 liqBaseIncentive;
        uint256 liqCurve;
        uint256 liqFee;
        uint256 baseCFactor;
        uint256 cFactorCurve;
    }

    struct MarketETokenData {
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
        uint256 sharePrice;
        uint256 tokenPrice;
        MarketAssetConfig config;
        AccountAssetPosition userTokenPosition;
    }

    struct MarketPTokenData {
        address assetAddress;
        address marketAddress;
        address underlyingAddress;
        uint256 underlyingBalance;
        string underlyingName;
        string underlyingSymbol;
        uint8 underlyingDecimal;
        uint256 totalPositionTokens;
        uint256 totalCollateralPosted;
        uint256 collateralCap;
        uint256 sharePrice;
        uint256 tokenPrice;
        MarketAssetConfig config;
        AccountAssetPosition userTokenPosition;
    }

    struct AllMarketData {
        MarketData marketData;
        MarketETokenData[] eTokenData;
        MarketPTokenData[] pTokenData;
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
        return centralRegistry.getMarketManagers();
    }

    /// EXTERNAL ACCOUNT-SPECIFIC FUNCTIONS ///

    /// EXTERNAL TOKEN-SPECIFIC FUNCTIONS ///

    /// @notice Returns if an account has an active position in `token`,
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
        bool isPToken = IMToken(token).isPToken();

        (hasPosition, balanceOf, collateralOrDebtAmount) = marketManager
            .tokenDataOf(account, token);
        collateralOrDebtAmount = isPToken
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

    /// Oracle Manager FUNCTIONS ///

    function getPrices(
        address[] calldata assets,
        bool[] calldata inUSD,
        bool[] calldata getLower
    ) external view returns (uint256[] memory, uint256[] memory) {
        return _getOracleManager().getPrices(assets, inUSD, getLower);
    }

    function hasRewards(address user) external view returns (bool) {
        return _getRewardManager().hasRewardsToClaim(user);
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
                MarketETokenData[] memory eTokenData,
                MarketPTokenData[] memory pTokenData
            ) = this.getMarketAssetData(markets[i], account);
            results[i] = AllMarketData(
                this.getMarketData(markets[i], account),
                eTokenData,
                pTokenData
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
        result.collateralPostedByUsd = getMarketCollateralPostedByUsd(market);
        result.tokensListed = getMarketAssets(market);

        if (result.lendingTVL > result.borrows) {
            result.borrowsAvailable = result.lendingTVL - result.borrows;
        } else {
            result.borrowsAvailable = 0;
        }
    }

    function getMarketAssetData(
        address market,
        address account
    )
        external
        view
        returns (MarketETokenData[] memory, MarketPTokenData[] memory)
    {
        MarketManager mm = MarketManager(market);
        address[] memory pTokens = getMarketCollateralAssets(market);
        uint256 numTokens = pTokens.length;
        MarketPTokenData[] memory pTokenMarketData = new MarketPTokenData[](
            numTokens
        );
        for (uint256 i; i < numTokens; i++) {
            BasePToken marketToken = BasePToken(pTokens[i]);
            IERC20 token = IERC20(marketToken.underlying());
            MarketPTokenData memory pTokenData;

            if (account != address(0)) {
                pTokenData.underlyingBalance = token.balanceOf(account);

                (
                    pTokenData.userTokenPosition.hasPosition,
                    pTokenData.userTokenPosition.shareAmount,
                    pTokenData.userTokenPosition.collateralOrDebtAmount
                ) = this.getAccountTokenData(account, pTokens[i]);

                pTokenData.userTokenPosition.tokenAmount = marketToken
                    .convertToAssets(pTokenData.userTokenPosition.shareAmount);
            }

            pTokenData.assetAddress = pTokens[i];
            pTokenData.marketAddress = market;
            pTokenData.underlyingAddress = address(token);
            pTokenData.underlyingName = token.name();
            pTokenData.underlyingSymbol = token.symbol();
            pTokenData.underlyingDecimal = token.decimals();
            pTokenData.totalPositionTokens =
                marketToken.totalSupply() -
                MARKET_ASSET_RESERVE;
            pTokenData.totalCollateralPosted = mm.collateralPosted(pTokens[i]);
            pTokenData.collateralCap = mm.collateralCaps(pTokens[i]);
            pTokenData.sharePrice = _getTokenPrice(pTokens[i], true);
            pTokenData.tokenPrice = _getTokenPrice(address(token), true);
            pTokenData.config = _getTokenConfig(pTokens[i], mm);

            pTokenMarketData[i] = pTokenData;
        }

        address[] memory eTokens = getMarketDebtAssets(market);
        numTokens = eTokens.length;
        MarketETokenData[] memory eTokenMarketData = new MarketETokenData[](
            numTokens
        );
        for (uint256 i = 0; i < numTokens; i++) {
            MarketETokenData memory eTokenData;
            EToken marketToken = EToken(eTokens[i]);
            IERC20 token = IERC20(marketToken.underlying());

            if (account != address(0)) {
                eTokenData.underlyingBalance = token.balanceOf(account);
                (
                    eTokenData.userTokenPosition.hasPosition,
                    eTokenData.userTokenPosition.shareAmount,
                    eTokenData.userTokenPosition.collateralOrDebtAmount
                ) = this.getAccountTokenData(account, eTokens[i]);

                eTokenData.userTokenPosition.tokenAmount = marketToken
                    .convertToAssets(eTokenData.userTokenPosition.shareAmount);
            }

            eTokenData.assetAddress = eTokens[i];
            eTokenData.marketAddress = market;
            eTokenData.underlyingAddress = address(token);
            eTokenData.underlyingName = token.name();
            eTokenData.underlyingSymbol = token.symbol();
            eTokenData.underlyingDecimal = token.decimals();
            eTokenData.tvl = this.getTokenTVL(eTokens[i], false);
            eTokenData.borrows = this.getTokenBorrows(eTokens[i]);
            eTokenData.supplyRatePerYear = this.getSupplyRatePerYear(
                eTokens[i]
            );
            eTokenData.borrowRatePerYear = this.getBorrowRatePerYear(
                eTokens[i]
            );
            eTokenData.predictedBorrowRatePerYear = this
                .getPredictedBorrowRatePerYear(eTokens[i]);
            eTokenData.utilizationRate = this.getUtilizationRate(eTokens[i]);
            eTokenData.sharePrice = _getTokenPrice(eTokens[i], false);
            eTokenData.tokenPrice = _getTokenPrice(address(token), false);
            eTokenData.config = _getTokenConfig(eTokens[i], mm);

            if (eTokenData.tvl > eTokenData.borrows) {
                eTokenData.liquidityAvailable =
                    eTokenData.tvl -
                    eTokenData.borrows;
            } else {
                eTokenData.liquidityAvailable = 0;
            }

            eTokenMarketData[i] = eTokenData;
        }

        return (eTokenMarketData, pTokenMarketData);
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
            getLower = IMToken(token).isPToken() ? true : false;
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
            if (IMToken(asset).isPToken()) {
                ++numCollateralAssets;
            }
        }

        address[] memory collateralAssets = new address[](numCollateralAssets);
        uint256 collateralAssetsIndex = 0;

        for (uint256 i; i < numAssets; ++i) {
            asset = assets[i];
            if (IMToken(asset).isPToken()) {
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
            if (!IMToken(asset).isPToken()) {
                ++numDebtAssets;
            }
        }

        address[] memory debtAssets = new address[](numDebtAssets);
        uint256 debtAssetsIndex = 0;

        for (uint256 i; i < numAssets; ++i) {
            asset = assets[i];
            if (!IMToken(asset).isPToken()) {
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

    /// @notice Returns the outstanding underlying tokens borrowed from a EToken market.
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
        return _getTokenPrice(token, IMToken(token).isPToken() ? true : false);
    }

    /// INTERNAL FUNCTIONS ///
    function _getTokenConfig(
        address token,
        MarketManager mm
    ) internal view returns (MarketAssetConfig memory) {
        MarketAssetConfig memory config;

        (
            bool isListed,
            uint256 collRatio,
            uint256 collReqSoft,
            uint256 collReqHard,
            uint256 liqBaseIncentive,
            uint256 liqCurve,
            uint256 liqFee,
            uint256 baseCFactor,
            uint256 cFactorCurve
        ) = mm.tokenData(token);

        config.isListed = isListed;
        config.collRatio = collRatio;
        config.collReqSoft = collReqSoft;
        config.collReqHard = collReqHard;
        config.liqBaseIncentive = liqBaseIncentive;
        config.liqCurve = liqCurve;
        config.liqFee = liqFee;
        config.baseCFactor = baseCFactor;
        config.cFactorCurve = cFactorCurve;

        return config;
    }

    function _getRewardManager() internal view returns (IRewardManager) {
        return IRewardManager(centralRegistry.rewardManager());
    }

    function _getOracleManager() internal view returns (IOracleManager) {
        return IOracleManager(centralRegistry.oracleManager());
    }

    function _getTokenPrice(
        address mToken,
        bool getLower
    ) internal view returns (uint256 price) {
        uint256 errorCode;
        (price, errorCode) = _getOracleManager().getPrice(
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
