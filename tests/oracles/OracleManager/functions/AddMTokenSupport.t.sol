// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";

contract AddMTokenSupportTest is TestBaseOracleManager {
    function setUp() public override {
        super.setUp();

        _deployEUSDC();
    }

    function test_addMTokenSupport_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(OracleManager.OracleManager__Unauthorized.selector);
        oracleManager.addMTokenSupport(address(eUSDC));
    }

    function test_addMTokenSupport_fail_whenMTokenIsAlreadyConfigured()
        public
    {
        oracleManager.addMTokenSupport(address(eUSDC));

        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.addMTokenSupport(address(eUSDC));
    }

    function test_addMTokenSupport_fail_whenMTokenIsInvalid() public {
        vm.expectRevert();
        oracleManager.addMTokenSupport(address(1));
    }

    function test_addMTokenSupport_success() public {
        (bool isMToken, address underlying) = oracleManager.mTokenAssets(
            address(eUSDC)
        );

        assertFalse(isMToken);
        assertEq(underlying, address(0));

        oracleManager.addMTokenSupport(address(eUSDC));

        (isMToken, underlying) = oracleManager.mTokenAssets(address(eUSDC));

        assertTrue(isMToken);
        assertEq(underlying, _USDC_ADDRESS);

        _addSinglePriceFeed();

        assertTrue(oracleManager.isSupportedAsset(_USDC_ADDRESS));
    }
}
