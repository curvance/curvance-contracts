// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { CombinedAggregator } from "contracts/oracles/adaptors/wrappedAggregators/CombinedAggregator.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract TestCombinedAggregator is Test {
    // Chainlink addresses
    address internal constant EZETH_ETH = 0xdA0Da3272575e3fed2Bd61Bc63DB776516e808F2;
    address internal constant ETH_USD = 0x1B1414782B859871781bA3E4B0979b9ca57A0A04;

    string internal constant ASSET_ID = "ezETH/USD";

    CentralRegistry internal centralRegistry;
    CombinedAggregator internal combined;
    IChainlink internal primaryAgg;
    IChainlink internal secondaryAgg;

    function setUp() public {
        // Fork Monad mainnet
        string memory rpc = vm.envString("ETH_NODE_URI_MONAD_MAINNET");
        vm.createSelectFork(rpc);

        // Deploy a minimal CentralRegistry 
        centralRegistry = new CentralRegistry(
            address(this),
            address(this),
            block.timestamp + 365 days,
            address(0), // sequencer
            address(0)  // feeToken
        );

        primaryAgg = IChainlink(EZETH_ETH); // ezETH / ETH
        secondaryAgg = IChainlink(ETH_USD); // ETH / USD

        // Deploy CombinedAggregator
        combined = new CombinedAggregator(
            ICentralRegistry(address(centralRegistry)),
            address(primaryAgg),
            address(secondaryAgg),
            0, // use DEFAULT_HEARTBEAT for secondary
            ASSET_ID
        );

         // Ensure a sane heartbeat
         combined.setSecondaryHeartbeat(1 days);
    }

    function test_combinedAggregator_correctlyCombinesPrices() public {
        (,int256 primaryAnswer,,,) = primaryAgg.latestRoundData();
        (,int256 secondaryAnswer,,,) = secondaryAgg.latestRoundData();

        uint8 secondaryDecimals = secondaryAgg.decimals();
        uint256 scale = 10 ** uint256(secondaryDecimals);

        // (ezETH/ETH) * (ETH/USD) scaled by 10**secondaryDecimals
        uint256 expected = (uint256(primaryAnswer) * uint256(secondaryAnswer)) / scale;

        (,int256 combinedAnswer,, uint256 updatedAt,) = combined.latestRoundData();

        // Check that we received non-stale data
        assertTrue(updatedAt != 0, "unexpected stale updatedAt");

        // Compare answers exactly
        assertEq(uint256(combinedAnswer), expected, "wrong combined price");

        // getAdjustedAnswer(primaryAnswer) should equal the same multiplication
        int256 adjusted = combined.getAdjustedAnswer(primaryAnswer);
        assertEq(uint256(adjusted), expected, "getAdjustedAnswer: mismatch");
    }

    function test_combinedAggregator_decimalsMatchPrimary() public {
        uint8 primaryDecimals = primaryAgg.decimals();
        uint8 combinedDecimals = combined.decimals();
        assertEq(combinedDecimals, primaryDecimals, "decimals mismatch");
    }

    function test_combinedAggregator_staleSecondarySetsUpdatedAtZero() public {

        // Set secondary heartbeat very small so oracle update appears stale
        combined.setSecondaryHeartbeat(1);

        // Advance time so the last secondary update is older than the heartbeat
        skip(2 days);

        (,,,uint256 updatedAt,) = combined.latestRoundData();

        // When secondary is stale, CombinedAggregator bubbles updatedAt = 0
        assertEq(updatedAt, 0, "updatedAt should be zero when secondary is stale");
    }
}


