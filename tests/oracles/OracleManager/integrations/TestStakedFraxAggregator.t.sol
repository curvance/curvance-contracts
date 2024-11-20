// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBase } from "tests/utils/TestBase.sol";

import { StakedFraxAggregator } from "contracts/oracles/adaptors/wrappedAggregators/StakedFraxAggregator.sol";
import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";
import { IStakedFrax } from "contracts/interfaces/external/frax/IStakedFrax.sol";

contract TestStakedFraxAggregator is TestBase {
    address internal _SFRAX_ADDRESS =
        0xA663B02CF0a4b149d2aD41910CB81e23e1c41c32;

    StakedFraxAggregator public aggregator;

    function setUp() public {
        _fork();

        aggregator = new StakedFraxAggregator(
            _SFRAX_ADDRESS,
            _FRAX_ADDRESS,
            _CHAINLINK_FRAX_USD
        );
    }

    function testMinMaxAnswer() public view {
        int192 maxAnswer = aggregator.maxAnswer();
        int192 minAnswer = aggregator.minAnswer();
        assertGt(maxAnswer, minAnswer);
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
}
