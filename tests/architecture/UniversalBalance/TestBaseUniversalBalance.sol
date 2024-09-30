// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";
import { DToken } from "contracts/market/collateral/DToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract TestBaseUniversalBalance is TestBaseMarket {
    UniversalBalance public universalBalance;
    DToken public dWETH;

    function setUp() public virtual override {
        super.setUp();

        dWETH = _deployDToken(_WETH_ADDRESS);

        universalBalance = new UniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(dWETH),
            _WETH_ADDRESS
        );

        deal(_WETH_ADDRESS, address(this), 10e18);
        deal(user1, _ONE);

        weth.approve(address(dWETH), 10e18);
        marketManager.listToken(address(dWETH));
        oracleRouter.addMTokenSupport(address(dWETH));

        dWETH.depositReserves(_ONE + 1);
    }
}
