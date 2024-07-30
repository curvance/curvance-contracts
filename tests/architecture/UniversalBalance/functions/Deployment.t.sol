// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseUniversalBalance } from "../TestBaseUniversalBalance.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { Delegable } from "contracts/libraries/Delegable.sol";

contract UniversalBalanceDeploymentTest is TestBaseUniversalBalance {
    function test_universalBalanceDeployment_fail_whenCentralRegistryIsInvalid()
        public
    {
        vm.expectRevert(Delegable.Delegable__InvalidCentralRegistry.selector);
        new UniversalBalance(
            ICentralRegistry(address(1)),
            address(dWETH),
            _WETH_ADDRESS
        );
    }

    function test_universalBalanceDeployment_fail_whenTokenIsCToken() public {
        vm.expectRevert(
            UniversalBalance.UniversalBalance__InvalidParameter.selector
        );
        new UniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(cBALRETH),
            _WETH_ADDRESS
        );
    }

    function test_universalBalanceDeployment_success() public {
        universalBalance = new UniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(dWETH),
            _WETH_ADDRESS
        );

        assertEq(
            address(universalBalance.centralRegistry()),
            address(centralRegistry)
        );
        assertEq(address(universalBalance.linkedDToken()), address(dWETH));
        assertEq(universalBalance.WETH(), _WETH_ADDRESS);
        assertEq(
            weth.allowance(address(universalBalance), address(dWETH)),
            type(uint256).max
        );
    }
}
