// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract PostCollateralTest is TestBaseStrategyCToken {
    event CollateralUpdated(uint256 shares, bool increased, address account);

    function setUp() public override {
        super.setUp();
        
        _prepareBALRETH(user1, _ONE + _ONE);

        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE + _ONE);
        strategyCBALRETH.deposit(_ONE + _ONE, user1);
        vm.stopPrank();
    }

    function test_strategyCTokenPostCollateral_fail_whenCollateralizationIsNotAllowed() public {
        marketManagerIsolated.setCollateralizationPaused(address(strategyCBALRETH), true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        _postBalRETHCollateral(0.1e18);
    }

    function test_strategyCTokenPostCollateral_fail_whenZeroAmount() public {
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        _postBalRETHCollateral(0);
    }

    function test_strategyCTokenPostCollateral_fail_whenCollateralAmountExceedsCTokens() public {
        vm.expectRevert(
            BaseCToken.BaseCToken__InsufficientLiquidity.selector
        );

        _postBalRETHCollateral(10e18);
    }

    function test_strategyCTokenPostCollateral_fail_whenCollateralAmountExceedsCollateralCap() public {
        _setCTokenConfigBasic(address(strategyCBALRETH), 1, 0);

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__CapReached.selector
        );

        _postBalRETHCollateral(_ONE);
    }

    function test_strategyCTokenPostCollateral_success() public {
        uint256 balanceBefore = strategyCBALRETH.balanceOf(user1);
        uint256 userCollateral = strategyCBALRETH.collateralPosted(user1);
        uint256 totalCollateral = strategyCBALRETH.marketCollateralPosted();

        vm.expectEmit(true, true, true, true, address(strategyCBALRETH));
        emit CollateralUpdated(_ONE, true, user1);

        uint256 newCollateral = _ONE;

        _postBalRETHCollateral(newCollateral);

        // Balance should not have changed.
        assertEq(strategyCBALRETH.balanceOf(user1), balanceBefore);

        // User collateral should go up by `newCollateral`.
        assertEq(strategyCBALRETH.collateralPosted(user1), userCollateral + newCollateral);

        // Market collateral should go up by `newCollateral`.
        assertEq(strategyCBALRETH.marketCollateralPosted(), totalCollateral + newCollateral);
    }

    function _postBalRETHCollateral(uint256 shares) internal {
        vm.startPrank(user1);
        strategyCBALRETH.postCollateral(shares);
        vm.stopPrank();
    }

}
