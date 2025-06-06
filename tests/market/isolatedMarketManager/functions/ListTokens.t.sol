// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarketManagerIsolated } from "../TestBaseMarketManagerIsolated.sol";

contract ListTokens is TestBaseMarketManagerIsolated {

    function setUp() public override {
        super.setUp();
    }

    function testListTokens() public {
        // Setup market with tokens
        deal(address(balRETH), address(this), 42069);
        balRETH.approve(address(pBALRETH), 42069);

        deal(address(_USDC_ADDRESS), address(this), 42069);
        usdc.approve(address(eUSDC), 42069);
        
        // Check that the tokens are not listed
        assertFalse(marketManagerIsolated.isListed(address(pBALRETH)));
        assertFalse(marketManagerIsolated.isListed(address(eUSDC)));
        
        // Call the function being tested
        marketManagerIsolated.listTokens(address(pBALRETH), address(eUSDC));
        
        // Assert the tokens are now listed
        assertTrue(
            marketManagerIsolated.isListed(address(pBALRETH)));
        assertTrue(
            marketManagerIsolated.isListed(address(eUSDC)));

        address [] memory tokens = marketManagerIsolated.queryTokensListed();
        assertEq(tokens.length, 2);
        assertEq(tokens[0], address(pBALRETH));
        assertEq(tokens[1], address(eUSDC));

    }
}

