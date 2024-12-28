// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseCurvancePrefarm } from "../TestBaseCurvancePrefarm.sol";
import { CurvancePrefarm } from "contracts/misc/CurvancePrefarm.sol";

contract MigrateTest is TestBaseCurvancePrefarm {
    event Migrated(address user, address token, uint256 amount);

    function setUp() public override {
        super.setUp();

        _prepareUSDC(address(this), 1000e6);
        _prepareBALRETH(address(this), 1000e18);
        _prepareUSDC(user1, 100e6);
        _prepareBALRETH(user1, 100e18);

        address[] memory newPrefarmTokens = new address[](1);
        newPrefarmTokens[0] = _BAL_WETH_RETH_ADDRESS;

        vm.startPrank(manager);
        curvancePrefarm.addPrefarmTokens(newPrefarmTokens);
        vm.stopPrank();

        usdc.approve(address(eUSDC), 1000e6);
        balRETH.approve(address(pBALRETH), 1000e18);

        marketManager.listToken(address(eUSDC));
        marketManager.listToken(address(pBALRETH));

        vm.startPrank(user1);

        usdc.approve(address(curvancePrefarm), 100e6);
        balRETH.approve(address(curvancePrefarm), 100e18);

        curvancePrefarm.deposit(_USDC_ADDRESS, 100e6);
        curvancePrefarm.deposit(_BAL_WETH_RETH_ADDRESS, 100e18);

        vm.stopPrank();

        vm.startPrank(manager);

        curvancePrefarm.setMigrationConfig(_USDC_ADDRESS, address(eUSDC));
        curvancePrefarm.setMigrationConfig(
            _BAL_WETH_RETH_ADDRESS,
            address(pBALRETH)
        );

        vm.stopPrank();
    }

    function test_migrate_fail_whenMigrationIsNotStarted() public {
        vm.expectRevert(
            CurvancePrefarm.CurvancePrefarm__MigrationNotPossible.selector
        );
        curvancePrefarm.migrate(_USDC_ADDRESS, 100e6, true);
    }

    function test_migrate_fail_whenExceedsDepositedAmount() public {
        skip(1 weeks);

        vm.prank(user1);

        vm.expectRevert(
            CurvancePrefarm.CurvancePrefarm__InvalidParameters.selector
        );
        curvancePrefarm.migrate(_USDC_ADDRESS, 100e6 + 1, true);
    }

    function test_migrate_fail_whenProtocolTokenIsNotConfigured() public {
        _prepareDAI(user1, 100e18);

        vm.startPrank(user1);

        dai.approve(address(curvancePrefarm), 100e18);

        curvancePrefarm.deposit(_DAI_ADDRESS, 100e18);

        skip(1 weeks);

        vm.expectRevert(
            CurvancePrefarm.CurvancePrefarm__MigrationNotPossible.selector
        );
        curvancePrefarm.migrate(_DAI_ADDRESS, 100e18, true);

        vm.stopPrank();
    }

    function test_migrate_success_withPToken_withCollateralize() public {
        skip(1 weeks);

        uint256 underlyingBalance = balRETH.balanceOf(address(pBALRETH));

        assertEq(
            curvancePrefarm.balanceOf(user1, _BAL_WETH_RETH_ADDRESS),
            100e18
        );
        assertEq(balRETH.balanceOf(address(curvancePrefarm)), 100e18);

        vm.prank(user1);

        vm.expectEmit(true, true, true, true);
        emit Migrated(user1, _BAL_WETH_RETH_ADDRESS, 100e18);

        curvancePrefarm.migrate(_BAL_WETH_RETH_ADDRESS, 100e18, true);

        assertEq(curvancePrefarm.balanceOf(user1, _BAL_WETH_RETH_ADDRESS), 0);
        assertEq(balRETH.balanceOf(address(curvancePrefarm)), 0);
        assertEq(balRETH.balanceOf(address(pBALRETH)), underlyingBalance);
        assertEq(pBALRETH.balanceOf(user1), 100e18);
    }

    function test_migrate_success_withPToken_withoutCollateralize() public {
        skip(1 weeks);

        uint256 underlyingBalance = balRETH.balanceOf(address(pBALRETH));

        assertEq(
            curvancePrefarm.balanceOf(user1, _BAL_WETH_RETH_ADDRESS),
            100e18
        );
        assertEq(balRETH.balanceOf(address(curvancePrefarm)), 100e18);

        vm.prank(user1);

        vm.expectEmit(true, true, true, true);
        emit Migrated(user1, _BAL_WETH_RETH_ADDRESS, 100e18);

        curvancePrefarm.migrate(_BAL_WETH_RETH_ADDRESS, 100e18, false);

        assertEq(curvancePrefarm.balanceOf(user1, _BAL_WETH_RETH_ADDRESS), 0);
        assertEq(balRETH.balanceOf(address(curvancePrefarm)), 0);
        assertEq(balRETH.balanceOf(address(pBALRETH)), underlyingBalance);
        assertEq(pBALRETH.balanceOf(user1), 100e18);
    }

    function test_migrate_success_withEToken() public {
        skip(1 weeks);

        uint256 marketUnderlyingHeld = eUSDC.marketUnderlyingHeld();

        assertEq(curvancePrefarm.balanceOf(user1, _USDC_ADDRESS), 100e6);
        assertEq(usdc.balanceOf(address(curvancePrefarm)), 100e6);

        vm.prank(user1);

        vm.expectEmit(true, true, true, true);
        emit Migrated(user1, _USDC_ADDRESS, 100e6);

        curvancePrefarm.migrate(_USDC_ADDRESS, 100e6, true);

        assertEq(curvancePrefarm.balanceOf(user1, _USDC_ADDRESS), 0);
        assertEq(usdc.balanceOf(address(curvancePrefarm)), 0);
        assertEq(eUSDC.marketUnderlyingHeld(), marketUnderlyingHeld + 100e6);
        assertEq(eUSDC.balanceOf(user1), 100e6);
    }
}
