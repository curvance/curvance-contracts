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
        MockERC20Token balRETH = MockERC20Token(pBALRETH.underlying());
        MockERC20Token USDC = MockERC20Token(eUSDC.underlying());

        // Prepare token balances
        _prepareBALRETH(address(this), 10e18);
        deal(address(USDC), address(this), 1_000_000e6);

        // Approve underlying tokens
        balRETH.approve(address(pBALRETH), 10e18);
        USDC.approve(address(eUSDC), 1_000_000e6);

        // List tokens
        marketManagerIsolated.listToken(address(pBALRETH));
        marketManagerIsolated.listToken(address(eUSDC));

        // Config position token
        marketManagerIsolated.updatePositionToken(
            address(pBALRETH),
            7000,
            4000,
            3000,
            200,
            400,
            1000
        );
        address[] memory mTokens = new address[](1);
        mTokens[0] = address(pBALRETH);
        uint256[] memory newCollateralCaps = new uint256[](1);
        newCollateralCaps[0] = 1_000_000e18;
        marketManagerIsolated.setCollateralCaps(mTokens, newCollateralCaps);

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
