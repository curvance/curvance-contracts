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
        MockERC20Token balRETH = MockERC20Token(pBALRETH.asset());
        MockERC20Token USDC = MockERC20Token(eUSDC.asset());

        // Prepare token balances
        _prepareBALRETH(address(this), 10e18);
        deal(address(USDC), address(this), 1_000_000e6);

        // Approve underlying tokens
        balRETH.approve(address(pBALRETH), 10e18);
        USDC.approve(address(eUSDC), 1_000_000e6);

        // List tokens
        marketManagerIsolated.listTokens(address(pBALRETH), address(eUSDC));

        MarketManagerIsolated.TokenConfig memory configToken0;
        configToken0.cToken = address(pBALRETH);
        configToken0.collRatio = 7000;
        configToken0.collReqSoft = 4000;
        configToken0.collReqHard = 3000;
        configToken0.liqIncBase = 1000;
        configToken0.liqIncHard = 1500;
        configToken0.liqIncMin = 500;
        configToken0.liqIncMax = 2000;
        configToken0.minEffectiveCloseFactor = 2000;
        configToken0.maxEffectiveCloseFactor = 5000;
        configToken0.baseCFactor = 1000;
        configToken0.collateralCap = 100_000e18;
        configToken0.debtCap = 0;

        marketManagerIsolated.updateTokenConfig(configToken0);

        MarketManagerIsolated.TokenConfig memory configToken1;
        configToken1.cToken = address(eUSDC);
        configToken1.debtCap = 100_000e6;
        marketManagerIsolated.updateTokenConfig(configToken1);


        // Deposit 1 pBALRETH
        pBALRETH.deposit(1e18, address(this));
        // Deposit & Collateralize 1 pBALRETH
        pBALRETH.depositAsCollateral(1e18, address(this));
        // Lend so there is something to borrow
        eUSDC.deposit(100_000e6, address(this));
        // Do a partial borrow
        eUSDC.borrow(750e6);
        // Fast forward to get past minimum hold
        vm.warp(block.timestamp + 1 days);
        // Withdraw 1 pBALRETH (which has not been collateralized yet)
        pBALRETH.redeem(1e18, address(this), address(this));
    }
}
