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

// ## Scenario 1: Multiple Users Liquidated
// - Setup: 5 users with varying health factors
// - User 1: 1.0 pBALRETH ($1,600), 800 USDC debt (healthy)
// - User 2: 1.0 pBALRETH ($1,600), 1,000 USDC debt (borderline)
// - User 3: 1.0 pBALRETH ($1,600), 1,100 USDC debt (soft liquidation)
// - User 4: 1.0 pBALRETH ($1,600), 1,200 USDC debt (hard liquidation)
// - User 5: 1.0 pBALRETH ($1,600), 1,300 USDC debt (severe liquidation)
// - Action: Price drop of pBALRETH by 15% (to $1,380)
// - Expected: Users 3, 4, and 5 should be liquidated in single transaction
    

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
        // _prepareUSDC(address(this), _ONE); // possibly not needed

        vm.prank(user1);
        usdc.approve(address(eUSDC), _ONE);
        balRETH.approve(address(pBALRETH), _ONE + 42069);

        marketManager.listTokens(address(pBALRETH), address(eUSDC));

        eUSDC.depositReserves(1000e6);
        // _prepareBALRETH(address(this), 10e18);
        // balRETH.approve(address(pBALRETH), 10e18);

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

        mockWethFeed.setMockAnswer(1380e8);
        mockRethFeed.setMockAnswer(1380e8);

        (,,,, uint256 liqBaseIncentive_, uint256 liqCurve_,,,,, uint256 baseCFactor_, uint256 cFactorCurve_) = 
            marketManager.tokenData(address(pBALRETH));

        liqBaseIncentive = liqBaseIncentive_;
        liqCurve = liqCurve_;
        baseCFactor = baseCFactor_;
        cFactorCurve = cFactorCurve_;

        // vm.warp(block.timestamp + 20 minutes); skipping so no interest accrues which keeps it simple

    }

    function test_multipleUsersLiquidatedWithVaryingHealthFactors() public {

        IMarketManager.LiqInstructions memory liqInstructions;
        liqInstructions = IMarketManager.LiqInstructions({
            eToken: address(eUSDC),
            pToken: address(pBALRETH),
            numAccounts: 5,
            liquidateExact: false,
            eTokenRepaid: 0,
            pTokenLiquidated: 0,
            badDebt: 0
        });

        _prepareUSDC(address(this), 100000e6);

        // ===== Cache liquidation values =====

        uint256[] memory lFactorsPreLiquidation = _getLFactorsPreLiquidation();
        uint256[] memory debtBalancesPreLiquidation = _getDebtBalancePreLiquidation();

        console2.log("lFactorsPreLiquidation", lFactorsPreLiquidation[0]);

        (,uint256 eTokenPrice, uint256 pTokenPrice) = 
            marketManager.liquidationStatusOf(borrowers[0], address(eUSDC), address(pBALRETH));

        (uint256[] memory maxAmount, uint256[] memory liquidatedPTokens, uint256[] memory collateralRequired) = 
            _getLiquidationValuesWithHigherPrecision(
                eTokenPrice, pTokenPrice, lFactorsPreLiquidation
            );

        // DELETE
        // address[] memory borrowersTemporary = new address[](1);
        // borrowersTemporary[0] = borrowers[4];

        console2.log("Expected maxAmount for borrower 1", maxAmount[0]);
        console2.log("Expected liquidatedPTokens for borrower 1", liquidatedPTokens[0]);
        console2.log("Expected collateralRequired for borrower 1", collateralRequired[0]);
        console2.log("Expected maxAmount for borrower 2", maxAmount[1]);
        console2.log("Expected liquidatedPTokens for borrower 2", liquidatedPTokens[1]);
        console2.log("Expected collateralRequired for borrower 2", collateralRequired[1]);
        console2.log("Expected maxAmount for borrower 3", maxAmount[2]);
        console2.log("Expected liquidatedPTokens for borrower 3", liquidatedPTokens[2]);
        console2.log("Expected collateralRequired for borrower 3", collateralRequired[2]);
        console2.log("Expected maxAmount for borrower 4", maxAmount[3]);
        console2.log("Expected liquidatedPTokens for borrower 4", liquidatedPTokens[3]);
        console2.log("Expected collateralRequired for borrower 4", collateralRequired[3]);
        console2.log("Expected maxAmount for borrower 5", maxAmount[4]);
        console2.log("Expected liquidatedPTokens for borrower 5", liquidatedPTokens[4]);
        console2.log("Expected collateralRequired for borrower 5", collateralRequired[4]);

        // ===== Liquidate =====

        eUSDC.approve(address(marketManager), 100000e6);
        eUSDC.liquidate(
            borrowers,
            address(pBALRETH)
        );

        // ===== Validate =====
        
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
            (lFactors[i],,) = marketManager.liquidationStatusOf(
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
            debtBalances[i] = eUSDC.debtBalanceCached(borrowers[i]);
        }
        return debtBalances;
    }

    function _getLiquidationValuesWithHigherPrecision(
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
                (pTokenPrice * pTokenExchangeRate)) * 1e18) / 1e6;
                
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

    function _calculateBadDebtWithHigherPrecision(
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

    function _calculateExpectedTotalBadDebt(
        uint256[] memory liquidatedPTokens
    ) internal view returns (uint256 totalBadDebt) {

        
    }



    // function _validateLiquidations() internal {

    //     uint256 lFactor;
    //     uint256 eTokenPrice;
    //     uint256 pTokenPrice;
        
    //     for(uint i; i < 5; i++) {

    //         (lFactor, eTokenPrice, pTokenPrice) = marketManager.liquidationStatusOf(
    //             borrowers[i],
    //             address(eUSDC),
    //             address(pBALRETH)
    //         );

    //         (uint256 maxAmount, uint256 liquidatedPTokens) = _calculateExpectedRepayAndLiquidated(
    //             _ONE,
    //             lFactor,
    //             borrowAmounts[i],
    //             eTokenPrice,
    //             pTokenPrice
    //         );

    //         uint256 badDebt = _calculateBadDebt(
    //             borrowAmounts[i],
    //             _ONE,
    //             liquidatedPTokens,
    //             pTokenPrice,
    //             eTokenPrice,
    //             borrowAmounts[i]
    //         );


    //     }
    // }

    // function _calculateExpectedRepayAndLiquidated(
    //     uint256 collateralAvailable, 
    //     uint256 lFactor, 
    //     uint256 loanAmount, 
    //     uint256 eTokenUnderlyingPrice, 
    //     uint256 pTokenUnderlyingPrice) internal view returns (uint256 maxAmount, uint256 liquidatedPTokens) {

    //     (,,,, uint256 liqBaseIncentive, uint256 liqCurve,,,,, uint256 baseCFactor, uint256 cFactorCurve) = 
    //         marketManager.tokenData(address(pBALRETH));
        
        
    //     // default values since not using ASS
    //     uint256 auctionCFactor = baseCFactor + ((cFactorCurve * lFactor) / WAD);

    //     uint256 auctionLiqIncentive = liqBaseIncentive +
    //             ((liqCurve * lFactor) / WAD);

    //     // uint256 pTokenDecimals = 1e18;
    //     // uint256 eTokenDecimals = 1e6;

    //     uint256 debtToCollateralMultiplier = 
    //     (((auctionLiqIncentive * eTokenUnderlyingPrice * WAD) /
    //         (pTokenUnderlyingPrice * 1e18)) *
    //         1e18) / 1e6;

    //     maxAmount = (auctionCFactor * loanAmount) / WAD;

    //     liquidatedPTokens = (maxAmount * debtToCollateralMultiplier) / WAD;

    //     console2.log("liquidatedPTokens 000", liquidatedPTokens);

    //     maxAmount = FixedPointMathLib.mulDivUp(
    //         maxAmount,
    //         collateralAvailable,
    //         liquidatedPTokens
    //     );

    //     liquidatedPTokens = collateralAvailable;


    //     return (maxAmount, liquidatedPTokens);
    // }


}