// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { console2 } from "forge-std/console2.sol";

contract TestBaseLiquidations is TestBaseMarketIsolated {

    function setUp() public virtual override {
        super.setUp();

        _prepareUSDC(address(this), _ONE);
        _prepareDAI(address(this), _ONE);
        deal(address(LP_wstETH_24Dec2025), address(this), _ONE);

        SafeTransferLib.safeApprove(_USDC_ADDRESS, address(borrowableCUSDC), _ONE);
        SafeTransferLib.safeApprove(_DAI_ADDRESS, address(borrowableCDAI), _ONE);
        SafeTransferLib.safeApprove(address(LP_wstETH_24Dec2025), address(pendleStrategyCTokenSTETH), _ONE);
    }

    function _prepareLiquidation() internal {

        // use mock pricing for testing
        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        _prepareUSDC(user1, _ONE);
        _prepareUSDC(address(this), _ONE);

        deal(address(LP_wstETH_24Dec2025), user1, _ONE + 77777);
        _prepareUSDC(address(this), _ONE); // possibly not needed

        vm.prank(user1);
        usdc.approve(address(borrowableCUSDC), _ONE);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE + 77777);

        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(pendleStrategyCTokenSTETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);

        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 200000e6);
        deal(address(LP_wstETH_24Dec2025), liquidityProvider, 10e18);
        // Mint borrowable cUSDC.
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 200000e6);
        borrowableCUSDC.deposit(200000e6, liquidityProvider);
        // Mint pendleStrategyCTokenSTETH.
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 10e18);
        pendleStrategyCTokenSTETH.deposit(10e18, liquidityProvider);
        vm.stopPrank();

        deal(address(LP_wstETH_24Dec2025), user1, _ONE);

        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE);
        pendleStrategyCTokenSTETH.deposit(_ONE, user1);
        pendleStrategyCTokenSTETH.postCollateral(_ONE - 1);

        borrowableCUSDC.borrow(3000e6, user1);
        vm.stopPrank();

        // skip 20 min hold period in harvestPendleLP
        _harvestPendleLP(1 weeks);

        mockUsdcFeed.setMockAnswer(3e8);
        // Refresh all mock feeds to ensure they're not stale after time advance
        _refreshMockFeeds();

        _prepareUSDC(user2, 1000e6);
    }
}
