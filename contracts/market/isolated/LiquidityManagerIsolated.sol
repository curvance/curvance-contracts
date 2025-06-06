// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { WAD } from "contracts/libraries/Constants.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IMToken, AccountSnapshot } from "contracts/interfaces/IMToken.sol";
import { IEToken } from "contracts/interfaces/IEToken.sol";
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
        IMToken[] assets;
        uint256 cooldownTimestamp;
    }

    /// @param activePosition Value that indicates whether an account has
    ///                       an active position in the token.
    ///                       0 or 1 for no; 2 for yes.
    /// @param collateralPosted The amount of collateral an account has posted
    ///                         inside the market. Only applicable to pTokens,
    ///                         not eTokens.
    struct AccountPosition {
        uint256 activePosition;
        uint256 collateralPosted;
    }

    /// @notice Storage configuration for how a market token should behave
    ///         in the liquidity manager.
    /// @param isListed Whether or not this market token is listed.
    ///                 false = unlisted; true = listed.
    /// @param collRatio The ratio at which this token can be collateralized.
    ///                  in `WAD`, e.g. 0.8e18 = 80% collateral value.
    /// @param collReqSoft The collateral requirement where dipping below this
    ///                    will cause a soft liquidation.
    /// @dev In `WAD`, e.g. 1.2e18 = 120% collateral vs debt value.
    /// @param collReqHard The collateral requirement where dipping below
    ///                    this will cause a hard liquidation.
    /// @dev In `WAD`, e.g. 1.2e18 = 120% collateral vs debt value.
    ///      NOTE: Should ALWAYS be less than `collReqSoft`.
    /// @param liqBaseIncentive The base ratio at which this token will be
    ///                         compensated on soft liquidation.
    /// @dev In `WAD`, stored as (Incentive + WAD) e.g. 1.05e18 = 5% incentive,
    ///      this saves gas for liquidation calculations.
    /// @param liqCurve The liquidation incentive curve length between
    ///                 soft liquidation to hard liquidation.
    ///                 e.g. 5% base incentive with 8% curve length results
    ///                 in 13% liquidation incentive on hard liquidation.
    /// @dev In `WAD`, e.g. 0.05e18 = 5% maximum additional incentive.
    /// @param baseCFactor Maximum % that a liquidator can repay when
    ///                    soft liquidating an account.
    /// @dev In `WAD` format, e.g. 0.1e18 = 10% base close factor.
    /// @param cFactorCurve cFactor curve length between soft liquidation
    ///                     and hard liquidation, should be equal to
    ///                     100% - baseCFactor.
    /// @dev In `WAD` format, e.g. 0.9e18 = 90% distance between base cFactor,
    ///      and 100%.
    /// @param accountPositions Mapping that stores account information like token
    ///                    positions and collateral posted.
    struct MarketToken {
        bool isListed;
        uint256 collRatio;
        uint256 collReqSoft;
        uint256 collReqHard;
        uint256 liqBaseIncentive;
        uint256 liqCurve;
        uint256 liqMinIncentive;
        uint256 liqMaxIncentive;
        uint256 minEffectiveCloseFactor;
        uint256 maxEffectiveCloseFactor;
        uint256 baseCFactor;
        uint256 cFactorCurve;
        mapping(address => AccountPosition) accountPositions;
    }

    /// @notice Data structure containing information on hypothetical action
    ///         to execute.
    /// @param mTokenModified The mToken to hypothetically redeem/borrow.
    /// @param redeemTokens The number of tokens to hypothetically redeem,
    ///                     in `shares`.
    /// @param borrowAmount The amount of underlying to hypothetically borrow,
    ///                     in `assets`.
    /// @param errorCodeBreakpoint The error code that will cause liquidity
    ///                            operations to revert. We reuse
    ///                            `errorCodeBreakpoint` as a return variable
    ///                            as a garbage collection flag to minimize
    ///                            local variables.
    struct HypotheticalAction {
        address mTokenModified;
        uint256 redeemTokens;
        uint256 borrowAmount;
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
    struct HypotheticalData {
        uint256 collateralSurplus;
        uint256 liquidityDeficit;
        uint256 positionClosureNeeded;
    }

    /// @notice Data structure returned on liquidation threshold calculation
    ///         containing an accounts collateral values under specific
    ///         (soft liquidation versus hard liquidation) methodology
    ///         that will lead to liquidations.
    /// @param accountCollateralSoft The account's soft collateral value
    ///                              (collateral adjusted by soft
    ///                              requirements).
    /// @param accountCollateralHard The account's hard collateral value
    ///                              (collateral adjusted by hard
    ///                              requirements).
    /// @param accountDebt The account's total debt value.
    struct AccountLiqData {
        uint256 accountCollateralSoft;
        uint256 accountCollateralHard;
        uint256 accountDebt;
    }

    /// @notice Data structure returned on querying a liquidation's current
    ///         configuration based on the auction liquidation system.
    /// @param lFactor The liquidation factor for an account, indicating the
    ///                severity of a liquidation, between 0 and WAD.
    /// @param debtBalance An account's current active debt to an eToken.
    /// @param auctionCFactor Maximum % that a liquidator can repay when soft
    ///                       liquidating an account.
    /// @param auctionLiqIncentive The ratio at which this token will be
    ///                            compensated on liquidation.
    /// @param baseCFactor Maximum % that a liquidator can repay when soft
    ///                    liquidating an account.
    /// @param cFactorCurve cFactor curve length between soft liquidation and
    ///                     hard liquidation, should be equal to
    ///                     100% - `baseCFactor`.
    /// @param liqBaseIncentive The base ratio at which this token will be
    ///                         compensated on soft liquidation.
    /// @param liqCurve The liquidation incentive curve length between soft
    ///                 liquidation to hard liquidation.
    struct AuctionLiqData {
        uint256 lFactor;
        uint256 debtBalance;
        uint256 auctionCFactor;
        uint256 auctionLiqIncentive;
        uint256 baseCFactor;
        uint256 cFactorCurve;
        uint256 liqBaseIncentive;
        uint256 liqCurve;
    }

    /// @notice Data structure returned on querying a liquidation's current
    ///         configuration based on the aggregate liquidation system.
    /// @param pToken The address of the position token (collateral token)
    ///               involved in the liquidation.
    /// @param eToken The address of the earn token (debt token) involved
    ///               in the liquidation.
    /// @param pTokenExchangeRate The exchange rate of pToken's underlying
    ///                           token to the pToken itself.
    /// @param pTokenCollReqSoft The collateral requirement where dipping
    ///                          below this will cause a soft liquidation.
    /// @param pTokenCollReqHard The collateral requirement where dipping
    ///                          below this will cause a hard liquidation.
    /// @param pTokenUnderlyingPrice The current price of the underlying token
    ///                              of the pToken.
    /// @param pTokenDecimals The decimals that `pToken` is measured in.
    /// @param eTokenDecimals The decimals that `eToken` is measured in.
    /// @param eTokenUnderlyingPrice The current price of the underlying token
    ///                              of the eToken.
    /// @param auctionBuffer The current buffer that accountCollateralSoft is
    ///                      multiplied against, 10 bps or 0 if not an auction
    ///                      liquidation.
    struct CachedLiqData {
        address pToken;
        address eToken;
        uint256 pTokenExchangeRate;
        uint256 pTokenCollReqSoft;
        uint256 pTokenCollReqHard;
        uint256 pTokenUnderlyingPrice;
        uint256 pTokenDecimals;
        uint256 eTokenDecimals;
        uint256 eTokenUnderlyingPrice;
        uint256 auctionBuffer;
    }

    /// CONSTANTS ///

    /// @notice Minimum loan size allowed inside Curvance that can be created
    ///         from a new line of credit inside a market.
    /// @dev This restriction is to minimize the potential of debt positions
    ///      being created that cannot not be profitably closed.
    uint256 public constant MIN_ACTIVE_LOAN_SIZE = 50e18;

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;

    /// STORAGE ///

    /// @notice Market token data including listing status,
    ///         token characterists, account position data.
    /// @dev Market Token Address => MarketToken struct.
    mapping(address => MarketToken) public tokenData;
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
    /// @return accountCollateral Total value of `account`'s collateral across
    ///                           all pTokens.
    /// @return maxDebt The maximum amount of debt `account`
    ///                 could take on based on `accountCollateral`.
    /// @return accountDebt Total value of `account`'s current outstanding
    ///                     debt across all debt positions.
    function _statusOf(
        address account
    )
        internal
        view
        returns (
            uint256 accountCollateral,
            uint256 maxDebt,
            uint256 accountDebt
        )
    {
        (
            AccountSnapshot[] memory snapshots,
            uint256[] memory underlyingPrices,
            uint256 numAssets
        ) = _assetDataOf(account, 2);
        AccountSnapshot memory snapshot;

        for (uint256 i; i < numAssets; ++i) {
            snapshot = snapshots[i];

            if (snapshot.isPToken) {
                // If the asset has a CR increment their collateral
                // and max borrow value.
                if (tokenData[snapshot.asset].collRatio != 0) {
                    uint256 collateralValue = _assetValue(
                        ((tokenData[snapshot.asset]
                            .accountPositions[account]
                            .collateralPosted * snapshot.exchangeRate) / WAD),
                        underlyingPrices[i],
                        10 ** snapshot.decimals,
                        true
                    );
                    accountCollateral += collateralValue;
                    maxDebt +=
                        (collateralValue *
                            tokenData[snapshot.asset].collRatio) /
                        WAD;
                }
            } else {
                // If they have a debt balance, increment their debt.
                if (snapshot.debtBalance > 0) {
                    accountDebt += _assetValue(
                        snapshot.debtBalance,
                        underlyingPrices[i],
                        10 ** snapshot.decimals,
                        false
                    );
                }
            }
        }
    }

    /// @notice Calculates hypothetical liquidity for an account after a
    ///         potential action such as redemption and borrowing.
    /// @dev Note that we calculate the exchangeRateCached for each collateral
    ///      mToken using stored data, without calculating accumulated
    ///      interest.
    /// @param account The address of the account being evaluated for with a
    ///                hypothetical action.
    /// @param action A HypotheticalAction struct containing:
    ///               mTokenModified: The address of the token being modified
    ///                               by the action.
    ///               redeemTokens The amount of tokens to hypothetically redeem,
    ///                            in `shares`.
    ///               borrowAmount The amount of underlying to hypothetically borrow,
    ///                            in `assets`.
    ///               errorCodeBreakpoint The error code that will cause liquidity
    ///                                   operations to revert.
    /// @return result A HypotheticalData struct containing:
    ///                - collateralSurplus: Excess collateral capacity after
    ///                                     the action.
    ///                - liquidityDeficit: Shortfall in collateral capacity
    ///                                    after the action.
    ///                - positionClosureNeeded: Flag indicating if positions
    ///                                         need to be closed.
    ///                                         (0: no, 2: yes)
    /// @return positionsToClose Boolean array indicating which positions
    ///                          would need to be closed.
    function _hypotheticalLiquidityOf(
        address account,
        HypotheticalAction memory action
    ) internal view returns (HypotheticalData memory result, bool[] memory) {
        (
            AccountSnapshot[] memory snapshots,
            uint256[] memory underlyingPrices,
            uint256 numAssets
        ) = _assetDataOf(account, action.errorCodeBreakpoint);
        bool[] memory positionsToClose = new bool[](numAssets);
        uint256 maxDebt;
        uint256 newDebt;

        {
            // Use scoping to avoid stack too deep.
            AccountSnapshot memory snapshot;

            for (uint256 i; i < numAssets; ++i) {
                uint256 posted;
                uint256 cr;
                snapshot = snapshots[i];

                if (snapshot.isPToken) {
                    // Cache Collateralization for pToken status and potential
                    // hypothetical action below.
                    cr = tokenData[snapshot.asset].collRatio;
                    // If the pToken has a Collateralization Ratio,
                    // increment their collateral and max borrow value.
                    if (cr != 0) {
                        // Cache collateral posted.
                        posted = tokenData[snapshot.asset]
                            .accountPositions[account]
                            .collateralPosted;

                        // If there is no collateral posted and its not a
                        // position to be modified, clean up the position
                        // entry as the user was liquidated.
                        if (posted == 0) {
                            // If there is no collateral posted and its not a
                            // position to be modified, clean up the position
                            // entry as the user was liquidated.
                            if (action.mTokenModified != snapshot.asset) {
                                positionsToClose[i] = true;
                                if (result.positionClosureNeeded == 0) {
                                    result.positionClosureNeeded = 2;
                                }
                            }
                        } else {
                            // There is collateral posted in this pToken,
                            // and the user can take on more debt.
                            maxDebt = _addLiquidityValue(
                                maxDebt,
                                posted,
                                snapshot.exchangeRate,
                                underlyingPrices[i],
                                10 ** snapshot.decimals,
                                cr
                            );
                        }
                    }
                } else {
                    // If they have a debt balance, increment their debt.
                    if (snapshot.debtBalance > 0) {
                        newDebt += _assetValue(
                            snapshot.debtBalance,
                            underlyingPrices[i],
                            10 ** snapshot.decimals,
                            false
                        );
                    } else {
                        // If there is no debt and its not a position
                        // to be modified, clean up the position entry as the
                        // user was liquidated (bad debt insolvency).
                        if (action.mTokenModified != snapshot.asset) {
                            positionsToClose[i] = true;
                            if (result.positionClosureNeeded == 0) {
                                result.positionClosureNeeded = 2;
                            }
                        }
                    }
                }

                // Calculate impact of mTokenModified action.
                if (action.mTokenModified == snapshot.asset) {
                    // If its a PToken our only option is to redeem it since
                    // it cant be borrowed.
                    // If its a EToken we can redeem it but it will not have
                    // any effect on borrow amount since EToken have a collateral
                    // value of 0.
                    if (snapshot.isPToken) {
                        // If the pToken has a Collateralization Ratio,
                        // increase their new debt.
                        if (cr != 0) {
                            // If they are trying to redeem more tokens than
                            // they have, the transaction will fail before it
                            // gets to this point, so no special case needed.
                            if (posted == action.redeemTokens) {
                                positionsToClose[i] = true;
                                if (result.positionClosureNeeded == 0) {
                                    result.positionClosureNeeded = 2;
                                }
                            }

                            // Hypothetical redemption action.
                            newDebt += _redemptionValue(
                                action.redeemTokens,
                                snapshot.exchangeRate,
                                underlyingPrices[i],
                                10 ** snapshot.decimals,
                                cr
                            );
                        }
                    } else {
                        // Hypothetical borrow action.
                        newDebt += _assetValue(
                            action.borrowAmount,
                            underlyingPrices[i],
                            10 ** snapshot.decimals,
                            false
                        );

                        // Initially, we would worry that newDebt can be
                        // incremented during both borrow and redemption
                        // actions but actions are done in isolation, so if
                        // newDebt is increases here then mTokenModified will
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
    /// @param eToken The address of the earn token (eToken) representing
    ///               debt positions.
    /// @param pToken The address of the position token (pToken) representing
    ///               collateral positions.
    /// @return accountData An AccountLiqData struct containing:
    ///                     accountCollateralSoft The account's soft collateral value
    ///                                           (collateral adjusted by soft
    ///                                           requirements).
    ///                     accountCollateralHard The account's hard collateral value
    ///                                           (collateral adjusted by hard
    ///                                           requirements).
    ///                     accountDebt The account's total debt value.
    /// @return lFactor The liquidation factor determining liquidation severity.
    /// @return earnTokenPrice The price of the underlying asset for the eToken.
    /// @return positionTokenPrice The price of the underlying asset for the pToken.
    function _liquidationValuesOf(
        address account,
        address eToken,
        address pToken
    )
        internal
        view
        returns (
            AccountLiqData memory accountData,
            uint256 lFactor,
            uint256 earnTokenPrice,
            uint256 positionTokenPrice
            )
    {
        (
            AccountSnapshot[] memory snapshots,
            uint256[] memory underlyingPrices,
            uint256 numAssets
        ) = _assetDataOf(account, 2);
        AccountSnapshot memory snapshot;

        for (uint256 i; i < numAssets; ++i) {
            snapshot = snapshots[i];

            if (snapshot.isPToken) {
                if (snapshot.asset == pToken) {
                    positionTokenPrice = underlyingPrices[i];
                }

                // If the asset has a CR increment their collateral.
                if (tokenData[snapshot.asset].collRatio != 0) {
                    {
                        (
                            accountData.accountCollateralSoft,
                            accountData.accountCollateralHard
                        ) = _addLiquidationValues(
                            snapshot,
                            account,
                            underlyingPrices[i],
                            accountData.accountCollateralSoft,
                            accountData.accountCollateralHard
                        );
                    }
                }
            } else {
                if (snapshot.asset == eToken) {
                    earnTokenPrice = underlyingPrices[i];
                }

                // If they have a debt balance,
                // we need to document collateral requirements.
                if (snapshot.debtBalance > 0) {
                    accountData.accountDebt += _assetValue(
                        snapshot.debtBalance,
                        underlyingPrices[i],
                        10 ** snapshot.decimals,
                        false
                    );
                }
            }
        }

        lFactor = _getLFactor(
            accountData.accountCollateralSoft,
            accountData.accountCollateralHard,
            accountData.accountDebt
        );
    }

    /// @notice Evaluates an account's collateral and debt positions to
    ///         determine liquidation factor using cached data.
    /// @param account The address of the account being evaluated for
    ///                 liquidation.
    /// @param action A CachedLiqData struct containing:
    ///               pToken The address of the collateral token (pToken).
    ///               eToken The address of the debt token (eToken).
    ///               pTokenExchangeRate The exchange rate for the pToken.
    ///               pTokenDecimals The number of decimals for the pToken.
    ///               pTokenCollReqSoft The soft collateral requirement for the
    ///                                 pToken.
    ///               pTokenCollReqHard The hard collateral requirement for the
    ///                                 pToken.
    ///               pTokenUnderlyingPrice The price of the underlying asset for
    ///                                     the pToken.
    
    ///               eTokenDecimals The number of decimals for the eToken.
    ///               eTokenUnderlyingPrice The price of the underlying asset for
    ///                                     the eToken.
    ///               auctionBuffer An optional buffer multiplier applied to soft
    ///                             collateral (WAD-scaled, use 0 for no buffer).
    ///  @return lFactor The liquidation factor for `account`.
    ///  @return debt The current debt position in `eToken` for `account`.
    function _liquidationValuesOfCached(
        address account,
        CachedLiqData memory cachedData
    )
        internal
        view
        returns (uint256 lFactor, uint256 debt)
    {
        AccountLiqData memory accountData;
        IMToken[] memory assets = accountAssets[account].assets;

        {
            address cachedAsset;
            // We cannot cache assets.length as we'd run into a
            // stack too deep compiler error here.
            for (uint256 i; i < assets.length;) {
                cachedAsset = address(assets[i++]);
                if (cachedAsset == cachedData.pToken) {
                    // NOTE: We already check collRatio in _canLiquidate and
                    // theres one pToken in an isolated non-rehypothecated market
                    // so we do not need to check again.
                    (
                        accountData.accountCollateralSoft,
                        accountData.accountCollateralHard
                    ) = _addLiquidationValuesCached(
                            cachedData.pTokenExchangeRate,
                            cachedData.pTokenDecimals,
                            cachedData.pTokenCollReqSoft,
                            cachedData.pTokenCollReqHard,
                            cachedData.pTokenUnderlyingPrice,
                            tokenData[cachedAsset]
                                .accountPositions[account].collateralPosted,
                            accountData.accountCollateralSoft,
                            accountData.accountCollateralHard
                    );
                } else {
                    // If the asset is not the pToken, the asset must be an `eToken`
                    // debt position because this market is limited to one
                    // pToken and one eToken.
                    debt = IEToken(cachedData.eToken).debtBalanceCached(account);
                    // If they have a debt balance,
                    // we need to document collateral requirements.
                    if (debt > 0) {
                        accountData.accountDebt += _assetValue(
                            debt,
                            cachedData.eTokenUnderlyingPrice,
                            cachedData.eTokenDecimals,
                            false
                        );
                    }
                }
            }
        }

        // If this is a potential liquidation from an auction, apply the
        // auction buffer to collateral values, discounting collateral values.
        if (cachedData.auctionBuffer != 0) {
            accountData.accountCollateralSoft =
                (accountData.accountCollateralSoft * cachedData.auctionBuffer) / WAD;
            accountData.accountCollateralHard =
                (accountData.accountCollateralHard * cachedData.auctionBuffer) / WAD;
        }

        lFactor = _getLFactor(
            accountData.accountCollateralSoft,
            accountData.accountCollateralHard,
            accountData.accountDebt
        );
    }

    ///  @notice Calculates the liquidation factor (LFactor) for an account
    ///          based on their collateral and debt positions.
    ///  @dev Determines whether an account is in a no-liquidation,
    ///       soft-liquidation, or hard-liquidation state.
    ///  @param collateralSoft The account's soft collateral value
    ///                        (collateral adjusted by soft requirements).
    ///  @param collateralHard The account's hard collateral value
    ///                        (collateral adjusted by hard requirements).
    ///  @param debt The account's total debt value.
    ///  @return result The liquidation factor where:
    ///          - 0: No liquidation (account is healthy).
    ///          - 1 to WAD-1: Soft liquidation (partial liquidation allowed).
    ///          - WAD: Hard liquidation (full liquidation, possibly including
    ///                 bad debt).
    function _getLFactor(
        uint256 collateralSoft,
        uint256 collateralHard,
        uint256 debt
    ) internal pure returns (uint256 result) {
        // Indicates no liquidation.
        if (collateralSoft >= debt) {
            return result;
        }

        // Indicates hard liquidation (may also include bad debt has
        // accumulated).
        if (debt >= collateralHard) {
            result = WAD;
            return result;
        }

        // Indicates soft liquidation.
        result = ((debt - collateralSoft) * WAD) /
            (collateralHard - collateralSoft);

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
            return FixedPointMathLib.mulDiv(amount, price, decimals);
        }

        return FixedPointMathLib.mulDivUp(amount, price, decimals);
    }

    /// @notice Calculates a redemption's value based on its `amount`,
    ///         `exchangeRate`, `price`, `collRatio`, and adjusts for
    ///         token decimals.
    /// @param amount The asset amount to redeem.
    /// @param exchangeRate The exchange rate between pToken and underlying.
    /// @param price The asset's price, in `WAD`.
    /// @param decimals The asset's decimals to adjust redemption value
    ///                 into proper form.
    /// @param collRatio The collateralization ratio of the asset.
    /// @return The calculated redemption value.
    function _redemptionValue(
        uint256 amount,
        uint256 exchangeRate,
        uint256 price,
        uint256 decimals,
        uint256 collRatio
    ) internal pure returns (uint256) {
        uint256 assetValue = _assetValue(
            (amount * exchangeRate) / WAD,
            price,
            decimals,
            false
        );

        // Hypothetical redemption action.
        return ((assetValue * collRatio) / WAD);
    }

    /// @notice Calculates asset liquidity for the purpose of borrowing
    ///         assets.
    /// @param liqForBorrowPrior Prior liquidity value to sum with asset value
    ///                          calculated for new maximum borrow allowed.
    /// @param posted Current collateral posted.
    /// @param exchangeRate The exchange rate between pToken and underlying.
    /// @param price The asset's price, in `WAD`.
    /// @param decimals The asset's decimals to adjust liquidity value
    ///                 into proper form.
    /// @param collRatio The collateralization ratio of the asset.
    /// @return The calculated liquidity value plus previous value.
    function _addLiquidityValue(
        uint256 liqForBorrowPrior,
        uint256 posted,
        uint256 exchangeRate,
        uint256 price,
        uint256 decimals,
        uint256 collRatio
    ) internal pure returns (uint256) {
        uint256 assetValue = _assetValue(
            ((posted * exchangeRate) / WAD),
            price,
            decimals,
            true
        );

        return (liqForBorrowPrior + (assetValue * collRatio) / WAD);
    }

    /// @notice Calculates and adds soft and hard collateral values for
    ///         liquidation assessment.
    /// @param snapshot Asset snapshot to calculate asset value from.
    /// @param account The account to query collateral posted for to calculate
    ///                liquidation values off of.
    /// @param price The price of the underlying asset, in `WAD`.
    /// @param softSumPrior The previous sum of soft collateral values.
    /// @param hardSumPrior The previous sum of hard collateral values.
    /// @return uint256 The updated sum of soft collateral values.
    /// @return uint256 The updated sum of hard collateral values.
    function _addLiquidationValues(
        AccountSnapshot memory snapshot,
        address account,
        uint256 price,
        uint256 softSumPrior,
        uint256 hardSumPrior
    ) internal view returns (uint256, uint256) {
        address asset = snapshot.asset;
        return _addLiquidationValuesCached(
            snapshot.exchangeRate,
            10 ** snapshot.decimals,
            tokenData[asset].collReqSoft,
            tokenData[asset].collReqHard,
            price,
            tokenData[asset].accountPositions[account].collateralPosted,
            softSumPrior,
            hardSumPrior
        );
    }

    /// @notice Calculates and adds soft and hard collateral values for
    ///         liquidation assessment with cached data.
    /// @param exchangeRate The exchange rate between the collateral token
    ///                     and its underlying asset (WAD-scaled).
    /// @param decimals The number of decimals for the collateral token.
    /// @param collReqSoft The soft collateral requirement ratio (WAD-scaled).
    /// @param collReqHard The hard collateral requirement ratio (WAD-scaled).
    /// @param price The price of the underlying asset, in `WAD`.
    /// @param collateralPosted The amount of collateral token posted as
    ///                         collateral by the account.
    /// @param softSumPrior The previous sum of soft collateral values.
    /// @param hardSumPrior The previous sum of hard collateral values.
    /// @return uint256 The updated sum of soft collateral values.
    /// @return uint256 The updated sum of hard collateral values.
    function _addLiquidationValuesCached(
        uint256 exchangeRate,
        uint256 decimals,
        uint256 collReqSoft,
        uint256 collReqHard,
        uint256 price,
        uint256 collateralPosted,
        uint256 softSumPrior,
        uint256 hardSumPrior
    ) internal pure returns (uint256, uint256) {
        uint256 assetValue = _assetValue(
            ((collateralPosted * exchangeRate) / WAD),
            price,
            decimals,
            true
        ) * WAD;

        return (
            softSumPrior + (assetValue / collReqSoft),
            hardSumPrior + (assetValue / collReqHard)
        );
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
