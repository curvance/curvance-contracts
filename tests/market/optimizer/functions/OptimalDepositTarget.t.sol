// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { LendingOptimizerHarness } from "../LendingOptimizerHarness.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract TestLendingOptimizerQueueRouting is TestBaseLendingOptimizer {

    LendingOptimizerHarness harness;

    address marketManagerWMON;
    address marketManagerWBTC;
    address marketManagerWETH;

    function setUp() public override {
        super.setUp();
    }

    // ============ Helpers ============

    function _setUpThreeMarketHarness() internal {
        _setUpThreeMarkets();
        harness = LendingOptimizerHarness(address(optimizer));

        marketManagerWMON = address(IBorrowableCToken(cUSDC_WMON_MARKET).marketManager());
        marketManagerWBTC = address(IBorrowableCToken(cUSDC_WBTC_MARKET).marketManager());
        marketManagerWETH = address(IBorrowableCToken(cUSDC_WETH_MARKET).marketManager());
    }

    function _setUpOneMarketHarness() internal {
        _setUpOneMarket();
        harness = LendingOptimizerHarness(address(optimizer));

        marketManagerWMON = address(IBorrowableCToken(cUSDC_WMON_MARKET).marketManager());
    }

    function _setUpTwoMarketHarness() internal {
        _setUpTwoMarkets();
        harness = LendingOptimizerHarness(address(optimizer));

        marketManagerWMON = address(IBorrowableCToken(cUSDC_WMON_MARKET).marketManager());
        marketManagerWBTC = address(IBorrowableCToken(cUSDC_WBTC_MARKET).marketManager());
    }

    /// @dev Mocks mintPaused for a specific cToken market.
    function _mockMintPaused(address cToken, bool paused) internal {
        address mm = address(IBorrowableCToken(cToken).marketManager());
        vm.mockCall(
            mm,
            abi.encodeWithSelector(IMarketManager.actionsPaused.selector, cToken),
            abi.encode(paused, false, false)
        );
    }

    /// @dev Mocks harvest permissions for the caller.
    function _mockHarvestPermissions() internal {
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasHarvestPermissions.selector, address(this)),
            abi.encode(true)
        );
    }

    // ==================== supplyQueueTarget Tests ====================

    function test_supplyQueueTarget_success_returnsFirstMarketInQueue() public {
        _setUpThreeMarketHarness();

        // Default supply queue is set during construction, first entry should be returned.
        address target = harness.supplyQueueTarget();
        address[] memory queue = harness.getSupplyQueue();

        assertEq(target, queue[0], "Should return first market in supply queue");
    }

    function test_supplyQueueTarget_success_oneMarket() public {
        _setUpOneMarketHarness();

        address target = harness.supplyQueueTarget();
        assertEq(target, cUSDC_WMON_MARKET, "Single market should be the target");
    }

    function test_supplyQueueTarget_success_skipsPausedFirstMarket() public {
        _setUpThreeMarketHarness();

        // Pause the first market in the supply queue.
        address[] memory queue = harness.getSupplyQueue();
        _mockMintPaused(queue[0], true);

        address target = harness.supplyQueueTarget();
        assertEq(target, queue[1], "Should skip paused first market and return second");
    }

    function test_supplyQueueTarget_success_skipsTwoPausedMarkets() public {
        _setUpThreeMarketHarness();

        address[] memory queue = harness.getSupplyQueue();
        _mockMintPaused(queue[0], true);
        _mockMintPaused(queue[1], true);

        address target = harness.supplyQueueTarget();
        assertEq(target, queue[2], "Should skip two paused markets and return third");
    }

    function test_supplyQueueTarget_reverts_allMarketsPaused() public {
        _setUpThreeMarketHarness();

        address[] memory queue = harness.getSupplyQueue();
        for (uint256 i = 0; i < queue.length; i++) {
            _mockMintPaused(queue[i], true);
        }

        vm.expectRevert(LendingOptimizer.LendingOptimizer__MarketPaused.selector);
        harness.supplyQueueTarget();
    }

    function test_supplyQueueTarget_success_consistentResults() public {
        _setUpThreeMarketHarness();

        // Multiple calls should return the same result (deterministic).
        address target1 = harness.supplyQueueTarget();
        address target2 = harness.supplyQueueTarget();
        address target3 = harness.supplyQueueTarget();

        assertEq(target1, target2, "First and second calls should match");
        assertEq(target2, target3, "Second and third calls should match");
    }

    function test_supplyQueueTarget_success_afterDeposit() public {
        _setUpThreeMarketHarness();

        address targetBefore = harness.supplyQueueTarget();

        // Make a deposit - target should remain the same since queue order doesn't change.
        uint256 depositAmount = 100_000e6;
        deal(USDC_MONAD, address(this), depositAmount);
        IERC20(USDC_MONAD).approve(address(harness), depositAmount);
        harness.deposit(depositAmount, address(this));

        address targetAfter = harness.supplyQueueTarget();
        assertEq(targetBefore, targetAfter, "Queue target should not change after deposit");
    }

    function test_supplyQueueTarget_success_afterTimePassesRatesChange() public {
        _setUpThreeMarketHarness();

        address target1 = harness.supplyQueueTarget();

        // Skip forward to simulate yield accrual - target is queue-based, not rate-based.
        skip(1 days);

        address target2 = harness.supplyQueueTarget();

        // Queue-based routing is deterministic regardless of rate changes.
        assertEq(target1, target2, "Queue target should not change with time");
    }

    // ==================== setSupplyQueue Tests ====================

    function test_setSupplyQueue_success_reordersQueue() public {
        _setUpThreeMarketHarness();
        _mockHarvestPermissions();

        // Reverse the queue order.
        address[] memory newQueue = new address[](3);
        newQueue[0] = cUSDC_WETH_MARKET;
        newQueue[1] = cUSDC_WBTC_MARKET;
        newQueue[2] = cUSDC_WMON_MARKET;

        harness.setSupplyQueue(newQueue);

        address[] memory result = harness.getSupplyQueue();
        assertEq(result.length, 3, "Queue length should be 3");
        assertEq(result[0], cUSDC_WETH_MARKET, "First entry should be WETH market");
        assertEq(result[1], cUSDC_WBTC_MARKET, "Second entry should be WBTC market");
        assertEq(result[2], cUSDC_WMON_MARKET, "Third entry should be WMON market");
    }

    function test_setSupplyQueue_success_subsetOfMarkets() public {
        _setUpThreeMarketHarness();
        _mockHarvestPermissions();

        // Queue can be a subset of approved markets.
        address[] memory newQueue = new address[](2);
        newQueue[0] = cUSDC_WBTC_MARKET;
        newQueue[1] = cUSDC_WMON_MARKET;

        harness.setSupplyQueue(newQueue);

        address[] memory result = harness.getSupplyQueue();
        assertEq(result.length, 2, "Queue length should be 2");
        assertEq(result[0], cUSDC_WBTC_MARKET, "First entry should be WBTC market");
        assertEq(result[1], cUSDC_WMON_MARKET, "Second entry should be WMON market");
    }

    function test_setSupplyQueue_success_singleMarket() public {
        _setUpThreeMarketHarness();
        _mockHarvestPermissions();

        address[] memory newQueue = new address[](1);
        newQueue[0] = cUSDC_WETH_MARKET;

        harness.setSupplyQueue(newQueue);

        address[] memory result = harness.getSupplyQueue();
        assertEq(result.length, 1, "Queue length should be 1");
        assertEq(result[0], cUSDC_WETH_MARKET, "Only entry should be WETH market");
    }

    function test_setSupplyQueue_success_changesDepositTarget() public {
        _setUpThreeMarketHarness();
        _mockHarvestPermissions();

        address targetBefore = harness.supplyQueueTarget();

        // Set a different market as first in queue.
        address[] memory newQueue = new address[](3);
        newQueue[0] = cUSDC_WETH_MARKET;
        newQueue[1] = cUSDC_WMON_MARKET;
        newQueue[2] = cUSDC_WBTC_MARKET;

        harness.setSupplyQueue(newQueue);

        address targetAfter = harness.supplyQueueTarget();
        assertEq(targetAfter, cUSDC_WETH_MARKET, "Target should be new first market in queue");

        // Only assert they differ if the original first wasn't already WETH.
        if (targetBefore != cUSDC_WETH_MARKET) {
            assertTrue(targetBefore != targetAfter, "Target should change after queue reorder");
        }
    }

    function test_setSupplyQueue_reverts_duplicateEntries() public {
        _setUpThreeMarketHarness();
        _mockHarvestPermissions();

        address[] memory newQueue = new address[](2);
        newQueue[0] = cUSDC_WMON_MARKET;
        newQueue[1] = cUSDC_WMON_MARKET;

        vm.expectRevert(LendingOptimizer.LendingOptimizer__DuplicateInQueue.selector);
        harness.setSupplyQueue(newQueue);
    }

    function test_setSupplyQueue_reverts_unapprovedMarket() public {
        _setUpThreeMarketHarness();
        _mockHarvestPermissions();

        address[] memory newQueue = new address[](1);
        newQueue[0] = address(0xdead);

        vm.expectRevert(LendingOptimizer.LendingOptimizer__InvalidQueueEntry.selector);
        harness.setSupplyQueue(newQueue);
    }

    function test_setSupplyQueue_reverts_queueLongerThanApproved() public {
        _setUpTwoMarketHarness();
        _mockHarvestPermissions();

        // Two approved markets, try to set a queue with 3 entries.
        address[] memory newQueue = new address[](3);
        newQueue[0] = cUSDC_WMON_MARKET;
        newQueue[1] = cUSDC_WBTC_MARKET;
        newQueue[2] = cUSDC_WETH_MARKET; // Not approved in two-market setup.

        vm.expectRevert(LendingOptimizer.LendingOptimizer__InvalidParameter.selector);
        harness.setSupplyQueue(newQueue);
    }

    function test_setSupplyQueue_reverts_noHarvestPermissions() public {
        _setUpThreeMarketHarness();

        address[] memory newQueue = new address[](1);
        newQueue[0] = cUSDC_WMON_MARKET;

        vm.prank(address(0xbeef));
        vm.expectRevert();
        harness.setSupplyQueue(newQueue);
    }

    // ==================== setWithdrawQueue Tests ====================

    function test_setWithdrawQueue_success_reordersQueue() public {
        _setUpThreeMarketHarness();
        _mockHarvestPermissions();

        address[] memory newQueue = new address[](3);
        newQueue[0] = cUSDC_WETH_MARKET;
        newQueue[1] = cUSDC_WMON_MARKET;
        newQueue[2] = cUSDC_WBTC_MARKET;

        harness.setWithdrawQueue(newQueue);

        address[] memory result = harness.getWithdrawQueue();
        assertEq(result.length, 3, "Queue length should be 3");
        assertEq(result[0], cUSDC_WETH_MARKET, "First entry should be WETH market");
        assertEq(result[1], cUSDC_WMON_MARKET, "Second entry should be WMON market");
        assertEq(result[2], cUSDC_WBTC_MARKET, "Third entry should be WBTC market");
    }

    function test_setWithdrawQueue_success_subsetOfMarkets() public {
        _setUpThreeMarketHarness();
        _mockHarvestPermissions();

        address[] memory newQueue = new address[](1);
        newQueue[0] = cUSDC_WBTC_MARKET;

        harness.setWithdrawQueue(newQueue);

        address[] memory result = harness.getWithdrawQueue();
        assertEq(result.length, 1, "Queue length should be 1");
        assertEq(result[0], cUSDC_WBTC_MARKET, "Only entry should be WBTC market");
    }

    function test_setWithdrawQueue_reverts_duplicateEntries() public {
        _setUpThreeMarketHarness();
        _mockHarvestPermissions();

        address[] memory newQueue = new address[](2);
        newQueue[0] = cUSDC_WBTC_MARKET;
        newQueue[1] = cUSDC_WBTC_MARKET;

        vm.expectRevert(LendingOptimizer.LendingOptimizer__DuplicateInQueue.selector);
        harness.setWithdrawQueue(newQueue);
    }

    function test_setWithdrawQueue_reverts_unapprovedMarket() public {
        _setUpThreeMarketHarness();
        _mockHarvestPermissions();

        address[] memory newQueue = new address[](1);
        newQueue[0] = address(0xdead);

        vm.expectRevert(LendingOptimizer.LendingOptimizer__InvalidQueueEntry.selector);
        harness.setWithdrawQueue(newQueue);
    }

    function test_setWithdrawQueue_reverts_noHarvestPermissions() public {
        _setUpThreeMarketHarness();

        address[] memory newQueue = new address[](1);
        newQueue[0] = cUSDC_WMON_MARKET;

        vm.prank(address(0xbeef));
        vm.expectRevert();
        harness.setWithdrawQueue(newQueue);
    }

    // ==================== Rebalance Queue Atomicity Tests ====================

    function test_rebalance_success_updatesQueuesAtomically() public {
        _setUpOneMarketHarness();
        _mockHarvestPermissions();

        // Single-market setup avoids cap issues for this queue-focused test.
        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 10_000e6);
        harness.deposit(10_000e6, address(this));

        // Build no-op rebalance actions (zero movement).
        uint256 l = harness.numApprovedMarkets();
        LendingOptimizer.ReallocationAction[] memory actions =
            new LendingOptimizer.ReallocationAction[](l);
        LendingOptimizer.AllocationBound[] memory bounds =
            new LendingOptimizer.AllocationBound[](l);
        for (uint256 i; i < l; ++i) {
            actions[i].cToken = IBorrowableCToken(harness.approvedCTokensList(i));
            actions[i].assetsOrBps = 0;
            bounds[i] = LendingOptimizer.AllocationBound({ minBps: 0, maxBps: 10000 });
        }

        // New queues (single market, same content but validates the path).
        address[] memory newSupplyQueue = new address[](1);
        newSupplyQueue[0] = cUSDC_WMON_MARKET;

        address[] memory newWithdrawQueue = new address[](1);
        newWithdrawQueue[0] = cUSDC_WMON_MARKET;

        harness.rebalance(actions, bounds, newSupplyQueue, newWithdrawQueue);

        // Verify both queues were updated.
        address[] memory supplyResult = harness.getSupplyQueue();
        assertEq(supplyResult.length, 1, "Supply queue length should be 1");
        assertEq(supplyResult[0], cUSDC_WMON_MARKET, "Supply queue[0] should be WMON");

        address[] memory withdrawResult = harness.getWithdrawQueue();
        assertEq(withdrawResult.length, 1, "Withdraw queue length should be 1");
        assertEq(withdrawResult[0], cUSDC_WMON_MARKET, "Withdraw queue[0] should be WMON");
    }

    function test_rebalance_success_updatesDepositTarget() public {
        _setUpOneMarketHarness();
        _mockHarvestPermissions();

        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 10_000e6);
        harness.deposit(10_000e6, address(this));

        address targetBefore = harness.supplyQueueTarget();
        assertEq(targetBefore, cUSDC_WMON_MARKET, "Initial target should be WMON");

        // No-op rebalance — target stays the same since there's only 1 market.
        uint256 l = harness.numApprovedMarkets();
        LendingOptimizer.ReallocationAction[] memory actions =
            new LendingOptimizer.ReallocationAction[](l);
        LendingOptimizer.AllocationBound[] memory bounds =
            new LendingOptimizer.AllocationBound[](l);
        for (uint256 i; i < l; ++i) {
            actions[i].cToken = IBorrowableCToken(harness.approvedCTokensList(i));
            actions[i].assetsOrBps = 0;
            bounds[i] = LendingOptimizer.AllocationBound({ minBps: 0, maxBps: 10000 });
        }

        address[] memory newSupplyQueue = new address[](1);
        newSupplyQueue[0] = cUSDC_WMON_MARKET;

        harness.rebalance(actions, bounds, newSupplyQueue, harness.getWithdrawQueue());

        address targetAfter = harness.supplyQueueTarget();
        assertEq(targetAfter, cUSDC_WMON_MARKET, "Target should still be WMON");
    }

    function test_rebalance_reverts_invalidSupplyQueue() public {
        _setUpOneMarketHarness();
        _mockHarvestPermissions();

        uint256 l = harness.numApprovedMarkets();
        LendingOptimizer.ReallocationAction[] memory actions =
            new LendingOptimizer.ReallocationAction[](l);
        LendingOptimizer.AllocationBound[] memory bounds =
            new LendingOptimizer.AllocationBound[](l);
        for (uint256 i; i < l; ++i) {
            actions[i].cToken = IBorrowableCToken(harness.approvedCTokensList(i));
            actions[i].assetsOrBps = 0;
            bounds[i] = LendingOptimizer.AllocationBound({ minBps: 0, maxBps: 10000 });
        }

        // Supply queue with unapproved market.
        address[] memory badSupplyQueue = new address[](1);
        badSupplyQueue[0] = address(0xdead);

        address[] memory wq = harness.getWithdrawQueue();
        vm.expectRevert(LendingOptimizer.LendingOptimizer__InvalidQueueEntry.selector);
        harness.rebalance(actions, bounds, badSupplyQueue, wq);
    }

    function test_rebalance_reverts_invalidWithdrawQueue() public {
        _setUpOneMarketHarness();
        _mockHarvestPermissions();

        uint256 l = harness.numApprovedMarkets();
        LendingOptimizer.ReallocationAction[] memory actions =
            new LendingOptimizer.ReallocationAction[](l);
        LendingOptimizer.AllocationBound[] memory bounds =
            new LendingOptimizer.AllocationBound[](l);
        for (uint256 i; i < l; ++i) {
            actions[i].cToken = IBorrowableCToken(harness.approvedCTokensList(i));
            actions[i].assetsOrBps = 0;
            bounds[i] = LendingOptimizer.AllocationBound({ minBps: 0, maxBps: 10000 });
        }

        // Withdraw queue with unapproved market.
        address[] memory badWithdrawQueue = new address[](1);
        badWithdrawQueue[0] = address(0xdead);

        address[] memory sq = harness.getSupplyQueue();
        vm.expectRevert(LendingOptimizer.LendingOptimizer__InvalidQueueEntry.selector);
        harness.rebalance(actions, bounds, sq, badWithdrawQueue);
    }

    function test_rebalance_success_subsetQueues() public {
        _setUpOneMarketHarness();
        _mockHarvestPermissions();

        uint256 l = harness.numApprovedMarkets();
        LendingOptimizer.ReallocationAction[] memory actions =
            new LendingOptimizer.ReallocationAction[](l);
        LendingOptimizer.AllocationBound[] memory bounds =
            new LendingOptimizer.AllocationBound[](l);
        for (uint256 i; i < l; ++i) {
            actions[i].cToken = IBorrowableCToken(harness.approvedCTokensList(i));
            actions[i].assetsOrBps = 0;
            bounds[i] = LendingOptimizer.AllocationBound({ minBps: 0, maxBps: 10000 });
        }

        // Supply queue as empty subset, withdraw queue as full set.
        address[] memory emptyQueue = new address[](0);
        address[] memory fullQueue = new address[](1);
        fullQueue[0] = cUSDC_WMON_MARKET;

        harness.rebalance(actions, bounds, emptyQueue, fullQueue);

        address[] memory supplyResult = harness.getSupplyQueue();
        assertEq(supplyResult.length, 0, "Supply queue should be empty");

        address[] memory withdrawResult = harness.getWithdrawQueue();
        assertEq(withdrawResult.length, 1, "Withdraw queue should have 1 entry");
    }

    // ==================== Queue Validation Tests ====================

    function test_queueValidation_reverts_triplicateDuplicates() public {
        _setUpThreeMarketHarness();
        _mockHarvestPermissions();

        address[] memory badQueue = new address[](3);
        badQueue[0] = cUSDC_WMON_MARKET;
        badQueue[1] = cUSDC_WBTC_MARKET;
        badQueue[2] = cUSDC_WMON_MARKET;

        vm.expectRevert(LendingOptimizer.LendingOptimizer__DuplicateInQueue.selector);
        harness.setSupplyQueue(badQueue);
    }

    function test_queueValidation_success_emptyQueue() public {
        _setUpThreeMarketHarness();
        _mockHarvestPermissions();

        // Empty queue should be valid.
        address[] memory emptyQueue = new address[](0);
        harness.setSupplyQueue(emptyQueue);

        address[] memory result = harness.getSupplyQueue();
        assertEq(result.length, 0, "Queue should be empty");
    }

    function test_queueValidation_success_allMarketsInQueue() public {
        _setUpThreeMarketHarness();
        _mockHarvestPermissions();

        address[] memory fullQueue = new address[](3);
        fullQueue[0] = cUSDC_WMON_MARKET;
        fullQueue[1] = cUSDC_WBTC_MARKET;
        fullQueue[2] = cUSDC_WETH_MARKET;

        harness.setSupplyQueue(fullQueue);

        address[] memory result = harness.getSupplyQueue();
        assertEq(result.length, 3, "Queue should contain all 3 markets");
    }

    function test_queueValidation_reverts_mixOfApprovedAndUnapproved() public {
        _setUpThreeMarketHarness();
        _mockHarvestPermissions();

        address[] memory badQueue = new address[](2);
        badQueue[0] = cUSDC_WMON_MARKET;
        badQueue[1] = address(0x1234);

        vm.expectRevert(LendingOptimizer.LendingOptimizer__InvalidQueueEntry.selector);
        harness.setSupplyQueue(badQueue);
    }

    // ==================== Integration: Deposit Routes via Queue ====================

    function test_deposit_routesToSupplyQueueTarget() public {
        _setUpThreeMarketHarness();
        _mockHarvestPermissions();

        // Reorder supply queue so WETH is first.
        address[] memory newQueue = new address[](3);
        newQueue[0] = cUSDC_WETH_MARKET;
        newQueue[1] = cUSDC_WMON_MARKET;
        newQueue[2] = cUSDC_WBTC_MARKET;
        harness.setSupplyQueue(newQueue);

        // Verify target is now WETH.
        address target = harness.supplyQueueTarget();
        assertEq(target, cUSDC_WETH_MARKET, "Target should be WETH");

        // Make a deposit and verify it goes to the target market.
        uint256 wethBalanceBefore = IBorrowableCToken(cUSDC_WETH_MARKET).balanceOf(address(harness));

        uint256 depositAmount = 1_000e6;
        deal(USDC_MONAD, address(this), depositAmount);
        IERC20(USDC_MONAD).approve(address(harness), depositAmount);
        harness.deposit(depositAmount, address(this));

        uint256 wethBalanceAfter = IBorrowableCToken(cUSDC_WETH_MARKET).balanceOf(address(harness));
        assertGt(wethBalanceAfter, wethBalanceBefore, "WETH market should receive the deposit");
    }

    function test_deposit_skipsFirstPausedAndRoutesToSecond() public {
        _setUpThreeMarketHarness();
        _mockHarvestPermissions();

        // Set queue: WMON, WBTC, WETH.
        address[] memory newQueue = new address[](3);
        newQueue[0] = cUSDC_WMON_MARKET;
        newQueue[1] = cUSDC_WBTC_MARKET;
        newQueue[2] = cUSDC_WETH_MARKET;
        harness.setSupplyQueue(newQueue);

        // Pause WMON so deposits skip it.
        _mockMintPaused(cUSDC_WMON_MARKET, true);

        address target = harness.supplyQueueTarget();
        assertEq(target, cUSDC_WBTC_MARKET, "Should skip paused WMON and target WBTC");

        // Deposit should go to WBTC.
        uint256 wbtcBalanceBefore = IBorrowableCToken(cUSDC_WBTC_MARKET).balanceOf(address(harness));
        uint256 wmonBalanceBefore = IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(harness));

        uint256 depositAmount = 1_000e6;
        deal(USDC_MONAD, address(this), depositAmount);
        IERC20(USDC_MONAD).approve(address(harness), depositAmount);
        harness.deposit(depositAmount, address(this));

        uint256 wbtcBalanceAfter = IBorrowableCToken(cUSDC_WBTC_MARKET).balanceOf(address(harness));
        uint256 wmonBalanceAfter = IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(harness));

        assertGt(wbtcBalanceAfter, wbtcBalanceBefore, "WBTC market should receive deposit");
        assertEq(wmonBalanceAfter, wmonBalanceBefore, "Paused WMON should not receive deposit");
    }
}
