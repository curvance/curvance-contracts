// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { OptimizerReader } from "contracts/views/OptimizerReader.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @title OptimizerReaderHarness
/// @notice Exposes internal functions for direct unit testing.
contract OptimizerReaderHarness is OptimizerReader {

    constructor(
        ICentralRegistry _centralRegistry
    ) OptimizerReader(
        _centralRegistry,
        new CollateralGuardConfig[](0),
        0
    ) {}

    /// @notice Exposes _removeDustActions for direct testing.
    /// @dev Returns the modified idealAssets alongside the boolean result
    ///      so tests can inspect the post-filter state.
    function exposed_removeDustActions(
        address[] memory markets,
        uint256[] memory idealAssets,
        uint256[] memory currentAssets
    ) external view returns (bool hasActions, uint256[] memory) {
        hasActions = _removeDustActions(markets, idealAssets, currentAssets);
        return (hasActions, idealAssets);
    }
}
