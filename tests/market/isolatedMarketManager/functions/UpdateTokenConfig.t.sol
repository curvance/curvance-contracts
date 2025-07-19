// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { TestBaseMarketManagerIsolated } from "tests/market/isolatedMarketManager/TestBaseMarketManagerIsolated.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract UpdateTokenConfigTest is TestBaseMarketManagerIsolated {

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

        address cToken = address(borrowableCUSDC);
        uint256 collateralCap = 1_000_000e6;
        uint256 debtCap = 1_000_000e6;
        
        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = cToken;
        tokenConfig.collRatio = 7000;
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.minEffectiveCloseFactor = 2000;
        tokenConfig.maxEffectiveCloseFactor = 5000;
        tokenConfig.baseCFactor = 2000;
        tokenConfig.collateralCap = collateralCap;
        tokenConfig.debtCap = debtCap;

        vm.prank(user2);
        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);

    }

    function test_updateTokenConfig_fail_whenTokenIsNotBorrowable() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(strategyCBALRETH));

        address cToken = address(strategyCBALRETH);
        uint256 collateralCap = 1_000_000e6;
        uint256 debtCap = 1_000_000e6;
        
        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = cToken;
        tokenConfig.collRatio = 7000;
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.minEffectiveCloseFactor = 2000;
        tokenConfig.maxEffectiveCloseFactor = 5000;
        tokenConfig.baseCFactor = 2000;
        tokenConfig.collateralCap = collateralCap;
        tokenConfig.debtCap = debtCap;

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_updateTokenConfig_fail_whenCollRatioIsTooHigh() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(strategyCBALRETH));

        address cToken = address(strategyCBALRETH);
        uint256 collateralCap = 1_000_000e6;
        uint256 debtCap = 0;
        
        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = cToken;
        tokenConfig.collRatio = 23500;    // collRatio 235% (above max)
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.minEffectiveCloseFactor = 2000;
        tokenConfig.maxEffectiveCloseFactor = 5000;
        tokenConfig.baseCFactor = 2000;
        tokenConfig.collateralCap = collateralCap;
        tokenConfig.debtCap = debtCap;

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_updateTokenConfig_fail_whenHardReqHigherThanSoftReq() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(strategyCBALRETH));

        address cToken = address(strategyCBALRETH);
        uint256 collateralCap = 1_000_000e6;
        uint256 debtCap = 0;
        
        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = cToken;
        tokenConfig.collRatio = 7000; 
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 5000;     //(should be < collReqSoft)
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.minEffectiveCloseFactor = 2000;
        tokenConfig.maxEffectiveCloseFactor = 5000;
        tokenConfig.baseCFactor = 2000;
        tokenConfig.collateralCap = collateralCap;
        tokenConfig.debtCap = debtCap;

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_updateTokenConfig_fail_whenLiqIncBaseIsLargerThanMax() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(strategyCBALRETH));

        address cToken = address(strategyCBALRETH);
        uint256 collateralCap = 1_000_000e6;
        uint256 debtCap = 0;
        
        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = cToken;
        tokenConfig.collRatio = 7000; 
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1500;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 1400;   //      (should be >=liqBase)
        tokenConfig.minEffectiveCloseFactor = 2000;
        tokenConfig.maxEffectiveCloseFactor = 5000;
        tokenConfig.baseCFactor = 2000;
        tokenConfig.collateralCap = collateralCap;
        tokenConfig.debtCap = debtCap;

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);

        tokenConfig.collRatio = 7000; 
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000; //   (should be >= liqInMin)
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 1500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.minEffectiveCloseFactor = 2000;
        tokenConfig.maxEffectiveCloseFactor = 5000;
        tokenConfig.baseCFactor = 2000;
    }

    function test_updateTokenConfig_fail_whenLiqIncMaxIsTooHigh() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(strategyCBALRETH));

        address cToken = address(strategyCBALRETH);
        uint256 collateralCap = 1_000_000e6;
        uint256 debtCap = 0;
        
        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = cToken;
        tokenConfig.collRatio = 7000; 
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 3100;   // (max is 30%)
        tokenConfig.minEffectiveCloseFactor = 2000;
        tokenConfig.maxEffectiveCloseFactor = 5000;
        tokenConfig.baseCFactor = 2000;
        tokenConfig.collateralCap = collateralCap;
        tokenConfig.debtCap = debtCap;

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_updateTokenConfig_fail_whenLiqMinGreaterThanLiqMax() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(strategyCBALRETH));

        address cToken = address(strategyCBALRETH);
        uint256 collateralCap = 1_000_000e6;
        uint256 debtCap = 0;
        
        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = cToken;
        tokenConfig.collRatio = 7000; 
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;   
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 2001; //    (should be < liqIncMax)
        tokenConfig.liqIncMax = 2000;
        tokenConfig.minEffectiveCloseFactor = 2000;
        tokenConfig.maxEffectiveCloseFactor = 5000;
        tokenConfig.baseCFactor = 2000;
        tokenConfig.collateralCap = collateralCap;
        tokenConfig.debtCap = debtCap;

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_updateTokenConfig_fail_CollateralBufferIsTooLow() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(strategyCBALRETH));

        address cToken = address(strategyCBALRETH);
        uint256 collateralCap = 1_000_000e6;
        uint256 debtCap = 0;
        
        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = cToken;
        tokenConfig.collRatio = 7000; 
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 1000;  
        tokenConfig.liqIncBase = 700;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 900; //     9% ((9 + 1.5% buffer) = 10.5%) > 10% collReqHard
        tokenConfig.minEffectiveCloseFactor = 2000;
        tokenConfig.maxEffectiveCloseFactor = 5000;
        tokenConfig.baseCFactor = 2000;
        tokenConfig.collateralCap = collateralCap;
        tokenConfig.debtCap = debtCap;

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_updateTokenConfig_fail_whenBaseCFactorisTooLow() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(strategyCBALRETH));

        address cToken = address(strategyCBALRETH);
        uint256 collateralCap = 1_000_000e6;
        uint256 debtCap = 0;
        
        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = cToken;
        tokenConfig.collRatio = 7000; 
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.minEffectiveCloseFactor = 2000;
        tokenConfig.maxEffectiveCloseFactor = 5000;
        tokenConfig.baseCFactor = 900;      // baseCFactor is 9% (min is 10%)
        tokenConfig.collateralCap = collateralCap;
        tokenConfig.debtCap = debtCap;

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);

        tokenConfig.cToken = cToken;
        tokenConfig.collRatio = 7000; 
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.minEffectiveCloseFactor = 2000;
        tokenConfig.maxEffectiveCloseFactor = 5000;
        tokenConfig.baseCFactor = 5100;      // baseCFactor 51% (max is 50%)

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);

    }

    function test_updateTokenConfig_fail_TurnOffCollateralization() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(strategyCBALRETH));

        address cToken = address(strategyCBALRETH);
        uint256 collateralCap = 1000e18;
        uint256 debtCap = 0;
        
        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = cToken;
        tokenConfig.collRatio = 7000; 
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.minEffectiveCloseFactor = 2000;
        tokenConfig.maxEffectiveCloseFactor = 5000;
        tokenConfig.baseCFactor = 2000;
        tokenConfig.collateralCap = collateralCap;
        tokenConfig.debtCap = debtCap;

        marketManagerIsolated.updateTokenConfig(tokenConfig);


        tokenConfig.cToken = cToken;
        tokenConfig.collRatio = 0; 
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.minEffectiveCloseFactor = 2000;
        tokenConfig.maxEffectiveCloseFactor = 5000;
        tokenConfig.baseCFactor = 2000;

        // will fail because coll ratio != 0 to start off
        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

        function test_updateTokenConfig_success_turnOffCollateralization_whenCollRatioStartsZero() public {
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(strategyCBALRETH));

        address cToken = address(strategyCBALRETH);
        uint256 collateralCap = 0;
        uint256 debtCap = 0;
        
        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = cToken;
        tokenConfig.collRatio = 0; 
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.minEffectiveCloseFactor = 2000;
        tokenConfig.maxEffectiveCloseFactor = 5000;
        tokenConfig.baseCFactor = 2000;
        tokenConfig.collateralCap = collateralCap;
        tokenConfig.debtCap = debtCap;

        marketManagerIsolated.updateTokenConfig(tokenConfig);


        tokenConfig.cToken = cToken;
        tokenConfig.collRatio = 0; 
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.minEffectiveCloseFactor = 2000;
        tokenConfig.maxEffectiveCloseFactor = 5000;
        tokenConfig.baseCFactor = 2000;

        // will succeed because coll ratio is already 0
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }



}