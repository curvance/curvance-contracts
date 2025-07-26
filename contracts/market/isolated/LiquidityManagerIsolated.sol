// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { WAD } from "contracts/libraries/Constants.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";

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
    /// @param assets Array of account assets.
    /// @param cooldownTimestamp Last time an account performed an action,
    ///                          which activates the redeem/repay/exit market
    ///                          cooldown.
    struct AccountData {
        address[] assets;
        uint256 cooldownTimestamp;
    }

    /// @notice Storage configuration for how a Curvance token should behave
    ///         in the liquidity manager.
    /// @param isListed Whether or not this Curvance token is listed.
    /// @dev false = unlisted; true = listed.
    /// @param collRatio The ratio at which this token can be borrowed against
    ///                  when collateralized.
    /// @dev In `WAD`, e.g. 0.8e18 = 80% collateral value borrowable.
    /// @param collReqSoft The collateral requirement where dipping below this
    ///                    will cause a soft liquidation.
    /// @dev In `WAD`, e.g. 1.2e18 = 120% collateral vs debt value.
    /// @param collReqHard The collateral requirement where dipping below
    ///                    this will cause a hard liquidation.
    /// @dev In `WAD`, e.g. 1.1e18 = 110% collateral vs debt value.
    /// @param liqIncBase The base ratio at which this token will be
    ///                   compensated on soft liquidation.
    /// @dev In `WAD`, stored as Incentive + WAD e.g. 1.05e18 = 5% incentive.
    /// @param liqIncCurve The liquidation incentive curve length between
    ///                    soft liquidation to hard liquidation.
    ///                    e.g. 5% base incentive with 8% curve length results
    ///                    in 13% liquidation incentive on hard liquidation.
    /// @dev In `WAD`, e.g. 0.05e18 = 5% maximum additional incentive.
    /// @param liqIncMin The minimum possible liquidation incentive for
    ///                  during an auction, in basis points.
    /// @dev In `WAD`, stored as Incentive + WAD e.g. 1.03e18 = 3% incentive.
    /// @param liqIncMax The maximum possible liquidation incentive for
    ///                  during an auction, in basis points.
    /// @dev In `WAD`, stored as Incentive + WAD e.g. 1.07e18 = 7% incentive.
    /// @param closeFactorBase Maximum % that a liquidator can repay when soft
    ///                        liquidating an account.
    /// @dev In `WAD` format, e.g. 0.1e18 = 10% base close factor.
    /// @param closeFactorCurve Curve length between soft liquidation and hard
    ///                         liquidation, should be equal to
    ///                         100% - `closeFactorBase`.
    /// @dev In `WAD` format, e.g. 0.9e18 = 90% distance between
    ///      `closeFactorBase`, and 100%.
    /// @param closeFactorMin The minimum possible close factor for during an
    ///                       auction, in basis points.
    /// @dev In `WAD` format, e.g. 0.2e18 = 20% minimum close factor.
    /// @param closeFactorMax The maximum possible close factor for during an 
    ///                       auction, in basis points.
    /// @dev In `WAD` format, e.g. 0.4e18 = 40% maximum close factor.
    struct CurvanceToken {
        bool isListed;
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
    /// @param liqIncAuction The ratio at which this token will be
    ///                            compensated on liquidation.
    /// @param liqIncBase The base ratio at which this token will be
    ///                   compensated on soft liquidation.
    /// @param liqIncCurve The liquidation incentive curve length between soft
    ///                 liquidation to hard liquidation.
    /// @param closeFactorAuction Maximum % that a liquidator can repay when
    ///                           soft liquidating an account.
    /// @param closeFactorBase Maximum % that a liquidator can repay when soft
    ///                        liquidating an account.
    /// @param closeFactorCurve Curve length between soft liquidation and hard
    ///                         liquidation, should be equal to
    ///                         100% - `closeFactorBase`.
    struct AccountLiqData {
        uint256 lFactor;
        uint256 debtBalance;
        uint256 liqIncAuction;
        uint256 liqIncBase;
        uint256 liqIncCurve;
        uint256 closeFactorAuction;
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
    /// @param collateralUnderlyingPrice The current price of the underlying
    ///                                  token to `collateralToken`.
    /// @param collateralDecimals The decimals that `collateralToken` is
    ///                           measured in.
    /// @param debtToken The address of the Curvance token to be repaid during
    ///                  the liquidation.
    /// @param debtDecimals The decimals that `debtToken` is measured in.
    /// @param debtUnderlyingPrice The current price of the underlying token
    ///                            of `debtToken`.
    /// @param auctionBuffer The current buffer that `cSoft` is multiplied
    ///                      against, 10 bps, or 0 if not an auction-based
    ///                      liquidation.
    struct TokenLiqData {
        address collateralToken;
        uint256 collateralExchangeRate;
        uint256 collateralReqSoft;
        uint256 collateralReqHard;
        uint256 collateralUnderlyingPrice;
        uint256 collateralDecimals;
        address debtToken;
        uint256 debtDecimals;
        uint256 debtUnderlyingPrice;
        uint256 auctionBuffer;
    }

    /// CONSTANTS ///

    /// @notice Minimum loan size allowed inside Curvance that can be created
    ///         from a new line of credit inside a market.
    /// @dev This restriction is to minimize the potential of debt positions
    ///      being created that cannot not be profitably closed.
    uint256 public constant MIN_ACTIVE_LOAN_SIZE = 10e18;

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;

    /// STORAGE ///

    /// @notice Curvance token data including listing status,
    ///         token characterists, account position data.
    /// @dev Curvance Token Address => CurvanceToken struct.
    mapping(address => CurvanceToken) public tokenData;

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

    error LiquidityManager__InvalidParameter();
    error LiquidityManager__InsufficientLoanSize();

    constructor(ICentralRegistry centralRegistry_) {
        if (
            !ERC165Checker.supportsInterface(
                address(centralRegistry_),
                type(ICentralRegistry).interfaceId
            )
        ) {
            // bytes4(keccak256(bytes("LiquidityManager__InvalidParameter()"))).
            _revert(0x78eefdcc);
        }

        centralRegistry = centralRegistry_;
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
    function _statusOf(address account) internal view returns (
        uint256 collateral,
        uint256 maxDebt,
        uint256 debt
    ){
        (
            AccountSnapshot[] memory snapshots,
            uint256[] memory underlyingPrices,
            uint256 numAssets
        ) = _assetDataOf(account, 2);
        AccountSnapshot memory snap;

        for (uint256 i; i < numAssets; ++i) {
            snap = snapshots[i];

            if (snap.isCollateral) {
                uint256 collateralValue = _assetValue(
                    _mulDiv(snap.collateralPosted, snap.exchangeRate, WAD),
                    underlyingPrices[i],
                    10 ** snap.decimals,
                    true
                );
                collateral += collateralValue;
                maxDebt += _mulDiv(
                    collateralValue,
                    tokenData[snap.asset].collRatio,
                    WAD
                );
            } else {
                // If they have a debt balance, increment their debt.
                if (snap.debtBalance > 0) {
                    debt += _assetValue(
                        snap.debtBalance,
                        underlyingPrices[i],
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
    /// @param action A HypotheticalAction struct containing:
    ///               cTokenModified The address of the token being modified
    ///                              by the action.
    ///               redemptionShares The amount of tokens to hypothetically
    ///                                redeem, in `shares`.
    ///               borrowAssets The amount of underlying to hypothetically
    ///                            borrow, in `assets`.
    ///               errorCodeBreakpoint The error code that will cause
    ///                                   liquidity operations to revert.
    /// @return result A HypotheticalResult struct containing:
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
    ) internal view returns (
        HypotheticalResult memory result,
        bool[] memory
    ) {
        (
            AccountSnapshot[] memory snapshots,
            uint256[] memory underlyingPrices,
            uint256 numAssets
        ) = _assetDataOf(account, action.errorCodeBreakpoint);
        bool[] memory positionsToClose = new bool[](numAssets);
        AccountSnapshot memory snap;
        uint256 maxDebt;
        uint256 newDebt;
        
        for (uint256 i; i < numAssets; ++i) {
            snap = snapshots[i];

            if (snap.isCollateral) {
                // If there is no collateral posted and its not a
                // position to be modified, clean up the position
                // entry as the user was liquidated.
                if (snap.collateralPosted == 0) {
                    // If there is no collateral posted and its not a
                    // position to be modified, clean up the position
                    // entry as the user was liquidated.
                    if (action.cTokenModified != snap.asset) {
                        positionsToClose[i] = true;
                        if (result.positionClosureNeeded == 0) {
                            result.positionClosureNeeded = 2;
                        }
                    }
                } else {
                    // There is collateral posted in this cToken,
                    // increasing collateral, or more simply the user
                    // can take on more debt.
                    maxDebt += _collateralValue(
                        snap.collateralPosted,
                        snap.exchangeRate,
                        underlyingPrices[i],
                        10 ** snap.decimals,
                        tokenData[snap.asset].collRatio,
                        true
                    );
                }
            } else {
                // If they have a debt balance, increment their debt.
                if (snap.debtBalance > 0) {
                    newDebt += _assetValue(
                        snap.debtBalance,
                        underlyingPrices[i],
                        10 ** snap.decimals,
                        false
                    );
                } else {
                    // If there is no debt and its not a position
                    // to be modified, clean up the position entry as the
                    // user was liquidated (bad debt insolvency).
                    if (action.cTokenModified != snap.asset) {
                        positionsToClose[i] = true;
                        if (result.positionClosureNeeded == 0) {
                            result.positionClosureNeeded = 2;
                        }
                    }
                }
            }

            // Calculate impact of cTokenModified action.
            if (action.cTokenModified == snap.asset) {
                // If the token is collateral it cannot also be debt position,
                // but, on a fresh borrow position snapshot can misreport
                // a debt position as collateral until its fully opened
                // because debtBalance still equals 0 at getSnapshot level.
                if (snap.isCollateral && action.borrowAssets == 0) {
                    // If they are trying to redeem more tokens than
                    // they have, the transaction will fail before it
                    // gets to this point, so no special case needed.
                    if (snap.collateralPosted == action.redemptionShares) {
                        positionsToClose[i] = true;
                        if (result.positionClosureNeeded == 0) {
                            result.positionClosureNeeded = 2;
                        }
                    }

                    // Hypothetical redemption action, decreasing collateral
                    // or more simply adding new debt.
                    newDebt += _collateralValue(
                        action.redemptionShares,
                        snap.exchangeRate,
                        underlyingPrices[i],
                        10 ** snap.decimals,
                        tokenData[snap.asset].collRatio,
                        false
                    );
                } else {
                    // Hypothetical borrow action.
                    newDebt += _assetValue(
                        action.borrowAssets,
                        underlyingPrices[i],
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
                        revert LiquidityManager__InsufficientLoanSize();
                    }

                    // We don't need to check for closing a position here
                    // since borrow action will only expand a position.
                }
            }
        }
        // These will not underflow/overflow as condition is checked prior.
        // Returns excess liquidity on hypothetical positions.
        if (maxDebt > newDebt) {
            unchecked {
                result.collateralSurplus = maxDebt - newDebt;
            }

            return (result, positionsToClose);
        }

        // Returns shortfall on hypothetical positions.
        unchecked {
            result.liquidityDeficit = newDebt - maxDebt;
        }

        return (result, positionsToClose);
    }

    /// @notice Evaluates collateral and debt positions to determine account
    ///         health and liquidation parameters.
    /// @param account The address of the account being evaluated for
    ///                liquidation.
    /// @param collateralToken The address of the Curvance token (cToken)
    ///                        collateralized by `account`.
    /// @param debtToken The address of the Curvance token (cToken) that
    ///                  `account` has outstanding debt in.
    /// @return result An AccountLiqResult struct containing:
    ///                cSoft The account's soft collateral value (collateral
    ///                      adjusted by soft requirements).
    ///                cHard The account's hard collateral value (collateral
    ///                      adjusted by hard requirements).
    ///                debt The account's total debt value.
    /// @return lFactor The liquidation factor determining liquidation
    ///                 severity.
    /// @return collateralTokenPrice The price of the underlying asset of
    ///                              `collateralToken`.
    /// @return debtTokenPrice The price of the underlying asset of
    ///                        `debtToken`.
    function _liquidationValuesOf(
        address account,
        address collateralToken,
        address debtToken
    )
        internal
        view
        returns (
            AccountLiqResult memory result,
            uint256 lFactor,
            uint256 collateralTokenPrice,
            uint256 debtTokenPrice
            )
    {
        (
            AccountSnapshot[] memory snapshots,
            uint256[] memory underlyingPrices,
            uint256 numAssets
        ) = _assetDataOf(account, 2);
        AccountSnapshot memory snap;

        for (uint256 i; i < numAssets; ++i) {
            snap = snapshots[i];

            if (snap.isCollateral) {
                if (snap.asset == collateralToken) {
                    collateralTokenPrice = underlyingPrices[i];
                }

                (
                    result.cSoft,
                    result.cHard
                ) = _addLiquidationValues(
                    snap,
                    account,
                    underlyingPrices[i],
                    result.cSoft,
                    result.cHard
                );
            } else {
                if (snap.asset == debtToken) {
                    debtTokenPrice = underlyingPrices[i];
                }

                // If they have a debt balance,
                // we need to document collateral requirements.
                if (snap.debtBalance > 0) {
                    result.debt += _assetValue(
                        snap.debtBalance,
                        underlyingPrices[i],
                        10 ** snap.decimals,
                        false
                    );
                }
            }
        }

        lFactor = _getLFactor(result.cSoft, result.cHard, result.debt);
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
    ///              auctionBuffer The current buffer that `cSoft` is
    ///                            multiplied against, 10 bps, or 0  if not
    ///                            an auction-based liquidation.
    ///  @return lFactor The liquidation factor for `account`.
    ///  @return debt The current debt position in `liqData.debtToken` for
    ///               `account`.
    function _liquidationValuesOfCached(
        address account,
        TokenLiqData memory tData
    ) internal view returns (uint256 lFactor, uint256 debt) {
        AccountLiqResult memory r;
        address[] memory assets = accountAssets[account].assets;

        {
            address asset;
            // We cannot cache assets.length as we'd run into a
            // stack too deep compiler error here.
            for (uint256 i; i < assets.length; ) {
                asset = assets[i++];
                if (asset == tData.collateralToken) {
                    (
                        r.cSoft,
                        r.cHard
                    ) = _addLiquidationValuesCached(
                            tData.collateralExchangeRate,
                            tData.collateralDecimals,
                            tData.collateralReqSoft,
                            tData.collateralReqHard,
                            tData.collateralUnderlyingPrice,
                            ICToken(tData.collateralToken).collateralPosted(
                                account
                            ),
                            r.cSoft,
                            r.cHard
                    );
                } else {
                    // If the asset is not `collateralToken`, the asset must
                    // be the `debtToken` debt position because this market
                    // only has two tokens.
                    debt = IBorrowableCToken(tData.debtToken).debtBalance(
                        account
                    );

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
        }

        // If this is a potential liquidation from an auction, apply the
        // auction buffer to collateral values, discounting collateral values.
        if (tData.auctionBuffer != 0) {
            r.cSoft = _mulDiv(r.cSoft, tData.auctionBuffer, WAD);
            r.cHard = _mulDiv(r.cHard, tData.auctionBuffer, WAD);
        }

        lFactor = _getLFactor(r.cSoft, r.cHard, r.debt);
    }

    ///  @notice Calculates the liquidation factor (LFactor) for an account
    ///          based on their collateral and debt positions.
    ///  @dev Determines whether an account is in a no-liquidation,
    ///       soft-liquidation, or hard-liquidation state.
    ///  @param cSoft The account's soft collateral value (collateral adjusted
    ///               by soft requirements).
    ///  @param cHard The account's hard collateral value (collateral adjusted
    ///               by hard requirements).
    ///  @param debt The account's total outstanding debt value.
    ///  @return result The liquidation factor where:
    ///          - 0: No liquidation (account is healthy).
    ///          - 1 to WAD-1: Soft liquidation (partial liquidation allowed).
    ///          - WAD: Hard liquidation (full liquidation, possibly including
    ///                 bad debt).
    function _getLFactor(
        uint256 cSoft,
        uint256 cHard,
        uint256 debt
    ) internal pure returns (uint256 result) {
        // Indicates no liquidation.
        if (cSoft >= debt) {
            return result;
        }

        // Indicates hard liquidation.
        if (debt >= cHard) {
            result = WAD;
            return result;
        }

        // Indicates soft liquidation.
        result = _mulDiv(debt - cSoft, WAD, cHard - cSoft);

        // Its theoretically possible for lFactor calculation to round
        // down here, if the delta between the hard and soft collateral
        // thresholds are significant (> WAD), with a minimal numerator
        // (~ WAD). For this case we round up on the side of the protocol.
        if (result == 0) {
            // Round to 1 wei to trigger a soft liquidation.
            result = 1;
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
    function _assetDataOf(
        address account,
        uint256 errorCodeBreakpoint
    )
        internal
        view
        returns (AccountSnapshot[] memory, uint256[] memory, uint256)
    {
        return
            IOracleManager(centralRegistry.oracleManager()).getPricesForMarket(
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

    /// @notice Calculates collateral value based on `amount`, `exchangeRate`,
    ///         `price`, `collRatio`, and adjusts for token decimals.
    /// @param amount The asset amount to calculate collateral value of.
    /// @param exchangeRate The exchange rate between cToken and underlying.
    /// @param price The asset's price, in `WAD`.
    /// @param decimals The asset's decimals to adjust redemption value
    ///                 into proper form.
    /// @param collRatio The collateralization ratio of the asset.
    /// @return result The calculated collateral value.
    function _collateralValue(
        uint256 amount,
        uint256 exchangeRate,
        uint256 price,
        uint256 decimals,
        uint256 collRatio,
        bool increasesCollateral
    ) internal pure returns (uint256 result) {
        result = _mulDiv(
            _assetValue(
                _mulDiv(amount, exchangeRate, WAD),
                price,
                decimals,
                increasesCollateral
            ),
            collRatio,
            WAD
        );
    }

    /// @notice Calculates and adds soft and hard collateral values for
    ///         liquidation assessment.
    /// @param snap Asset snapshot to calculate asset value from.
    /// @param account The account to query collateral posted for to calculate
    ///                liquidation values off of.
    /// @param price The price of the underlying asset, in `WAD`.
    /// @param softSumPrior The previous sum of soft collateral values.
    /// @param hardSumPrior The previous sum of hard collateral values.
    /// @return uint256 The updated sum of soft collateral values.
    /// @return uint256 The updated sum of hard collateral values.
    function _addLiquidationValues(
        AccountSnapshot memory snap,
        address account,
        uint256 price,
        uint256 softSumPrior,
        uint256 hardSumPrior
    ) internal view returns (uint256, uint256) {
        address asset = snap.asset;
        return _addLiquidationValuesCached(
            snap.exchangeRate,
            10 ** snap.decimals,
            tokenData[asset].collReqSoft,
            tokenData[asset].collReqHard,
            price,
            ICToken(asset).collateralPosted(account),
            softSumPrior,
            hardSumPrior
        );
    }

    /// @notice Calculates and adds soft and hard collateral values for
    ///         liquidation assessment with cached data.
    /// @param exchangeRate The exchange rate between the collateral token
    ///                     and its underlying asset, in WAD.
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
    function _addLiquidationValuesCached(
        uint256 exchangeRate,
        uint256 decimals,
        uint256 collReqSoft,
        uint256 collReqHard,
        uint256 price,
        uint256 collateralPosted,
        uint256 softSumPrior,
        uint256 hardSumPrior
    ) internal pure returns (uint256 softSum, uint256 hardSum) {
        uint256 assetValue = _assetValue(
            _mulDiv(collateralPosted, exchangeRate, WAD),
            price,
            decimals,
            true
        ) * WAD;

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