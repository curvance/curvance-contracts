// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarketManagerIsolated } from "tests/market/isolatedMarketManager/TestBaseMarketManagerIsolated.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { IEToken } from "contracts/interfaces/IEToken.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { WAD } from "contracts/libraries/Constants.sol";

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

        // Simulate price drop
        mockWethFeed.setMockAnswer(1520e8);
        mockRethFeed.setMockAnswer(1520e8);
    }

    function test_noneLiquidated() public {
        _prepareUSDC(address(this), 100000e6);

        // Cache original debt balances for verification
        uint256[] memory debtBalancesPreLiquidation = _getDebtBalancePreLiquidation();
        uint256 totalBorrowsBefore = eUSDC.totalBorrows();

        // Attempt to liquidate
        eUSDC.approve(address(marketManagerIsolated), 100000e6);

        vm.expectRevert(abi.encodeWithSelector(MarketManagerIsolated.MarketManager__NoLiquidationAvailable.selector));
        eUSDC.liquidate(
            borrowers,
            address(pBALRETH)
        );

        // Verify all healthy accounts are not liquidated
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
            (lFactors[i],,) = marketManagerIsolated.liquidationStatusOf(
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
}