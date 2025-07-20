// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { TestBaseMarketManagerIsolated } from "tests/market/isolatedMarketManager/TestBaseMarketManagerIsolated.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";

// 3 liquidations, all are auctions, 2 are soft liquidated, 1 is hard liquidated
// also harvest positions before liquidation

contract AuctionVaryingHealthTest is TestBaseMarketManagerIsolated {

    address borrower1 = makeAddr("borrower1");
    address borrower2 = makeAddr("borrower2");
    address borrower3 = makeAddr("borrower3");

    address dappControlUser = makeAddr("dappControlUser");

    function setUp() public override {
        super.setUp();

        // set up positions
        _setUpMarketPreLiquidation();
        _setUpBorrowerCollateral();
        // _setUpBorrowerDebt();
        _harvestAuraStrategyRewards();
        
    }

    function testNothing() public {
        
    }

    function _setUpMarketPreLiquidation() internal {
        // Setup market with tokens
        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(strategyCBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777 + 1_000_000e6);
        usdc.approve(address(borrowableCUSDC), 77777 + 1_000_000e6);

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);

        // Create a dapp control user
        vm.startPrank(centralRegistry.daoAddress());
        centralRegistry.addAuctionPermissions(dappControlUser);
        vm.stopPrank();

        // provide liquidity to the market
        borrowableCUSDC.deposit(1_000_000e6, address(this));
    }

    function _setUpBorrowerCollateral() internal {

        _prepareBALRETH(borrower1, 1e18);
        _prepareBALRETH(borrower2, 1e18);
        _prepareBALRETH(borrower3, 1e18);

        // deposit collateral
        
        vm.startPrank(borrower1);
        balRETH.approve(address(strategyCBALRETH), 1e18);
        strategyCBALRETH.depositAsCollateral(1e18, borrower1);
        vm.stopPrank();

        vm.startPrank(borrower2);
        balRETH.approve(address(strategyCBALRETH), 1e18);
        strategyCBALRETH.depositAsCollateral(1e18, borrower2);
        vm.stopPrank();

        vm.startPrank(borrower3);
        balRETH.approve(address(strategyCBALRETH), 1e18);
        strategyCBALRETH.depositAsCollateral(1e18, borrower3);
        vm.stopPrank();
    }

    function _setUpBorrowerDebt() internal {
        // high ltv, trigger hard liquidation
        vm.startPrank(borrower1);
        borrowableCUSDC.borrow(1600e8, borrower1);
        vm.stopPrank();

        // medium ltv, trigger soft liquidation
        vm.startPrank(borrower2);
        borrowableCUSDC.borrow(0, borrower2);
        vm.stopPrank();

        // slightly lower than medium ltv, trigger soft liquidation
        vm.startPrank(borrower3);
        borrowableCUSDC.borrow(0, borrower3);
        vm.stopPrank();
    }

}