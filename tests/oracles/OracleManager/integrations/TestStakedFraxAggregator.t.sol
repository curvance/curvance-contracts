// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBase } from "tests/utils/TestBase.sol";

import { StakedFraxAggregator } from "contracts/oracles/adaptors/wrappedAggregators/StakedFraxAggregator.sol";
import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";
import { IStakedFrax } from "contracts/interfaces/external/frax/IStakedFrax.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract TestStakedFraxAggregator is TestBase {
    address internal _SFRAX_ADDRESS =
        0xA663B02CF0a4b149d2aD41910CB81e23e1c41c32;

    StakedFraxAggregator public aggregator;

    function setUp() public {
        _fork();

        aggregator = new StakedFraxAggregator(
            _SFRAX_ADDRESS,
            _FRAX_ADDRESS,
            _CHAINLINK_FRAX_USD,
            "100"
        );
    }

    function testLatestRoundData() public view {
        (, int256 sfraxPrice, , , ) = aggregator.latestRoundData();
        (, int256 fraxPrice, , , ) = IChainlink(_CHAINLINK_FRAX_USD)
            .latestRoundData();
        assertEq(
            uint256(sfraxPrice),
            (uint256(fraxPrice) *
                IStakedFrax(_SFRAX_ADDRESS).pricePerShare()) / 1e18
        );
    }

    function testStakedFraxAggregator_DifferentDecimals() public {

        uint8 newDecimals = 6;

        vm.mockCall(
            _FRAX_ADDRESS,
            abi.encodeWithSelector(IERC20.decimals.selector),
            abi.encode(uint8(newDecimals))
        );

        assertEq(IERC20(_FRAX_ADDRESS).decimals(), newDecimals);

        aggregator = new StakedFraxAggregator(
            _SFRAX_ADDRESS,
            _FRAX_ADDRESS,
            _CHAINLINK_FRAX_USD,
            "100"
        );

        (, int256 sfraxPrice, , , ) = aggregator.latestRoundData();
        (, int256 fraxPrice, , , ) = IChainlink(_CHAINLINK_FRAX_USD)
            .latestRoundData();
        assertEq(
            uint256(sfraxPrice),
            (uint256(fraxPrice) *
                IStakedFrax(_SFRAX_ADDRESS).pricePerShare()) / 1e6
        );
    }
}
