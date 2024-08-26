// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseUniversalBalance } from "../TestBaseUniversalBalance.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract DepositWETHTest is TestBaseUniversalBalance {
    event Deposit(
        address indexed by,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    function setUp() public override {
        super.setUp();

        deal(_WETH_ADDRESS, address(this), 10e18);
        deal(_WETH_ADDRESS, user1, _ONE);
        deal(user1, _ONE);

        weth.approve(address(dWETH), 10e18);
        marketManager.listToken(address(dWETH));
        oracleRouter.addMTokenSupport(address(dWETH));
        
        vm.prank(user1);
        weth.approve(address(universalBalance), _ONE);
    }

    function test_depositWETH_fail_whenHasNoEnoughWETH() public {
        vm.startPrank(user1);

        weth.approve(address(universalBalance), _ONE + 1);

        vm.expectRevert();
        universalBalance.depositWETH(_ONE + 1, true);

        vm.stopPrank();
    }

    function test_depositWETH_fail_whenExceedsAllowance() public {
        deal(_WETH_ADDRESS, user1, _ONE + 1);

        vm.prank(user1);

        vm.expectRevert();
        universalBalance.depositWETH(_ONE + 1, true);
    }

    function test_depositWETH_fail_whenTokenIsNotListed() public {
        universalBalance = new UniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(dUSDC),
            _WETH_ADDRESS
        );

        vm.startPrank(user1);

        weth.approve(address(universalBalance), _ONE);

        vm.expectRevert(MarketManager.MarketManager__TokenNotListed.selector);
        universalBalance.depositWETH(_ONE, true);

        vm.stopPrank();
    }

    function test_depositWETH_fail_whenAmountIsZero() public {
        vm.prank(user1);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__InvalidParameter.selector
        );
        universalBalance.depositWETH(0, false);
    }

    function test_depositWETH_success_withLend() public {
        uint256 receiveAmount = dWETH.convertToShares(_ONE);
        uint256 wethBalance = weth.balanceOf(address(universalBalance));
        uint256 dWETHBalance = dWETH.balanceOf(address(universalBalance));
        uint256 userWETHBalance = weth.balanceOf(user1);

        vm.prank(user1);

        vm.expectEmit();
        emit Deposit(user1, user1, _ONE, receiveAmount);

        universalBalance.depositWETH(_ONE, true);

        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user1);

        assertEq(sittingBalance, 0);
        assertEq(lentBalance, receiveAmount);
        assertEq(weth.balanceOf(address(universalBalance)), wethBalance);
        assertEq(
            dWETH.balanceOf(address(universalBalance)),
            dWETHBalance + receiveAmount
        );
        assertEq(weth.balanceOf(user1), userWETHBalance - _ONE);
    }

    function test_depositWETH_success_withoutLend() public {
        uint256 wethBalance = weth.balanceOf(address(universalBalance));
        uint256 dWETHBalance = dWETH.balanceOf(address(universalBalance));
        uint256 userWETHBalance = weth.balanceOf(user1);

        vm.prank(user1);

        vm.expectEmit();
        emit Deposit(user1, user1, _ONE, _ONE);

        universalBalance.depositWETH(_ONE, false);

        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user1);

        assertEq(sittingBalance, _ONE);
        assertEq(lentBalance, 0);
        assertEq(
            weth.balanceOf(address(universalBalance)),
            wethBalance + _ONE
        );
        assertEq(dWETH.balanceOf(address(universalBalance)), dWETHBalance);
        assertEq(weth.balanceOf(user1), userWETHBalance - _ONE);
    }
}
