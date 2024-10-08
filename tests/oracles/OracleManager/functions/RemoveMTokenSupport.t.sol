// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";

contract RemoveMTokenSupportTest is TestBaseOracleManager {
    function test_removeMTokenSupport_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(OracleManager.OracleManager__Unauthorized.selector);
        oracleManager.removeMTokenSupport(address(eUSDC));
    }

    function test_removeMTokenSupport_fail_whenMTokenIsNotConfigured() public {
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.removeMTokenSupport(address(eUSDC));
    }

    function test_removeMTokenSupport_success() public {
        oracleManager.addMTokenSupport(address(eUSDC));

        (bool isMToken, address underlying) = oracleManager.mTokenAssets(
            address(eUSDC)
        );

        assertTrue(isMToken);
        assertEq(underlying, _USDC_ADDRESS);

        oracleManager.removeMTokenSupport(address(eUSDC));

        (isMToken, underlying) = oracleManager.mTokenAssets(address(eUSDC));

        assertFalse(isMToken);
        assertEq(underlying, address(0));
    }
}
