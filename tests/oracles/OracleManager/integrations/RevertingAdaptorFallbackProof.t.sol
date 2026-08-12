// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {
    TestBaseOracleManager
} from "tests/oracles/OracleManager/TestBaseOracleManager.sol";
import {IOracleAdaptor} from "contracts/interfaces/IOracleAdaptor.sol";
import {CAUTION} from "contracts/libraries/ConstantsLib.sol";

contract ConfigurableOracleAdaptor {
    error ConfigurableOracleAdaptor__ForcedRevert();

    address public immutable supportedAsset;
    uint256 public price = 1e18;
    bool public hadError;
    bool public shouldRevert;

    constructor(address asset) {
        supportedAsset = asset;
    }

    function setBehavior(bool hadError_, bool shouldRevert_) external {
        hadError = hadError_;
        shouldRevert = shouldRevert_;
    }

    function adaptorType() external pure returns (uint256) {
        return 1;
    }

    function isSupportedAsset(address asset) external view returns (bool) {
        return asset == supportedAsset;
    }

    function getPrice(address asset, bool inUSD, bool)
        external
        view
        returns (IOracleAdaptor.PricingResult memory)
    {
        if (shouldRevert) {
            revert ConfigurableOracleAdaptor__ForcedRevert();
        }

        if (asset != supportedAsset) {
            return IOracleAdaptor.PricingResult(0, inUSD, true);
        }

        return IOracleAdaptor.PricingResult(price, inUSD, hadError);
    }
}

contract RevertingAdaptorFallbackProof is TestBaseOracleManager {
    function test_dualAdaptorHadErrorUsesHealthyFallback() public {
        (
            ConfigurableOracleAdaptor primary,
            ConfigurableOracleAdaptor secondary
        ) = _configureDualAdaptors();

        primary.setBehavior(true, false);

        (uint256 price, uint256 errorCode) =
            oracleManager.getPrice(_USDC_ADDRESS, true, true);

        assertEq(price, secondary.price());
        assertEq(errorCode, CAUTION);
    }

    function test_dualAdaptorPrimaryRevertPreventsHealthyFallback() public {
        (
            ConfigurableOracleAdaptor primary,
            ConfigurableOracleAdaptor secondary
        ) = _configureDualAdaptors();

        primary.setBehavior(false, true);

        vm.expectRevert(
            ConfigurableOracleAdaptor.ConfigurableOracleAdaptor__ForcedRevert
                .selector
        );
        oracleManager.getPrice(_USDC_ADDRESS, true, true);

        assertEq(secondary.price(), 1e18);
    }

    function test_dualAdaptorSecondaryRevertPreventsHealthyFallback() public {
        (
            ConfigurableOracleAdaptor primary,
            ConfigurableOracleAdaptor secondary
        ) = _configureDualAdaptors();

        secondary.setBehavior(false, true);

        vm.expectRevert(
            ConfigurableOracleAdaptor.ConfigurableOracleAdaptor__ForcedRevert
                .selector
        );
        oracleManager.getPrice(_USDC_ADDRESS, true, true);

        assertEq(primary.price(), 1e18);
    }

    function _configureDualAdaptors()
        internal
        returns (
            ConfigurableOracleAdaptor primary,
            ConfigurableOracleAdaptor secondary
        )
    {
        primary = new ConfigurableOracleAdaptor(_USDC_ADDRESS);
        secondary = new ConfigurableOracleAdaptor(_USDC_ADDRESS);

        oracleManager.addApprovedAdaptor(address(primary));
        oracleManager.addApprovedAdaptor(address(secondary));

        oracleManager.addAssetPricingAdaptor(
            _USDC_ADDRESS, address(primary), 180, 130, 180, 130
        );
        oracleManager.addAssetPricingAdaptor(
            _USDC_ADDRESS, address(secondary), 180, 130, 180, 130
        );
    }
}
