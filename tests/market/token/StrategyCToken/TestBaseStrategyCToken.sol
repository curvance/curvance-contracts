// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract TestBaseStrategyCToken is TestBaseMarketIsolated {

    function setUp() public virtual override {
        super.setUp();

        deal(address(LP_wstETH_24Dec2025), user1, _ONE);

        {
            _prepareDAI(address(this), 200000e18);
            dai.approve(address(borrowableCDAI), 200000e18);   
        }

        {
            deal(address(LP_wstETH_24Dec2025), address(this), 1 ether);
            LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 1 ether);
        }

        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(borrowableCDAI));

        _setCTokenConfigBasic(address(pendleStrategyCTokenSTETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 100_000e18);
    }
    
}
