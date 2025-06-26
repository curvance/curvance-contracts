// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";

contract AddMTokenSupportTest is TestBaseOracleManager {
    function setUp() public override {
        super.setUp();

        _deployEUSDC();
    }

    function test_addCTokenSupport_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(OracleManager.OracleManager__Unauthorized.selector);
        oracleManager.addCTokenSupport(address(eUSDC));
    }

    function test_addCTokenSupport_fail_whenMTokenIsAlreadyConfigured()
        public
    {
        oracleManager.addCTokenSupport(address(eUSDC));

        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.addCTokenSupport(address(eUSDC));
    }

    function test_addCTokenSupport_fail_whenMTokenIsInvalid() public {
        vm.expectRevert();
        oracleManager.addCTokenSupport(address(1));
    }

    function test_addCTokenSupport_success() public {
        (bool isMToken, address underlying) = oracleManager.mTokenAssets(
            address(eUSDC)
        );

        assertFalse(isMToken);
        assertEq(underlying, address(0));

        oracleManager.addCTokenSupport(address(eUSDC));

        (isMToken, underlying) = oracleManager.mTokenAssets(address(eUSDC));

        assertTrue(isMToken);
        assertEq(underlying, _USDC_ADDRESS);

        _addSinglePriceFeed();

        assertTrue(oracleManager.isSupportedAsset(_USDC_ADDRESS));
    }
}
