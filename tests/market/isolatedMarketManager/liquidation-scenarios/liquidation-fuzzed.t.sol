// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarketManagerIsolated } from "tests/market/isolatedMarketManager/TestBaseMarketManagerIsolated.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { WAD } from "contracts/libraries/Constants.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import "forge-std/console2.sol";

// TODO - ADD ASSERTIONS!!!!

// 0. Use maximum LTV possible for fuzzing
// 1. Fuzz collateral
// 2. Borrow amounts - make sure fuzzed borrows are within the maximum LTV
// 3. Fuzz oracle price of collateral
// 4. Add a case for when the lFactor is 0, expectRevert for liquidate
// 5. Use liquidate() to liquidate the position.
// 6. Assert all liquidation values match expected values

contract LiquidationFuzzedTest is TestBaseMarketManagerIsolated {

    address borrower = makeAddr("borrower");

    address[] borrowerArray = [borrower];

    uint256 constant INITIAL_PRICE = 1500e8;
    uint256 constant MINIMUM_COLLATERAL_AMOUNT = 0.1e18;
    uint256 constant MAXIMUM_COLLATERAL_AMOUNT = 20e18;
    int256 constant MINIMUM_COLLATERAL_PRICE = 1000e8;
    int256 constant MAXIMUM_COLLATERAL_PRICE = 2000e8;
    uint256 constant MINIMUM_BORROW_AMOUNT = 50e6;

    uint256 liqBaseIncentive;
    uint256 liqCurve;
    uint256 baseCFactor;
    uint256 cFactorCurve;

    // Storage to avoid stack too deep
    uint256 maxAmount;
    uint256 liquidatedPTokens;
    uint256 collateralRequired;
    uint256 cTokenExchangeRate;
    uint256 debtBalancesPreLiquidation;
    uint256 collateralAmounts;
    uint256 expectedBadDebt;


    event BadDebtRecognized(address liquidator, uint256 amount);
    event Repay(address liquidator, address account, uint256 amount);

    function setUp() public override {
        super.setUp();

        mockUsdcFeed = new MockDataFeed(_CHAINLINK_USDC_USD);
        chainlinkAdaptor.addAsset(_USDC_ADDRESS, address(mockUsdcFeed), 0, true);
        dualChainlinkAdaptor.addAsset(_USDC_ADDRESS, address(mockUsdcFeed), 0, true);

        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        chainlinkEthUsd.updateAnswer(int256(INITIAL_PRICE));
        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockAnswer(int256(INITIAL_PRICE));
        mockRethFeed.setMockAnswer(int256(INITIAL_PRICE));
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);

        _prepareUSDC(user1, _ONE);
        _prepareBALRETH(user1, _ONE + 77777);

        vm.prank(user1);
        usdc.approve(address(eUSDC), _ONE);
        balRETH.approve(address(pBALRETH), _ONE + 77777);

        marketManagerIsolated.listTokens(address(pBALRETH), address(eUSDC));
        eUSDC.depositReserves(1000e6);

        marketManagerIsolated.updatePositionToken(
            9750,    // collRatio 97.5% (max borrowing power)
            250,     // collReqSoft 2.5% (enables ~97.56% LTV liquidation trigger)
            200,     // collReqHard 2.0% (enables ~98.04% LTV hard liquidation)
            1000,    // liqIncBase 10%
            1500,    // liqIncHard 15%
            500,     // liqIncMin 5%
            2000,    // liqIncMax 20%
            2000,    // minEffectiveCFactor 20%
            5000,    // maxEffectiveCFactor 50%
            2000     // baseCFactor 20%
        );

        address[] memory tokens = new address[](1);
        tokens[0] = address(pBALRETH);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManagerIsolated.setCollateralCaps(tokens, caps);

        // Add liquidity
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 200000e6);
        _prepareBALRETH(liquidityProvider, 100e18);
        
        vm.startPrank(liquidityProvider);
        usdc.approve(address(eUSDC), 200000e6);
        eUSDC.mint(200000e6);
        balRETH.approve(address(pBALRETH), 100e18);
        pBALRETH.deposit(100e18, liquidityProvider);
        vm.stopPrank();

        (,,,, uint256 liqBaseIncentive_, uint256 liqCurve_,,,,, uint256 baseCFactor_, uint256 cFactorCurve_) = 
            marketManagerIsolated.tokenData(address(pBALRETH));

        liqBaseIncentive = liqBaseIncentive_;
        liqCurve = liqCurve_;
        baseCFactor = baseCFactor_;
        cFactorCurve = cFactorCurve_;
    }

    function fuzzLiquidation(
        uint256 _collateralAmount,
        uint256 _borrowAmount,
        int256 _oraclePrice
    ) public {

        vm.assume(_collateralAmount >= MINIMUM_COLLATERAL_AMOUNT
            && _collateralAmount <= MAXIMUM_COLLATERAL_AMOUNT);

        _prepareBALRETH(borrower, _collateralAmount);

        vm.startPrank(borrower);
        balRETH.approve(address(pBALRETH), _collateralAmount);
        pBALRETH.depositAsCollateral(_collateralAmount,borrower);

        // get maximum borrow amount
        (, uint256 maxBorrowAmount,) = marketManagerIsolated.statusOf(borrower);

        vm.assume(_borrowAmount >= MINIMUM_BORROW_AMOUNT
            && _borrowAmount <= maxBorrowAmount);

        eUSDC.borrow(_borrowAmount);

        vm.stopPrank();

        // create liquidation scenario price
        vm.assume(_oraclePrice <= MAXIMUM_COLLATERAL_PRICE
            && _oraclePrice >= MINIMUM_COLLATERAL_PRICE);

        mockWethFeed.setMockAnswer(_oraclePrice);
        mockRethFeed.setMockAnswer(_oraclePrice);


        skip(20 minutes);


        uint256 lFactorsPreLiquidation = _getLFactorsPreLiquidation(borrower);

        (,uint256 eTokenPrice, uint256 cTokenPrice) = 
            marketManagerIsolated.liquidationStatusOf(borrower, address(eUSDC), address(pBALRETH));

        (maxAmount, liquidatedPTokens, collateralRequired) = 
            _getLiquidationValuesWithHigherPrecision_NonAuction_Liquidate(
                eTokenPrice, cTokenPrice, lFactorsPreLiquidation, _collateralAmount, _borrowAmount
            );
        cTokenExchangeRate = pBALRETH.exchangeRate();

        collateralAmounts = pBALRETH.collateralPosted(borrower);

        debtBalancesPreLiquidation = eUSDC.debtBalanceWithUpdateSafe(borrower);

        expectedBadDebt = _calculateBadDebt(
                debtBalancesPreLiquidation,
                maxAmount,
                collateralAmounts,
                collateralRequired,
                liquidatedPTokens,
                cTokenPrice,
                eTokenPrice,
                cTokenExchangeRate
            );
        
        _prepareUSDC(liquidator, 1_000_000e6);

        vm.prank(liquidator);
        (uint256 lFactor,,) = marketManagerIsolated.liquidationStatusOf(
            borrower,
            address(eUSDC),
            address(pBALRETH)
        );
        usdc.approve(address(eUSDC), 1_000_000e6);
        if (lFactor == 0) {
            vm.expectRevert(abi.encodeWithSelector(MarketManagerIsolated.MarketManager__NoLiquidationAvailable.selector));
        }

        vm.expectEmit();
        emit BadDebtRecognized(borrower, expectedBadDebt);
        emit Repay(liquidator, borrower , maxAmount + expectedBadDebt);

        eUSDC.liquidate(borrowerArray, address(pBALRETH));

        // TODO ADD ASSERTIONS!!!!!

    }

    function _getLiquidationValuesWithHigherPrecision_NonAuction_Liquidate(
        uint256 _eTokenPrice,
        uint256 _cTokenPrice,
        uint256 lFactors,
        uint256 _collateralAmounts,
        uint256 _borrowAmounts
    ) internal view returns (
        uint256 maxAmount, 
        uint256 liquidatedPTokens,
        uint256 collateralRequired
    ) {
        
        // Keep original values but use higher precision for calculations
        uint256 PRECISION_FACTOR = 1e18; // Extra precision factor
    
            if (lFactors == 0) return (0,0,0);
            
            // Follow the contract's exact calculations but with higher precision
            uint256 auctionCFactor = baseCFactor + ((cFactorCurve * lFactors / WAD));
            uint256 auctionLiqIncentive = liqBaseIncentive + ((liqCurve * lFactors) / WAD);
            
            // Calculate with extra precision
            uint256 highPrecisionD2C = (((auctionLiqIncentive * _eTokenPrice * WAD * PRECISION_FACTOR) /
                (_cTokenPrice * cTokenExchangeRate)) * 1e18) / 1e6;
                
            maxAmount = (auctionCFactor * _borrowAmounts) / WAD;
            
            // Calculate with extra precision
            liquidatedPTokens = (maxAmount * highPrecisionD2C) / (WAD * PRECISION_FACTOR);
            
            if (liquidatedPTokens > _collateralAmounts) {
                // Use the contract's exact formula
                maxAmount = FixedPointMathLib.mulDivUp(
                    maxAmount,
                    _collateralAmounts,
                    liquidatedPTokens
                );
                liquidatedPTokens = _collateralAmounts;
            }
            
            // Use the contract's exact formula
            collateralRequired = (_borrowAmounts * highPrecisionD2C) / (WAD * PRECISION_FACTOR);


        return (maxAmount, liquidatedPTokens, collateralRequired);
    }

    function _getLFactorsPreLiquidation(address _borrowers) internal view returns (uint256 lFactors) {

            (lFactors,,) = marketManagerIsolated.liquidationStatusOf(
                _borrowers,
                address(eUSDC),
                address(pBALRETH)
            );

        return lFactors;
    }

    function _calculateBadDebt(
        uint256 _debtBalance,
        uint256 _debtAmount,
        uint256 _collateralAvailable,
        uint256 _collateralRequired,
        uint256 _liquidatedPTokens,
        uint256 _cTokenUnderlyingPrice,
        uint256 _eTokenUnderlyingPrice,
        uint256 _cTokenExchangeRate
    ) internal pure returns (uint256 badDebt) {

        if(_collateralRequired > _collateralAvailable) {
    
        badDebt = (_debtBalance - _debtAmount) -
        FixedPointMathLib.mulDivUp(
            ((_collateralAvailable - _liquidatedPTokens) * _cTokenExchangeRate) / WAD,
            _cTokenUnderlyingPrice,
            (_eTokenUnderlyingPrice * WAD) / 1e6
        );

        } else {
            return 0;
        }
        
    }

}