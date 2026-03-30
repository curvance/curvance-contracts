// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { LendingOptimizerHarness } from "../LendingOptimizerHarness.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @notice Supply/withdraw queues have been removed from LendingOptimizer.
///         All tests in this file tested queue functionality (supplyQueueTarget,
///         setSupplyQueue, setWithdrawQueue, getSupplyQueue, getWithdrawQueue)
///         and are no longer applicable. Test bodies have been commented out.
contract TestLendingOptimizerQueueRouting is TestBaseLendingOptimizer {

    function setUp() public override {
        super.setUp();
    }

    // All tests in this file were entirely about queue functionality
    // (supplyQueueTarget, setSupplyQueue, setWithdrawQueue, getSupplyQueue,
    //  getWithdrawQueue, rebalance with queue parameters).
    // These functions have been removed from LendingOptimizer.
    // No tests remain.
}
