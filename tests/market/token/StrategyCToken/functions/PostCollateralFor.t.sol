// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";
import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract PostCollateralForTest is TestBaseStrategyCToken {
    event CollateralUpdated(uint256 shares, bool increased, address account);

    function setUp() public override {
        super.setUp();
        
        _prepareBALRETH(user1, _ONE + _ONE);

        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE + _ONE);
        strategyCBALRETH.deposit(_ONE + _ONE, user1);

        // Approve delegated collateral posting for `user1` by `user2`.
        strategyCBALRETH.setDelegateApproval(user2, true);
        vm.stopPrank();

        _prepareBALRETH(user1, _ONE + _ONE);
    }

    function test_strategyCTokenPostCollateralFor_fail_whenNotDelegated() public {
        vm.startPrank(user1);
        strategyCBALRETH.setDelegateApproval(user2, false);
        vm.stopPrank();

        vm.expectRevert(PluginDelegable.PluginDelegable__Unauthorized.selector);
        _postBalRETHCollateralForUser1(0.1e18);
    }

    function test_strategyCTokenPostCollateralFor_fail_whenCollateralizationIsNotAllowed() public {
        marketManagerIsolated.setCollateralizationPaused(address(strategyCBALRETH), true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        _postBalRETHCollateralForUser1(0.1e18);
    }

    function test_strategyCTokenPostCollateralFor_fail_whenZeroAmount() public {
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        _postBalRETHCollateralForUser1(0);
    }

    function test_strategyCTokenPostCollateralFor_fail_whenCollateralAmountExceedsCTokens() public {
        vm.expectRevert(
            BaseCToken.BaseCToken__InsufficientLiquidity.selector
        );

        _postBalRETHCollateralForUser1(10e18);
    }

    function test_strategyCTokenPostCollateralFor_fail_whenCollateralAmountExceedsCollateralCap() public {
        _setCTokenConfigBasic(address(strategyCBALRETH), 1, 0);

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__CapReached.selector
        );

        _postBalRETHCollateralForUser1(_ONE);
    }

    function test_strategyCTokenPostCollateralFor_success() public {
        uint256 balanceBefore = strategyCBALRETH.balanceOf(user1);
        uint256 userCollateral = strategyCBALRETH.collateralPosted(user1);
        uint256 totalCollateral = strategyCBALRETH.marketCollateralPosted();

        vm.expectEmit(true, true, true, true, address(strategyCBALRETH));
        emit CollateralUpdated(_ONE, true, user1);

        uint256 newCollateral = _ONE;

        _postBalRETHCollateralForUser1(newCollateral);

        // Balance should not have changed.
        assertEq(strategyCBALRETH.balanceOf(user1), balanceBefore);

        // User collateral should go up by `newCollateral`.
        assertEq(strategyCBALRETH.collateralPosted(user1), userCollateral + newCollateral);

        // Market collateral should go up by `newCollateral`.
        assertEq(strategyCBALRETH.marketCollateralPosted(), totalCollateral + newCollateral);
    }

    function _postBalRETHCollateralForUser1(uint256 shares) internal {
        vm.startPrank(user2);
        strategyCBALRETH.postCollateralFor(shares, user1);
        vm.stopPrank();
    }

}
