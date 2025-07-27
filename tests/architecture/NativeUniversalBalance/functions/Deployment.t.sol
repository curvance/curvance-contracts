// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseNativeUniversalBalance } from "../TestBaseNativeUniversalBalance.sol";
import { NativeUniversalBalance } from "contracts/architecture/NativeUniversalBalance.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";

contract NativeUniversalBalanceDeploymentTest is
    TestBaseNativeUniversalBalance
{
    function test_nativeUniversalBalanceDeployment_fail_whenCentralRegistryIsInvalid()
        public
    {
        vm.expectRevert(
            PluginDelegable.PluginDelegable__InvalidCentralRegistry.selector
        );
        new NativeUniversalBalance(
            ICentralRegistry(address(1)),
            address(borrowableCWETH),
            _WETH_ADDRESS
        );
    }

    function test_nativeUniversalBalanceDeployment_fail_whenTokenIsPToken()
        public
    {
        // `bytes4(keccak256(bytes("UniversalBalance__InvalidParameter()")))`.
        vm.expectRevert(bytes4(0xc75f2a32));
        new NativeUniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(strategyCBALRETH),
            _WETH_ADDRESS
        );
    }

    function test_nativeUniversalBalanceDeployment_fail_whenUnderlyingTokenMismatch()
        public
    {
        vm.expectRevert(
            NativeUniversalBalance
                .NativeUniversalBalance__UnderlyingTokenMismatch
                .selector
        );
        new NativeUniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(borrowableCWETH),
            _USDC_ADDRESS
        );
    }

    function test_nativeUniversalBalanceDeployment_success() public {
        nativeUniversalBalance = new NativeUniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(borrowableCWETH),
            _WETH_ADDRESS
        );

        assertEq(
            address(nativeUniversalBalance.centralRegistry()),
            address(centralRegistry)
        );
        assertEq(
            address(nativeUniversalBalance.linkedToken()),
            address(borrowableCWETH)
        );
        assertEq(nativeUniversalBalance.underlying(), _WETH_ADDRESS);
        assertEq(
            weth.allowance(address(nativeUniversalBalance), address(borrowableCWETH)),
            type(uint256).max
        );
    }
}
