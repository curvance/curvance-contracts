// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManager } from "../TestBaseMarketManager.sol";


contract ListTokenTest is TestBaseMarketManager {
    event TokenListed(address mToken);

    function test_listToken_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(MarketManager.MarketManager__Unauthorized.selector);
        marketManager.listToken(address(borrowableCUSDC));
    }

    function test_listToken_fail_whenMTokenIsAlreadyListed() public {
        marketManager.listToken(address(borrowableCUSDC));

        vm.expectRevert(
            MarketManager.MarketManager__InvalidParameter.selector
        );
        marketManager.listToken(address(borrowableCUSDC));
    }

    function test_listToken_fail_whenMTokenIsInvalid() public {
        vm.expectRevert();
        marketManager.listToken(address(1));
    }

    function test_listToken_success() public {
        (bool isListed, uint256 collRatio, , , , , , ) = marketManager
            .tokenData(address(borrowableCUSDC));
        assertFalse(isListed);
        assertEq(collRatio, 0);

        vm.expectEmit(true, true, true, true, address(marketManager));
        emit TokenListed(address(borrowableCUSDC));

        marketManager.listToken(address(borrowableCUSDC));

        (isListed, collRatio, , , , , , ) = marketManager.tokenData(
            address(borrowableCUSDC)
        );
        assertTrue(isListed);
        assertEq(collRatio, 0);

        assertEq(borrowableCUSDC.totalSupply(), 77777);
    }
}
