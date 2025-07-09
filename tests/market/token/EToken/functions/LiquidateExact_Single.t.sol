// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseETokenIsolated } from "tests/market/token/EToken/TestBaseETokenIsolated.t.sol";

// NOTES:
// 1. test_liquidateExact_single_success fails because of the lack of bad debt expected

contract LiquidateExactSingleTest is TestBaseETokenIsolated {
    function setUp() public override {
        super.setUp();

        _prepareLiquidation();
    }

    // Test a single liquidation
    function test_liquidateExact_single_success() public {
        address[] memory accounts = new address[](1);
        accounts[0] = user1;
        uint256[] memory debtAmounts = new uint256[](1);
        debtAmounts[0] = 250e6;
     
        vm.startPrank(user2);
        usdc.approve(address(borrowableCUSDC), 250e6);
        borrowableCUSDC.liquidateExact(
            accounts,
            debtAmounts,
            address(simpleCBALRETH)
        );
        vm.stopPrank();

        _checkLiquidationResult();
    }

    function _checkLiquidationResult() internal {
        (uint256 balRETHPrice, ) = oracleManager.getPrice(
            address(balRETH),
            true,
            true
        );

        assertApproxEqRel(
            simpleCBALRETH.balanceOf(user1),
            _ONE - (500e18 * _ONE) / balRETHPrice,
            0.02e18
        );
        assertEq(simpleCBALRETH.exchangeRate(), _ONE);

        assertEq(borrowableCUSDC.balanceOf(user1), 0);
        assertApproxEqRel(borrowableCUSDC.debtBalance(user1), 750e6, 0.01e18);
        assertApproxEqRel(borrowableCUSDC.exchangeRate(), _ONE, 0.01e18);
    }
}