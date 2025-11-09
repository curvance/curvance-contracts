// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";
import { WAD, BPS } from "contracts/libraries/ConstantsLib.sol";
import { CommonLib } from "contracts/libraries/CommonLib.sol";

import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { ICToken, AccountSnapshot } from "contracts/interfaces/ICToken.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";

/// @title Curvance Liquidity Manager.
/// @notice Calculates liquidity of an account in various positions.
/// @dev NOTE: Only use this as an abstract contract as no account
///            data is written here.
abstract contract LiquidityManagerIsolated {
    /// TYPES ///

    /// @notice Storage structure for Account data involving liquidity
    ///         positions, and pending redemption cooldown.
    /// @param cooldownTimestamp Timestamp corresponding to when the last time
    ///                          `account` performed a liquidity focused
    ///                          action, which activates a cooldown period on
    ///                          redemptions/repayment/collateral removal.
    /// @param assets Array containing all Curvance tokens an account has
    ///               active liquidity positions in.
    struct AccountData {
        uint256 cooldownTimestamp;
        address[] assets;
    }

    /// @notice Storage configuration for how a Curvance token should behave
    ///         in the liquidity manager.
    /// @param isListed Whether or not this Curvance token is listed.
    /// @dev false = unlisted; true = listed.
    /// @param mintPaused Whether token minting is paused.
    /// @dev Token Address => 0 or 1 = unpaused; 2 = paused.
    /// @param collateralizationPaused Whether token collateralization is paused.
    /// @dev Token Address => 0 or 1 = unpaused; 2 = paused.
    /// @param borrowPaused Whether token borrowing is paused.
    /// @dev Token Address => 0 or 1 = unpaused; 2 = paused.
    /// @param collRatio The ratio at which this token can be borrowed against
    ///                  when collateralized.
    /// @dev In `BPS`, e.g. 0.8e18 = 80% collateral value borrowable.
    /// @param collReqSoft The collateral requirement where dipping below this
    ///                    will cause a soft liquidation.
    /// @dev In `BPS`, e.g. 1.2e18 = 120% collateral vs debt value.
    /// @param collReqHard The collateral requirement where dipping below
    ///                    this will cause a hard liquidation.
    /// @dev In `BPS`, e.g. 1.1e18 = 110% collateral vs debt value.
    /// @param liqIncBase The base ratio at which this token will be
    ///                   compensated on soft liquidation.
    /// @dev In `BPS`, stored as Incentive + BPS e.g. 1.05e18 = 5% incentive.
    /// @param liqIncCurve The liquidation incentive curve length between
    ///                    soft liquidation to hard liquidation.
    ///                    e.g. 5% base incentive with 8% curve length results
    ///                    in 13% liquidation incentive on hard liquidation.
    /// @dev In `BPS`, e.g. 0.05e18 = 5% maximum additional incentive.
    /// @param liqIncMin The minimum possible liquidation incentive for
    ///                  during an auction.
    /// @dev In `BPS`, stored as Incentive + BPS e.g. 1.03e18 = 3% incentive.
    /// @param liqIncMax The maximum possible liquidation incentive for
    ///                  during an auction.
    /// @dev In `BPS`, stored as Incentive + BPS e.g. 1.07e18 = 7% incentive.
    /// @param closeFactorBase Maximum % that a liquidator can repay when soft
    ///                        liquidating an account.
    /// @dev In `BPS` format, e.g. 0.1e18 = 10% base close factor.
    /// @param closeFactorCurve Curve length between soft liquidation and hard
    ///                         liquidation, should be equal to
    ///                         100% - `closeFactorBase`.
    /// @dev In `BPS` format, e.g. 0.9e18 = 90% distance between
    ///      `closeFactorBase`, and 100%.
    /// @param closeFactorMin The minimum possible close factor for during an
    ///                       auction.
    /// @dev In `BPS` format, e.g. 0.2e18 = 20% minimum close factor.
    /// @param closeFactorMax The maximum possible close factor for during an 
    ///                       auction.
    /// @dev In `BPS` format, e.g. 0.4e18 = 40% maximum close factor.
    struct CurvanceToken {
        bool isListed;
        uint8 mintPaused;
        uint8 collateralizationPaused;
        uint8 borrowPaused;
        uint24 collRatio;
        uint24 collReqSoft;
        uint24 collReqHard;
        uint16 liqIncBase;
        uint16 liqIncCurve;
        uint16 liqIncMin;
        uint16 liqIncMax;
        uint16 closeFactorBase;
        uint16 closeFactorCurve;
        uint16 closeFactorMin;
        uint16 closeFactorMax;
    }

    /// @notice Data structure containing information on hypothetical action
    ///         to execute.
    /// @param cTokenModified The cToken to hypothetically redeem/borrow.
    /// @param redemptionShares The number of tokens to hypothetically redeem,
    ///                         in `shares`.
    /// @param borrowAssets The amount of underlying to hypothetically borrow,
    ///                     in `assets`.
    /// @param errorCodeBreakpoint The error code that will cause liquidity
    ///                            operations to revert. We reuse
    ///                            `errorCodeBreakpoint` as a return variable
    ///                            as a garbage collection flag to minimize
    ///                            local variables.
    struct HypotheticalAction {
        address cTokenModified;
        uint256 redemptionShares;
        uint256 borrowAssets;
        uint256 errorCodeBreakpoint;
    }

    /// @notice Data structure returned on hypothetical calculation containing
    ///         whether there was a collateral surplus or a liquidity deficit,
    ///         and whether account positions need to be updated.
    /// @param collateralSurplus Excess collateral when adjusted for debt
    ///                          obligations.
    /// @param liquidityDeficit Liquidity deficit when adjusted for debt
    ///                         obligations.
    /// @param positionClosureNeeded Whether account positions need to be
    ///                              updated.
    struct HypotheticalResult {
        uint256 collateralSurplus;
        uint256 liquidityDeficit;
        uint256 positionClosureNeeded;
    }

    /// @notice Data structure returned on liquidation threshold calculation
    ///         containing an accounts collateral values under specific
    ///         (soft liquidation versus hard liquidation) methodology
    ///         that will lead to liquidations.
    /// @param cSoft The account's soft collateral value (collateral adjusted
    ///              by soft requirements).
    /// @param cHard The account's hard collateral value (collateral adjusted
    ///              by hard requirements).
    /// @param debt The account's total outstanding debt.
    struct AccountLiqResult {
        uint256 cSoft;
        uint256 cHard;
        uint256 debt;
    }

    /// @notice Data structure returned on querying a liquidation's current
    ///         configuration based on the auction liquidation system.
    /// @param lFactor The liquidation factor for an account, indicating the
    ///                severity of a liquidation, between 0 and WAD.
    /// @param debtBalance An account's outstanding debt to a cToken.
    /// @param liqInc The ratio at which debt repayment will be compensated on
    ///               liquidation.
    /// @param liqIncBase The base ratio at which this token will be
    ///                   compensated on soft liquidation.
    /// @param liqIncCurve The liquidation incentive curve length between soft
    ///                 liquidation to hard liquidation.
    /// @param closeFactor Maximum debt % that a liquidator can repay
    ///                    during a liquidation of an account.
    /// @param closeFactorBase Maximum % that a liquidator can repay when soft
    ///                        liquidating an account.
    /// @param closeFactorCurve Curve length between soft liquidation and hard
    ///                         liquidation, should be equal to
    ///                         100% - `closeFactorBase`.
    struct AccountLiqData {
        uint256 lFactor;
        uint256 debtBalance;
        uint256 liqInc;
        uint256 liqIncBase;
        uint256 liqIncCurve;
        uint256 closeFactor;
        uint256 closeFactorBase;
        uint256 closeFactorCurve;
    }

    /// @notice Data structure returned on querying a liquidation's current
    ///         configuration based on the aggregate liquidation system.
    /// @param collateralToken The address of the Curvance token to be seized
    ///                        during in the liquidation.
    /// @param collateralExchangeRate The exchange rate of `collateralToken`'s
    ///                               underlying token to the cToken itself.
    /// @param collateralReqSoft The collateral requirement where dipping
    ///                          below this will cause a soft liquidation.
    /// @param collateralReqHard The collateral requirement where dipping
    ///                          below this will cause a hard liquidation.
    /// @param collateralSharesPrice The current price of `collateralToken`,
    ///                              in `shares`.
    /// @param collateralDecimals The decimals that `collateralToken` is
    ///                           measured in.
    /// @param debtToken The address of the Curvance token to be repaid during
    ///                  the liquidation.
    /// @param debtDecimals The decimals that `debtToken` is measured in.
    /// @param debtUnderlyingPrice The current price of the underlying token
    ///                            of `debtToken`, in `assets`.
    /// @param auctionBuffer The current buffer that `cSoft` and `cHard` are 
    ///                      multiplied against, 10 bps, or 0 if not an 
    ///                      auction-based liquidation.
    struct TokenLiqData {
        address collateralToken;
        uint256 collateralReqSoft;
        uint256 collateralReqHard;
        uint256 collateralSharesPrice;
        uint256 collateralDecimals;
        address debtToken;
        uint256 debtDecimals;
        uint256 debtUnderlyingPrice;
        uint256 auctionBuffer;
    }

    /// CONSTANTS ///

    /// @notice Maximum collateralization ratio, in `BPS`.
    /// @dev 9750 = 97.50%.
    ///      ~40x leverage calculated from: 1 / (1 - Collateralization Ratio).
    uint256 public constant MAX_COLL_RATIO_CORRELATED = 9750;
    /// @notice Maximum collateralization ratio, in `BPS`.
    /// @dev 9696 = 96.96%.
    ///      ~33x leverage calculated from: 1 / (1 - Collateralization Ratio).
    uint256 public constant MAX_COLL_RATIO_UNCORRELATED = 9696;
    /// @notice Buffer to ensure orderflow auction-based liquidations have
    ///         priority versus basic liquidations, for correlated assets,
    ///         in `BPS`.
    /// @dev 9990 = 99.9%. Multiplied then divided by `BPS` = 10 bps buffer
    ///                    auction liquidation priority for correlated assets.
    uint256 public constant AUCTION_BUFFER_CORRELATED = 9990;
    /// @notice Buffer to ensure orderflow auction-based liquidations have
    ///         priority versus basic liquidations, for uncorrelated assets,
    ///         in `BPS`.
    /// @dev 9950 = 99.5%. Multiplied then divided by `BPS` = 50 bps buffer
    ///                    auction liquidation priority for uncorrelated assets.
    uint256 public constant AUCTION_BUFFER_UNCORRELATED = 9950;
    /// @notice Enforced Liquidity buffer provided to users before a liquidation
    ///         can occur related to a maximum leverage position. This value is
    ///         added with `AUCTION_BUFFER` to determine
    ///         `MIN_LIQUIDATION_BUFFER_REQUIRED` inside a market, in `BPS`.
    /// @dev 25 = 0.25%. An additional 25 basis points buffer ahead of auction
    ///      buffer before a liquidation can trigger.
    uint256 public constant EXTRA_BUFFER_BEFORE_LIQUIDATION = 25;

    /// @notice Whether this market is for correlated assets or not, this
    ///         impacts auction buffer and maximum theoretical
    ///         collateralization ratio allowed.
    bool public immutable IS_CORRELATED_ASSET_MARKET;
    /// @notice Maximum collateralization ratio ratio allowed for any asset
    ///         inside this market, in `BPS`, e.g. 9696 = 96.96%, or ~33x
    ///         leverage calculated from: 1 / (1 - Collateralization Ratio).
    uint256 public immutable MAX_COLL_RATIO;
    /// @notice Buffer to ensure auction-based liquidations have priority
    ///         versus basic liquidations by multiplying a user's active
    ///         collateral $ value by `AUCTION_BUFFER` then dividing by `BPS`.
    ///         Denominated in `BPS`, e.g. 9990 = 99.9% -> 10 bps priority.
    uint256 public immutable AUCTION_BUFFER;
    /// @notice Minimum excess collateral requirement before soft liquidation
    ///         can occur, in `BPS`, e.g. 9950 = 99.5% -> 50 bps drop before a
    ///         liquidation can step in, used during `updateTokenConfig`.
    uint256 public immutable MIN_LIQUIDATION_BUFFER_REQUIRED;
    /// @notice Minimum loan size allowed inside Curvance that can be created
    ///         from a new line of credit inside a market.
    /// @dev This restriction is to minimize the potential of debt positions
    ///      being created that cannot not be profitably closed.
    uint256 public immutable MIN_INITIAL_LOAN_SIZE;
    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;

    /// STORAGE ///

    /// @notice Curvance token data including listing status,
    ///         action enablement, collateralization configuration,
    ///         and liquidation configuration.
    /// @dev Curvance Token Address => CurvanceToken struct.
    mapping(address => CurvanceToken) internal _tokenConfig;

    // ACCOUNT LIQUIDITY DATA //

    /// @notice Value that indicates whether an account has an
    ///         active position in the token.
    /// @dev Curvance Token address => Account address => Active position
    ///      status. 0 or 1 for no; 2 for yes.
    mapping(address => mapping(address => uint256)) public accountPositions;
    /// @notice Assets and redemption cooldown data for an account.
    /// @dev Account => AccountData struct.
    mapping(address => AccountData) public accountAssets;

    /// ERRORS ///

    error LiquidityManager__InsufficientLoanSize();

    /// @param cr The address of the Protocol Central Registry.
    /// @param minLoanSize The minimum active loan size for this isolated
    ///                    market, must be between $10 - $100 in `WAD`.
    /// @param isCorrelatedMarket Whether this market is for correlated assets
    ///                           or not, this impacts auction buffer and
    ///                           maximum theoretical collateralization
    ///                           ratio allowed.
    constructor(
        ICentralRegistry cr,
        uint256 minLoanSize,
        bool isCorrelatedMarket
    ) {
        if (minLoanSize < 10e18 || minLoanSize > 100e18) {
            revert LiquidityManager__InsufficientLoanSize();
        }
        CentralRegistryLib._isCentralRegistry(cr);

        centralRegistry = cr;
        MIN_INITIAL_LOAN_SIZE = minLoanSize;
        IS_CORRELATED_ASSET_MARKET = isCorrelatedMarket;
        MAX_COLL_RATIO = isCorrelatedMarket ?
            MAX_COLL_RATIO_CORRELATED :
            MAX_COLL_RATIO_UNCORRELATED;
        AUCTION_BUFFER = isCorrelatedMarket ? AUCTION_BUFFER_CORRELATED :
            AUCTION_BUFFER_UNCORRELATED;

        // Calculates the minimum liquidation buffer the market needs to give
        // users before liquidation. E.g. 9950 auction buffer - 25 extra
        // buffer = 9925 or 75 bps buffer from max leverage to liquidation.
        MIN_LIQUIDATION_BUFFER_REQUIRED =
            AUCTION_BUFFER - EXTRA_BUFFER_BEFORE_LIQUIDATION;
    }

    /// @notice Determine `account`'s current status between collateral,
    ///         debt, and additional liquidity.
    /// @param account The account to determine liquidity for.
    /// @return collateral Total value of `account`'s collateral across
    ///                    all positions.
    /// @return maxDebt The maximum amount of debt `account`
    ///                 could take on based on `collateral`.
    /// @return debt Total value of `account`'s current outstanding
    ///              debt across all positions.
    function _statusOf(address account) internal returns (
        uint256 collateral,
        uint256 maxDebt,
        uint256 debt
    ) {
        (
            AccountSnapshot[] memory snapshots,
            uint256[] memory prices,
            uint256 numAssets
        ) = _assetDataOf(account, 2);
        AccountSnapshot memory snap;

        for (uint256 i; i < numAssets; ++i) {
            snap = snapshots[i];

            if (snap.isCollateral) {
                uint256 collateralValue = _assetValue(
                    snap.collateralPosted,
                    prices[i],
                    10 ** snap.decimals,
                    true
                );
                collateral += collateralValue;
                maxDebt += _mulDiv(
                    collateralValue,
                    _tokenConfig[snap.asset].collRatio,
                    BPS
                );
            } else {
                // If they have a debt balance, increment their debt.
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
    }

    /// @notice Calculates hypothetical liquidity for an account after a
    ///         potential action such as redemption and borrowing.
    /// @param account The address of the account being evaluated for `action`
    ///                being done.
    /// @param action Instructions for a hypothetical action containing:
    ///               cTokenModified The address of the token being modified
    ///                              by the action.
    ///               redemptionShares The amount of tokens to hypothetically
    ///                                redeem, in `shares`.
    ///               borrowAssets The amount of underlying to hypothetically
    ///                            borrow, in `assets`.
    ///               errorCodeBreakpoint The error code that will cause
    ///                                   liquidity operations to revert.
    /// @return result Hypothetical results for an action containing:
    ///                collateralSurplus Excess collateral capacity after
    ///                                  the action.
    ///                liquidityDeficit Shortfall in collateral capacity after
    ///                                 the action.
    ///                positionClosureNeeded Flag indicating if positions need
    ///                                      to be closed. (0: no, 2: yes)
    /// @return positionsToClose Boolean array indicating which positions
    ///                          would need to be closed.
    function _hypotheticalLiquidityOf(
        address account,
        HypotheticalAction memory action
    ) internal returns (HypotheticalResult memory result, bool[] memory) {
        (
            AccountSnapshot[] memory snapshots,
            uint256[] memory prices,
            uint256 numAssets
        ) = _assetDataOf(account, action.errorCodeBreakpoint);
        bool[] memory positionsToClose = new bool[](numAssets);
        AccountSnapshot memory snap;
        uint256 maxDebt;
        uint256 newDebt;
        
        for (uint256 i; i < numAssets; ++i) {
            snap = snapshots[i];

            // Generally `isCollateral` tells us if an entry is collateral or
            // debt, but, on a fresh borrow position snapshot misreports
            // `isCollateral` as true until its action is fully processed
            // because debtBalance still equals 0 at getSnapshotUpdated level.
            if (
                action.cTokenModified == snap.asset && snap.isCollateral &&
                action.borrowAssets > 0
            ) {
                // We can skip the error code check as we've already
                // priced the share token which requires pricing the
                // underlying token.
                (prices[i], ) =
                    CommonLib._oracleManager(centralRegistry).
                        getPrice(snap.underlying, true, false);
                // Adjust `isCollateral` to be false since this is a debt
                // entry not a collateral entry.
                delete snap.isCollateral;
            }

            if (snap.isCollateral) {
                // If the user is redeeming collateral, offset their
                // collateral posted.
                if (action.cTokenModified == snap.asset) {
                    snap.collateralPosted -= action.redemptionShares;
                }

                // CASE: There is no collateral posted. Either the position
                // will be closed through a full redemption, or the user
                // already had their position closed via liquidation.
                if (snap.collateralPosted == 0) {
                    positionsToClose[i] = true;
                    if (result.positionClosureNeeded == 0) {
                        result.positionClosureNeeded = 2;
                    }
                } else {
                    // CASE: There is collateral posted in this cToken,
                    // the user can take on more debt from lenders.
                    maxDebt += _mulDiv(
                        _assetValue(
                            snap.collateralPosted,
                            prices[i],
                            10 ** snap.decimals,
                            true
                        ),
                        _tokenConfig[snap.asset].collRatio,
                        BPS
                    );
                }
            } else {
                if (action.cTokenModified == snap.asset) {
                    snap.debtBalance += action.borrowAssets;
                }

                // CASE: There is no outstanding debt, clean up the position
                // entry as the user was liquidated, otherwise add to the
                // user's outstanding debt.
                if (snap.debtBalance == 0) {
                    positionsToClose[i] = true;
                    if (result.positionClosureNeeded == 0) {
                        result.positionClosureNeeded = 2;
                    }
                } else {
                    // CASE: There is outstanding debt to lenders, add it to
                    // `newDebt` to check against `maxDebt`.
                    newDebt += _assetValue(
                        snap.debtBalance,
                        prices[i],
                        10 ** snap.decimals,
                        false
                    );

                    // Check `newDebt` to make sure the loan size will not be
                    // too small for us to allow issuing the loan.
                    if (newDebt < MIN_INITIAL_LOAN_SIZE) {
                        revert LiquidityManager__InsufficientLoanSize();
                    }
                }
            }
        }

        // Returns excess liquidity on hypothetical positions.
        if (maxDebt > newDebt) {
            result.collateralSurplus = maxDebt - newDebt;
            return (result, positionsToClose);
        }

        // Returns shortfall on hypothetical positions.
        result.liquidityDeficit = newDebt - maxDebt;
        return (result, positionsToClose);
    }

    /// @notice Evaluates an account's collateral and debt positions to
    ///         determine liquidation factor using cached data.
    /// @param account The address of the account being evaluated for
    ///                 liquidation.
    /// @param tData A TokenLiqData struct containing:
    ///              collateralToken The token which is used as collateral
    ///                               by `account` and may be seized.
    ///              collateralExchangeRate The exchange rate of
    ///                                     `collateralToken` underlying token
    ///                                     to `collateralToken`.
    ///              collateralReqSoft The collateral requirement where
    ///                                dipping below this will cause a soft
    ///                                liquidation.
    ///              collateralReqHard The collateral requirement where
    ///                                dipping below this will cause a hard
    ///                                liquidation.
    ///              collateralUnderlyingPrice The current price of the
    ///                                        underlying token of
    ///                                        `collateralToken`.
    ///              collateralDecimals The decimals that `collateralToken`
    ///                                 is measured in.
    ///              debtToken The token to potentially repay which has
    ///                        outstanding debt by `account`.
    ///              debtDecimals The decimals that `debtToken` is measured
    ///                           in.
    ///              debtUnderlyingPrice The current price of the underlying
    ///                                  token of `debtToken`.
    ///              auctionBuffer The current buffer that `cSoft` and `cHard` 
    ///                            are multiplied against, 10 bps, or 0 if not
    ///                            an auction-based liquidation.
    ///  @return lFactor The liquidation factor where:
    ///                  0: No liquidation (account is healthy).
    ///                  1 to WAD - 1: Soft liquidation (partial liquidation
    ///                                allowed).
    ///                  WAD: Hard liquidation (full liquidation, possibly
    ///                       including bad debt).
    ///  @return debt The current debt position in `liqData.debtToken` for
    ///               `account`.
    function _liquidationValuesOf(
        address account,
        TokenLiqData memory tData
    ) internal view returns (uint256 lFactor, uint256 debt) {
        AccountLiqResult memory r;
        address[] memory assets = accountAssets[account].assets;

        address asset;
        uint256 numAssets = assets.length;
        for (uint256 i; i < numAssets; ) {
            asset = assets[i++];
            if (asset == tData.collateralToken) {
                (r.cSoft, r.cHard) = _addLiquidationValues(
                    tData.collateralDecimals,
                    tData.collateralReqSoft,
                    tData.collateralReqHard,
                    tData.collateralSharesPrice,
                    ICToken(tData.collateralToken).collateralPosted(account),
                    r.cSoft,
                    r.cHard
                );
            } else {
                // If the asset is not `collateralToken`, the asset must
                // be the `debtToken` debt position because this market
                // only has two tokens.
                debt =
                    IBorrowableCToken(tData.debtToken).debtBalance(account);

                // If they have a debt balance, document additional
                // collateral requirements.
                if (debt > 0) {
                    r.debt += _assetValue(
                        debt,
                        tData.debtUnderlyingPrice,
                        tData.debtDecimals,
                        false
                    );
                }
            }
        }
        
        // If this is a potential liquidation from an auction, apply the
        // auction buffer to collateral values, discounting collateral values.
        if (tData.auctionBuffer != 0) {
            r.cSoft = _mulDiv(r.cSoft, tData.auctionBuffer, BPS);
            r.cHard = _mulDiv(r.cHard, tData.auctionBuffer, BPS);
        }

        // Get `account` lFactor.
        if (r.cSoft >= r.debt) {
            // Indicates no liquidation.
            lFactor = 0;
        } else {
            lFactor = r.debt >= r.cHard ? WAD // Indicates hard liquidation.
            // Indicates soft liquidation, we round up here in favor of the
            // protocol, we know that we wont run into a value > WAD due to
            // cHard being at least 1 higher than debt.
            : FixedPointMathLib.mulDivUp(r.debt - r.cSoft, WAD, r.cHard - r.cSoft);
        }
    }

    /// @notice Retrieves the prices and account data of multiple assets
    ///         inside this market.
    /// @param account The account to retrieve data for.
    /// @param errorCodeBreakpoint The error code that will cause liquidity
    ///                            operations to revert.
    /// @return Assets data for `account`.
    /// @return Prices for `account` assets.
    /// @return The number of assets `account` is in.
    function _assetDataOf(address account, uint256 errorCodeBreakpoint)
        internal
        returns (AccountSnapshot[] memory, uint256[] memory, uint256) {
        return CommonLib._oracleManager(centralRegistry).getPricesForMarket(
            account,
            accountAssets[account].assets,
            errorCodeBreakpoint
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

    /// @notice Calculates and adds soft and hard collateral values for
    ///         liquidation assessment with cached data.
    /// @param decimals The number of decimals for the collateral token.
    /// @param collReqSoft The soft collateral requirement ratio, in WAD.
    /// @param collReqHard The hard collateral requirement ratio, in WAD.
    /// @param price The price of the underlying asset, in `WAD`.
    /// @param collateralPosted The amount of collateral token posted as
    ///                         collateral by the account.
    /// @param softSumPrior The previous sum of soft collateral values.
    /// @param hardSumPrior The previous sum of hard collateral values.
    /// @return softSum The updated sum of soft collateral values.
    /// @return hardSum The updated sum of hard collateral values.
    function _addLiquidationValues(
        uint256 decimals,
        uint256 collReqSoft,
        uint256 collReqHard,
        uint256 price,
        uint256 collateralPosted,
        uint256 softSumPrior,
        uint256 hardSumPrior
    ) internal pure returns (uint256 softSum, uint256 hardSum) {
        uint256 assetValue = _assetValue(
            collateralPosted,
            price,
            decimals,
            true
        ) * BPS;

        softSum = softSumPrior + (assetValue / collReqSoft);
        hardSum = hardSumPrior + (assetValue / collReqHard);
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

    /// @dev Internal helper for reverting efficiently.
    function _revert(uint256 s) internal pure {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, s)
            revert(0x1c, 0x04)
        }
    }
}