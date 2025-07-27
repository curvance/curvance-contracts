// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

contract TestBaseStrategyCTokenWithExitFee is TestBaseMarketIsolated {

    function setUp() public virtual override {
        super.setUp();

        _prepareBALRETH(user1, _ONE);
        _prepareBALRETH(address(this), _ONE);

        _prepareDAI(address(this), _ONE);

        SafeTransferLib.safeApprove(
            _BAL_WETH_RETH_ADDRESS,
            address(strategyCBALRETHWithExitFee),
            _ONE
        );

        dai.approve(address(borrowableCDAI), _ONE);
        marketManagerIsolated.listTokens(address(strategyCBALRETHWithExitFee), address(borrowableCDAI));
    }
}
