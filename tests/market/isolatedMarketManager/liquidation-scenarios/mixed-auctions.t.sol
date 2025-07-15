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

// ## Scenario 4: Mixed Auction and Regular Liquidations, all using liquidate() function
// - Setup: 4 users with varying positions
// - User 1: 1.9 strategyCBALRETH ($2,850), 2500 USDC debt (for Auction)
// - User 2: 1.9 strategyCBALRETH ($2,850), 2500 USDC debt (for Auction)
// - User 3: 1.9 strategyCBALRETH ($2,850), 2500 USDC debt (for regular)
// - User 4: 1.9 strategyCBALRETH ($2,850), 2500 USDC debt (for regular)
// - Action 1: Price drop by to ~$1,300, Auction transaction with custom parameters for User 1 and User 2
// - Action 2: Regular liquidation attempt for User 3 and User 4
// - Expected: Users 1 and 2 liquidated via Auction with custom parameters, Users 3 and 4 via regular liquidation
//          All users have the same underwater position, so each accrue bad debt at the moment.
//          Users who are liquidated via Auction accrue less bad debt because their positions are not completely closed
//                  because they use a lower close factor than using liquiding the maximum amount.
//          Users who are liquidated without Auction are fully liquidated and accrue the full bad debt amount.

// TODO: Use different loan/collateral ratios for each user. Currently each have the same collateral amount and loan.


