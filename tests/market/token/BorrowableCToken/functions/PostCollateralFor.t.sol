// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseBorrowableCToken } from "../TestBaseBorrowableCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract PostCollateralForTest is TestBaseBorrowableCToken {
    event CollateralUpdated(uint256 shares, bool increased, address account);

    function setUp() public override {
        super.setUp();
        
        _prepareUSDC(user1, _ONE + _ONE);

        vm.startPrank(user1);
        usdc.approve(address(borrowableCUSDC), _ONE + _ONE);
        borrowableCUSDC.deposit(_ONE + _ONE, user1);
        vm.stopPrank();

        _prepareBALRETH(user1, _ONE + _ONE);

        vm.startPrank(user1);
        borrowableCUSDC.setDelegateApproval(user2, true);
        vm.stopPrank();
    }

    function test_borrowableCTokenPostCollateralFor_fail_whenNotDelegated() public {
        vm.startPrank(user1);
        borrowableCUSDC.setDelegateApproval(user2, false);
        vm.stopPrank();

        vm.expectRevert(PluginDelegable.PluginDelegable__Unauthorized.selector);
        _postBorrowableCUSDCCollateralForUser1(0.1e18);
    }

    function test_borrowableCTokenPostCollateralFor_fail_whenCollateralizationIsNotAllowed() public {
        marketManagerIsolated.setCollateralizationPaused(address(borrowableCUSDC), true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        _postBorrowableCUSDCCollateralForUser1(0.1e18);
    }

    function test_borrowableCTokenPostCollateralFor_fail_whenZeroAmount() public {
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);

        _postBorrowableCUSDCCollateralForUser1(0);
    }

    function test_borrowableCTokenPostCollateralFor_fail_whenCollateralAmountExceedsCTokens() public {
        vm.expectRevert(
            BaseCToken.BaseCToken__InsufficientLiquidity.selector
        );

        _postBorrowableCUSDCCollateralForUser1(10e18);
    }

    function test_borrowableCTokenPostCollateralFor_fail_whenCollateralAmountExceedsCollateralCap() public {
        _setCTokenConfigBasic(address(borrowableCUSDC), 1, 100_000e18);

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__CapReached.selector
        );

        _postBorrowableCUSDCCollateralForUser1(_ONE);
    }

    function test_borrowableCTokenBorrow_fail_whenDebtInBorrowableCToken() public {
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

        _postBorrowableCUSDCCollateralForUser1(_ONE);
    }

    function test_borrowableCTokenPostCollateralFor_success() public {
        uint256 balanceBefore = borrowableCUSDC.balanceOf(user1);
        uint256 userCollateral = borrowableCUSDC.collateralPosted(user1);
        uint256 totalCollateral = borrowableCUSDC.marketCollateralPosted();

        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit CollateralUpdated(_ONE, true, user1);

        uint256 newCollateral = _ONE;

        _postBorrowableCUSDCCollateralForUser1(newCollateral);

        // Balance should not have changed.
        assertEq(borrowableCUSDC.balanceOf(user1), balanceBefore);

        // User collateral should go up by `newCollateral`.
        assertEq(borrowableCUSDC.collateralPosted(user1), userCollateral + newCollateral);

        // Market collateral should go up by `newCollateral`.
        assertEq(borrowableCUSDC.marketCollateralPosted(), totalCollateral + newCollateral);
    }

    function _postBorrowableCUSDCCollateralForUser1(uint256 shares) internal {
        vm.startPrank(user2);
        borrowableCUSDC.postCollateralFor(shares, user1);
        vm.stopPrank();
    }

}
