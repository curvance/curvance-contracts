// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract CollateralCapsFuzzed is TestBaseMarketIsolated {
    function setUp() override public {
        super.setUp();

        _prepareDAI(address(this), 77777);
        _prepareUSDC(address(this), 77777);

        dai.approve(address(borrowableCDAI), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));
    }

    function test_fuzz_CollateralCaps(uint256 collateralCap, uint256 depositAmount) public {

        collateralCap = bound(collateralCap, 1e18, 1_000_000e18);
        depositAmount = bound(depositAmount, collateralCap / 1000 + 1, collateralCap);

        _setCTokenConfigBasic(address(borrowableCDAI), collateralCap, 1_000_000e18);
        _setCTokenConfigBasic(address(borrowableCUSDC), 1_000_000e6, 1_000_000e6);

        vm.startPrank(user1);

        do {
            _prepareDAI(user1, depositAmount);
            dai.approve(address(borrowableCDAI), depositAmount);
            borrowableCDAI.depositAsCollateral(depositAmount, user1); 
        } while (borrowableCDAI.marketCollateralPosted() + depositAmount <= marketManagerIsolated.collateralCaps(address(borrowableCDAI)));

        _prepareDAI(user1, depositAmount);
        dai.approve(address(borrowableCDAI), depositAmount);
        
        vm.expectRevert(MarketManagerIsolated.MarketManager__CapReached.selector);
        borrowableCDAI.depositAsCollateral(depositAmount, user1);

        vm.stopPrank();

    }
}