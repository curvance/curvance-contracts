// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract SetRewardManagerTest is TestBaseMarket {
    event CoreContractSet(string indexed contractType, address newAddress);

    address public newRewardManager = makeAddr("Reward Manager");

    function setUp() public override {
        super.setUp();

        centralRegistry = new CentralRegistry(
            _ZERO_ADDRESS,
            _ZERO_ADDRESS,
            _ZERO_ADDRESS,
            block.timestamp + 1,
            address(0),
            _USDC_ADDRESS
        );
    }

    function test_setRewardManager_fail_whenUnauthorized() public {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.setRewardManager(newRewardManager);
    }

    function test_setRewardManager_fail_whenEpochAlreadyStarted() public {
        vm.warp(centralRegistry.genesisEpoch());

        vm.expectRevert(
            CentralRegistry.CentralRegistry__EpochHasStarted.selector
        );
        centralRegistry.setRewardManager(newRewardManager);
    }

    function test_setRewardManager_fail_whenRewardManagerIsAlreadySet()
        public
    {
        centralRegistry.setRewardManager(newRewardManager);

        vm.expectRevert(
            CentralRegistry.CentralRegistry__ParametersMisconfigured.selector
        );
        centralRegistry.setRewardManager(newRewardManager);
    }

    function test_setRewardManager_success() public {
        assertEq(centralRegistry.rewardManager(), _ZERO_ADDRESS);

        vm.expectEmit(true, true, true, true);
        emit CoreContractSet("Reward Manager", newRewardManager);

        centralRegistry.setRewardManager(newRewardManager);

        assertEq(centralRegistry.rewardManager(), newRewardManager);
    }
}
