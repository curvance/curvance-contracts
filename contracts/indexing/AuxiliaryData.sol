// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { WAD } from "contracts/libraries/Constants.sol";
import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";

import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { ILiquidityManager } from "contracts/interfaces/ILiquidityManager.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";
import { IRewardManager } from "contracts/interfaces/IRewardManager.sol";
import { IVeCVE } from "contracts/interfaces/IVeCVE.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

/// @title Curvance Auxiliary Data.
/// @notice An auxiliary contract for querying nuanced data
///         inside the Curvance ecosystem.
/// @dev The Curvance Auxiliary Data contract aims to be an all in one
///      interface for pulling data related to Curvance Protocol. The
///      secondary benefit is to minimize external RPC calls to pull said
///      data, by compressing multiple variable calls together this reduces
///      the number of EVM instances needed to perform the desired view
///      call(s). Because this auxiliary contract is all view functions
///      with no active storage values new versions can be deployed at any
///      time, to support new query or data formats.
contract AuxiliaryData {
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
        uint256 baseCFactor;
        uint256 cFactorCurve;
    }

    struct MarketBorrowableCTokens {
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
        uint256[2] adaptorTypes;
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
        uint256 sharePrice;
        uint256 tokenPrice;
        MarketAssetConfig config;
        AccountAssetPosition userTokenPosition;
        uint256[2] adaptorTypes;
    }

    struct AllMarketData {
        MarketData marketData;
        MarketBorrowableCTokens[] eTokenData;
        MarketCTokenData[] cTokenData;
    }

    struct LookupAccountState {
        address account;
        address[] markets;
        address[][] pTokensForPosition;
        address[][] eTokensForPosition;
        address[] tokensForBalance;
    }

    /// CONSTANTS ///
    uint256 public constant MARKET_ASSET_RESERVE = 77777;

    /// STORAGE ///

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;

    /// ERRORS ///

    error AuxiliaryData__ParametersMisconfigured();
    error AuxiliaryData__InvalidCentralRegistry();
    error AuxiliaryData__Unauthorized();

    /// CONSTRUCTOR ///

    constructor(ICentralRegistry centralRegistry_) {
        if (
            !ERC165Checker.supportsInterface(
                address(centralRegistry_),
                type(ICentralRegistry).interfaceId
            )
        ) {
            revert AuxiliaryData__InvalidCentralRegistry();
        }

        centralRegistry = centralRegistry_;
    }

    /// PUBLIC FUNCTIONS ///

    /// CHAIN-WIDE FUNCTIONS ///

    /// @notice Returns the current TVL inside Curvance.
    /// @return result The current TVL inside Curvance, in `WAD`.
    function getTotalTVL() public view returns (uint256 result) {
        address[] memory markets = marketManagers();
        uint256 numMarkets = markets.length;

        for (uint256 i; i < numMarkets; ) {
            result += getMarketTVL(markets[i++]);
        }
    }

    /// @notice Returns the current collateral TVL inside Curvance.
    /// @return result The current collateral TVL inside Curvance, in `WAD`.
    function getTotalCollateralTVL() public view returns (uint256 result) {
        address[] memory markets = marketManagers();
        uint256 numMarkets = markets.length;

        for (uint256 i; i < numMarkets; ) {
            result += getMarketCollateralTVL(markets[i++]);
        }
    }

    /// @notice Returns the current lending TVL inside Curvance.
    /// @return result The current lending TVL inside Curvance, in `WAD`.
    function getTotalLendingTVL() public view returns (uint256 result) {
        address[] memory markets = marketManagers();
        uint256 numMarkets = markets.length;

        for (uint256 i; i < numMarkets; ) {
            result += getMarketLendingTVL(markets[i++]);
        }
    }

    /// @notice Returns the current outstanding borrows inside Curvance.
    /// @return result The current outstanding borrows inside Curvance, in `WAD`.
    function getTotalBorrows() public view returns (uint256 result) {
        address[] memory markets = marketManagers();
        uint256 numMarkets = markets.length;

        for (uint256 i; i < numMarkets; ) {
            result += getMarketBorrows(markets[i++]);
        }
    }

    function marketManagers() public view returns (address[] memory) {
        return centralRegistry.marketManagers();
    }

    /// TOKEN-SPECIFIC FUNCTIONS ///
    function getAccountState(
        LookupAccountState calldata lookup
    )
        external
        view
        returns (
            AccountMarketPosition[] memory marketPositions,
            AccountAssetPosition[][] memory eTokenPositions,
            AccountAssetPosition[][] memory pTokenPositions,
            uint256[] memory tokenBalances
        )
    {
        if (lookup.account == address(0)) {
            revert("An account is required to query state");
        }

        marketPositions = new AccountMarketPosition[](lookup.markets.length);
        eTokenPositions = new AccountAssetPosition[][](lookup.markets.length);
        pTokenPositions = new AccountAssetPosition[][](lookup.markets.length);
        tokenBalances = new uint256[](lookup.tokensForBalance.length);

        // For each market in the marketplace
        for (uint256 i; i < lookup.markets.length; i++) {
            address market = lookup.markets[i];

            try IMarketManager(market).statusOf(lookup.account) returns (
                uint256 collateral,
                uint256 maxDebt,
                uint256 debt
            ) {
                marketPositions[i] = AccountMarketPosition({
                    collateral: collateral,
                    maxDebt: maxDebt,
                    debt: debt
                });
            } catch {}

            // Find the position for each token in the market
            if (i < lookup.eTokensForPosition.length) {
                address[] memory eTokens = lookup.eTokensForPosition[i];
                eTokenPositions[i] = new AccountAssetPosition[](
                    eTokens.length
                );
                for (uint256 j; j < eTokens.length; j++) {
                    IBorrowableCToken token = IBorrowableCToken(eTokens[j]);

                    AccountAssetPosition memory position;
                    (
                        position.hasPosition,
                        position.shareAmount,
                        position.collateralOrDebtAmount
                    ) = this.getAccountTokenData(
                        lookup.account,
                        address(token)
                    );
                    position.tokenAmount = token.convertToAssets(
                        position.shareAmount
                    );

                    eTokenPositions[i][j] = position;
                }
            }

            // Find the position for each token in the market
            if (i < lookup.pTokensForPosition.length) {
                address[] memory pTokens = lookup.pTokensForPosition[i];
                pTokenPositions[i] = new AccountAssetPosition[](
                    pTokens.length
                );
                for (uint256 j; j < pTokens.length; j++) {
                    ICToken token = ICToken(pTokens[j]);

                    AccountAssetPosition memory position;
                    (
                        position.hasPosition,
                        position.shareAmount,
                        position.collateralOrDebtAmount
                    ) = this.getAccountTokenData(
                        lookup.account,
                        address(token)
                    );
                    position.tokenAmount = token.convertToAssets(
                        position.shareAmount
                    );

                    pTokenPositions[i][j] = position;
                }
            }
        }

        // Find the balance for each token in the marketplace
        for (uint256 i; i < lookup.tokensForBalance.length; i++) {
            IERC20 token = IERC20(lookup.tokensForBalance[i]);
            tokenBalances[i] = token.balanceOf(lookup.account);
        }
    }

    /// @notice Returns if an account has an active position in `token`,
    /// @notice Returns if an account has an active position in `token`,
    ///         and any user balances or collateral posted in `token`.
    /// @param account The address of the account to check token data of.
    /// @param cToken The address of the Curvance token.
    function getAccountTokenData(
        address account,
        address cToken
    )
        public
        view
        returns (
            bool hasPosition,
            uint256 balanceOf,
            uint256 collateralOrDebtAmount
        )
    {
        ICToken token = ICToken(cToken);
        ILiquidityManager liquidityManager = ILiquidityManager(
            address(token.marketManager())
        );

        hasPosition = liquidityManager.accountPositions(cToken, account) == 2
            ? true
            : false;
        balanceOf = token.balanceOf(account);
        collateralOrDebtAmount = !token.isBorrowable()
            ? token.collateralPosted(account)
            : IBorrowableCToken(cToken).debtBalance(account);
    }

    /// @notice Returns if an account has an active position in `cToken`.
    /// @param account The address of the account to check a position of.
    /// @param cToken The address of the Curvance token.
    function tokenDataOf(
        address account,
        address cToken
    )
        external
        view
        returns (
            bool hasPosition,
            uint256 balanceOf,
            uint256 collateralPostedOf
        )
    {
        ICToken token = ICToken(cToken);
        IMarketManager marketManager = token.marketManager();
        uint256 hasPosition_ = ILiquidityManager(address(marketManager))
            .accountPositions(cToken, account);
        if (hasPosition_ == 2) {
            hasPosition = true;
        }

        balanceOf = token.balanceOf(account);
        collateralPostedOf = token.collateralPosted(account);
    }

    /// @notice Returns the `cToken` underlying balance of the `account`.
    /// @param account The address of the account to query.
    /// @param cToken The address of the token to query underlying balance of.
    /// @return The amount of `cToken` underlying owned by `account`.
    function getAccountBalanceOfUnderlying(
        address account,
        address cToken
    ) public view returns (uint256) {
        return (ICToken(cToken).convertToAssets(
            ICToken(cToken).balanceOf(account)
        ) / WAD);
    }

    /// @notice Return the debt balance of `account` based on stored data.
    /// @param account The address whose debt balance should be calculated.
    /// @param cToken The token to query outstanding debt balance of.
    /// @return `account`'s outstanding debt balance for `cToken`.
    function getAccountDebtData(
        address account,
        address cToken
    ) public view returns (uint256) {
        return IBorrowableCToken(cToken).debtBalance(account);
    }

    /// @notice Calculates the current eToken utilization rate.
    /// @param cToken The Curvance token to pull utilization rate data for.
    /// @return The utilization rate, in `WAD`.
    function getUtilizationRate(address cToken) public view returns (uint256) {
        IBorrowableCToken token = IBorrowableCToken(cToken);
        return
            token.interestRateModel().utilizationRate(
                token.assetsHeld(),
                token.marketOutstandingDebt()
            );
    }

    /// @notice Returns the current borrow interest rate per year for `cToken`.
    /// @param cToken The Curvance token to pull borrow rate data for.
    /// @return The borrow interest rate per year, in `WAD`.
    function getBorrowRatePerYear(
        address cToken
    ) public view returns (uint256) {
        IBorrowableCToken token = IBorrowableCToken(cToken);
        return
            token.interestRateModel().getBorrowRatePerYear(
                token.assetsHeld(),
                token.marketOutstandingDebt()
            );
    }

    /// @notice Returns predicted upcoming borrow interest rate per year
    ///         for `cToken`.
    /// @param cToken The Curvance token to pull predicted borrow rate
    ///               data for.
    /// @return The predicted borrow interest rate per year, in `WAD`.
    function getPredictedBorrowRatePerYear(
        address cToken
    ) public view returns (uint256) {
        IBorrowableCToken token = IBorrowableCToken(cToken);
        return
            token.interestRateModel().getPredictedBorrowRatePerYear(
                token.assetsHeld(),
                token.marketOutstandingDebt()
            );
    }

    /// @notice Returns the current supply interest rate per year for `cToken`.
    /// @param cToken The Curvance token to pull supply rate data for.
    /// @return The supply interest rate per year, in `WAD`.
    function getSupplyRatePerYear(
        address cToken
    ) public view returns (uint256) {
        IBorrowableCToken token = IBorrowableCToken(cToken);
        return
            token.interestRateModel().getSupplyRatePerYear(
                token.assetsHeld(),
                token.marketOutstandingDebt(),
                token.interestFee()
            );
    }

    function getBaseRewards(address token) public view returns (uint256) {}
    function getCVERewards(address token) public view returns (uint256) {}

    /// Oracle Manager FUNCTIONS ///

    function getPrices(
        address[] calldata assets,
        bool[] calldata inUSD,
        bool[] calldata getLower
    ) public view returns (uint256[] memory, uint256[] memory) {
        return _getOracleManager().getPrices(assets, inUSD, getLower);
    }

    function hasRewards(address user) public view returns (bool) {
        return _getRewardManager().hasRewardsToClaim(user);
    }

    /// MARKET-SPECIFIC FUNCTIONS ///

    /// @notice Returns all market data for all markets.
    /// @param account The account to get market data for.
    /// @return results An array of AllMarketData structs containing market data for all markets.
    function getAllMarketData(
        address account
    ) public view returns (AllMarketData[] memory) {
        address[] memory markets = this.marketManagers();
        uint256 numMarkets = markets.length;
        AllMarketData[] memory results = new AllMarketData[](numMarkets);

        for (uint256 i; i < numMarkets; i++) {
            (
                MarketBorrowableCTokens[] memory eTokenData,
                MarketCTokenData[] memory cTokenData
            ) = this.getMarketAssetData(markets[i], account);
            results[i] = AllMarketData(
                this.getMarketData(markets[i], account),
                eTokenData,
                cTokenData
            );
        }

        return results;
    }

    /// @notice Returns market data for a specific market.
    /// @param market The market to get data for.
    /// @param account The account to get market data for.
    /// @return result A MarketData struct containing market data.
    function getMarketData(
        address market,
        address account
    ) public view returns (MarketData memory result) {
        if (account != address(0)) {
            try IMarketManager(market).statusOf(account) returns (
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

    /// @notice Returns market asset data for a specific market.
    /// @param market The market to get asset data for.
    /// @param account The account to get asset data for.
    /// @return An array of MarketBorrowableCTokens structs
    ///         containing asset data for all borrowableCTokens.
    /// @return An array of MarketCTokenData structs containing
    ///         asset data for all collateralTokens.
    function getMarketAssetData(
        address market,
        address account
    )
        public
        view
        returns (MarketBorrowableCTokens[] memory, MarketCTokenData[] memory)
    {
        IOracleManager router = _getOracleManager();
        IMarketManager mm = IMarketManager(market);
        address[] memory collateralTokens = getMarketCollateralAssets(market);
        uint256 numTokens = collateralTokens.length;
        MarketCTokenData[] memory pTokenMarketData = new MarketCTokenData[](
            numTokens
        );
        for (uint256 i; i < numTokens; i++) {
            ICToken marketToken = ICToken(collateralTokens[i]);
            IERC20 token = IERC20(marketToken.asset());
            MarketCTokenData memory cTokenData;

            if (account != address(0)) {
                cTokenData.underlyingBalance = token.balanceOf(account);

                (
                    cTokenData.userTokenPosition.hasPosition,
                    cTokenData.userTokenPosition.shareAmount,
                    cTokenData.userTokenPosition.collateralOrDebtAmount
                ) = getAccountTokenData(account, collateralTokens[i]);

                cTokenData.userTokenPosition.tokenAmount = marketToken
                    .convertToAssets(cTokenData.userTokenPosition.shareAmount);
            }

            cTokenData.assetAddress = collateralTokens[i];
            cTokenData.marketAddress = market;
            cTokenData.underlyingAddress = address(token);
            cTokenData.underlyingName = token.name();
            cTokenData.underlyingSymbol = token.symbol();
            cTokenData.underlyingDecimal = token.decimals();
            cTokenData.totalCollateralTokens =
                marketToken.totalSupply() -
                MARKET_ASSET_RESERVE;
            cTokenData.totalCollateralPosted = ICToken(collateralTokens[i])
                .marketCollateralPosted();
            cTokenData.collateralCap = mm.collateralCaps(collateralTokens[i]);
            cTokenData.sharePrice = _getTokenPrice(collateralTokens[i], true);
            cTokenData.tokenPrice = _getTokenPrice(address(token), true);
            cTokenData.config = _getTokenConfig(
                collateralTokens[i],
                ILiquidityManager(address(mm))
            );
            (uint256 oracleA, uint256 oracleB) = router.getAdaptorTypes(
                collateralTokens[i]
            );
            cTokenData.adaptorTypes = [oracleA, oracleB];

            pTokenMarketData[i] = cTokenData;
        }

        address[] memory borrowableCTokens = getMarketDebtAssets(market);
        numTokens = borrowableCTokens.length;
        MarketBorrowableCTokens[]
            memory eTokenMarketData = new MarketBorrowableCTokens[](numTokens);
        for (uint256 i; i < numTokens; ++i) {
            MarketBorrowableCTokens memory eTokenData;
            IBorrowableCToken marketToken = IBorrowableCToken(
                borrowableCTokens[i]
            );
            IERC20 token = IERC20(marketToken.asset());

            if (account != address(0)) {
                eTokenData.underlyingBalance = token.balanceOf(account);
                (
                    eTokenData.userTokenPosition.hasPosition,
                    eTokenData.userTokenPosition.shareAmount,
                    eTokenData.userTokenPosition.collateralOrDebtAmount
                ) = getAccountTokenData(account, borrowableCTokens[i]);

                eTokenData.userTokenPosition.tokenAmount = marketToken
                    .convertToAssets(eTokenData.userTokenPosition.shareAmount);
            }

            eTokenData.assetAddress = borrowableCTokens[i];
            eTokenData.marketAddress = market;
            eTokenData.underlyingAddress = address(token);
            eTokenData.underlyingName = token.name();
            eTokenData.underlyingSymbol = token.symbol();
            eTokenData.underlyingDecimal = token.decimals();
            eTokenData.tvl = getTokenTVL(borrowableCTokens[i], false);
            eTokenData.borrows = getTokenBorrows(borrowableCTokens[i]);
            eTokenData.supplyRatePerYear = getSupplyRatePerYear(
                borrowableCTokens[i]
            );
            eTokenData.borrowRatePerYear = getBorrowRatePerYear(
                borrowableCTokens[i]
            );
            eTokenData.predictedBorrowRatePerYear = this
                .getPredictedBorrowRatePerYear(borrowableCTokens[i]);
            eTokenData.utilizationRate = getUtilizationRate(
                borrowableCTokens[i]
            );
            eTokenData.sharePrice = _getTokenPrice(
                borrowableCTokens[i],
                false
            );
            eTokenData.tokenPrice = _getTokenPrice(address(token), false);
            eTokenData.config = _getTokenConfig(
                borrowableCTokens[i],
                ILiquidityManager(address(mm))
            );

            if (eTokenData.tvl > eTokenData.borrows) {
                eTokenData.liquidityAvailable =
                    eTokenData.tvl -
                    eTokenData.borrows;
            } else {
                eTokenData.liquidityAvailable = 0;
            }
            (uint256 oracleA, uint256 oracleB) = router.getAdaptorTypes(
                borrowableCTokens[i]
            );
            eTokenData.adaptorTypes = [oracleA, oracleB];

            eTokenMarketData[i] = eTokenData;
        }

        return (eTokenMarketData, pTokenMarketData);
    }

    /// @notice Determine whether `account` can currently be liquidated
    ///         in `market` for `eToken` and `pToken`.
    /// @param market The market to check `account` for liquidation flag.
    /// @param account The account to check for liquidation flag.
    /// @param eToken The eToken to be repaid during potential liquidation.
    /// @param pToken The pToken to be seized during potential
    ///                        liquidation.
    /// @dev Note: Liquidation flag uses cached exchange rates for each mToken.
    ///            Thus, accumulated but unrecognized interest is not included.
    /// @return Whether `account` can be liquidated currently.
    function flaggedForLiquidation(
        address market,
        address account,
        address eToken,
        address pToken
    ) external view returns (bool) {
        (uint256 lFactor, , ) = IMarketManager(market).liquidationStatusOf(
            account,
            eToken,
            pToken
        );
        return lFactor > 0;
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
            getLower = ICToken(token).isBorrowable() ? true : false;
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

        address asset;
        for (uint256 i; i < numAssets; ) {
            asset = assets[i++];
            result +=
                (_getTokenPrice(asset, true) *
                    ICToken(asset).marketCollateralPosted()) /
                10 ** ICToken(asset).decimals();
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
            ++numCollateralAssets;
        }

        address[] memory collateralAssets = new address[](numCollateralAssets);
        uint256 collateralAssetsIndex = 0;

        for (uint256 i; i < numAssets; ++i) {
            asset = assets[i];
            collateralAssets[collateralAssetsIndex++] = asset;
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
            if (!ICToken(asset).isBorrowable()) {
                ++numDebtAssets;
            }
        }

        address[] memory debtAssets = new address[](numDebtAssets);
        uint256 debtAssetsIndex = 0;

        for (uint256 i; i < numAssets; ++i) {
            asset = assets[i];
            if (!ICToken(asset).isBorrowable()) {
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
                (ICToken(token).totalSupply() - MARKET_ASSET_RESERVE)) /
            10 ** ICToken(token).decimals();
    }

    /// @notice Returns the outstanding underlying debt for `cToken`.
    /// @param cToken The Curvance token to query outstanding debt for.
    /// @return result The outstanding underlying debt, in `WAD`.
    function getTokenBorrows(
        address cToken
    ) public view returns (uint256 result) {
        IBorrowableCToken token = IBorrowableCToken(cToken);

        // Get outstanding debt then query price and return.
        result =
            (_getTokenPrice(token.asset(), false) *
                token.marketOutstandingDebt()) /
            10 ** token.decimals();
    }

    function getTokenPrice(address token) public view returns (uint256) {
        return
            _getTokenPrice(
                token,
                !ICToken(token).isBorrowable() ? true : false
            );
    }

    /// INTERNAL FUNCTIONS ///
    function _getTokenConfig(
        address token,
        ILiquidityManager mm
    ) internal view returns (MarketAssetConfig memory) {
        MarketAssetConfig memory config;

        (
            bool isListed,
            uint256 collRatio,
            uint256 collReqSoft,
            uint256 collReqHard,
            uint256 liqBaseIncentive,
            uint256 liqCurve,
            ,
            ,
            ,
            ,
            uint256 baseCFactor,
            uint256 cFactorCurve
        ) = mm.tokenData(token);

        config.isListed = isListed;
        config.collRatio = collRatio;
        config.collReqSoft = collReqSoft;
        config.collReqHard = collReqHard;
        config.liqBaseIncentive = liqBaseIncentive;
        config.liqCurve = liqCurve;
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
