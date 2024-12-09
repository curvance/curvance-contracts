// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseEToken } from "../TestBaseEToken.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";
import { EToken } from "contracts/market/token/EToken.sol";
import { IMToken } from "contracts/interfaces/IMToken.sol";

contract ETokenQueueLiquidationTest is TestBaseEToken {
    event LiquidationQueued(
        address indexed account,
        address indexed liquidator,
        address indexed eToken
    );

    function test_eTokenQueueLiquidation_fail_whenCallerIsLiquidator() public {
        vm.prank(user1);

        vm.expectRevert(EToken.EToken__Unauthorized.selector);
        eUSDC.queueLiquidation(user1, IMToken(address(pBALRETH)));
    }

    function test_eTokenQueueLiquidation_fail_whenMTokenIsNotPositionToken()
        public
    {
        vm.prank(user2);

        vm.expectRevert(EToken.EToken__ValidationFailed.selector);
        eUSDC.queueLiquidation(user1, IMToken(address(eUSDC)));
    }

    function test_eTokenQueueLiquidation_fail_whenNoLiquidationAvailable()
        public
    {
        vm.prank(user2);

        vm.expectRevert(
            MarketManager.MarketManager__NoLiquidationAvailable.selector
        );
        eUSDC.queueLiquidation(user1, IMToken(address(pBALRETH)));
    }

    function test_eTokenQueueLiquidation_success() public {
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

        vm.prank(user2);

        vm.expectEmit(true, true, true, true, address(marketManager));
        emit LiquidationQueued(user1, user2, address(eUSDC));

        eUSDC.queueLiquidation(user1, IMToken(address(pBALRETH)));

        (priorityStartline, regularStartline, endLine, nonce) = marketManager
            .regularQueue(queueKey);

        assertEq(priorityStartline, block.timestamp + 1);
        assertEq(regularStartline, block.timestamp + 2);
        assertEq(endLine, block.timestamp + 30);
        assertEq(nonce, 1);
        assertEq(marketManager.priorityAccess(accessKey), block.timestamp + 1);
    }
}
