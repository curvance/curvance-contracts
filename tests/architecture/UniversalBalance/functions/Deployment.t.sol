// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";

import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { TestBaseUniversalBalance } from "../TestBaseUniversalBalance.sol";

contract UniversalBalanceDeploymentTest is TestBaseUniversalBalance {
    function test_universalBalanceDeployment_fail_whenCentralRegistryIsInvalid()
        public
    {
        vm.expectRevert(
            CentralRegistryLib.CentralRegistryLib__InvalidCentralRegistry
                .selector
        );
        new UniversalBalance(ICentralRegistry(address(1)), address(borrowableCUSDC));
    }

    function test_universalBalanceDeployment_fail_whenTokenIsPToken() public {
        vm.expectRevert(
            UniversalBalance.UniversalBalance__InvalidParameter.selector
        );
        new UniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(strategyCBALRETH)
        );
    }

    function test_universalBalanceDeployment_success() public {
        universalBalance = new UniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(borrowableCUSDC)
        );

        assertEq(
            address(universalBalance.centralRegistry()),
            address(centralRegistry)
        );
        assertEq(address(universalBalance.linkedToken()), address(borrowableCUSDC));
        assertEq(universalBalance.underlying(), _USDC_ADDRESS);
        assertEq(
            usdc.allowance(address(universalBalance), address(borrowableCUSDC)),
            type(uint256).max
        );
    }
}
