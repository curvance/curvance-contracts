// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMessagingHub } from "tests/architecture/MessagingHub/TestBaseMessagingHub.sol";
import { CurvancePrefarm } from "contracts/misc/CurvancePrefarm.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract TestBaseCurvancePrefarm is TestBaseMessagingHub {
    CurvancePrefarm public curvancePrefarm;
    address public manager = makeAddr("Manager");

    function setUp() public virtual override {
        super.setUp();

        curvancePrefarm = new CurvancePrefarm(
            ICentralRegistry(address(centralRegistry)),
            manager,
            block.timestamp + 1 weeks
        );

        address[] memory prefarmTokens = new address[](2);
        prefarmTokens[0] = _USDC_ADDRESS;
        prefarmTokens[1] = _DAI_ADDRESS;

        vm.startPrank(manager);
        curvancePrefarm.addPrefarmTokens(prefarmTokens);
        vm.stopPrank();
    }
}
