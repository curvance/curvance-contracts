// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract RemoveCollateralTest is TestBaseStrategyCToken {
    event CollateralUpdated(uint256 shares, bool increased, address account);

    function setUp() public override {
        super.setUp();
        
        deal(address(LP_wstETH_24Dec2025), user1, _ONE + _ONE);

        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE + _ONE);
        pendleStrategyCTokenSTETH.depositAsCollateral(_ONE + _ONE, user1);
        vm.stopPrank();
    }

    function test_strategyCTokenRemoveCollateral_fail_whenZeroAmount() public {
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        _removePendleStrategyCTokenSTETHCollateral(0);
    }

    function test_strategyCTokenRemoveCollateral_fail_whenCooldownActive() public {
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__MinimumHoldPeriod.selector
        );

        _removePendleStrategyCTokenSTETHCollateral(_ONE);
    }

    function test_strategyCTokenRemoveCollateral_fail_whenCollateralAmountExceedsCTokens() public {
        vm.expectRevert(
            BaseCToken.BaseCToken__InsufficientLiquidity.selector
        );

        _removePendleStrategyCTokenSTETHCollateral(10e18);
    }

    function test_strategyCTokenRemoveCollateral_fail_whenCollateralIsRequired() public {
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

        _removePendleStrategyCTokenSTETHCollateral(1.9e18);
    }

    function test_strategyCTokenRemoveCollateral_success() public {
        uint256 balanceBefore = pendleStrategyCTokenSTETH.balanceOf(user1);
        uint256 userCollateral = pendleStrategyCTokenSTETH.collateralPosted(user1);
        uint256 totalCollateral = pendleStrategyCTokenSTETH.marketCollateralPosted();
        uint256 collateralRemoved = _ONE;

        skip(20 minutes);

        vm.expectEmit(true, true, true, true, address(pendleStrategyCTokenSTETH));
        emit CollateralUpdated(collateralRemoved, false, user1);

        _removePendleStrategyCTokenSTETHCollateral(collateralRemoved);

        // Balance should not have changed.
        assertEq(pendleStrategyCTokenSTETH.balanceOf(user1), balanceBefore);

        // User collateral should go up by `collateralRemoved`.
        assertEq(pendleStrategyCTokenSTETH.collateralPosted(user1), userCollateral - collateralRemoved);

        // Market collateral should go up by `collateralRemoved`.
        assertEq(pendleStrategyCTokenSTETH.marketCollateralPosted(), totalCollateral - collateralRemoved);
    }

    function _removePendleStrategyCTokenSTETHCollateral(uint256 shares) internal {
        vm.startPrank(user1);
        pendleStrategyCTokenSTETH.removeCollateral(shares);
        vm.stopPrank();
    }

}
