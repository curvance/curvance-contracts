// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract RemoveCollateralForTest is TestBaseStrategyCToken {
    event CollateralUpdated(uint256 shares, bool increased, address account);

    function setUp() public override {
        super.setUp();
        
        deal(address(LP_wstETH_24Dec2025), user1, _ONE + _ONE);

        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE + _ONE);
        pendleStrategyCTokenSTETH.depositAsCollateral(_ONE + _ONE, user1);

        // Approve delegated collateral removal for `user1` by `user2`.
        pendleStrategyCTokenSTETH.setDelegateApproval(user2, true);
        vm.stopPrank();
    }

    function test_strategyCTokenRemoveCollateralFor_fail_whenNotDelegated() public {
        vm.startPrank(user1);
        pendleStrategyCTokenSTETH.setDelegateApproval(user2, false);
        vm.stopPrank();

        vm.expectRevert(PluginDelegable.PluginDelegable__Unauthorized.selector);
        _removePendleStrategyCTokenSTETHCollateralForUser1(0.1e18);
    }

    function test_strategyCTokenRemoveCollateralFor_fail_whenZeroAmount() public {
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        _removePendleStrategyCTokenSTETHCollateralForUser1(0);
    }

    function test_strategyCTokenRemoveCollateralFor_fail_whenCooldownActive() public {
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__MinimumHoldPeriod.selector
        );

        _removePendleStrategyCTokenSTETHCollateralForUser1(_ONE);
    }

    function test_strategyCTokenRemoveCollateralFor_fail_whenCollateralAmountExceedsCTokens() public {
        vm.expectRevert(
            BaseCToken.BaseCToken__InsufficientLiquidity.selector
        );

        _removePendleStrategyCTokenSTETHCollateralForUser1(10e18);
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

        _removePendleStrategyCTokenSTETHCollateralForUser1(1.9e18);
    }

    function test_strategyCTokenRemoveCollateralFor_success() public {
        uint256 balanceBefore = pendleStrategyCTokenSTETH.balanceOf(user1);
        uint256 userCollateral = pendleStrategyCTokenSTETH.collateralPosted(user1);
        uint256 totalCollateral = pendleStrategyCTokenSTETH.marketCollateralPosted();
        uint256 collateralRemoved = _ONE;

        skip(20 minutes);

        vm.expectEmit(true, true, true, true, address(pendleStrategyCTokenSTETH));
        emit CollateralUpdated(collateralRemoved, false, user1);

        _removePendleStrategyCTokenSTETHCollateralForUser1(collateralRemoved);

        // Balance should not have changed.
        assertEq(pendleStrategyCTokenSTETH.balanceOf(user1), balanceBefore);

        // User collateral should go up by `collateralRemoved`.
        assertEq(pendleStrategyCTokenSTETH.collateralPosted(user1), userCollateral - collateralRemoved);

        // Market collateral should go up by `collateralRemoved`.
        assertEq(pendleStrategyCTokenSTETH.marketCollateralPosted(), totalCollateral - collateralRemoved);
    }

    function _removePendleStrategyCTokenSTETHCollateralForUser1(uint256 shares) internal {
        vm.startPrank(user2);
        pendleStrategyCTokenSTETH.removeCollateralFor(shares, user1);
        vm.stopPrank();
    }

}
