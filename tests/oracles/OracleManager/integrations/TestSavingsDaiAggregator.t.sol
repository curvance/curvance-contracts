// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBase } from "tests/utils/TestBase.sol";

import { SavingsDaiAggregator } from "contracts/oracles/adaptors/wrappedAggregators/SavingsDaiAggregator.sol";
import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";
import { IPotLike } from "contracts/interfaces/external/maker/IPotLike.sol";
import { ISavingsDai } from "contracts/interfaces/external/maker/ISavingsDai.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract TestSavingsDaiAggregator is TestBase {
    address internal _SDAI_ADDRESS =
        0x83F20F44975D03b1b09e64809B757c47f942BEeA;

    SavingsDaiAggregator public aggregator;

    function setUp() public {
        _fork();

        aggregator = new SavingsDaiAggregator(
            _SDAI_ADDRESS,
            _DAI_ADDRESS,
            _CHAINLINK_DAI_USD
        );
    }

    function testLatestRoundData() public view {
        (, int256 sdaiPrice, , , ) = aggregator.latestRoundData();
        (, int256 daiPrice, , , ) = IChainlink(_CHAINLINK_DAI_USD)
            .latestRoundData();
        assertEq(
            uint256(sdaiPrice),
            ((uint256(daiPrice) *
                IPotLike(ISavingsDai(_SDAI_ADDRESS).pot()).chi()) / 1e9) / 1e18
        );
    }

    function testSavingsDaiAggregator_DifferentDecimals() public {
        uint8 newDecimals = 6;

        vm.mockCall(
            _DAI_ADDRESS,
            abi.encodeWithSelector(IERC20.decimals.selector),
            abi.encode(uint8(newDecimals))
        );
    
        assertEq(IERC20(_DAI_ADDRESS).decimals(), newDecimals);

        aggregator = new SavingsDaiAggregator(
            _SDAI_ADDRESS,
            _DAI_ADDRESS,
            _CHAINLINK_DAI_USD
        );

        (, int256 sdaiPrice, , , ) = aggregator.latestRoundData();
        (, int256 daiPrice, , , ) = IChainlink(_CHAINLINK_DAI_USD)
            .latestRoundData();
        assertEq(
            uint256(sdaiPrice),
            ((uint256(daiPrice) *
                IPotLike(ISavingsDai(_SDAI_ADDRESS).pot()).chi()) / 1e9) / 1e6
        );
    }
}
