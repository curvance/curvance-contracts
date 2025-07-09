// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarketManagerIsolated } from "../TestBaseMarketManagerIsolated.sol";

contract ListTokens is TestBaseMarketManagerIsolated {

    function setUp() public override {
        super.setUp();
    }

    function testListTokens() public {
        // Setup market with tokens
        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(strategyCBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);
        
        // Check that the tokens are not listed
        assertFalse(marketManagerIsolated.isListed(address(strategyCBALRETH)));
        assertFalse(marketManagerIsolated.isListed(address(borrowableCUSDC)));
        
        // Call the function being tested
        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));
        
        // Assert the tokens are now listed
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

