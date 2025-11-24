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

        deal(address(LP_wstETH_24Dec2025), address(this), 77777);

        usdc.approve(address(borrowableCUSDC), 1000e6 + 77777);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 77777);
        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(borrowableCUSDC));

        console2.log(" SET UP DEPOSIT");
        borrowableCUSDC.deposit(1000e6, address(this));
        console2.log(" SET UP DEPOSIT DONE");

        vm.prank(user1);
        usdc.approve(address(universalBalance), type(uint256).max);
    }
}
