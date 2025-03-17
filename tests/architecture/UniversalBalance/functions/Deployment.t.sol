// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseUniversalBalance } from "../TestBaseUniversalBalance.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";

contract UniversalBalanceDeploymentTest is TestBaseUniversalBalance {
    function test_universalBalanceDeployment_fail_whenCentralRegistryIsInvalid()
        public
    {
        vm.expectRevert(
            PluginDelegable.PluginDelegable__InvalidCentralRegistry.selector
        );
        new UniversalBalance(ICentralRegistry(address(1)), address(eUSDC));
    }

    function test_universalBalanceDeployment_fail_whenTokenIsPToken() public {
        vm.expectRevert(
            UniversalBalance.UniversalBalance__InvalidParameter.selector
        );
        new UniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(pBALRETH)
        );
    }

    function test_universalBalanceDeployment_success() public {
        universalBalance = new UniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(eUSDC)
        );

        assertEq(
            address(universalBalance.centralRegistry()),
            address(centralRegistry)
        );
        assertEq(address(universalBalance.linkedToken()), address(eUSDC));
        assertEq(universalBalance.underlying(), _USDC_ADDRESS);
        assertEq(
            usdc.allowance(address(universalBalance), address(eUSDC)),
            type(uint256).max
        );
    }
}
