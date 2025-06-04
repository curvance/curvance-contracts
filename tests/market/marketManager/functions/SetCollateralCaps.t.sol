// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManager } from "../TestBaseMarketManager.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";

contract SetCollateralCapsTest is TestBaseMarketManager {
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

    function test_setCollateralCaps_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(1));
        vm.expectRevert(MarketManager.MarketManager__Unauthorized.selector);
        marketManager.setCollateralCaps(mTokens, collateralCaps);
    }

    function test_setCollateralCaps_fail_whenMTokenLengthIsZero()
        public
    {
        vm.expectRevert(
            MarketManager.MarketManager__InvalidParameter.selector
        );
        marketManager.setCollateralCaps(
            new address[](0),
            collateralCaps
        );
    }

    function test_setCollateralCaps_fail_whenMTokenAndCapsLengthsMismatch()
        public
    {
        mTokens.push(address(eUSDC));
        assertNotEq(mTokens.length, collateralCaps.length);
        vm.expectRevert(
            MarketManager.MarketManager__InvalidParameter.selector
        );
        marketManager.setCollateralCaps(mTokens, collateralCaps);
        mTokens.pop();
    }

    function test_setCollateralCaps_fail_whenNotPToken() public {
        assertEq(mTokens.length, collateralCaps.length);
        vm.expectRevert(
            MarketManager.MarketManager__InvalidParameter.selector
        );
        marketManager.setCollateralCaps(mTokens, collateralCaps);
    }

    function test_setCollateralCaps_success() public {
        _prepareBALRETH(address(this), 1 ether);
        balRETH.approve(address(pBALRETH), 1 ether);
        marketManager.listToken(address(pBALRETH));
        marketManager.updatePositionToken(
            address(pBALRETH),
            7000,
            4000,
            3000,
            200,
            400,
            1000
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

        marketManager.setCollateralCaps(
            validMTokens,
            validCollateralCaps
        );

        assertEq(
            marketManager.collateralCaps(address(pBALRETH)),
            validCollateralCaps[1]
        );
    }
}
