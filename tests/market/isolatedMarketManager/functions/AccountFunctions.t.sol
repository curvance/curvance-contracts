// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { TestBaseMarketManagerIsolated } from "tests/market/isolatedMarketManager/TestBaseMarketManagerIsolated.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { IMToken } from "contracts/interfaces/IMToken.sol";

contract AccountFunctionsIsolatedMarketManager is TestBaseMarketManagerIsolated {
    address dappControlUser = makeAddr("dappControlUser");


    function setUp() public override {
        super.setUp();
        
        // // Setup market with tokens
        // deal(address(balRETH), address(this), 42069);
        // balRETH.approve(address(pBALRETH), 42069);

        // deal(address(_USDC_ADDRESS), address(this), 42069);
        // usdc.approve(address(eUSDC), 42069);
        
        // // List tokens in the market
        // marketManager.listTokens(address(pBALRETH), address(eUSDC));
        
        // // Set position token parameters
        // marketManager.updatePositionToken(
        //     7000,    // collRatio 70%
        //     4000,    // collReqSoft 40%
        //     3000,    // collReqHard 25%
        //     1000,    // liqIncBase 10%
        //     1500,    // liqIncHard 15%
        //     500,     // liqIncMin 5%
        //     2000,    // liqIncMax 20%
        //     2000,    // minEffectiveCFactor 20%
        //     5000,    // maxEffectiveCFactor 50%
        //     2000     // baseCFactor 20%
        // );

        // // Create a dapp control user
        // dappControlUser = makeAddr("dappControlUser");
        // vm.startPrank(centralRegistry.daoAddress());
        // centralRegistry.addAuthorizedAtlasDAppControl(dappControlUser);
        // vm.stopPrank();

        // address[] memory tokens = new address[](1);
        // tokens[0] = address(pBALRETH);
        // uint256[] memory caps = new uint256[](1);
        // caps[0] = 100_000e18;
        // marketManager.setCollateralCaps(tokens, caps);

        _prepareLiquidation();

    }

    function test_assetsOf() public {
        IMToken[] memory assets = marketManager.assetsOf(user1);
        assertEq(assets.length, 2);
        assertEq(address(assets[0]), address(pBALRETH));
        assertEq(address(assets[1]), address(eUSDC));
    }

    function test_tokenDataOf() public {

        (bool hasPosition, uint256 balanceOf, uint256 collateralPostedOf) = marketManager.tokenDataOf(user1, address(pBALRETH));
        assertEq(hasPosition, true);
        assertEq(balanceOf, _ONE, "balance of mismatch");
        assertEq(collateralPostedOf, _ONE - 1, "collateral posted mismatch");

    }

    function test_statusOf() public {

        mockUsdcFeed.setMockAnswer(1e8); // reset price back to $1

        (uint256 accountCollateral, uint256 maxDebt, uint256 accountDebt) = marketManager.statusOf(user1);

        uint256 expectedMaxDebt = 7000 * accountCollateral / 10000; // 70% LTV

        assertEq(maxDebt, expectedMaxDebt,"max debt mismatch");

        assertEq(accountDebt, 1e21, "account debt mismatch");

    }

}