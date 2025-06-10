// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseETokenIsolated } from "tests/market/token/EToken/TestBaseETokenIsolated.t.sol";

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
        usdc.approve(address(eUSDC), 250e6);
        eUSDC.liquidateExact(
            accounts,
            debtAmounts,
            address(pBALRETH)
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
            pBALRETH.balanceOf(user1),
            _ONE - (500e18 * _ONE) / balRETHPrice,
            0.02e18
        );
        assertEq(pBALRETH.exchangeRateCached(), _ONE);

        assertEq(eUSDC.balanceOf(user1), 0);
        assertApproxEqRel(eUSDC.debtBalanceCached(user1), 750e6, 0.01e18);
        assertApproxEqRel(eUSDC.exchangeRateCached(), _ONE, 0.01e18);
    }
}