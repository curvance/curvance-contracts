// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";

contract RemoveApprovedAdaptorTest is TestBaseOracleManager {
    function test_removeApprovedAdaptor_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(1));

        vm.expectRevert(OracleManager.OracleManager__Unauthorized.selector);
        oracleManager.removeApprovedAdaptor(address(chainlinkAdaptor));
    }

    function test_removeApprovedAdaptor_fail_whenAdaptorDoesNotExist() public {
        vm.expectRevert(
            OracleManager.OracleManager__AdaptorIsNotApproved.selector
        );
        oracleManager.removeApprovedAdaptor(address(chainlinkAdaptor));
    }

    function test_removeApprovedAdaptor_success() public {
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        assertTrue(oracleManager.isApprovedAdaptor(address(chainlinkAdaptor)));

        oracleManager.removeApprovedAdaptor(address(chainlinkAdaptor));

        assertFalse(
            oracleManager.isApprovedAdaptor(address(chainlinkAdaptor))
        );
    }
}
