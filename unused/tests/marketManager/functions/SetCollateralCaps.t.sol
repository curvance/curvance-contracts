// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { TestBaseMarketManager } from "../TestBaseMarketManager.sol";


contract SetCollateralCapsTest is TestBaseMarketManager {
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
        mTokens.push(address(borrowableCUSDC));
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
        balRETH.approve(address(simpleCBALRETH), 1 ether);
        marketManager.listToken(address(simpleCBALRETH));
        marketManager.updatePositionToken(
            address(simpleCBALRETH),
            7000,
            4000,
            3000,
            200,
            400,
            1000
        );

        address[] memory validMTokens = new address[](2);
        validMTokens[0] = address(simpleCBALRETH);
        validMTokens[1] = address(simpleCBALRETH);
        uint256[] memory validCollateralCaps = new uint256[](2);
        validCollateralCaps[0] = 100e18;
        validCollateralCaps[1] = 10e18;

        for (uint256 i = 0; i < validMTokens.length; i++) {
            vm.expectEmit(address(marketManager));
            emit CollateralCapUpdated(validMTokens[i], validCollateralCaps[i]);
        }

        marketManager.setCollateralCaps(
            validMTokens,
            validCollateralCaps
        );

        assertEq(
            marketManager.collateralCaps(address(simpleCBALRETH)),
            validCollateralCaps[1]
        );
    }
}
