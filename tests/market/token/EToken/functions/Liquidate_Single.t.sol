// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseETokenIsolated } from "tests/market/token/EToken/TestBaseETokenIsolated.t.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { PriceReturnData } from "contracts/interfaces/IOracleAdaptor.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { WAD } from "contracts/libraries/Constants.sol";
import "forge-std/console2.sol";

// TODO: canLiquidate is no longer callable by anyone!

contract LiquidateSingleTest is TestBaseETokenIsolated {

    uint256 eTokenUnderlyingPrice = 1e18;

    function setUp() public override {
        super.setUp();

        _prepareLiquidationRethDrop();
    }

    // Test a single liquidation
    function test_liquidate_single_success() public {
        address[] memory accounts = new address[](1);
        accounts[0] = user1;

        uint256[] memory debtAmounts = new uint256[](1);
        debtAmounts[0] = 0;
        
        _prepareUSDC(user2, 1000e6);
        vm.startPrank(user2);
        usdc.approve(address(eUSDC), 1000e6);

        IMarketManager.LiqInstructions memory instructions = IMarketManager.LiqInstructions({
            eToken: address(eUSDC),
            cToken: address(pBALRETH),
            numAccounts: 1,
            liquidateExact: false,
            eTokenRepaid: 0,
            cTokenLiquidated: 0,
            badDebt: 0
        });

        (IMarketManager.LiqResults memory results, uint256[] memory debtAmountReturned) = marketManagerIsolated.canLiquidate(
            user2,
            accounts,
            debtAmounts,
            instructions
        );

        uint256 expectedRepayAmount = _calculateExpectedRepayAmountNotExact(user1);

        // Hard liquidation, should have lost all collateral
        assertEq(results.liquidatedAmounts[0], _ONE - 1, "Liquidated amount mismatch");
        eUSDC.liquidate(
            accounts,
            address(pBALRETH)
        );
        vm.stopPrank();

        console2.log("eUSDC.debtBalanceCached(user1)", eUSDC.debtBalanceCached(user1));
        console2.log("eUSDC.exchangeRateCached()", eUSDC.exchangeRateCached());
        console2.log("Debt amount returned", debtAmountReturned[0]);
        console2.log("LiqResults.liquidatedAmounts[0]", results.liquidatedAmounts[0]);
        console2.log("LiqResults.debtRepaid", results.debtRepaid);
        console2.log("LiqResults.badDebtRealized", results.badDebtRealized);

        // Hard liquidation, should have lost all collateral
        assertEq(
            pBALRETH.balanceOf(user1),
            1, "Borrower pBALRETH balance mismatch"
        );

        assertEq(expectedRepayAmount, results.debtRepaid, "Debt repaid mismatch");

        assertEq(eUSDC.debtBalanceCached(user1), 0, "eUSDC debt balance mismatch");
        assertEq(pBALRETH.exchangeRate(), _ONE, "pBALRETH exchange rate mismatch");
        assertLt(eUSDC.exchangeRateCached(), _ONE, "eUSDC exchange rate mismatch, there should be bad debt");
        assertEq(pBALRETH.balanceOf(user2), _ONE - 1, "Liquidator pBALRETH balance mismatch");
        assertEq(usdc.balanceOf(user2), 1000e6 - results.debtRepaid, "Liquidator USDC balance mismatch");
       
    }

    function _prepareLiquidationRethDrop() internal {
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

        _prepareBALRETH(user1, _ONE);

        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), _ONE);
        pBALRETH.deposit(_ONE, user1);
        pBALRETH.postCollateral(_ONE - 1);

        eUSDC.borrow(1000e6);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);

        mockWethFeed.setMockAnswer(1000e8);
        mockRethFeed.setMockAnswer(1000e8);

        _prepareUSDC(user2, 250e6);
    }

    // Helper function to calculate debtToCollateralMultiplier
    function calculateDebtToCollateralMultiplier(
        uint256 auctionLiqIncentive,
        uint256 earnTokenPrice,
        uint256 positionTokenPrice
    ) internal view returns (uint256) {
        uint256 exchangeRate = pBALRETH.exchangeRate();
        return (((auctionLiqIncentive * earnTokenPrice * WAD) / (positionTokenPrice * exchangeRate)) * 10 ** 18) / 10 ** 6;
    }

    // Helper function to calculate debtAmount with collateral adjustment
    function calculateDebtAmount(
        address user,
        uint256 maxAmount,
        uint256 debtToCollateralMultiplier
    ) internal view returns (uint256) {
        (, , uint256 collateralAvailable) = auxiliaryData.tokenDataOf(user, address(pBALRETH));
        uint256 debtAmount = maxAmount;
        uint256 liquidatedPTokens = (debtAmount * debtToCollateralMultiplier) / WAD;
        if (liquidatedPTokens > collateralAvailable) {
            debtAmount = FixedPointMathLib.mulDivUp(collateralAvailable, WAD, debtToCollateralMultiplier);
        }
        return debtAmount;
    }

    // Main function refactored to avoid stack too deep
    function _calculateExpectedRepayAmountNotExact(address user) internal view returns (uint256) {
        (,,,, uint256 liqBaseIncentive, uint256 liqCurve,,,,, uint256 baseCFactor, uint256 cFactorCurve) = 
            marketManagerIsolated.tokenData(address(pBALRETH));
        
        (uint256 lFactor, uint256 earnTokenPrice, uint256 positionTokenPrice) = 
            marketManagerIsolated.liquidationStatusOf(user, address(eUSDC), address(pBALRETH));

        uint256 auctionCFactor = baseCFactor + ((cFactorCurve * lFactor) / WAD);
        uint256 auctionLiqIncentive = liqBaseIncentive + ((liqCurve * lFactor) / WAD);
        
        // Calculate debt-to-collateral multiplier using helper function
        uint256 debtToCollateralMultiplier = calculateDebtToCollateralMultiplier(
            auctionLiqIncentive,
            earnTokenPrice,
            positionTokenPrice
        );
        
        uint256 maxAmount = (auctionCFactor * eUSDC.debtBalanceCached(user)) / WAD;
        
        uint256 debtAmount = calculateDebtAmount(user, maxAmount, debtToCollateralMultiplier);
        
        return debtAmount;
    }


}