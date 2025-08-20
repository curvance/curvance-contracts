// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { MarketManagerIsolated, LiquidityManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { CommonLib } from "contracts/libraries/CommonLib.sol";
import { WAD, WAD_SQUARED, SECONDS_PER_YEAR } from "contracts/libraries/ConstantsLib.sol";
import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";

import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { IOracleAdaptor } from "contracts/interfaces/IOracleAdaptor.sol";
import { IVeCVE } from "contracts/interfaces/IVeCVE.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IDynamicIRM } from "contracts/interfaces/IDynamicIRM.sol";

contract ProtocolReader {
    /// TYPES ///
    
    struct StaticMarketData {
        address _address;
        uint256[] adapters;
        uint256 cooldownLength;
        StaticMarketToken[] tokens;
    }

    struct StaticMarketToken {
        address _address;
        string name;
        string symbol;
        uint8 decimals;
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

    struct DynamicMarketData {
        address _address;
        DynamicMarketToken[] tokens;
    }

    struct DynamicMarketToken {
        address _address;
        uint256 totalSupply;
        uint256 collateral;
        uint256 debt;
        uint256 sharePrice;
        uint256 assetPrice;
        uint256 sharePriceLower;
        uint256 assetPriceLower;
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
        uint256 collateral;
        uint256 maxDebt;
        uint256 debt;
        uint256 positionHealth;
        uint256 cooldown;
        UserMarketToken[] tokens;
    }

    struct UserMarketToken {
        address _address;
        uint256 userAssetBalance;
        uint256 userShareBalance;
        uint256 userCollateral;
        uint256 userDebt;
    }

    /// CONSTANTS ///

    // @dev: See MarketManagerIsolated constant: MIN_HOLD_PERIOD
    uint256 public constant MARKET_COOLDOWN_LENGTH = 20 minutes;
    uint256 public constant MARKET_ASSET_RESERVE = 77777;

    /// STORAGE ///

    ICentralRegistry public immutable centralRegistry;

    /// ERRORS ///

    error ProtocolReader__PriceError();
    error ProtocolReader__TokenNotListed();
    error ProtocolReader__NonCollateralizable();

    /// CONSTRUCTOR ///

    constructor(ICentralRegistry cr) {
        CentralRegistryLib._isCentralRegistry(cr);
        centralRegistry = cr;
    }

    /// PUBLIC FUNCTIONS ///

    function getAllDynamicState(address account) public view returns (
        DynamicMarketData[] memory market,
        UserData memory user
    ) {
        return (getDynamicMarketData(), getUserData(account));
    }

    function getStaticMarketData()
        public
        view
        returns (StaticMarketData[] memory data)
    {
        address[] memory markets = centralRegistry.marketManagers();
        IOracleManager om = _getOracleManager();

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

    function getPrice(
        address asset,
        bool inUSD,
        bool getLower
    ) public view returns (uint256 price, uint256 errorCode) {
        (price, errorCode) = _getOracleManager()
            .getPrice(asset, inUSD, getLower);
        if (errorCode == 2) {
            price = 0;
        }
    }

    function getPriceOnly(
        address asset,
        bool inUSD,
        bool getLower
    ) public view returns (uint256 price) {
        (price, ) = getPrice(asset, inUSD, getLower);
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
    }

    /// @notice Gets the health factor of a user's position in a market
    /// @param mm The market manager to pull data from.
    /// @param account The user address to get the health factor for.
    /// @return positionHealth The healthiness of `account`'s position.
    function getPositionHealth(
        IMarketManager mm,
        address account
    ) public view returns (uint256 positionHealth) {
        (uint256 soft, , uint256 debt, ) = mm.liquidationValuesOf(account);

        // No debt means infinite position health.
        if (debt == 0) {
            return type(uint256).max; 
        }

        positionHealth = (soft * WAD) / debt;
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
            data.markets[i] =
                _buildUserMarket(MarketManagerIsolated(markets[i]), account);
        }
    }

    /// @notice Calculates the hypothetical maximum amount of
    ///         `borrowableCToken` assets `account` can borrow for maximum
    ///         leverage based on a new `cToken` collateralized deposit.
    /// @dev NOTE: This can overestimate maximum executeable leverage when
    ///            swapping due to AMM fees and slippage.
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
    function hypotheticalMaxRemainingLeverageOf(
        address account,
        address borrowableCToken,
        address cToken,
        uint256 assets
    ) public view returns (uint256 maxDebtBorrowable, bool isOffset) {
        IMarketManager mm = ICToken(borrowableCToken).marketManager();
        (uint256 price, uint256 errorCode) =
            getPrice(address(cToken), true, true);

        // Validate we got a price for `cToken`.
        if (errorCode != 0) {
            revert ProtocolReader__PriceError();
        }

        // Validate `cToken` and `borrowableCToken` are properly listed.
        if (!mm.isListed(borrowableCToken)) {
            revert ProtocolReader__TokenNotListed();
        }

        (uint256 sumCollateral, uint256 maxDebt, uint256 sumDebt) =
            mm.statusOf(account);

        {
            uint256 newCollateral = _mulDiv(
                ICToken(cToken).previewDeposit(assets),
                price,
                10 ** ICToken(cToken).decimals()
            );

            (uint256 collRatio, ,) = mm.collConfig(address(cToken));
            // If the collateral token cannot be borrowed against the hypothetical
            // leverage check will result in 0 meaning nothing new to leverage
            // against.
            if (collRatio == 0) {
                revert ProtocolReader__NonCollateralizable();
            }

            sumCollateral += newCollateral;
            maxDebt += _mulDiv(newCollateral, collRatio, WAD);
        }

        // We can calculate terminal leverage by calculating the infinite
        // series of swapping to maximum LTV over and over, which results
        // in the equation 1 / (1 - LTV).
        //
        // For example, 80% LTV will result in terminal maximum leverage of:
        // 1 / (1 - .8) -> (1 / 0.2) -> 5x leverage.
        // The equation below is equal to this equation,
        // just extrapolated for an account's collateral vs debt.
        /// NOTE: This can overestimate maximum executeable leverage when
        ///       swapping due to AMM fees and slippage.
        uint256 maxLeverage = _mulDiv(
            maxDebt - sumDebt,
            sumCollateral,
            sumCollateral - maxDebt
        );

        (price, errorCode) = getPrice(address(borrowableCToken), true, false);

        // Validate we got a price for `borrowableCToken`.
        if (errorCode != 0) {
            revert();
        }

        maxDebtBorrowable = _mulDiv(
            _mulDiv(maxLeverage, WAD, price),
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

    /// @notice Preview the impact of a new asset deposit on the market
    /// @param user The user address
    /// @param collateralCToken The address of the collateral cToken
    /// @param debtBorrowableCToken The address of the debt borrowable cToken
    /// @param newCollateralAssets The amount of new collateral assets to deposit
    /// @return supply The projected supply amount
    /// @return borrow The projected borrow amount
    function previewAssetImpact(
        address user,
        address collateralCToken,
        address debtBorrowableCToken,
        uint256 newCollateralAssets,
        uint256 newDebtAssets
    ) public view returns (uint256 supply, uint256 borrow) {
        ICToken cToken = ICToken(collateralCToken);
        IBorrowableCToken bcToken;
        uint256 assetsHeld;
        uint256 debt = bcToken.marketOutstandingDebt();
        
        if (cToken.isBorrowable()) {
            bcToken = IBorrowableCToken(address(collateralCToken));
            assetsHeld = bcToken.assetsHeld() + newCollateralAssets;
            debt = bcToken.marketOutstandingDebt();
            supply = bcToken.IRM()
                .supplyRate(assetsHeld, debt, bcToken.interestFee()) * SECONDS_PER_YEAR;
        }

        bcToken = IBorrowableCToken(debtBorrowableCToken);
        if (bcToken.debtBalance(user) != 0) {
            assetsHeld = bcToken.assetsHeld() - newDebtAssets;
            debt = bcToken.marketOutstandingDebt();
            borrow = bcToken.IRM()
                .borrowRate(assetsHeld, debt) * SECONDS_PER_YEAR;
        }
    }

    /// INTERNAL FUNCTIONS ///

    function _getStaticTokenAsset(ICToken cToken) internal view returns (StaticMarketAsset memory a) {
        IERC20 asset = IERC20(cToken.asset());
        a._address = address(asset);
        a.name =  asset.name();
        a.symbol = asset.symbol();
        a.decimals = asset.decimals();
        a.totalSupply = asset.totalSupply();
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
        t.name = cToken.name();
        t.symbol = cToken.symbol();
        t.decimals = cToken.decimals();
        t.asset = _getStaticTokenAsset(cToken);
        
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
    ) internal view returns (UserMarketToken memory umt) {
        ICToken ctoken = ICToken(tokenAddress);
        uint256 shares = ctoken.balanceOf(account);

        umt._address = tokenAddress;
        umt.userAssetBalance = ctoken.convertToAssets(shares);
        umt.userShareBalance = ctoken.balanceOf(account);
        umt.userDebt = ctoken.isBorrowable() ? IBorrowableCToken(address(ctoken)).debtBalance(account) : 0;
        umt.userCollateral = ctoken.collateralPosted(account);
    }

    function _buildUserMarket(
        MarketManagerIsolated mm,
        address account
    ) internal view returns (UserMarket memory um) {
        address[] memory tokenAddresses = mm.queryTokensListed();
        uint256 numTokens = tokenAddresses.length;
        UserMarketToken[] memory tokens = new UserMarketToken[](numTokens);
        
        for (uint256 j; j < numTokens; ++j) {
            tokens[j] = _buildUserMarketToken(tokenAddresses[j], account);
        }
        
        (um.collateral, um.maxDebt, um.debt) = mm.statusOf(account);
        um._address = address(mm);
        um.positionHealth = getPositionHealth(mm, account);
        um.cooldown = mm.accountAssets(account) + MARKET_COOLDOWN_LENGTH;
        um.tokens = tokens;
    }

    function _buildDynamicMarketToken(
        ICToken ctoken
    ) internal view returns (DynamicMarketToken memory dmt) {
        address asset = ctoken.asset();

        dmt._address = address(ctoken);
        dmt.assetPrice = getPriceOnly(address(asset), true, false);
        dmt.assetPriceLower = getPriceOnly(address(asset), true, true);
        dmt.sharePrice = getPriceOnly(address(ctoken), true, false);
        dmt.sharePriceLower = getPriceOnly(address(ctoken), true, true);
        dmt.totalSupply = ctoken.totalSupply();
        dmt.collateral = ctoken.marketCollateralPosted();

        if(ctoken.isBorrowable()) {
            IBorrowableCToken bcToken = IBorrowableCToken(address(ctoken));
            uint256 assetsHeld = bcToken.assetsHeld();
            IDynamicIRM irm = bcToken.IRM();

            dmt.debt = bcToken.marketOutstandingDebt();
            dmt.liquidity = assetsHeld - dmt.debt;

            // All of these values are multiplied depending on the time frame you are looking for.
            // For example you might multiply this by SECONDS_PER_YEAR to get an annualized rate.
            dmt.borrowRate = irm.borrowRate(assetsHeld, dmt.debt);
            dmt.predictedBorrowRate = irm.predictedBorrowRate(assetsHeld, dmt.debt);
            dmt.utilizationRate = irm.utilizationRate(assetsHeld, dmt.debt);
            dmt.supplyRate = irm.supplyRate(assetsHeld, dmt.debt, bcToken.interestFee());
        }
    }

    function _buildDynamicMarketData(
        IMarketManager mm
    ) internal view returns (DynamicMarketData memory dmd) {
        address[] memory tokenAddresses = mm.queryTokensListed();
        DynamicMarketToken[] memory tokens = new DynamicMarketToken[](tokenAddresses.length);

        for (uint256 i; i < tokenAddresses.length; ++i) {
            ICToken ctoken = ICToken(tokenAddresses[i]);
            DynamicMarketToken memory dmToken = _buildDynamicMarketToken(ctoken);
            tokens[i] = dmToken;
        }

        dmd._address = address(mm);
        dmd.tokens = tokens;
    }

    /// @dev Returns `floor(x * y / d)`.
    /// Reverts if `x * y` overflows, or `d` is zero.
    function _mulDiv(
        uint256 x,
        uint256 y,
        uint256 d
    ) internal pure returns (uint256 z) {
        z = FixedPointMathLib.mulDiv(x, y, d);
    }

    function _getOracleManager() internal view returns (IOracleManager) {
        return CommonLib._oracleManager(centralRegistry);
    }
}