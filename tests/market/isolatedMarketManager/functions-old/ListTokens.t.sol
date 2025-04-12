// // SPDX-License-Identifier: UNLICENSED
// pragma solidity ^0.8.26;

// import { TestBaseMarketManager } from "tests/market/marketManager/TestBaseMarketManager.sol";

// contract ListTokens is TestBaseMarketManager {

//     function setUp() public override {
//         super.setUp();
//     }

//     function testListTokens() public {
//         // Setup market with tokens
//         deal(address(balRETH), address(this), 42069);
//         balRETH.approve(address(pBALRETHIsolated), 42069);

//         deal(address(_USDC_ADDRESS), address(this), 42069);
//         usdc.approve(address(eUSDCIsolated), 42069);
        
//         // Check that the tokens are not listed
//         assertFalse(marketManagerIsolated.isListed(address(pBALRETHIsolated)));
//         assertFalse(marketManagerIsolated.isListed(address(eUSDCIsolated)));
        
//         // Call the function being tested
//         marketManagerIsolated.listTokens(address(pBALRETHIsolated), address(eUSDCIsolated));
        
//         // Assert the tokens are now listed
//         assertTrue(
//             marketManagerIsolated.isListed(address(pBALRETHIsolated)));
//         assertTrue(
//             marketManagerIsolated.isListed(address(eUSDCIsolated)));

//         address [] memory tokens = marketManagerIsolated.queryTokensListed();
//         assertEq(tokens.length, 2);
//         assertEq(tokens[0], address(pBALRETHIsolated));
//         assertEq(tokens[1], address(eUSDCIsolated));

//     }
// }

