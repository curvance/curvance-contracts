// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseOracleRouter } from "../TestBaseOracleRouter.sol";
import { OracleRouter } from "contracts/oracles/OracleRouter.sol";

contract AddMTokenSupportTest is TestBaseOracleRouter {
    function setUp() public override {
        super.setUp();

        _deployDUSDC();
    }

    function test_addMTokenSupport_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(OracleRouter.OracleRouter__Unauthorized.selector);
        oracleRouter.addMTokenSupport(address(dUSDC));
    }

    function test_addMTokenSupport_fail_whenMTokenIsAlreadyConfigured()
        public
    {
        oracleRouter.addMTokenSupport(address(dUSDC));

        vm.expectRevert(OracleRouter.OracleRouter__InvalidParameter.selector);
        oracleRouter.addMTokenSupport(address(dUSDC));
    }

    function test_addMTokenSupport_fail_whenMTokenIsInvalid() public {
        vm.expectRevert();
        oracleRouter.addMTokenSupport(address(1));
    }

    function test_addMTokenSupport_success() public {
        (bool isMToken, address underlying) = oracleRouter.mTokenAssets(
            address(dUSDC)
        );

        assertFalse(isMToken);
        assertEq(underlying, address(0));

        oracleRouter.addMTokenSupport(address(dUSDC));

        (isMToken, underlying) = oracleRouter.mTokenAssets(address(dUSDC));

        assertTrue(isMToken);
        assertEq(underlying, _USDC_ADDRESS);

        _addSinglePriceFeed();

        assertTrue(oracleRouter.isSupportedAsset(_USDC_ADDRESS));
    }
}
