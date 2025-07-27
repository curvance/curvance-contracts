// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { BorrowableCTokenWithGauge } from "contracts/market/token/withGauge/BorrowableCTokenWithGauge.sol";
import { SimpleCTokenWithGauge } from "contracts/market/token/withGauge/SimpleCTokenWithGauge.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract TestBaseGaugeManager is TestBaseMarketIsolated {

    function setUp() public virtual override {
        super.setUp();
    }

    // Deploy BorrowableCTokenWithGauge.
    function _deployBorrowableCTokenWithGauge(
        address token
    ) internal returns (address borrowableCUSDCWithGauge) {
        borrowableCUSDCWithGauge = address(new BorrowableCTokenWithGauge(
            ICentralRegistry(address(centralRegistry)),
            IERC20(token),
            address(marketManagerIsolated),
            _deployDynamicInterestRateModel(token)
        )); 

        interestRateModels[block.chainid][token].setLinkedToken(
            address(borrowableCUSDCWithGauge)
        );
    }

    // Deploy SimpleCTokenWithGauge.
    function _deploySimpleCTokenWithGauge(
        address token
    ) internal returns (address simpleCTokenWithGauge) {
        simpleCTokenWithGauge = address(new BorrowableCTokenWithGauge(
            ICentralRegistry(address(centralRegistry)),
            IERC20(token),
            address(marketManagerIsolated),
            _deployDynamicInterestRateModel(token)
        )); 
    }
}
