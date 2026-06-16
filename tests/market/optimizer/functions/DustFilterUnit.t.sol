// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import { OptimizerReaderHarness } from "../OptimizerReaderHarness.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";

/// @title _removeDustActions Unit Tests
/// @notice Directly tests the dust filtering algorithm via the harness,
///         using mocked convertToShares to precisely control which deltas
///         are dust (return 0) and which are not.
/// @dev Covers all three phases:
///      Phase 1 — zeroing dust entries and computing signed imbalance
///      Phase 2 — trimming the smallest opposing entry to restore zero-sum
///      Phase 3 — returning whether any non-zero delta remains
contract TestDustFilterUnit is Test {

    OptimizerReaderHarness harness;

    // Mock market addresses (never called except via mockCall).
    address constant M0 = address(0xA0);
    address constant M1 = address(0xA1);
    address constant M2 = address(0xA2);
    address constant M3 = address(0xA3);

    function setUp() public {
        // Deploy harness — needs a CentralRegistry with an oracleManager.
        // Mock the oracleManager call so the constructor doesn't revert.
        address mockRegistry = address(0xCE);
        vm.mockCall(
            mockRegistry,
            abi.encodeWithSelector(ICentralRegistry.oracleManager.selector),
            abi.encode(address(0xDA))
        );
        harness = new OptimizerReaderHarness(ICentralRegistry(mockRegistry), 20);
    }

    // ==================== Helpers ====================

    /// @dev Mocks convertToShares on `market`: returns `result` for the exact
    ///      input `assets`. All other inputs return a non-zero default (1).
    function _mockDust(address market, uint256 assets) internal {
        // Specific amount -> 0 shares (dust).
        vm.mockCall(
            market,
            abi.encodeWithSelector(IBorrowableCToken.convertToShares.selector, assets),
            abi.encode(uint256(0))
        );
    }

    /// @dev Mocks convertToShares on `market`: returns 1 for any input (non-dust).
    function _mockNonDust(address market) internal {
        vm.mockCall(
            market,
            abi.encodeWithSelector(IBorrowableCToken.convertToShares.selector),
            abi.encode(uint256(1))
        );
    }

    /// @dev Mocks convertToShares: returns 0 for amounts <= dustThreshold, 1 otherwise.
    ///      Sets up mocks for specific amounts only — the "non-dust default" mock
    ///      must be set first via _mockNonDust.
    function _mockDustThreshold(address market, uint256 dustThreshold) internal {
        for (uint256 i = 1; i <= dustThreshold; ++i) {
            _mockDust(market, i);
        }
    }

    function _markets2() internal pure returns (address[] memory m) {
        m = new address[](2);
        m[0] = M0;
        m[1] = M1;
    }

    function _markets3() internal pure returns (address[] memory m) {
        m = new address[](3);
        m[0] = M0;
        m[1] = M1;
        m[2] = M2;
    }

    function _markets4() internal pure returns (address[] memory m) {
        m = new address[](4);
        m[0] = M0;
        m[1] = M1;
        m[2] = M2;
        m[3] = M3;
    }

    function _arr2(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = b;
    }

    function _arr3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory r) {
        r = new uint256[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }

    function _arr4(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (uint256[] memory r) {
        r = new uint256[](4);
        r[0] = a;
        r[1] = b;
        r[2] = c;
        r[3] = d;
    }

    // ==================== Phase 1: Zeroing Dust Entries ====================

    /// @notice No dust entries — all deltas survive, returns true.
    function test_removeDust_noDust_allSurvive() public {
        _mockNonDust(M0);
        _mockNonDust(M1);

        // M0: deposit +100, M1: withdraw -100.
        (bool hasActions, uint256[] memory ideal) = harness.exposed_removeDustActions(
            _markets2(),
            _arr2(200, 0),  // ideal
            _arr2(100, 100) // current
        );

        assertTrue(hasActions, "Should have actions");
        assertEq(ideal[0], 200, "M0 ideal unchanged");
        assertEq(ideal[1], 0, "M1 ideal unchanged");
    }

    /// @notice All deltas are zero — returns false, no actions.
    function test_removeDust_allZero_returnsFalse() public {
        (bool hasActions, ) = harness.exposed_removeDustActions(
            _markets2(),
            _arr2(100, 100), // ideal == current
            _arr2(100, 100)
        );

        assertFalse(hasActions, "No actions when all deltas are zero");
    }

    /// @notice Single dust deposit — zeroed, zero-sum lost, no opposing
    ///         entry to trim -> all zeroed, returns false.
    function test_removeDust_singleDustDeposit_allZeroed() public {
        _mockNonDust(M0);
        _mockDust(M0, 5);

        // M0: deposit +5 (dust), M1: no delta.
        (bool hasActions, uint256[] memory ideal) = harness.exposed_removeDustActions(
            _markets2(),
            _arr2(105, 100), // ideal
            _arr2(100, 100)  // current
        );

        assertFalse(hasActions, "Dust deposit with no offset: no actions");
        assertEq(ideal[0], 100, "M0 zeroed");
    }

    /// @notice Single dust withdrawal — zeroed, no opposing entry -> all zeroed.
    function test_removeDust_singleDustWithdrawal_allZeroed() public {
        _mockNonDust(M0);
        _mockDust(M0, 5);

        // M0: withdraw -5 (dust).
        (bool hasActions, uint256[] memory ideal) = harness.exposed_removeDustActions(
            _markets2(),
            _arr2(95, 100), // ideal
            _arr2(100, 100) // current
        );

        assertFalse(hasActions, "Dust withdrawal with no offset: no actions");
        assertEq(ideal[0], 100, "M0 zeroed");
    }

    // ==================== Phase 2: Zero-Sum Rebalancing ====================

    /// @notice Dust deposit zeroed -> excess withdrawals -> trim smallest deposit.
    ///         M0: deposit +5 (dust), M1: withdraw -100, M2: deposit +95.
    ///         After zeroing M0: imbalance = -5 (need to reduce withdrawals by 5).
    ///         M1 withdrawal trimmed from 100 to 95.
    function test_removeDust_dustDeposit_trimsWithdrawal() public {
        _mockNonDust(M0);
        _mockNonDust(M1);
        _mockNonDust(M2);
        _mockDust(M0, 5);

        (bool hasActions, uint256[] memory ideal) = harness.exposed_removeDustActions(
            _markets3(),
            _arr3(105, 0, 195),  // ideal: M0 +5 dust, M1 -100, M2 +95
            _arr3(100, 100, 100) // current
        );

        assertTrue(hasActions, "Should have surviving actions");
        assertEq(ideal[0], 100, "M0 dust zeroed");
        assertEq(ideal[1], 5, "M1 withdrawal trimmed from -100 to -95");
        assertEq(ideal[2], 195, "M2 deposit unchanged");
    }

    /// @notice Dust withdrawal zeroed -> excess deposits -> trim smallest deposit.
    ///         M0: withdraw -5 (dust), M1: deposit +100, M2: withdraw -95.
    ///         After zeroing M0: imbalance = +5 (need to reduce deposits by 5).
    ///         M1 deposit trimmed from 100 to 95.
    function test_removeDust_dustWithdrawal_trimsDeposit() public {
        _mockNonDust(M0);
        _mockNonDust(M1);
        _mockNonDust(M2);
        _mockDust(M0, 5);

        (bool hasActions, uint256[] memory ideal) = harness.exposed_removeDustActions(
            _markets3(),
            _arr3(95, 200, 5),   // ideal: M0 -5 dust, M1 +100, M2 -95
            _arr3(100, 100, 100) // current
        );

        assertTrue(hasActions, "Should have surviving actions");
        assertEq(ideal[0], 100, "M0 dust zeroed");
        assertEq(ideal[1], 195, "M1 deposit trimmed from +100 to +95");
        assertEq(ideal[2], 5, "M2 withdrawal unchanged");
    }

    /// @notice Trim fully consumes the smallest entry (excess >= bestAmt).
    ///         M0: deposit +3 (dust), M1: withdraw -50, M2: deposit +47.
    ///         After zeroing M0: need to reduce withdrawals by 3.
    ///         M1 is the only withdrawal (50). Partial trim: 50 -> 47.
    function test_removeDust_partialTrimOnLargeEntry() public {
        _mockNonDust(M0);
        _mockNonDust(M1);
        _mockNonDust(M2);
        _mockDust(M0, 3);

        (bool hasActions, uint256[] memory ideal) = harness.exposed_removeDustActions(
            _markets3(),
            _arr3(103, 50, 147),  // ideal: M0 +3 dust, M1 -50, M2 +47
            _arr3(100, 100, 100)  // current
        );

        assertTrue(hasActions, "Should have surviving actions");
        assertEq(ideal[0], 100, "M0 dust zeroed");
        assertEq(ideal[1], 53, "M1 withdrawal trimmed: 100-50+3 = 53 -> delta -47");
        assertEq(ideal[2], 147, "M2 deposit unchanged");
    }

    /// @notice Trim completely zeros the smallest entry and excess remains 0.
    ///         M0: deposit +10 (dust), M1: withdraw -10, M2: deposit +0.
    ///         Zeroing M0 creates imbalance -10. M1 withdrawal is exactly 10.
    ///         Full zero -> excess 0. Only M2 remains but has no delta -> false.
    function test_removeDust_trimExactlyConsumesEntry() public {
        _mockNonDust(M0);
        _mockNonDust(M1);
        _mockDust(M0, 10);

        (bool hasActions, uint256[] memory ideal) = harness.exposed_removeDustActions(
            _markets3(),
            _arr3(110, 90, 100), // ideal: M0 +10 dust, M1 -10
            _arr3(100, 100, 100) // current
        );

        assertFalse(hasActions, "Both entries consumed -> no actions");
        assertEq(ideal[0], 100, "M0 zeroed");
        assertEq(ideal[1], 100, "M1 zeroed (consumed by trim)");
    }

    // ==================== Phase 2: Cascading Dust ====================

    /// @notice Partial trim creates new dust -> direction flips.
    ///         M0: deposit +5 (dust), M1: withdraw -8 (non-dust), M2: deposit +3.
    ///         Phase 1: zero M0 -> imbalance = -5, reduceDeposits=false.
    ///         Phase 2: trim M1 withdrawal by 5 -> M1 ideal becomes 97 (delta = -3).
    ///                  Check convertToShares(3) on M1: if dust -> zero M1,
    ///                  excess = 3, flip to reduceDeposits=true.
    ///                  Now trim M2 deposit (3). excess >= 3 -> zero M2. excess = 0.
    ///                  All zeroed -> false.
    function test_removeDust_cascadingDust_flipsDirection() public {
        // M0: convertToShares(5) = 0 (dust)
        _mockNonDust(M0);
        _mockDust(M0, 5);

        // M1: convertToShares(8) = 1 (non-dust), convertToShares(3) = 0 (dust after trim)
        _mockNonDust(M1);
        _mockDust(M1, 3);

        // M2: convertToShares(3) = 1 (non-dust, but fully consumed by cascade)
        _mockNonDust(M2);

        (bool hasActions, uint256[] memory ideal) = harness.exposed_removeDustActions(
            _markets3(),
            _arr3(105, 92, 103),  // ideal: M0 +5 dust, M1 -8 non-dust, M2 +3
            _arr3(100, 100, 100)  // current
        );

        assertFalse(hasActions, "Cascade should zero everything");
        assertEq(ideal[0], 100, "M0 zeroed (initial dust)");
        assertEq(ideal[1], 100, "M1 zeroed (cascade dust)");
        assertEq(ideal[2], 100, "M2 zeroed (consumed by cascade trim)");
    }

    /// @notice Partial trim remainder is non-dust — cascade stops.
    ///         M0: deposit +5 (dust), M1: withdraw -20.
    ///         Trim M1 by 5 -> remainder 15. convertToShares(15) = non-zero -> stop.
    function test_removeDust_partialTrim_remainderNonDust_stops() public {
        _mockNonDust(M0);
        _mockNonDust(M1);
        _mockDust(M0, 5);

        (bool hasActions, uint256[] memory ideal) = harness.exposed_removeDustActions(
            _markets2(),
            _arr2(105, 80), // ideal: M0 +5 dust, M1 -20
            _arr2(100, 100) // current
        );

        assertTrue(hasActions, "M1 still has a valid withdrawal");
        assertEq(ideal[0], 100, "M0 zeroed");
        assertEq(ideal[1], 85, "M1 withdrawal reduced from -20 to -15");
    }

    // ==================== Phase 2: Multiple Dust Entries ====================

    /// @notice Two dust entries on the same side — both zeroed, combined
    ///         imbalance compensated from the other side.
    function test_removeDust_twoDustDeposits_compensatedFromWithdrawals() public {
        _mockNonDust(M0);
        _mockNonDust(M1);
        _mockNonDust(M2);
        _mockDust(M0, 3);
        _mockDust(M1, 2);

        // M0: +3 dust, M1: +2 dust, M2: -5 non-dust.
        (bool hasActions, uint256[] memory ideal) = harness.exposed_removeDustActions(
            _markets3(),
            _arr3(103, 102, 95), // ideal
            _arr3(100, 100, 100) // current
        );

        // Both dust deposits zeroed -> imbalance = -5.
        // M2 withdrawal is 5, fully consumed by trim -> excess 0.
        assertFalse(hasActions, "All entries consumed");
        assertEq(ideal[0], 100);
        assertEq(ideal[1], 100);
        assertEq(ideal[2], 100);
    }

    /// @notice Two dust entries on opposite sides — they partially cancel.
    ///         M0: +3 dust, M1: -2 dust, M2: +50, M3: -51.
    ///         imbalance = -3 (from M0) + 2 (from M1) = -1.
    ///         Reduce withdrawals by 1: trim M3 from -51 to -50.
    function test_removeDust_dustOnBothSides_netImbalance() public {
        _mockNonDust(M0);
        _mockNonDust(M1);
        _mockNonDust(M2);
        _mockNonDust(M3);
        _mockDust(M0, 3);
        _mockDust(M1, 2);

        (bool hasActions, uint256[] memory ideal) = harness.exposed_removeDustActions(
            _markets4(),
            _arr4(103, 98, 150, 49), // M0 +3 dust, M1 -2 dust, M2 +50, M3 -51
            _arr4(100, 100, 100, 100)
        );

        assertTrue(hasActions, "M2 and M3 survive");
        assertEq(ideal[0], 100, "M0 dust zeroed");
        assertEq(ideal[1], 100, "M1 dust zeroed");
        assertEq(ideal[2], 150, "M2 deposit unchanged");
        assertEq(ideal[3], 50, "M3 withdrawal trimmed from -51 to -50");
    }

    // ==================== Phase 2: !found Fallback ====================

    /// @notice No entries on the target side to trim -> zero everything.
    ///         M0: +5 dust (zeroed), M1: +10 (deposit, same side as excess).
    ///         imbalance = -5 -> reduceDeposits=false -> need to trim withdrawals.
    ///         No withdrawals exist -> !found -> zero all.
    function test_removeDust_noOpposingSide_zerosAll() public {
        _mockNonDust(M0);
        _mockNonDust(M1);
        _mockDust(M0, 5);

        // M0: +5 dust, M1: +10 non-dust. No withdrawals.
        // This shouldn't happen with valid zero-sum input (total would be off).
        // But the function handles it defensively.
        (bool hasActions, uint256[] memory ideal) = harness.exposed_removeDustActions(
            _markets2(),
            _arr2(105, 110), // ideal: both deposits
            _arr2(100, 100)  // current
        );

        assertFalse(hasActions, "No opposing side: zero all");
        assertEq(ideal[0], 100);
        assertEq(ideal[1], 100);
    }

    // ==================== Phase 2: Smallest-First Selection ====================

    /// @notice Trim picks the smallest entry on the target side.
    ///         M0: +2 dust, M1: -5 (withdraw), M2: -20 (withdraw), M3: +23.
    ///         imbalance = -2 -> reduce withdrawals -> pick M1 (smallest at 5).
    ///         excess = 2 < 5 -> partial trim M1 from -5 to -3.
    function test_removeDust_smallestFirst_partialTrim() public {
        _mockNonDust(M0);
        _mockNonDust(M1);
        _mockNonDust(M2);
        _mockNonDust(M3);
        _mockDust(M0, 2);

        (bool hasActions, uint256[] memory ideal) = harness.exposed_removeDustActions(
            _markets4(),
            _arr4(102, 95, 80, 123), // M0 +2 dust, M1 -5, M2 -20, M3 +23
            _arr4(100, 100, 100, 100)
        );

        assertTrue(hasActions, "Non-dust entries survive");
        assertEq(ideal[0], 100, "M0 dust zeroed");
        assertEq(ideal[1], 97, "M1 trimmed: was -5, now -3 (smallest picked)");
        assertEq(ideal[2], 80, "M2 unchanged (not smallest)");
        assertEq(ideal[3], 123, "M3 unchanged");
    }

    /// @notice When excess > smallest entry, the entry is fully consumed
    ///         and the loop continues to the next smallest.
    function test_removeDust_smallestFirst_multipleConsumed() public {
        _mockNonDust(M0);
        _mockNonDust(M1);
        _mockNonDust(M2);
        _mockNonDust(M3);
        _mockDust(M0, 10);

        // M0: +10 dust, M1: -3 (withdraw), M2: -4 (withdraw), M3: +17 (deposit).
        // imbalance = -10 -> reduce withdrawals by 10.
        // Pick smallest withdrawal: M1 at 3. Zero it. excess = 7.
        // Pick next: M2 at 4. Zero it. excess = 3.
        // No more withdrawals -> !found -> zero all remaining.
        (bool hasActions, uint256[] memory ideal) = harness.exposed_removeDustActions(
            _markets4(),
            _arr4(110, 97, 96, 117), // M0 +10, M1 -3, M2 -4, M3 +17
            _arr4(100, 100, 100, 100)
        );

        assertFalse(hasActions, "All consumed in cascade");
        assertEq(ideal[0], 100);
        assertEq(ideal[1], 100);
        assertEq(ideal[2], 100);
        assertEq(ideal[3], 100);
    }

    // ==================== Phase 3: Return Value ====================

    /// @notice Returns true when at least one non-zero delta survives.
    function test_removeDust_returnsTrue_whenSurvivorsExist() public {
        _mockNonDust(M0);
        _mockNonDust(M1);
        _mockNonDust(M2);
        _mockDust(M0, 1);

        // M0: +1 dust, M1: -50, M2: +49. After zeroing M0: trim M1 by 1.
        (bool hasActions, ) = harness.exposed_removeDustActions(
            _markets3(),
            _arr3(101, 50, 149),
            _arr3(100, 100, 100)
        );

        assertTrue(hasActions);
    }

    /// @notice Returns false when all deltas are zero from the start.
    function test_removeDust_returnsFalse_allDeltasZero() public {
        (bool hasActions, ) = harness.exposed_removeDustActions(
            _markets3(),
            _arr3(100, 200, 300),
            _arr3(100, 200, 300)
        );

        assertFalse(hasActions);
    }

    /// @notice Returns false when all deltas become zero after filtering.
    function test_removeDust_returnsFalse_allBecomeZero() public {
        _mockNonDust(M0);
        _mockNonDust(M1);
        _mockDust(M0, 7);
        _mockDust(M1, 7);

        // M0: +7 dust, M1: -7 dust. Both zeroed independently, imbalance cancels.
        (bool hasActions, uint256[] memory ideal) = harness.exposed_removeDustActions(
            _markets2(),
            _arr2(107, 93),
            _arr2(100, 100)
        );

        assertFalse(hasActions);
        assertEq(ideal[0], 100);
        assertEq(ideal[1], 100);
    }

    // ==================== Complex Scenarios ====================

    /// @notice Large number of dust entries with one survivor.
    function test_removeDust_manyDust_oneSurvivor() public {
        _mockNonDust(M0);
        _mockNonDust(M1);
        _mockNonDust(M2);
        _mockNonDust(M3);
        _mockDust(M0, 1);
        _mockDust(M1, 2);
        _mockDust(M2, 3);

        // M0: +1 dust, M1: -2 dust, M2: +3 dust, M3: -2 non-dust.
        // Phase 1: zero M0, M1, M2. imbalance = -1 + 2 + (-3) = -2.
        // Phase 2: reduceDeposits=false, excess=2. Only withdrawal: M3 (-2).
        // excess == bestAmt -> zero M3. excess = 0. All zeroed.
        (bool hasActions, uint256[] memory ideal) = harness.exposed_removeDustActions(
            _markets4(),
            _arr4(101, 98, 103, 98),
            _arr4(100, 100, 100, 100)
        );

        assertFalse(hasActions, "All dust + survivor consumed: no actions");
        assertEq(ideal[3], 100, "M3 consumed by compensation");
    }

    /// @notice Realistic scenario: one large deposit, one large withdrawal,
    ///         two tiny dust entries. Dust filtered, large entries survive.
    function test_removeDust_realistic_largeSurvivorsWithTinyDust() public {
        _mockNonDust(M0);
        _mockNonDust(M1);
        _mockNonDust(M2);
        _mockNonDust(M3);
        _mockDust(M2, 1);
        _mockDust(M3, 2);

        // M0: +5000, M1: -5003, M2: +1 dust, M3: +2 dust.
        // Phase 1: zero M2, M3. imbalance = -1 + (-2) = -3.
        //   (both were deposits, zeroing reduces ideal sum)
        // Phase 2: reduceDeposits=false, excess=3. Trim withdrawal M1 by 3.
        //   M1: -5003 -> -5000. convertToShares(5000) = non-zero -> excess = 0.
        (bool hasActions, uint256[] memory ideal) = harness.exposed_removeDustActions(
            _markets4(),
            _arr4(5100, 0 /* actually 4997 */, 101, 102),
            _arr4(100, 5003, 100, 100)
        );

        // Let me redo this with correct values.
        // current: [100, 5003, 100, 100] total = 5303
        // ideal:   [5100, 0, 101, 102]   total = 5303
        // Deltas:  +5000, -5003, +1 dust, +2 dust
        // Phase 1: zero M2 (imbal -= 1), zero M3 (imbal -= 2). imbalance = -3.
        // Phase 2: excess=3, reduceDeposits=false. Only withdrawal: M1 (-5003).
        //   partial trim: 5003 - 3 = 5000 remaining. If non-dust -> stop.
        assertTrue(hasActions, "Large entries survive");
        assertEq(ideal[0], 5100, "M0 large deposit survives");
        assertEq(ideal[1], 3, "M1 withdrawal trimmed from -5003 to -5000");
        assertEq(ideal[2], 100, "M2 dust zeroed");
        assertEq(ideal[3], 100, "M3 dust zeroed");
    }

    /// @notice Double cascade: trim creates dust, flips direction, new trim
    ///         creates dust again, flips again.
    function test_removeDust_doubleCascade() public {
        // Setup: M0 +10 dust, M1 -15 non-dust, M2 +8 non-dust, M3 -3 non-dust.
        // Phase 1: zero M0. imbalance = -10.
        // Phase 2: reduceDeposits=false, excess=10.
        //   Smallest withdrawal: M3 (-3). Zero it. excess = 7.
        //   Next smallest withdrawal: M1 (-15). Partial trim by 7: -15 -> -8.
        //   convertToShares(8) on M1 — if dust -> zero, excess=8, flip.
        //   Now reduceDeposits=true, excess=8.
        //   Only deposit: M2 (+8). Zero it. excess=0.
        //   All zeroed.
        _mockNonDust(M0);
        _mockNonDust(M1);
        _mockNonDust(M2);
        _mockNonDust(M3);
        _mockDust(M0, 10);
        _mockDust(M1, 8); // M1's remainder after trim is 8, which is dust

        (bool hasActions, uint256[] memory ideal) = harness.exposed_removeDustActions(
            _markets4(),
            _arr4(110, 85, 108, 97), // M0 +10, M1 -15, M2 +8, M3 -3
            _arr4(100, 100, 100, 100)
        );

        assertFalse(hasActions, "Double cascade zeroes everything");
        assertEq(ideal[0], 100);
        assertEq(ideal[1], 100);
        assertEq(ideal[2], 100);
        assertEq(ideal[3], 100);
    }

    /// @notice Cascade that stops midway: first flip produces non-dust remainder.
    function test_removeDust_cascadeStopsMidway() public {
        // M0: +5 dust, M1: -8, M2: +30, M3: -27.
        // Phase 1: zero M0. imbalance = -5.
        // Phase 2: excess=5, reduceDeposits=false.
        //   Smallest withdrawal: M1 (-8). Partial trim by 5: -8 -> -3.
        //   convertToShares(3) on M1: non-dust -> stop. excess=0.
        _mockNonDust(M0);
        _mockNonDust(M1);
        _mockNonDust(M2);
        _mockNonDust(M3);
        _mockDust(M0, 5);
        // M1 remainder (3) is non-dust since _mockNonDust covers all

        (bool hasActions, uint256[] memory ideal) = harness.exposed_removeDustActions(
            _markets4(),
            _arr4(105, 92, 130, 73), // M0 +5, M1 -8, M2 +30, M3 -27
            _arr4(100, 100, 100, 100)
        );

        assertTrue(hasActions, "M1, M2, M3 survive");
        assertEq(ideal[0], 100, "M0 zeroed");
        assertEq(ideal[1], 97, "M1 trimmed from -8 to -3");
        assertEq(ideal[2], 130, "M2 unchanged");
        assertEq(ideal[3], 73, "M3 unchanged");
    }
}
