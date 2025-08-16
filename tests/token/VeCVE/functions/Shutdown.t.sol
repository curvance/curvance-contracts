// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseVeCVE } from "../TestBaseVeCVE.sol";
import { VeCVE } from "contracts/token/VeCVE.sol";

contract ShutdownTest is TestBaseVeCVE {
    function test_shutdown_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(VeCVE.VeCVE__Unauthorized.selector);
        veCVE.shutdown();
    }

    function test_shutdown_success() public {
        assertEq(veCVE.isShutdown(), 1);
        assertEq(rewardManager.isShutdown(), 1);

        veCVE.shutdown();

        assertEq(veCVE.isShutdown(), 2);
        assertEq(rewardManager.isShutdown(), 2);
    }
}
