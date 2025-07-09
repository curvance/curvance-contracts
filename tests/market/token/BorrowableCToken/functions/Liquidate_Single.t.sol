// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseBorrowableCToken } from "tests/market/token/BorrowableCToken/TestBaseBorrowableCToken.t.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { PriceReturnData } from "contracts/interfaces/IOracleAdaptor.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { WAD } from "contracts/libraries/Constants.sol";
import "forge-std/console2.sol";

// TODO: canLiquidate is no longer callable by anyone!

contract LiquidateSingleTest is TestBaseBorrowableCToken {

    uint256 borrowableCTokenUnderlyingPrice = 1e18;

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
        usdc.approve(address(borrowableCUSDC), 1000e6);

        IMarketManager.LiqInstructions memory instructions = IMarketManager.LiqInstructions({
            debtToken: address(borrowableCUSDC),
            collateralToken: address(strategyCBALRETH),
            numAccounts: 1,
            liquidateExact: false,
            debtRepaid: 0,
            collateralLiquidated: 0,
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
        borrowableCUSDC.liquidate(
            accounts,
            address(strategyCBALRETH)
        );
        vm.stopPrank();

        console2.log("borrowableCUSDC.debtBalance(user1)", borrowableCUSDC.debtBalance(user1));
        console2.log("borrowableCUSDC.exchangeRate()", borrowableCUSDC.exchangeRate());
        console2.log("Debt amount returned", debtAmountReturned[0]);
        console2.log("LiqResults.liquidatedAmounts[0]", results.liquidatedAmounts[0]);
        console2.log("LiqResults.debtRepaid", results.debtRepaid);
        console2.log("LiqResults.badDebtRealized", results.badDebtRealized);

        // Hard liquidation, should have lost all collateral
        assertEq(
            strategyCBALRETH.balanceOf(user1),
            1, "Borrower strategyCBALRETH balance mismatch"
        );

        assertEq(expectedRepayAmount, results.debtRepaid, "Debt repaid mismatch");

        assertEq(borrowableCUSDC.debtBalance(user1), 0, "eUSDC debt balance mismatch");
        assertEq(strategyCBALRETH.exchangeRate(), _ONE, "strategyCBALRETH exchange rate mismatch");
        assertLt(borrowableCUSDC.exchangeRate(), _ONE, "eUSDC exchange rate mismatch, there should be bad debt");
        assertEq(strategyCBALRETH.balanceOf(user2), _ONE - 1, "Liquidator strategyCBALRETH balance mismatch");
        assertEq(usdc.balanceOf(user2), 1000e6 - results.debtRepaid, "Liquidator USDC balance mismatch");
       
    }

    function _prepareLiquidationRethDrop() internal {
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 200000e6);
        _prepareBALRETH(liquidityProvider, 10e18);
        // mint eUSDC
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 200000e6);
        borrowableCUSDC.deposit(200000e6, liquidityProvider);
        // mint cBALETH
        balRETH.approve(address(strategyCBALRETH), 10e18);
        strategyCBALRETH.deposit(10e18, liquidityProvider);
        vm.stopPrank();

        _prepareBALRETH(user1, _ONE);

        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.deposit(_ONE, user1);
        strategyCBALRETH.postCollateral(_ONE - 1);

        borrowableCUSDC.borrow(1000e6);
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
        uint256 exchangeRate = strategyCBALRETH.exchangeRate();
        return (((auctionLiqIncentive * earnTokenPrice * WAD) / (positionTokenPrice * exchangeRate)) * 10 ** 18) / 10 ** 6;
    }

    // Helper function to calculate debtAmount with collateral adjustment
    function calculateDebtAmount(
        address user,
        uint256 maxAmount,
        uint256 debtToCollateralMultiplier
    ) internal view returns (uint256) {
        (, , uint256 collateralAvailable) = auxiliaryData.tokenDataOf(user, address(strategyCBALRETH));
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
            marketManagerIsolated.tokenData(address(strategyCBALRETH));
        
        (uint256 lFactor, uint256 earnTokenPrice, uint256 positionTokenPrice) = 
            marketManagerIsolated.liquidationStatusOf(user, address(borrowableCUSDC), address(strategyCBALRETH));

        uint256 auctionCFactor = baseCFactor + ((cFactorCurve * lFactor) / WAD);
        uint256 auctionLiqIncentive = liqBaseIncentive + ((liqCurve * lFactor) / WAD);
        
        // Calculate debt-to-collateral multiplier using helper function
        uint256 debtToCollateralMultiplier = calculateDebtToCollateralMultiplier(
            auctionLiqIncentive,
            earnTokenPrice,
            positionTokenPrice
        );
        
        uint256 maxAmount = (auctionCFactor * borrowableCUSDC.debtBalance(user)) / WAD;
        
        uint256 debtAmount = calculateDebtAmount(user, maxAmount, debtToCollateralMultiplier);
        
        return debtAmount;
    }


}