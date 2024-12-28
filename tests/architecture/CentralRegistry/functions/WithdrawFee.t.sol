// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract WithdrawFeeTest is TestBaseMarket {
    function test_withdrawFee_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.withdrawFee();
    }

    function test_withdrawFee_success() public {
        _prepareUSDC(address(centralRegistry), 100e6);

        assertEq(usdc.balanceOf(centralRegistry.daoAddress()), 0);
        assertEq(usdc.balanceOf(address(centralRegistry)), 100e6);

        centralRegistry.withdrawFee();

        assertEq(usdc.balanceOf(centralRegistry.daoAddress()), 100e6);
        assertEq(usdc.balanceOf(address(centralRegistry)), 0);
    }
}
