// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { WstETHAggregator } from "contracts/oracles/adaptors/wrappedAggregators/WstETHAggregator.sol";

import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";
import { IWstETH } from "contracts/interfaces/external/lido/IWstETH.sol";

import { TestBase } from "tests/utils/TestBase.sol";

contract TestWstETHAggregator is TestBase {
    address internal _WSTETH_ADDRESS =
        0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    address internal _CHAINLINK_STETH_USD =
        0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8;

    WstETHAggregator public aggregator;

    function setUp() public {
        _fork(18031848);

        aggregator = new WstETHAggregator(
            _WSTETH_ADDRESS,
            _STETH_ADDRESS,
            _CHAINLINK_STETH_USD
        );
    }
    
    function testLatestRoundData() public {
        (, int256 wstethPrice, , , ) = aggregator.latestRoundData();
        (, int256 stethPrice, , , ) = IChainlink(_CHAINLINK_STETH_USD)
            .latestRoundData();
        assertEq(
            uint256(wstethPrice),
            (uint256(stethPrice) *
                IWstETH(_WSTETH_ADDRESS).getStETHByWstETH(1e18)) / 1e18
        );
    }
}
