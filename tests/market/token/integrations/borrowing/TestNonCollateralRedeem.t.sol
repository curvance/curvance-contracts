// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MockERC20Token } from "contracts/mocks/MockERC20Token.sol";

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

        // Config position token
        marketManagerIsolated.updatePositionToken(
            7000,    // collRatio 70%
            4000,    // collReqSoft 40%
            3000,    // collReqHard 25%
            1000,    // liqIncBase 10%
            1500,    // liqIncHard 15%
            500,     // liqIncMin 5%
            2000,    // liqIncMax 20%
            2000,    // minEffectiveCFactor 20%
            5000,    // maxEffectiveCFactor 50%
            1000     // baseCFactor 20%
        );
        address[] memory tokens = new address[](1);
        tokens[0] = address(pBALRETH);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 1_000_000e18;
        marketManagerIsolated.setCollateralCaps(tokens, caps);

        caps[0] = 100_000e6;
        tokens[0] = address(eUSDC);
        marketManagerIsolated.setDebtCaps(tokens, caps);


        // Deposit 1 pBALRETH
        pBALRETH.deposit(1e18, address(this));
        // Deposit & Collateralize 1 pBALRETH
        pBALRETH.depositAsCollateral(1e18, address(this));
        // Lend so there is something to borrow
        eUSDC.mint(100_000e6);
        // Do a partial borrow
        eUSDC.borrow(750e6);
        // Fast forward to get past minimum hold
        vm.warp(block.timestamp + 1 days);
        // Withdraw 1 pBALRETH (which has not been collateralized yet)
        pBALRETH.redeem(1e18, address(this), address(this));
    }
}
