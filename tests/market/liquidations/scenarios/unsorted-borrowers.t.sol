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

        _setCTokenConfigHighValues(address(strategyCBALRETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 100_000e6);

        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 200000e6);
        // Mint borrowable cUSDC.
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 200000e6);
        borrowableCUSDC.deposit(200000e6, liquidityProvider);
        vm.stopPrank();

        _createPositions();

        mockBalEthRethFeed.setMockAnswer(1100e8);
        
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
        borrowableCUSDC.liquidate(borrowers, address(strategyCBALRETH));
        
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

        borrowableCUSDC.liquidate(borrowers, address(strategyCBALRETH));
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
        borrowableCUSDC.borrow(1100e6, borrower1);
        vm.stopPrank();

        vm.startPrank(borrower2);
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.depositAsCollateral(_ONE, borrower2);
        borrowableCUSDC.borrow(1100e6, borrower2);
        vm.stopPrank();

        vm.startPrank(borrower3);
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.depositAsCollateral(_ONE, borrower3);
        borrowableCUSDC.borrow(1100e6, borrower3);
        vm.stopPrank();

        vm.startPrank(borrower4);
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.depositAsCollateral(_ONE, borrower4);
        borrowableCUSDC.borrow(1100e6, borrower4);
        vm.stopPrank();

        vm.startPrank(borrower5);
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.depositAsCollateral(_ONE, borrower5);
        borrowableCUSDC.borrow(1100e6, borrower5);
        vm.stopPrank();
    }

}