// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { NativeUniversalBalance } from "contracts/architecture/NativeUniversalBalance.sol";
import { EToken } from "contracts/market/token/EToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract TestBaseNativeUniversalBalance is TestBaseMarketIsolated {
    NativeUniversalBalance public nativeUniversalBalance;
    EToken public eWETH;

    function setUp() public virtual override {
        super.setUp();

        eWETH = _deployEToken(_WETH_ADDRESS);

        nativeUniversalBalance = new NativeUniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(eWETH),
            _WETH_ADDRESS
        );

        _prepareWETH(address(this), 10e18);
        _prepareBALRETH(address(this), 1000e18);
        deal(user1, _ONE);

        weth.approve(address(eWETH), 10e18);
        balRETH.approve(address(pBALRETH), 1000e18);
        marketManagerIsolated.listTokens(address(pBALRETH), address(eWETH));
        oracleManager.addMTokenSupport(address(eWETH));

        eWETH.depositReserves(_ONE + 1);

        vm.prank(user1);
        weth.approve(address(nativeUniversalBalance), type(uint256).max);
    }
}
