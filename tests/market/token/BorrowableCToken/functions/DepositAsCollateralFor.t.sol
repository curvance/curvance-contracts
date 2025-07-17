// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract DepositAsCollateralForTest is TestBaseStrategyCToken {
    event CollateralUpdated(uint256 shares, bool increased, address account);

    function setUp() public override {
        super.setUp();
        _prepareUSDC(user2, _ONE + _ONE);

        vm.startPrank(user2);
        usdc.approve(address(borrowableCUSDC), _ONE + _ONE);
        vm.stopPrank();
        
        vm.startPrank(user1);
        // Approve delegated collateral deposits for `user1` by `user2`.
        borrowableCUSDC.setDelegateApproval(user2, true);
        vm.stopPrank();
    }

    function test_borrowableCTokenDepositAsCollateralFor_fail_whenNotDelegated() public {
        vm.startPrank(user1);
        borrowableCUSDC.setDelegateApproval(user2, false);
        vm.stopPrank();

        vm.expectRevert(PluginDelegable.PluginDelegable__Unauthorized.selector);
        _depositAndPostBorrowableCUSDCCollateralForUser1(0.1e18);
    }

    function test_borrowableCTokenDepositAsCollateralFor_fail_whenMintingIsNotAllowed() public {
        marketManagerIsolated.setMintPaused(address(borrowableCUSDC), true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        _depositAndPostBorrowableCUSDCCollateralForUser1(0.1e18);
    }

    function test_borrowableCTokenDepositAsCollateralFor_fail_whenCollateralizationIsNotAllowed() public {
        marketManagerIsolated.setCollateralizationPaused(address(borrowableCUSDC), true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        _depositAndPostBorrowableCUSDCCollateralForUser1(0.1e18);
    }

    function test_borrowableCTokenDepositAsCollateralFor_fail_whenNotApproved() public {
        // Prepare extra to try to deposit meaning approval is the restriction.
        _prepareUSDC(user1, _ONE + _ONE);

        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        _depositAndPostBorrowableCUSDCCollateralForUser1(3e18);
    }

    function test_borrowableCTokenDepositAsCollateralFor_fail_whenZeroAmount() public {
        marketManagerIsolated.setBorrowPaused(address(borrowableCUSDC), true);

        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        _depositAndPostBorrowableCUSDCCollateralForUser1(0);
    }

    function test_borrowableCTokenDepositAsCollateralFor_fail_whenDepositAmountExceedsAssetsHeld() public {
        // Approve extra to try to deposit meaning assets held is the restriction.
        vm.startPrank(user1);
        usdc.approve(address(borrowableCUSDC), 5e18);
        vm.stopPrank();

        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        _depositAndPostBorrowableCUSDCCollateralForUser1(5e18);
    }

    function test_borrowableCTokenDepositAsCollateralFor_fail_whenCollateralAmountExceedsCollateralCap() public {
        _setCTokenConfigBasic(address(borrowableCUSDC), 1, 0);

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__CapReached.selector
        );

        _depositAndPostBorrowableCUSDCCollateralForUser1(_ONE);
    }

    function test_borrowableCTokenDepositAsCollateralFor_fail_whenDebtInBorrowableCToken() public {
        _prepareUSDC(address(this), _ONE + _ONE);
        usdc.approve(address(borrowableCUSDC), _ONE + _ONE);
        borrowableCUSDC.deposit(_ONE, address(this));

        _prepareBALRETH(user1, _ONE + _ONE);

        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE + _ONE);
        strategyCBALRETH.deposit(_ONE + _ONE, user1);
        strategyCBALRETH.postCollateral(_ONE);
        
        borrowableCUSDC.borrow(20e6, user1);
        vm.stopPrank();

        vm.expectRevert(
            BorrowableCToken.BorrowableCToken__DebtPositionActive.selector
        );

        _depositAndPostBorrowableCUSDCCollateralForUser1(_ONE);
    }

    function test_borrowableCTokenDepositAsCollateralFor_success() public {
        uint256 balanceBefore = borrowableCUSDC.balanceOf(user1);
        uint256 supplyBefore = borrowableCUSDC.totalSupply();
        uint256 userCollateral = borrowableCUSDC.collateralPosted(user1);
        uint256 totalCollateral = borrowableCUSDC.marketCollateralPosted();

        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit CollateralUpdated(_ONE, true, user1);

        uint256 sharesReceived = _depositAndPostBorrowableCUSDCCollateralForUser1(_ONE);

        // Balance should have increased by `sharesReceived`.
        assertEq(borrowableCUSDC.balanceOf(user1), balanceBefore + sharesReceived);

        // Balance should have increased by `sharesReceived`.
        assertEq(borrowableCUSDC.totalSupply(), supplyBefore + sharesReceived);

        // User collateral should go up by `sharesReceived`.
        assertEq(borrowableCUSDC.collateralPosted(user1), userCollateral + sharesReceived);

        // Market collateral should go up by `sharesReceived`.
        assertEq(borrowableCUSDC.marketCollateralPosted(), totalCollateral + sharesReceived);
    }

    function _depositAndPostBorrowableCUSDCCollateralForUser1(uint256 assets) internal returns (uint256 shares) {
        vm.startPrank(user2);
        shares = borrowableCUSDC.depositAsCollateralFor(assets, user1);
        vm.stopPrank();
    }

}
