// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract SetDeviationBoundsTest is TestBaseOracleManager {

    function setUp() public override {
        super.setUp();

        oracleManager.addAssetPricingAdaptor(_USDC_ADDRESS, address(chainlinkAdaptor), 180, 130, 180, 130);
        oracleManager.addAssetPricingAdaptor(_USDC_ADDRESS, address(dualChainlinkAdaptor), 180, 130, 180, 130);
    }

    function test_setDeviationBounds_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(OracleManager.OracleManager__Unauthorized.selector);
        oracleManager.setDeviationBounds(_USDC_ADDRESS, 100, 100, 100, 100);
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
        oracleManager.setDeviationBounds(_USDC_ADDRESS, 150, 130, 150, 130);
    }

    function test_setDeviationBounds_fail_whenBadSourceIsTooLarge() public {
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        // badSource too large (> MAX_DEVIATION_BOUND = 350).
        oracleManager.setDeviationBounds(_USDC_ADDRESS, 351, 200, 351, 200);
    }

    function test_setDeviationBounds_success_badSourceAtMaximum() public {
        (uint16 badSourceBoundBefore, uint16 cautionBoundBefore , , ) = oracleManager.assetPricingConfig(_USDC_ADDRESS);
        assertEq(uint256(badSourceBoundBefore), 10180);
        assertEq(uint256(cautionBoundBefore), 10130);

        // Should succeed at exactly MAX_DEVIATION_BOUND (350).
        oracleManager.setDeviationBounds(_USDC_ADDRESS, 350, 200, 350, 200);

        (uint16 badSourceBoundAfter, uint16 cautionBoundAfter , , ) = oracleManager.assetPricingConfig(_USDC_ADDRESS);
        assertEq(uint256(badSourceBoundAfter), 10350); // 10000 + 350
        assertEq(uint256(cautionBoundAfter), 10200);   // 10000 + 200
    }

    function test_setDeviationBounds_fail_whenBadSourceIsTooSmall() public {
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        // badSource too small (< MIN_DEVIATION_BOUND = 20).
        oracleManager.setDeviationBounds(_USDC_ADDRESS, 150, 10, 150, 10);
    }

    function test_setDeviationBounds_fail_whenDeltaTooSmall() public {
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.setDeviationBounds(_USDC_ADDRESS, 150, 140, 150, 140);
    }

    function test_setDeviationBounds_fail_whenCautionLargerThanBadSource() public {
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.setDeviationBounds(_USDC_ADDRESS, 130, 150, 130, 150);
    }

    function test_setDeviationBounds_success_cautionInUSD() public {
        (uint16 badSourceBoundBefore, uint16 cautionBoundBefore , , ) = oracleManager.assetPricingConfig(_USDC_ADDRESS);
        // Initial caution from setUp is 130 = stored 10130
        assertEq(uint256(badSourceBoundBefore), 10180);
        assertEq(uint256(cautionBoundBefore), 10130);

        // Update caution to 140 (1.40%), and badSource to 190 (1.90%).
        oracleManager.setDeviationBounds(_USDC_ADDRESS, 190, 140, 190, 140);

        (uint16 badSourceBoundAfter, uint16 cautionBoundAfter , , ) = oracleManager.assetPricingConfig(_USDC_ADDRESS);
        assertEq(uint256(badSourceBoundAfter), 10190);
        assertEq(uint256(cautionBoundAfter), 10140);
    }

    function test_setDeviationBounds_success_badSourceInUSD() public {
        (uint16 badSourceBoundBefore, uint16 cautionBoundBefore , , ) = oracleManager.assetPricingConfig(_USDC_ADDRESS);
        assertEq(uint256(badSourceBoundBefore), 10180);
        assertEq(uint256(cautionBoundBefore), 10130);

        // Update badSource to 150 (1.50%), keep caution at 130 (1.30%)
        oracleManager.setDeviationBounds(_USDC_ADDRESS, 150, 130, 150, 130);

        (uint16 badSourceBoundAfter, uint16 cautionBoundAfter , , ) = oracleManager.assetPricingConfig(_USDC_ADDRESS);
        assertEq(uint256(badSourceBoundAfter), 10150);
        assertEq(uint256(cautionBoundBefore), cautionBoundBefore);
    }

    function test_setDeviationBounds_success_deviationScenarios() public {

        // Set deviation bounds at maximum
        oracleManager.setDeviationBounds(_USDC_ADDRESS, 350, 250, 350, 250);

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

    function test_setDeviationBounds_success_noBadSourceWithNonZeroBounds() public {
        oracleManager.setDeviationBounds(
            _USDC_ADDRESS,
            50,
            20,
            50,
            20
        );

        (, uint256 errorCodeUSD) = oracleManager.getPrice(_USDC_ADDRESS, true, true);
        assertEq(errorCodeUSD, 0, "Should not get BAD_SOURCE with properly set USD bounds");

        (, uint256 errorCodeNative) = oracleManager.getPrice(_USDC_ADDRESS, false, true);
        assertEq(errorCodeNative, 0, "Should not get BAD_SOURCE with properly set Native bounds");

        // Verify both sets of bounds are non-zero
        (uint16 badSourceUSD, uint16 cautionUSD, uint16 badSourceNative, uint16 cautionNative) =
            oracleManager.assetPricingConfig(_USDC_ADDRESS);

        assertTrue(badSourceUSD > 0, "badSourceBoundUSD must be non-zero");
        assertTrue(cautionUSD > 0, "cautionBoundUSD must be non-zero");
        assertTrue(badSourceNative > 0, "badSourceBoundNative must be non-zero");
        assertTrue(cautionNative > 0, "cautionBoundNative must be non-zero");
    }

    // Test native to USD conversion with bounds enforcement
    function test_setDeviationBounds_success_nativeToUSDConversionWithBounds() public {

        // Remove the USD feeds to simulate an asset that only has native feeds
        chainlinkAdaptor.removeAsset(_USDC_ADDRESS);
        dualChainlinkAdaptor.removeAsset(_USDC_ADDRESS);

        // Re-add only the native feeds so adaptors still support USDC natively
        chainlinkAdaptor.addAsset(_USDC_ADDRESS, false, _CHAINLINK_USDC_ETH, 0);
        dualChainlinkAdaptor.addAsset(_USDC_ADDRESS, false, _CHAINLINK_USDC_ETH, 0);

        // Register native asset with OracleManager so conversion can occur
        oracleManager.addAssetPricingAdaptor(
            _ETH_ADDRESS,
            address(chainlinkAdaptor),
            180,
            130,
            180,
            130
        );

        oracleManager.addAssetPricingAdaptor(
            _USDC_ADDRESS,
            address(chainlinkAdaptor),
            200,
            150,
            180,
            130
        );

        oracleManager.addAssetPricingAdaptor(
            _USDC_ADDRESS,
            address(dualChainlinkAdaptor),
            200,
            150,
            180,
            130
        );

        // Verify both sets of bounds are set
        (uint16 badSourceUSD, uint16 cautionUSD, uint16 badSourceNative, uint16 cautionNative) =
            oracleManager.assetPricingConfig(_USDC_ADDRESS);

        assertEq(uint256(badSourceUSD), 10200, "USD bounds MUST be non-zero");
        assertEq(uint256(cautionUSD), 10150, "USD bounds MUST be non-zero");
        assertEq(uint256(badSourceNative), 10180, "Native bounds MUST be non-zero");
        assertEq(uint256(cautionNative), 10130, "Native bounds MUST be non-zero");

        // Test query in native directly
        (uint256 priceNative, uint256 errorCodeNative) = oracleManager.getPrice(_USDC_ADDRESS, false, true);
        assertTrue(priceNative > 0, "Should get valid Native price");
        assertEq(errorCodeNative, 0, "Native query with no deviation should be NO_ERROR");

        // Test conversion ETH to USD
        (uint256 priceUSD, uint256 errorCodeUSD) = oracleManager.getPrice(_USDC_ADDRESS, true, true);
        assertTrue(priceUSD > 0, "Should get valid converted USD price");
        assertEq(errorCodeUSD, 0, "USD query with non-zero USD bounds should be NO_ERROR");

        // Test deviation bounds in native
        (, int256 baseUsdcEth,, ,) = IChainlink(_CHAINLINK_USDC_ETH).latestRoundData();

        MockV3Aggregator mockedUsdcEth = new MockV3Aggregator(18, baseUsdcEth);
        dualChainlinkAdaptor.addAsset(_USDC_ADDRESS, false, address(mockedUsdcEth), 0);

        // Set 1.6% deviation in native
        int256 deviatedUsdcEth = (baseUsdcEth * int256(10160)) / int256(10000);
        mockedUsdcEth.updateAnswer(deviatedUsdcEth);

        (, errorCodeNative) = oracleManager.getPrice(_USDC_ADDRESS, false, true);
        assertEq(errorCodeNative, 1, "1.6% native deviation triggers CAUTION");

        // Test USD bounds when ETH has 1.6% deviation
        (, errorCodeUSD) = oracleManager.getPrice(_USDC_ADDRESS, true, true);
        assertEq(errorCodeUSD, 1, "1.6% Native deviation triggers CAUTION because of the 1.5% USD bounds");

        // Increase deviation to BAD_SOURCE and check native query
        deviatedUsdcEth = (baseUsdcEth * int256(10190)) / int256(10000);
        mockedUsdcEth.updateAnswer(deviatedUsdcEth);
        (, errorCodeNative) = oracleManager.getPrice(_USDC_ADDRESS, false, true);
        assertEq(errorCodeNative, 2, "1.9% Native deviation should trigger BAD_SOURCE");

        // Increase deviation to BAD_SOURCE and check USD query
        deviatedUsdcEth = (baseUsdcEth * int256(10210)) / int256(10000);
        mockedUsdcEth.updateAnswer(deviatedUsdcEth);
        (, errorCodeUSD) = oracleManager.getPrice(_USDC_ADDRESS, true, true);
        assertEq(errorCodeUSD, 2, "2.1% USD deviation should trigger BAD_SOURCE because of the 2.0% USD bounds");
    }

}
