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
// - User 1: 1.0 strategyCBALRETH ($1,600), 800 USDC debt (healthy)
// - User 2: 1.0 strategyCBALRETH ($1,600), 1,000 USDC debt (borderline)
// - User 3: 1.0 strategyCBALRETH ($1,600), 1,100 USDC debt (soft liquidation)
// - User 4: 1.0 strategyCBALRETH ($1,600), 1,200 USDC debt (hard liquidation)
// - User 5: 1.0 strategyCBALRETH ($1,600), 1,300 USDC debt (severe liquidation)
// - Action: Price drop of strategyCBALRETH by 15% (to $1,380)
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

    event Repay(uint256 assets, address payer, address account);
    event BadDebtRecognized(uint256 assets, address liquidator);

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
        usdc.approve(address(borrowableCUSDC), _ONE);
        balRETH.approve(address(strategyCBALRETH), _ONE + 77777);

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(strategyCBALRETH);
        tokenConfig.collRatio = 8000;
        tokenConfig.collReqSoft = 2500;
        tokenConfig.collReqHard = 2200;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.minEffectiveCloseFactor = 2000;
        tokenConfig.maxEffectiveCloseFactor = 5000;
        tokenConfig.baseCFactor = 2000;
        tokenConfig.collateralCap = 100_000e18;
        tokenConfig.debtCap = 0;

        marketManagerIsolated.updateTokenConfig(tokenConfig);

        tokenConfig.cToken = address(borrowableCUSDC);
        tokenConfig.debtCap = 100_000e6;
        marketManagerIsolated.updateTokenConfig(tokenConfig);

        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 200000e6);
        _prepareBALRETH(liquidityProvider, 10e18);
        // Mint borrowable cUSDC.
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 200000e6);
        borrowableCUSDC.deposit(200000e6, liquidityProvider);
        // Mint cBALETH.
        balRETH.approve(address(strategyCBALRETH), 10e18);
        strategyCBALRETH.deposit(10e18, liquidityProvider);
        vm.stopPrank();

        _createPositions();

        mockWethFeed.setMockAnswer(1380e8);
        mockRethFeed.setMockAnswer(1380e8);

        (,,,, uint256 liqBaseIncentive_, uint256 liqCurve_,,,,, uint256 baseCFactor_, uint256 cFactorCurve_) = 
            marketManagerIsolated.tokenData(address(strategyCBALRETH));

        liqBaseIncentive = liqBaseIncentive_;
        liqCurve = liqCurve_;
        baseCFactor = baseCFactor_;
        cFactorCurve = cFactorCurve_;

        // vm.warp(block.timestamp + 20 minutes); skipping so no interest accrues which keeps it simple

    }

    function test_multipleUsersLiquidatedWithVaryingHealthFactors() public {

        IMarketManager.LiqInstructions memory liqInstructions;
        liqInstructions = IMarketManager.LiqInstructions({
            debtToken: address(borrowableCUSDC),
            collateralToken: address(strategyCBALRETH),
            numAccounts: 5,
            liquidateExact: false,
            liquidatedShares: 0,
            debtRepaid: 0,
            badDebt: 0
        });

        _prepareUSDC(address(this), 100000e6);

        // ===== Cache liquidation values =====

        uint256[] memory lFactorsPreLiquidation = _getLFactorsPreLiquidation();
        uint256[] memory debtBalancesPreLiquidation = _getDebtBalancePreLiquidation();

        (,uint256 collateralTokenPrice, uint256 debtTokenPrice) = 
            marketManagerIsolated.liquidationStatusOf(
                borrowers[0],
                address(strategyCBALRETH), 
                address(borrowableCUSDC)
            );

        (uint256[] memory maxAmount, uint256[] memory collateralLiquidated, uint256[] memory collateralRequired) = 
            _getLiquidationValuesWithHigherPrecision_NonAuction(
                debtTokenPrice, collateralTokenPrice, lFactorsPreLiquidation
            );

        uint256 expectedTotalBadDebt;
        uint256 cTokenExchangeRate = strategyCBALRETH.exchangeRate();

        for(uint i; i < 5; i++) {
            badDebt[i] = _calculateBadDebt(
                debtBalancesPreLiquidation[i],
                maxAmount[i],
                collateralAvailable,
                collateralRequired[i],
                collateralLiquidated[i],
                collateralTokenPrice,
                debtTokenPrice,
                cTokenExchangeRate
            );
            expectedTotalBadDebt += badDebt[i];
        }

        uint256 totalBorrowsBefore = borrowableCUSDC.marketOutstandingDebt();

        // ===== Liquidate =====

        borrowableCUSDC.approve(address(marketManagerIsolated), 100000e6);

        // Assert BadDebtRecognized event is emitted with expected total bad debt
        vm.expectEmit();
        emit BadDebtRecognized(expectedTotalBadDebt, address(this));
        emit Repay(maxAmount[2] + badDebt[2], address(this), borrowers[2]);
        emit Repay(maxAmount[3] + badDebt[3], address(this), borrowers[3]);
        emit Repay(maxAmount[4] + badDebt[4], address(this), borrowers[4]);

        borrowableCUSDC.liquidate(
            borrowers,
            address(strategyCBALRETH)
        );

        // ===== Validate =====

        // Verify healthy accounts (1 and 2) are not liquidated
        assertEq(borrowableCUSDC.debtBalance(borrowers[0]), debtBalancesPreLiquidation[0], "Healthy account 1 shouldn't be liquidated");
        assertEq(borrowableCUSDC.debtBalance(borrowers[1]), debtBalancesPreLiquidation[1], "Healthy account 2 shouldn't be liquidated");

        // Verify liquidated accounts (3, 4, and 5) are liquidated
        for (uint i = 2; i < 5; i++) {
            // Debt should be reduced by maxAmount if soft liquidation
            if(borrowers[i] == borrower3) {

                assertEq(borrowableCUSDC.debtBalance(borrowers[i]), debtBalancesPreLiquidation[i] - maxAmount[i], "Borrower 3 should be soft liquidated");
            } else {
                assertEq(borrowableCUSDC.debtBalance(borrowers[i]), 0, "Borrower should be hard liquidated");
            }

            // Collateral should be reduced by collateralLiquidated
            assertApproxEqAbs(
                strategyCBALRETH.balanceOf(borrowers[i]), 
                _ONE - collateralLiquidated[i],
                1000, // Tolerance of 1000 wei 
                "Collateral post liquidation mismatch"
            );
        }

        uint256 totalDebtRepaid = maxAmount[2] + borrowAmounts[3] + borrowAmounts[4];

        assertApproxEqAbs(
            borrowableCUSDC.marketOutstandingDebt(),
            totalBorrowsBefore - totalDebtRepaid,
            100, // Small tolerance
            "Incorrect totalBorrows after liquidation"
        );

        // Verify liquidator received the expected collateral
        uint256 expectedLiquidatorBalance = collateralLiquidated[2] + collateralLiquidated[3] + collateralLiquidated[4];
        assertApproxEqAbs(
            strategyCBALRETH.balanceOf(address(this)),
            expectedLiquidatorBalance,
            1000,
            "Liquidator didn't receive expected collateral"
        );

        // Test accounts health factor after liquidation
        for (uint i = 2; i < 5; i++) {
            (uint256 lFactorAfter,,) = marketManagerIsolated.liquidationStatusOf(
                borrowers[i],
                address(borrowableCUSDC),
                address(strategyCBALRETH)
            );
            
            if (borrowableCUSDC.debtBalance(borrowers[i]) > 0) {
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
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.depositAsCollateral(_ONE, borrower1);
        borrowableCUSDC.borrow(borrowAmounts[0], borrower1);
        vm.stopPrank();

        vm.startPrank(borrower2);
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.depositAsCollateral(_ONE, borrower2);
        borrowableCUSDC.borrow(borrowAmounts[1], borrower2);
        vm.stopPrank();

        vm.startPrank(borrower3);
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.depositAsCollateral(_ONE, borrower3);
        borrowableCUSDC.borrow(borrowAmounts[2], borrower3);
        vm.stopPrank();

        vm.startPrank(borrower4);
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.depositAsCollateral(_ONE, borrower4);
        borrowableCUSDC.borrow(borrowAmounts[3], borrower4);
        vm.stopPrank();

        vm.startPrank(borrower5);
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.depositAsCollateral(_ONE, borrower5);
        borrowableCUSDC.borrow(borrowAmounts[4], borrower5);
        vm.stopPrank();
    }

    function _getLFactorsPreLiquidation() internal view returns (uint256[] memory lFactors) {
        lFactors = new uint256[](5);

        for(uint i; i < 5; i++) {
            (lFactors[i],,) = marketManagerIsolated.liquidationStatusOf(
                borrowers[i],
                address(borrowableCUSDC),
                address(strategyCBALRETH)
            );
        }

        return lFactors;
    }

    function _getDebtBalancePreLiquidation() internal view returns (uint256[] memory debtBalances) {
        debtBalances = new uint256[](5);
        for(uint i; i < 5; i++) {
            debtBalances[i] = borrowableCUSDC.debtBalance(borrowers[i]);
        }
        return debtBalances;
    }

    function _getLiquidationValuesWithHigherPrecision_NonAuction(
        uint256 debtTokenPrice,
        uint256 collateralTokenPrice,
        uint256[] memory lFactors
    ) internal view returns (
        uint256[] memory maxAmount, 
        uint256[] memory collateralLiquidated,
        uint256[] memory collateralRequired
    ) {
        uint256 cTokenExchangeRate = strategyCBALRETH.exchangeRate();
        
        // Keep original values but use higher precision for calculations
        uint256 PRECISION_FACTOR = 1e18; // Extra precision factor
        
        maxAmount = new uint256[](5);
        collateralLiquidated = new uint256[](5);
        collateralRequired = new uint256[](5);

        for (uint i; i < 5; i++) {
            if (lFactors[i] == 0) continue;
            
            // Follow the contract's exact calculations but with higher precision
            uint256 auctionCFactor = baseCFactor + ((cFactorCurve * lFactors[i]) / WAD);
            uint256 auctionLiqIncentive = liqBaseIncentive + ((liqCurve * lFactors[i]) / WAD);
            
            // Calculate with extra precision
            uint256 highPrecisionD2C = (((auctionLiqIncentive * debtTokenPrice * WAD * PRECISION_FACTOR) /
                (collateralTokenPrice * cTokenExchangeRate)) * 1e18) / 1e6;
                
            maxAmount[i] = (auctionCFactor * borrowAmounts[i]) / WAD;
            
            // Calculate with extra precision
            collateralLiquidated[i] = (maxAmount[i] * highPrecisionD2C) / (WAD * PRECISION_FACTOR);
            
            if (collateralLiquidated[i] > collateralAvailable) {
                // Use the contract's exact formula
                maxAmount[i] = FixedPointMathLib.mulDivUp(
                    maxAmount[i],
                    collateralAvailable,
                    collateralLiquidated[i]
                );
                collateralLiquidated[i] = collateralAvailable;
            }
            
            // Use the contract's exact formula
            collateralRequired[i] = (borrowAmounts[i] * highPrecisionD2C) / (WAD * PRECISION_FACTOR);
        }

        return (maxAmount, collateralLiquidated, collateralRequired);
    }

    function _calculateBadDebt(
        uint256 _debtBalance,
        uint256 _debtAmount,
        uint256 _collateralAvailable,
        uint256 _collateralRequired,
        uint256 _collateralLiquidated,
        uint256 _collateralTokenUnderlyingPrice,
        uint256 _debtTokenUnderlyingPrice,
        uint256 _cTokenExchangeRate
    ) internal pure returns (uint256 badDebt) {

        if(_collateralRequired > _collateralAvailable) {
    
        badDebt = (_debtBalance - _debtAmount) -
        FixedPointMathLib.mulDivUp(
            ((_collateralAvailable - _collateralLiquidated) * _cTokenExchangeRate) / WAD,
            _collateralTokenUnderlyingPrice,
            (_debtTokenUnderlyingPrice * WAD) / 1e6
        );

        } else {
            return 0;
        }
        
    }

}