// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

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

        address underlying = oracleManager.cTokens(address(borrowableCUSDC));
        assertEq(underlying, _USDC_ADDRESS);

        oracleManager.removeCTokenSupport(address(borrowableCUSDC));

        underlying = oracleManager.cTokens(address(borrowableCUSDC));
        assertEq(underlying, address(0));
    }
}
