// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { TestBaseMarketManagerIsolated } from "tests/market/isolatedMarketManager/TestBaseMarketManagerIsolated.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";

contract UpdatePositionTokenIsolatedTest is TestBaseMarketManagerIsolated {

    function setUp() public override {
        super.setUp();
        
        // Setup market with tokens
        deal(address(balRETH), address(this), 42069);
        balRETH.approve(address(pBALRETH), 42069);

        deal(address(_USDC_ADDRESS), address(this), 42069);
        usdc.approve(address(eUSDC), 42069);
        
        // List tokens in the market
        marketManager.listTokens(address(pBALRETH), address(eUSDC));

    }

    function testUpdatePositionToken() public {
        // Set position token parameters
        marketManager.updatePositionToken(
            7000,    // collRatio 70%
            4000,    // collReqSoft 40%
            3000,    // collReqHard 25%
            1000,    // liqIncBase 10%
            500,     // liqIncMin 5%
            2000,    // liqIncMax 20%
            2000,    // minEffectiveCFactor 20%
            5000,    // maxEffectiveCFactor 50%
            2000     // baseCFactor 20%
        );

        (
            bool isListed,
            uint256 collRatio,
            uint256 collReqSoft,
            uint256 collReqHard,
            uint256 liqBaseIncentive,
            uint256 liqMinIncentive,
            uint256 liqMaxIncentive,
            uint256 minEffectiveCloseFactor,
            uint256 maxEffectiveCloseFactor,
            uint256 baseCFactor,
            uint256 cFactorCurve
        ) = marketManager.tokenData(address(pBALRETH));

        assertEq(collRatio, 700000000000000000);
        assertEq(collReqSoft, 1400000000000000000);
        assertEq(collReqHard, 1300000000000000000);
        assertEq(liqBaseIncentive, 1100000000000000000);
        assertEq(liqMinIncentive, 1050000000000000000);
        assertEq(liqMaxIncentive, 1200000000000000000);
        assertEq(minEffectiveCloseFactor, 200000000000000000);
        assertEq(maxEffectiveCloseFactor, 500000000000000000);
        // assertEq(liqCurve, 100000000000000000);  //        marketToken.liqCurve = marketToken.liqMaxIncentive - marketToken.liqBaseIncentive;
        assertEq(baseCFactor, 200000000000000000);
        assertEq(cFactorCurve, 800000000000000000); // WAD - baseCFactor;
    }

    function testUpdatePositionToken_Unauthorized() public {

        vm.prank(user1);
        
        // Should revert with MarketManager__Unauthorized()
        vm.expectRevert(abi.encodeWithSignature("MarketManager__Unauthorized()"));
        marketManager.updatePositionToken(
            7000, 4000, 3000, 1000, 500, 2000, 2000, 5000, 2000
        );
    }

    function testUpdatePositionToken_MaxCollRatio() public {
        // if (collRatio > MAX_COLLATERALIZATION_RATIO) {
        //     _revert(_INVALID_PARAMETER_SELECTOR);
        // }
        vm.expectRevert(abi.encodeWithSignature("MarketManager__InvalidParameter()"));
        marketManager.updatePositionToken(
            23500,    // collRatio 235% (above max)
            4000,    // collReqSoft 40%
            3000,    // collReqHard 25%
            1000,    // liqIncBase 10%
            500,     // liqIncMin 5%
            2000,    // liqIncMax 20%
            2000,    // minEffectiveCFactor 20%
            5000,    // maxEffectiveCFactor 50%
            2000     // baseCFactor 20%
        );
    }

    function testUpdatePositionToken_InvalidCollReqSoft() public {
        // if (collReqSoft > MAX_COLLATERAL_REQUIREMENT) {
        //     _revert(_INVALID_PARAMETER_SELECTOR);
        // }
        vm.expectRevert(abi.encodeWithSignature("MarketManager__InvalidParameter()"));
        marketManager.updatePositionToken(
            7000,    // collRatio 70%
            23500,   // collReqSoft 235% (above max)
            3000,    // collReqHard 30%
            1000,    // liqIncBase 10%
            500,     // liqIncMin 5%
            2000,    // liqIncMax 20%
            2000,    // minEffectiveCFactor 20%
            5000,    // maxEffectiveCFactor 50%
            2000     // baseCFactor 20%
        );
    }

    function testUpdatePositionToken_HigherHardReq() public {
        // if (collReqHard >= collReqSoft) {
        //     _revert(_INVALID_PARAMETER_SELECTOR);
        // }
        vm.expectRevert(abi.encodeWithSignature("MarketManager__InvalidParameter()"));
        marketManager.updatePositionToken(
            7000,    // collRatio 70%
            4000,    // collReqSoft 40%
            5000,    // collReqHard 50% (should be < collReqSoft)
            1000,    // liqIncBase 10%
            500,     // liqIncMin 5%
            2000,    // liqIncMax 20%
            2000,    // minEffectiveCFactor 20%
            5000,    // maxEffectiveCFactor 50%
            2000     // baseCFactor 20%
        );

        vm.expectRevert(abi.encodeWithSignature("MarketManager__InvalidParameter()"));
        marketManager.updatePositionToken(
            7000,    // collRatio 70%
            4000,    // collReqSoft 40%
            5000,    // collReqHard 40% (should be < collReqSoft not equal)
            1000,    // liqIncBase 10%
            500,     // liqIncMin 5%
            2000,    // liqIncMax 20%
            2000,    // minEffectiveCFactor 20%
            5000,    // maxEffectiveCFactor 50%
            2000     // baseCFactor 20%
        );
    }

    function testUpdatePositionToken_InvalidLiqIncBaseMinMax() public {
        // if (liqIncBase > liqIncMax || liqIncBase < liqIncMin) {
        //     _revert(_INVALID_PARAMETER_SELECTOR);
        // }
        vm.expectRevert(abi.encodeWithSignature("MarketManager__InvalidParameter()"));
        marketManager.updatePositionToken(
            7000,    // collRatio 70%
            4000,    // collReqSoft 40%
            3000,    // collReqHard 30%
            1500,    // liqIncBase 15%
            500,     // liqIncMin 5%
            1400,    // liqIncMax 14% (should be >= liqIncBase)
            2000,    // minEffectiveCFactor 20%
            5000,    // maxEffectiveCFactor 50%
            2000     // baseCFactor 20%
        );

        vm.expectRevert(abi.encodeWithSignature("MarketManager__InvalidParameter()"));
        marketManager.updatePositionToken(
            7000,    // collRatio 70%
            4000,    // collReqSoft 40%
            3000,    // collReqHard 30%
            1000,    // liqIncBase 10% (should be >= liqIncMin)
            1500,    // liqIncMin 15% 
            2000,    // liqIncMax 20%
            2000,    // minEffectiveCFactor 20%
            5000,    // maxEffectiveCFactor 50%
            2000     // baseCFactor 20%
        );

    }

    function testUpdatePositionToken_InvalidLiqIncMax() public {
        // if (liqIncMax > MAX_LIQUIDATION_INCENTIVE) {
        //     _revert(_INVALID_PARAMETER_SELECTOR);
        // }
        vm.expectRevert(abi.encodeWithSignature("MarketManager__InvalidParameter()"));
        marketManager.updatePositionToken(
            7000,    // collRatio 70%
            4000,    // collReqSoft 40%
            3000,    // collReqHard 30%
            1000,    // liqIncBase 10%
            500,     // liqIncMin 5%
            3100,    // liqIncMax 31% (max is 30%)
            2000,    // minEffectiveCFactor 20%
            5000,    // maxEffectiveCFactor 50%
            2000     // baseCFactor 20%
        );
    }

    function testUpdatePositionToken_MinGreaterThanMax() public {
        // if (liqIncMin >= liqIncMax) {
        //     _revert(_INVALID_PARAMETER_SELECTOR);
        // }
        vm.expectRevert(abi.encodeWithSignature("MarketManager__InvalidParameter()"));
        marketManager.updatePositionToken(
            7000,    // collRatio 70%
            4000,    // collReqSoft 40%
            3000,    // collReqHard 25%
            1000,    // liqIncBase 10%
            2001,    // liqIncMin 20.01%
            2000,    // liqIncMax 20%
            2000,    // minEffectiveCFactor 20%
            5000,    // maxEffectiveCFactor 50%
            2000     // baseCFactor 20%
        );
        
    }

    function testUpdatePositionToken_TooLowCollateralBuffer() public {
        // if (liqIncMax + MIN_EXCESS_COLLATERAL_REQUIREMENT > collReqHard) {
        //     _revert(_INVALID_PARAMETER_SELECTOR);
        // }
        vm.expectRevert(abi.encodeWithSignature("MarketManager__InvalidParameter()"));
        marketManager.updatePositionToken(
            7000,    // collRatio 70%
            4000,    // collReqSoft 40%
            1000,    // collReqHard 10% (too low)
            700,     // liqIncBase 7%
            500,     // liqIncMin 5%
            900,     // liqIncMax 9% ((9 + 1.5% buffer) = 10.5%) > 10%
            2000,    // minEffectiveCFactor 20%
            5000,    // maxEffectiveCFactor 50%
            2000     // baseCFactor 20%
        );
    }

    function testUpdatePositionToken_InvalidBaseCFactor() public {
        // if (baseCFactor > MAX_BASE_CFACTOR || baseCFactor < MIN_BASE_CFACTOR) {
        //     _revert(_INVALID_PARAMETER_SELECTOR);
        // }
        vm.expectRevert(abi.encodeWithSignature("MarketManager__InvalidParameter()"));
        marketManager.updatePositionToken(
            7000,    // collRatio 70%
            4000,    // collReqSoft 40%
            3000,    // collReqHard 30%
            1000,    // liqIncBase 10%
            500,     // liqIncMin 5%
            2000,    // liqIncMax 20%
            2000,    // minEffectiveCFactor 20%
            5000,    // maxEffectiveCFactor 50%
            900      // baseCFactor 9% (min is 10%)
        );
        
        vm.expectRevert(abi.encodeWithSignature("MarketManager__InvalidParameter()"));
        marketManager.updatePositionToken(
            7000,    // collRatio 70%
            4000,    // collReqSoft 40%
            3000,    // collReqHard 30%
            1000,    // liqIncBase 10%
            500,     // liqIncMin 5%
            2000,    // liqIncMax 20%
            2000,    // minEffectiveCFactor 20%
            5000,    // maxEffectiveCFactor 50%
            5100     // baseCFactor 51% (max is 50%)
        );
    }

    function testUpdatePositionToken_SoftLiquidationCollateralPremium() public {
        // if (collRatio > (WAD_SQUARED / (WAD + collReqSoft))) {
        //     _revert(_INVALID_PARAMETER_SELECTOR);
        // }

        // (1e36 / (1e18 + (4000 * 1e14))) = 71.4 % max collRatio
        // 7200 > 71.4%
        vm.expectRevert(abi.encodeWithSignature("MarketManager__InvalidParameter()"));
        marketManager.updatePositionToken(
            7200,    // collRatio 72% 
            4000,    // collReqSoft 40%
            3000,    // collReqHard 30%
            1000,    // liqIncBase 10%
            500,     // liqIncMin 5%
            2000,    // liqIncMax 20%
            2000,    // minEffectiveCFactor 20%
            5000,    // maxEffectiveCFactor 50%
            2000     // baseCFactor 20%
        );
    }

    function testUpdatePositionToken_TurnOffCollateralization() public {
        // if (marketToken.collRatio != 0 && collRatio == 0) {
        //     _revert(_INVALID_PARAMETER_SELECTOR);
        // }

        // set up normally
        marketManager.updatePositionToken(
            7000,    // collRatio 70%
            4000,    // collReqSoft 40%
            3000,    // collReqHard 25%
            1000,    // liqIncBase 10%
            500,     // liqIncMin 5%
            2000,    // liqIncMax 20%
            2000,    // minEffectiveCFactor 20%
            5000,    // maxEffectiveCFactor 50%
            2000     // baseCFactor 20%
        );
        
        // turn off collateralization
        // will revert with MarketManager__InvalidParameter()
        vm.expectRevert(abi.encodeWithSignature("MarketManager__InvalidParameter()"));
        marketManager.updatePositionToken(
            0,    // collRatio 0%
            4000,    // collReqSoft 40%
            3000,    // collReqHard 25%
            1000,    // liqIncBase 10%
            500,     // liqIncMin 5%
            2000,    // liqIncMax 20%
            2000,    // minEffectiveCFactor 20%
            5000,    // maxEffectiveCFactor 50%
            2000     // baseCFactor 20%
        );
        
        
    }




}