// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { UniversalBalanceNative } from "contracts/architecture/UniversalBalanceNative.sol";
import { EToken } from "contracts/market/token/EToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract TestBaseUniversalBalanceNative is TestBaseMarket {
    UniversalBalanceNative public universalBalanceNative;
    EToken public eWETH;

    function setUp() public virtual override {
        super.setUp();

        eWETH = _deployEToken(_WETH_ADDRESS);

        universalBalanceNative = new UniversalBalanceNative(
            ICentralRegistry(address(centralRegistry)),
            address(eWETH),
            _WETH_ADDRESS
        );

        _prepareWETH(address(this), 10e18);
        deal(user1, _ONE);

        weth.approve(address(eWETH), 10e18);
        marketManager.listToken(address(eWETH));
        oracleManager.addMTokenSupport(address(eWETH));

        eWETH.depositReserves(_ONE + 1);

        vm.prank(user1);
        weth.approve(address(universalBalanceNative), type(uint256).max);
    }
}
