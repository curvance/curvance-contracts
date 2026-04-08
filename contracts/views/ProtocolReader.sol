// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { CommonLib } from "contracts/libraries/CommonLib.sol";
import { BPS, WAD, BAD_SOURCE, SECONDS_PER_YEAR } from "contracts/libraries/ConstantsLib.sol";
import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";

import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { ICToken, AccountSnapshot } from "contracts/interfaces/ICToken.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { IOracleAdaptor } from "contracts/interfaces/IOracleAdaptor.sol";
import { IVeCVE } from "contracts/interfaces/IVeCVE.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IDynamicIRM } from "contracts/interfaces/IDynamicIRM.sol";
import { DynamicIRM } from "contracts/market/DynamicIRM.sol";

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
        uint256 maxLeverage;
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
        uint256 irmTargetRate;
        uint256 irmMaxRate;
        uint256 irmTargetUtilization;
        uint256 interestFee;
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
        uint256 exchangeRate;
        uint256 totalAssets;
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
        bool errorCodeHit;
        UserMarketToken[] tokens;
    }

    struct UserMarketToken {
        address _address;
        uint256 userAssetBalance;
        uint256 userShareBalance;
        uint256 userUnderlyingBalance;
        uint256 userCollateral;
        uint256 userDebt;
        uint256 liquidationPrice;
    }

    /// @notice Data structure returned on hypothetical calculation containing
    ///         whether there was a collateral surplus or a liquidity deficit,
    ///         and whether account positions need to be updated.
    /// @param collateral Total value of `account`'s collateral across
    ///                    all positions.
    /// @param maxDebt The maximum amount of debt `account` could take
    ///                on based on `collateral`.
    /// @param debt Total value of `account`'s current outstanding debt
    ///             across all positions.
    /// @param collateralSurplus Excess collateral when adjusted for debt
    ///                          obligations.
    /// @param liquidityDeficit Liquidity deficit when adjusted for debt
    ///                         obligations.
    /// @param loanSizeError Whether the desired loan size is insufficient
    ///                      causing an error.
    /// @param oracleError Whether an oracle error was hit when pricing assets.
    struct HypotheticalResult {
        uint256 collateral;
        uint256 maxDebt;
        uint256 debt;
        uint256 collateralSurplus;
        uint256 liquidityDeficit;
        bool loanSizeError;
        bool oracleError;
    }

    /// CONSTANTS ///

    /// @notice Minimum loan size allowed inside Curvance that can be created
    ///         from a new line of credit inside a market.
    /// @dev This restriction is to minimize the potential of debt positions
    ///      being created that cannot not be profitably closed.
    uint256 public constant MIN_ACTIVE_LOAN_SIZE = 10e18;
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

    /// @param cr The address of the Protocol Central Registry.
    constructor(ICentralRegistry cr) {
        CentralRegistryLib._isCentralRegistry(cr);
        centralRegistry = cr;
    }

    /// PUBLIC FUNCTIONS ///



    function getAllDynamicState(address account) external view returns (
        DynamicMarketData[] memory market,
        UserData memory user
    ) {
        return (getDynamicMarketData(), getUserData(account));
    }

    function getStaticMarketData()
        external
        view
        returns (StaticMarketData[] memory data)
    {
        address[] memory markets = centralRegistry.marketManagers();
        IOracleManager om = _getOracleManager();

        data = new StaticMarketData[](markets.length);
        uint256 numMarkets = markets.length;
        for (uint256 i; i < numMarkets; ++i) {
            IMarketManager mm = IMarketManager(markets[i]);

            address[] memory tokenAddresses = mm.queryTokensListed();
            uint256 numTokens = tokenAddresses.length;
            StaticMarketToken[] memory tokens = new StaticMarketToken[](
                numTokens
            );

            uint256[] memory uniqueAdapters;
            for (uint256 j; j < numTokens; ++j) {
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
        if (errorCode == BAD_SOURCE) {
            price = 0;
        }
    }

    function getPriceSafely(
        address asset,
        bool inUSD,
        bool getLower,
        uint256 errorCodeBreakpoint
    ) public view returns (uint256) {
        (uint256 price, uint256 errorCode) = _getOracleManager()
            .getPrice(asset, inUSD, getLower);
        if (errorCode >= errorCodeBreakpoint) {
            revert ProtocolReader__PriceError();
        }

        return price;
    }

    function getDynamicMarketData()
        public
        view
        returns (DynamicMarketData[] memory data)
    {
        address[] memory markets = centralRegistry.marketManagers();
        uint256 numMarkets = markets.length;
        data = new DynamicMarketData[](numMarkets);
        for (uint256 i; i < numMarkets; ++i) {
            data[i] = _buildDynamicMarketData(IMarketManager(markets[i]));
        }
    }

    /// @notice Gets the Position health of `account` inside a market (`mm`).
    /// @param mm The market manager to pull data from.
    /// @param account The user address to get the position health of.
    /// @param cToken Optional collateral token for a hypothetical action.
    /// @param borrowableCToken Optional debt token for a hypothetical action.
    /// @param isDeposit Whether `collateralAssets` is for a deposit (true) or
    ///                  redemption (false).
    /// @param collateralAssets The amount of assets for a hypothetical action
    ///                         with `cToken`.
    /// @param isRepayment Whether `debtAssets` is for a repayment (true) or
    ///                    borrow (false).
    /// @param debtAssets The amount of assets for a hypothetical action with
    ///                   `borrowableCToken`.
    /// @param bufferTime Any additional time buffer debt accrual is expected
    ///                   before a user's action, in seconds.
    /// @return positionHealth The healthiness of `account`'s position inside
    ///                        `mm`.
    /// @return errorCodeHit Whether an error code was hit or not, which
    ///                      would provide incorrect Position Health.
    function getPositionHealth(
        IMarketManager mm,
        address account,
        address cToken,
        address borrowableCToken,
        bool isDeposit,
        uint256 collateralAssets,
        bool isRepayment,
        uint256 debtAssets,
        uint256 bufferTime
    ) public view returns (uint256 positionHealth, bool errorCodeHit) {
        uint256 soft;
        uint256 debt;
        uint256 tempValue;
        // We use isAuction = true to grab pessimistic position health value.
        (soft, , debt, , errorCodeHit) =
            liquidationValuesOf(mm, account, true);

        if (mm.isListed(cToken) && collateralAssets != 0) {
            tempValue = _collateralValue(cToken, collateralAssets);
            (, uint256 collReqSoft,) = _collConfig(mm, cToken);
            if (collReqSoft != 0) {
                tempValue = _mulDiv(tempValue, BPS, collReqSoft);
                if (tempValue > soft && !isDeposit) {
                    errorCodeHit = true;
                } else {
                    soft = isDeposit ? soft + tempValue : soft - tempValue;
                }
            }
        }

        if (mm.isListed(borrowableCToken) && debtAssets != 0) {
            if (debtAssets == type(uint256).max) {
                debtAssets = debtBalanceAtTimestamp(account, borrowableCToken, block.timestamp + bufferTime);
            }

            tempValue = _debtValue(borrowableCToken, debtAssets);
            if (
                debtBalanceAtTimestamp(account, borrowableCToken, block.timestamp + bufferTime) <
                debtAssets && isRepayment
            ) {
                errorCodeHit = true;
            } else {
                debt = isRepayment ? debt - tempValue : debt + tempValue;
            }
        }

        if (debt == 0) {
            positionHealth = type(uint256).max;
        } else {
            positionHealth = (soft * WAD) / debt;
        }
    }

    function getLiquidationPrice(
        address account,
        address cToken,
        bool long
    ) public view returns (uint256 price, bool errorHit) {
        MarketManagerIsolated mm =
            MarketManagerIsolated(address(_marketManager(cToken)));
        price = type(uint256).max;
        uint256 amount;
        uint256 offset;
        uint256 currPrice;
        uint256 errorCode;
        address underlying = _asset(cToken);

        // long: price cToken (getLower=true), short: price underlying (getLower=false).
        (currPrice, errorCode) = getPrice(long ? cToken : underlying, true, long);
        if (errorCode == 2) return (price, true);

        // Divergent: offset source and amount source.
        if (long) {
            (, offset,) = _collConfig(mm, cToken);
            amount = _collateralPosted(cToken, account);
        } else {
            offset = BPS;
            amount = debtBalanceAtTimestamp(account, cToken, block.timestamp);
        }

        // Shared: normalize amount to WAD precision.
        amount = FixedPointMathLib.fullMulDiv(
            amount, WAD, 10 ** _decimals(underlying)
        );

        if (amount == 0 || !mm.isListed(cToken)) {
            return (price, false);
        }

        uint256 margin;
        uint256 debt;
        // We use isAuction = true to grab pessimistic liquidation values.
        (margin, , debt, , errorHit) = liquidationValuesOf(mm, account, true);

        if (debt == 0) return (price, false);
        if (errorHit) return (price, errorHit);

        uint256 buffer = mm.AUCTION_BUFFER();

        // Compute absolute distance and direction, single fullMulDiv call.
        bool marginExceedsDebt = margin > debt;
        uint256 LHS = FixedPointMathLib.fullMulDiv(
            marginExceedsDebt ? margin - debt : debt - margin,
            offset * WAD,
            amount * buffer
        );

        // long+surplus = price drops to liquidation; long+deficit = already past it.
        price = (long == marginExceedsDebt) ? currPrice - LHS : currPrice + LHS;
    }

    function getUserData(
        address account
    ) public view returns (UserData memory data) {
        if(centralRegistry.veCVE() != address(0)) {
            (uint256[] memory lockAmounts, uint256[] memory lockTimestamps) =
                IVeCVE(centralRegistry.veCVE()).queryUserLocks(account);
            uint256 numLocks = lockAmounts.length;
            data.locks = new UserLock[](numLocks);
            for (uint256 i; i < numLocks; ++i) {
                data.locks[i] = UserLock({
                    lockIndex: i,
                    amount: lockAmounts[i],
                    unlockTime: lockTimestamps[i]
                });
            }
        }

        address[] memory markets = centralRegistry.marketManagers();
        uint256 numMarkets = markets.length;
        data.markets = new UserMarket[](numMarkets);
        for (uint256 i; i < numMarkets; ++i) {
            data.markets[i] =
                _buildUserMarket(MarketManagerIsolated(markets[i]), account);
        }
    }

    /// @notice Determine the maximum amount of `cTokenRedeemed` that `account`
    ///         can redeem.
    /// @param account The account to determine redemptions for.
    /// @param cTokenRedeemed The cToken to redeem.
    /// @param bufferTime Any additional time buffer debt accrual is expected
    ///                   before a user's action, in seconds.
    /// @return collateralizedSharesRedeemable The amount of collateralized `cTokenModified`
    ///                                        shares redeemable by `account`.
    /// @return uncollateralizedShares The amount of uncollateralized `cTokenModified`
    ///                                shares redeemable by `account`.
    /// @return oracleError Whether an oracle error was hit when pricing assets.
    function maxRedemptionOf(
        address account,
        address cTokenRedeemed,
        uint256 bufferTime
    ) external view returns (
        uint256 collateralizedSharesRedeemable,
        uint256 uncollateralizedShares,
        bool oracleError
    ) {
        IMarketManager mm = _marketManager(cTokenRedeemed);

        // Make sure they are not trying to hypothetically redeem
        // a token they are borrowing, not trying to redeem 0 shares, or
        // redeem an unlisted token.
        if (!mm.isListed(cTokenRedeemed)) {
            return(0, 0, true);
        }

        HypotheticalResult memory r =
            hypotheticalLiquidityOf(mm, account, address(0), 0, 0, bufferTime);
        oracleError = r.oracleError;
        collateralizedSharesRedeemable =
            _collateralPosted(cTokenRedeemed, account);
        uncollateralizedShares = _balanceOf(cTokenRedeemed, account) -
            collateralizedSharesRedeemable;
        if (collateralizedSharesRedeemable > 0) {
            (uint256 collRatio,,) = _collConfig(mm, cTokenRedeemed);
            uint256 redemptionDebt = _mulDiv(
                _assetValue(
                    collateralizedSharesRedeemable,
                    getPriceSafely(cTokenRedeemed, true, true, 2),
                    10 ** _decimals(cTokenRedeemed),
                    true
                ),
                collRatio,
                BPS
            );

            if (r.debt + redemptionDebt > r.maxDebt) {
                // If the account is already at or above debt cap no collateral
                // can be redeemed.
                if (r.debt >= r.maxDebt) {
                    collateralizedSharesRedeemable = 0;
                } else {
                    // Else calculate partial redemption.
                    collateralizedSharesRedeemable = _mulDiv(
                        collateralizedSharesRedeemable,
                        _mulDiv(r.maxDebt - r.debt, WAD, redemptionDebt),
                        WAD
                    );
                }
            }
        }
    }

    /// @notice Determine what the account liquidity would be if
    ///         the given shares were redeemed.
    /// @param account The account to determine liquidity for.
    /// @param cTokenModified The cToken to hypothetically redeem.
    /// @param redemptionShares The number of shares to hypothetically redeem.
    /// @param bufferTime Any additional time buffer debt accrual is expected
    ///                   before a user's action, in seconds.
    /// @return Hypothetical account liquidity in excess of collateral
    ///         requirements.
    /// @return Hypothetical account liquidity deficit below collateral
    ///         requirements.
    /// @return bool Whether the proposed action is possible. NOTE: NOT
    ///              whether it passes liquidity constraints or not.
    /// @return bool Whether an error code was hit.
    function hypotheticalRedemptionOf(
        address account,
        address cTokenModified,
        uint256 redemptionShares,
        uint256 bufferTime
    ) external view returns (uint256, uint256, bool, bool) {
        IMarketManager mm = _marketManager(cTokenModified);

        // Make sure they are not trying to hypothetically redeem
        // a token they are borrowing, not trying to redeem 0 shares, or
        // redeem an unlisted token.
        if (
            _debtBalance(IBorrowableCToken(cTokenModified), account) > 0 ||
            redemptionShares == 0 || !mm.isListed(cTokenModified)
        ) {
            return(0, 0, false, false);
        }

        HypotheticalResult memory r =
            hypotheticalLiquidityOf(
                mm,
                account,
                cTokenModified,
                redemptionShares,
                0,
                bufferTime
            );
        return (r.collateralSurplus, r.liquidityDeficit, true, r.oracleError);
    }

    /// @notice Determine what the account liquidity would be if
    ///         the given assets were borrowed.
    /// @param account The account to determine liquidity for.
    /// @param borrowableCTokenModified The borrowableCToken to hypothetically
    ///                                 borrow.
    /// @param borrowAssets The number of assets to hypothetically borrow.
    /// @param bufferTime Any additional time buffer debt accrual is expected
    ///                   before a user's action, in seconds.
    /// @return Hypothetical account liquidity in excess of collateral
    ///         requirements.
    /// @return Hypothetical account liquidity deficit below collateral
    ///         requirements.
    /// @return bool Whether the proposed action is possible. NOTE: NOT
    ///              whether it passes liquidity constraints or not.
    /// @return bool Whether the desired loan size is insufficient causing an
    ///              error.
    /// @return bool Whether an error code was hit.
    function hypotheticalBorrowOf(
        address account,
        address borrowableCTokenModified,
        uint256 borrowAssets,
        uint256 bufferTime
    ) external view returns (uint256, uint256, bool, bool, bool) {
        IMarketManager mm = _marketManager(borrowableCTokenModified);

        // Make sure they are not trying to hypothetically redeem
        // a token they are borrowing, not trying to redeem 0 shares, or
        // redeem an unlisted token.
        if (
            _collateralPosted(borrowableCTokenModified, account) > 0 ||
            borrowAssets == 0 || !mm.isListed(borrowableCTokenModified)
        ) {
            return(0, 0, false, false, false);
        }

        HypotheticalResult memory r =
            hypotheticalLiquidityOf(
                mm,
                account,
                borrowableCTokenModified,
                0,
                borrowAssets,
                bufferTime
            );
        return (r.collateralSurplus, r.liquidityDeficit, true, r.loanSizeError, r.oracleError);
    }

    /// @notice Calculates the hypothetical maximum amount of
    ///         `borrowableCToken` assets `account` can borrow for maximum
    ///         leverage based on a new `cToken` collateralized deposit.
    /// @dev NOTE: This can overestimate maximum executeable leverage when
    ///            swapping due to AMM fees and slippage.
    /// @param account The account to query maximum borrow amount for.
    /// @param cToken The token that `account` will deposit to leverage
    ///               against.
    /// @param borrowableCToken The token that `account` will borrow assets
    ///                         from to achieve leverage.
    /// @param assets The amount of `cToken` underlying that `account` will
    ///               deposit to leverage against.
    /// @param bufferTime Any additional time buffer debt accrual is expected
    ///                   before a user's action, in seconds.
    /// @return currentLeverage Returns the current leverage multiplier of
    ///                         `account`, in `WAD`.
    /// @return adjustedMaxLeverage Returns the maximum leverage multiplier of
    ///                             `account` after a hypothetical deposit
    ///                             action, adjusted by liquidity constraints,
    ///                             in `WAD`.
    /// @return maxLeverage Returns the maximum leverage multiplier of
    ///                     `account` after a hypothetical deposit action,
    ///                     in `WAD`.
    /// @return maxDebtBorrowable Returns the maximum remaining borrow amount
    ///                           allowed from `borrowableCToken`, measured in
    ///                           underlying token amount, after the new
    ///                           hypothetical deposit.
    /// @return loanSizeError Whether the desired loan size is insufficient
    ///                       causing an error.
    /// @return oracleError Whether an oracle error was hit when pricing assets.
    function hypotheticalLeverageOf(
        address account,
        address cToken,
        address borrowableCToken,
        uint256 assets,
        uint256 bufferTime
    ) external view returns (
        uint256 currentLeverage,
        uint256 adjustedMaxLeverage,
        uint256 maxLeverage,
        uint256 maxDebtBorrowable,
        bool loanSizeError,
        bool oracleError
    ) {
        IMarketManager mm = _marketManager(borrowableCToken);

        // Validate `cToken` and `borrowableCToken` are properly listed.
        if (!mm.isListed(borrowableCToken) || !mm.isListed(cToken)) {
            revert ProtocolReader__TokenNotListed();
        }

        HypotheticalResult memory r =
            hypotheticalLiquidityOf(mm, account, address(0), 0, 0, bufferTime);
        loanSizeError = r.loanSizeError;
        oracleError = r.oracleError;
        // If the account is insolvent or we can immediately return with 0 for
        // everything.
        if (r.debt > r.collateral) {
            return (0, 0, 0, 0, false, false);
        }

        if (r.debt == 0 || r.collateral == 0) {
            currentLeverage = WAD;
        } else {
            currentLeverage =
                _mulDiv(r.collateral, WAD, r.collateral - r.debt);
        }

        {
            (uint256 collRatio,,) = _collConfig(mm, address(cToken));
            // If the collateral token cannot be borrowed against the hypothetical
            // leverage check will result in 0 meaning nothing new to leverage
            // against.
            if (collRatio == 0) {
                revert ProtocolReader__NonCollateralizable();
            }

            uint256 newCollateral = _collateralValue(cToken, assets);
            r.collateral += newCollateral;
            r.maxDebt += _mulDiv(newCollateral, collRatio, BPS);
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
        maxDebtBorrowable = _mulDiv(
            r.maxDebt - r.debt,
            r.collateral,
            r.collateral - r.maxDebt
        );

        // Calculate the theoretical maximum leverage.
        maxLeverage = _mulDiv(
            r.collateral + maxDebtBorrowable,
            WAD,
            r.collateral - r.debt
        );

        // Convert maxDebtBorrowable, currently in WAD, to assets denomination.
        maxDebtBorrowable = _mulDiv(
            maxDebtBorrowable,
            10 ** _decimals(borrowableCToken),
            getPriceSafely(_asset(borrowableCToken), true, false, 1)
        );

        // Adjust for market limitations (caps, liquidity).
        maxDebtBorrowable = _adjustForLimitations(
            mm,
            cToken,
            ICToken(cToken).previewDeposit(assets),
            borrowableCToken,
            maxDebtBorrowable
        );

        // If theres no ability to borrow then can return adjusted leverage of 0.
        // Also convert adjusted maxDebtBorrowable back to WAD from assets denomination.
        if (maxDebtBorrowable > 0) {
            // Calculate the real maximum leverage.
            adjustedMaxLeverage = _mulDiv(
                r.collateral + _debtValue(borrowableCToken, maxDebtBorrowable),
                WAD,
                r.collateral - r.debt
            );
        }
    }

    /// @notice Returns the debt balance of `account` at `timestamp`.
    /// @dev This function is intended for frontend data querying and should
    ///      not be used for onchain execution.
    /// @param account The address whose debt balance should be calculated.
    /// @param borrowableCToken The token that `account`'s debt balance
    ///                         will be checked for.
    /// @param timestamp The unix timestamp to calculate account debt
    ///                  balance with.
    /// @return debtBalance The debt balance of `account` at `timestamp`.
    function debtBalanceAtTimestamp(
        address account,
        address borrowableCToken,
        uint256 timestamp
    ) public view returns (uint256 debtBalance) {
        IBorrowableCToken bcToken = IBorrowableCToken(borrowableCToken);
        debtBalance = _debtBalance(bcToken, account);

        // If `account` has no debt its still going to be 0 at `timestamp`.
        if (debtBalance == 0) {
            return 0;
        }

        // Pull latest yield information.
        (uint256 rate, uint256 vestingEnd, uint256 lastVestingClaim, ) =
            bcToken.getYieldInformation();

        // If `timestamp` is before block.timestamp, use `block.timestamp`.
        timestamp = timestamp < block.timestamp ? block.timestamp : timestamp;

        // If no time has passed since `lastVestingClaim` can return
        // `debtBalance`.
        if (timestamp == lastVestingClaim) {
            return debtBalance;
        }

        uint256 newDebt;

        // Check whether there is pending debt owed.
        if (rate > 0 && lastVestingClaim < vestingEnd) {
            // When calculating pending debt owed, if the vesting period
            // has not ended:
            // newDebt = rate * (timestamp - lastVestingClaim).
            // If the vesting period has ended:
            // newDebt = rate * (vestingEnd - lastVestingClaim)).
            // Then in either case:
            // Divide the pending debt by `WAD` (1e18) for precision.
            newDebt = _mulDiv(
                timestamp < vestingEnd
                    ? rate * (timestamp - lastVestingClaim)
                    : rate * (vestingEnd - lastVestingClaim),
                debtBalance,
                WAD
            );
        }

        // Update `lastVestingClaim`, stopping at `vestingEnd` if current
        // vesting period has ended.
        lastVestingClaim = timestamp > vestingEnd ? vestingEnd : timestamp;

        // Check if it is time to start a new vesting period.
        if (timestamp >= vestingEnd) {
            uint256 assetsHeld = _assetsHeld(bcToken);
            uint256 outstandingDebt = _outstandingDebt(bcToken);
            // Calculate the new interest rate for borrowers, in seconds.
            rate = _IRM(bcToken).predictedBorrowRate(assetsHeld, outstandingDebt);
            debtBalance = debtBalance + newDebt;

            newDebt = _mulDiv(
                rate * (timestamp - lastVestingClaim),
                debtBalance,
                WAD
            );
        }

        debtBalance += newDebt;
    }

    /// @notice Returns the cooldown periods for multiple markets for a user
    /// @param markets The list of market addresses
    /// @param user The user address
    /// @return cooldowns The list of cooldown periods for each market
    function marketMultiCooldown(
        address[] calldata markets,
        address user
    ) external view returns (uint256[] memory) {
        uint256 numMarkets = markets.length;
        uint256[] memory cooldowns = new uint256[](numMarkets);
        for (uint256 i; i < numMarkets; ++i) {
            MarketManagerIsolated mm = MarketManagerIsolated(markets[i]);
            uint256 cooldownTimestamp = mm.accountAssets(user);

            cooldowns[i] = cooldownTimestamp + MARKET_COOLDOWN_LENGTH;
        }
        return cooldowns;
    }

    /// @notice Preview the impact of a new asset deposit or borrow on market
    ///         interest rates.
    /// @param user The address of the user account to preview asset impact
    ///             of.
    /// @param collateralCToken The address of the collateral cToken.
    /// @param debtBorrowableCToken The address of the debt borrowable cToken
    /// @param newCollateralAssets The amount of new collateral asset to
    ///                            deposit, in assets.
    /// @param newDebtAssets The amount of new debt asset to borrow,
    ///                      in assets.
    /// @return supply The projected supply rate, in `WAD` seconds.
    /// @return borrow The projected borrow amount, in `WAD` seconds.
    function previewAssetImpact(
        address user,
        address collateralCToken,
        address debtBorrowableCToken,
        uint256 newCollateralAssets,
        uint256 newDebtAssets
    ) external view returns (uint256 supply, uint256 borrow) {
        ICToken cToken = ICToken(collateralCToken);
        IBorrowableCToken bcToken;
        uint256 outstandingDebt;
        uint256 assetsHeld;

        if (cToken.isBorrowable()) {
            bcToken = IBorrowableCToken(address(collateralCToken));
            outstandingDebt = _outstandingDebt(bcToken);
            assetsHeld = _assetsHeld(bcToken) + newCollateralAssets;
            supply = _IRM(bcToken)
                .supplyRate(assetsHeld, outstandingDebt, _interestFee(bcToken));
        }

        bcToken = IBorrowableCToken(debtBorrowableCToken);
        if (_debtBalance(bcToken, user) != 0) {
            outstandingDebt = _outstandingDebt(bcToken);
            assetsHeld = _assetsHeld(bcToken);
            assetsHeld = assetsHeld > newDebtAssets
                ? assetsHeld - newDebtAssets
                : 0;
            borrow = _IRM(bcToken).borrowRate(assetsHeld, outstandingDebt);
        }
    }

    /// @notice Calculates hypothetical liquidity for an account after a
    ///         potential action such as redemption and borrowing.
    /// @param mm The market manager to pull hypothetical liquidity values
    ///           from.
    /// @param account The account to determine liquidity for.
    /// @param cTokenModified The cToken to hypothetically redeem/borrow.
    /// @param redemptionShares The number of tokens to hypothetically redeem,
    ///                         in `shares`.
    /// @param borrowAssets The amount of underlying to hypothetically borrow,
    ///                     in `assets`.
    /// @param bufferTime Any additional time buffer debt accrual is expected
    ///                   before a user's action, in seconds.
    /// @return result Hypothetical results for an action containing:
    ///                collateral Total value of `account`'s collateral across
    ///                           all positions.
    ///                maxDebt The maximum amount of debt `account`
    ///                        could take on based on `collateral`.
    ///                debt Total value of `account`'s current outstanding
    ///                     debt across all positions.
    ///                collateralSurplus Excess collateral capacity after
    ///                                  the action.
    ///                liquidityDeficit Shortfall in collateral capacity after
    ///                                 the action.
    ///                positionClosureNeeded Flag indicating if positions need
    ///                                      to be closed. (0: no, 2: yes)
    ///                loanSizeError Whether the desired loan size is
    ///                              insufficient causing an error.
    ///                oracleError Whether an oracle error was hit when pricing
    ///                            assets.
    function hypotheticalLiquidityOf(
        IMarketManager mm,
        address account,
        address cTokenModified,
        uint256 redemptionShares,
        uint256 borrowAssets,
        uint256 bufferTime
    ) public view returns (HypotheticalResult memory result) {
        AccountSnapshot[] memory snapshots;
        uint256[] memory prices;
        uint256 numAssets;
        (snapshots, prices, numAssets, result.oracleError) =
            _assetDataOf(mm, account, 2);
        AccountSnapshot memory snap;
        uint256 newDebt;

        uint256 collRatio;
        for (uint256 i; i < numAssets; ++i) {
            snap = snapshots[i];

            if (snap.isCollateral) {
                (collRatio,,) = _collConfig(mm, snap.asset);
                uint256 collateralValue = _assetValue(
                    snap.collateralPosted,
                    prices[i],
                    10 ** snap.decimals,
                    true
                );
                result.collateral += collateralValue;
                result.maxDebt += _mulDiv(
                    collateralValue,
                    collRatio,
                    BPS
                );
            } else {
                // Update debt balance for `account` if necessary.
                snap.debtBalance =
                    debtBalanceAtTimestamp(account, snap.asset, block.timestamp + bufferTime);
                // If they have a debt balance, increment their debt.
                if (snap.debtBalance > 0) {
                    result.debt += _assetValue(
                        snap.debtBalance,
                        prices[i],
                        10 ** snap.decimals,
                        false
                    );
                }
            }

            // Calculate impact of cTokenModified action.
            if (cTokenModified == snap.asset) {
                // If the token is collateral it cannot also be debt position,
                // but, on a fresh borrow position snapshot can misreport
                // a debt position as collateral until its fully opened
                // because debtBalance still equals 0 at getSnapshot level.
                if (snap.isCollateral && borrowAssets == 0) {
                    (collRatio,,) = _collConfig(mm, snap.asset);
                    // Hypothetical redemption action, decreasing collateral
                    // or more simply adding new debt.
                    newDebt += _mulDiv(
                        _assetValue(
                            redemptionShares,
                            prices[i],
                            10 ** snap.decimals,
                            true
                        ),
                        collRatio,
                        BPS
                    );
                } else {
                    if (snap.isCollateral) {
                        prices[i] = getPriceSafely(snap.underlying, true, false, 2);
                    }

                    // Hypothetical borrow action.
                    newDebt += _assetValue(
                        borrowAssets,
                        prices[i],
                        10 ** snap.decimals,
                        false
                    );

                    // Initially, we would worry that newDebt can be
                    // incremented during both borrow and redemption
                    // actions but actions are done in isolation, so if
                    // newDebt is increases here then cTokenModified will
                    // never reach the redemption action block.
                    // This means we can check terminal newDebt value here
                    // and know its only including current and
                    // hypothetical new debt.
                    if (newDebt < MIN_ACTIVE_LOAN_SIZE) {
                        result.loanSizeError = true;
                    }

                    // We don't need to check for closing a position here
                    // since borrow action will only expand a position.
                }
            }
        }

        // Returns excess liquidity on hypothetical positions.
        if (result.maxDebt > newDebt) {
            result.collateralSurplus = result.maxDebt - newDebt;
            return result;
        }

        // Returns shortfall on hypothetical positions.
        result.liquidityDeficit = newDebt - result.maxDebt;
    }

    /// @notice Evaluates collateral and debt positions to determine account
    ///         health and liquidation parameters.
    /// @param mm The market manager to pull liquidation values from.
    /// @param account The address of the account being evaluated for
    ///                liquidation.
    /// @param isAuction Whether the liquidation is an auction or not, if true
    ///        then applies `AUCTION_BUFFER` discount to cSoft/cHard
    ///        indicating a closer/sooner liquidation value.
    /// @return cSoft The account's soft collateral value (collateral
    ///               adjusted by soft requirements).
    /// @return cHard The account's hard collateral value (collateral
    ///               adjusted by hard requirements).
    /// @return debt The account's total debt value.
    /// @return lFactor The value that determines liquidation severity.
    function liquidationValuesOf(
        IMarketManager mm,
        address account,
        bool isAuction
    ) public view returns (
        uint256 cSoft, uint256 cHard, uint256 debt, uint256 lFactor, bool
    ) {
        (
            AccountSnapshot[] memory snapshots,
            uint256[] memory prices,
            uint256 numAssets,
            bool errorCodeHit
        ) = _assetDataOf(mm, account, 2);
        AccountSnapshot memory snap;

        for (uint256 i; i < numAssets; ++i) {
            snap = snapshots[i];

            if (snap.isCollateral) {
                (cSoft, cHard) = _addLiquidationValues(
                    snap,
                    mm,
                    account,
                    prices[i],
                    cSoft,
                    cHard
                );
            } else {
                // If they have a debt balance,
                // we need to document collateral requirements.
                if (snap.debtBalance > 0) {
                    debt += _assetValue(
                        snap.debtBalance,
                        prices[i],
                        10 ** snap.decimals,
                        false
                    );
                }
            }
        }

        if (isAuction) {
            uint256 AUCTION_BUFFER = MarketManagerIsolated(address(mm)).AUCTION_BUFFER();
            if (AUCTION_BUFFER != 0) {
                cSoft = _mulDiv(cSoft, AUCTION_BUFFER, BPS);
                cHard = _mulDiv(cHard, AUCTION_BUFFER, BPS);
            }
        }

        // Get `account` lFactor.
        if (cSoft >= debt) {
            // Indicates no liquidation.
            lFactor = 0;
        } else {
            lFactor = debt >= cHard ? WAD // Indicates hard liquidation.
            // Indicates soft liquidation, we round up here in favor of the
            // protocol, we know that we wont run into a value > WAD due to cHard
            // being at least 1 higher than debt.
            : FixedPointMathLib.mulDivUp(debt - cSoft, WAD, cHard - cSoft);
        }

        return (cSoft, cHard, debt, lFactor, errorCodeHit);
    }

    function getBalancesOf(
        address[] calldata tokens,
        address account
    ) external view returns (uint256[] memory) {
        uint256 numTokens = tokens.length;
        uint256[] memory balances = new uint256[](numTokens);
        for (uint256 i; i < numTokens; ++i) {
            balances[i] = CommonLib._isNative(tokens[i])
                ? account.balance
                : _balanceOf(tokens[i], account);
        }
        return balances;
    }

    /// INTERNAL FUNCTIONS ///

    /// @dev Returns true if minting is paused for `cToken`.
    function _isMintPaused(
        address cToken,
        IMarketManager mm
    ) internal view returns (bool mp) {
        (mp,,) = mm.actionsPaused(cToken);
    }

    /// @dev Convenience overload — resolves market manager from cToken.
    function _isMintPaused(address cToken) internal view returns (bool mp) {
        mp = _isMintPaused(cToken, _marketManager(cToken));
    }

    /// @notice Calculates and adds soft and hard collateral values for
    ///         liquidation assessment.
    /// @param snap Asset snapshot to calculate asset value from.
    /// @param account The account to query collateral posted for to calculate
    ///                liquidation values off of.
    /// @param price The price of the underlying asset, in `WAD`.
    /// @param softSumPrior The previous sum of soft collateral values.
    /// @param hardSumPrior The previous sum of hard collateral values.
    /// @return softSum The updated sum of soft collateral values.
    /// @return hardSum The updated sum of hard collateral values.
    function _addLiquidationValues(
        AccountSnapshot memory snap,
        IMarketManager mm,
        address account,
        uint256 price,
        uint256 softSumPrior,
        uint256 hardSumPrior
    ) internal view returns (uint256 softSum, uint256 hardSum) {
        address asset = snap.asset;
        (, uint256 collReqSoft, uint256 collReqHard) =
            _collConfig(mm, asset);
        uint256 assetValue = _assetValue(
            _collateralPosted(asset, account),
            price,
            10 ** snap.decimals,
            true
        ) * BPS;

        softSum = softSumPrior + (assetValue / collReqSoft);
        hardSum = hardSumPrior + (assetValue / collReqHard);
    }

    function _getStaticTokenAsset(ICToken cToken) internal view returns (StaticMarketAsset memory a) {
        IERC20 asset = IERC20(_asset(address(cToken)));
        a._address = address(asset);
        a.name =  asset.name();
        a.symbol = asset.symbol();
        a.decimals = uint8(_decimals(address(asset)));
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
        t.decimals = uint8(_decimals(address(cToken)));
        t.asset = _getStaticTokenAsset(cToken);

        t.collateralCap = mm.collateralCaps(address(cToken));
        t.debtCap = mm.debtCaps(address(cToken));

        t.isListed = mm.isListed(address(cToken));
        (t.mintPaused, t.collateralizationPaused, t.borrowPaused) =
            mm.actionsPaused(address(cToken));
        t.isBorrowable = cToken.isBorrowable();
        (t.collRatio, t.collReqSoft, t.collReqHard) = _collConfig(mm, address(cToken));
        t.maxLeverage = _mulDiv(BPS, BPS, BPS - t.collRatio);
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

        if (t.isBorrowable) {
            _getIRMConfig(cToken, t);
        }
    }

    /// @notice Reads IRM curve configuration for a borrowable cToken.
    /// @dev Separated from `_getStaticTokenConfig` to avoid stack-too-deep.
    /// @param cToken The borrowable cToken to read IRM config from.
    /// @param t The StaticMarketToken struct to populate.
    function _getIRMConfig(
        ICToken cToken,
        StaticMarketToken memory t
    ) internal view {
        IBorrowableCToken bcToken = IBorrowableCToken(address(cToken));
        DynamicIRM irm = DynamicIRM(address(_IRM(bcToken)));

        (
            uint64 targetRateBase,
            uint64 maxRateBase,
            uint64 targetUtilization,
            ,,,,,  // increaseThresholdStart, decreaseThresholdEnd,
                   // adjustmentVelocity, decayPerAdjustment,
                   // vertexMultiplierMax, linkedToken
        ) = irm.ratesConfig();

        t.irmTargetRate = _mulDiv(
            uint256(targetRateBase) * SECONDS_PER_YEAR,
            uint256(targetUtilization),
            WAD
        );
        t.irmMaxRate = t.irmTargetRate + _mulDiv(
            uint256(maxRateBase) * SECONDS_PER_YEAR,
            WAD - uint256(targetUtilization),
            WAD
        );
        t.irmTargetUtilization = uint256(targetUtilization);
        t.interestFee = _interestFee(bcToken);
    }

    /// @notice Adds an newAdapter to the existingAdapters if it doesn't already exist
    /// @param existingAdapters A list of adapters for the market
    /// @param newAdapter The adapter value to add
    /// @return allAdapters The potentially expanded array
    function _addUniqueAdapter(
        uint256[] memory existingAdapters,
        uint256 newAdapter
    ) internal pure returns (uint256[] memory allAdapters) {
        uint256 len = existingAdapters.length;
        allAdapters = new uint256[](len + 1);
        for (uint256 i; i < len; ++i) {
            if (existingAdapters[i] == newAdapter) {
                return existingAdapters; // Already exists, return original
            }
            allAdapters[i] = existingAdapters[i];
        }

        // Doesn't exist, so we add it to the end
        allAdapters[len] = newAdapter;
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
        address cTokenUnderlying = om.cTokens(asset);
        if (cTokenUnderlying != address(0)) {
            asset = cTokenUnderlying;
        }

        address[] memory adaptors = om.getPricingAdaptors(asset);

        uint256 numAdaptors = adaptors.length;
        if (numAdaptors == 0) {
            return (0, 0);
        }

        address adaptor;

        // If the asset only has one price feed, we know it will be in
        // feed slot 0 so get both prices and return
        if (numAdaptors < 2) {
            adaptor = adaptors[0];
            if (!om.isApprovedAdaptor(adaptor)) {
                return (0, 0);
            }

            return (IOracleAdaptor(adaptor).adaptorType(), 0);
        }

        adaptor = adaptors[0];
        uint256 adaptorTypeA = om.isApprovedAdaptor(adaptor)
            ? IOracleAdaptor(adaptor).adaptorType()
            : 0;

        adaptor = adaptors[1];
        uint256 adaptorTypeB = om.isApprovedAdaptor(adaptor)
            ? IOracleAdaptor(adaptor).adaptorType()
            : 0;

        return (adaptorTypeA, adaptorTypeB);
    }

    function _buildUserMarketToken(
        address tokenAddress,
        address account
    ) internal view returns (UserMarketToken memory umt) {
        ICToken cToken = ICToken(tokenAddress);
        IERC20 underlying = IERC20(_asset(tokenAddress));
        uint256 shares = _balanceOf(tokenAddress, account);

        umt._address = tokenAddress;
        umt.userAssetBalance = cToken.convertToAssets(shares);
        umt.userShareBalance = shares;
        umt.userUnderlyingBalance = _balanceOf(address(underlying), account);
        umt.userDebt = cToken.isBorrowable() ? _debtBalance(IBorrowableCToken(address(cToken)), account) : 0;
        umt.userCollateral = _collateralPosted(address(cToken), account);
        (umt.liquidationPrice, ) = getLiquidationPrice(
            account,
            tokenAddress,
            umt.userCollateral > 0
        );
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

        HypotheticalResult memory r =
            hypotheticalLiquidityOf(mm, account, address(0), 0, 0, 0);
        um.collateral = r.collateral;
        um.maxDebt = r.maxDebt;
        um.debt = r.debt;
        um.errorCodeHit = r.oracleError;

        um._address = address(mm);
        // Get position health without any hypothetical changes.
        (um.positionHealth, um.errorCodeHit) =
            getPositionHealth(mm, account, address(0), address(0), false, 0, false, 0, 0);
        um.cooldown = mm.accountAssets(account) + MARKET_COOLDOWN_LENGTH;
        um.tokens = tokens;
    }

    function _buildDynamicMarketToken(
        ICToken ctoken
    ) internal view returns (DynamicMarketToken memory dmt) {
        address asset = _asset(address(ctoken));

        dmt._address = address(ctoken);
        dmt.assetPrice = getPriceSafely(address(asset), true, false, 3);
        dmt.assetPriceLower = getPriceSafely(address(asset), true, true, 3);
        dmt.sharePrice = getPriceSafely(address(ctoken), true, false, 3);
        dmt.sharePriceLower = getPriceSafely(address(ctoken), true, true, 3);
        dmt.totalSupply = ctoken.totalSupply();
        dmt.exchangeRate = ctoken.exchangeRate();
        dmt.totalAssets = ctoken.totalAssets();
        dmt.collateral = ctoken.marketCollateralPosted();

        if(ctoken.isBorrowable()) {
            IBorrowableCToken bcToken = IBorrowableCToken(address(ctoken));
            uint256 assetsHeld = _assetsHeld(bcToken);
            IDynamicIRM irm = _IRM(bcToken);

            dmt.debt = _outstandingDebt(bcToken);
            dmt.liquidity = assetsHeld;

            // Values are given in seconds, and should be multiplied depending
            // on the time frame needed. For example, you might multiply these
            // by SECONDS_PER_YEAR to get an annualized rate.
            dmt.borrowRate = irm.borrowRate(assetsHeld, dmt.debt);
            dmt.predictedBorrowRate = irm.predictedBorrowRate(assetsHeld, dmt.debt);
            dmt.utilizationRate = irm.utilizationRate(assetsHeld, dmt.debt);
            dmt.supplyRate = irm.supplyRate(assetsHeld, dmt.debt, _interestFee(bcToken));
        }
    }

    function _buildDynamicMarketData(
        IMarketManager mm
    ) internal view returns (DynamicMarketData memory dmd) {
        address[] memory tokenAddresses = mm.queryTokensListed();
        uint256 numTokens = tokenAddresses.length;
        DynamicMarketToken[] memory tokens = new DynamicMarketToken[](numTokens);

        for (uint256 i; i < numTokens; ++i) {
            ICToken ctoken = ICToken(tokenAddresses[i]);
            DynamicMarketToken memory dmToken = _buildDynamicMarketToken(ctoken);
            tokens[i] = dmToken;
        }

        dmd._address = address(mm);
        dmd.tokens = tokens;
    }

    /// @notice Calculates the debt borrowable from `debtCToken` based on
    ///         any current restrictions.
    /// @param mm The market manager to pull token config from.
    /// @param collateralCToken The token that `account` will deposit to
    ///                         leverage against.
    /// @param collateralShares The amount of `cToken` shares that `account`
    ///                          will deposit to leverage against.
    /// @param debtCToken The token that `account` will borrow assets
    ///                   from to achieve leverage.
    /// @param debtAssets The amount of `debtCToken` underlying that
    ///               `account` will borrow to leverage up.
    function _adjustForLimitations(
        IMarketManager mm,
        address collateralCToken,
        uint256 collateralShares,
        address debtCToken,
        uint256 debtAssets
    ) internal view returns (uint256) {
        uint256 collateralCap = mm.collateralCaps(collateralCToken);
        uint256 marketCollateral = ICToken(collateralCToken).marketCollateralPosted();
        uint256 debtCap = mm.debtCaps(debtCToken);
        uint256 marketDebt = _outstandingDebt(IBorrowableCToken(debtCToken));
        uint256 cTokenPrice = getPriceSafely(address(collateralCToken), true, true, 1);
        uint256 debtTokenPrice = getPriceSafely(_asset(debtCToken), true, false, 1);
        uint256 debtAssetsInCollateral =
            ((debtAssets * debtTokenPrice * (10 ** _decimals(collateralCToken))) /
                (cTokenPrice * (10 ** _decimals(debtCToken))));

        // If theres insufficient collateral room left we will need to adjust collateral
        // and debt down proportionally.
        if (marketCollateral + collateralShares + debtAssetsInCollateral > collateralCap) {
            // If the user cannot collateralize the shares they want to deposit
            // can bubble up that leverage is not possible.
            if (marketCollateral + collateralShares > collateralCap) {
                return 0;
            }

            uint256 collateralShortfall = marketCollateral + collateralShares
                + debtAssetsInCollateral - collateralCap;
            debtAssets = _mulDiv(
                debtAssets,
                debtAssetsInCollateral - collateralShortfall,
                debtAssetsInCollateral
            );
        }

        if (marketDebt + debtAssets > debtCap) {
            debtAssets = _mulDiv(debtAssets, debtCap - marketDebt, debtAssets);
        }

        uint256 liquidityAvailable = _assetsHeld(IBorrowableCToken(debtCToken));
        if (liquidityAvailable < debtAssets) {
            debtAssets = liquidityAvailable;
        }

        return debtAssets;
    }

    /// @notice Retrieves the prices and account data of multiple assets
    ///         inside this market.
    /// @param account The account to retrieve data for.
    /// @param errorCodeBreakpoint The error code that will cause liquidity
    ///                            operations to revert.
    /// @return Assets data for `account`.
    /// @return Prices for `account` assets.
    /// @return The number of assets `account` is in.
    function _assetDataOf(
        IMarketManager mm,
        address account,
        uint256 errorCodeBreakpoint
    ) internal view returns (
        AccountSnapshot[] memory,
        uint256[] memory,
        uint256,
        bool errorCodeHit
    ) {
        address[] memory assets = mm.assetsOf(account);
        uint256 numAssets = assets.length;
        AccountSnapshot[] memory snapshots = new AccountSnapshot[](numAssets);
        uint256[] memory prices = new uint256[](numAssets);

        address asset;
        uint256 errorCode;
        for (uint256 i; i < numAssets; ++i) {
            asset = assets[i];
            snapshots[i] = ICToken(asset).getSnapshot(account);

            if (snapshots[i].isCollateral) {
                (prices[i], errorCode) = getPrice(snapshots[i].underlying, true, true);
                prices[i] = (prices[i] * ICToken(asset).exchangeRate()) / WAD;
            } else {
                (prices[i], errorCode) = getPrice(snapshots[i].underlying, true, false);
            }

            if (errorCode >= errorCodeBreakpoint && !errorCodeHit) {
                errorCodeHit = true;
            }

        }

        return (snapshots, prices, numAssets, errorCodeHit);
    }

    function _marketManager(
        address cToken
    ) internal view returns (IMarketManager mm) {
        mm = ICToken(cToken).marketManager();
    }

    function _collateralPosted(
        address cToken,
        address account
    ) internal view returns (uint256 shares) {
        shares = ICToken(cToken).collateralPosted(account);
    }

    function _collConfig(
        IMarketManager mm,
        address cToken
    ) internal view returns (uint256 collRatio, uint256 collReqSoft, uint256 collReqHard) {
        (collRatio, collReqSoft, collReqHard) = mm.collConfig(cToken);
    }

    function _asset(address token) internal view returns (address result) {
        result = ICToken(token).asset();
    }

    function _decimals(address token) internal view returns (uint256 result) {
        result = ICToken(token).decimals();
    }

    function _assetsHeld(
        IBorrowableCToken token
    ) internal view returns (uint256 result) {
        result = token.assetsHeld();
    }

    function _outstandingDebt(
        IBorrowableCToken token
    ) internal view returns (uint256 result) {
        result = token.marketOutstandingDebt();
    }

    function _debtBalance(
        IBorrowableCToken token,
        address account
    ) internal view returns (uint256 result) {
        result = token.debtBalance(account);
    }

    function _interestFee(
        IBorrowableCToken token
    ) internal view returns (uint256 result) {
        result = token.interestFee();
    }

    function _IRM(
        IBorrowableCToken token
    ) internal view returns (IDynamicIRM result) {
        result = token.IRM();
    }

    function _balanceOf(
        address token,
        address account
    ) internal view returns (uint256 result) {
        result = ICToken(token).balanceOf(account);
    }

    /// @notice Calculates collateral value based on `cToken` `assets`,
    ///         querying necessary values like price and decimals.
    /// @param cToken The address of the cToken to calculate collateral value of.
    /// @param assets The amount of underlying `cToken` assets.
    function _collateralValue(
        address cToken,
        uint256 assets
    ) internal view returns(uint256 value) {
        value = _assetValue(
            ICToken(cToken).previewDeposit(assets),
            getPriceSafely(cToken, true, true, 1), // Price `cToken`.
            10 ** _decimals(cToken),
            true
        );
    }

    /// @notice Calculates debt value based on `borrowableCToken` `assets`,
    ///         querying necessary values like price and decimals.
    /// @param borrowableCToken The address of the borrowableCToken to
    ///                         calculate debt value of.
    /// @param assets The amount of underlying `borrowableCToken` assets.
    function _debtValue(
        address borrowableCToken,
        uint256 assets
    ) internal view returns(uint256 value) {
        address underlyingAsset = _asset(borrowableCToken);
        value = _assetValue(
            assets,
            getPriceSafely(underlyingAsset, true, false, 1), // Price `borrowableCToken`.
            10 ** _decimals(underlyingAsset),
            false
        );
    }

    /// @notice Calculates an assets value based on its `price`,
    ///         `amount`, and adjusts for decimals.
    /// @param amount The asset amount to calculate asset value from.
    /// @param price The asset price to calculate asset value from, in `WAD`.
    /// @param decimals The asset decimals to adjust asset value
    ///                 into proper form.
    /// @param increasesCollateral Whether the asset adds positive value or
    ///        not to the liquidity check, we round down when increasing
    ///        collateral value and round up when increasing collateral
    ///        value/increasing debt.
    /// @return The calculated asset value.
    function _assetValue(
        uint256 amount,
        uint256 price,
        uint256 decimals,
        bool increasesCollateral
    ) internal pure returns (uint256) {
        if (increasesCollateral) {
            return _mulDiv(amount, price, decimals);
        }

        return FixedPointMathLib.mulDivUp(amount, price, decimals);
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