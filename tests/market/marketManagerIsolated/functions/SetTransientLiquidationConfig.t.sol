// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { console2 } from "forge-std/console2.sol";

contract SetTransientLiquidationConfigTest is TestBaseMarketIsolated {

    function setUp() public override {
        super.setUp();

        deal(address(LP_wstETH_24Dec2025), address(this), 77777);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);
        
        // List tokens in the market.
        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(borrowableCUSDC));

        _setCTokenConfigCollateralOff(address(pendleStrategyCTokenSTETH), 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);
    }

    function test_setTransientLiquidationConfig_fail_whenUnauthorized() public {
        _setCTokenConfigBasic(address(pendleStrategyCTokenSTETH), 100_000e18, 0);

        // // Non-dapp control user should not be able to set penalty
        vm.startPrank(user1);
        
        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.setTransientLiquidationConfig(address(pendleStrategyCTokenSTETH), 1.15e18, 0.30e18);
        
        vm.stopPrank();
    }

    function test_setTransientLiquidationConfig_fail_whenTokenNotListed() public {
        _setCTokenConfigBasic(address(pendleStrategyCTokenSTETH), 100_000e18, 0);

        vm.startPrank(auctionPermsUser);

        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector); 
        marketManagerIsolated.setTransientLiquidationConfig(user1, 1.15e18, 0.30e18);
        vm.stopPrank();
    }

    function test_setTransientLiquidationConfig_fail_whenCollateralizationOff() public {
        vm.startPrank(auctionPermsUser);

        vm.expectRevert(MarketManagerIsolated.MarketManager__UnauthorizedLiquidation.selector); 
        marketManagerIsolated.setTransientLiquidationConfig(address(pendleStrategyCTokenSTETH), 1.15e18, 0.30e18);
        vm.stopPrank();
    }

    function test_setTransientLiquidationConfig_fail_whenInvalidValues() public {
        _setCTokenConfigBasic(address(pendleStrategyCTokenSTETH), 100_000e18, 0);

        uint256 tooLowPenalty = 1.0001e18;
        uint256 tooHighPenalty = 1.25e18; 
        uint256 validPenalty = 1.15e18;
        uint256 tooHighCloseFactor = 1.51e18;
        uint256 tooLowCloseFactor = 1.09e18;
        uint256 validCloseFactor = 0.30e18;

        vm.startPrank(auctionPermsUser);
        
        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector); 
        marketManagerIsolated.setTransientLiquidationConfig(address(pendleStrategyCTokenSTETH), tooLowPenalty, validCloseFactor);

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector); 
        marketManagerIsolated.setTransientLiquidationConfig(address(pendleStrategyCTokenSTETH), tooHighPenalty, validCloseFactor);

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector); 
        marketManagerIsolated.setTransientLiquidationConfig(address(pendleStrategyCTokenSTETH), validPenalty, tooHighCloseFactor);

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector); 
        marketManagerIsolated.setTransientLiquidationConfig(address(pendleStrategyCTokenSTETH), validPenalty, tooLowCloseFactor);

        vm.stopPrank();
    }

    function test_setTransientLiquidationConfig_success() public {
        _setCTokenConfigBasic(address(pendleStrategyCTokenSTETH), 100_000e18, 0);
        _setAuctionConfigs(address(pendleStrategyCTokenSTETH), 11500, 3000);

        vm.startPrank(auctionPermsUser);

        // Verify all values were set correctly including address (bit packing check)
        (address storedToken, uint256 currentPenalty, uint256 currentCloseFactor) = marketManagerIsolated.getTransientLiquidationConfig();
        assertEq(storedToken, address(pendleStrategyCTokenSTETH), "Token address must round-trip correctly");
        assertEq(currentPenalty, 11500);
        assertEq(currentCloseFactor, 3000);
        vm.stopPrank();
    }

    function test_setTransientLiquidationConfig_success_withBothZeroValues() public {
        _setCTokenConfigBasic(address(pendleStrategyCTokenSTETH), 100_000e18, 0);
        _setAuctionConfigs(address(pendleStrategyCTokenSTETH), 0, 0);

        vm.startPrank(auctionPermsUser);

        // Verify both values are zero (signaling protocol-derived) and address is correct
        (address storedToken, uint256 currentPenalty, uint256 currentCloseFactor) = marketManagerIsolated.getTransientLiquidationConfig();
        assertEq(storedToken, address(pendleStrategyCTokenSTETH), "Token address must round-trip correctly");
        assertEq(currentPenalty, 0, "Incentive should be 0 to signal protocol-derived");
        assertEq(currentCloseFactor, 0, "Close factor should be 0 to signal protocol-derived");
        vm.stopPrank();
    }

    function test_setTransientLiquidationConfig_success_withZeroIncentiveNonZeroCloseFactor() public {
        _setCTokenConfigBasic(address(pendleStrategyCTokenSTETH), 100_000e18, 0);
        // closeFactorMin = 2000, closeFactorMax = 5000 from _setCTokenConfigBasic
        _setAuctionConfigs(address(pendleStrategyCTokenSTETH), 0, 3000);

        vm.startPrank(auctionPermsUser);

        // Verify incentive is zero (protocol-derived), close factor is custom, and address is correct
        (address storedToken, uint256 currentPenalty, uint256 currentCloseFactor) = marketManagerIsolated.getTransientLiquidationConfig();
        assertEq(storedToken, address(pendleStrategyCTokenSTETH), "Token address must round-trip correctly");
        assertEq(currentPenalty, 0, "Incentive should be 0 to signal protocol-derived");
        assertEq(currentCloseFactor, 3000, "Close factor should be custom value");
        vm.stopPrank();
    }

    function test_setTransientLiquidationConfig_success_withNonZeroIncentiveZeroCloseFactor() public {
        _setCTokenConfigBasic(address(pendleStrategyCTokenSTETH), 100_000e18, 0);
        // liqIncMin = 10, liqIncMax = 2000 from _setCTokenConfigBasic
        // Use 10500 (105%) which is above liqIncMin + BPS = 10010
        _setAuctionConfigs(address(pendleStrategyCTokenSTETH), 10500, 0);

        vm.startPrank(auctionPermsUser);

        // Verify incentive is custom, close factor is zero (protocol-derived), and address is correct
        (address storedToken, uint256 currentPenalty, uint256 currentCloseFactor) = marketManagerIsolated.getTransientLiquidationConfig();
        assertEq(storedToken, address(pendleStrategyCTokenSTETH), "Token address must round-trip correctly");
        assertEq(currentPenalty, 10500, "Incentive should be custom value");
        assertEq(currentCloseFactor, 0, "Close factor should be 0 to signal protocol-derived");
        vm.stopPrank();
    }

    function test_setTransientLiquidationConfig_success_multipleCallsCustomIncentive() public {
        _setCTokenConfigBasic(address(pendleStrategyCTokenSTETH), 100_000e18, 0);

        vm.startPrank(auctionPermsUser);

        // First call: Set to 10500, 0
        marketManagerIsolated.setTransientLiquidationConfig(address(pendleStrategyCTokenSTETH), 10500, 0);

        // Verify first call
        (address stored1, uint256 incentive1, uint256 closeFactor1) = marketManagerIsolated.getTransientLiquidationConfig();
        assertEq(stored1, address(pendleStrategyCTokenSTETH), "First call: token address must be correct");
        assertEq(incentive1, 10500, "First call: incentive should be 10500");
        assertEq(closeFactor1, 0, "First call: close factor should be 0");

        // Second call: Overwrite with 11000, 0 (different custom incentive)
        marketManagerIsolated.setTransientLiquidationConfig(address(pendleStrategyCTokenSTETH), 11000, 0);

        // Verify second call overwrote first
        (address stored2, uint256 incentive2, uint256 closeFactor2) = marketManagerIsolated.getTransientLiquidationConfig();
        assertEq(stored2, address(pendleStrategyCTokenSTETH), "Second call: token address must be correct");
        assertEq(incentive2, 11000, "Second call: incentive should be 11000 (overwrote 10500)");
        assertEq(closeFactor2, 0, "Second call: close factor should be 0");

        // Third call: Overwrite with 10800, 0 (another different custom incentive)
        marketManagerIsolated.setTransientLiquidationConfig(address(pendleStrategyCTokenSTETH), 10800, 0);

        // Verify third call is final state
        (address stored3, uint256 incentive3, uint256 closeFactor3) = marketManagerIsolated.getTransientLiquidationConfig();
        assertEq(stored3, address(pendleStrategyCTokenSTETH), "Third call: token address must be correct");
        assertEq(incentive3, 10800, "Third call: incentive should be 10800 (final value)");
        assertEq(closeFactor3, 0, "Third call: close factor should be 0");

        vm.stopPrank();
    }

    function test_setTransientLiquidationConfig_success_multipleCallsBothZero() public {
        _setCTokenConfigBasic(address(pendleStrategyCTokenSTETH), 100_000e18, 0);

        vm.startPrank(auctionPermsUser);

        // First call: Set to 0, 0
        marketManagerIsolated.setTransientLiquidationConfig(address(pendleStrategyCTokenSTETH), 0, 0);

        // Verify first call
        (address stored1, uint256 incentive1, uint256 closeFactor1) = marketManagerIsolated.getTransientLiquidationConfig();
        assertEq(stored1, address(pendleStrategyCTokenSTETH), "First call: token address must be correct");
        assertEq(incentive1, 0, "First call: incentive should be 0");
        assertEq(closeFactor1, 0, "First call: close factor should be 0");

        // Second call: Overwrite with 0, 0 (same values, tests idempotency)
        marketManagerIsolated.setTransientLiquidationConfig(address(pendleStrategyCTokenSTETH), 0, 0);

        // Verify second call maintains values
        (address stored2, uint256 incentive2, uint256 closeFactor2) = marketManagerIsolated.getTransientLiquidationConfig();
        assertEq(stored2, address(pendleStrategyCTokenSTETH), "Second call: token address must be correct");
        assertEq(incentive2, 0, "Second call: incentive should be 0");
        assertEq(closeFactor2, 0, "Second call: close factor should be 0");

        // Third call: Overwrite with 0, 0 again
        marketManagerIsolated.setTransientLiquidationConfig(address(pendleStrategyCTokenSTETH), 0, 0);

        // Verify third call is final state
        (address stored3, uint256 incentive3, uint256 closeFactor3) = marketManagerIsolated.getTransientLiquidationConfig();
        assertEq(stored3, address(pendleStrategyCTokenSTETH), "Third call: token address must be correct");
        assertEq(incentive3, 0, "Third call: incentive should be 0 (final value)");
        assertEq(closeFactor3, 0, "Third call: close factor should be 0");

        vm.stopPrank();
    }

}