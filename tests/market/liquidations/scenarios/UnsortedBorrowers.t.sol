// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { TestBaseLiquidations } from "tests/market/liquidations/TestBaseLiquidations.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { console2 } from "forge-std/console2.sol";
    

contract TestUnsortedBorrowersLiquidationTest is TestBaseLiquidations {

    address borrower1 = address(0x0000000000000000000000000000000000000001);
    address borrower2 = address(0x0000000000000000000000000000000000000002);
    address borrower3 = address(0x0000000000000000000000000000000000000003);
    address borrower4 = address(0x0000000000000000000000000000000000000004);
    address borrower5 = address(0x0000000000000000000000000000000000000005);

    function setUp() public override {
        super.setUp();

        // use mock pricing for testing
        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        _prepareUSDC(user1, _ONE);
        _prepareUSDC(address(this), _ONE);

        deal(address(LP_wstETH_24Dec2025), user1, _ONE + 77777);

        vm.prank(user1);
        usdc.approve(address(borrowableCUSDC), _ONE);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE + 77777);

        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(borrowableCUSDC));

        _setCTokenConfigHighValues(address(pendleStrategyCTokenSTETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 100_000e6);

        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 200000e6);
        // Mint borrowable cUSDC.
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 200000e6);
        borrowableCUSDC.deposit(200000e6, liquidityProvider);
        vm.stopPrank();

        _createPositions();

        _setPendleStEthLpPrice(1100e8);
    }

    function test_fail_whenUnsortedBorrowers() public {

        _prepareUSDC(address(this), 100000e6);
        usdc.approve(address(borrowableCUSDC), 100000e6);

        address[] memory borrowers = new address[](5);
        borrowers[0] = borrower5;
        borrowers[1] = borrower4;
        borrowers[2] = borrower3;
        borrowers[3] = borrower2;
        borrowers[4] = borrower1;

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        borrowableCUSDC.liquidate(borrowers, address(pendleStrategyCTokenSTETH));
        
    }

    function test_success_whenSortedBorrowers() public {
        _prepareUSDC(address(this), 100000e6);
        usdc.approve(address(borrowableCUSDC), 100000e6);

        address[] memory borrowers = new address[](5);
        borrowers[0] = borrower1;
        borrowers[1] = borrower2;
        borrowers[2] = borrower3;
        borrowers[3] = borrower4;
        borrowers[4] = borrower5;

        borrowableCUSDC.liquidate(borrowers, address(pendleStrategyCTokenSTETH));
    }

    function _createPositions() internal {
        deal(address(LP_wstETH_24Dec2025), borrower1, _ONE);
        deal(address(LP_wstETH_24Dec2025), borrower2, _ONE);
        deal(address(LP_wstETH_24Dec2025), borrower3, _ONE);
        deal(address(LP_wstETH_24Dec2025), borrower4, _ONE);
        deal(address(LP_wstETH_24Dec2025), borrower5, _ONE);

        vm.startPrank(borrower1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE);
        pendleStrategyCTokenSTETH.depositAsCollateral(_ONE, borrower1);
        borrowableCUSDC.borrow(1100e6, borrower1);
        vm.stopPrank();

        vm.startPrank(borrower2);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE);
        pendleStrategyCTokenSTETH.depositAsCollateral(_ONE, borrower2);
        borrowableCUSDC.borrow(1100e6, borrower2);
        vm.stopPrank();

        vm.startPrank(borrower3);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE);
        pendleStrategyCTokenSTETH.depositAsCollateral(_ONE, borrower3);
        borrowableCUSDC.borrow(1100e6, borrower3);
        vm.stopPrank();

        vm.startPrank(borrower4);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE);
        pendleStrategyCTokenSTETH.depositAsCollateral(_ONE, borrower4);
        borrowableCUSDC.borrow(1100e6, borrower4);
        vm.stopPrank();

        vm.startPrank(borrower5);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE);
        pendleStrategyCTokenSTETH.depositAsCollateral(_ONE, borrower5);
        borrowableCUSDC.borrow(1100e6, borrower5);
        vm.stopPrank();
    }

}