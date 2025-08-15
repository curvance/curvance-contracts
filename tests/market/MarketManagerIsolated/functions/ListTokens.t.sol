// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract ListTokensTest is TestBaseMarketIsolated {

    function setUp() public override {
        super.setUp();
    }

    function test_listTokens_fail_whenUnauthorized() public {
        // Prepare tokens for initializeDeposit().
        _prepareUSDC(address(this), 77777);
        _prepareBALRETH(address(this), 77777);

        // Approve token transfers for initializeDeposit().
        balRETH.approve(address(strategyCBALRETH), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);
        
        vm.startPrank(user2);
        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));
    }

    function test_listTokens_fail_whenTokensNotApprovedForInitializeDeposits() public {
        _prepareUSDC(address(this), 77777);
        _prepareBALRETH(address(this), 77777);

        balRETH.approve(address(strategyCBALRETH), 0);
        usdc.approve(address(borrowableCUSDC), 0);

        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));
    }

    function test_listTokens_fail_whenMissingTokensForInitializeDeposits() public {
        uint256 balanceofBALRETH = balRETH.balanceOf(address(this));
        if (balanceofBALRETH > 0) {
            SafeTransferLib.safeTransfer(address(balRETH), user2, balanceofBALRETH);
        }

        uint256 balanceofUSDC = usdc.balanceOf(address(this));
        if (balanceofUSDC > 0) {
            SafeTransferLib.safeTransfer(address(usdc), user2, balanceofUSDC);
        }

        balRETH.approve(address(strategyCBALRETH), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));
    }

    function test_listTokens_fail_whenIdenticalTokens() public {
        _prepareUSDC(address(this), 77777);
        _prepareBALRETH(address(this), 77777);

        balRETH.approve(address(strategyCBALRETH), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);
        
        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(strategyCBALRETH));
    }

    function test_listTokens_fail_whenBothNotBorrowable() public {
        _prepareBALRETH(address(this), 77777);
        _prepareBALRETH(address(this), 77777);

        balRETH.approve(address(strategyCBALRETH), 77777);
        balRETH.approve(address(strategyCBALRETHWithExitFee), 77777);
        
        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(strategyCBALRETHWithExitFee));
    }

    function test_listTokens_fail_whenTryingToRelist() public {
        // Prepare tokens for initializeDeposit().
        _prepareUSDC(address(this), 77777);
        _prepareBALRETH(address(this), 77777);

        // Approve token transfers for initializeDeposit().
        balRETH.approve(address(strategyCBALRETH), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);
        
        // Validate that the tokens are not listed.
        assertFalse(marketManagerIsolated.isListed(address(strategyCBALRETH)));
        assertFalse(marketManagerIsolated.isListed(address(borrowableCUSDC)));

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));
        
        // Validate the tokens are now listed.
        assertTrue(
            marketManagerIsolated.isListed(address(strategyCBALRETH)));
        assertTrue(
            marketManagerIsolated.isListed(address(borrowableCUSDC)));

        address [] memory tokens = marketManagerIsolated.queryTokensListed();
        assertEq(tokens.length, 2);
        assertEq(tokens[0], address(strategyCBALRETH));
        assertEq(tokens[1], address(borrowableCUSDC));

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));
    }

    function test_listTokens_success() public {
        // Prepare tokens for initializeDeposit().
        _prepareUSDC(address(this), 77777);
        _prepareBALRETH(address(this), 77777);

        // Approve token transfers for initializeDeposit().
        balRETH.approve(address(strategyCBALRETH), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);
        
        // Validate that the tokens are not listed.
        assertFalse(marketManagerIsolated.isListed(address(strategyCBALRETH)));
        assertFalse(marketManagerIsolated.isListed(address(borrowableCUSDC)));

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));
        
        // Validate the tokens are now listed.
        assertTrue(
            marketManagerIsolated.isListed(address(strategyCBALRETH)));
        assertTrue(
            marketManagerIsolated.isListed(address(borrowableCUSDC)));

        address [] memory tokens = marketManagerIsolated.queryTokensListed();
        assertEq(tokens.length, 2);
        assertEq(tokens[0], address(strategyCBALRETH));
        assertEq(tokens[1], address(borrowableCUSDC));
    }
}

