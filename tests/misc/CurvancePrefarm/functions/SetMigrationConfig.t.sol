// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseCurvancePrefarm } from "../TestBaseCurvancePrefarm.sol";
import { CurvancePrefarm } from "contracts/misc/CurvancePrefarm.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract SetMigrationConfigTest is TestBaseCurvancePrefarm {
    function test_setMigrationConfig_fail_whenCallerIsNotManager() public {
        vm.expectRevert(
            CurvancePrefarm.CurvancePrefarm__Unauthorized.selector
        );
        curvancePrefarm.setMigrationConfig(_USDC_ADDRESS, address(eUSDC));
    }

    function test_setMigrationConfig_fail_whenTokenIsNotApproved() public {
        curvancePrefarm = new CurvancePrefarm(
            ICentralRegistry(address(centralRegistry)),
            manager,
            block.timestamp + 1 weeks
        );

        vm.prank(manager);

        vm.expectRevert(
            CurvancePrefarm.CurvancePrefarm__InvalidParameters.selector
        );
        curvancePrefarm.setMigrationConfig(_USDC_ADDRESS, address(eUSDC));
    }

    function test_setMigrationConfig_fail_whenUnderlyingIsNotPrefarmToken()
        public
    {
        vm.prank(manager);

        vm.expectRevert(
            CurvancePrefarm.CurvancePrefarm__InvalidParameters.selector
        );
        curvancePrefarm.setMigrationConfig(_USDC_ADDRESS, address(eDAI));
    }

    function test_setMigrationConfig_fail_whenProtocolTokenIsNotListed()
        public
    {
        vm.prank(manager);

        vm.expectRevert(
            CurvancePrefarm.CurvancePrefarm__InvalidParameters.selector
        );
        curvancePrefarm.setMigrationConfig(_USDC_ADDRESS, address(eUSDC));
    }

    function test_setMigrationConfig_success() public {
        deal(_USDC_ADDRESS, address(this), 1000e6);
        deal(_BAL_WETH_RETH_ADDRESS, address(this), 1000e18);

        usdc.approve(address(eUSDC), 1000e6);
        balRETH.approve(address(pBALRETH), 1000e18);

        marketManager.listToken(address(eUSDC));
        marketManager.listToken(address(pBALRETH));

        (, address mTokenAddress, bool isPToken) = curvancePrefarm.tokenData(
            _USDC_ADDRESS
        );

        assertFalse(isPToken);
        assertEq(mTokenAddress, _ZERO_ADDRESS);

        vm.prank(manager);
        curvancePrefarm.setMigrationConfig(_USDC_ADDRESS, address(eUSDC));

        (, mTokenAddress, isPToken) = curvancePrefarm.tokenData(_USDC_ADDRESS);

        assertFalse(isPToken);
        assertEq(mTokenAddress, address(eUSDC));

        (, mTokenAddress, isPToken) = curvancePrefarm.tokenData(
            _BAL_WETH_RETH_ADDRESS
        );

        assertFalse(isPToken);
        assertEq(mTokenAddress, _ZERO_ADDRESS);

        address[] memory newPrefarmTokens = new address[](1);
        newPrefarmTokens[0] = _BAL_WETH_RETH_ADDRESS;

        vm.prank(manager);
        curvancePrefarm.addPrefarmTokens(newPrefarmTokens);

        vm.prank(manager);
        curvancePrefarm.setMigrationConfig(
            _BAL_WETH_RETH_ADDRESS,
            address(pBALRETH)
        );

        (, mTokenAddress, isPToken) = curvancePrefarm.tokenData(
            _BAL_WETH_RETH_ADDRESS
        );

        assertTrue(isPToken);
        assertEq(mTokenAddress, address(pBALRETH));
    }
}
