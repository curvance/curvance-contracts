// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";
import { EToken } from "contracts/market/token/EToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract TestBaseUniversalBalance is TestBaseMarket {
    UniversalBalance public universalBalance;
    EToken public eWETH;

    function setUp() public virtual override {
        super.setUp();

        eWETH = _deployEToken(_WETH_ADDRESS);

        universalBalance = new UniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(eWETH),
            _WETH_ADDRESS
        );

        deal(_WETH_ADDRESS, address(this), 10e18);
        deal(user1, _ONE);

        weth.approve(address(eWETH), 10e18);
        marketManager.listToken(address(eWETH));
        oracleManager.addMTokenSupport(address(eWETH));

        eWETH.depositReserves(_ONE + 1);
    }
}
