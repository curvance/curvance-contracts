// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseOracleRouter } from "../TestBaseOracleRouter.sol";
import { OracleRouter } from "contracts/oracles/OracleRouter.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";

contract AddApprovedAdaptorTest is TestBaseOracleRouter {
    function test_addApprovedAdaptor_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(OracleRouter.OracleRouter__Unauthorized.selector);
        oracleRouter.addApprovedAdaptor(address(chainlinkAdaptor));
    }

    function test_addApprovedAdaptor_fail_whenAdaptorIsAlreadyConfigured()
        public
    {
        oracleRouter.addApprovedAdaptor(address(chainlinkAdaptor));

        vm.expectRevert(OracleRouter.OracleRouter__InvalidParameter.selector);
        oracleRouter.addApprovedAdaptor(address(chainlinkAdaptor));
    }

    function test_addApprovedAdaptor_success() public {
        assertFalse(oracleRouter.isApprovedAdaptor(address(chainlinkAdaptor)));

        oracleRouter.addApprovedAdaptor(address(chainlinkAdaptor));

        assertTrue(oracleRouter.isApprovedAdaptor(address(chainlinkAdaptor)));
    }
}
