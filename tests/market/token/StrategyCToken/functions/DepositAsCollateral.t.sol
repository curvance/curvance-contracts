// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract DepositAsCollateralTest is TestBaseStrategyCToken {
    event CollateralUpdated(uint256 shares, bool increased, address account);

    function setUp() public override {
        super.setUp();
        _prepareBALRETH(user1, _ONE + _ONE);

        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE + _ONE);
        vm.stopPrank();
    }

    function test_strategyCTokenDepositAsCollateral_fail_whenMintingIsNotAllowed() public {
        marketManagerIsolated.setMintPaused(address(strategyCBALRETH), true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        _depositAndPostBalRETHCollateral(0.1e18);
    }

    function test_strategyCTokenDepositAsCollateral_fail_whenCollateralizationIsNotAllowed() public {
        marketManagerIsolated.setCollateralizationPaused(address(strategyCBALRETH), true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        _depositAndPostBalRETHCollateral(0.1e18);
    }

    function test_strategyCTokenDepositAsCollateral_fail_whenNotApproved() public {
        // Prepare extra to try to deposit meaning approval is the restriction.
        _prepareBALRETH(user1, _ONE + _ONE);

        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        _depositAndPostBalRETHCollateral(3e18);
    }

    function test_strategyCTokenDepositAsCollateral_fail_whenZeroAmount() public {
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        _depositAndPostBalRETHCollateral(0);
    }

    function test_strategyCTokenDepositAsCollateral_fail_whenDepositAmountExceedsAssetsHeld() public {
        // Approve extra to try to deposit meaning assets held is the restriction.
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 5e18);
        vm.stopPrank();

        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        _depositAndPostBalRETHCollateral(5e18);
    }

    function test_strategyCTokenDepositAsCollateral_fail_whenCollateralAmountExceedsCollateralCap() public {
        _setCTokenConfigBasic(address(strategyCBALRETH), 1, 0);

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__CapReached.selector
        );

        _depositAndPostBalRETHCollateral(_ONE);
    }

    function test_strategyCTokenDepositAsCollateral_success() public {
        uint256 balanceBefore = strategyCBALRETH.balanceOf(user1);
        uint256 supplyBefore = strategyCBALRETH.totalSupply();
        uint256 userCollateral = strategyCBALRETH.collateralPosted(user1);
        uint256 totalCollateral = strategyCBALRETH.marketCollateralPosted();

        vm.expectEmit(true, true, true, true, address(strategyCBALRETH));
        emit CollateralUpdated(_ONE, true, user1);

        uint256 sharesReceived = _depositAndPostBalRETHCollateral(_ONE);

        // Balance should have increased by `sharesReceived`.
        assertEq(strategyCBALRETH.balanceOf(user1), balanceBefore + sharesReceived);

        // Balance should have increased by `sharesReceived`.
        assertEq(strategyCBALRETH.totalSupply(), supplyBefore + sharesReceived);

        // User collateral should go up by `sharesReceived`.
        assertEq(strategyCBALRETH.collateralPosted(user1), userCollateral + sharesReceived);

        // Market collateral should go up by `sharesReceived`.
        assertEq(strategyCBALRETH.marketCollateralPosted(), totalCollateral + sharesReceived);
    }

    function _depositAndPostBalRETHCollateral(uint256 assets) internal returns (uint256 shares) {
        vm.startPrank(user1);
        shares = strategyCBALRETH.depositAsCollateral(assets, user1);
        vm.stopPrank();
    }

}
