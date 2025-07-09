// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract TestBaseUniversalBalance is TestBaseMarketIsolated {
    UniversalBalance public universalBalance;

    function setUp() public virtual override {
        super.setUp();

        universalBalance = new UniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(borrowableCUSDC)
        );

        _prepareUSDC(address(this), 1000e6);
        deal(user1, _ONE);

        _prepareBALRETH(address(this), 1000e18);

        usdc.approve(address(borrowableCUSDC), 1000e6);
        balRETH.approve(address(simpleCBALRETH), 1000e18);
        marketManagerIsolated.listTokens(address(simpleCBALRETH), address(borrowableCUSDC));

        borrowableCUSDC.deposit(1000e6, address(this));

        vm.prank(user1);
        usdc.approve(address(universalBalance), type(uint256).max);
    }
}
