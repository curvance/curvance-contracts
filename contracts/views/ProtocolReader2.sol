// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { MarketManagerIsolated, ICentralRegistry, WAD, WAD_SQUARED, LiquidityManagerIsolated, ICToken, IOracleManager, IMarketManager, FixedPointMathLib, IERC20, ERC165Checker } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { IOracleAdaptor } from "contracts/interfaces/IOracleAdaptor.sol";
import { IVeCVE } from "contracts/interfaces/IVeCVE.sol";

// NOTE: This is a work in progress, don't implement yet.
// TODO: Figure out what to do with tokenDataOf since we have tests attached
contract ProtocolReader2 {
    /// TYPES ///
    struct StaticMarketData {
        address _address;
        uint256[] adapters;
        StaticMarketToken[] tokens;
    }

    struct StaticMarketToken {
        address _address;
        StaticMarketAsset asset;
        uint256[2] adapters;
        bool borrowPaused;
        bool collateralizationPaused;
        bool mintPaused;
        uint256 collateralCap;
        uint256 debtCap;
        LiquidityManagerIsolated.CurvanceToken config;
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
        uint256 tvl;
        DynamicMarketToken[] tokens;
    }

    struct DynamicMarketToken {
        address _address;
        uint256 posted;
        uint256 sharePrice;
        uint256 tokenPrice;
        uint256 tvl;
        uint256 borrowRate;
        uint256 utilizationRate;
        uint256 supplyRate;
        uint256 predicted_supplyRate;
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
        bool hasPosition;
        uint256 tokenAmount;
        uint256 shareAmount;
        uint256 debt;
    }

    /// CONSTANTS ///
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
        IOracleManager router = IOracleManager(
            centralRegistry.oracleManager()
        );

        data = new StaticMarketData[](markets.length);
        for (uint256 i; i < markets.length; i++) {
            MarketManagerIsolated mm = MarketManagerIsolated(markets[i]);

            address[] memory tokenAddresses = mm.queryTokensListed();
            StaticMarketToken[] memory tokens = new StaticMarketToken[](
                tokenAddresses.length
            );

            uint256[] memory uniqueAdapters;
            for (uint256 j; j < tokenAddresses.length; j++) {
                ICToken cToken = ICToken(tokenAddresses[j]);
                IERC20 asset = IERC20(cToken.asset());
                (uint256 oracleA, uint256 oracleB) = _getAdaptorTypes(
                    address(cToken),
                    router
                );

                uniqueAdapters = _addUniqueAdapter(uniqueAdapters, oracleA);
                uniqueAdapters = _addUniqueAdapter(uniqueAdapters, oracleB);

                tokens[j] = StaticMarketToken({
                    _address: address(cToken),
                    asset: StaticMarketAsset({
                        _address: address(asset),
                        name: asset.name(),
                        symbol: asset.symbol(),
                        decimals: asset.decimals(),
                        totalSupply: asset.totalSupply()
                    }),
                    borrowPaused: mm.borrowPaused(address(cToken)) == 2,
                    collateralizationPaused: mm.collateralizationPaused(
                        address(cToken)
                    ) == 2,
                    mintPaused: mm.mintPaused(address(cToken)) == 2,
                    debtCap: mm.debtCaps(address(cToken)),
                    collateralCap: mm.collateralCaps(address(cToken)),
                    config: _convertTokenData(mm, address(cToken)),
                    adapters: [oracleA, oracleB]
                });
            }

            data[i] = StaticMarketData({
                _address: address(mm),
                adapters: uniqueAdapters,
                tokens: tokens
            });
        }
    }

    // TODO: Implement
    // getAllMarketData
    function getDynamicMarketData()
        public
        view
        returns (DynamicMarketData[] memory data)
    {
        // address[] memory markets = centralRegistry.marketManagers();
    }

    // TODO: Implement
    // getAllMarketData
    // getAccountState
    // getUserLocks
    function getUserData(
        address account
    ) public view returns (UserData memory data) {
        // Load locks
        // (data.locks, ) = IVeCVE(centralRegistry.veCVE()).queryUserLocks(
        //     account
        // );

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

            uint256 collRatio = mm.collateralizationRatio(cToken);
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

    /// INTERNAL FUNCTIONS ///

    /// @notice Copies a CurvanceToken from contract as CurvanceToken struct,
    /// for whatever reason this is needed since its a compilation error to just fetch mm.tokenData(cToken) as the CurvanceToken struct
    /// @param mm The market manager
    /// @param cToken The address of the cToken to convert
    /// @return config A instance of the CurvanceToken struct
    function _convertTokenData(
        MarketManagerIsolated mm,
        address cToken
    )
        internal
        view
        returns (LiquidityManagerIsolated.CurvanceToken memory config)
    {
        // I tried setting config directly in this tuple, but hit a compilation error
        (
            bool isListed,
            uint256 collRatio,
            uint256 collReqSoft,
            uint256 collReqHard,
            uint256 liqIncBase,
            uint256 liqIncCurve,
            uint256 liqIncMin,
            uint256 liqIncMax,
            uint256 closeFactorBase,
            uint256 closeFactorCurve,
            uint256 closeFactorMin,
            uint256 closeFactorMax
        ) = mm.tokenData(cToken);

        // So here we are.
        config.isListed = isListed;
        config.collRatio = uint80(collRatio);
        config.collReqSoft = uint80(collReqSoft);
        config.collReqHard = uint80(collReqHard);
        config.liqIncBase = uint64(liqIncBase);
        config.liqIncCurve = uint64(liqIncCurve);
        config.liqIncMin = uint64(liqIncMin);
        config.liqIncMax = uint64(liqIncMax);
        config.closeFactorBase = uint64(closeFactorBase);
        config.closeFactorCurve = uint64(closeFactorCurve);
        config.closeFactorMin = uint64(closeFactorMin);
        config.closeFactorMax = uint64(closeFactorMax);
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
}
