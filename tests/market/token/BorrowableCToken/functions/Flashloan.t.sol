// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseBorrowableCToken } from "../TestBaseBorrowableCToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { FixedPointMathLib } from "contracts/market/token/BaseCToken.sol";
import "forge-std/console2.sol";

contract FlashloanTest is TestBaseBorrowableCToken {

    uint256 flashloanAmount = 10_000e6;
    uint256 fee = FixedPointMathLib.mulDivUp(10_000e6, 4, 10_000);

    function setUp() public override {
        super.setUp();

        // Provide liquidity from user1
        vm.startPrank(user1);
        _prepareUSDC(address(user1), flashloanAmount);
        usdc.approve(address(borrowableCUSDC), flashloanAmount);
        borrowableCUSDC.deposit(flashloanAmount, address(user1));
        vm.stopPrank();
    }

    function test_flashloan_success() public {

        _prepareUSDC(address(this), 0); // reset USDC balance

        uint256 cUSDCBalanceBeforeFlashloan = usdc.balanceOf(address(borrowableCUSDC));

        bytes memory cUSDCBalanceBeforeFlashloanBytes = abi.encode(cUSDCBalanceBeforeFlashloan, false);

        borrowableCUSDC.flashLoan(flashloanAmount, cUSDCBalanceBeforeFlashloanBytes);

        uint256 cUSDCBalanceAfterFlashloan = usdc.balanceOf(address(borrowableCUSDC));

        assertEq(cUSDCBalanceAfterFlashloan, cUSDCBalanceBeforeFlashloan + fee, "cUSDC should have profited");

    }

    function test_flashloan_fail_whenAssetsReturnedIsLessThanAssets() public {
        _prepareUSDC(address(this), 0); // reset USDC balance
        
        uint256 cUSDCBalanceBeforeFlashloan = usdc.balanceOf(address(borrowableCUSDC));
        bytes memory cUSDCBalanceBeforeFlashloanBytes = abi.encode(cUSDCBalanceBeforeFlashloan, true);
        vm.expectRevert();
        borrowableCUSDC.flashLoan(flashloanAmount, cUSDCBalanceBeforeFlashloanBytes);
    }

    // Callback function for the flashloan
    function onFlashLoan(uint256 assets, uint256 assetsReturned, bytes calldata data) external returns (bytes32) {

        console2.log("onFlashLoan called");

        (uint256 cUSDCBalanceBeforeFlashloan, bool isRevert) = abi.decode(data, (uint256, bool));

        uint256 cUSDCBalanceDuringFlashloan = usdc.balanceOf(address(borrowableCUSDC));

        assertEq(assets, flashloanAmount, "assets should be the flashloan amount");
        assertEq(assetsReturned, flashloanAmount + fee, "assetsReturned should be the flashloan amount + fee");

        assertEq(cUSDCBalanceDuringFlashloan, cUSDCBalanceBeforeFlashloan - flashloanAmount, "cUSDC should have loaned out the flashloan amount");
        assertEq(usdc.balanceOf(address(this)), flashloanAmount, "this contract should have received the flashloan amount");

        if (!isRevert) {
            _prepareUSDC(address(this), assetsReturned);
        } else {
            // 0% interest loan
        }

        usdc.approve(address(borrowableCUSDC), flashloanAmount + fee);

        return bytes32(0);
    }



}
