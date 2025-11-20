// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseOracleManager } from "tests/oracles/OracleManager/TestBaseOracleManager.sol";

import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { StaticPriceAggregator } from "contracts/oracles/adaptors/wrappedAggregators/StaticPriceAggregator.sol";

contract MockStaticPriceAggregator is StaticPriceAggregator {
    constructor(uint256 staticPrice) StaticPriceAggregator(staticPrice) {}
}

contract TestStaticPriceAggregator is TestBaseOracleManager {
    address internal _mockAsset = makeAddr("mockAsset");

    StaticPriceAggregator public aggregator;

    function setUp() public override {
        super.setUp();

        aggregator = new MockStaticPriceAggregator(
            1e8
        );
    }

    function testLatestRoundData() public view {
        (, int256 price, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = aggregator.latestRoundData();
        assertEq(uint256(price), 1e8);
        assertEq(startedAt, block.timestamp);
        assertEq(updatedAt, block.timestamp);
        assertEq(answeredInRound, 1);
    }

    function testLatestRound() public view {
        uint256 round = aggregator.latestRound();
        assertEq(round, 1);
    }

    function testGetRoundData() public view {
        (, int256 price, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = aggregator.getRoundData(1);
        assertEq(uint256(price), 1e8);
        assertEq(startedAt, block.timestamp);
        assertEq(updatedAt, block.timestamp);
        assertEq(answeredInRound, 1);
    }

    function testDecimals() public view {
        assertEq(aggregator.decimals(), 18);
    }

    function testConfig_fail_zeroPrice() public {
        vm.expectRevert(abi.encodeWithSelector(StaticPriceAggregator.StaticPriceAggregator__InvalidConfig.selector, 0));
        new MockStaticPriceAggregator(0);
    }

    function testGetPrice_withChainlinkAdaptor() public {
        chainlinkAdaptor.addAsset(_mockAsset, true, address(aggregator), 0);
        oracleManager.addAssetPricingAdaptor(_mockAsset, address(chainlinkAdaptor), 100, 50, 100, 50);

        (uint256 price, uint256 errorCode) = oracleManager.getPrice(_mockAsset, true, false);
        assertEq(price, 1e18);
        assertEq(errorCode, 0);
    }
}
