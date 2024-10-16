// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract TestBaseUniversalBalance is TestBaseMarket {
    UniversalBalance public universalBalance;

    function setUp() public virtual override {
        super.setUp();

        universalBalance = new UniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(eUSDC)
        );

        deal(_USDC_ADDRESS, address(this), 1000e6);
        deal(user1, _ONE);

        usdc.approve(address(eUSDC), 1000e6);
        marketManager.listToken(address(eUSDC));

        eUSDC.depositReserves(100e6);

        vm.prank(user1);
        usdc.approve(address(universalBalance), type(uint256).max);
    }
}
