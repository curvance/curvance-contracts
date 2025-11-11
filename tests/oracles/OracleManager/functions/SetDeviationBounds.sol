// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";

contract SetDeviationBoundsTest is TestBaseOracleManager {

    function setUp() public override {
        super.setUp();

        oracleManager.addAssetPricingAdaptor(_USDC_ADDRESS, address(chainlinkAdaptor), true, 180, 130);
        oracleManager.addAssetPricingAdaptor(_USDC_ADDRESS, address(dualChainlinkAdaptor), true, 180, 130);
    }

    function test_setDeviationBounds_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(OracleManager.OracleManager__Unauthorized.selector);
        oracleManager.setDeviationBounds(_USDC_ADDRESS, true, 100, 100);
    }

    function test_setDeviationBounds_fail_whenDeviationIsTooSmall() public {
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.setDeviationBounds(_USDC_ADDRESS, true, 1, 100);
    }

    function test_setDeviationBounds_fail_whenDeviationIsTooLarge() public {
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        // badSource too large (> MAX_DEVIATION_BOUND = 300).
        oracleManager.setDeviationBounds(_USDC_ADDRESS, true, 301, 200);
    }

    function test_setDeviationBounds_fail_whenDeviationIsTooSmall() public {
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.setDeviationBounds(_USDC_ADDRESS, true, 129, 130);
    }

    function test_setDeviationBounds_fail_whenDeviationIsTooLarge() public {
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        // badSource above MAX should revert
        oracleManager.setDeviationBounds(_USDC_ADDRESS, true, 301, 130);
    }

    function test_setDeviationBounds_fail_whenCautionEqualToBadSource() public {
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.setDeviationBounds(_USDC_ADDRESS, true, 150, 150);
    }

    function test_setDeviationBounds_fail_whenCautionLargerThanBadSource() public {
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.setDeviationBounds(_USDC_ADDRESS, true, 130, 150);
    }

    function test_setDeviationBounds_Caution_USD_success() public {
        (uint16 badSourceBoundBefore, uint16 cautionBoundBefore , , ) = oracleManager.assetPricingConfig(_USDC_ADDRESS);
        // Initial caution from setUp is 130 = stored 10130
        assertEq(uint256(badSourceBoundBefore), 10180);
        assertEq(uint256(cautionBoundBefore), 10130);

        // Update caution to 140 (1.40%), and badSource to 190 (1.90%).
        oracleManager.setDeviationBounds(_USDC_ADDRESS, true, 190, 140);

        (uint16 badSourceBoundAfter, uint16 cautionBoundAfter , , ) = oracleManager.assetPricingConfig(_USDC_ADDRESS);
        assertEq(uint256(badSourceBoundAfter), 10190);
        assertEq(uint256(cautionBoundAfter), 10140);
    }

    function test_setDeviationBounds_BadSource_USD_success() public {
        (uint16 badSourceBoundBefore, uint16 cautionBoundBefore , , ) = oracleManager.assetPricingConfig(_USDC_ADDRESS);
        assertEq(uint256(badSourceBoundBefore), 10180);
        assertEq(uint256(cautionBoundBefore), 10130);

        // Update badSource to 150 (1.50%), keep caution at 130 (1.30%)
        oracleManager.setDeviationBounds(_USDC_ADDRESS, true, 150, 130);

        (uint16 badSourceBoundAfter, uint16 cautionBoundAfter , , ) = oracleManager.assetPricingConfig(_USDC_ADDRESS);
        assertEq(uint256(badSourceBoundAfter), 10150);
        assertEq(uint256(cautionBoundAfter), cautionBoundBefore);
    }
}
