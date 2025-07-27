// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";

contract RemoveCTokenSupportTest is TestBaseOracleManager {
    function test_removeCTokenSupport_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(OracleManager.OracleManager__Unauthorized.selector);
        oracleManager.removeCTokenSupport(address(borrowableCUSDC));
    }

    function test_removeCTokenSupport_fail_whenCTokenIsNotConfigured() public {
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.removeCTokenSupport(address(borrowableCUSDC));
    }

    function test_removeCTokenSupport_success() public {
        oracleManager.addCTokenSupport(address(borrowableCUSDC));

        (bool isCToken, address underlying) = oracleManager.cTokenAssets(
            address(borrowableCUSDC)
        );

        assertTrue(isCToken);
        assertEq(underlying, _USDC_ADDRESS);

        oracleManager.removeCTokenSupport(address(borrowableCUSDC));

        (isCToken, underlying) = oracleManager.cTokenAssets(address(borrowableCUSDC));

        assertFalse(isCToken);
        assertEq(underlying, address(0));
    }
}
