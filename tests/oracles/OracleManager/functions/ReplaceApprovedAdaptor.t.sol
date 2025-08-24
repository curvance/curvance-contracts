// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";

contract ReplaceApprovedAdaptorTest is TestBaseOracleManager {
    function test_replaceApprovedAdaptor_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(1));

        vm.expectRevert(OracleManager.OracleManager__Unauthorized.selector);
        oracleManager.replaceApprovedAdaptor(
            address(chainlinkAdaptor),
            address(dualChainlinkAdaptor)
        );
    }

    function test_replaceApprovedAdaptor_fail_whenAdaptorsAreIdentical()
        public
    {
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.replaceApprovedAdaptor(
            address(chainlinkAdaptor),
            address(chainlinkAdaptor)
        );
    }

    function test_replaceApprovedAdaptor_fail_whenNewAdaptorIsAlreadyConfigured()
        public
    {
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
        oracleManager.addApprovedAdaptor(address(dualChainlinkAdaptor));

        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.replaceApprovedAdaptor(
            address(dualChainlinkAdaptor),
            address(chainlinkAdaptor)
        );
    }

    function test_replaceApprovedAdaptor_fail_whenCurrentAdaptorIsNotConfigured()
        public
    {
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.replaceApprovedAdaptor(
            address(dualChainlinkAdaptor),
            address(chainlinkAdaptor)
        );
    }

    function test_replaceApprovedAdaptor_success() public {
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
        assertTrue(oracleManager.isApprovedAdaptor(address(chainlinkAdaptor)));

        oracleManager.replaceApprovedAdaptor(
            address(chainlinkAdaptor),
            address(dualChainlinkAdaptor)
        );

        assertFalse(
            oracleManager.isApprovedAdaptor(address(chainlinkAdaptor))
        );
        assertTrue(
            oracleManager.isApprovedAdaptor(address(dualChainlinkAdaptor))
        );
    }
}
