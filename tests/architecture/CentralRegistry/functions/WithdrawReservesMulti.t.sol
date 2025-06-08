// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract WithdrawReservesMultiTest is TestBaseMarketIsolated {
    address[] public eTokens;

    function setUp() public override {
        super.setUp();

        eTokens.push(address(eDAI));

        _prepareDAI(address(this), 1000e18);

        dai.approve(address(eDAI), 1000e18);

        marketManagerIsolated.listTokens(address(pBALRETH), address(eDAI));
    }

    function test_withdrawReservesMulti_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.withdrawReservesMulti(eTokens);
    }

    function test_withdrawReservesMulti_fail_whenETokensLengthIsZero() public {
        eTokens.pop();

        vm.expectRevert(
            CentralRegistry.CentralRegistry__ParametersMisconfigured.selector
        );
        centralRegistry.withdrawReservesMulti(eTokens);
    }

    function test_withdrawReservesMulti_fail_whenETokenIsPToken() public {
        eTokens.pop();
        eTokens.push(address(pBALRETH));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__ParametersMisconfigured.selector
        );
        centralRegistry.withdrawReservesMulti(eTokens);
    }

    function test_withdrawReservesMulti_success() public {
        assertEq(dai.balanceOf(address(eDAI)), 100e18 + 42069);

        centralRegistry.withdrawReservesMulti(eTokens);

        assertEq(dai.balanceOf(address(eDAI)), 42069);
    }
}
