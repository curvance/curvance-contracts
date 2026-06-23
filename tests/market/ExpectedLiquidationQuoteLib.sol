// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IBorrowableCToken} from "contracts/interfaces/IBorrowableCToken.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {ICToken} from "contracts/interfaces/ICToken.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {IMarketManager} from "contracts/interfaces/IMarketManager.sol";
import {IOracleManager} from "contracts/interfaces/IOracleManager.sol";
import {
    BAD_SOURCE,
    BPS,
    WAD,
    WAD_SQUARED,
    WAD_SQUARED_BPS_OFFSET
} from "contracts/libraries/ConstantsLib.sol";
import {
    FixedPointMathLib
} from "contracts/libraries/external/FixedPointMathLib.sol";

/// @notice Test-only mirror of the current `MarketManagerIsolated._canLiquidate`
///         quote math used by stateful liquidation handlers.
library ExpectedLiquidationQuoteLib {
    struct ExpectedQuote {
        bool valid;
        uint256 debtRepaid;
        uint256 collateralSeized;
        uint256 badDebt;
    }

    struct Config {
        uint256 collateralPrice;
        uint256 debtPrice;
        uint256 collateralDecimals;
        uint256 debtDecimals;
        uint256 collReqSoft;
        uint256 collReqHard;
        uint256 liqIncBase;
        uint256 liqIncCurve;
        uint256 closeFactorBase;
        uint256 closeFactorCurve;
    }

    function expectedQuote(
        IMarketManager marketManager,
        ICentralRegistry centralRegistry,
        address collateralToken,
        address debtToken,
        address borrower,
        uint256 debtAmount,
        bool liquidateExact
    ) internal returns (ExpectedQuote memory quote) {
        uint256 debtBalance = IBorrowableCToken(debtToken)
            .debtBalance(borrower);
        uint256 sharesPosted =
            ICToken(collateralToken).collateralPosted(borrower);
        if (debtBalance == 0 || sharesPosted == 0) {
            return quote;
        }

        Config memory config = _config(
            marketManager, centralRegistry, collateralToken, debtToken
        );
        (uint256 lFactor, uint256 debtToCollateral) =
            _riskValues(config, sharesPosted, debtBalance);
        if (lFactor == 0) {
            return quote;
        }

        uint256 closeFactor = config.closeFactorBase
            + FixedPointMathLib.mulDiv(config.closeFactorCurve, lFactor, WAD);
        uint256 maxDebt = (closeFactor * debtBalance) / BPS;
        if (!liquidateExact) {
            debtAmount = maxDebt;
        }

        uint256 collateralSeized = FixedPointMathLib.fullMulDiv(
            debtAmount, debtToCollateral, WAD_SQUARED
        );
        if (liquidateExact) {
            if (debtAmount > maxDebt || collateralSeized > sharesPosted) {
                return quote;
            }
        } else if (collateralSeized > sharesPosted) {
            debtAmount = FixedPointMathLib.fullMulDivUp(
                debtAmount, sharesPosted, collateralSeized
            );
            collateralSeized = sharesPosted;
        }

        quote.valid = debtAmount > 0;
        quote.debtRepaid = debtAmount;
        quote.collateralSeized = collateralSeized;
        quote.badDebt =
            _badDebt(debtBalance, debtAmount, debtToCollateral, sharesPosted);
    }

    function _config(
        IMarketManager marketManager,
        ICentralRegistry centralRegistry,
        address collateralToken,
        address debtToken
    ) private returns (Config memory config) {
        IOracleManager oracleManager =
            IOracleManager(centralRegistry.oracleManager());
        (config.collateralPrice, config.debtPrice) =
            oracleManager.getPriceIsolatedPair(
                collateralToken, debtToken, BAD_SOURCE
            );

        (, config.collReqSoft, config.collReqHard) =
            marketManager.collConfig(collateralToken);
        (
            config.liqIncBase,
            config.liqIncCurve,,,
            config.closeFactorBase,
            config.closeFactorCurve,,
        ) = marketManager.liquidationConfig(collateralToken);

        config.collateralDecimals = 10 ** IERC20(collateralToken).decimals();
        config.debtDecimals = 10 ** IERC20(debtToken).decimals();
    }

    function _riskValues(
        Config memory config,
        uint256 sharesPosted,
        uint256 debtBalance
    ) private pure returns (uint256 lFactor, uint256 debtToCollateral) {
        uint256 collateralValue = FixedPointMathLib.mulDiv(
            sharesPosted, config.collateralPrice, config.collateralDecimals
        ) * BPS;
        uint256 cSoft = collateralValue / config.collReqSoft;
        uint256 cHard = collateralValue / config.collReqHard;
        uint256 debtValue = FixedPointMathLib.mulDivUp(
            debtBalance, config.debtPrice, config.debtDecimals
        );

        if (cSoft >= debtValue) {
            return (0, 0);
        }

        lFactor = debtValue >= cHard
            ? WAD
            : FixedPointMathLib.mulDivUp(debtValue - cSoft, WAD, cHard - cSoft);

        uint256 liqInc = config.liqIncBase
            + FixedPointMathLib.mulDiv(config.liqIncCurve, lFactor, WAD);
        debtToCollateral = FixedPointMathLib.fullMulDiv(
            FixedPointMathLib.fullMulDiv(
                liqInc * config.debtPrice,
                WAD_SQUARED_BPS_OFFSET,
                config.collateralPrice
            ),
            config.collateralDecimals,
            config.debtDecimals
        );
    }

    function _badDebt(
        uint256 debtBalance,
        uint256 debtAmount,
        uint256 debtToCollateral,
        uint256 sharesPosted
    ) private pure returns (uint256) {
        uint256 sharesNeeded =
            FixedPointMathLib.fullMulDivUp(
                debtBalance, debtToCollateral, WAD_SQUARED
            );
        if (sharesNeeded <= sharesPosted) {
            return 0;
        }

        uint256 badDebt = FixedPointMathLib.fullMulDivUp(
            debtAmount, sharesNeeded, sharesPosted
        );

        if (badDebt > debtBalance) {
            return debtBalance - debtAmount;
        }

        return badDebt - debtAmount;
    }
}
