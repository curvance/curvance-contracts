// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract UpdateTokenConfigTest is TestBaseMarketIsolated {

    function setUp() public override {
        super.setUp();

        _prepareUSDC(address(this), 77777);
        _prepareDAI(address(this), 77777);
        _prepareBALRETH(address(this), 77777);

        usdc.approve(address(borrowableCUSDC), 77777);
        dai.approve(address(borrowableCDAI), 77777);
        balRETH.approve(address(strategyCBALRETH), 77777);
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
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(strategyCBALRETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(strategyCBALRETH);
        tokenConfig.collRatio = 9950;    // collRatio 99.5% (above max of 97.5)
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
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(strategyCBALRETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(strategyCBALRETH);
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
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(strategyCBALRETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(strategyCBALRETH);
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
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(strategyCBALRETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(strategyCBALRETH);
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
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(strategyCBALRETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(strategyCBALRETH);
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
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(strategyCBALRETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(strategyCBALRETH);
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
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(strategyCBALRETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(strategyCBALRETH);
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
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(strategyCBALRETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(strategyCBALRETH);
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
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(strategyCBALRETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(strategyCBALRETH);
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
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(strategyCBALRETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(strategyCBALRETH);
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
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(strategyCBALRETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(strategyCBALRETH);
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
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(strategyCBALRETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(strategyCBALRETH);
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
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(strategyCBALRETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(strategyCBALRETH);
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
        tokenConfig.debtCap = 100e55; // Cap for debt limits in 2^168-1 or 3.74e50.

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_updateTokenConfig_fail_whenOracleManagerCannotPriceCToken() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(borrowableCDAI));

        // Remove cToken support from Oracle Manager so pricing will fail.
        oracleManager.removeCTokenSupport(address(borrowableCDAI));

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

    function test_updateTokenConfig_fail_whenCollateralCapTurnedOnWithoutCollateralization() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(strategyCBALRETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(strategyCBALRETH);
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
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(strategyCBALRETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(strategyCBALRETH);
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
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(strategyCBALRETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(strategyCBALRETH);
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
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(strategyCBALRETH));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(strategyCBALRETH);
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

}