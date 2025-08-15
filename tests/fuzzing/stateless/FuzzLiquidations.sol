// pragma solidity ^0.8.28;

// import { WAD } from "contracts/libraries/ConstantsLib.sol";
// import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
// import { ICToken } from "contracts/interfaces/ICToken.sol";
// import { StatefulBaseMarket } from "tests/fuzzing/StatefulBaseMarket.sol";

// contract FuzzLiquidations is StatefulBaseMarket {
//     /// @notice the position token to be used in liquidations
//     address collateralToken;
//     /// @notice the debt token to be used in liquidations
//     address debtToken;
//     /// @notice the state of the entire system at the time of liquidation
//     struct LiquidationData {
//         bool isListed;
//         uint256 collRatio;
//         uint256 collReqSoft;
//         uint256 collReqHard;
//         uint256 liqBaseIncentive;
//         uint256 liqCurve;
//         uint256 closeFactorBase;
//         uint256 closeFactorCurve;
//         uint256 lFactor;
//         uint256 debtTokenPrice;
//         uint256 collateralTokenPrice;
//         uint256 debtBalance;
//         uint256 exchangeRate;
//     }
//     LiquidationData data;
//     /// @notice how much the liquidator is intending to liquidate
//     uint256 debtAmount;
//     /// @notice stores intermediate calculated values as those that match the canLiquidate function
//     struct IntermediateValues {
//         uint256 cFactor;
//         uint256 incentive;
//         uint256 maxAmount;
//         uint256 debtToCollateralRatio;
//         uint256 amountAdjusted;
//         uint256 liquidatedTokens;
//         uint256 liquidatedTokenToProtocol;
//     }
//     /// @notice stores intermediate calculated values
//     IntermediateValues calculated;

//     constructor() {
//         collateralToken = address(pUSDC);
//         debtToken = address(borrowableCDAI);
//     }

//     /// @notice stores failed steps and error codes
//     mapping(uint256 => HasError) errors;
//     struct HasError {
//         bool err;
//         string msg;
//     }

//     function calculateLiquidation_exact(
//         uint256 amount,
//         bool liquidateExact
//     ) internal returns (uint256[] memory error_id, string[] memory msgs) {
//         // Setup state
//         debtAmount = amount;
//         _saveCurrentState();

//         // Arithmetic calculation
//         _calculateCFactor();
//         _calculateIncentive();
//         _calculateMaxAmount();
//         _calculateDebtToCollateralRatio();
//         _calculateAmountAdjusted();
//         _calculateLiquidatedTokens();

//         (
//             uint256 _canLiq_debt,
//             uint256 _canLiq_liquidatedTokens
//         ) = marketManager.canLiquidate(
//                 debtToken,
//                 collateralToken,
//                 address(this),
//                 amount,
//                 liquidateExact
//             );

//         assertEq(
//             debtAmount,
//             _canLiq_debt,
//             "LIQUIDATIONS - expected calculated debtAmount = can liquidate debt"
//         );
//         assertEq(
//             calculated.liquidatedTokens,
//             _canLiq_liquidatedTokens,
//             "LIQUIDATED - expected liquidated tokens = can liquidate liquidate"
//         );

//         bool hadError;
//         uint8 index;
//         for (uint8 i = 0; i < 13; i++) {
//             HasError memory has = errors[i];
//             if (has.err) {
//                 hadError = true;
//                 error_id[index] += i;
//                 msgs[index] = has.msg;
//                 index++;
//                 emit LogUint256("Liquidation arithmetic errored:", i);
//             }
//         }
//         return (error_id, msgs);
//     }

//     /// @notice saves token data and liquidation status of system
//     function _saveCurrentState() private {
//         (
//             bool isListed,
//             uint256 collRatio,
//             uint256 collReqSoft,
//             uint256 collReqHard,
//             uint256 liqBaseIncentive,
//             uint256 liqCurve,
//             uint256 closeFactorBase,
//             uint256 closeFactorCurve
//         ) = marketManager.tokenData(collateralToken);
//         (
//             uint256 lFactor,
//             uint256 debtTokenPrice,
//             uint256 collateralTokenPrice
//         ) = marketManager.liquidationStatusOf(
//                 address(this),
//                 debtToken,
//                 collateralToken
//             );
//         uint256 debtBalance = IBorrowableCToken(debtToken).debtBalance(
//             address(this)
//         );
//         uint256 exchangeRate = IBorrowableCToken(debtToken).exchangeRate();

