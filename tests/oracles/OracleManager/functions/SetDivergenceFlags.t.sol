// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";

contract SetDivergenceFlagsTest is TestBaseOracleManager {
    function test_setCautionDivergenceFlag_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(1));

        vm.expectRevert(OracleManager.OracleManager__Unauthorized.selector);
        oracleManager.setDeviationBounds(_USDC_ADDRESS, 10100, 10100);
    }

    function test_setCautionDivergenceFlag_fail_whenDivergenceIsTooSmall()
        public
    {
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.setDeviationBounds(_USDC_ADDRESS, 10001, 10100);
    }

    function test_setCautionDivergenceFlag_fail_whenDivergenceIsTooLarge()
        public
    {
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.setDeviationBounds(_USDC_ADDRESS, 12001, 10200);
    }

    function test_setBadSourceDivergenceFlag_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(1));

        vm.expectRevert(OracleManager.OracleManager__Unauthorized.selector);
        oracleManager.setDeviationBounds(_USDC_ADDRESS, 10200, 10200);
    }

    function test_setBadSourceDivergenceFlag_fail_whenDivergenceIsTooSmall()
        public
    {
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.setDeviationBounds(_USDC_ADDRESS, 10010, 10009);
    }

    function test_setBadSourceDivergenceFlag_fail_whenDivergenceIsTooLarge()
        public
    {
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.setDeviationBounds(_USDC_ADDRESS, 10100, 12001);
    }

    function test_setDivergenceFlags_fail_whenCautionEqualToBadSource()
        public
    {
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.setDeviationBounds(_USDC_ADDRESS, 10200, 10200);
    }

    function test_setDivergenceFlags_fail_whenCautionLargerThanBadSource()
        public
    {
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.setDeviationBounds(_USDC_ADDRESS, 10200, 10100);
    }

    function test_setCautionDivergenceFlag_success() public {
        (, uint16 cautionBoundBefore) = oracleManager.assetPricingConfig(_USDC_ADDRESS);
        assertEq(uint256(cautionBoundBefore), 10050);


        oracleManager.setDeviationBounds(_USDC_ADDRESS, 10100, 10200);

        (uint16 badSourceBoundAfter, uint16 cautionBoundAfter) = oracleManager.assetPricingConfig(_USDC_ADDRESS);
        assertEq(uint256(cautionBoundAfter), 10100);
        assertEq(uint256(badSourceBoundAfter), 10200);
    }

    function test_setBadSourceDivergenceFlag_success() public {
        (uint16 badSourceBoundBefore, ) = oracleManager.assetPricingConfig(_USDC_ADDRESS);
        assertEq(uint256(badSourceBoundBefore), 10100);

        oracleManager.setDeviationBounds(_USDC_ADDRESS, 10100, 10150);

        (uint16 badSourceBoundAfter, uint16 cautionBoundAfter) = oracleManager.assetPricingConfig(_USDC_ADDRESS);
        assertEq(uint256(cautionBoundAfter), 10100);
        assertEq(uint256(badSourceBoundAfter), 10150);
    }
}
