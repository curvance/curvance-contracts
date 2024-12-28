// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManager } from "../TestBaseMarketManager.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";

contract QueueAccountLiquidationTest is TestBaseMarketManager {
    event AccountLiquidationQueued(
        address indexed account,
        address indexed liquidator
    );

    function test_queueAccountLiquidation_fail_whenCallerIsAccount() public {
        vm.prank(user1);

        vm.expectRevert(MarketManager.MarketManager__Unauthorized.selector);
        marketManager.queueAccountLiquidation(user1);
    }

    function test_queueAccountLiquidation_fail_whenPaused() public {
        marketManager.setSeizePaused(true);

        vm.prank(user2);

        vm.expectRevert(MarketManager.MarketManager__Paused.selector);
        marketManager.queueAccountLiquidation(user1);
    }

    function test_queueAccountLiquidation_fail_whenNoLiquidationAvailable()
        public
    {
        vm.prank(user2);

        vm.expectRevert(
            MarketManager.MarketManager__NoLiquidationAvailable.selector
        );
        marketManager.queueAccountLiquidation(user1);
    }

    function test_queueAccountLiquidation_success() public {
        _prepareLiquidation();

        bytes32 queueKey = keccak256(abi.encodePacked(user1, address(0)));
        bytes32 user2AccessKey = keccak256(
            abi.encodePacked(user1, user2, uint64(1), address(0))
        );
        bytes32 user3AccessKey = keccak256(
            abi.encodePacked(user1, user3, uint64(1), address(0))
        );
        bytes32 user4AccessKey = keccak256(
            abi.encodePacked(user1, user4, uint64(2), address(0))
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

        vm.prank(user2);

        vm.expectEmit(true, true, true, true, address(marketManager));
        emit AccountLiquidationQueued(user1, user2);

        marketManager.queueAccountLiquidation(user1);

        vm.prank(user3);

        vm.expectEmit(true, true, true, true, address(marketManager));
        emit AccountLiquidationQueued(user1, user3);

        marketManager.queueAccountLiquidation(user1);

        (priorityStartline, regularStartline, endLine, nonce) = marketManager
            .regularQueue(queueKey);

        assertEq(priorityStartline, block.timestamp + 1);
        assertEq(regularStartline, block.timestamp + 2);
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

        vm.prank(user4);

        vm.expectEmit(true, true, true, true, address(marketManager));
        emit AccountLiquidationQueued(user1, user4);

        marketManager.queueAccountLiquidation(user1);

        (priorityStartline, regularStartline, endLine, nonce) = marketManager
            .regularQueue(queueKey);

        assertEq(priorityStartline, block.timestamp + 1);
        assertEq(regularStartline, block.timestamp + 2);
        assertEq(endLine, block.timestamp + 30);
        assertEq(nonce, 2);
        assertEq(
            marketManager.priorityAccess(user4AccessKey),
            block.timestamp + 1
        );
    }
}
