// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManager } from "../TestBaseMarketManager.sol";


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

    function test_marketManagerQueueLiquidation_fail_whenNoLiquidationAvailable()
        public
    {
        marketManager.listToken(address(eUSDC));
        marketManager.listToken(address(pBALRETH));

        marketManager.updatePositionToken(
            address(pBALRETH),
            7000,
            4000, // liquidate at 71%
            3000,
            200, // 2% liq incentive
            400,
            1000
        );

        vm.prank(address(eUSDC));

        vm.expectRevert(
            MarketManager.MarketManager__NoLiquidationAvailable.selector
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
        bytes32 user2AccessKey = keccak256(
            abi.encodePacked(user1, user2, uint64(1), address(eUSDC))
        );
        bytes32 user3AccessKey = keccak256(
            abi.encodePacked(user1, user3, uint64(1), address(eUSDC))
        );
        bytes32 user4AccessKey = keccak256(
            abi.encodePacked(user1, user4, uint64(2), address(eUSDC))
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
        assertEq(marketManager.priorityAccess(user2AccessKey), 0);
        assertEq(marketManager.priorityAccess(user3AccessKey), 0);
        assertEq(marketManager.priorityAccess(user4AccessKey), 0);

        vm.startPrank(address(eUSDC));

        vm.expectEmit(true, true, true, true, address(marketManager));
        emit LiquidationQueued(user1, user2, address(eUSDC));

        marketManager.queueLiquidation(
            address(eUSDC),
            address(pBALRETH),
            user2,
            user1
        );

        vm.expectEmit(true, true, true, true, address(marketManager));
        emit LiquidationQueued(user1, user3, address(eUSDC));

        marketManager.queueLiquidation(
            address(eUSDC),
            address(pBALRETH),
            user3,
            user1
        );

        (priorityStartline, regularStartline, endLine, nonce) = marketManager
            .regularQueue(queueKey);

        assertEq(priorityStartline, block.timestamp + 1);
        assertEq(regularStartline, block.timestamp + 3);
        assertEq(endLine, block.timestamp + 30);
        assertEq(nonce, 1);
        assertEq(
            marketManager.priorityAccess(user2AccessKey),
            block.timestamp + 1
        );
        assertEq(
            marketManager.priorityAccess(user3AccessKey),
            block.timestamp + 1
        );

        vm.roll(block.number + 10);
        skip(100);

        vm.expectEmit(true, true, true, true, address(marketManager));
        emit LiquidationQueued(user1, user4, address(eUSDC));

        marketManager.queueLiquidation(
            address(eUSDC),
            address(pBALRETH),
            user4,
            user1
        );

        (priorityStartline, regularStartline, endLine, nonce) = marketManager
            .regularQueue(queueKey);

        assertEq(priorityStartline, block.timestamp + 1);
        assertEq(regularStartline, block.timestamp + 3);
        assertEq(endLine, block.timestamp + 30);
        assertEq(nonce, 2);
        assertEq(
            marketManager.priorityAccess(user4AccessKey),
            block.timestamp + 1
        );

        vm.stopPrank();
    }
}
