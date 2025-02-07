// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract IncrementApprovalIndexTest is TestBaseMarket {
    event ApprovalIndexIncremented(address indexed user, uint256 newIndex);

    function test_incrementApprovalIndex_success() public {
        assertEq(centralRegistry.getUserApprovalIndex(user1), 0);

        vm.startPrank(user1);

        pBALRETH.setDelegateApproval(user2, true);

        assert(pBALRETH.isDelegate(user1, user2));

        vm.expectEmit(true, true, true, true);
        emit ApprovalIndexIncremented(user1, 1);

        centralRegistry.incrementApprovalIndex();

        assert(!pBALRETH.isDelegate(user1, user2)); // Ensure delegation is reset

        assertEq(centralRegistry.getUserApprovalIndex(user1), 1);
    }
}
