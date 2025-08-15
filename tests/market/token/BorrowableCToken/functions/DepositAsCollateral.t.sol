// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { TestBaseBorrowableCToken } from "../TestBaseBorrowableCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract DepositAsCollateralTest is TestBaseBorrowableCToken {
    event CollateralUpdated(uint256 shares, bool increased, address account);

    function setUp() public override {
        super.setUp();
        
        _prepareUSDC(user1, _ONE + _ONE);

        vm.startPrank(user1);
        usdc.approve(address(borrowableCUSDC), _ONE + _ONE);
        vm.stopPrank();
    }

    function test_borrowableCTokenDepositAsCollateral_fail_whenMintingIsNotAllowed() public {
        marketManagerIsolated.setMintPaused(address(borrowableCUSDC), true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        _depositAndPostBorrowableCUSDCCollateral(0.1e18);
    }

    function test_borrowableCTokenDepositAsCollateral_fail_whenCollateralizationIsNotAllowed() public {
        marketManagerIsolated.setCollateralizationPaused(address(borrowableCUSDC), true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        _depositAndPostBorrowableCUSDCCollateral(0.1e18);
    }

    function test_borrowableCTokenDepositAsCollateral_fail_whenNotApproved() public {
        // Prepare extra to try to deposit meaning approval is the restriction.
        _prepareUSDC(user1, _ONE + _ONE);

        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        _depositAndPostBorrowableCUSDCCollateral(3e18);
    }

    function test_borrowableCTokenDepositAsCollateral_fail_whenZeroAmount() public {
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        _depositAndPostBorrowableCUSDCCollateral(0);
    }

    function test_borrowableCTokenDepositAsCollateral_fail_whenDepositAmountExceedsAssetsHeld() public {
        // Approve extra to try to deposit meaning assets held is the restriction.
        vm.startPrank(user1);
        usdc.approve(address(borrowableCUSDC), 5e18);
        vm.stopPrank();

        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        _depositAndPostBorrowableCUSDCCollateral(5e18);
    }

    function test_borrowableCTokenDepositAsCollateral_fail_whenCollateralAmountExceedsCollateralCap() public {
        _setCTokenConfigBasic(address(borrowableCUSDC), 1, 0);

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__CapReached.selector
        );

        _depositAndPostBorrowableCUSDCCollateral(_ONE);
    }

    function test_borrowableCTokenDepositAsCollateral_fail_whenDebtInBorrowableCToken() public {
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

        _depositAndPostBorrowableCUSDCCollateral(_ONE);
    }

    function test_borrowableCTokenDepositAsCollateral_success() public {
        uint256 balanceBefore = borrowableCUSDC.balanceOf(user1);
        uint256 supplyBefore = borrowableCUSDC.totalSupply();
        uint256 userCollateral = borrowableCUSDC.collateralPosted(user1);
        uint256 totalCollateral = borrowableCUSDC.marketCollateralPosted();

        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit CollateralUpdated(_ONE, true, user1);

        uint256 sharesReceived = _depositAndPostBorrowableCUSDCCollateral(_ONE);

        // Balance should have increased by `sharesReceived`.
        assertEq(borrowableCUSDC.balanceOf(user1), balanceBefore + sharesReceived);

        // Balance should have increased by `sharesReceived`.
        assertEq(borrowableCUSDC.totalSupply(), supplyBefore + sharesReceived);

        // User collateral should go up by `sharesReceived`.
        assertEq(borrowableCUSDC.collateralPosted(user1), userCollateral + sharesReceived);

        // Market collateral should go up by `sharesReceived`.
        assertEq(borrowableCUSDC.marketCollateralPosted(), totalCollateral + sharesReceived);
    }

    function _depositAndPostBorrowableCUSDCCollateral(uint256 assets) internal returns (uint256 shares) {
        vm.startPrank(user1);
        shares = borrowableCUSDC.depositAsCollateral(assets, user1);
        vm.stopPrank();
    }

}
