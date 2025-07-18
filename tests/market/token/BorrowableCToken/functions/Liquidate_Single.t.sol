// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseBorrowableCToken } from "tests/market/token/BorrowableCToken/TestBaseBorrowableCToken.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { PriceReturnData } from "contracts/interfaces/IOracleAdaptor.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { WAD } from "contracts/libraries/Constants.sol";
import "forge-std/console2.sol";

// NOTE: Test also uses canLiquidate for extra accounting checks

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
            liquidatedShares: 0,
            debtRepaid: 0,
            badDebt: 0
        });

        (IMarketManager.LiqResults memory results, uint256[] memory debtAmountReturned) = marketManagerIsolated.canLiquidate(
            debtAmounts,
            user2,
            accounts,
            instructions
        );

        ExpectedLiquidationValues memory expectedLiquidationValues = _calculateExpectedLiquidationValues(
            LiquidationParams({
                borrower: user1,
                collateralToken: address(strategyCBALRETH),
                borrowedToken: address(borrowableCUSDC),
                isLiquidateExact: false,
                liquidateExactAmount: 0,
                isAuction: false,
                isMultiMarketTest: false,
                marketManagerId: 0
            })
        );

        // Hard liquidation, should have lost all collateral
        assertEq(results.liquidatedShares[0], _ONE - 1, "Liquidated amount mismatch");
        borrowableCUSDC.liquidate(
            accounts,
            address(strategyCBALRETH)
        );
        vm.stopPrank();

        // Hard liquidation, should have lost all collateral
        assertEq(
            strategyCBALRETH.balanceOf(user1),
            1, "Borrower strategyCBALRETH balance mismatch"
        );

        assertEq(expectedLiquidationValues.debtRepaid, results.debtRepaid, "Debt repaid mismatch");

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
        // Mint borrowable cUSDC.
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 200000e6);
        borrowableCUSDC.deposit(200000e6, liquidityProvider);
        // Mint cBALETH.
        balRETH.approve(address(strategyCBALRETH), 10e18);
        strategyCBALRETH.deposit(10e18, liquidityProvider);
        vm.stopPrank();

        _prepareBALRETH(user1, _ONE);

        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.deposit(_ONE, user1);
        strategyCBALRETH.postCollateral(_ONE - 1);

        borrowableCUSDC.borrow(1000e6, user1);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);

        mockWethFeed.setMockAnswer(1000e8);
        mockRethFeed.setMockAnswer(1000e8);

        _prepareUSDC(user2, 250e6);
    }


}