// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { TestBaseLiquidations } from "tests/market/liquidations/TestBaseLiquidations.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";

// ## Scenario 3: No Users Liquidated, all using liquidate() function
// - Setup: 3 users with healthy positions
// - User 1: 1.5 strategyCBALRETH ($2,400), 1,000 USDC debt
// - User 2: 1.4 strategyCBALRETH ($2,240), 1,000 USDC debt
// - User 3: 1.3 strategyCBALRETH ($2,080), 1,000 USDC debt
// - Action: Price drop of strategyCBALRETH by 5% (to $1,520)
// - Expected: No liquidations occur
    
contract NoneLiquidated is TestBaseLiquidations {

    address borrower1 = makeAddr("borrower1");
    address borrower2 = makeAddr("borrower2");
    address borrower3 = makeAddr("borrower3");

    uint256 borrowAmount = 1000e6;
    address[] borrowers = [borrower1, borrower2, borrower3];
    uint256[] collateralAmounts = [1.5e18, 1.4e18, 1.3e18];

    function setUp() public override {
        super.setUp();

        mockUsdcFeed = new MockDataFeed(_CHAINLINK_USDC_USD);
        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            true,
            address(mockUsdcFeed),
            0
        );
        dualChainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            true,
            address(mockUsdcFeed),
            0
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

        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);
        _setCTokenConfigLowValues(address(borrowableCUSDC), 100_000e18, 100_000e6);

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

        // Simulate price drop
        mockWethFeed.setMockAnswer(1520e8);
        mockRethFeed.setMockAnswer(1520e8);
    }

    function test_noneLiquidated() public {
        _prepareUSDC(address(this), 100000e6);

        // Cache original debt balances for verification
        uint256[] memory debtBalancesPreLiquidation = _getDebtBalancePreLiquidation();
        uint256 totalBorrowsBefore = borrowableCUSDC.marketOutstandingDebt();

        // Attempt to liquidate
        borrowableCUSDC.approve(address(marketManagerIsolated), 100000e6);

        vm.expectRevert(abi.encodeWithSelector(MarketManagerIsolated.MarketManager__NoLiquidationAvailable.selector));
        borrowableCUSDC.liquidate(
            borrowers,
            address(strategyCBALRETH)
        );

        // Verify all healthy accounts are not liquidated
        assertEq(borrowableCUSDC.debtBalance(borrowers[0]), debtBalancesPreLiquidation[0], "Healthy account 1 shouldn't be liquidated");
        assertEq(borrowableCUSDC.debtBalance(borrowers[1]), debtBalancesPreLiquidation[1], "Healthy account 2 shouldn't be liquidated");
        assertEq(borrowableCUSDC.debtBalance(borrowers[2]), debtBalancesPreLiquidation[2], "Healthy account 3 shouldn't be liquidated");

        // Verify all users have the same collateral
        assertEq(strategyCBALRETH.balanceOf(borrowers[0]), collateralAmounts[0], "Healthy account 1 should have the same collateral");
        assertEq(strategyCBALRETH.balanceOf(borrowers[1]), collateralAmounts[1], "Healthy account 2 should have the same collateral");
        assertEq(strategyCBALRETH.balanceOf(borrowers[2]), collateralAmounts[2], "Healthy account 3 should have the same collateral");
    
        // Verify the same amount of borrows is still owed
        assertEq(borrowableCUSDC.marketOutstandingDebt(), totalBorrowsBefore, "Total borrows should be the same");

        // Verify liquidator received no collateral
        assertEq(strategyCBALRETH.balanceOf(address(this)), 0, "Liquidator should have received no collateral");
    }

    function _createPositions() internal {
        _prepareBALRETH(borrower1, collateralAmounts[0]);
        _prepareBALRETH(borrower2, collateralAmounts[1]);
        _prepareBALRETH(borrower3, collateralAmounts[2]);

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
    }

    function _getDebtBalancePreLiquidation() internal view returns (uint256[] memory debtBalances) {
        debtBalances = new uint256[](3);
        for(uint i; i < 3; i++) {
            debtBalances[i] = borrowableCUSDC.debtBalance(borrowers[i]);
        }
        return debtBalances;
    }
}