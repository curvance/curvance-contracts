// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManager } from "../TestBaseMarketManager.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";

contract MarketManagerQueueLiquidationTest is TestBaseMarketManager {
    event LiquidationQueued(
        address indexed account,
        address indexed liquidator,
        address indexed eToken
    );

    function test_marketManagerQueueLiquidation_fail_whenCallerIsNotEToken()
        public
    {
        vm.expectRevert(MarketManager.MarketManager__Unauthorized.selector);
        marketManager.queueLiquidation(
            address(eUSDC),
            address(pBALRETH),
            user2,
            user1
        );
    }

    function test_marketManagerQueueLiquidation_fail_whenMTokenIsNotListed()
        public
    {
        vm.prank(address(eUSDC));

        vm.expectRevert(MarketManager.MarketManager__TokenNotListed.selector);
        marketManager.queueLiquidation(
            address(eUSDC),
            address(pBALRETH),
            user2,
            user1
        );
    }

    function test_marketManagerQueueLiquidation_fail_whenPTokenIsNotListed()
        public
    {
        marketManager.listToken(address(eUSDC));

        vm.prank(address(eUSDC));

        vm.expectRevert(MarketManager.MarketManager__TokenNotListed.selector);
        marketManager.queueLiquidation(
            address(eUSDC),
            address(pBALRETH),
            user2,
            user1
        );
    }

    function test_marketManagerQueueLiquidation_fail_whenCallateralRatioIsZero()
        public
    {
        marketManager.listToken(address(eUSDC));
        marketManager.listToken(address(pBALRETH));

        vm.prank(address(eUSDC));

        vm.expectRevert(
            MarketManager.MarketManager__InvalidParameter.selector
        );
        marketManager.queueLiquidation(
            address(eUSDC),
            address(pBALRETH),
            user2,
            user1
        );
    }

    function test_marketManagerQueueLiquidation_success() public {
        _prepareLiquidation();

        bytes32 queueKey = keccak256(abi.encodePacked(user1, address(eUSDC)));
        bytes32 accessKey = keccak256(
            abi.encodePacked(user1, user2, uint64(1), address(eUSDC))
        );

        (
            uint64 priorityStartline,
            uint64 regularStartline,
            uint64 endLine,
            uint64 nonce
        ) = marketManager.regularQueue(queueKey);

        assertEq(priorityStartline, 0);
        assertEq(regularStartline, 0);
        assertEq(endLine, 0);
        assertEq(nonce, 0);
        assertEq(marketManager.priorityAccess(accessKey), 0);

        vm.prank(address(eUSDC));

        vm.expectEmit(true, true, true, true, address(marketManager));
        emit LiquidationQueued(user1, user2, address(eUSDC));

        marketManager.queueLiquidation(
            address(eUSDC),
            address(pBALRETH),
            user2,
            user1
        );

        (priorityStartline, regularStartline, endLine, nonce) = marketManager
            .regularQueue(queueKey);

        assertEq(priorityStartline, block.timestamp + 1);
        assertEq(regularStartline, block.timestamp + 2);
        assertEq(endLine, block.timestamp + 30);
        assertEq(nonce, 1);
        assertEq(marketManager.priorityAccess(accessKey), block.timestamp + 1);
    }
}
