// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { MockERC20Token } from "contracts/mocks/MockERC20Token.sol";
import { IMToken } from "contracts/interfaces/market/IMToken.sol";

contract TestNonCollateralRedeem is TestBaseMarket {
    function setUp() public override {
        super.setUp();
    }

    function test_PartialCollateralizedWithdraw() public {
        // Get underlying
        MockERC20Token balRETH = MockERC20Token(cBALRETH.underlying());
        MockERC20Token USDC = MockERC20Token(dUSDC.underlying());

        // Prepare token balances
        deal(address(balRETH), address(this), 10e18);
        deal(address(USDC), address(this), 1_000_000e6);

        // Approve underlying tokens
        balRETH.approve(address(cBALRETH), 10e18);
        USDC.approve(address(dUSDC), 1_000_000e6);

        // List tokens
        marketManager.listToken(address(cBALRETH));
        marketManager.listToken(address(dUSDC));
        gaugePool.start(address(marketManager));

        // Config collateral token
        marketManager.updateCollateralToken(
            IMToken(address(cBALRETH)),
            7000,
            4000,
            3000,
            200,
            400,
            0,
            1000
        );
        address[] memory mTokens = new address[](1);
        mTokens[0] = address(cBALRETH);
        uint256[] memory newCollateralCaps = new uint256[](1);
        newCollateralCaps[0] = 1_000_000e18;
        marketManager.setCTokenCollateralCaps(mTokens, newCollateralCaps);

        // Deposit 1 CBALRETH
        cBALRETH.deposit(1e18, address(this));
        // Deposit & Collateralize 1 CBALRETH
        cBALRETH.depositAsCollateral(1e18, address(this));
        // Lend so there is something to borrow
        dUSDC.mint(100_000e6);
        // Do a partial borrow
        dUSDC.borrow(750e6);
        // Fast forward to get past minimum hold
        vm.warp(block.timestamp + 1 days);
        // Withdraw 1 CBALRETH (which has not been collateralized yet)
        cBALRETH.redeem(1e18, address(this), address(this));
    }
}
