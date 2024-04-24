// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { Test } from "forge-std/Test.sol";
import { Faucet } from "contracts/testnet/Faucet.sol";
import { TestnetToken } from "contracts/mocks/TestnetToken.sol";
import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { MockERC20Token } from "contracts/mocks/MockERC20Token.sol";
import { IMToken } from "contracts/interfaces/market/IMToken.sol";
import { CurvanceAuxiliaryData } from "contracts/indexing/CurvanceAuxiliaryData.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import "forge-std/console.sol";

contract Austin is TestBaseMarket {
    address token1;
    address token2;
    address token3;
    Faucet faucet;
    CurvanceAuxiliaryData aux;

    function setUp() public override {
        super.setUp();

        faucet = new Faucet();
        token1 = address(new TestnetToken("Token1", "T1", 18));
        token2 = address(new TestnetToken("Token2", "T2", 8));
        token3 = address(new TestnetToken("Token3", "T3", 6));

        vm.startPrank(0xBAaf22d2Bc4Ac001BBDDA7De73d3ae1bA71dfDDB);
        TestnetToken(token1).transfer(address(faucet), 100000);
        TestnetToken(token2).transfer(address(faucet), 100000);
        TestnetToken(token3).transfer(address(faucet), 100000);
        vm.stopPrank();

        aux = new CurvanceAuxiliaryData(ICentralRegistry(address(centralRegistry)));
    }

    function test_marketGetAllData() public {
        test_collateralizedWithdraw();
        aux.getAllMarketData(address(this));
    }

    function test_collateralizedWithdraw() public {
        // Get underlying
        MockERC20Token balRETH = MockERC20Token(cBALRETH.underlying());
        MockERC20Token USDC = MockERC20Token(dUSDC.underlying());

        // Need to steal 10 balRETH & 1M USDC from some other wallets
        address currentUser = address(this);
        vm.prank(0x79eF6103A513951a3b25743DB509E267685726B7);
        balRETH.transfer(currentUser, 10e18);
        vm.prank(0x0A59649758aa4d66E25f08Dd01271e891fe52199);
        USDC.transfer(currentUser, 1_000_000e6);

        // Approve stolen money to be used
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
        // Borrow 25% of maxBorrow
        (uint256 collateral, uint256 maxDebt, uint256 debt) = marketManager.statusOf(address(this));
        uint256 usdcPrice = aux.getTokenPrice(address(dUSDC));
        dUSDC.borrow(maxDebt / 4 / usdcPrice);
        // Fast forward to get past minimum hold
        vm.warp(block.timestamp + 1 days);
        // Withdraw 1 CBALRETH (which has not been collateralized yet)
        cBALRETH.redeem(1e18, address(this), address(this));
    }

    function test_Multiclaim() public {
        address[] memory tokens = new address[](3);
        tokens[0] = token1;
        tokens[1] = token2;
        tokens[2] = token3;

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1000;
        amounts[1] = 1000;
        amounts[2] = 1000;

        faucet.multiClaim(address(this), tokens, amounts);

        assertEq(TestnetToken(token1).balanceOf(address(this)), 1000);
        assertEq(TestnetToken(token2).balanceOf(address(this)), 1000);
        assertEq(TestnetToken(token3).balanceOf(address(this)), 1000);

        assertEq(TestnetToken(token1).balanceOf(address(faucet)), 99000);
        assertEq(TestnetToken(token2).balanceOf(address(faucet)), 99000);
        assertEq(TestnetToken(token3).balanceOf(address(faucet)), 99000);
    }
}
