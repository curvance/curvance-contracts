// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBasePredeposit } from "../TestBasePredeposit.sol";
import { Predeposit } from "contracts/misc/Predeposit.sol";

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

        usdc.approve(address(eUSDC), 1000e6);
        balRETH.approve(address(pBALRETH), 1000e18);

        marketManagerIsolated.listToken(address(eUSDC));
        marketManagerIsolated.listToken(address(pBALRETH));

        vm.startPrank(user1);

        usdc.approve(address(predeposit), 100e6);
        balRETH.approve(address(predeposit), 100e18);

        predeposit.deposit(_USDC_ADDRESS, 100e6);
        predeposit.deposit(_BAL_WETH_RETH_ADDRESS, 100e18);

        vm.stopPrank();

        vm.startPrank(manager);

        predeposit.setMigrationConfig(_USDC_ADDRESS, address(eUSDC));
        predeposit.setMigrationConfig(
            _BAL_WETH_RETH_ADDRESS,
            address(pBALRETH)
        );

        vm.stopPrank();

        marketManagerIsolated.updatePositionToken(
            address(pBALRETH),
            7000,
            4000,
            3000,
            200,
            400,
            1000
        );
        address[] memory mTokens = new address[](1);
        mTokens[0] = address(pBALRETH);
        uint256[] memory newCollateralCaps = new uint256[](1);
        newCollateralCaps[0] = 1000000 * 10 ** 18;
        marketManagerIsolated.setCollateralCaps(mTokens, newCollateralCaps);
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

    function test_migrate_success_withPToken_withCollateralize() public {
        skip(1 weeks);

        uint256 underlyingBalance = balRETH.balanceOf(address(pBALRETH));

        assertEq(
            predeposit.balanceOf(user1, _BAL_WETH_RETH_ADDRESS),
            100e18
        );
        assertEq(balRETH.balanceOf(address(predeposit)), 100e18);

        vm.prank(user1);
        pBALRETH.setDelegateApproval(address(predeposit), true);

        vm.prank(user1);

        vm.expectEmit(true, true, true, true);
        emit Migrated(user1, _BAL_WETH_RETH_ADDRESS, 100e18);

        predeposit.migrate(_BAL_WETH_RETH_ADDRESS, 100e18, true);

        assertEq(predeposit.balanceOf(user1, _BAL_WETH_RETH_ADDRESS), 0);
        assertEq(balRETH.balanceOf(address(predeposit)), 0);
        assertEq(balRETH.balanceOf(address(pBALRETH)), underlyingBalance);
        assertEq(pBALRETH.balanceOf(user1), 100e18);
    }

    function test_migrate_success_withPToken_withoutCollateralize() public {
        skip(1 weeks);

        uint256 underlyingBalance = balRETH.balanceOf(address(pBALRETH));

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
        assertEq(balRETH.balanceOf(address(pBALRETH)), underlyingBalance);
        assertEq(pBALRETH.balanceOf(user1), 100e18);
    }

    function test_migrate_success_withEToken() public {
        skip(1 weeks);

        uint256 marketUnderlyingHeld = eUSDC.marketUnderlyingHeld();

        assertEq(predeposit.balanceOf(user1, _USDC_ADDRESS), 100e6);
        assertEq(usdc.balanceOf(address(predeposit)), 100e6);

        vm.prank(user1);

        vm.expectEmit(true, true, true, true);
        emit Migrated(user1, _USDC_ADDRESS, 100e6);

        predeposit.migrate(_USDC_ADDRESS, 100e6, true);

        assertEq(predeposit.balanceOf(user1, _USDC_ADDRESS), 0);
        assertEq(usdc.balanceOf(address(predeposit)), 0);
        assertEq(eUSDC.marketUnderlyingHeld(), marketUnderlyingHeld + 100e6);
        assertEq(eUSDC.balanceOf(user1), 100e6);
    }
}
