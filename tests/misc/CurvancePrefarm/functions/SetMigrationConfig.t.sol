// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseCurvancePrefarm } from "../TestBaseCurvancePrefarm.sol";
import { CurvancePrefarm } from "contracts/misc/CurvancePrefarm.sol";

contract SetMigrationConfigTest is TestBaseCurvancePrefarm {
    function test_setMigrationConfig_fail_whenCallerIsNotManager() public {
        vm.expectRevert(
            CurvancePrefarm.CurvancePrefarm__Unauthorized.selector
        );
        curvancePrefarm.setMigrationConfig(_USDC_ADDRESS, address(dUSDC));
    }

    function test_setMigrationConfig_fail_whenUnderlyingIsNotPrefarmToken()
        public
    {
        vm.prank(manager);

        vm.expectRevert(
            CurvancePrefarm.CurvancePrefarm__InvalidParameters.selector
        );
        curvancePrefarm.setMigrationConfig(_USDC_ADDRESS, address(dDAI));
    }

    function test_setMigrationConfig_fail_whenProtocolTokenIsNotListed()
        public
    {
        vm.prank(manager);

        vm.expectRevert(
            CurvancePrefarm.CurvancePrefarm__InvalidParameters.selector
        );
        curvancePrefarm.setMigrationConfig(_USDC_ADDRESS, address(dUSDC));
    }

    function test_setMigrationConfig_success() public {
        deal(_USDC_ADDRESS, address(this), 1000e6);
        deal(_BAL_WETH_RETH_ADDRESS, address(this), 1000e18);

        usdc.approve(address(dUSDC), 1000e6);
        balRETH.approve(address(cBALRETH), 1000e18);

        marketManager.listToken(address(dUSDC));
        marketManager.listToken(address(cBALRETH));

        (, address mTokenAddress, bool isCToken) = curvancePrefarm.tokenData(
            _USDC_ADDRESS
        );

        assertFalse(isCToken);
        assertEq(mTokenAddress, _ZERO_ADDRESS);

        vm.prank(manager);
        curvancePrefarm.setMigrationConfig(_USDC_ADDRESS, address(dUSDC));

        (, address mTokenAddress, bool isCToken) = curvancePrefarm.tokenData(
            _USDC_ADDRESS
        );

        assertFalse(isCToken);
        assertEq(mTokenAddress, address(dUSDC));

        (, address mTokenAddress, bool isCToken) = curvancePrefarm.tokenData(
            _BAL_WETH_RETH_ADDRESS
        );

        assertFalse(isCToken);
        assertEq(mTokenAddress, _ZERO_ADDRESS);

        vm.prank(manager);
        curvancePrefarm.setMigrationConfig(
            _BAL_WETH_RETH_ADDRESS,
            address(cBALRETH)
        );

        (, address mTokenAddress, bool isCToken) = curvancePrefarm.tokenData(
            _BAL_WETH_RETH_ADDRESS
        );

        assertTrue(isCToken);
        assertEq(mTokenAddress, address(cBALRETH));
    }
}
