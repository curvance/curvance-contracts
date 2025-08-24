// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { console2 } from "forge-std/console2.sol";

contract TestBaseUniversalBalance is TestBaseMarketIsolated {
    UniversalBalance public universalBalance;

    function setUp() public virtual override {
        super.setUp();

        universalBalance = new UniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(borrowableCUSDC)
        );

        _prepareUSDC(address(this), 1000e6 + 77777);
        deal(user1, _ONE);

        _prepareBALRETH(address(this), 1000e18);

        usdc.approve(address(borrowableCUSDC), 1000e6 + 77777);
        balRETH.approve(address(strategyCBALRETH), 1000e18);
        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        console2.log(" SET UP DEPOSIT");
        borrowableCUSDC.deposit(1000e6, address(this));
        console2.log(" SET UP DEPOSIT DONE");

        vm.prank(user1);
        usdc.approve(address(universalBalance), type(uint256).max);
    }
}
