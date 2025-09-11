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
        deal(address(LP_wstETH_24Dec2025), user2, _ONE + _ONE);

        vm.startPrank(user2);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE + _ONE);
        vm.stopPrank();
        
        vm.startPrank(user1);
        // Approve delegated collateral deposits for `user1` by `user2`.
        pendleStrategyCTokenSTETH.setDelegateApproval(user2, true);
        vm.stopPrank();
    }

    function test_strategyCTokenDepositAsCollateralFor_fail_whenNotDelegated() public {
        vm.startPrank(user1);
        pendleStrategyCTokenSTETH.setDelegateApproval(user2, false);
        vm.stopPrank();

        vm.expectRevert(PluginDelegable.PluginDelegable__Unauthorized.selector);
        _depositAndPostPendleLPCollateralForUser1(0.1e18);
    }

    function test_strategyCTokenDepositAsCollateralFor_fail_whenMintingIsNotAllowed() public {
        marketManagerIsolated.setMintPaused(address(pendleStrategyCTokenSTETH), true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        _depositAndPostPendleLPCollateralForUser1(0.1e18);
    }

    function test_strategyCTokenDepositAsCollateralFor_fail_whenCollateralizationIsNotAllowed() public {
        marketManagerIsolated.setCollateralizationPaused(address(pendleStrategyCTokenSTETH), true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        _depositAndPostPendleLPCollateralForUser1(0.1e18);
    }

    function test_strategyCTokenDepositAsCollateralFor_fail_whenNotApproved() public {
        // Prepare extra to try to deposit meaning approval is the restriction.
        deal(address(LP_wstETH_24Dec2025), user1, _ONE + _ONE);

        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        _depositAndPostPendleLPCollateralForUser1(3e18);
    }

    function test_strategyCTokenDepositAsCollateralFor_fail_whenZeroAmount() public {
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        _depositAndPostPendleLPCollateralForUser1(0);
    }

    function test_strategyCTokenDepositAsCollateralFor_fail_whenDepositAmountExceedsAssetsHeld() public {
        // Approve extra to try to deposit meaning assets held is the restriction.
        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 5e18);
        vm.stopPrank();

        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        _depositAndPostPendleLPCollateralForUser1(5e18);
    }

    function test_strategyCTokenDepositAsCollateralFor_fail_whenCollateralAmountExceedsCollateralCap() public {
        _setCTokenConfigBasic(address(pendleStrategyCTokenSTETH), 1, 0);

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__CapReached.selector
        );

        _depositAndPostPendleLPCollateralForUser1(_ONE);
    }

    function test_strategyCTokenDepositAsCollateralFor_success() public {
        uint256 balanceBefore = pendleStrategyCTokenSTETH.balanceOf(user1);
        uint256 supplyBefore = pendleStrategyCTokenSTETH.totalSupply();
        uint256 userCollateral = pendleStrategyCTokenSTETH.collateralPosted(user1);
        uint256 totalCollateral = pendleStrategyCTokenSTETH.marketCollateralPosted();

        vm.expectEmit(true, true, true, true, address(pendleStrategyCTokenSTETH));
        emit CollateralUpdated(_ONE, true, user1);

        uint256 sharesReceived = _depositAndPostPendleLPCollateralForUser1(_ONE);

        // Balance should have increased by `sharesReceived`.
        assertEq(pendleStrategyCTokenSTETH.balanceOf(user1), balanceBefore + sharesReceived);

        // Balance should have increased by `sharesReceived`.
        assertEq(pendleStrategyCTokenSTETH.totalSupply(), supplyBefore + sharesReceived);

        // User collateral should go up by `sharesReceived`.
        assertEq(pendleStrategyCTokenSTETH.collateralPosted(user1), userCollateral + sharesReceived);

        // Market collateral should go up by `sharesReceived`.
        assertEq(pendleStrategyCTokenSTETH.marketCollateralPosted(), totalCollateral + sharesReceived);
    }

    function _depositAndPostPendleLPCollateralForUser1(uint256 assets) internal returns (uint256 shares) {
        vm.startPrank(user2);
        shares = pendleStrategyCTokenSTETH.depositAsCollateralFor(assets, user1);
        vm.stopPrank();
    }

}
