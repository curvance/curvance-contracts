// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract WithdrawFeeTest is TestBaseMarketIsolated {
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

    function test_withdrawFee_success_UsingBalanceAssertions() public {
        _prepareUSDC(address(centralRegistry), 100e6);

        uint256 initialDaoBalance = usdc.balanceOf(centralRegistry.daoAddress());
        uint256 initialRegistryBalance = usdc.balanceOf(address(centralRegistry));

        centralRegistry.withdrawFee();

        assertEq(usdc.balanceOf(centralRegistry.daoAddress()), initialDaoBalance + 100e6);
        assertEq(usdc.balanceOf(address(centralRegistry)), initialRegistryBalance - 100e6);
    }
}
