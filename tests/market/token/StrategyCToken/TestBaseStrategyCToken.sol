// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract TestBaseStrategyCToken is TestBaseMarketIsolated {

    function setUp() public virtual override {
        super.setUp();

        _prepareBALRETH(user1, _ONE);

        {
            _prepareDAI(address(this), 200000e18);
            dai.approve(address(borrowableCDAI), 200000e18);   
        }

        {
            _prepareBALRETH(address(this), 1 ether);
            balRETH.approve(address(strategyCBALRETH), 1 ether);
        }

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCDAI));

        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 100_000e18);
    }
    
}
