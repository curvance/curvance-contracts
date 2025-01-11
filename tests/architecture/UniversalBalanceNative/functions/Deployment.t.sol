// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseUniversalBalanceNative } from "../TestBaseUniversalBalanceNative.sol";
import { UniversalBalanceNative } from "contracts/architecture/UniversalBalanceNative.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";

contract UniversalBalanceNativeDeploymentTest is
    TestBaseUniversalBalanceNative
{
    function test_universalBalanceNativeDeployment_fail_whenCentralRegistryIsInvalid()
        public
    {
        vm.expectRevert(
            PluginDelegable.PluginDelegable__InvalidCentralRegistry.selector
        );
        new UniversalBalanceNative(
            ICentralRegistry(address(1)),
            address(eWETH),
            _WETH_ADDRESS
        );
    }

    function test_universalBalanceNativeDeployment_fail_whenTokenIsPToken()
        public
    {
        // `bytes4(keccak256(bytes("UniversalBalance__InvalidParameter()")))`.
        vm.expectRevert(0xc75f2a32);
        new UniversalBalanceNative(
            ICentralRegistry(address(centralRegistry)),
            address(pBALRETH),
            _WETH_ADDRESS
        );
    }

    function test_universalBalanceNativeDeployment_fail_whenUnderlyingTokenMismatch()
        public
    {
        vm.expectRevert(
            UniversalBalanceNative
                .UniversalBalanceNative__UnderlyingTokenMismatch
                .selector
        );
        new UniversalBalanceNative(
            ICentralRegistry(address(centralRegistry)),
            address(eWETH),
            _USDC_ADDRESS
        );
    }

    function test_universalBalanceNativeDeployment_success() public {
        universalBalanceNative = new UniversalBalanceNative(
            ICentralRegistry(address(centralRegistry)),
            address(eWETH),
            _WETH_ADDRESS
        );

        assertEq(
            address(universalBalanceNative.centralRegistry()),
            address(centralRegistry)
        );
        assertEq(
            address(universalBalanceNative.linkedEToken()),
            address(eWETH)
        );
        assertEq(universalBalanceNative.underlying(), _WETH_ADDRESS);
        assertEq(
            weth.allowance(address(universalBalanceNative), address(eWETH)),
            type(uint256).max
        );
    }
}
