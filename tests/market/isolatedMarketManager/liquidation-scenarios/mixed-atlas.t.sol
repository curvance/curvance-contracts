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

// ## Scenario 4: Mixed Atlas and Regular Liquidations
// - Setup: 4 users with varying positions
// - User 1: 1.9 pBALRETH ($2,850), 2500 USDC debt (for Atlas)
// - User 2: 1.9 pBALRETH ($2,850), 2500 USDC debt (for Atlas)
// - User 3: 1.9 pBALRETH ($2,850), 2500 USDC debt (for regular)
// - User 4: 1.9 pBALRETH ($2,850), 2500 USDC debt (for regular)
// - Action 1: Price drop by to ~$1,300, Atlas transaction with custom parameters for User 1 and User 2
// - Action 2: Regular liquidation attempt for User 3 and User 4
// - Expected: Users 1 and 2 liquidated via Atlas with custom parameters, Users 3 and 4 via regular liquidation
//          All users have the same underwater position, so each accrue bad debt at the moment.
//          Users who are liquidated via Atlas accrue less bad debt because their positions are not completely closed
//                  because they use a lower close factor than using liquiding the maximum amount.
//          Users who are liquidated without Atlas are fully liquidated and accrue the full bad debt amount.

// TODO: Use different loan/collateral ratios for each user. Currently each have the same collateral amount and loan.


