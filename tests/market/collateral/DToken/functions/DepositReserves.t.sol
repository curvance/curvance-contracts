// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseDToken } from "../TestBaseDToken.sol";
import { GaugeManager } from "contracts/architecture/GaugeManager.sol";
import { DToken } from "contracts/market/collateral/DToken.sol";

contract DTokenDepositReservesTest is TestBaseDToken {
    function test_dTokenDepositReserves_fail_whenCallIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(DToken.DToken__Unauthorized.selector);
        dUSDC.depositReserves(100e6);
    }

    function test_dTokenDepositReserves_fail_whenAmountIsZero() public {
        vm.expectRevert(GaugeManager.GaugeManager__InvalidAmount.selector);
        dUSDC.depositReserves(0);
    }

    function test_dTokenDepositReserves_success() public {
        uint256 underlyingBalance = usdc.balanceOf(address(this));
        uint256 balance = dUSDC.balanceOf(address(this));
        uint256 totalSupply = dUSDC.totalSupply();

        dUSDC.depositReserves(100e6);

        assertEq(usdc.balanceOf(address(this)), underlyingBalance - 100e6);
        assertEq(dUSDC.balanceOf(address(this)), balance);
        assertEq(dUSDC.totalSupply(), totalSupply);
    }
}
