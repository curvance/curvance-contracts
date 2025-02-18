// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";

contract AddApprovedAdaptorTest is TestBaseOracleManager {
    function test_addApprovedAdaptor_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(OracleManager.OracleManager__Unauthorized.selector);
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
    }

    function test_addApprovedAdaptor_fail_whenAdaptorIsAlreadyConfigured()
        public
    {
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        vm.expectRevert(
            OracleManager.OracleManager__AdaptorIsNotApproved.selector
        );
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
    }

    function test_addApprovedAdaptor_success() public {
        assertFalse(
            oracleManager.isApprovedAdaptor(address(chainlinkAdaptor))
        );

        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        assertTrue(oracleManager.isApprovedAdaptor(address(chainlinkAdaptor)));
    }
}
