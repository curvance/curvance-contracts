// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract RemoveCollateralForTest is TestBaseStrategyCToken {
    event CollateralUpdated(uint256 shares, bool increased, address account);

    function setUp() public override {
        super.setUp();
        _prepareBALRETH(user1, _ONE + _ONE);

        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE + _ONE);
        strategyCBALRETH.depositAsCollateral(_ONE + _ONE, user1);

        // Approve delegated collateral removal for `user1` by `user2`.
        strategyCBALRETH.setDelegateApproval(user2, true);
        vm.stopPrank();
    }

    function test_strategyCTokenRemoveCollateralFor_fail_whenNotDelegated() public {
        vm.startPrank(user1);
        strategyCBALRETH.setDelegateApproval(user2, false);
        vm.stopPrank();

        vm.expectRevert(PluginDelegable.PluginDelegable__Unauthorized.selector);
        _removeBalRETHCollateralForUser1(0.1e18);
    }

    function test_strategyCTokenRemoveCollateralFor_fail_whenZeroAmount() public {
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        _removeBalRETHCollateralForUser1(0);
    }

    function test_strategyCTokenRemoveCollateralFor_fail_whenCooldownActive() public {
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__MinimumHoldPeriod.selector
        );

        _removeBalRETHCollateralForUser1(_ONE);
    }

    function test_strategyCTokenRemoveCollateralFor_fail_whenCollateralAmountExceedsCTokens() public {
        vm.expectRevert(
            BaseCToken.BaseCToken__InsufficientLiquidity.selector
        );

        _removeBalRETHCollateralForUser1(10e18);
    }

    function test_strategyCTokenRemoveCollateralFor_fail_whenCollateralIsRequired() public {
        _prepareDAI(address(this), 2000e18);
        dai.approve(address(borrowableCDAI), 2000e18);
        borrowableCDAI.deposit(2000e18, address(this));

        vm.startPrank(user1);
        borrowableCDAI.borrow(1000e18, user1);
        vm.stopPrank();

        skip(20 minutes);

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral.selector
        );

        _removeBalRETHCollateralForUser1(1.9e18);
    }

    function test_strategyCTokenRemoveCollateralFor_success() public {
        uint256 balanceBefore = strategyCBALRETH.balanceOf(user1);
        uint256 userCollateral = strategyCBALRETH.collateralPosted(user1);
        uint256 totalCollateral = strategyCBALRETH.marketCollateralPosted();
        uint256 newCollateral = _ONE;

        skip(20 minutes);

        vm.expectEmit(true, true, true, true, address(strategyCBALRETH));
        emit CollateralUpdated(newCollateral, false, user1);

        _removeBalRETHCollateralForUser1(newCollateral);

        // Balance should not have changed.
        assertEq(strategyCBALRETH.balanceOf(user1), balanceBefore);

        // User collateral should go up by `newCollateral`.
        assertEq(strategyCBALRETH.collateralPosted(user1), userCollateral - newCollateral);

        // Market collateral should go up by `newCollateral`.
        assertEq(strategyCBALRETH.marketCollateralPosted(), totalCollateral - newCollateral);
    }

    function _removeBalRETHCollateralForUser1(uint256 shares) internal {
        vm.startPrank(user2);
        strategyCBALRETH.removeCollateralFor(shares, user1);
        vm.stopPrank();
    }

}
