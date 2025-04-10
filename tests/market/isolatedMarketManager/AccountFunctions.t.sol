// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { TestBaseMarketManager } from "tests/market/marketManager/TestBaseMarketManager.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { IMToken } from "contracts/interfaces/IMToken.sol";

contract AccountFunctionsIsolatedMarketManager is TestBaseMarketManager {
    address dappControlUser = makeAddr("dappControlUser");


    function setUp() public override {
        super.setUp();
        
        // Setup market with tokens
        deal(address(balRETH), address(this), 42069);
        balRETH.approve(address(pBALRETHIsolated), 42069);

        deal(address(_USDC_ADDRESS), address(this), 42069);
        usdc.approve(address(eUSDCIsolated), 42069);
        
        // List tokens in the market
        marketManagerIsolated.listTokens(address(pBALRETHIsolated), address(eUSDCIsolated));
        
        // Set position token parameters
        marketManagerIsolated.updatePositionToken(
            7000,    // collRatio 70%
            4000,    // collReqSoft 40%
            3000,    // collReqHard 25%
            1000,    // liqIncBase 10%
            500,     // liqIncMin 5%
            2000,    // liqIncMax 20%
            2000     // baseCFactor 20%
        );

        // Create a dapp control user
        dappControlUser = makeAddr("dappControlUser");
        vm.startPrank(centralRegistry.daoAddress());
        centralRegistry.addAuthorizedAtlasDAppControl(dappControlUser);
        vm.stopPrank();

        address[] memory tokens = new address[](1);
        tokens[0] = address(pBALRETHIsolated);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManagerIsolated.setPTokenCollateralCaps(tokens, caps);

        _prepareLiquidationIsolated();

    }

    function test_assetsOf() public {
        IMToken[] memory assets = marketManagerIsolated.assetsOf(user1);
        assertEq(assets.length, 2);
        assertEq(address(assets[0]), address(pBALRETHIsolated));
        assertEq(address(assets[1]), address(eUSDCIsolated));
    }

    function test_tokenDataOf() public {

        (bool hasPosition, uint256 balanceOf, uint256 collateralPostedOf) = marketManagerIsolated.tokenDataOf(user1, address(pBALRETHIsolated));
        assertEq(hasPosition, true);
        assertEq(balanceOf, _ONE);
        assertEq(collateralPostedOf, _ONE - 1);

    }

    function test_statusOf() public {

        mockUsdcFeed.setMockAnswer(1e8); // reset price back to $1

        (uint256 accountCollateral, uint256 maxDebt, uint256 accountDebt) = marketManagerIsolated.statusOf(user1);

        uint256 expectedMaxDebt = 7000 * accountCollateral / 10000; // 70% LTV

        assertEq(maxDebt, expectedMaxDebt);

        assertEq(accountDebt, 1e21);

    }

}