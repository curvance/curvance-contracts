// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract ListTokensTest is TestBaseMarketIsolated {

     event Deposit(address indexed by, address indexed owner, uint256 assets, uint256 shares);

    function setUp() public override {
        super.setUp();
    }

    function test_listTokens_fail_whenUnauthorized() public {
        // Prepare tokens for initializeDeposit().
        _prepareUSDC(address(this), 77777);
        deal(address(LP_wstETH_24Dec2025), address(this), 77777);

        // Approve token transfers for initializeDeposit().
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);
        
        vm.startPrank(user2);
        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(borrowableCUSDC));
    }

    function test_listTokens_fail_whenTokensNotApprovedForInitializeDeposits() public {
        _prepareUSDC(address(this), 77777);
        deal(address(LP_wstETH_24Dec2025), address(this), 77777);

        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 0);
        usdc.approve(address(borrowableCUSDC), 0);

        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(borrowableCUSDC));
    }

    function test_listTokens_fail_whenMissingTokensForInitializeDeposits() public {
        uint256 balanceofLP_wstETH_24Dec2025 = LP_wstETH_24Dec2025.balanceOf(address(this));
        if (balanceofLP_wstETH_24Dec2025 > 0) {
            SafeTransferLib.safeTransfer(address(LP_wstETH_24Dec2025), user2, balanceofLP_wstETH_24Dec2025);
        }

        uint256 balanceofUSDC = usdc.balanceOf(address(this));
        if (balanceofUSDC > 0) {
            SafeTransferLib.safeTransfer(address(usdc), user2, balanceofUSDC);
        }

        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(borrowableCUSDC));
    }

    function test_listTokens_fail_whenIdenticalTokens() public {
        _prepareUSDC(address(this), 77777);
        deal(address(LP_wstETH_24Dec2025), address(this), 77777);

        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);
        
        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(pendleStrategyCTokenSTETH));
    }

    function test_listTokens_fail_whenBothNotBorrowable() public {
        deal(address(LP_wstETH_24Dec2025), address(this), 77777);
        _prepareBALRETH(address(this), 77777);

        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 77777);
        balRETH.approve(address(strategyCBALRETHWithExitFee), 77777);
        
        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(strategyCBALRETHWithExitFee));
    }

    function test_listTokens_fail_whenTryingToRelist() public {
        // Prepare tokens for initializeDeposit().
        _prepareUSDC(address(this), 77777);
        deal(address(LP_wstETH_24Dec2025), address(this), 77777);

        // Approve token transfers for initializeDeposit().
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);
        
        // Validate that the tokens are not listed.
        assertFalse(marketManagerIsolated.isListed(address(pendleStrategyCTokenSTETH)));
        assertFalse(marketManagerIsolated.isListed(address(borrowableCUSDC)));

        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(borrowableCUSDC));
        
        // Validate the tokens are now listed.
        assertTrue(
            marketManagerIsolated.isListed(address(pendleStrategyCTokenSTETH)));
        assertTrue(
            marketManagerIsolated.isListed(address(borrowableCUSDC)));

        address [] memory tokens = marketManagerIsolated.queryTokensListed();
        assertEq(tokens.length, 2);
        assertEq(tokens[0], address(pendleStrategyCTokenSTETH));
        assertEq(tokens[1], address(borrowableCUSDC));

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(borrowableCUSDC));
    }

    function test_listTokens_success() public {
        // Prepare tokens for initializeDeposit().
        _prepareUSDC(address(this), 77777);
        deal(address(LP_wstETH_24Dec2025), address(this), 77777);

        // Approve token transfers for initializeDeposit().
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);
        
        // Validate that the tokens are not listed.
        assertFalse(marketManagerIsolated.isListed(address(pendleStrategyCTokenSTETH)));
        assertFalse(marketManagerIsolated.isListed(address(borrowableCUSDC)));

        // Expect Deposit is emitted from each cToken during _initializeDeposits().
        vm.expectEmit(true, true, false, true, address(pendleStrategyCTokenSTETH));
        emit Deposit(address(this), address(0), 77777, 77777);
        
        vm.expectEmit(true, true, false, true, address(borrowableCUSDC));
        emit Deposit(address(this), address(0), 77777, 77777);

        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(borrowableCUSDC));
        
        // Validate the tokens are now listed.
        assertTrue(
            marketManagerIsolated.isListed(address(pendleStrategyCTokenSTETH)));
        assertTrue(
            marketManagerIsolated.isListed(address(borrowableCUSDC)));

        address [] memory tokens = marketManagerIsolated.queryTokensListed();
        assertEq(tokens.length, 2);
        assertEq(tokens[0], address(pendleStrategyCTokenSTETH));
        assertEq(tokens[1], address(borrowableCUSDC));
    }
}

