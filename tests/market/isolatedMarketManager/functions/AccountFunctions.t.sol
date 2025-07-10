// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { TestBaseMarketManagerIsolated } from "tests/market/isolatedMarketManager/TestBaseMarketManagerIsolated.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";

contract AccountFunctionsIsolatedMarketManager is TestBaseMarketManagerIsolated {
    address dappControlUser = makeAddr("dappControlUser");


    function setUp() public override {
        super.setUp();
        
        // // Setup market with tokens
        // deal(address(balRETH), address(this), 77777);
        // balRETH.approve(address(simpleCBALRETH), 77777);

        // deal(address(_USDC_ADDRESS), address(this), 77777);
        // usdc.approve(address(borrowableCUSDC), 77777);
        
        // // List tokens in the market
        // marketManager.listTokens(address(simpleCBALRETH), address(borrowableCUSDC));
        
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
        // centralRegistry.addAuctionPermissions(dappControlUser);
        // vm.stopPrank();

        // address[] memory tokens = new address[](1);
        // tokens[0] = address(simpleCBALRETH);
        // uint256[] memory caps = new uint256[](1);
        // caps[0] = 100_000e18;
        // marketManager.setCollateralCaps(tokens, caps);

        _prepareLiquidation();

    }

    function test_assetsOf() public {
        address[] memory assets = marketManagerIsolated.assetsOf(user1);
        assertEq(assets.length, 2);
        assertEq(address(assets[0]), address(strategyCBALRETH));
        assertEq(address(assets[1]), address(borrowableCUSDC));
    }

    function test_tokenDataOf() public {

        (bool hasPosition, uint256 balanceOf, uint256 collateralPostedOf) = auxiliaryData.tokenDataOf(user1, address(strategyCBALRETH));
        assertEq(hasPosition, true);
        assertEq(balanceOf, _ONE, "balance of mismatch");
        assertEq(collateralPostedOf, _ONE - 1, "collateral posted mismatch");

    }

    function test_statusOf() public {

        mockUsdcFeed.setMockAnswer(1e8); // reset price back to $1

        (uint256 accountCollateral, uint256 maxDebt, uint256 accountDebt) = marketManagerIsolated.statusOf(user1);

        uint256 expectedMaxDebt = 7000 * accountCollateral / 10000; // 70% LTV

        assertEq(maxDebt, expectedMaxDebt,"max debt mismatch");

        assertEq(accountDebt, 1e21, "account debt mismatch");

    }

}