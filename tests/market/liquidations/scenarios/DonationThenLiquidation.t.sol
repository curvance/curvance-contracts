// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseBorrowableCToken } from "tests/market/token/BorrowableCToken/TestBaseBorrowableCToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { WAD } from "contracts/libraries/ConstantsLib.sol";

import "forge-std/console2.sol";

contract DonationThenLiquidationTest is TestBaseBorrowableCToken {

    function setUp() public override {
        super.setUp();
        // Preparation work: LiquidityProvider provides 1000 USDC.
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 1000e6);
        // Mint borrowable cUSDC.
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 1000e6);
        borrowableCUSDC.deposit(1000e6, liquidityProvider);
        // Mint cBALETH.
        vm.stopPrank();
    }

    function test_donation_then_liquidation() public {
        uint256 assetsHeldBefore = borrowableCUSDC.assetsHeld();
        uint256 totalAssetsBefore = borrowableCUSDC.totalAssets();

        // Step 1: Random user transfers 1000 USDC into cUSDC.
        _prepareUSDC(user1, 1000e6);
        usdc.transfer(address(borrowableCUSDC), 1000e6);

        // Donations do NOT increase assetsHeld() or totalAssets().
        uint256 assetsHeldAfter = borrowableCUSDC.assetsHeld();
        uint256 totalAssetsAfter = borrowableCUSDC.totalAssets();
        assertEq(assetsHeldBefore, assetsHeldAfter);
        assertEq(totalAssetsBefore, totalAssetsAfter);

        // Step 2: User1 deposits 2 Pendle Strategy cToken as collateral and attempts to borrow 2000 USDC.
        // Borrowing > assetsHeld() should revert with InsufficientAssetsHeld.
        deal(address(LP_wstETH_24Dec2025), user1, 2*_ONE);

        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 2*_ONE);
        pendleStrategyCTokenSTETH.deposit(2*_ONE, user1);
        pendleStrategyCTokenSTETH.postCollateral(2*_ONE);

        vm.expectRevert(BorrowableCToken.BorrowableCToken__InsufficientAssetsHeld.selector);
        borrowableCUSDC.borrow(2000e6, user1);

        // Borrow a valid amount within assetsHeld() constraints.
        borrowableCUSDC.borrow(1000e6, user1);
        vm.stopPrank();

        // Step 3: Mock the Pendle Strategy cToken price to 100 USD, so we can liquidate the position.
        _setPendleStEthLpPrice(100e8);

        // Step 4: User2 liquidates user1's position, should not underflow.
        address[] memory accounts = new address[](1);
        accounts[0] = user1;
        _prepareUSDC(user2, 2000e6);
        vm.startPrank(user2);
        usdc.approve(address(borrowableCUSDC), 2000e6);
        // Full liquidation succeeds without underflow.
        borrowableCUSDC.liquidate(
            accounts,
            address(pendleStrategyCTokenSTETH)
        );
        vm.stopPrank();

        // Step 5: Invariants: totalAssets decreased (bad debt recognized) but remains > 0.
        totalAssetsAfter = borrowableCUSDC.totalAssets();
        assertLt(totalAssetsAfter, totalAssetsBefore);
        assertGt(totalAssetsAfter, 0);
    }
}