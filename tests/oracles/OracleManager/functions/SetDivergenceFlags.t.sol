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
        oracleManager.setDivergenceFlags(10100, 10100);
    }

    function test_setCautionDivergenceFlag_fail_whenDivergenceIsTooSmall()
        public
    {
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.setDivergenceFlags(10001, 10100);
    }

    function test_setCautionDivergenceFlag_fail_whenDivergenceIsTooLarge()
        public
    {
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.setDivergenceFlags(12001, 10200);
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
        oracleManager.setDivergenceFlags(10010, 10009);
    }

    function test_setBadSourceDivergenceFlag_fail_whenDivergenceIsTooLarge()
        public
    {
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.setDivergenceFlags(10100, 12001);
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
        oracleManager.setDivergenceFlags(10200, 10100);
    }

    function test_setCautionDivergenceFlag_success() public {
        (uint256 caution, uint256 badSource) =
            oracleManager.getDivergenceFlags();
        assertEq(caution, 10050);

        oracleManager.setDivergenceFlags(10100, 10200);
        (uint256 caution, uint256 badSource) =
            oracleManager.getDivergenceFlags();

        assertEq(caution, 10100);
        assertEq(badSource, 10200);
    }

    function test_setBadSourceDivergenceFlag_success() public {
        (uint256 caution, uint256 badSource) =
            oracleManager.getDivergenceFlags();
        assertEq(badSource, 10100);

        oracleManager.setDivergenceFlags(10100, 10150);
        (uint256 caution, uint256 badSource) =
            oracleManager.getDivergenceFlags();

        assertEq(caution, 10100);
        assertEq(badSource, 10150);
    }
}