//         data = LiquidationData(
//             isListed,
//             collRatio,
//             collReqSoft,
//             collReqHard,
//             liqBaseIncentive,
//             liqCurve,
//             closeFactorBase,
//             closeFactorCurve,
//             lFactor,
//             debtTokenPrice,
//             collateralTokenPrice,
//             debtBalance,
//             exchangeRate
//         );
//     }

//     /// @custom:property liq-1 The closeFactorBase must be bound between  MIN_BASE_CFACTOR and MAX_BASE_CFACTOR
//     /// @custom:property liq-2 The lFactor must be bound between 1 and WAD.
//     /// @custom:property liq-3 cFactor from calculation must be between WAD and MAX_BASE_CFACTOR
//     /// @custom:precondition closeFactorBase > MIN_BASE_CFACTOR
//     /// @custom:precondition closeFactorBase <= MAX_BASE_CFACTOR
//     /// @custom:precondition lFactor > 0
//     /// @custom:precondition l factor <= WAD
//     function _calculateCFactor() private {
//         // Preconditions
//         if (
//             data.closeFactorBase < marketManager.MIN_BASE_CFACTOR() ||
//             data.closeFactorBase > marketManager.MAX_BASE_CFACTOR()
//         ) {
//             emit LogUint256("data.closeFactorBase", data.closeFactorBase);
//             errors[1] = HasError(
//                 true,
//                 "LIQ-1 - c base c factor must be >= to MIN_BASE_CFACTOR and  <= MAX_BASE_CFACTOR"
//             );
//         }

//         if (data.lFactor <= 0 || data.lFactor > WAD) {
//             emit LogUint256("data.lFactor", data.lFactor);
//             errors[2] = HasError(true, "L factor must be > 0 and <= WAD");
//         }

//         uint256 cFactor = data.closeFactorBase +
//             (data.closeFactorCurve * data.lFactor) /
//             WAD;

//         // Postconditions
//         if (!(cFactor >= data.closeFactorBase && cFactor <= WAD)) {
//             errors[3] = HasError(
//                 true,
//                 "LIQ-3 - c factor result must be bound between [data.closeFactorBase, WAD]"
//             );
//         }

//         calculated.cFactor = cFactor;
//     }

//     /// @custom:property liq-4 incentive must be <= MAX_LIQUIDATION_INCENTIVE
//     /// @custom:property liq-4 incentive must be >= MIN_LIQUIDATION_INCENTIVE
//     /// @custom:property liq-5 resullting incentive must be bound between MIN_LIQUIDATION_INCENTIVE to MAX_LIQUIDATION_INCENTIVE
//     /// @custom:precondition liqBaseIncentive must be <= MAX_LIQUIDATION_INCENTIVE
//     /// @custom:precondition incentive must be >= MIN_LIQUIDATION_INCENTIVE
//     function _calculateIncentive() private {
//         // Preconditions
//         if (
//             // data.liqBaseIncentive <
//             // marketManager.MIN_LIQUIDATION_INCENTIVE() ||
//             data.liqBaseIncentive >
//             marketManager.MAX_LIQUIDATION_INCENTIVE() - 1
//         ) {
//             errors[4] = HasError(
//                 true,
//                 "LIQ-4 - data.liqBaseIncentive must be between [MIN_LIQUIDATION_INCENTIVE, MAX_LIQUIDATION_INCENTIVE]"
//             );
//         }

//         uint256 incentive = data.liqBaseIncentive +
//             (data.liqCurve * data.lFactor) /
//             WAD;

//         // Postconditions
//         if (
//             // incentive < marketManager.MIN_LIQUIDATION_INCENTIVE() ||
//             incentive > marketManager.MAX_LIQUIDATION_INCENTIVE()
//         ) {
//             errors[5] = HasError(
//                 true,
//                 "LIQ-5 - incentive must be between [MIN_LIQUIDATION_INCENTIVE, MAX_LIQUIDATION_INCENTIVE]"
//             );
//         }
//         calculated.incentive = incentive;
//     }

