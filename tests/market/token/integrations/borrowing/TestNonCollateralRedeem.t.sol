// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MockERC20Token } from "contracts/mocks/MockERC20Token.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

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

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(strategyCBALRETH);
        tokenConfig.collRatio = 7000;
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.minEffectiveCloseFactor = 2000;
        tokenConfig.maxEffectiveCloseFactor = 5000;
        tokenConfig.baseCFactor = 1000;
        tokenConfig.collateralCap = 100_000e18;
        tokenConfig.debtCap = 0;

        marketManagerIsolated.updateTokenConfig(tokenConfig);

        tokenConfig.cToken = address(borrowableCUSDC);
        tokenConfig.debtCap = 100_000e6;
        marketManagerIsolated.updateTokenConfig(tokenConfig);

        // Deposit 1 strategyCBALRETH
        strategyCBALRETH.deposit(1e18, address(this));
        // Deposit & Collateralize 1 strategyCBALRETH
        strategyCBALRETH.depositAsCollateral(1e18, address(this));
        // Lend so there is something to borrow
        borrowableCUSDC.deposit(100_000e6, address(this));
        // Do a partial borrow
        borrowableCUSDC.borrow(750e6);
        // Fast forward to get past minimum hold
        vm.warp(block.timestamp + 1 days);
        // Withdraw 1 strategyCBALRETH (which has not been collateralized yet)
        strategyCBALRETH.redeem(1e18, address(this), address(this));
    }
}
