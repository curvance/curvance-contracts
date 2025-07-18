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

    function test_strategyCTokenRemoveCollateral_fail_whenCollateralAmountExceedsCTokens() public {
        vm.expectRevert(
            BaseCToken.BaseCToken__InsufficientLiquidity.selector
        );

        _removeBalRETHCollateral(10e18);
    }

    function test_strategyCTokenRemoveCollateral_fail_whenCollateralIsRequired() public {
        _prepareDAI(address(this), _ONE + _ONE);
        dai.approve(address(borrowableCDAI), _ONE + _ONE);
        borrowableCDAI.deposit(_ONE, address(this));

        _prepareBALRETH(user1, _ONE + _ONE);

        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE + _ONE);
        strategyCBALRETH.deposit(_ONE + _ONE, user1);
        strategyCBALRETH.postCollateral(_ONE);
        
        borrowableCDAI.borrow(1000e6, user1);
        vm.stopPrank();

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral.selector
        );

        _removeBalRETHCollateral(1.5e18);
    }

    function test_strategyCTokenRemoveCollateral_success() public {
        uint256 balanceBefore = strategyCBALRETH.balanceOf(user1);
        uint256 userCollateral = strategyCBALRETH.collateralPosted(user1);
        uint256 totalCollateral = strategyCBALRETH.marketCollateralPosted();
        uint256 newCollateral = _ONE;

        vm.expectEmit(true, true, true, true, address(strategyCBALRETH));
        emit CollateralUpdated(newCollateral, false, user1);

        _removeBalRETHCollateral(newCollateral);

        // Balance should not have changed.
        assertEq(strategyCBALRETH.balanceOf(user1), balanceBefore);

        // User collateral should go up by `newCollateral`.
        assertEq(strategyCBALRETH.collateralPosted(user1), userCollateral - newCollateral);

        // Market collateral should go up by `newCollateral`.
        assertEq(strategyCBALRETH.marketCollateralPosted(), totalCollateral - newCollateral);
    }

    function _removeBalRETHCollateral(uint256 shares) internal {
        vm.startPrank(user1);
        strategyCBALRETH.removeCollateral(shares);
        vm.stopPrank();
    }

}
