// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";

import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { OptimizerReader } from "contracts/views/OptimizerReader.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @notice Fork coverage for the current-block accrued OptimizerReader path.
/// @dev This file keeps the legacy filename for discoverability, but
///      `optimalRebalanceAt` and cToken accrual projection have been removed.
contract TestOptimalRebalanceCurrentMonadFork is Test {
    address constant LENDING_OPTIMIZER = 0x37Bf94D8Af2Fbbf562Da5a3f1b0787b3515D10dd;
    address constant CENTRAL_REGISTRY = 0x1310f352f1389969Ece6741671c4B919523912fF;

    // Monad mainnet block 75302964, timestamp 2026-05-18 01:51:57 UTC.
    uint256 constant FORK_BLOCK = 75_302_964;
    uint256 constant DEFAULT_SLIPPAGE_BPS = 100;

    OptimizerReader reader;
    LendingOptimizer optimizer;

    function setUp() public {
        vm.createSelectFork(vm.envString("MON_NODE_URI_MONAD_ARCHIVE"), FORK_BLOCK);

        optimizer = LendingOptimizer(LENDING_OPTIMIZER);
        reader = new OptimizerReader(ICentralRegistry(CENTRAL_REGISTRY), 0);
    }

    function test_optimalRebalance_accruesAndReturnsCurrentBlockPlan() public {
        uint256 cachedAssets = optimizer.totalAssets();

        (LendingOptimizer.ReallocationAction[] memory actions,
         LendingOptimizer.AllocationBound[] memory bounds) =
            reader.optimalRebalance(LENDING_OPTIMIZER, DEFAULT_SLIPPAGE_BPS, 200);

        assertGe(optimizer.totalAssets(), cachedAssets, "reader should accrue optimizer state");
        assertEq(actions.length, bounds.length, "actions and bounds length mismatch");
    }
}
