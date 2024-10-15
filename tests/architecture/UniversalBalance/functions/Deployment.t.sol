// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseUniversalBalance } from "../TestBaseUniversalBalance.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";

contract UniversalBalanceDeploymentTest is TestBaseUniversalBalance {
    function test_universalBalanceDeployment_fail_whenCentralRegistryIsInvalid()
        public
    {
        vm.expectRevert(PluginDelegable.PluginDelegable__InvalidCentralRegistry.selector);
        new UniversalBalance(
            ICentralRegistry(address(1)),
            address(eWETH),
            _WETH_ADDRESS
        );
    }

    function test_universalBalanceDeployment_fail_whenTokenIsPToken() public {
        vm.expectRevert(
            UniversalBalance.UniversalBalance__InvalidParameter.selector
        );
        new UniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(pBALRETH),
            _WETH_ADDRESS
        );
    }

    function test_universalBalanceDeployment_success() public {
        universalBalance = new UniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(eWETH),
            _WETH_ADDRESS
        );

        assertEq(
            address(universalBalance.centralRegistry()),
            address(centralRegistry)
        );
        assertEq(address(universalBalance.linkedEToken()), address(eWETH));
        assertEq(universalBalance.wrappedNative(), _WETH_ADDRESS);
        assertEq(
            weth.allowance(address(universalBalance), address(eWETH)),
            type(uint256).max
        );
    }
}
