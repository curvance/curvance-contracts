// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { TestBaseMarketManagerIsolated } from "../TestBaseMarketManagerIsolated.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract SetCollateralCapsTest is TestBaseMarketManagerIsolated {
    address[] public mTokens;
    uint256[] public collateralCaps;

    event CollateralCapUpdated(address mToken, uint256 newCollateralCap);

    function setUp() public override {
        super.setUp();

        mTokens.push(address(borrowableCUSDC));
        mTokens.push(address(borrowableCDAI));
        mTokens.push(address(simpleCBALRETH));
        collateralCaps.push(100e6);
        collateralCaps.push(100e18);
        collateralCaps.push(100e18);
    }

    function test_setCollateralCaps_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(1));
        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.setCollateralCaps(mTokens, collateralCaps);
    }

    function test_setCollateralCaps_fail_whenMTokenLengthIsZero()
        public
    {
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InvalidParameter.selector
        );
        marketManagerIsolated.setCollateralCaps(
            new address[](0),
            collateralCaps
        );
    }

    function test_setCollateralCaps_fail_whenMTokenAndCapsLengthsMismatch()
        public
    {
        mTokens.push(address(borrowableCUSDC));
        assertNotEq(mTokens.length, collateralCaps.length);
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InvalidParameter.selector
        );
        marketManagerIsolated.setCollateralCaps(mTokens, collateralCaps);
        mTokens.pop();
    }

    function test_setCollateralCaps_fail_whenNotPToken() public {
        assertEq(mTokens.length, collateralCaps.length);
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InvalidParameter.selector
        );
        marketManagerIsolated.setCollateralCaps(mTokens, collateralCaps);
    }

    function test_setCollateralCaps_success() public {
        _prepareBALRETH(address(this), 1 ether);
        balRETH.approve(address(simpleCBALRETH), 1 ether);
        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(simpleCBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(simpleCBALRETH), address(borrowableCUSDC));
        marketManagerIsolated.updatePositionToken(
            7000,    // collRatio 70%
            4000,    // collReqSoft 40%
            3000,    // collReqHard 25%
            1000,    // liqIncBase 10%
            1500,    // liqIncHard 15%
            500,     // liqIncMin 5%
            2000,    // liqIncMax 20%
            2000,    // minEffectiveCFactor 20%
            5000,    // maxEffectiveCFactor 50%
            2000     // baseCFactor 20%
        );

        address[] memory validMTokens = new address[](2);
        validMTokens[0] = address(simpleCBALRETH);
        validMTokens[1] = address(simpleCBALRETH);
        uint256[] memory validCollateralCaps = new uint256[](2);
        validCollateralCaps[0] = 100e18;
        validCollateralCaps[1] = 10e18;

        for (uint256 i = 0; i < validMTokens.length; i++) {
            vm.expectEmit(address(marketManagerIsolated));
            emit CollateralCapUpdated(validMTokens[i], validCollateralCaps[i]);
        }

        marketManagerIsolated.setCollateralCaps(
            validMTokens,
            validCollateralCaps
        );

        assertEq(
            marketManagerIsolated.collateralCaps(address(simpleCBALRETH)),
            validCollateralCaps[1]
        );
    }
}
