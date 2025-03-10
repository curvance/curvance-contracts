// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract WithdrawReservesMultiTest is TestBaseMarket {
    address[] public eTokens;

    function setUp() public override {
        super.setUp();

        eTokens.push(address(eUSDC));
        eTokens.push(address(eDAI));

        _prepareUSDC(address(this), 1000e6);
        _prepareDAI(address(this), 1000e18);

        usdc.approve(address(eUSDC), 1000e6);
        dai.approve(address(eDAI), 1000e18);

        marketManager.listToken(address(eUSDC));
        marketManager.listToken(address(eDAI));

        eUSDC.depositReserves(100e6);
        eDAI.depositReserves(100e18);
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
        assertEq(usdc.balanceOf(address(eUSDC)), 100e6 + 42069);
        assertEq(dai.balanceOf(address(eDAI)), 100e18 + 42069);

        centralRegistry.withdrawReservesMulti(eTokens);

        assertEq(usdc.balanceOf(address(eUSDC)), 42069);
        assertEq(dai.balanceOf(address(eDAI)), 42069);
    }
}
