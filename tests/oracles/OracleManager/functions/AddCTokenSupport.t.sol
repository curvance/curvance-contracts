// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";

contract AddCTokenSupportTest is TestBaseOracleManager {
    function setUp() public override {
        super.setUp();

        _deployBorrowableCUSDC();
    }

    function test_addCTokenSupport_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(OracleManager.OracleManager__Unauthorized.selector);
        oracleManager.addCTokenSupport(address(borrowableCUSDC));
    }

    function test_addCTokenSupport_fail_whenCTokenIsAlreadyConfigured()
        public
    {
        oracleManager.addCTokenSupport(address(borrowableCUSDC));

        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.addCTokenSupport(address(borrowableCUSDC));
    }

    function test_addCTokenSupport_fail_whenCTokenIsInvalid() public {
        vm.expectRevert();
        oracleManager.addCTokenSupport(address(1));
    }

    function test_addCTokenSupport_success() public {
        (bool isCToken, address underlying) = oracleManager.cTokens(
            address(borrowableCUSDC)
        );

        assertFalse(isCToken);
        assertEq(underlying, address(0));

        oracleManager.addCTokenSupport(address(borrowableCUSDC));

        (isCToken, underlying) = oracleManager.cTokens(address(borrowableCUSDC));

        assertTrue(isCToken);
        assertEq(underlying, _USDC_ADDRESS);

        _addSinglePriceFeed();

        assertTrue(oracleManager.isSupportedAsset(_USDC_ADDRESS));
    }
}
