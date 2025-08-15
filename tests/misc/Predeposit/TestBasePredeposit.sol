// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import { TestBaseMessagingHub } from "tests/architecture/MessagingHub/TestBaseMessagingHub.sol";
import { Predeposit } from "contracts/misc/Predeposit.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract TestBasePredeposit is TestBaseMessagingHub {
    Predeposit public predeposit;
    address public manager = makeAddr("Manager");

    function setUp() public virtual override {
        super.setUp();

        predeposit = new Predeposit(
            ICentralRegistry(address(centralRegistry)),
            manager,
            block.timestamp + 1 weeks
        );

        address[] memory predepositTokens = new address[](2);
        predepositTokens[0] = _USDC_ADDRESS;
        predepositTokens[1] = _DAI_ADDRESS;

        vm.startPrank(manager);
        predeposit.addPredepositTokens(predepositTokens);
        vm.stopPrank();
    }
}
