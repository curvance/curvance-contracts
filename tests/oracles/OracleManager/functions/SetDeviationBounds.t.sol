// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";

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

    function test_setDeviationBounds_fail_whenOnlyOneAdaptor() public {
        oracleManager.removeAssetPricingAdaptor(
            _USDC_ADDRESS,
            address(chainlinkAdaptor)
        );

        // Reverts due only 1 configured adaptor attacked to `_USDC_ADDRESS`.
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.setDeviationBounds(_USDC_ADDRESS, true, 150, 130);
    }

    function test_setDeviationBounds_fail_whenBadSourceIsTooLarge() public {
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        // badSource too large (> MAX_DEVIATION_BOUND = 350).
        oracleManager.setDeviationBounds(_USDC_ADDRESS, true, 351, 200);
    }

    function test_setDeviationBounds_success_badSourceAtMaximum() public {
        (uint16 badSourceBoundBefore, uint16 cautionBoundBefore , , ) = oracleManager.assetPricingConfig(_USDC_ADDRESS);
        assertEq(uint256(badSourceBoundBefore), 10180);
        assertEq(uint256(cautionBoundBefore), 10130);

        // Should succeed at exactly MAX_DEVIATION_BOUND (350).
        oracleManager.setDeviationBounds(_USDC_ADDRESS, true, 350, 200);

        (uint16 badSourceBoundAfter, uint16 cautionBoundAfter , , ) = oracleManager.assetPricingConfig(_USDC_ADDRESS);
        assertEq(uint256(badSourceBoundAfter), 10350); // 10000 + 350
        assertEq(uint256(cautionBoundAfter), 10200);   // 10000 + 200
    }

    function test_setDeviationBounds_fail_whenBadSourceIsTooSmall() public {
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        // badSource too small (< MIN_DEVIATION_BOUND = 20).
        oracleManager.setDeviationBounds(_USDC_ADDRESS, true, 150, 10);
    }

    function test_setDeviationBounds_fail_whenDeltaTooSmall() public {
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.setDeviationBounds(_USDC_ADDRESS, true, 150, 140);
    }

    function test_setDeviationBounds_fail_whenCautionLargerThanBadSource() public {
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.setDeviationBounds(_USDC_ADDRESS, true, 130, 150);
    }

    function test_setDeviationBounds_success_cautionInUSD() public {
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

    function test_setDeviationBounds_success_badSourceInUSD() public {
        (uint16 badSourceBoundBefore, uint16 cautionBoundBefore , , ) = oracleManager.assetPricingConfig(_USDC_ADDRESS);
        assertEq(uint256(badSourceBoundBefore), 10180);
        assertEq(uint256(cautionBoundBefore), 10130);

        // Update badSource to 150 (1.50%), keep caution at 130 (1.30%)
        oracleManager.setDeviationBounds(_USDC_ADDRESS, true, 150, 130);

        (uint16 badSourceBoundAfter, uint16 cautionBoundAfter , , ) = oracleManager.assetPricingConfig(_USDC_ADDRESS);
        assertEq(uint256(badSourceBoundAfter), 10150);
        assertEq(uint256(cautionBoundBefore), cautionBoundBefore);
    }

    function test_setDeviationBounds_success_deviationScenarios() public {

        // Set deviation bounds at maximum
        oracleManager.setDeviationBounds(_USDC_ADDRESS, true, 350, 250);

        // Get the base USDC price from Chainlink
        (, int256 baseUsdcPrice, , , ) = IChainlink(_CHAINLINK_USDC_USD).latestRoundData();

        // Create a mock feed to simulate a deviation
        MockV3Aggregator mockedUsdc = new MockV3Aggregator(8, baseUsdcPrice);
        dualChainlinkAdaptor.addAsset(_USDC_ADDRESS, true, address(mockedUsdc), 0);

        // Test at 3.4% deviation (should trigger CAUTION not BAD_SOURCE)
        int256 deviatedPrice = (baseUsdcPrice * int256(10340)) / int256(10000);
        mockedUsdc.updateAnswer(deviatedPrice);

        (, uint256 errorCode) = oracleManager.getPrice(_USDC_ADDRESS, true, true);
        // errorCode should be 1 (CAUTION), not 2 (BAD_SOURCE)
        assertEq(errorCode, 1, "3.4% deviation should trigger CAUTION");

        // Test at 3.5% deviation (right at the boundary, should still not trigger BAD_SOURCE)
        deviatedPrice = (baseUsdcPrice * int256(10350)) / int256(10000);
        mockedUsdc.updateAnswer(deviatedPrice);

        // errorCode should still be 1 (CAUTION), not 2 (BAD_SOURCE) at exactly 3.5%
        (, errorCode) = oracleManager.getPrice(_USDC_ADDRESS, true, true);
        assertEq(errorCode, 1, "3.5% deviation should trigger CAUTION");

        // Test at 3.6% deviation (should now trigger BAD_SOURCE)
        deviatedPrice = (baseUsdcPrice * int256(10360)) / int256(10000);
        mockedUsdc.updateAnswer(deviatedPrice);

        // errorCode should be 2 (BAD_SOURCE)
        (, errorCode) = oracleManager.getPrice(_USDC_ADDRESS, true, true);
        assertEq(errorCode, 2, "3.6% deviation should trigger BAD_SOURCE");

        // Test at 2.4% deviation (should be within bounds, no error)
        deviatedPrice = (baseUsdcPrice * int256(10240)) / int256(10000);
        mockedUsdc.updateAnswer(deviatedPrice);

        (, errorCode) = oracleManager.getPrice(_USDC_ADDRESS, true, true);
        assertEq(errorCode, 0, "2.4% deviation should not trigger any error");
    }
}
