// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract DepositAsCollateralForTest is TestBaseStrategyCToken {
    event CollateralUpdated(uint256 shares, bool increased, address account);

    function setUp() public override {
        super.setUp();
        _prepareBALRETH(user2, _ONE + _ONE);

        vm.startPrank(user2);
        balRETH.approve(address(strategyCBALRETH), _ONE + _ONE);
        vm.stopPrank();
        
        vm.startPrank(user1);
        // Approve delegated collateral deposits for `user1` by `user2`.
        strategyCBALRETH.setDelegateApproval(user2, true);
        vm.stopPrank();
    }

    function test_strategyCTokenDepositAsCollateralFor_fail_whenNotDelegated() public {
        vm.startPrank(user1);
        strategyCBALRETH.setDelegateApproval(user2, false);
        vm.stopPrank();

        vm.expectRevert(PluginDelegable.PluginDelegable__Unauthorized.selector);
        _depositAndPostBalRETHCollateralForUser1(0.1e18);
    }

    function test_strategyCTokenDepositAsCollateralFor_fail_whenMintingIsNotAllowed() public {
        marketManagerIsolated.setMintPaused(address(strategyCBALRETH), true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        _depositAndPostBalRETHCollateralForUser1(0.1e18);
    }

    function test_strategyCTokenDepositAsCollateralFor_fail_whenCollateralizationIsNotAllowed() public {
        marketManagerIsolated.setCollateralizationPaused(address(strategyCBALRETH), true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        _depositAndPostBalRETHCollateralForUser1(0.1e18);
    }

    function test_strategyCTokenDepositAsCollateralFor_fail_whenNotApproved() public {
        // Prepare extra to try to deposit meaning approval is the restriction.
        _prepareBALRETH(user1, _ONE + _ONE);

        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        _depositAndPostBalRETHCollateralForUser1(3e18);
    }

    function test_strategyCTokenDepositAsCollateralFor_fail_whenZeroAmount() public {
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        _depositAndPostBalRETHCollateralForUser1(0);
    }

    function test_strategyCTokenDepositAsCollateralFor_fail_whenDepositAmountExceedsAssetsHeld() public {
        // Approve extra to try to deposit meaning assets held is the restriction.
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 5e18);
        vm.stopPrank();

        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        _depositAndPostBalRETHCollateralForUser1(5e18);
    }

    function test_strategyCTokenDepositAsCollateralFor_fail_whenCollateralAmountExceedsCollateralCap() public {
        _setCTokenConfigBasic(address(strategyCBALRETH), 1, 0);

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__CapReached.selector
        );

        _depositAndPostBalRETHCollateralForUser1(_ONE);
    }

    function test_strategyCTokenDepositAsCollateralFor_success() public {
        uint256 balanceBefore = strategyCBALRETH.balanceOf(user1);
        uint256 supplyBefore = strategyCBALRETH.totalSupply();
        uint256 userCollateral = strategyCBALRETH.collateralPosted(user1);
        uint256 totalCollateral = strategyCBALRETH.marketCollateralPosted();

        vm.expectEmit(true, true, true, true, address(strategyCBALRETH));
        emit CollateralUpdated(_ONE, true, user1);

        uint256 sharesReceived = _depositAndPostBalRETHCollateralForUser1(_ONE);

        // Balance should have increased by `sharesReceived`.
        assertEq(strategyCBALRETH.balanceOf(user1), balanceBefore + sharesReceived);

        // Balance should have increased by `sharesReceived`.
        assertEq(strategyCBALRETH.totalSupply(), supplyBefore + sharesReceived);

        // User collateral should go up by `sharesReceived`.
        assertEq(strategyCBALRETH.collateralPosted(user1), userCollateral + sharesReceived);

        // Market collateral should go up by `sharesReceived`.
        assertEq(strategyCBALRETH.marketCollateralPosted(), totalCollateral + sharesReceived);
    }

    function _depositAndPostBalRETHCollateralForUser1(uint256 assets) internal returns (uint256 shares) {
        vm.startPrank(user2);
        shares = strategyCBALRETH.depositAsCollateralFor(assets, user1);
        vm.stopPrank();
    }

}
