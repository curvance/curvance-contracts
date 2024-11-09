// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";

contract SetDivergenceFlagsTest is TestBaseOracleManager {
    function test_setCautionDivergenceFlag_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(1));

        vm.expectRevert(OracleManager.OracleManager__Unauthorized.selector);
        oracleManager.setDivergenceFlags(10200, 10200);
    }

    function test_setCautionDivergenceFlag_fail_whenDivergenceIsTooSmall()
        public
    {
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.setDivergenceFlags(10199, 10200);
    }

    function test_setCautionDivergenceFlag_fail_whenDivergenceIsTooLarge()
        public
    {
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.setDivergenceFlags(12001, 10200);
    }

    function test_setCautionDivergenceFlag_success() public {
        assertEq(oracleManager.cautionDivergenceFlag(), 10500);

        oracleManager.setDivergenceFlags(10200, 11000);

        assertEq(oracleManager.cautionDivergenceFlag(), 10200);
    }

    function test_setBadSourceDivergenceFlag_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(1));

        vm.expectRevert(OracleManager.OracleManager__Unauthorized.selector);
        oracleManager.setDivergenceFlags(10200, 10200);
    }

    function test_setBadSourceDivergenceFlag_fail_whenDivergenceIsTooSmall()
        public
    {
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.setDivergenceFlags(10200, 10199);
    }

    function test_setBadSourceDivergenceFlag_fail_whenDivergenceIsTooLarge()
        public
    {
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.setDivergenceFlags(10200, 12001);
    }

    function test_setBadSourceDivergenceFlag_success() public {
        assertEq(oracleManager.badSourceDivergenceFlag(), 11000);

        oracleManager.setDivergenceFlags(10500, 10800);

        assertEq(oracleManager.badSourceDivergenceFlag(), 10800);
    }

    function test_setDivergenceFlags_fail_whenCautionEqualToBadSource()
        public
    {
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.setDivergenceFlags(10200, 10200);
    }

    function test_setDivergenceFlags_fail_whenCautionLargerThanBadSource()
        public
    {
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.setDivergenceFlags(10500, 10200);
    }
}
