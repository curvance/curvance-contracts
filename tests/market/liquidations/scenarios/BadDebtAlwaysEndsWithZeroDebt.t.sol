// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { console2 } from "forge-std/console2.sol";

contract BadDebtAlwaysEndsWithZeroDebtTest is TestBaseMarketIsolated {

    function setUp() public override {
        super.setUp();

        // set up dai/usdc market
        _prepareDAI(address(this), 77777);
        _prepareUSDC(address(this), 77777);

        usdc.approve(address(borrowableCUSDC), 77777);
        dai.approve(address(borrowableCDAI), 77777);

        marketManagerIsolated.listTokens(address(borrowableCDAI), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 100_000e18);
        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e6, 100_000e6);

        // provide liquidity
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 50_000e6);
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 50_000e6);
        borrowableCUSDC.deposit(50_000e6, liquidityProvider);
        vm.stopPrank();

        mockUsdcFeed.setMockAnswer(1e8);
        mockDaiFeed.setMockAnswer(1e8);

        // set up borrow position
        _prepareDAI(user1, 10_000e18);
        vm.startPrank(user1);
        dai.approve(address(borrowableCDAI), 10_000e18);
        borrowableCDAI.depositAsCollateral(10_000e18, user1);

        borrowableCUSDC.borrow(7000e6, user1);
        vm.stopPrank();

    }

    function test_badDebtAlwaysEndsWithZeroDebt(int256 daiPrice, uint256 accrualTime) public {

        daiPrice = int256(bound(daiPrice, 1, 0.5e8));
        accrualTime = bound(accrualTime, 20 minutes, 1 weeks);

        console2.log("daiPrice", daiPrice);
        console2.log("accrualTime", accrualTime);

        mockDaiFeed.setMockAnswer(daiPrice);

        skip(accrualTime);
        _refreshMockFeeds();

        address[] memory accounts = new address[](1);
        accounts[0] = user1;

        vm.startPrank(user2);
        _prepareUSDC(user2, 10_000e6);
        usdc.approve(address(borrowableCUSDC), 10_000e6);

        borrowableCUSDC.liquidate(
            accounts,
            address(borrowableCDAI)
        );

        vm.stopPrank();

        assertEq(borrowableCDAI.balanceOf(user1), 0, "user1 should have all collateral seized");
        assertEq(borrowableCUSDC.debtBalance(user1), 0, "user1 should have debt cleared");
    }

}