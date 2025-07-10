// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBasePredeposit } from "../TestBasePredeposit.sol";
import { Predeposit } from "contracts/misc/Predeposit.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract MigrateTest is TestBasePredeposit {
    event Migrated(address user, address token, uint256 amount);

    function setUp() public override {
        super.setUp();

        _prepareUSDC(address(this), 1000e6);
        _prepareBALRETH(address(this), 1000e18);
        _prepareUSDC(user1, 100e6);
        _prepareBALRETH(user1, 100e18);

        address[] memory newPredepositTokens = new address[](1);
        newPredepositTokens[0] = _BAL_WETH_RETH_ADDRESS;

        vm.startPrank(manager);
        predeposit.addPredepositTokens(newPredepositTokens);
        vm.stopPrank();

        usdc.approve(address(borrowableCUSDC), 1000e6);
        balRETH.approve(address(strategyCBALRETH), 1000e18);

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        vm.startPrank(user1);

        usdc.approve(address(predeposit), 100e6);
        balRETH.approve(address(predeposit), 100e18);

        predeposit.deposit(_USDC_ADDRESS, 100e6);
        predeposit.deposit(_BAL_WETH_RETH_ADDRESS, 100e18);

        vm.stopPrank();

        vm.startPrank(manager);

        predeposit.setMigrationConfig(_USDC_ADDRESS, address(borrowableCUSDC));
        predeposit.setMigrationConfig(
            _BAL_WETH_RETH_ADDRESS,
            address(strategyCBALRETH)
        );

        vm.stopPrank();

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(strategyCBALRETH);
        tokenConfig.collRatio = 7000;
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.minEffectiveCloseFactor = 2000;
        tokenConfig.maxEffectiveCloseFactor = 5000;
        tokenConfig.baseCFactor = 1000;
        tokenConfig.collateralCap = 100_000e18;
        tokenConfig.debtCap = 0;

        marketManagerIsolated.updateTokenConfig(tokenConfig);

        tokenConfig.cToken = address(borrowableCUSDC);
        tokenConfig.debtCap = 100_000e6;
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_migrate_fail_whenMigrationIsNotStarted() public {
        vm.expectRevert(
            Predeposit.Predeposit__MigrationNotPossible.selector
        );
        predeposit.migrate(_USDC_ADDRESS, 100e6, true);
    }

    function test_migrate_fail_whenExceedsDepositedAmount() public {
        skip(1 weeks);

        vm.prank(user1);

        vm.expectRevert(
            Predeposit.Predeposit__InvalidParameters.selector
        );
        predeposit.migrate(_USDC_ADDRESS, 100e6 + 1, true);
    }

    function test_migrate_fail_whenProtocolTokenIsNotConfigured() public {
        _prepareDAI(user1, 100e18);

        vm.startPrank(user1);

        dai.approve(address(predeposit), 100e18);

        predeposit.deposit(_DAI_ADDRESS, 100e18);

        skip(1 weeks);

        vm.expectRevert(
            Predeposit.Predeposit__MigrationNotPossible.selector
        );
        predeposit.migrate(_DAI_ADDRESS, 100e18, true);

        vm.stopPrank();
    }

    function test_migrate_success_withStrategyCToken_withCollateralize() public {
        skip(1 weeks);

        uint256 underlyingBalance = balRETH.balanceOf(address(strategyCBALRETH));

        assertEq(
            predeposit.balanceOf(user1, _BAL_WETH_RETH_ADDRESS),
            100e18
        );
        assertEq(balRETH.balanceOf(address(predeposit)), 100e18);

        vm.prank(user1);
        strategyCBALRETH.setDelegateApproval(address(predeposit), true);

        vm.prank(user1);

        vm.expectEmit(true, true, true, true);
        emit Migrated(user1, _BAL_WETH_RETH_ADDRESS, 100e18);

        predeposit.migrate(_BAL_WETH_RETH_ADDRESS, 100e18, true);

        assertEq(predeposit.balanceOf(user1, _BAL_WETH_RETH_ADDRESS), 0);
        assertEq(balRETH.balanceOf(address(predeposit)), 0);
        assertEq(balRETH.balanceOf(address(strategyCBALRETH)), underlyingBalance);
        assertEq(strategyCBALRETH.balanceOf(user1), 100e18);
    }

    function test_migrate_success_withStrategyCToken_withoutCollateralize() public {
        skip(1 weeks);

        uint256 underlyingBalance = balRETH.balanceOf(address(strategyCBALRETH));

        assertEq(
            predeposit.balanceOf(user1, _BAL_WETH_RETH_ADDRESS),
            100e18
        );
        assertEq(balRETH.balanceOf(address(predeposit)), 100e18);

        vm.prank(user1);

        vm.expectEmit(true, true, true, true);
        emit Migrated(user1, _BAL_WETH_RETH_ADDRESS, 100e18);

        predeposit.migrate(_BAL_WETH_RETH_ADDRESS, 100e18, false);

        assertEq(predeposit.balanceOf(user1, _BAL_WETH_RETH_ADDRESS), 0);
        assertEq(balRETH.balanceOf(address(predeposit)), 0);
        assertEq(balRETH.balanceOf(address(strategyCBALRETH)), underlyingBalance);
        assertEq(strategyCBALRETH.balanceOf(user1), 100e18);
    }

    function test_migrate_success_withBorrowableCTokenWithCollateralize() public {
        skip(1 weeks);

        uint256 marketUnderlyingHeld = borrowableCUSDC.assetsHeld();

        assertEq(predeposit.balanceOf(user1, _USDC_ADDRESS), 100e6);
        assertEq(usdc.balanceOf(address(predeposit)), 100e6);

        vm.startPrank(user1);
        borrowableCUSDC.setDelegateApproval(address(predeposit), true);

        vm.expectEmit(true, true, true, true);
        emit Migrated(user1, _USDC_ADDRESS, 100e6);

        predeposit.migrate(_USDC_ADDRESS, 100e6, true);

        vm.stopPrank();

        assertEq(predeposit.balanceOf(user1, _USDC_ADDRESS), 0);
        assertEq(usdc.balanceOf(address(predeposit)), 0);
        assertEq(borrowableCUSDC.assetsHeld(), marketUnderlyingHeld + 100e6);
        assertEq(borrowableCUSDC.balanceOf(user1), 100e6);
    }

    function test_migrate_success_withBorrowableCTokenWithoutCollateralize() public {
        skip(1 weeks);

        uint256 marketUnderlyingHeld = borrowableCUSDC.assetsHeld();

        assertEq(predeposit.balanceOf(user1, _USDC_ADDRESS), 100e6);
        assertEq(usdc.balanceOf(address(predeposit)), 100e6);

        vm.startPrank(user1);
        
        vm.expectEmit(true, true, true, true);
        emit Migrated(user1, _USDC_ADDRESS, 100e6);

        predeposit.migrate(_USDC_ADDRESS, 100e6, false);

        vm.stopPrank();

        assertEq(predeposit.balanceOf(user1, _USDC_ADDRESS), 0);
        assertEq(usdc.balanceOf(address(predeposit)), 0);
        assertEq(borrowableCUSDC.assetsHeld(), marketUnderlyingHeld + 100e6);
        assertEq(borrowableCUSDC.balanceOf(user1), 100e6);
    }
}
