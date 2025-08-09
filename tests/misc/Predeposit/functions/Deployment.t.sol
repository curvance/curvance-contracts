// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { Predeposit } from "contracts/misc/Predeposit.sol";

import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { TestBasePredeposit } from "../TestBasePredeposit.sol";

contract PredepositDeploymentTest is TestBasePredeposit {
    function test_predepositDeployment_fail_whenCentralRegistryIsInvalid()
        public
    {
        vm.expectRevert(
            CentralRegistryLib.CentralRegistryLib__InvalidCentralRegistry
                .selector
        );
        new Predeposit(
            ICentralRegistry(address(1)),
            manager,
            block.timestamp + 1 weeks
        );
    }

    function test_predepositDeployment_success() public {
        uint256 endTimestamp = block.timestamp + 1 weeks;

        predeposit = new Predeposit(
            ICentralRegistry(address(centralRegistry)),
            manager,
            endTimestamp
        );
        address[] memory predepositTokens = new address[](1);
        predepositTokens[0] = _WETH_ADDRESS;

        vm.startPrank(manager);
        predeposit.addPredepositTokens(predepositTokens);
        vm.stopPrank();

        (bool isApproved, ) = predeposit.tokenData(_WETH_ADDRESS);

        assertEq(
            address(predeposit.centralRegistry()),
            address(centralRegistry)
        );
        assertEq(predeposit.predepositManager(), manager);
        assertEq(predeposit.predepositEndTimestamp(), endTimestamp);
        assertTrue(isApproved);
    }
}
