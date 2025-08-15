// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/**
 * @title MockPermissionV3Aggregator
 * @notice A mock aggregator that allows elevated permissions to update answers
 *         Mainly used for testnet.
 */
contract MockPermissionV3Aggregator is MockV3Aggregator {
    ICentralRegistry public registry;

    constructor(
        ICentralRegistry _centralRegistry,
        uint8 _decimals,
        int256 _initialAnswer
    ) MockV3Aggregator(_decimals, _initialAnswer) {
        // Leaving this as a note -- super annyoing but address(registry) != address(0)
        // needs to be checked along side hasElevatedPermissions because of MockV3Aggregator initialization
        // happens before registry is set & calls updateAnswer
        registry = _centralRegistry;
    }

    function updateAnswer(int256 _answer) public override {
        if (
            address(registry) != address(0) &&
            !registry.hasElevatedPermissions(msg.sender)
        ) {
            revert("MockPermissionV3Aggregator: Unauthorized");
        }
        super.updateAnswer(_answer);
    }

    function updateRoundData(
        uint80 _roundId,
        int256 _answer,
        uint256 _timestamp,
        uint256 _startedAt
    ) public override {
        if (!registry.hasElevatedPermissions(msg.sender)) {
            revert("MockPermissionV3Aggregator: Unauthorized");
        }
        super.updateRoundData(_roundId, _answer, _timestamp, _startedAt);
    }
}
