// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MockERC20Token } from "contracts/mocks/MockERC20Token.sol";

contract TestNonCollateralRedeem is TestBaseMarketIsolated {
    function setUp() public override {
        super.setUp();
    }

    function test_partialCollateralizedWithdraw() public {
        // Get underlying
        MockERC20Token balRETH = MockERC20Token(strategyCBALRETH.asset());
        MockERC20Token USDC = MockERC20Token(borrowableCUSDC.asset());

        // Prepare token balances
        _prepareBALRETH(address(this), 10e18);
        deal(address(USDC), address(this), 1_000_000e6);

        // Approve underlying tokens
        balRETH.approve(address(strategyCBALRETH), 10e18);
        USDC.approve(address(borrowableCUSDC), 1_000_000e6);

        // List tokens
        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 100_000e6);

        // Deposit 1 strategyCBALRETH
        strategyCBALRETH.deposit(1e18, address(this));
        // Deposit & Collateralize 1 strategyCBALRETH
        strategyCBALRETH.depositAsCollateral(1e18, address(this));
        // Lend so there is something to borrow.
        borrowableCUSDC.deposit(100_000e6, address(this));

        // Do a partial borrow.
        borrowableCUSDC.borrow(750e6, address(this));
        // Fast forward to get past minimum hold
        vm.warp(block.timestamp + 1 days);
        // Withdraw 1 strategyCBALRETH (which has not been collateralized yet)
        strategyCBALRETH.redeem(1e18, address(this), address(this));
    }
}
