// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarketManagerIsolated } from "tests/market/isolatedMarketManager/TestBaseMarketManagerIsolated.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { IEToken } from "contracts/interfaces/IEToken.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { PriceReturnData } from "contracts/interfaces/IOracleAdaptor.sol";
import { WAD } from "contracts/libraries/Constants.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import "forge-std/console2.sol";

// ## Scenario 4: Mixed Auction and Regular Liquidations, with a mix of liquidateExact() and liquidate()
// - Setup: 4 users with varying positions
// - User 1: 1.9 pBALRETH ($2,850), 2500 USDC debt
// - Action 1: Price drop by to ~$1,300, 
// - Action 2: User 1 is liquidated via regular liquidation using liquidateExact() 1/4 of their total debt
// - Action 3: User 1 is liquidated via regular liquidation using liquidateExact() 1/4 of their remaining debt
// - Action 3: User 1 has the rest of their debt liquidated via regular liquidation using liquidate()

contract MixedAuction is TestBaseMarketManagerIsolated {

    address borrower1 = makeAddr("borrower1");

    address[] borrowers = [borrower1];

    uint256 borrowAmount = 2500e6;

    uint256 collateralAmountStart = 1.9e18;

    uint256 WAD_SQUARED = 1e36;

    uint256 liqBaseIncentive;
    uint256 liqCurve;
    uint256 baseCFactor;
    uint256 cFactorCurve;

    address dappControlUser = makeAddr("dappControlUser");

    // Auction parameters
    uint256 validPenalty = 1.04e18;
    uint256 closeFactor = 0.50e18;

    uint256[] amountToRepayPartial;

    event BadDebtRecognized(address liquidator, uint256 amount);
    event Repay(address liquidator, address account, uint256 amount);

    function setUp() public override {
        super.setUp();

        mockUsdcFeed = new MockDataFeed(_CHAINLINK_USDC_USD);
        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(mockUsdcFeed),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(mockUsdcFeed),
            0,
            true
        );

        // use mock pricing for testing
        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        chainlinkEthUsd.updateAnswer(1500e8);
        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);

        _prepareUSDC(user1, _ONE);
        _prepareUSDC(address(this), _ONE);

        _prepareBALRETH(user1, _ONE + 77777);

        vm.prank(user1);
        usdc.approve(address(eUSDC), _ONE);
        balRETH.approve(address(pBALRETH), _ONE + 77777);

        marketManagerIsolated.listTokens(address(pBALRETH), address(eUSDC));

        eUSDC.depositReserves(1000e6);

        // Update position token parameters
        marketManagerIsolated.updatePositionToken(
            9200,    // collRatio 92%
            830,     // collReqSoft 8.3%
            650,     // collReqHard 6.5%
            500,     // liqIncBase 5%
            550,     // liqIncHard 5.5%
            300,     // liqIncMin 3%
            550,     // liqIncMax 5.5% 
            1000,    // minEffectiveCFactor 20%
            5000,    // maxEffectiveCFactor 50%
            2000     // baseCFactor 20%
        );


        address[] memory tokens = new address[](1);
        tokens[0] = address(pBALRETH);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManagerIsolated.setCollateralCaps(tokens, caps);

        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 200000e6);
        _prepareBALRETH(liquidityProvider, 10e18);
        // mint eUSDC
        vm.startPrank(liquidityProvider);
        usdc.approve(address(eUSDC), 200000e6);
        eUSDC.mint(200000e6);
        // mint cBALETH
        balRETH.approve(address(pBALRETH), 10e18);
        pBALRETH.deposit(10e18, liquidityProvider);
        vm.stopPrank();
        _createPositions();

        mockWethFeed.setMockAnswer(1300e8);
        mockRethFeed.setMockAnswer(1300e8);

        (,,,, uint256 liqBaseIncentive_, uint256 liqCurve_,,,,, uint256 baseCFactor_, uint256 cFactorCurve_) = 
            marketManagerIsolated.tokenData(address(pBALRETH));

        liqBaseIncentive = liqBaseIncentive_;
        liqCurve = liqCurve_;
        baseCFactor = baseCFactor_;
        cFactorCurve = cFactorCurve_;

        // Create a dapp control user
        vm.startPrank(centralRegistry.daoAddress());
        centralRegistry.addAuctionPermissions(dappControlUser);
        vm.stopPrank();

        console2.log("SETUP COMPLETE");
    }

    uint256 totalBorrowsBefore;
    uint256 eTokenPrice;
    uint256 cTokenPrice;
    uint256 quarterRatio = 0.25e18;

    function test_liquidateExactMix() public {

        // ===== Cache general liquidation values =====

        uint256 cTokenExchangeRate = pBALRETH.exchangeRate();

        totalBorrowsBefore = eUSDC.totalBorrows();

        uint256 debtBalancesPreLiquidation = _getDebtBalancePreLiquidation(borrower1);

        uint256 lFactorsPreLiquidation = _getLFactorsPreLiquidation(borrower1);

        (,eTokenPrice, cTokenPrice) = 
            marketManagerIsolated.liquidationStatusOf(borrower1, address(eUSDC), address(pBALRETH));

        // ===== Cache first liquidation values =====
        amountToRepayPartial = new uint256[](1);

        // repay a quarter of the total debt
        amountToRepayPartial[0] = (debtBalancesPreLiquidation * quarterRatio) / WAD;

        (uint256 maxAmount_liquidateExact_1, uint256 liquidatedPTokens_liquidateExact_first, uint256 collateralRequired_liquidateExact_1) = 
            _getLiquidationValuesWithHigherPrecision_NonAuction_LiquidateExact(
                eTokenPrice, 
                cTokenPrice, 
                lFactorsPreLiquidation,
                collateralAmountStart, 
                amountToRepayPartial[0]
            );

        uint256 badDebt_expected_liquidateExact_1 = _calculateBadDebt(
            debtBalancesPreLiquidation,
            maxAmount_liquidateExact_1,
            collateralAmountStart,
            collateralRequired_liquidateExact_1,
            liquidatedPTokens_liquidateExact_first,
            cTokenPrice,
            eTokenPrice,
            cTokenExchangeRate
        );

        uint256 totalDebtPaid_first = amountToRepayPartial[0] + badDebt_expected_liquidateExact_1;

        uint256 remainingDebt_after_first = debtBalancesPreLiquidation - totalDebtPaid_first;

        // ===== First liquidation using liquidateExact() =====

        address first_liquidator = makeAddr("first_liquidator");
        _prepareUSDC(first_liquidator, 100_000e6);

        vm.startPrank(first_liquidator);

        // expect bad debt emit and debt repaid
        vm.expectEmit();
        emit BadDebtRecognized(first_liquidator, badDebt_expected_liquidateExact_1);
        emit Repay(first_liquidator, borrower1, totalDebtPaid_first);

        eUSDC.liquidateExact(
            borrowers,
            amountToRepayPartial,
            address(pBALRETH)
        );

        vm.stopPrank();

        // ===== Cache second liquidation values =====

        // repay a quarter of the remaining debt
        amountToRepayPartial[0] = (remainingDebt_after_first * quarterRatio) / WAD;

        // Update lFactor (shouldn't change much)
        lFactorsPreLiquidation = _getLFactorsPreLiquidation(borrower1);

        // Update expected remaining collateral
        uint256 collateralAmount_after_first = collateralAmountStart - liquidatedPTokens_liquidateExact_first;

        (uint256 maxAmount_liquidateExact_2, uint256 liquidatedPTokens_liquidateExact_2, uint256 collateralRequired_liquidateExact_2) = 
            _getLiquidationValuesWithHigherPrecision_NonAuction_LiquidateExact(
                eTokenPrice, 
                cTokenPrice, 
                lFactorsPreLiquidation,
                collateralAmount_after_first, 
                amountToRepayPartial[0]
            );

        uint256 badDebt_expected_liquidateExact_2 = _calculateBadDebt(
            debtBalancesPreLiquidation,
            maxAmount_liquidateExact_2,
            collateralAmount_after_first,
            collateralRequired_liquidateExact_2,
            liquidatedPTokens_liquidateExact_2,
            cTokenPrice,
            eTokenPrice,
            cTokenExchangeRate
        );

        uint256 totalDebtPaid_second = amountToRepayPartial[0] + badDebt_expected_liquidateExact_2;

        uint256 remainingDebt_after_second = remainingDebt_after_first - totalDebtPaid_second;

        // ====== Second liquidation using liquidateExact() =====

        address second_liquidator = makeAddr("second_liquidator");
        _prepareUSDC(second_liquidator, 100_000e6);

        vm.startPrank(second_liquidator);

        // expect bad debt emit and debt repaid
        vm.expectEmit();
        emit BadDebtRecognized(second_liquidator, badDebt_expected_liquidateExact_2);
        emit Repay(second_liquidator, borrower1, totalDebtPaid_second);

        // The second liquidation should have the same expected result as the first

        eUSDC.liquidateExact(
            borrowers,
            amountToRepayPartial,
            address(pBALRETH)
        );

        vm.stopPrank();

        // ===== Cache third liquidation values =====

        // Update lFactor (shouldn't change much)
        lFactorsPreLiquidation = _getLFactorsPreLiquidation(borrower1);

        // Update expected remaining collateral
        uint256 collateralAmount_after_second = collateralAmount_after_first - liquidatedPTokens_liquidateExact_2;

        // ====== Third liquidation using liquidate ======
        // third liquidation should liquidate all remaining debt

        // repay the remaining debt
        amountToRepayPartial[0] = remainingDebt_after_second;

        (uint256 maxAmount_liquidateExact_3, uint256 liquidatedPTokens_liquidateExact_3, uint256 collateralRequired_liquidateExact_3) = 
            _getLiquidationValuesWithHigherPrecision_NonAuction_LiquidateExact(
                eTokenPrice, 
                cTokenPrice, 
                lFactorsPreLiquidation,
                collateralAmount_after_second, 
                amountToRepayPartial[0]
            );

        uint256 badDebt_expected_liquidateExact_3 = _calculateBadDebt(
            debtBalancesPreLiquidation,
            maxAmount_liquidateExact_3,
            collateralAmount_after_second,
            collateralRequired_liquidateExact_3,
            liquidatedPTokens_liquidateExact_3,
            cTokenPrice,
            eTokenPrice,
            cTokenExchangeRate
        );

        uint256 totalDebtPaid_third = amountToRepayPartial[0] + badDebt_expected_liquidateExact_3;

        uint256 remainingDebt_after_third = remainingDebt_after_second - totalDebtPaid_third;

        address third_liquidator = makeAddr("third_liquidator");
        _prepareUSDC(third_liquidator, 100_000e6);

        vm.startPrank(third_liquidator);

        // expect bad debt emit and debt repaid
        vm.expectEmit();
        emit BadDebtRecognized(third_liquidator, badDebt_expected_liquidateExact_3);
        emit Repay(third_liquidator, borrower1, totalDebtPaid_third);

        eUSDC.liquidate(
            borrowers,
            address(pBALRETH)
        );

       vm.stopPrank();

        // ===== Final Assertions =====

        // Verify borrower1's debt is fully liquidated
        assertEq(eUSDC.debtBalanceCached(borrower1), 0, "Borrower1 should have zero debt remaining");

        // Verify borrower1's collateral is fully liquidated
        assertEq(pBALRETH.balanceOf(borrower1), 0, "Borrower1 should have zero collateral remaining");

        // Verify total borrows decreased appropriately
        uint256 totalBorrowsAfter = eUSDC.totalBorrows();
        assertLt(totalBorrowsAfter, totalBorrowsBefore, "Total borrows should have decreased");

        // Verify the position is no longer liquidatable
        (uint256 lFactorFinal,,) = marketManagerIsolated.liquidationStatusOf(
            borrower1,
            address(eUSDC),
            address(pBALRETH)
        );
        assertEq(lFactorFinal, 0, "Position should no longer be liquidatable");

        // Verify remaining debt calculation was correct
        assertApproxEqAbs(remainingDebt_after_third, 0, 1, "Remaining debt should be approximately zero");
        

    }

    function _createPositions() internal {
        _prepareBALRETH(borrower1, collateralAmountStart);

        vm.startPrank(borrower1);
        balRETH.approve(address(pBALRETH), collateralAmountStart);
        pBALRETH.depositAsCollateral(collateralAmountStart, borrower1);
        eUSDC.borrow(borrowAmount);
        vm.stopPrank();

    }

    function _getLFactorsPreLiquidation(address _borrowers) internal view returns (uint256 lFactors) {

            (lFactors,,) = marketManagerIsolated.liquidationStatusOf(
                _borrowers,
                address(eUSDC),
                address(pBALRETH)
            );

        return lFactors;
    }

    function _getDebtBalancePreLiquidation(address _borrower) internal view returns (uint256 debtBalance) {

        debtBalance = eUSDC.debtBalanceCached(_borrower);

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
        uint256 cTokenExchangeRate = pBALRETH.exchangeRate();
        
        // Keep original values but use higher precision for calculations
        uint256 PRECISION_FACTOR = 1e18; // Extra precision factor
    
            if (lFactors == 0) return (0,0,0);
            
            // Follow the contract's exact calculations but with higher precision
            uint256 auctionCFactor = baseCFactor + ((cFactorCurve * lFactors / WAD));
            uint256 auctionLiqIncentive = liqBaseIncentive + ((liqCurve * lFactors) / WAD);
            
            // Calculate with extra precision
            uint256 highPrecisionD2C = (((auctionLiqIncentive * _eTokenPrice * WAD * PRECISION_FACTOR) /
                (_cTokenPrice * cTokenExchangeRate)) * 1e18) / 1e6;
                
            maxAmount = (auctionCFactor * borrowAmount) / WAD;
            
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

    function _getLiquidationValuesWithHigherPrecision_NonAuction_LiquidateExact(
        uint256 _eTokenPrice,
        uint256 _cTokenPrice,
        uint256 lFactor,
        uint256 _debtAmount,
        uint256 _collateralAmount
    ) internal view returns (
        uint256 maxAmount,
        uint256 liquidatedPTokens,
        uint256 collateralRequired
    ) {
        uint256 cTokenExchangeRate = pBALRETH.exchangeRate();
        
        // Keep original values but use higher precision for calculations
        uint256 PRECISION_FACTOR = 1e18; // Extra precision factor
            
        // Follow the contract's exact calculations but with higher precision
        uint256 auctionCFactor = baseCFactor + ((cFactorCurve * lFactor) / WAD);
        uint256 auctionLiqIncentive = liqBaseIncentive + ((liqCurve * lFactor) / WAD);
        
        // Calculate with extra precision
        uint256 highPrecisionD2C = (((auctionLiqIncentive * _eTokenPrice * WAD * PRECISION_FACTOR) /
            (_cTokenPrice * cTokenExchangeRate)) * 1e18) / 1e6;

        maxAmount = (auctionCFactor * _debtAmount) / WAD;

        // Calculate with extra precision
        liquidatedPTokens = (maxAmount * highPrecisionD2C) / (WAD * PRECISION_FACTOR);
        
        collateralRequired = (_debtAmount * highPrecisionD2C) / (WAD * PRECISION_FACTOR);
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