// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManagerIsolated } from "../TestBaseMarketManagerIsolated.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";

contract SetPTokenCollateralCapsTest is TestBaseMarketManagerIsolated {
    address[] public mTokens;
    uint256[] public collateralCaps;

    event NewCollateralCap(address mToken, uint256 newCollateralCap);

    function setUp() public override {
        super.setUp();

        mTokens.push(address(eUSDC));
        mTokens.push(address(eDAI));
        mTokens.push(address(pBALRETH));
        collateralCaps.push(100e6);
        collateralCaps.push(100e18);
        collateralCaps.push(100e18);
    }

    function test_setPTokenCollateralCaps_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(1));
        vm.expectRevert(MarketManager.MarketManager__Unauthorized.selector);
        marketManager.setPTokenCollateralCaps(mTokens, collateralCaps);
    }

    function test_setPTokenCollateralCaps_fail_whenMTokenLengthIsZero()
        public
    {
        vm.expectRevert(
            MarketManager.MarketManager__InvalidParameter.selector
        );
        marketManager.setPTokenCollateralCaps(
            new address[](0),
            collateralCaps
        );
    }

    function test_setPTokenCollateralCaps_fail_whenMTokenAndCapsLengthsMismatch()
        public
    {
        mTokens.push(address(eUSDC));
        assertNotEq(mTokens.length, collateralCaps.length);
        vm.expectRevert(
            MarketManager.MarketManager__InvalidParameter.selector
        );
        marketManager.setPTokenCollateralCaps(mTokens, collateralCaps);
        mTokens.pop();
    }

    function test_setPTokenCollateralCaps_fail_whenNotPToken() public {
        assertEq(mTokens.length, collateralCaps.length);
        vm.expectRevert(
            MarketManager.MarketManager__InvalidParameter.selector
        );
        marketManager.setPTokenCollateralCaps(mTokens, collateralCaps);
    }

    function test_setPTokenCollateralCaps_success() public {
        _prepareBALRETH(address(this), 1 ether);
        balRETH.approve(address(pBALRETH), 1 ether);
        deal(address(balRETH), address(this), 42069);
        balRETH.approve(address(pBALRETH), 42069);

        deal(address(_USDC_ADDRESS), address(this), 42069);
        usdc.approve(address(eUSDC), 42069);

        marketManager.listTokens(address(pBALRETH), address(eUSDC));
        marketManager.updatePositionToken(
            7000,    // collRatio 70%
            4000,    // collReqSoft 40%
            3000,    // collReqHard 25%
            1000,    // liqIncBase 10%
            500,     // liqIncMin 5%
            2000,    // liqIncMax 20%
            2000     // baseCFactor 20%
        );

        address[] memory validMTokens = new address[](2);
        validMTokens[0] = address(pBALRETH);
        validMTokens[1] = address(pBALRETH);
        uint256[] memory validCollateralCaps = new uint256[](2);
        validCollateralCaps[0] = 100e18;
        validCollateralCaps[1] = 10e18;

        for (uint256 i = 0; i < validMTokens.length; i++) {
            vm.expectEmit(address(marketManager));
            emit NewCollateralCap(validMTokens[i], validCollateralCaps[i]);
        }

        marketManager.setPTokenCollateralCaps(
            validMTokens,
            validCollateralCaps
        );

        assertEq(
            marketManager.collateralCaps(address(pBALRETH)),
            validCollateralCaps[1]
        );
    }
}
