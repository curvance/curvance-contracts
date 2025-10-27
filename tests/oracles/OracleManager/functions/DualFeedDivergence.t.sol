// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";

contract DualFeedDivergenceTest is TestBaseOracleManager {
    MockV3Aggregator private MockUsdcUsd;

    function setUp() public override {
        super.setUp();

        _addDualPriceFeed();

        // Swap out the second adaptor's feed to use the mock
        MockUsdcUsd = new MockV3Aggregator(8, 1e8);
        dualChainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            true,
            address(MockUsdcUsd),
            0,
            100
        );
    }

    function test_divergence_noError_withinCaution() public {
        ( , uint256 err) = oracleManager.getPrice(_USDC_ADDRESS, true, true);
        assertEq(err, 0);
    }

    function test_divergence_caution_betweenBounds() public {
        // Current bounds: badSource 1.8%, caution 1.30%.
        // Bump a tiny bit into caution, but not badSource
        MockUsdcUsd.updateAnswer(1.0131e8); // 1.31%

        ( , uint256 err) = oracleManager.getPrice(_USDC_ADDRESS, true, true);
        assertEq(err, 1);
    }

    function test_divergence_badSource_aboveBadSource() public {
        // Bump above bad source
        MockUsdcUsd.updateAnswer(1.0190e8); // 1.9%

        ( , uint256 err) = oracleManager.getPrice(_USDC_ADDRESS, true, true);
        assertEq(err, 2);
    }
}


