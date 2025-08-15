// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { NativeUniversalBalance } from "contracts/architecture/NativeUniversalBalance.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract TestBaseNativeUniversalBalance is TestBaseMarketIsolated {
    NativeUniversalBalance public nativeUniversalBalance;
    BorrowableCToken public borrowableCWETH;

    function setUp() public virtual override {
        super.setUp();

        borrowableCWETH = _deployBorrowableCToken(_WETH_ADDRESS);

        nativeUniversalBalance = new NativeUniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(borrowableCWETH),
            _WETH_ADDRESS
        );

        _prepareWETH(address(this), 10e18);
        _prepareBALRETH(address(this), 1000e18);
        deal(user1, _ONE);

        weth.approve(address(borrowableCWETH), 10e18);
        balRETH.approve(address(strategyCBALRETH), 1000e18);
        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCWETH));
        oracleManager.addCTokenSupport(address(borrowableCWETH));

        borrowableCWETH.deposit(_ONE + 1, address(this));

        vm.prank(user1);
        weth.approve(address(nativeUniversalBalance), type(uint256).max);
    }
}
