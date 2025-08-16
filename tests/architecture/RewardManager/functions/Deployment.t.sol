// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { RewardManager } from "contracts/architecture/RewardManager.sol";

import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { TestBaseRewardManager } from "../TestBaseRewardManager.sol";

contract RewardManagerDeploymentTest is TestBaseRewardManager {
    function test_rewardManagerDeployment_fail_whenCentralRegistryIsInvalid()
        public
    {
        vm.expectRevert(
            CentralRegistryLib.CentralRegistryLib__InvalidCentralRegistry
                .selector
        );
        new RewardManager(ICentralRegistry(address(0)));
    }

    function test_rewardManagerDeployment_success() public {
        rewardManager = new RewardManager(
            ICentralRegistry(address(centralRegistry))
        );

        assertEq(
            address(rewardManager.centralRegistry()),
            address(centralRegistry)
        );

        vm.warp(centralRegistry.genesisEpoch() - 1);

        assertEq(rewardManager.currentEpoch(block.timestamp), 0);
    }
}
