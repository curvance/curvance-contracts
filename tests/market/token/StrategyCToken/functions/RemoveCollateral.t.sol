// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract RemoveCollateralTest is TestBaseStrategyCToken {
    event CollateralUpdated(uint256 shares, bool increased, address account);

    function setUp() public override {
        super.setUp();
        
        _prepareBALRETH(user1, _ONE + _ONE);

        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE + _ONE);
        strategyCBALRETH.depositAsCollateral(_ONE + _ONE, user1);
        vm.stopPrank();
    }

    function test_strategyCTokenRemoveCollateral_fail_whenZeroAmount() public {
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        _removeBalRETHCollateral(0);
    }

    function test_strategyCTokenRemoveCollateral_fail_whenCooldownActive() public {
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__MinimumHoldPeriod.selector
        );

        _removeBalRETHCollateral(_ONE);
    }

    function test_strategyCTokenRemoveCollateral_fail_whenCollateralAmountExceedsCTokens() public {
        vm.expectRevert(
            BaseCToken.BaseCToken__InsufficientLiquidity.selector
        );

        _removeBalRETHCollateral(10e18);
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

        _removeBalRETHCollateral(1.9e18);
    }

    function test_strategyCTokenRemoveCollateral_success() public {
        uint256 balanceBefore = strategyCBALRETH.balanceOf(user1);
        uint256 userCollateral = strategyCBALRETH.collateralPosted(user1);
        uint256 totalCollateral = strategyCBALRETH.marketCollateralPosted();
        uint256 collateralRemoved = _ONE;

        skip(20 minutes);

        vm.expectEmit(true, true, true, true, address(strategyCBALRETH));
        emit CollateralUpdated(collateralRemoved, false, user1);

        _removeBalRETHCollateral(collateralRemoved);

        // Balance should not have changed.
        assertEq(strategyCBALRETH.balanceOf(user1), balanceBefore);

        // User collateral should go up by `collateralRemoved`.
        assertEq(strategyCBALRETH.collateralPosted(user1), userCollateral - collateralRemoved);

        // Market collateral should go up by `collateralRemoved`.
        assertEq(strategyCBALRETH.marketCollateralPosted(), totalCollateral - collateralRemoved);
    }

    function _removeBalRETHCollateral(uint256 shares) internal {
        vm.startPrank(user1);
        strategyCBALRETH.removeCollateral(shares);
        vm.stopPrank();
    }

}