//     /// @custom:property liq-6 if cfactor == 0, maxAmount to be liquidated = 0
//     /// @custom:property liq-7 if cFactor == WAD, maxAmount to be liquidated = debtBalance
//     /// @custom:property liq-8 if cFactor is between [0, WAD], maxAmount to be liquidated must be bound between [0, debtBalance]
//     function _calculateMaxAmount() private {
//         // Preconditions

//         uint256 maxAmount = (calculated.cFactor * data.debtBalance) /
//             WAD;

//         // Postconditions
//         if (calculated.cFactor == 0) {
//             errors[6] = HasError(
//                 true,
//                 "LIQ-6 - maxAmount = 0 when calculated.cFactor = 0"
//             );
//         } else if (calculated.cFactor == WAD) {
//             if (maxAmount != data.debtBalance) {
//                 errors[7] = HasError(
//                     true,
//                     "LIQ-7 - maxAmount = data.debtBalance when calculated.cFactor = WAD"
//                 );
//             }
//         } else {
//             if (maxAmount == 0 || maxAmount > data.debtBalance) {
//                 errors[8] = HasError(
//                     true,
//                     "LIQ-8 - maxAmount must be >0 and <= debt balance cached"
//                 );
//             }
//         }
//         calculated.maxAmount = maxAmount;
//     }

//     /// @custom:notice No property bounds as debt to collateral ratio can be unbounded
//     function _calculateDebtToCollateralRatio() private {
//         // No Preconditions

//         uint256 debtToCollateralRatio = (calculated.incentive *
//             data.debtTokenPrice *
//             WAD) / (data.collateralTokenPrice * data.exchangeRate);

//         // No Postconditions
//         calculated.debtToCollateralRatio = debtToCollateralRatio;
//     }

//     /// @custom:property liq-9 if position token and debt token have the same number of decimals, amountAdjusted = debtBalance
//     /// @custom:property liq-10 if position token decimals > debtTokenDecimals, amountAdjusted > debtBalance
//     /// @custom:property liq-11 if position token decimals < debtTokenDecimals, amountAdjusted < debtBalance
//     function _calculateAmountAdjusted() private {
//         // Saves state
//         uint256 collateralTokenDecimals = ICToken(collateralToken).decimals();
//         uint256 debtTokenDecimals = IBorrowableCToken(debtToken).decimals();

//         uint256 amountAdjusted = (data.debtBalance *
//             10 ** collateralTokenDecimals) / (10 ** debtTokenDecimals);

//         // Postconditions
//         if (collateralTokenDecimals == debtTokenDecimals) {
//             if (amountAdjusted != data.debtBalance) {
//                 errors[9] = HasError(
//                     true,
//                     "LIQ-9 - when collat token dec == debt token dec, amountAdjusted = debtAmount"
//                 );
//             }
//         } else if (collateralTokenDecimals > debtTokenDecimals) {
//             if (amountAdjusted <= data.debtBalance) {
//                 errors[10] = HasError(
//                     true,
//                     "LIQ-10 - amountAdjusted > debtBalance when position token < debt token decimals"
//                 );
//             }
//         } else if (collateralTokenDecimals < debtTokenDecimals) {
//             if (amountAdjusted >= data.debtBalance) {
//                 errors[11] = HasError(
//                     true,
//                     "LIQ-11 - amountAdjusted < debtBalance when position token < debt token decimals"
//                 );
//             }
//         }
//         calculated.amountAdjusted = amountAdjusted;
//     }

//     /// @custom:property liq-12 if amountAdjusted == 0, tokens to be liquidated = 0
//     /// @custom:property liq-13 if debtToCollateralRatio == 0, tokens to be liquidated = 0
//     function _calculateLiquidatedTokens() private {
//         uint256 liquidatedTokens = (calculated.amountAdjusted *
//             calculated.debtToCollateralRatio) / WAD;

//         // Postconditions
//         if (calculated.amountAdjusted == 0) {
//             if (liquidatedTokens != 0) {
//                 errors[12] = HasError(
//                     true,
//                     "LIQ-12 - liquidatedTokens = 0 when amountAdjusted = 0"
//                 );
//             }
//         } else if (calculated.debtToCollateralRatio == 0) {
//             if (liquidatedTokens != 0) {
//                 errors[13] = HasError(
//                     true,
//                     "LIQ-13 - liquidatedTokens = 0 when amountAdjusted = 0"
//                 );
//             }
//         }
//         calculated.liquidatedTokens = liquidatedTokens;
//     }
// }
