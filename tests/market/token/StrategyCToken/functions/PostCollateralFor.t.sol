// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";
import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract PostCollateralForTest is TestBaseStrategyCToken {
    event CollateralUpdated(uint256 shares, bool increased, address account);

    function setUp() public override {
        super.setUp();
        
        deal(address(LP_wstETH_24Dec2025), user1, _ONE + _ONE);

        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE + _ONE);
        pendleStrategyCTokenSTETH.deposit(_ONE + _ONE, user1);

        // Approve delegated collateral posting for `user1` by `user2`.
        pendleStrategyCTokenSTETH.setDelegateApproval(user2, true);
        vm.stopPrank();

        deal(address(LP_wstETH_24Dec2025), user1, _ONE + _ONE);
    }

    function test_strategyCTokenPostCollateralFor_fail_whenNotDelegated() public {
        vm.startPrank(user1);
        pendleStrategyCTokenSTETH.setDelegateApproval(user2, false);
        vm.stopPrank();

        vm.expectRevert(PluginDelegable.PluginDelegable__Unauthorized.selector);
        _postPendleStrategyCTokenSTETHCollateralForUser1(0.1e18);
    }

    function test_strategyCTokenPostCollateralFor_fail_whenCollateralizationIsNotAllowed() public {
        marketManagerIsolated.setCollateralizationPaused(address(pendleStrategyCTokenSTETH), true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        _postPendleStrategyCTokenSTETHCollateralForUser1(0.1e18);
    }

    function test_strategyCTokenPostCollateralFor_fail_whenZeroAmount() public {
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        _postPendleStrategyCTokenSTETHCollateralForUser1(0);
    }

    function test_strategyCTokenPostCollateralFor_fail_whenCollateralAmountExceedsCTokens() public {
        vm.expectRevert(
            BaseCToken.BaseCToken__InsufficientLiquidity.selector
        );

        _postPendleStrategyCTokenSTETHCollateralForUser1(10e18);
    }

    function test_strategyCTokenPostCollateralFor_fail_whenCollateralAmountExceedsCollateralCap() public {
        _setCTokenConfigBasic(address(pendleStrategyCTokenSTETH), 1, 0);

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__CapReached.selector
        );

        _postPendleStrategyCTokenSTETHCollateralForUser1(_ONE);
    }

    function test_strategyCTokenPostCollateralFor_success() public {
        uint256 balanceBefore = pendleStrategyCTokenSTETH.balanceOf(user1);
        uint256 userCollateral = pendleStrategyCTokenSTETH.collateralPosted(user1);
        uint256 totalCollateral = pendleStrategyCTokenSTETH.marketCollateralPosted();

        vm.expectEmit(true, true, true, true, address(pendleStrategyCTokenSTETH));
        emit CollateralUpdated(_ONE, true, user1);

        uint256 newCollateral = _ONE;

        _postPendleStrategyCTokenSTETHCollateralForUser1(newCollateral);

        // Balance should not have changed.
        assertEq(pendleStrategyCTokenSTETH.balanceOf(user1), balanceBefore);

        // User collateral should go up by `newCollateral`.
        assertEq(pendleStrategyCTokenSTETH.collateralPosted(user1), userCollateral + newCollateral);

        // Market collateral should go up by `newCollateral`.
        assertEq(pendleStrategyCTokenSTETH.marketCollateralPosted(), totalCollateral + newCollateral);
    }

    function _postPendleStrategyCTokenSTETHCollateralForUser1(uint256 shares) internal {
        vm.startPrank(user2);
        pendleStrategyCTokenSTETH.postCollateralFor(shares, user1);
        vm.stopPrank();
    }

}
