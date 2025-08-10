// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { LiquidityManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { IOracleAdaptor } from "contracts/interfaces/IOracleAdaptor.sol";
import { IVeCVE } from "contracts/interfaces/IVeCVE.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IDynamicIRM } from "contracts/interfaces/IDynamicIRM.sol";

import { WAD, WAD_SQUARED, SECONDS_PER_YEAR } from "contracts/libraries/ConstantsLib.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";

// NOTE: This is a work in progress, don't implement yet.
// TODO: Change things like tokenPrice -> assetPrice, this token prefix is 
// commonly referenced as the "asset" which is what the protocol uses
contract ProtocolReader2 {
    /// TYPES ///
    struct StaticMarketData {
        address _address;
        uint256[] adapters;
        uint256 cooldownLength;
        StaticMarketToken[] tokens;
    }

    struct StaticMarketToken {
        address _address;
        StaticMarketAsset asset;
        uint256 collateralCap;
        uint256 debtCap;
        bool isListed;
        bool mintPaused;
        bool collateralizationPaused;
        bool borrowPaused;
        bool isBorrowable;
        uint256 collRatio;
        uint256 collReqSoft;
        uint256 collReqHard;
        uint256 liqIncBase;
        uint256 liqIncCurve;
        uint256 liqIncMin;
        uint256 liqIncMax;
        uint256 closeFactorBase;
        uint256 closeFactorCurve;
        uint256 closeFactorMin;
        uint256 closeFactorMax;
        uint256[2] adapters;
    }

    struct StaticMarketAsset {
        address _address;
        string name;
        string symbol;
        uint8 decimals;
        uint256 totalSupply;
    }

    // TODO: In the JS world we need to have the option to convert tvl,collateral,debt to USD
    struct DynamicMarketData {
        address _address;
        uint256 tvl;
        uint256 collateral;
        uint256 debt;
        DynamicMarketToken[] tokens;
    }

    // TODO: In the JS world we need to have the option to convert tvl,collateral,debt to USD
    struct DynamicMarketToken {
        address _address;
        uint256 tvl;
        uint256 collateral;
        uint256 debt;
        uint256 sharePrice;
        uint256 tokenPrice;
        uint256 sharePriceLower;
        uint256 tokenPriceLower;
        uint256 borrowRate;
        uint256 predictedBorrowRate;
        uint256 utilizationRate;
        uint256 supplyRate;
        uint256 liquidity;
    }

    struct UserData {
        UserLock[] locks;
        UserMarket[] markets;
    }

    struct UserLock {
        uint256 lockIndex;
        uint256 amount;
        uint256 unlockTime;
    }

    struct UserMarket {
        address _address;
        uint256 debt;
        uint256 collateral;
        uint256 maxDebt;
        uint256 healthFactor;
        uint256 cooldown;
        UserMarketToken[] tokens;
    }

    struct UserMarketToken {
        address _address;
        uint256 tokenAmount;
        uint256 shareAmount;
        uint256 debt;
        uint256 collateral;
    }

    /// CONSTANTS ///
    // @dev: See MarketManagerIsolated constant: MIN_HOLD_PERIOD
    uint256 public constant MARKET_COOLDOWN_LENGTH = 20 minutes;
    uint256 public constant MARKET_ASSET_RESERVE = 77777;

    /// STORAGE ///
    ICentralRegistry public immutable centralRegistry;
    uint256 public calcMaxLeverage = 0.99e18;

    /// ERRORS ///
    error AuxiliaryData__InvalidCentralRegistry();

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

    function setCalcMaxLeverage(uint256 newCalcMaxLeverage) external {
		calcMaxLeverage = newCalcMaxLeverage;
    }

    function getAllDynamicState(
        address account
    )
        public
        view
        returns (DynamicMarketData[] memory market, UserData memory user)
    {
        return (getDynamicMarketData(), getUserData(account));
    }

    function getStaticMarketData()
        public
        view
        returns (StaticMarketData[] memory data)
    {
        address[] memory markets = centralRegistry.marketManagers();
        IOracleManager om = IOracleManager(centralRegistry.oracleManager());

        data = new StaticMarketData[](markets.length);
        for (uint256 i; i < markets.length; i++) {
            IMarketManager mm = IMarketManager(markets[i]);

            address[] memory tokenAddresses = mm.queryTokensListed();
            StaticMarketToken[] memory tokens = new StaticMarketToken[](
                tokenAddresses.length
            );

            uint256[] memory uniqueAdapters;
            for (uint256 j; j < tokenAddresses.length; j++) {
                ICToken cToken = ICToken(tokenAddresses[j]);
                (uint256 oracleA, uint256 oracleB) = _getAdaptorTypes(
                    address(cToken),
                    om
                );

                uniqueAdapters = _addUniqueAdapter(uniqueAdapters, oracleA);
                uniqueAdapters = _addUniqueAdapter(uniqueAdapters, oracleB);

                tokens[j] = _getStaticTokenConfig(mm, cToken);
                tokens[j].adapters = [oracleA, oracleB];
            }

            data[i] = StaticMarketData({
                _address: address(mm),
                adapters: uniqueAdapters,
                cooldownLength: MARKET_COOLDOWN_LENGTH,
                tokens: tokens
            });
        }
    }

    function getDynamicMarketData()
        public
        view
        returns (DynamicMarketData[] memory data)
    {
        address[] memory markets = centralRegistry.marketManagers();
        data = new DynamicMarketData[](markets.length);
        for (uint256 i; i < markets.length; i++) {
            data[i] = _buildDynamicMarketData(IMarketManager(markets[i]));
        }

        return data;
    }

    function getUserData(
        address account
    ) public view returns (UserData memory data) {
        IVeCVE veCve = IVeCVE(centralRegistry.veCVE());
        (uint256[] memory lockAmounts, uint256[] memory lockTimestamps) = veCve.queryUserLocks(account);
        data.locks = new UserLock[](lockAmounts.length);
        for (uint256 i = 0; i < lockAmounts.length; i++) {
            data.locks[i] = UserLock({
                lockIndex: i,
                amount: lockAmounts[i],
                unlockTime: lockTimestamps[i]
            });
        }
        
        address[] memory markets = centralRegistry.marketManagers();
        data.markets = new UserMarket[](markets.length);
        for (uint256 i = 0; i < markets.length; i++) {
            IMarketManager mm = IMarketManager(markets[i]);
            data.markets[i] = _buildUserMarket(mm, account);
        }

        return data;
    }

    /// @notice Calculates the hypothetical maximum amount of
    ///         `borrowableCToken` assets `account` can borrow for maximum
    ///         leverage based on a new `cToken` collateralized deposit.
    /// @dev Applies a minor dampening effect to calculated maximum leverage
    ///      via `calcMaxLeverage`. Offsets maximum borrowable debt amount if
    ///      there is insufficient liquidity to borrow in the target market.
    /// @param account The account to query maximum borrow amount for.
    /// @param borrowableCToken The token that `account` will borrow assets
    ///                         from to achieve leverage.
    /// @param cToken The token that `account` will deposit to
    ///                        leverage against.
    /// @param assets The amount of `cToken` underlying that
    ///               `account` will deposit to leverage against.
    /// @return maxDebtBorrowable Returns the maximum remaining borrow amount
    ///                           allowed from `borrowableCToken`, measured in
    ///                           underlying token amount, after the new
    ///                           hypothetical deposit.
    /// @return isOffset Whether the maximum borrowable debt amount returned
    ///                  has been offset due to available liquidity or not.
    function hypotheticalMaxLeverage(
        address account,
        address borrowableCToken,
        address cToken,
        uint256 assets
    ) public view returns (uint256 maxDebtBorrowable, bool isOffset) {
        IMarketManager mm = ICToken(borrowableCToken).marketManager();
        (uint256 price, uint256 errorCode) = IOracleManager(
            ICentralRegistry(centralRegistry).oracleManager()
        ).getPrice(address(cToken), true, true);

        // Validate we got a price for `cToken`.
        if (errorCode != 0) {
            revert();
        }

        (uint256 sumCollateral, uint256 maxDebt, uint256 sumDebt) = mm
            .statusOf(account);

        {
            uint256 newCollateral = FixedPointMathLib.mulDiv(
                ICToken(cToken).previewDeposit(assets),
                price,
                10 ** ICToken(cToken).decimals()
            );

            (uint256 collRatio, ,) = mm.collConfig(address(cToken));

            // If the collateral token cannot be borrowed against the hypothetical
            // leverage check will result in 0 meaning nothing new to leverage
            // against.
            if (collRatio == 0) {
                revert();
            }

            sumCollateral += newCollateral;
            maxDebt += FixedPointMathLib.mulDiv(newCollateral, collRatio, WAD);
        }

        // We can calculate terminal leverage by calculating the infinite
        // series of swapping to maximum LTV over and over, which results
        // in the equation 1 / (1 - LTV).
        //
        // For example, 80% LTV will result in terminal maximum leverage of:
        // 1 / (1 - .8) -> (1 / 0.2) -> 5x leverage.
        // The equation below is equal to this equation,
        // just extrapolated for an account's collateral vs debt.
        //
        // We also embed a `calcMaxLeverage` dampening effect to minimize
        // transaction failure from imperfect execution due to things
        // such as price fluctuations, and AMM fees.
        uint256 maxLeverage = FixedPointMathLib.mulDiv(
            maxDebt - sumDebt,
            sumCollateral * calcMaxLeverage,
            sumCollateral - maxDebt
        ) / WAD;

        (price, errorCode) = IOracleManager(
            ICentralRegistry(centralRegistry).oracleManager()
        ).getPrice(address(borrowableCToken), true, false);

        // Validate we got a price for `borrowableCToken`.
        if (errorCode != 0) {
            revert();
        }

        maxDebtBorrowable = FixedPointMathLib.mulDiv(
            FixedPointMathLib.mulDiv(maxLeverage, WAD, price),
            10 ** IERC20(borrowableCToken).decimals(),
            WAD
        );

        uint256 liquidityAvailable = IERC20(ICToken(borrowableCToken).asset())
            .balanceOf(borrowableCToken);

        if (liquidityAvailable < maxDebtBorrowable) {
            maxDebtBorrowable = liquidityAvailable;
            isOffset = true;
        }
    }

    /// @notice Returns the cooldown periods for multiple markets for a user
    /// @param markets The list of market addresses
    /// @param user The user address
    /// @return cooldowns The list of cooldown periods for each market
    function marketMultiCooldown(
        address[] calldata markets,
        address user
    ) public view returns (uint256[] memory) {
        uint256[] memory cooldowns = new uint256[](markets.length);
        for (uint256 i; i < markets.length; ++i) {
            MarketManagerIsolated mm = MarketManagerIsolated(markets[i]);
            uint256 cooldownTimestamp = mm.accountAssets(user);

            cooldowns[i] = cooldownTimestamp + MARKET_COOLDOWN_LENGTH;
        }
        return cooldowns;
    }

    /// INTERNAL FUNCTIONS ///
    /// @notice Gets the health factor of a user's position in a market
    /// @param mm The market manager to pull data from.
    /// @param account The user address to get the health factor for.
    /// @return healthFactor The health factor of the user's position.
    function _getPositionHealth(IMarketManager mm, address account)
        internal
        view
        returns (uint256 healthFactor) {
        (uint256 soft, , uint256 debt) = mm.liquidationValuesOf(account);
        return (soft * WAD) / debt;
    }

    /// @notice Queries static token configuration of `cToken`
    /// @param mm The market manager to pull static token data from.
    /// @param cToken The address of the cToken to pull static token
    ///               configuration of.
    /// @return t A StaticMarketToken struct containing static token
    ///           configuration information.
    function _getStaticTokenConfig(
        IMarketManager mm,
        ICToken cToken
    ) internal view returns (StaticMarketToken memory t) {
        t._address = address(cToken);
        t.asset._address = cToken.asset();
        t.asset.name =  cToken.name();
        t.asset.symbol = cToken.symbol();
        t.asset.decimals = cToken.decimals();
        t.asset.totalSupply = cToken.totalSupply();
        
        t.collateralCap = mm.collateralCaps(address(cToken));
        t.debtCap = mm.debtCaps(address(cToken));

        t.isListed = mm.isListed(address(cToken));
        (t.mintPaused, t.collateralizationPaused, t.borrowPaused) =
            mm.actionsPaused(address(cToken));
        t.isBorrowable = cToken.isBorrowable();
        (t.collRatio, t.collReqSoft, t.collReqHard) = mm.collConfig(address(cToken));
        (
            t.liqIncBase,
            t.liqIncCurve,
            t.liqIncMin,
            t.liqIncMax,
            t.closeFactorBase,
            t.closeFactorCurve,
            t.closeFactorMin,
            t.closeFactorMax
        ) = mm.liquidationConfig(address(cToken));
    }

    /// @notice Adds an newAdapter to the existingAdapters if it doesn't already exist
    /// @param existingAdapters A list of adapters for the market
    /// @param newAdapter The adapter value to add
    /// @return allAdapters The potentially expanded array
    function _addUniqueAdapter(
        uint256[] memory existingAdapters,
        uint256 newAdapter
    ) internal pure returns (uint256[] memory allAdapters) {
        allAdapters = new uint256[](existingAdapters.length + 1);
        for (uint256 i = 0; i < existingAdapters.length; i++) {
            if (existingAdapters[i] == newAdapter) {
                return existingAdapters; // Already exists, return original
            }
            allAdapters[i] = existingAdapters[i];
        }

        // Doesn't exist, so we add it to the end
        allAdapters[existingAdapters.length] = newAdapter;
    }

    /// @notice Returns the types of adaptors pricing `asset` uses.
    /// @dev Used by frontends to determine how to properly interact
    ///      with a supported asset.
    /// @param  asset The asset whose adaptor types should be returned.
    /// @return A tuple containing the types of adaptors pricing `asset`
    ///         uses, a value of 0 indicates an unsupported or empty
    ///         adaptor slot.
    function _getAdaptorTypes(
        address asset,
        IOracleManager om
    ) internal view returns (uint256, uint256) {
        IOracleManager.CToken memory cToken = om.getCToken(asset);
        if (cToken.isCToken) {
            asset = cToken.underlying;
        }

        address[] memory feeds = om.getPriceFeeds(asset);

        uint256 numFeeds = feeds.length;
        if (numFeeds == 0) {
            return (0, 0);
        }

        address adaptor;

        // If the asset only has one price feed, we know it will be in
        // feed slot 0 so get both prices and return
        if (numFeeds < 2) {
            adaptor = feeds[0];
            if (!om.isApprovedAdaptor(adaptor)) {
                return (0, 0);
            }

            return (IOracleAdaptor(adaptor).adaptorType(), 0);
        }

        adaptor = feeds[0];
        uint256 adaptorTypeA = om.isApprovedAdaptor(adaptor)
            ? IOracleAdaptor(adaptor).adaptorType()
            : 0;

        adaptor = feeds[1];
        uint256 adaptorTypeB = om.isApprovedAdaptor(adaptor)
            ? IOracleAdaptor(adaptor).adaptorType()
            : 0;

        return (adaptorTypeA, adaptorTypeB);
    }

    function _buildUserMarketToken(
        address tokenAddress,
        address account
    ) internal view returns (UserMarketToken memory) {
        ICToken ctoken = ICToken(tokenAddress);
        uint256 shares = ctoken.balanceOf(account);
        return UserMarketToken({
            _address: tokenAddress,
            tokenAmount: ctoken.convertToAssets(shares),
            shareAmount: shares,
            debt: ctoken.isBorrowable() ? IBorrowableCToken(address(ctoken)).debtBalance(account) : 0,
            collateral: ctoken.collateralPosted(account)
        });
    }

    function _buildUserMarket(
        IMarketManager mm,
        address account
    ) internal view returns (UserMarket memory) {
        address[] memory tokenAddresses = mm.queryTokensListed();
        UserMarketToken[] memory tokens = new UserMarketToken[](tokenAddresses.length);
        for (uint256 j = 0; j < tokenAddresses.length; j++) {
            tokens[j] = _buildUserMarketToken(tokenAddresses[j], account);
        }
        
        (uint256 collateral, uint256 maxDebt, uint256 debt) = mm.statusOf(account);
        return UserMarket({
            _address: address(mm),
            debt: debt,
            collateral: collateral,
            maxDebt: maxDebt,
            healthFactor: _getPositionHealth(mm, account),
            cooldown: MarketManagerIsolated(address(mm)).accountAssets(account) + MARKET_COOLDOWN_LENGTH,
            tokens: tokens
        });
    }

    function _buildDynamicMarketToken(ICToken ctoken) internal view returns (DynamicMarketToken memory) {
        bool canBorrow = ctoken.isBorrowable();
        address asset = ctoken.asset();
        uint256 tokenPriceLower = _getUsdPrice(address(asset), true);
        uint256 sharePriceLower = _getUsdPrice(address(ctoken), true);
        uint256 tokenPrice = _getUsdPrice(address(asset), false);
        uint256 sharePrice = _getUsdPrice(address(ctoken), false);

        DynamicMarketToken memory dmt = DynamicMarketToken({
            _address: address(ctoken),
            tokenPrice: tokenPrice,
            tokenPriceLower: tokenPriceLower,
            sharePrice: sharePrice,
            sharePriceLower: sharePriceLower,
            tvl: IERC20(asset).balanceOf(address(ctoken)),
            collateral: ctoken.marketCollateralPosted(),
            debt: 0,
            liquidity: 0,
            borrowRate: 0,
            predictedBorrowRate: 0,
            utilizationRate: 0,
            supplyRate: 0
        });

        if(canBorrow) {
            IBorrowableCToken bcToken = IBorrowableCToken(address(ctoken));
            IDynamicIRM irm = bcToken.IRM();

            dmt.debt = bcToken.marketOutstandingDebt();
            dmt.liquidity = dmt.tvl - dmt.debt;
            dmt.borrowRate = irm.borrowRate(dmt.tvl, dmt.debt) * SECONDS_PER_YEAR;
            dmt.predictedBorrowRate = irm.predictedBorrowRate(dmt.tvl, dmt.debt) * SECONDS_PER_YEAR;
            dmt.utilizationRate = irm.utilizationRate(dmt.tvl, dmt.debt) * SECONDS_PER_YEAR;
            dmt.supplyRate = irm.supplyRate(dmt.tvl, dmt.debt, bcToken.interestFee()) * SECONDS_PER_YEAR;
        }

        return dmt;
    }

    function _buildDynamicMarketData(IMarketManager mm) internal view returns (DynamicMarketData memory) {
        address[] memory tokenAddresses = mm.queryTokensListed();
        DynamicMarketToken[] memory tokens = new DynamicMarketToken[](tokenAddresses.length);

        uint256 marketTvl = 0;
        uint256 marketCollateral = 0;
        uint256 marketDebt = 0;
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            ICToken ctoken = ICToken(tokenAddresses[i]);
            DynamicMarketToken memory dmToken = _buildDynamicMarketToken(ctoken);
            tokens[i] = dmToken;

            marketTvl += dmToken.tvl;
            marketCollateral += dmToken.collateral;
            marketDebt += dmToken.debt;
        }

        return DynamicMarketData({
            _address: address(mm),
            tvl: marketTvl,
            collateral: marketCollateral,
            debt: marketDebt,
            tokens: tokens
        });
    }

    function _getUsdPrice(address token, bool getLower) internal view returns (uint256) {
        IOracleManager om = IOracleManager(centralRegistry.oracleManager());
        (uint256 price, ) = om.getPrice(token, true, getLower);
        return price;
    }
}
