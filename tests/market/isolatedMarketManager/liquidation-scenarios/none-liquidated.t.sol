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

// ## Scenario 3: No Users Liquidated
// - Setup: 3 users with healthy positions
// - User 1: 1.5 pBALRETH ($2,400), 1,000 USDC debt
// - User 2: 1.4 pBALRETH ($2,240), 1,000 USDC debt
// - User 3: 1.3 pBALRETH ($2,080), 1,000 USDC debt
// - Action: Price drop of pBALRETH by 5% (to $1,520)
// - Expected: No liquidations occur
    

contract NoneLiquidated is TestBaseMarketManagerIsolated {

    address borrower1 = makeAddr("borrower1");
    address borrower2 = makeAddr("borrower2");
    address borrower3 = makeAddr("borrower3");

    uint256 borrowAmount = 1000e6;
    address[] borrowers = [borrower1, borrower2, borrower3];
    uint256[] collateralAmounts = [1.5e18, 1.4e18, 1.3e18];

    uint256 WAD_SQUARED = 1e36;

    uint256 collateralAvailable = WAD;

    uint256 liqBaseIncentive;
    uint256 liqCurve;
    uint256 baseCFactor;
    uint256 cFactorCurve;

    event BadDebtRecognized(address liquidator, uint256 amount);

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

        _prepareBALRETH(user1, _ONE + 42069);

        vm.prank(user1);
        usdc.approve(address(eUSDC), _ONE);
        balRETH.approve(address(pBALRETH), _ONE + 42069);

        marketManager.listTokens(address(pBALRETH), address(eUSDC));

        eUSDC.depositReserves(1000e6);

        // Update position token parameters
        marketManager.updatePositionToken(
            8000,    // collRatio 80% 
            2500,    // collReqSoft 25%
            2200,    // collReqHard 22% (increased to be > liqIncMax + 1%)
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
        marketManager.setPTokenCollateralCaps(tokens, caps);

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

        mockWethFeed.setMockAnswer(1520e8);
        mockRethFeed.setMockAnswer(1520e8);

        (,,,, uint256 liqBaseIncentive_, uint256 liqCurve_,,,,, uint256 baseCFactor_, uint256 cFactorCurve_) = 
            marketManager.tokenData(address(pBALRETH));

        liqBaseIncentive = liqBaseIncentive_;
        liqCurve = liqCurve_;
        baseCFactor = baseCFactor_;
        cFactorCurve = cFactorCurve_;

        // vm.warp(block.timestamp + 20 minutes); 

    }

    function test_noneLiquidated() public {

        IMarketManager.LiqInstructions memory liqInstructions;
        liqInstructions = IMarketManager.LiqInstructions({
            eToken: address(eUSDC),
            pToken: address(pBALRETH),
            numAccounts: 3,
            liquidateExact: false,
            eTokenRepaid: 0,
            pTokenLiquidated: 0,
            badDebt: 0
        });

        _prepareUSDC(address(this), 100000e6);

        // ===== Cache liquidation values =====

        uint256[] memory lFactorsPreLiquidation = _getLFactorsPreLiquidation();
        uint256[] memory debtBalancesPreLiquidation = _getDebtBalancePreLiquidation();

        (,uint256 eTokenPrice, uint256 pTokenPrice) = 
            marketManager.liquidationStatusOf(borrowers[0], address(eUSDC), address(pBALRETH));

        (uint256[] memory maxAmount, uint256[] memory liquidatedPTokens, uint256[] memory collateralRequired) = 
            _getLiquidationValuesWithHigherPrecision_NonAtlas(
                eTokenPrice, pTokenPrice, lFactorsPreLiquidation
            );

        uint256 expectedTotalBadDebt;
        uint256 pTokenExchangeRate = pBALRETH.exchangeRateCached();

        for(uint i; i < 3; i++) {
            expectedTotalBadDebt += _calculateBadDebt(
                debtBalancesPreLiquidation[i],
                maxAmount[i],
                collateralAvailable,
                collateralRequired[i],
                liquidatedPTokens[i],
                pTokenPrice,
                eTokenPrice,
                pTokenExchangeRate
            );
        }

        uint256 totalBorrowsBefore = eUSDC.totalBorrows();

        // ===== Liquidate =====

        eUSDC.approve(address(marketManager), 100000e6);

        vm.expectRevert(abi.encodeWithSelector(MarketManagerIsolated.MarketManager__NoLiquidationAvailable.selector));
        eUSDC.liquidate(
            borrowers,
            address(pBALRETH)
        );

        // ===== Validate =====

        // Verify all healthy accounts (1, 2, and 3) are not liquidated
        assertEq(eUSDC.debtBalanceCached(borrowers[0]), debtBalancesPreLiquidation[0], "Healthy account 1 shouldn't be liquidated");
        assertEq(eUSDC.debtBalanceCached(borrowers[1]), debtBalancesPreLiquidation[1], "Healthy account 2 shouldn't be liquidated");
        assertEq(eUSDC.debtBalanceCached(borrowers[2]), debtBalancesPreLiquidation[2], "Healthy account 3 shouldn't be liquidated");

        // Verify all users have the same collateral
        assertEq(pBALRETH.balanceOf(borrowers[0]), collateralAmounts[0], "Healthy account 1 should have the same collateral");
        assertEq(pBALRETH.balanceOf(borrowers[1]), collateralAmounts[1], "Healthy account 2 should have the same collateral");
        assertEq(pBALRETH.balanceOf(borrowers[2]), collateralAmounts[2], "Healthy account 3 should have the same collateral");
    
        // Verify the same amount of borrows is still owed
        assertEq(eUSDC.totalBorrows(), totalBorrowsBefore, "Total borrows should be the same");

        // Verify liquidator received no collateral
        assertEq(pBALRETH.balanceOf(address(this)), 0, "Liquidator should have received no collateral");
    }

    function _createPositions() internal {
        _prepareBALRETH(borrower1, collateralAmounts[0]);
        _prepareBALRETH(borrower2, collateralAmounts[1]);
        _prepareBALRETH(borrower3, collateralAmounts[2]);

        vm.startPrank(borrower1);
        balRETH.approve(address(pBALRETH), collateralAmounts[0]);
        pBALRETH.depositAsCollateral(collateralAmounts[0], borrower1);
        eUSDC.borrow(borrowAmount);
        vm.stopPrank();

        vm.startPrank(borrower2);
        balRETH.approve(address(pBALRETH), collateralAmounts[1]);
        pBALRETH.depositAsCollateral(collateralAmounts[1], borrower2);
        eUSDC.borrow(borrowAmount);
        vm.stopPrank();

        vm.startPrank(borrower3);
        balRETH.approve(address(pBALRETH), collateralAmounts[2]);
        pBALRETH.depositAsCollateral(collateralAmounts[2], borrower3);
        eUSDC.borrow(borrowAmount);
        vm.stopPrank();
    }

    function _getLFactorsPreLiquidation() internal view returns (uint256[] memory lFactors) {
        lFactors = new uint256[](3);

        for(uint i; i < 3; i++) {
            (lFactors[i],,) = marketManager.liquidationStatusOf(
                borrowers[i],
                address(eUSDC),
                address(pBALRETH)
            );
        }

        return lFactors;
    }

    function _getDebtBalancePreLiquidation() internal view returns (uint256[] memory debtBalances) {
        debtBalances = new uint256[](3);
        for(uint i; i < 3; i++) {
            debtBalances[i] = eUSDC.debtBalanceCached(borrowers[i]);
        }
        return debtBalances;
    }

    function _getLiquidationValuesWithHigherPrecision_NonAtlas(
        uint256 eTokenPrice,
        uint256 pTokenPrice,
        uint256[] memory lFactors
    ) internal view returns (
        uint256[] memory maxAmount, 
        uint256[] memory liquidatedPTokens,
        uint256[] memory collateralRequired
    ) {
        uint256 pTokenExchangeRate = pBALRETH.exchangeRateCached();
        
        // Keep original values but use higher precision for calculations
        uint256 PRECISION_FACTOR = 1e18; // Extra precision factor
        
        maxAmount = new uint256[](3);
        liquidatedPTokens = new uint256[](3);
        collateralRequired = new uint256[](3);

        for (uint i; i < 3; i++) {
            if (lFactors[i] == 0) continue;
            
            // Follow the contract's exact calculations but with higher precision
            uint256 auctionCFactor = baseCFactor + ((cFactorCurve * lFactors[i]) / WAD);
            uint256 auctionLiqIncentive = liqBaseIncentive + ((liqCurve * lFactors[i]) / WAD);
            
            // Calculate with extra precision
            uint256 highPrecisionD2C = (((auctionLiqIncentive * eTokenPrice * WAD * PRECISION_FACTOR) /
                (pTokenPrice * pTokenExchangeRate)) * 1e18) / 1e6;
                
            maxAmount[i] = (auctionCFactor * borrowAmount) / WAD;
            
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
            collateralRequired[i] = (borrowAmount * highPrecisionD2C) / (WAD * PRECISION_FACTOR);
        }

        return (maxAmount, liquidatedPTokens, collateralRequired);
    }

    function _calculateBadDebt(
        uint256 _debtBalance,
        uint256 _debtAmount,
        uint256 _collateralAvailable,
        uint256 _collateralRequired,
        uint256 _liquidatedPTokens,
        uint256 _pTokenUnderlyingPrice,
        uint256 _eTokenUnderlyingPrice,
        uint256 _pTokenExchangeRate
    ) internal pure returns (uint256 badDebt) {

        if(_collateralRequired > _collateralAvailable) {
    
        badDebt = (_debtBalance - _debtAmount) -
        FixedPointMathLib.mulDivUp(
            ((_collateralAvailable - _liquidatedPTokens) * _pTokenExchangeRate) / WAD,
            _pTokenUnderlyingPrice,
            (_eTokenUnderlyingPrice * WAD) / 1e6
        );

        } else {
            return 0;
        }
        
    }

}