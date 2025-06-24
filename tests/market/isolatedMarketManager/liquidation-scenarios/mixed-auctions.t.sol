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
// - User 1: 1.9 pBALRETH ($2,850), 2500 USDC debt (for Auction)
// - User 2: 1.9 pBALRETH ($2,850), 2500 USDC debt (for Auction)
// - User 3: 1.9 pBALRETH ($2,850), 2500 USDC debt (for regular)
// - User 4: 1.9 pBALRETH ($2,850), 2500 USDC debt (for regular)
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

        tokens[0] = address(eUSDC);
        caps[0] = 100_000e6;
        marketManagerIsolated.setDebtCaps(tokens, caps);

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

    uint256[] debtBalancesPreLiquidation_auction;
    uint256[] debtBalancesPreLiquidation_regular;
    uint256[] lFactorsPreLiquidation_auction;
    uint256[] lFactorsPreLiquidation_regular;
    uint256 eTokenPrice;
    uint256 cTokenPrice;
    uint256[] maxAmount_auction;
    uint256[] liquidatedPTokens_auction;
    uint256[] collateralRequired_auction;
    uint256[] maxAmount_regular;
    uint256[] liquidatedPTokens_regular;
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

        uint256 cTokenExchangeRate = pBALRETH.exchangeRate();

        totalBorrowsBefore = eUSDC.totalBorrows();

        debtBalancesPreLiquidation_auction = _getDebtBalancePreLiquidation(auctionBorrowers);
        debtBalancesPreLiquidation_regular = _getDebtBalancePreLiquidation(regularBorrowers);

        lFactorsPreLiquidation_auction = _getLFactorsPreLiquidation(auctionBorrowers);
        lFactorsPreLiquidation_regular = _getLFactorsPreLiquidation(regularBorrowers);

        (,eTokenPrice, cTokenPrice) = 
            marketManagerIsolated.liquidationStatusOf(auctionBorrowers[0], address(eUSDC), address(pBALRETH));

        (maxAmount_auction, liquidatedPTokens_auction, collateralRequired_auction) = 
            _getLiquidationValuesWithHigherPrecision_Auction(
                eTokenPrice, cTokenPrice, lFactorsPreLiquidation_auction, closeFactor, validPenalty
            );

        (maxAmount_regular, liquidatedPTokens_regular, collateralRequired_regular) = 
            _getLiquidationValuesWithHigherPrecision_NonAuction(
                eTokenPrice, cTokenPrice, lFactorsPreLiquidation_regular
            );

        console2.log("CHECKPOINT 1");

        for(uint i; i < 2; i++) {
            badDebt_auction[i] = _calculateBadDebt(
                debtBalancesPreLiquidation_auction[i],
                maxAmount_auction[i],
                collateralAmounts[i],
                collateralRequired_auction[i],
                liquidatedPTokens_auction[i],
                cTokenPrice,
                eTokenPrice,
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
                liquidatedPTokens_regular[i],
                cTokenPrice,
                eTokenPrice,
                cTokenExchangeRate
            );
            totalBadDebtRegular += badDebt_regular[i];
            console2.log("badDebt_regular", badDebt_regular[i]);
        }

            // ===== Liquidate =====

        vm.startPrank(dappControlUser);
        usdc.approve(address(eUSDC), 100000e6);

        marketManagerIsolated.setAuctionParameters(validPenalty, closeFactor);
        marketManagerIsolated.unlockAuctionCollateral(address(eUSDC));

        // Assert BadDebtRecognized event is emitted with expected total bad debt
        vm.expectEmit();
        emit BadDebtRecognized(dappControlUser, totalBadDebtAuction);
        emit Repay(dappControlUser, auctionBorrowers[0], maxAmount_auction[0] + badDebt_auction[0]);
        emit Repay(dappControlUser, auctionBorrowers[1], maxAmount_auction[1] + badDebt_auction[1]);

        eUSDC.liquidate(
            auctionBorrowers,
            address(pBALRETH)
        );
        marketManagerIsolated.lockAuctionCollateral();
        marketManagerIsolated.resetAuctionParameters();
        vm.stopPrank();

        usdc.approve(address(eUSDC), 100000e6);

        // Assert BadDebtRecognized event is emitted with expected total bad debt
        vm.expectEmit();
        emit BadDebtRecognized(address(this), totalBadDebtRegular);
        emit Repay(address(this), regularBorrowers[0], maxAmount_regular[0] + badDebt_regular[0]);
        emit Repay(address(this), regularBorrowers[1], maxAmount_regular[1] + badDebt_regular[1]);

        eUSDC.liquidate(
            regularBorrowers,
            address(pBALRETH)
        );

        // ===== Validate =====

        // Verify debt balances
        assertEq(eUSDC.debtBalanceCached(auctionBorrowers[0]), debtBalancesPreLiquidation_auction[0] - (maxAmount_auction[0] + badDebt_auction[0]), "Auction borrower 1 debt balance mismatch");
        assertEq(eUSDC.debtBalanceCached(auctionBorrowers[1]), debtBalancesPreLiquidation_auction[1] - (maxAmount_auction[1] + badDebt_auction[1]), "Auction borrower 2 debt balance mismatch");
        assertEq(eUSDC.debtBalanceCached(regularBorrowers[0]), debtBalancesPreLiquidation_regular[0] - (maxAmount_regular[0] + badDebt_regular[0]), "Regular borrower 1 debt balance mismatch");
        assertEq(eUSDC.debtBalanceCached(regularBorrowers[1]), debtBalancesPreLiquidation_regular[1] - (maxAmount_regular[1] + badDebt_regular[1]), "Regular borrower 2 debt balance mismatch");

        // Verify collateral is reduced by liquidatedPTokens
        assertApproxEqAbs(
            pBALRETH.balanceOf(auctionBorrowers[0]),
            collateralAmounts[0] - (liquidatedPTokens_auction[0]),
            1000, // Tolerance of 1000 wei 
            "Collateral post liquidation mismatch"
        );

        assertApproxEqAbs(
            pBALRETH.balanceOf(auctionBorrowers[1]),
            collateralAmounts[1] - (liquidatedPTokens_auction[1]),
            1000, // Tolerance of 1000 wei 
            "Collateral post liquidation mismatch"
        );

        assertApproxEqAbs(
            pBALRETH.balanceOf(regularBorrowers[0]),
            collateralAmounts[2] - (liquidatedPTokens_regular[0]),
            1000, // Tolerance of 1000 wei 
            "Collateral post liquidation mismatch"
        );

        assertApproxEqAbs(
            pBALRETH.balanceOf(regularBorrowers[1]),
            collateralAmounts[3] - (liquidatedPTokens_regular[1]),
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
            eUSDC.totalBorrows(),
            totalBorrowsBefore - totalDebtRepaid,
            100, // Small tolerance
            "Incorrect totalBorrows after liquidation"
        );

        // Verify liquidator received the expected collateral
        uint256 expectedDappControlUserLiquidatorBalance = 
        (liquidatedPTokens_auction[0]) + 
        (liquidatedPTokens_auction[1]);

        uint256 expectedNormalUserLiquidatorBalance = 
        (liquidatedPTokens_regular[0]) + 
        (liquidatedPTokens_regular[1]);

        console2.log("expectedDappControlUserLiquidatorBalance", expectedDappControlUserLiquidatorBalance);
        console2.log("liquidatedPTokens_auction[0]", liquidatedPTokens_auction[0]);
        console2.log("liquidatedPTokens_auction[1]", liquidatedPTokens_auction[1]);
        console2.log("liquidatedPTokens_regular[0]", liquidatedPTokens_regular[0]);
        console2.log("liquidatedPTokens_regular[1]", liquidatedPTokens_regular[1]);

        assertApproxEqAbs(
            pBALRETH.balanceOf(dappControlUser),
            expectedDappControlUserLiquidatorBalance,
            1000,
            "Dapp control user didn't receive expected collateral"
        );

        assertApproxEqAbs(
            pBALRETH.balanceOf(address(this)),
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
                address(eUSDC),
                address(pBALRETH)
            );

            assertGt(lFactorAfter, 0, "Auction borrower should still have lFactor > 0");
        }

        for(uint i = 0; i < 2; i++) {
            (uint256 lFactorAfter,,) = marketManagerIsolated.liquidationStatusOf(
                regularBorrowers[i],
                address(eUSDC),
                address(pBALRETH)
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

        vm.startPrank(borrower4);
        balRETH.approve(address(pBALRETH), collateralAmounts[3]);
        pBALRETH.depositAsCollateral(collateralAmounts[3], borrower4);
        eUSDC.borrow(borrowAmount);
        vm.stopPrank();

    }

    function _getLFactorsPreLiquidation(address[] memory borrowers) internal view returns (uint256[] memory lFactors) {
        lFactors = new uint256[](2);

        for(uint i; i < borrowers.length; i++) {
            (lFactors[i],,) = marketManagerIsolated.liquidationStatusOf(
                borrowers[i],
                address(eUSDC),
                address(pBALRETH)
            );
        }

        return lFactors;
    }

    function _getDebtBalancePreLiquidation(address[] memory borrowers) internal view returns (uint256[] memory debtBalances) {
        debtBalances = new uint256[](borrowers.length);
        for(uint i; i < borrowers.length; i++) {
            debtBalances[i] = eUSDC.debtBalanceCached(borrowers[i]);
        }
        return debtBalances;
    }

    function _getLiquidationValuesWithHigherPrecision_NonAuction(
        uint256 _eTokenPrice,
        uint256 _cTokenPrice,
        uint256[] memory lFactors
    ) internal view returns (
        uint256[] memory maxAmount, 
        uint256[] memory liquidatedPTokens,
        uint256[] memory collateralRequired
    ) {
        uint256 cTokenExchangeRate = pBALRETH.exchangeRate();
        
        // Keep original values but use higher precision for calculations
        uint256 PRECISION_FACTOR = 1e18; // Extra precision factor
        
        maxAmount = new uint256[](lFactors.length);
        liquidatedPTokens = new uint256[](lFactors.length);
        collateralRequired = new uint256[](lFactors.length);

        for (uint i; i < lFactors.length; i++) {
            if (lFactors[i] == 0) continue;
            
            // Follow the contract's exact calculations but with higher precision
            uint256 auctionCFactor = baseCFactor + ((cFactorCurve * lFactors[i]) / WAD);
            uint256 auctionLiqIncentive = liqBaseIncentive + ((liqCurve * lFactors[i]) / WAD);
            
            // Calculate with extra precision
            uint256 highPrecisionD2C = (((auctionLiqIncentive * _eTokenPrice * WAD * PRECISION_FACTOR) /
                (_cTokenPrice * cTokenExchangeRate)) * 1e18) / 1e6;
                
            maxAmount[i] = (auctionCFactor * borrowAmount) / WAD;
            
            // Calculate with extra precision
            liquidatedPTokens[i] = (maxAmount[i] * highPrecisionD2C) / (WAD * PRECISION_FACTOR);
            
            if (liquidatedPTokens[i] > collateralAmounts[i]) {
                // Use the contract's exact formula
                maxAmount[i] = FixedPointMathLib.mulDivUp(
                    maxAmount[i],
                    collateralAmounts[i],
                    liquidatedPTokens[i]
                );
                liquidatedPTokens[i] = collateralAmounts[i];
            }
            
            // Use the contract's exact formula
            collateralRequired[i] = (borrowAmount * highPrecisionD2C) / (WAD * PRECISION_FACTOR);
        }

        return (maxAmount, liquidatedPTokens, collateralRequired);
    }

    function _getLiquidationValuesWithHigherPrecision_Auction(
        uint256 _eTokenPrice,
        uint256 _cTokenPrice,
        uint256[] memory lFactors,
        uint256 auctionCFactor,
        uint256 auctionLiqIncentive
    ) internal view returns (
        uint256[] memory maxAmount, 
        uint256[] memory liquidatedPTokens,
        uint256[] memory collateralRequired
    ) {
        uint256 cTokenExchangeRate = pBALRETH.exchangeRate();
        
        // Keep original values but use higher precision for calculations
        uint256 PRECISION_FACTOR = 1e18; // Extra precision factor
        
        maxAmount = new uint256[](lFactors.length);
        liquidatedPTokens = new uint256[](lFactors.length);
        collateralRequired = new uint256[](lFactors.length);

        for (uint i; i < lFactors.length; i++) {
            if (lFactors[i] == 0) continue;
            
            // Calculate with extra precision
            uint256 highPrecisionD2C = (((auctionLiqIncentive * _eTokenPrice * WAD * PRECISION_FACTOR) /
                (_cTokenPrice * cTokenExchangeRate)) * 1e18) / 1e6;
                
            maxAmount[i] = (auctionCFactor * borrowAmount) / WAD;
            
            // Calculate with extra precision
            liquidatedPTokens[i] = (maxAmount[i] * highPrecisionD2C) / (WAD * PRECISION_FACTOR);
            
            if (liquidatedPTokens[i] > collateralAmounts[i]) {
                // Use the contract's exact formula
                maxAmount[i] = FixedPointMathLib.mulDivUp(
                    maxAmount[i],
                    collateralAmounts[i],
                    liquidatedPTokens[i]
                );
                liquidatedPTokens[i] = collateralAmounts[i];
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