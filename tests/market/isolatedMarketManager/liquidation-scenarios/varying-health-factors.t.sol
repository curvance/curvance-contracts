// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarketManagerIsolated } from "tests/market/isolatedMarketManager/TestBaseMarketManagerIsolated.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { PriceReturnData } from "contracts/interfaces/IOracleAdaptor.sol";
import { WAD } from "contracts/libraries/Constants.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import "forge-std/console2.sol";

// ## Scenario 1: Multiple Users Liquidated, all using liquidate() function
// - Setup: 5 users with varying health factors
// - User 1: 1.0 pBALRETH ($1,600), 800 USDC debt (healthy)
// - User 2: 1.0 pBALRETH ($1,600), 1,000 USDC debt (borderline)
// - User 3: 1.0 pBALRETH ($1,600), 1,100 USDC debt (soft liquidation)
// - User 4: 1.0 pBALRETH ($1,600), 1,200 USDC debt (hard liquidation)
// - User 5: 1.0 pBALRETH ($1,600), 1,300 USDC debt (severe liquidation)
// - Action: Price drop of pBALRETH by 15% (to $1,380)
// - Expected: Users 3, 4, and 5 should be liquidated in single transaction
//          User 3 has a soft liquidation, so no bad debt is accrued.
//          User 4 has a hard liquidation, which accrues some bad debt.
//          User 5 has a severe hard liquidaiton, which accrues substantial bad debt.
    

