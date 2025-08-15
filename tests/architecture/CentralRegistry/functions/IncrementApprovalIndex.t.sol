// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract IncrementApprovalIndexTest is TestBaseMarketIsolated {
    event ApprovalIndexIncremented(address indexed user, uint256 newIndex);

    function test_incrementApprovalIndex_success() public {
        assertEq(centralRegistry.userApprovalIndex(user1), 0);

        vm.startPrank(user1);

        strategyCBALRETH.setDelegateApproval(user2, true);

        assert(strategyCBALRETH.isDelegate(user1, user2));

        vm.expectEmit(true, true, true, true);
        emit ApprovalIndexIncremented(user1, 1);

        centralRegistry.incrementApprovalIndex();

        assert(!strategyCBALRETH.isDelegate(user1, user2)); // Ensure delegation is reset

        assertEq(centralRegistry.userApprovalIndex(user1), 1);
    }
}
