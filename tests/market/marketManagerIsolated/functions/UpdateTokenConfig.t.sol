// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { BPS, CAUTION, BAD_SOURCE } from "contracts/libraries/ConstantsLib.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";

contract UpdateTokenConfigTest is TestBaseMarketIsolated {

    function setUp() public override {
        super.setUp();

        _prepareUSDC(address(this), 77777);
        _prepareDAI(address(this), 77777);
        deal(address(LP_wstETH_24Dec2025), address(this), 77777);

        usdc.approve(address(borrowableCUSDC), 77777);
        dai.approve(address(borrowableCDAI), 77777);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 77777);
    }

    function test_updateTokenConfig_fail_whenCallerIsNotAuthorized() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(borrowableCDAI));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(borrowableCUSDC);
        tokenConfig.collRatio = 7000;
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.closeFactorMin = 2000;
        tokenConfig.closeFactorMax = 5000;
        tokenConfig.closeFactorBase = 2000;
        tokenConfig.collateralCap = 1_000_000e6;
        tokenConfig.debtCap = 1_000_000e6;

        vm.prank(user2);
        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_updateTokenConfig_fail_whenCTokenIsNotListed() public {
        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(borrowableCUSDC);
        tokenConfig.collRatio = 7000;
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.closeFactorMin = 2000;
        tokenConfig.closeFactorMax = 5000;
        tokenConfig.closeFactorBase = 2000;
        tokenConfig.collateralCap = 1_000_000e6;
        tokenConfig.debtCap = 1_000_000e6;

        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig); 
    }

    function test_updateTokenConfig_fail_whenCollRatioIsTooHigh() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(pendleStrategyCTokenSTETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(pendleStrategyCTokenSTETH);
        tokenConfig.collRatio = 9900;    // collRatio 99%, above max of 98%
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.closeFactorMin = 2000;
        tokenConfig.closeFactorMax = 5000;
        tokenConfig.closeFactorBase = 2000;
        tokenConfig.collateralCap = 1_000_000e6;
        tokenConfig.debtCap = 0;

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_updateTokenConfig_fail_whenSoftReqIsTooHigh() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(pendleStrategyCTokenSTETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(pendleStrategyCTokenSTETH);
        tokenConfig.collRatio = 7000; 
        tokenConfig.collReqSoft = 23500;    // collReqSoft 235% (above max of 234%)
        tokenConfig.collReqHard = 5000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.closeFactorMin = 2000;
        tokenConfig.closeFactorMax = 5000;
        tokenConfig.closeFactorBase = 2000;
        tokenConfig.collateralCap = 1_000_000e6;
        tokenConfig.debtCap = 0;

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_updateTokenConfig_fail_whenHardReqHigherThanSoftReq() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(pendleStrategyCTokenSTETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(pendleStrategyCTokenSTETH);
        tokenConfig.collRatio = 7000; 
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 5000;     //(should be < collReqSoft)
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.closeFactorMin = 2000;
        tokenConfig.closeFactorMax = 5000;
        tokenConfig.closeFactorBase = 2000;
        tokenConfig.collateralCap = 1_000_000e6;
        tokenConfig.debtCap = 0;

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_updateTokenConfig_fail_whenLiqIncBaseIsLargerThanLiqIncHard() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(pendleStrategyCTokenSTETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(pendleStrategyCTokenSTETH);
        tokenConfig.collRatio = 7000; 
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1500;
        tokenConfig.liqIncHard = 1400; //      (should be >=liqIncBase)
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.closeFactorMin = 2000;
        tokenConfig.closeFactorMax = 5000;
        tokenConfig.closeFactorBase = 2000;
        tokenConfig.collateralCap = 1_000_000e6;
        tokenConfig.debtCap = 0;

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_updateTokenConfig_fail_whenLiqIncBaseIsLargerThanLiqIncMax() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(pendleStrategyCTokenSTETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(pendleStrategyCTokenSTETH);
        tokenConfig.collRatio = 7000; 
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1500;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 1400;   //      (should be >=liqBase)
        tokenConfig.closeFactorMin = 2000;
        tokenConfig.closeFactorMax = 5000;
        tokenConfig.closeFactorBase = 2000;
        tokenConfig.collateralCap = 1_000_000e6;
        tokenConfig.debtCap = 0;

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_updateTokenConfig_fail_whenLiqIncMinIsLargerThanLiqIncMax() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(pendleStrategyCTokenSTETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(pendleStrategyCTokenSTETH);
        tokenConfig.collRatio = 7000; 
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1500;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 2100;
        tokenConfig.liqIncMax = 2000; //      (should be >=liqIncMin)
        tokenConfig.closeFactorMin = 2000;
        tokenConfig.closeFactorMax = 5000;
        tokenConfig.closeFactorBase = 2000;
        tokenConfig.collateralCap = 1_000_000e6;
        tokenConfig.debtCap = 0;

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_updateTokenConfig_fail_whenLiqIncMaxIsTooHigh() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(pendleStrategyCTokenSTETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(pendleStrategyCTokenSTETH);
        tokenConfig.collRatio = 7000; 
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 3100;   // (max is 30%)
        tokenConfig.closeFactorMin = 2000;
        tokenConfig.closeFactorMax = 5000;
        tokenConfig.closeFactorBase = 2000;
        tokenConfig.collateralCap = 1_000_000e6;
        tokenConfig.debtCap = 0;

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_updateTokenConfig_fail_CollateralBufferIsTooLowFromliqIncHard() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(pendleStrategyCTokenSTETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(pendleStrategyCTokenSTETH);
        tokenConfig.collRatio = 7000; 
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 1000;  
        tokenConfig.liqIncBase = 700;
        tokenConfig.liqIncHard = 900; //     9% ((9 + 1.5% buffer) = 10.5%) > 10% collReqHard
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 1500;
        tokenConfig.closeFactorMin = 2000;
        tokenConfig.closeFactorMax = 5000;
        tokenConfig.closeFactorBase = 2000;
        tokenConfig.collateralCap = 1_000_000e6;
        tokenConfig.debtCap = 0;

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_updateTokenConfig_fail_CollateralBufferIsTooLowFromLiqIncMax() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(pendleStrategyCTokenSTETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(pendleStrategyCTokenSTETH);
        tokenConfig.collRatio = 7000; 
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 1000;  
        tokenConfig.liqIncBase = 700;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 900; //     9% ((9 + 1.5% buffer) = 10.5%) > 10% collReqHard
        tokenConfig.closeFactorMin = 2000;
        tokenConfig.closeFactorMax = 5000;
        tokenConfig.closeFactorBase = 2000;
        tokenConfig.collateralCap = 1_000_000e6;
        tokenConfig.debtCap = 0;

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_updateTokenConfig_fail_whenCloseFactorBaseisTooLow() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(pendleStrategyCTokenSTETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(pendleStrategyCTokenSTETH);
        tokenConfig.collRatio = 7000; 
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.closeFactorMin = 2000;
        tokenConfig.closeFactorMax = 5000;
        tokenConfig.closeFactorBase = 900;      // closeFactorBase is 9% (min is 10%)
        tokenConfig.collateralCap = 1_000_000e6;
        tokenConfig.debtCap = 0;

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_updateTokenConfig_fail_whenCloseFactorBaseisTooHigh() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(pendleStrategyCTokenSTETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(pendleStrategyCTokenSTETH);
        tokenConfig.collRatio = 7000; 
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.closeFactorMin = 2000;
        tokenConfig.closeFactorMax = 5000;
        tokenConfig.closeFactorBase = 5100;      // closeFactorBase 51% (max is 50%)
        tokenConfig.collateralCap = 1_000_000e6;
        tokenConfig.debtCap = 0;

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_updateTokenConfig_fail_whenCollReqSoftCollateralPremiumTooHighVersusCollRatio() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(pendleStrategyCTokenSTETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(pendleStrategyCTokenSTETH);
        tokenConfig.collRatio = 7000; 
        tokenConfig.collReqSoft = 20000; // 200% collateral requirement to avoid liquidation, not possible with 70% collRatio.
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.closeFactorMin = 2000;
        tokenConfig.closeFactorMax = 5000;
        tokenConfig.closeFactorBase = 2000;
        tokenConfig.collateralCap = 1_000_000e6;
        tokenConfig.debtCap = 0;

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_updateTokenConfig_fail_whenDebtCapAboveZeroWhenCTokenIsNotBorrowable() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(pendleStrategyCTokenSTETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(pendleStrategyCTokenSTETH);
        tokenConfig.collRatio = 7000;
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.closeFactorMin = 2000;
        tokenConfig.closeFactorMax = 5000;
        tokenConfig.closeFactorBase = 2000;
        tokenConfig.collateralCap = 1_000_000e6;
        tokenConfig.debtCap = 1_000_000e6;

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_updateTokenConfig_fail_debtCapAboveMaxDebtCap() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(borrowableCDAI));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(borrowableCDAI);
        tokenConfig.collRatio = 7000; 
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.closeFactorMin = 2000;
        tokenConfig.closeFactorMax = 5000;
        tokenConfig.closeFactorBase = 2000;
        tokenConfig.collateralCap = 100_000e18;
        tokenConfig.debtCap = 9e40; // Cap for debt limits in 2^136-1 or 8.71e40.

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_updateTokenConfig_fail_whenOracleManagerCannotPriceCToken() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(borrowableCDAI));

        // Remove the underlying price adaptors so cToken pricing will fail.
        oracleManager.removeAssetPricingAdaptor(
            _DAI_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleManager.removeAssetPricingAdaptor(
            _DAI_ADDRESS,
            address(dualChainlinkAdaptor)
        );

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(borrowableCDAI);
        tokenConfig.collRatio = 7000; 
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.closeFactorMin = 2000;
        tokenConfig.closeFactorMax = 5000;
        tokenConfig.closeFactorBase = 2000;
        tokenConfig.collateralCap = 100_000e18;
        tokenConfig.debtCap = 100_000e18;

        // We expect pricing failure here on call.
        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_updateTokenConfig_success_whenCTokenOracleInCaution() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(borrowableCDAI));

        _setUsdcDualFeedAnswer(1.016e8, CAUTION);
        (, uint256 cTokenErrorCode) =
            oracleManager.getPrice(address(borrowableCUSDC), true, true);
        assertEq(cTokenErrorCode, CAUTION, "cToken should inherit CAUTION");

        MarketManagerIsolated.TokenConfig memory tokenConfig =
            _validBorrowableTokenConfig(address(borrowableCUSDC));

        marketManagerIsolated.updateTokenConfig(tokenConfig);

        (uint256 collRatio, uint256 collReqSoft, uint256 collReqHard) =
            marketManagerIsolated.collConfig(address(borrowableCUSDC));
        assertEq(collRatio, tokenConfig.collRatio);
        assertEq(collReqSoft, tokenConfig.collReqSoft + BPS);
        assertEq(collReqHard, tokenConfig.collReqHard + BPS);
    }

    function test_updateTokenConfig_fail_whenCTokenOracleInBadSource() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(borrowableCDAI));

        _setUsdcDualFeedAnswer(1.03e8, BAD_SOURCE);
        (, uint256 cTokenErrorCode) =
            oracleManager.getPrice(address(borrowableCUSDC), true, true);
        assertEq(cTokenErrorCode, BAD_SOURCE, "cToken should inherit BAD_SOURCE");

        MarketManagerIsolated.TokenConfig memory tokenConfig =
            _validBorrowableTokenConfig(address(borrowableCUSDC));

        vm.expectRevert(MarketManagerIsolated.MarketManager__PriceError.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_updateTokenConfig_fail_whenCTokenOracleFeedIsStale() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(borrowableCDAI));

        _makeDefaultUsdcFeedsStale(BAD_SOURCE);
        (, uint256 cTokenErrorCode) =
            oracleManager.getPrice(address(borrowableCUSDC), true, true);
        assertEq(cTokenErrorCode, BAD_SOURCE, "cToken should inherit stale BAD_SOURCE");

        MarketManagerIsolated.TokenConfig memory tokenConfig =
            _validBorrowableTokenConfig(address(borrowableCUSDC));

        vm.expectRevert(MarketManagerIsolated.MarketManager__PriceError.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_updateTokenConfig_fail_whenCTokenOraclePriceGuardFlagsBadSource()
        public
    {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(borrowableCDAI));

        chainlinkAdaptor.setGuardedPriceConfig(
            _USDC_ADDRESS,
            true,
            0,
            0,
            2e18,
            99e16
        );
        dualChainlinkAdaptor.setGuardedPriceConfig(
            _USDC_ADDRESS,
            true,
            0,
            0,
            2e18,
            99e16
        );

        mockUsdcFeed.setMockAnswer(0.98e8);
        _setUsdcDualFeedAnswer(0.98e8, BAD_SOURCE);

        MarketManagerIsolated.TokenConfig memory tokenConfig =
            _validBorrowableTokenConfig(address(borrowableCUSDC));

        vm.expectRevert(MarketManagerIsolated.MarketManager__PriceError.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_updateTokenConfig_fail_whenCollateralCapTurnedOnWithoutCollateralization() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(pendleStrategyCTokenSTETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(pendleStrategyCTokenSTETH);
        tokenConfig.collRatio = 0; 
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.closeFactorMin = 2000;
        tokenConfig.closeFactorMax = 5000;
        tokenConfig.closeFactorBase = 2000;
        tokenConfig.collateralCap = 100_000e18;
        tokenConfig.debtCap = 0;

        // Will fail because collateralization should not be possible with
        // coll ratio set to 0.
        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_updateTokenConfig_fail_TurnOffCollateralizationWithoutCollateralCap() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(pendleStrategyCTokenSTETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(pendleStrategyCTokenSTETH);
        tokenConfig.collRatio = 7000; 
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.closeFactorMin = 2000;
        tokenConfig.closeFactorMax = 5000;
        tokenConfig.closeFactorBase = 2000;
        tokenConfig.collateralCap = 0;
        tokenConfig.debtCap = 0;

        marketManagerIsolated.updateTokenConfig(tokenConfig);

        tokenConfig.collRatio = 0; 

        // Will fail because coll ratio cannot be set to 0 after being set above 0.
        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_updateTokenConfig_fail_TurnOffCollateralizationWithCollateralCap() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(pendleStrategyCTokenSTETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(pendleStrategyCTokenSTETH);
        tokenConfig.collRatio = 7000; 
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.closeFactorMin = 2000;
        tokenConfig.closeFactorMax = 5000;
        tokenConfig.closeFactorBase = 2000;
        tokenConfig.collateralCap = 1000e18;
        tokenConfig.debtCap = 0;

        marketManagerIsolated.updateTokenConfig(tokenConfig);

        tokenConfig.collRatio = 0; 

        // Will fail because coll ratio cannot be set to 0 after being set above 0.
        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_updateTokenConfig_success_strategyCTokenAndBorrowableCToken() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(pendleStrategyCTokenSTETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(pendleStrategyCTokenSTETH);
        tokenConfig.collRatio = 7000; 
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.closeFactorMin = 2000;
        tokenConfig.closeFactorMax = 5000;
        tokenConfig.closeFactorBase = 2000;
        tokenConfig.collateralCap = 100_000e18;
        tokenConfig.debtCap = 0;

        marketManagerIsolated.updateTokenConfig(tokenConfig);

        tokenConfig.cToken = address(borrowableCUSDC);
        tokenConfig.debtCap = 100_000e18;

        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_updateTokenConfig_success_twoBorrowableCTokens() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(borrowableCDAI));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(borrowableCDAI);
        tokenConfig.collRatio = 7000; 
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.closeFactorMin = 2000;
        tokenConfig.closeFactorMax = 5000;
        tokenConfig.closeFactorBase = 2000;
        tokenConfig.collateralCap = 100_000e18;
        tokenConfig.debtCap = 100_000e18;

        marketManagerIsolated.updateTokenConfig(tokenConfig);

        tokenConfig.cToken = address(borrowableCUSDC);

        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_updateTokenConfig_fail_whenLiqIncMinIsZero() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(pendleStrategyCTokenSTETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(pendleStrategyCTokenSTETH);
        tokenConfig.collRatio = 7000;
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 0; // Invalid
        tokenConfig.liqIncMax = 2000;
        tokenConfig.closeFactorMin = 2000;
        tokenConfig.closeFactorMax = 5000;
        tokenConfig.closeFactorBase = 2000;
        tokenConfig.collateralCap = 1_000_000e18;
        tokenConfig.debtCap = 0;

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_updateTokenConfig_fail_whenCloseFactorMinGreaterThanEqualToCloseFactorMax() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(pendleStrategyCTokenSTETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(pendleStrategyCTokenSTETH);
        tokenConfig.collRatio = 7000;
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.closeFactorBase = 2000;
        tokenConfig.closeFactorMin = 6000;
        tokenConfig.closeFactorMax = 6000; // min >= max -> invalid
        tokenConfig.collateralCap = 100_000e18;
        tokenConfig.debtCap = 0;

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_updateTokenConfig_fail_whenCloseFactorMaxAboveBPS() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(pendleStrategyCTokenSTETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(pendleStrategyCTokenSTETH);
        tokenConfig.collRatio = 7000;
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.closeFactorBase = 2000;
        tokenConfig.closeFactorMin = 2000;
        tokenConfig.closeFactorMax = 10001; // > BPS (10000) -> invalid
        tokenConfig.collateralCap = 100_000e18;
        tokenConfig.debtCap = 0;

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_updateTokenConfig_fail_whenLiqIncHardAboveMax() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(pendleStrategyCTokenSTETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(pendleStrategyCTokenSTETH);
        tokenConfig.collRatio = 7000;
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 3100; // > MAX_LIQUIDATION_INCENTIVE (3000)
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.closeFactorMin = 2000;
        tokenConfig.closeFactorMax = 5000;
        tokenConfig.closeFactorBase = 2000;
        tokenConfig.collateralCap = 100_000e18;
        tokenConfig.debtCap = 0;

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_updateTokenConfig_fail_whenCloseFactorMinIsZero() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(borrowableCDAI));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(borrowableCDAI);
        tokenConfig.collRatio = 7000; 
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.closeFactorMin = 0; // Invalid
        tokenConfig.closeFactorMax = 5000;
        tokenConfig.closeFactorBase = 2000;
        tokenConfig.collateralCap = 100_000e18;
        tokenConfig.debtCap = 100_000e18;

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);

    }

    function _validBorrowableTokenConfig(
        address cToken
    ) internal pure returns (MarketManagerIsolated.TokenConfig memory tokenConfig) {
        tokenConfig.cToken = cToken;
        tokenConfig.collRatio = 7000;
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.closeFactorMin = 2000;
        tokenConfig.closeFactorMax = 5000;
        tokenConfig.closeFactorBase = 2000;
        tokenConfig.collateralCap = 100_000e18;
        tokenConfig.debtCap = 100_000e18;
    }

    function _setUsdcDualFeedAnswer(
        int256 answer,
        uint256 expectedErrorCode
    ) internal {
        MockV3Aggregator usdcFeed = new MockV3Aggregator(8, answer);
        dualChainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            true,
            address(usdcFeed),
            0
        );

        (, uint256 errorCode) =
            oracleManager.getPrice(_USDC_ADDRESS, true, true);
        assertEq(errorCode, expectedErrorCode, "unexpected USDC oracle status");
    }

    function _makeDefaultUsdcFeedsStale(
        uint256 expectedErrorCode
    ) internal {
        uint256 staleTimestamp =
            block.timestamp - chainlinkAdaptor.DEFAULT_HEARTBEAT() - 1;
        mockUsdcFeed.setMockUpdatedAt(staleTimestamp);

        (, uint256 errorCode) =
            oracleManager.getPrice(_USDC_ADDRESS, true, true);
        assertEq(errorCode, expectedErrorCode, "unexpected stale USDC status");
    }

}