contract MixedAtlas is TestBaseMarketManagerIsolated {

    address borrower1 = makeAddr("borrower1");
    address borrower2 = makeAddr("borrower2");
    address borrower3 = makeAddr("borrower3");
    address borrower4 = makeAddr("borrower4");

    uint256 borrowAmount = 2500e6;
    address[] atlasBorrowers = [borrower1, borrower2];
    address[] regularBorrowers = [borrower3, borrower4];
    uint256[] collateralAmounts = [1.9e18, 1.9e18, 1.9e18, 1.9e18];

    uint256 WAD_SQUARED = 1e36;

    uint256 liqBaseIncentive;
    uint256 liqCurve;
    uint256 baseCFactor;
    uint256 cFactorCurve;

    address dappControlUser = makeAddr("dappControlUser");

    // Atlas parameters
    uint256 validPenalty = 1.04e18;
    uint256 closeFactor = 0.50e18;

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

    uint256[] debtBalancesPreLiquidation_atlas;
    uint256[] debtBalancesPreLiquidation_regular;
    uint256[] lFactorsPreLiquidation_atlas;
    uint256[] lFactorsPreLiquidation_regular;
    uint256 eTokenPrice;
    uint256 pTokenPrice;
    uint256[] maxAmount_atlas;
    uint256[] liquidatedPTokens_atlas;
    uint256[] collateralRequired_atlas;
    uint256[] maxAmount_regular;
    uint256[] liquidatedPTokens_regular;
    uint256[] collateralRequired_regular;
    uint256[] badDebt_atlas = new uint256[](2);
    uint256[] badDebt_regular = new uint256[](2);
    uint256 totalBorrowsBefore;
    uint256 totalDebtRepaid;

    function test_mixedAtlas() public {

        _prepareUSDC(dappControlUser, 100000e6);
        _prepareUSDC(address(this), 100000e6);

        // ===== Cache liquidation values =====

        uint256 pTokenExchangeRate = pBALRETH.exchangeRateCached();

        totalBorrowsBefore = eUSDC.totalBorrows();

        debtBalancesPreLiquidation_atlas = _getDebtBalancePreLiquidation(atlasBorrowers);
        debtBalancesPreLiquidation_regular = _getDebtBalancePreLiquidation(regularBorrowers);

        lFactorsPreLiquidation_atlas = _getLFactorsPreLiquidation(atlasBorrowers);
        lFactorsPreLiquidation_regular = _getLFactorsPreLiquidation(regularBorrowers);

        (,eTokenPrice, pTokenPrice) = 
            marketManagerIsolated.liquidationStatusOf(atlasBorrowers[0], address(eUSDC), address(pBALRETH));

        (maxAmount_atlas, liquidatedPTokens_atlas, collateralRequired_atlas) = 
            _getLiquidationValuesWithHigherPrecision_Atlas(
                eTokenPrice, pTokenPrice, lFactorsPreLiquidation_atlas, closeFactor, validPenalty
            );

        (maxAmount_regular, liquidatedPTokens_regular, collateralRequired_regular) = 
            _getLiquidationValuesWithHigherPrecision_NonAtlas(
                eTokenPrice, pTokenPrice, lFactorsPreLiquidation_regular
            );

        console2.log("CHECKPOINT 1");

        for(uint i; i < 2; i++) {
            badDebt_atlas[i] = _calculateBadDebt(
                debtBalancesPreLiquidation_atlas[i],
                maxAmount_atlas[i],
                collateralAmounts[i],
                collateralRequired_atlas[i],
                liquidatedPTokens_atlas[i],
                pTokenPrice,
                eTokenPrice,
                pTokenExchangeRate
            );
            console2.log("badDebt_atlas", badDebt_atlas[i]);
        }

        for(uint i; i < 2; i++) {
            badDebt_regular[i] = _calculateBadDebt(
                debtBalancesPreLiquidation_regular[i],
                maxAmount_regular[i],
                collateralAmounts[i],
                collateralRequired_regular[i],
                liquidatedPTokens_regular[i],
                pTokenPrice,
                eTokenPrice,
                pTokenExchangeRate
            );
            console2.log("badDebt_regular", badDebt_regular[i]);
        }

            // ===== Liquidate =====

        vm.startPrank(dappControlUser);
        usdc.approve(address(eUSDC), 100000e6);

        marketManagerIsolated.setAuctionParameters(validPenalty, closeFactor);
        marketManagerIsolated.unlockAuctionCollateral(address(eUSDC));
        eUSDC.liquidate(
            atlasBorrowers,
            address(pBALRETH)
        );
        marketManagerIsolated.lockAuctionCollateral();
        marketManagerIsolated.resetAuctionParameters();
        vm.stopPrank();

        usdc.approve(address(eUSDC), 100000e6);
        eUSDC.liquidate(
            regularBorrowers,
            address(pBALRETH)
        );

        // ===== Validate =====

        // Verify debt balances
        assertEq(eUSDC.debtBalanceCached(atlasBorrowers[0]), debtBalancesPreLiquidation_atlas[0] - (maxAmount_atlas[0] + badDebt_atlas[0]), "Atlas borrower 1 debt balance mismatch");
        assertEq(eUSDC.debtBalanceCached(atlasBorrowers[1]), debtBalancesPreLiquidation_atlas[1] - (maxAmount_atlas[1] + badDebt_atlas[1]), "Atlas borrower 2 debt balance mismatch");
        assertEq(eUSDC.debtBalanceCached(regularBorrowers[0]), debtBalancesPreLiquidation_regular[0] - (maxAmount_regular[0] + badDebt_regular[0]), "Regular borrower 1 debt balance mismatch");
        assertEq(eUSDC.debtBalanceCached(regularBorrowers[1]), debtBalancesPreLiquidation_regular[1] - (maxAmount_regular[1] + badDebt_regular[1]), "Regular borrower 2 debt balance mismatch");

        // Verify collateral is reduced by liquidatedPTokens
        assertApproxEqAbs(
            pBALRETH.balanceOf(atlasBorrowers[0]),
            collateralAmounts[0] - (liquidatedPTokens_atlas[0]),
            1000, // Tolerance of 1000 wei 
            "Collateral post liquidation mismatch"
        );

        assertApproxEqAbs(
            pBALRETH.balanceOf(atlasBorrowers[1]),
            collateralAmounts[1] - (liquidatedPTokens_atlas[1]),
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

        totalDebtRepaid = maxAmount_atlas[0] + 
        maxAmount_atlas[1] + 
        maxAmount_regular[0] + 
        maxAmount_regular[1] + 
        badDebt_atlas[0] + 
        badDebt_atlas[1] + 
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
        (liquidatedPTokens_atlas[0]) + 
        (liquidatedPTokens_atlas[1]);

        uint256 expectedNormalUserLiquidatorBalance = 
        (liquidatedPTokens_regular[0]) + 
        (liquidatedPTokens_regular[1]);

        console2.log("expectedDappControlUserLiquidatorBalance", expectedDappControlUserLiquidatorBalance);
        console2.log("liquidatedPTokens_atlas[0]", liquidatedPTokens_atlas[0]);
        console2.log("liquidatedPTokens_atlas[1]", liquidatedPTokens_atlas[1]);
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
        // Atlas borrowers should still have lFactor > 0
        // Regular borrowers should have lFactor since fully liquidated

        for(uint i = 0; i < 2; i++) {
            (uint256 lFactorAfter,,) = marketManagerIsolated.liquidationStatusOf(
                atlasBorrowers[i],
                address(eUSDC),
                address(pBALRETH)
            );

            assertGt(lFactorAfter, 0, "Atlas borrower should still have lFactor > 0");
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
        
        maxAmount = new uint256[](lFactors.length);
        liquidatedPTokens = new uint256[](lFactors.length);
        collateralRequired = new uint256[](lFactors.length);

        for (uint i; i < lFactors.length; i++) {
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

    function _getLiquidationValuesWithHigherPrecision_Atlas(
        uint256 eTokenPrice,
        uint256 pTokenPrice,
        uint256[] memory lFactors,
        uint256 auctionCFactor,
        uint256 auctionLiqIncentive
    ) internal view returns (
        uint256[] memory maxAmount, 
        uint256[] memory liquidatedPTokens,
        uint256[] memory collateralRequired
    ) {
        uint256 pTokenExchangeRate = pBALRETH.exchangeRateCached();
        
        // Keep original values but use higher precision for calculations
        uint256 PRECISION_FACTOR = 1e18; // Extra precision factor
        
        maxAmount = new uint256[](lFactors.length);
        liquidatedPTokens = new uint256[](lFactors.length);
        collateralRequired = new uint256[](lFactors.length);

        for (uint i; i < lFactors.length; i++) {
            if (lFactors[i] == 0) continue;
            
            // Calculate with extra precision
            uint256 highPrecisionD2C = (((auctionLiqIncentive * eTokenPrice * WAD * PRECISION_FACTOR) /
                (pTokenPrice * pTokenExchangeRate)) * 1e18) / 1e6;
                
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