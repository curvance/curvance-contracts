// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract SetRewardManagerTest is TestBaseMarket {
    event CoreContractSet(string indexed contractType, address newAddress);

    address public newRewardManager = makeAddr("Reward Manager");

    function test_setRewardManager_fail_whenUnauthorized() public {
        vm.prank(address(0));

        /// bytes4(keccak256(bytes("CentralRegistry__ParametersMisconfigured()")))
        vm.expectRevert(0xa5bb570d);
        centralRegistry.setRewardManager(newRewardManager);
    }

    // function test_setRewardManager_success() public {
    //     assertEq(centralRegistry.rewardManager(), address(rewardManager));

    //     vm.expectEmit(true, true, true, true);
    //     emit CoreContractSet("Reward Manager", newRewardManager);

    //     centralRegistry.setRewardManager(newRewardManager);

    //     assertEq(centralRegistry.rewardManager(), newRewardManager);
    // }
}
