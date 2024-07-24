// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseUniversalBalance } from "../TestBaseUniversalBalance.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";

contract WithdrawAsWETHTest is TestBaseUniversalBalance {
    event Withdraw(
        address indexed by,
        address indexed to,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    function setUp() public override {
        super.setUp();

        deal(_WETH_ADDRESS, address(this), 10e18);
        deal(user1, _ONE * 2);

        weth.approve(address(dWETH), 10e18);
        marketManager.listToken(address(dWETH));
        oracleRouter.addMTokenSupport(address(dWETH));
        gaugePool.start(address(marketManager));

        vm.startPrank(user1);

        universalBalance.depositETH{ value: _ONE }(true);
        universalBalance.depositETH{ value: _ONE }(false);

        vm.stopPrank();
    }

    function test_withdrawAsWETH_fail_whenExceedsLentBalance() public {
        vm.prank(user1);

        vm.expectRevert();
        universalBalance.withdrawAsWETH(_ONE + 1, true);
    }

    function test_withdrawAsWETH_fail_whenExceedsSittingBalance() public {
        vm.prank(user1);

        vm.expectRevert();
        universalBalance.withdrawAsWETH(_ONE + 1, false);
    }

    function test_withdrawAsWETH_fail_whenAmountIsZero() public {
        vm.prank(user1);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__InvalidParameter.selector
        );
        universalBalance.withdrawAsWETH(0, false);
    }

    function test_withdrawAsWETH_success_withLend() public {
        uint256 redeemAmount = dWETH.convertToShares(_ONE);
        uint256 ethBalance = address(universalBalance).balance;
        uint256 wethBalance = weth.balanceOf(address(universalBalance));
        uint256 dWETHBalance = dWETH.balanceOf(address(universalBalance));
        uint256 userWETHBalance = weth.balanceOf(user1);

        vm.prank(user1);

        vm.expectEmit();
        emit Withdraw(user1, user1, user1, _ONE, redeemAmount);

        universalBalance.withdrawAsWETH(_ONE, true);

        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user1);

        assertEq(sittingBalance, _ONE);
        assertEq(lentBalance, 0);
        assertEq(address(universalBalance).balance, ethBalance);
        assertEq(weth.balanceOf(address(universalBalance)), wethBalance);
        assertEq(
            dWETH.balanceOf(address(universalBalance)),
            dWETHBalance - redeemAmount
        );
        assertEq(weth.balanceOf(user1), userWETHBalance + _ONE);
    }

    function test_withdrawAsWETH_success_withoutLend() public {
        uint256 ethBalance = address(universalBalance).balance;
        uint256 wethBalance = weth.balanceOf(address(universalBalance));
        uint256 dWETHBalance = dWETH.balanceOf(address(universalBalance));
        uint256 userWETHBalance = weth.balanceOf(user1);

        vm.prank(user1);

        vm.expectEmit();
        emit Withdraw(user1, user1, user1, _ONE, _ONE);

        universalBalance.withdrawAsWETH(_ONE, false);

        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user1);

        assertEq(sittingBalance, 0);
        assertEq(lentBalance, _ONE);
        assertEq(address(universalBalance).balance, ethBalance);
        assertEq(
            weth.balanceOf(address(universalBalance)),
            wethBalance - _ONE
        );
        assertEq(dWETH.balanceOf(address(universalBalance)), dWETHBalance);
        assertEq(weth.balanceOf(user1), userWETHBalance + _ONE);
    }
}