contract VaryingHealthFactors is TestBaseMarketManagerIsolated {

    address borrower1 = makeAddr("borrower1");
    address borrower2 = makeAddr("borrower2");
    address borrower3 = makeAddr("borrower3");
    address borrower4 = makeAddr("borrower4");
    address borrower5 = makeAddr("borrower5");

    uint256[] borrowAmounts = [800e6, 1000e6, 1100e6, 1200e6, 1300e6];
    address[] borrowers = [borrower1, borrower2, borrower3, borrower4, borrower5];

    uint256 WAD_SQUARED = 1e36;

    uint256 collateralAvailable = WAD;

    uint256 liqBaseIncentive;
    uint256 liqCurve;
    uint256 baseCFactor;
    uint256 cFactorCurve;

    uint256[] badDebt = [0,0,0,0,0];

    event BadDebtRecognized(address liquidator, uint256 amount);
    event Repay(address liquidator, address borrower, uint256 amount);

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

        MarketManagerIsolated.TokenConfig memory configToken0;
        configToken0.cToken = address(pBALRETH);
        configToken0.collRatio = 8000;
        configToken0.collReqSoft = 2500;
        configToken0.collReqHard = 2200;
        configToken0.liqIncBase = 1000;
        configToken0.liqIncHard = 1500;
        configToken0.liqIncMin = 500;
        configToken0.liqIncMax = 2000;
        configToken0.minEffectiveCloseFactor = 2000;
        configToken0.maxEffectiveCloseFactor = 5000;
        configToken0.baseCFactor = 2000;
        configToken0.collateralCap = 100_000e18;
        configToken0.debtCap = 0;

        marketManagerIsolated.updateTokenConfig(configToken0);

        MarketManagerIsolated.TokenConfig memory configToken1;
        configToken1.cToken = address(eUSDC);
        configToken1.debtCap = 100_000e6;
        marketManagerIsolated.updateTokenConfig(configToken1);

        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 200000e6);
        _prepareBALRETH(liquidityProvider, 10e18);
        // mint eUSDC
        vm.startPrank(liquidityProvider);
        usdc.approve(address(eUSDC), 200000e6);
        eUSDC.deposit(200000e6, liquidityProvider);
        // mint cBALETH
        balRETH.approve(address(pBALRETH), 10e18);
        pBALRETH.deposit(10e18, liquidityProvider);
        vm.stopPrank();

        _createPositions();

        mockWethFeed.setMockAnswer(1380e8);
        mockRethFeed.setMockAnswer(1380e8);

        (,,,, uint256 liqBaseIncentive_, uint256 liqCurve_,,,,, uint256 baseCFactor_, uint256 cFactorCurve_) = 
            marketManagerIsolated.tokenData(address(pBALRETH));

        liqBaseIncentive = liqBaseIncentive_;
        liqCurve = liqCurve_;
        baseCFactor = baseCFactor_;
        cFactorCurve = cFactorCurve_;

        // vm.warp(block.timestamp + 20 minutes); skipping so no interest accrues which keeps it simple

    }

    function test_multipleUsersLiquidatedWithVaryingHealthFactors() public {

        IMarketManager.LiqInstructions memory liqInstructions;
        liqInstructions = IMarketManager.LiqInstructions({
            debtToken: address(eUSDC),
            collateralToken: address(pBALRETH),
            numAccounts: 5,
            liquidateExact: false,
            debtRepaid: 0,
            collateralLiquidated: 0,
            badDebt: 0
        });

        _prepareUSDC(address(this), 100000e6);

        // ===== Cache liquidation values =====

        uint256[] memory lFactorsPreLiquidation = _getLFactorsPreLiquidation();
        uint256[] memory debtBalancesPreLiquidation = _getDebtBalancePreLiquidation();

        (,uint256 eTokenPrice, uint256 cTokenPrice) = 
            marketManagerIsolated.liquidationStatusOf(borrowers[0], address(eUSDC), address(pBALRETH));

        (uint256[] memory maxAmount, uint256[] memory liquidatedPTokens, uint256[] memory collateralRequired) = 
            _getLiquidationValuesWithHigherPrecision_NonAuction(
                eTokenPrice, cTokenPrice, lFactorsPreLiquidation
            );

        uint256 expectedTotalBadDebt;
        uint256 cTokenExchangeRate = pBALRETH.exchangeRate();

        for(uint i; i < 5; i++) {
            badDebt[i] = _calculateBadDebt(
                debtBalancesPreLiquidation[i],
                maxAmount[i],
                collateralAvailable,
                collateralRequired[i],
                liquidatedPTokens[i],
                cTokenPrice,
                eTokenPrice,
                cTokenExchangeRate
            );
            expectedTotalBadDebt += badDebt[i];
        }

        uint256 totalBorrowsBefore = eUSDC.marketOutstandingDebt();

        // ===== Liquidate =====

        eUSDC.approve(address(marketManagerIsolated), 100000e6);

        // Assert BadDebtRecognized event is emitted with expected total bad debt
        vm.expectEmit();
        emit BadDebtRecognized(address(this), expectedTotalBadDebt);
        emit Repay(address(this), borrowers[2], maxAmount[2] + badDebt[2]);
        emit Repay(address(this), borrowers[3], maxAmount[3] + badDebt[3]);
        emit Repay(address(this), borrowers[4], maxAmount[4] + badDebt[4]);

        eUSDC.liquidate(
            borrowers,
            address(pBALRETH)
        );

        // ===== Validate =====

        // Verify healthy accounts (1 and 2) are not liquidated
        assertEq(eUSDC.debtBalance(borrowers[0]), debtBalancesPreLiquidation[0], "Healthy account 1 shouldn't be liquidated");
        assertEq(eUSDC.debtBalance(borrowers[1]), debtBalancesPreLiquidation[1], "Healthy account 2 shouldn't be liquidated");

        // Verify liquidated accounts (3, 4, and 5) are liquidated
        for (uint i = 2; i < 5; i++) {
            // Debt should be reduced by maxAmount if soft liquidation
            if(borrowers[i] == borrower3) {
                assertEq(eUSDC.debtBalance(borrowers[i]), debtBalancesPreLiquidation[i] - maxAmount[i], "Borrower 3 should be soft liquidated");
            } else {
                assertEq(eUSDC.debtBalance(borrowers[i]), 0, "Borrower should be hard liquidated");
            }

            // Collateral should be reduced by liquidatedPTokens
            assertApproxEqAbs(
                pBALRETH.balanceOf(borrowers[i]), 
                _ONE - liquidatedPTokens[i],
                1000, // Tolerance of 1000 wei 
                "Collateral post liquidation mismatch"
            );
        }

        uint256 totalDebtRepaid = maxAmount[2] + borrowAmounts[3] + borrowAmounts[4];

        assertApproxEqAbs(
            eUSDC.marketOutstandingDebt(),
            totalBorrowsBefore - totalDebtRepaid,
            100, // Small tolerance
            "Incorrect totalBorrows after liquidation"
        );

        // Verify liquidator received the expected collateral
        uint256 expectedLiquidatorBalance = liquidatedPTokens[2] + liquidatedPTokens[3] + liquidatedPTokens[4];
        assertApproxEqAbs(
            pBALRETH.balanceOf(address(this)),
            expectedLiquidatorBalance,
            1000,
            "Liquidator didn't receive expected collateral"
        );

        // Test accounts health factor after liquidation
        for (uint i = 2; i < 5; i++) {
            (uint256 lFactorAfter,,) = marketManagerIsolated.liquidationStatusOf(
                borrowers[i],
                address(eUSDC),
                address(pBALRETH)
            );
            
            if (eUSDC.debtBalance(borrowers[i]) > 0) {
                // If there's still debt, health factor should be improved
                assertTrue(
                    lFactorAfter < lFactorsPreLiquidation[i],
                    "Health factor should improve after partial liquidation"
                );
            } else {
                // If fully liquidated, lFactor should be 0
                assertEq(lFactorAfter, 0, "Fully liquidated account should have 0 lFactor");
            }
        }
    }

    function _createPositions() internal {
        _prepareBALRETH(borrower1, _ONE);
        _prepareBALRETH(borrower2, _ONE);
        _prepareBALRETH(borrower3, _ONE);
        _prepareBALRETH(borrower4, _ONE);
        _prepareBALRETH(borrower5, _ONE);

        vm.startPrank(borrower1);
        balRETH.approve(address(pBALRETH), _ONE);
        pBALRETH.depositAsCollateral(_ONE, borrower1);
        eUSDC.borrow(borrowAmounts[0]);
        vm.stopPrank();

        vm.startPrank(borrower2);
        balRETH.approve(address(pBALRETH), _ONE);
        pBALRETH.depositAsCollateral(_ONE, borrower2);
        eUSDC.borrow(borrowAmounts[1]);
        vm.stopPrank();

        vm.startPrank(borrower3);
        balRETH.approve(address(pBALRETH), _ONE);
        pBALRETH.depositAsCollateral(_ONE, borrower3);
        eUSDC.borrow(borrowAmounts[2]);
        vm.stopPrank();

        vm.startPrank(borrower4);
        balRETH.approve(address(pBALRETH), _ONE);
        pBALRETH.depositAsCollateral(_ONE, borrower4);
        eUSDC.borrow(borrowAmounts[3]);
        vm.stopPrank();

        vm.startPrank(borrower5);
        balRETH.approve(address(pBALRETH), _ONE);
        pBALRETH.depositAsCollateral(_ONE, borrower5);
        eUSDC.borrow(borrowAmounts[4]);
        vm.stopPrank();
    }

    function _getLFactorsPreLiquidation() internal view returns (uint256[] memory lFactors) {
        lFactors = new uint256[](5);

        for(uint i; i < 5; i++) {
            (lFactors[i],,) = marketManagerIsolated.liquidationStatusOf(
                borrowers[i],
                address(eUSDC),
                address(pBALRETH)
            );
        }

        return lFactors;
    }

    function _getDebtBalancePreLiquidation() internal view returns (uint256[] memory debtBalances) {
        debtBalances = new uint256[](5);
        for(uint i; i < 5; i++) {
            debtBalances[i] = eUSDC.debtBalance(borrowers[i]);
        }
        return debtBalances;
    }

    function _getLiquidationValuesWithHigherPrecision_NonAuction(
        uint256 eTokenPrice,
        uint256 cTokenPrice,
        uint256[] memory lFactors
    ) internal view returns (
        uint256[] memory maxAmount, 
        uint256[] memory liquidatedPTokens,
        uint256[] memory collateralRequired
    ) {
        uint256 cTokenExchangeRate = pBALRETH.exchangeRate();
        
        // Keep original values but use higher precision for calculations
        uint256 PRECISION_FACTOR = 1e18; // Extra precision factor
        
        maxAmount = new uint256[](5);
        liquidatedPTokens = new uint256[](5);
        collateralRequired = new uint256[](5);

        for (uint i; i < 5; i++) {
            if (lFactors[i] == 0) continue;
            
            // Follow the contract's exact calculations but with higher precision
            uint256 auctionCFactor = baseCFactor + ((cFactorCurve * lFactors[i]) / WAD);
            uint256 auctionLiqIncentive = liqBaseIncentive + ((liqCurve * lFactors[i]) / WAD);
            
            // Calculate with extra precision
            uint256 highPrecisionD2C = (((auctionLiqIncentive * eTokenPrice * WAD * PRECISION_FACTOR) /
                (cTokenPrice * cTokenExchangeRate)) * 1e18) / 1e6;
                
            maxAmount[i] = (auctionCFactor * borrowAmounts[i]) / WAD;
            
            // Calculate with extra precision
            liquidatedPTokens[i] = (maxAmount[i] * highPrecisionD2C) / (WAD * PRECISION_FACTOR);
            
            if (liquidatedPTokens[i] > collateralAvailable) {
                // Use the contract's exact formula
                maxAmount[i] = FixedPointMathLib.mulDivUp(
                    maxAmount[i],
                    collateralAvailable,
                    liquidatedPTokens[i]
                );
                liquidatedPTokens[i] = collateralAvailable;
            }
            
            // Use the contract's exact formula
            collateralRequired[i] = (borrowAmounts[i] * highPrecisionD2C) / (WAD * PRECISION_FACTOR);
        }

        return (maxAmount, liquidatedPTokens, collateralRequired);
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