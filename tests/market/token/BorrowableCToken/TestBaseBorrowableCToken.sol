// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract TestBaseBorrowableCToken is TestBaseMarketIsolated {

    function setUp() public virtual override {
        super.setUp();

        _prepareUSDC(address(this), _ONE + 77777);
        deal(address(LP_wstETH_24Dec2025), address(this), 10e18 + 77777);
        
        usdc.approve(address(borrowableCUSDC), _ONE + 77777);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 10e18 + 77777);

        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(pendleStrategyCTokenSTETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 100_000e6);

        pendleStrategyCTokenSTETH.mint(_ONE, address(this));
    }

    function _prepareLiquidation() internal {
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 200000e6);
        deal(address(LP_wstETH_24Dec2025), liquidityProvider, 10e18);
        
        // Mint borrowable cUSDC.
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 200000e6);
        borrowableCUSDC.deposit(200000e6, liquidityProvider);
        // Mint cBALETH.
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 10e18);
        pendleStrategyCTokenSTETH.deposit(10e18, liquidityProvider);
        vm.stopPrank();

        deal(address(LP_wstETH_24Dec2025), user1, _ONE);

        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE);
        pendleStrategyCTokenSTETH.deposit(_ONE, user1);
        pendleStrategyCTokenSTETH.postCollateral(_ONE - 1);

        borrowableCUSDC.borrow(5000e6, user1);
        vm.stopPrank();

        // skip 20 min hold period in harvestAuraStrategyRewards
        _harvestPendleLP(1 weeks);

        mockUsdcFeed.setMockAnswer(2e8);
        mockUsdcFeed.setMockUpdatedAt(block.timestamp);

        _prepareUSDC(user2, 250e6);
    }

}