contract MixedAuction is TestBaseMarketManagerIsolated {

    address borrower1 = makeAddr("borrower1");
    address borrower2 = makeAddr("borrower2");
    address borrower3 = makeAddr("borrower3");
    address borrower4 = makeAddr("borrower4");

    uint256 borrowAmount = 2500e6;
    address[] auctionBorrowers = [borrower1, borrower2];
    address[] regularBorrowers = [borrower3, borrower4];
    uint256[] collateralAmounts = [1.9e18, 1.9e18, 1.9e18, 1.9e18];

    uint256 WAD_SQUARED = 1e36;

    uint256 liqBaseIncentive;
    uint256 liqCurve;
    uint256 baseCFactor;
    uint256 cFactorCurve;

    address dappControlUser = makeAddr("dappControlUser");

    // Auction parameters
    uint256 validPenalty = 1.04e18;
    uint256 closeFactor = 0.50e18;

    event Repay(uint256 assets, address payer, address account);
    event BadDebtRecognized(uint256 assets, address liquidator);

    function setUp() public override {
        super.setUp();

        mockUsdcFeed = new MockDataFeed(_CHAINLINK_USDC_USD);
        mockUsdcFeed.setMockAnswer(1e8);

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

        MarketManagerIsolated.TokenConfig memory tokenConfigs;
        tokenConfigs.cToken = address(strategyCBALRETH);
        tokenConfigs.collRatio = 9200;
        tokenConfigs.collReqSoft = 830;
        tokenConfigs.collReqHard = 650;
        tokenConfigs.liqIncBase = 500;
        tokenConfigs.liqIncHard = 550;
        tokenConfigs.liqIncMin = 300;
        tokenConfigs.liqIncMax = 550;
        tokenConfigs.minEffectiveCloseFactor = 1000;
        tokenConfigs.maxEffectiveCloseFactor = 5000;
        tokenConfigs.baseCFactor = 2000;
        tokenConfigs.collateralCap = 100_000e18;
        tokenConfigs.debtCap = 0;

        marketManagerIsolated.updateTokenConfig(tokenConfigs);

        tokenConfigs.cToken = address(borrowableCUSDC);
        tokenConfigs.debtCap = 100_000e6;

        marketManagerIsolated.updateTokenConfig(tokenConfigs);

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

        mockWethFeed.setMockAnswer(1300e8);
        mockRethFeed.setMockAnswer(1300e8);

        (,,,, uint256 liqBaseIncentive_, uint256 liqCurve_,,,,, uint256 baseCFactor_, uint256 cFactorCurve_) = 
            marketManagerIsolated.tokenData(address(strategyCBALRETH));

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

    uint256[] debtBalancesPreLiquidation_auction;
    uint256[] debtBalancesPreLiquidation_regular;
    uint256[] lFactorsPreLiquidation_auction;
    uint256[] lFactorsPreLiquidation_regular;
    uint256 debtTokenPrice;
    uint256 collateralTokenPrice;
    uint256[] maxAmount_auction;
    uint256[] collateralLiquidated_auction;
    uint256[] collateralRequired_auction;
    uint256[] maxAmount_regular;
    uint256[] collateralLiquidated_regular;
    uint256[] collateralRequired_regular;
    uint256[] badDebt_auction = new uint256[](2);
    uint256[] badDebt_regular = new uint256[](2);
    uint256 totalBadDebtRegular;
    uint256 totalBadDebtAuction;
    uint256 totalBorrowsBefore;
    uint256 totalDebtRepaid;

    function test_mixedAuction() public {

        _prepareUSDC(dappControlUser, 100000e6);
        _prepareUSDC(address(this), 100000e6);

        // ===== Cache liquidation values =====

        uint256 cTokenExchangeRate = strategyCBALRETH.exchangeRate();

        totalBorrowsBefore = borrowableCUSDC.marketOutstandingDebt();

        debtBalancesPreLiquidation_auction = _getDebtBalancePreLiquidation(auctionBorrowers);
        debtBalancesPreLiquidation_regular = _getDebtBalancePreLiquidation(regularBorrowers);

        lFactorsPreLiquidation_auction = _getLFactorsPreLiquidation(auctionBorrowers);
        lFactorsPreLiquidation_regular = _getLFactorsPreLiquidation(regularBorrowers);

        ( , collateralTokenPrice, debtTokenPrice) =
            marketManagerIsolated.liquidationStatusOf(
                auctionBorrowers[0],
                address(strategyCBALRETH),   // collateral token
                address(borrowableCUSDC)     // debt token
            );


        (maxAmount_auction, collateralLiquidated_auction, collateralRequired_auction) = 
            _getLiquidationValuesWithHigherPrecision_Auction(
                debtTokenPrice, collateralTokenPrice, lFactorsPreLiquidation_auction, closeFactor, validPenalty
            );

        (maxAmount_regular, collateralLiquidated_regular, collateralRequired_regular) = 
            _getLiquidationValuesWithHigherPrecision_NonAuction(
                debtTokenPrice, collateralTokenPrice, lFactorsPreLiquidation_regular
            );

        console2.log("CHECKPOINT 1");

        for(uint i; i < 2; i++) {
            badDebt_auction[i] = _calculateBadDebt(
                debtBalancesPreLiquidation_auction[i],
                maxAmount_auction[i],
                collateralAmounts[i],
                collateralRequired_auction[i],
                collateralLiquidated_auction[i],
                collateralTokenPrice,
                debtTokenPrice,
                cTokenExchangeRate
            );
            totalBadDebtAuction += badDebt_auction[i];
            console2.log("badDebt_auction", badDebt_auction[i]);
        }

        for(uint i; i < 2; i++) {
            badDebt_regular[i] = _calculateBadDebt(
                debtBalancesPreLiquidation_regular[i],
                maxAmount_regular[i],
                collateralAmounts[i],
                collateralRequired_regular[i],
                collateralLiquidated_regular[i],
                collateralTokenPrice,
                debtTokenPrice,
                cTokenExchangeRate
            );
            totalBadDebtRegular += badDebt_regular[i];
            console2.log("badDebt_regular", badDebt_regular[i]);
        }

            // ===== Liquidate =====

        vm.startPrank(dappControlUser);
        usdc.approve(address(borrowableCUSDC), 100000e6);

        marketManagerIsolated.setAuctionParameters(
            address(borrowableCUSDC),  
            validPenalty,
            closeFactor
        );

        marketManagerIsolated.unlockAuctionCollateral(address(strategyCBALRETH));

        // Assert BadDebtRecognized event is emitted with expected total bad debt
        vm.expectEmit();
        emit BadDebtRecognized(totalBadDebtAuction, dappControlUser);
        emit Repay(maxAmount_auction[0] + badDebt_auction[0],dappControlUser, auctionBorrowers[0]);
        emit Repay(maxAmount_auction[1] + badDebt_auction[1],dappControlUser, auctionBorrowers[1]);

        borrowableCUSDC.liquidate(
            auctionBorrowers,
            address(strategyCBALRETH)
        );
        marketManagerIsolated.lockAuctionCollateral();
        marketManagerIsolated.resetAuctionParameters();
        vm.stopPrank();

        usdc.approve(address(borrowableCUSDC), 100000e6);

        // Assert BadDebtRecognized event is emitted with expected total bad debt
        vm.expectEmit();
        emit BadDebtRecognized(totalBadDebtRegular, address(this));
        emit Repay(maxAmount_regular[0] + badDebt_regular[0],address(this), regularBorrowers[0] );
        emit Repay(maxAmount_regular[1] + badDebt_regular[1],address(this), regularBorrowers[1]);

        borrowableCUSDC.liquidate(
            regularBorrowers,
            address(strategyCBALRETH)
        );

        // ===== Validate =====

        // Verify debt balances
        assertEq(borrowableCUSDC.debtBalance(auctionBorrowers[0]), debtBalancesPreLiquidation_auction[0] - (maxAmount_auction[0] + badDebt_auction[0]), "Auction borrower 1 debt balance mismatch");
        assertEq(borrowableCUSDC.debtBalance(auctionBorrowers[1]), debtBalancesPreLiquidation_auction[1] - (maxAmount_auction[1] + badDebt_auction[1]), "Auction borrower 2 debt balance mismatch");
        assertEq(borrowableCUSDC.debtBalance(regularBorrowers[0]), debtBalancesPreLiquidation_regular[0] - (maxAmount_regular[0] + badDebt_regular[0]), "Regular borrower 1 debt balance mismatch");
        assertEq(borrowableCUSDC.debtBalance(regularBorrowers[1]), debtBalancesPreLiquidation_regular[1] - (maxAmount_regular[1] + badDebt_regular[1]), "Regular borrower 2 debt balance mismatch");

        // Verify collateral is reduced by collateralLiquidated
        assertApproxEqAbs(
            strategyCBALRETH.balanceOf(auctionBorrowers[0]),
            collateralAmounts[0] - (collateralLiquidated_auction[0]),
            1000, // Tolerance of 1000 wei 
            "Collateral post liquidation mismatch"
        );

        assertApproxEqAbs(
            strategyCBALRETH.balanceOf(auctionBorrowers[1]),
            collateralAmounts[1] - (collateralLiquidated_auction[1]),
            1000, // Tolerance of 1000 wei 
            "Collateral post liquidation mismatch"
        );

        assertApproxEqAbs(
            strategyCBALRETH.balanceOf(regularBorrowers[0]),
            collateralAmounts[2] - (collateralLiquidated_regular[0]),
            1000, // Tolerance of 1000 wei 
            "Collateral post liquidation mismatch"
        );

        assertApproxEqAbs(
            strategyCBALRETH.balanceOf(regularBorrowers[1]),
            collateralAmounts[3] - (collateralLiquidated_regular[1]),
            1000, // Tolerance of 1000 wei 
            "Collateral post liquidation mismatch"
        );

        // Assert Total borrows is reduced by the amount of debt repaid

        totalDebtRepaid = maxAmount_auction[0] + 
        maxAmount_auction[1] + 
        maxAmount_regular[0] + 
        maxAmount_regular[1] + 
        badDebt_auction[0] + 
        badDebt_auction[1] + 
        badDebt_regular[0] + 
        badDebt_regular[1];

        assertApproxEqAbs(
            borrowableCUSDC.marketOutstandingDebt(),
            totalBorrowsBefore - totalDebtRepaid,
            100, // Small tolerance
            "Incorrect totalBorrows after liquidation"
        );

        // Verify liquidator received the expected collateral
        uint256 expectedDappControlUserLiquidatorBalance = 
        (collateralLiquidated_auction[0]) + 
        (collateralLiquidated_auction[1]);

        uint256 expectedNormalUserLiquidatorBalance = 
        (collateralLiquidated_regular[0]) + 
        (collateralLiquidated_regular[1]);

        console2.log("expectedDappControlUserLiquidatorBalance", expectedDappControlUserLiquidatorBalance);
        console2.log("collateralLiquidated_auction[0]", collateralLiquidated_auction[0]);
        console2.log("collateralLiquidated_auction[1]", collateralLiquidated_auction[1]);
        console2.log("collateralLiquidated_regular[0]", collateralLiquidated_regular[0]);
        console2.log("collateralLiquidated_regular[1]", collateralLiquidated_regular[1]);

        assertApproxEqAbs(
            strategyCBALRETH.balanceOf(dappControlUser),
            expectedDappControlUserLiquidatorBalance,
            1000,
            "Dapp control user didn't receive expected collateral"
        );

        assertApproxEqAbs(
            strategyCBALRETH.balanceOf(address(this)),
            expectedNormalUserLiquidatorBalance,
            1000,
            "Liquidator didn't receive expected collateral"
        );

        // Verify lFactors
        // Auction borrowers should still have lFactor > 0
        // Regular borrowers should have lFactor since fully liquidated

        for(uint i = 0; i < 2; i++) {
            (uint256 lFactorAfter,,) = marketManagerIsolated.liquidationStatusOf(
                auctionBorrowers[i],
                address(borrowableCUSDC),
                address(strategyCBALRETH)
            );

            assertGt(lFactorAfter, 0, "Auction borrower should still have lFactor > 0");
        }

        for(uint i = 0; i < 2; i++) {
            (uint256 lFactorAfter,,) = marketManagerIsolated.liquidationStatusOf(
                regularBorrowers[i],
                address(borrowableCUSDC),
                address(strategyCBALRETH)
            );

            assertEq(lFactorAfter, 0, "Regular borrower should have lFactor = 0");
        }

    }


    function _createPositions() internal {
        _prepareBALRETH(borrower1, collateralAmounts[0]);
        _prepareBALRETH(borrower2, collateralAmounts[1]);
        _prepareBALRETH(borrower3, collateralAmounts[2]);
        _prepareBALRETH(borrower4, collateralAmounts[3]);

        vm.startPrank(borrower1);
        balRETH.approve(address(strategyCBALRETH), collateralAmounts[0]);
        strategyCBALRETH.depositAsCollateral(collateralAmounts[0], borrower1);
        borrowableCUSDC.borrow(borrowAmount, borrower1);
        vm.stopPrank();

        vm.startPrank(borrower2);
        balRETH.approve(address(strategyCBALRETH), collateralAmounts[1]);
        strategyCBALRETH.depositAsCollateral(collateralAmounts[1], borrower2);
        borrowableCUSDC.borrow(borrowAmount, borrower2);
        vm.stopPrank();

        vm.startPrank(borrower3);
        balRETH.approve(address(strategyCBALRETH), collateralAmounts[2]);
        strategyCBALRETH.depositAsCollateral(collateralAmounts[2], borrower3);
        borrowableCUSDC.borrow(borrowAmount, borrower3);
        vm.stopPrank();

        vm.startPrank(borrower4);
        balRETH.approve(address(strategyCBALRETH), collateralAmounts[3]);
        strategyCBALRETH.depositAsCollateral(collateralAmounts[3], borrower4);
        borrowableCUSDC.borrow(borrowAmount, borrower4);
        vm.stopPrank();

    }

    function _getLFactorsPreLiquidation(address[] memory borrowers) internal view returns (uint256[] memory lFactors) {
        lFactors = new uint256[](2);

        for(uint i; i < borrowers.length; i++) {
            (lFactors[i],,) = marketManagerIsolated.liquidationStatusOf(
                borrowers[i],
                address(borrowableCUSDC),
                address(strategyCBALRETH)
            );
        }

        return lFactors;
    }

    function _getDebtBalancePreLiquidation(address[] memory borrowers) internal view returns (uint256[] memory debtBalances) {
        debtBalances = new uint256[](borrowers.length);
        for(uint i; i < borrowers.length; i++) {
            debtBalances[i] = borrowableCUSDC.debtBalance(borrowers[i]);
        }
        return debtBalances;
    }

    function _getLiquidationValuesWithHigherPrecision_NonAuction(
        uint256 _debtTokenPrice,
        uint256 _collateralTokenPrice,
        uint256[] memory lFactors
    ) internal view returns (
        uint256[] memory maxAmount, 
        uint256[] memory collateralLiquidated,
        uint256[] memory collateralRequired
    ) {
        uint256 cTokenExchangeRate = strategyCBALRETH.exchangeRate();
        
        // Keep original values but use higher precision for calculations
        uint256 PRECISION_FACTOR = 1e18; // Extra precision factor
        
        maxAmount = new uint256[](lFactors.length);
        collateralLiquidated = new uint256[](lFactors.length);
        collateralRequired = new uint256[](lFactors.length);

        for (uint i; i < lFactors.length; i++) {
            if (lFactors[i] == 0) continue;
            
            // Follow the contract's exact calculations but with higher precision
            uint256 auctionCFactor = baseCFactor + ((cFactorCurve * lFactors[i]) / WAD);
            uint256 auctionLiqIncentive = liqBaseIncentive + ((liqCurve * lFactors[i]) / WAD);
            
            // Calculate with extra precision
            uint256 highPrecisionD2C = (((auctionLiqIncentive * _debtTokenPrice * WAD * PRECISION_FACTOR) /
                (_collateralTokenPrice * cTokenExchangeRate)) * 1e18) / 1e6;
                
            maxAmount[i] = (auctionCFactor * borrowAmount) / WAD;
            
            // Calculate with extra precision
            collateralLiquidated[i] = (maxAmount[i] * highPrecisionD2C) / (WAD * PRECISION_FACTOR);
            
            if (collateralLiquidated[i] > collateralAmounts[i]) {
                // Use the contract's exact formula
                maxAmount[i] = FixedPointMathLib.mulDivUp(
                    maxAmount[i],
                    collateralAmounts[i],
                    collateralLiquidated[i]
                );
                collateralLiquidated[i] = collateralAmounts[i];
            }
            
            // Use the contract's exact formula
            collateralRequired[i] = (borrowAmount * highPrecisionD2C) / (WAD * PRECISION_FACTOR);
        }

        return (maxAmount, collateralLiquidated, collateralRequired);
    }

    function _getLiquidationValuesWithHigherPrecision_Auction(
        uint256 _debtTokenPrice,
        uint256 _collateralTokenPrice,
        uint256[] memory lFactors,
        uint256 auctionCFactor,
        uint256 auctionLiqIncentive
    ) internal view returns (
        uint256[] memory maxAmount, 
        uint256[] memory collateralLiquidated,
        uint256[] memory collateralRequired
    ) {
        uint256 cTokenExchangeRate = strategyCBALRETH.exchangeRate();
        
        // Keep original values but use higher precision for calculations
        uint256 PRECISION_FACTOR = 1e18; // Extra precision factor
        
        maxAmount = new uint256[](lFactors.length);
        collateralLiquidated = new uint256[](lFactors.length);
        collateralRequired = new uint256[](lFactors.length);

        for (uint i; i < lFactors.length; i++) {
            if (lFactors[i] == 0) continue;
            
            // Calculate with extra precision
            uint256 highPrecisionD2C = (((auctionLiqIncentive * _debtTokenPrice * WAD * PRECISION_FACTOR) /
                (_collateralTokenPrice * cTokenExchangeRate)) * 1e18) / 1e6;
                
            maxAmount[i] = (auctionCFactor * borrowAmount) / WAD;
            
            // Calculate with extra precision
            collateralLiquidated[i] = (maxAmount[i] * highPrecisionD2C) / (WAD * PRECISION_FACTOR);
            
            if (collateralLiquidated[i] > collateralAmounts[i]) {
                // Use the contract's exact formula
                maxAmount[i] = FixedPointMathLib.mulDivUp(
                    maxAmount[i],
                    collateralAmounts[i],
                    collateralLiquidated[i]
                );
                collateralLiquidated[i] = collateralAmounts[i];
            }
            
            // Use the contract's exact formula
            collateralRequired[i] = (borrowAmount * highPrecisionD2C) / (WAD * PRECISION_FACTOR);
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