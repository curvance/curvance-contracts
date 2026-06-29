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
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.replaceApprovedAdaptor(
            address(dualChainlinkAdaptor),
            address(chainlinkAdaptor)
        );
    }

    function test_replaceApprovedAdaptor_fail_whenNewAdaptorHasNoCode() public {
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.replaceApprovedAdaptor(
            address(chainlinkAdaptor),
            address(1)
        );
    }

    function test_replaceApprovedAdaptor_fail_whenNewAdaptorIsNotOracleAdaptor()
        public
    {
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.replaceApprovedAdaptor(
            address(chainlinkAdaptor),
            address(this)
        );
    }

    function test_replaceApprovedAdaptor_success() public {

        assertTrue(oracleManager.isApprovedAdaptor(address(chainlinkAdaptor)));
        oracleManager.removeApprovedAdaptor(address(dualChainlinkAdaptor));

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