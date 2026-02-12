// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { SECONDS_PER_YEAR, WAD } from "contracts/libraries/ConstantsLib.sol";

/// @title Rounding Helper Functions Tests
/// @notice Tests for the proposed _perSecondToBPS and _wadToBPS helper functions
///         that will be added to ProtocolManager to fix the ~1 BPS rounding loss
///         when back-converting per-second rates to BPS.
contract RoundingHelpersTest is Test {

    /// CONSTANTS (matching ProtocolManager) ///

    uint256 constant WAD_TO_BPS = 1e14;

    // DynamicIRM constraints
    uint256 constant MIN_VERTEX_START_BPS = 5000;   // 50%
    uint256 constant MAX_VERTEX_START_BPS = 9500;   // 95%
    uint256 constant MAX_BASE_RATE_BPS = 15000;     // 150%
    uint256 constant MAX_VERTEX_RATE_BPS = 20000;   // 200%
    uint256 constant MIN_MULTIPLIER_MAX_BPS = 10000;  // 1x
    uint256 constant MAX_MULTIPLIER_MAX_BPS = 200000; // 20x

    /// PROPOSED HELPER FUNCTIONS ///

    /// @notice Converts per-second rate back to BPS with proper rounding.
    /// @dev Uses rounding division: (x + divisor/2) / divisor
    /// @param ratePerSecond The rate per second (as stored in DynamicIRM).
    /// @param vertexFactor Either vertexStart or (WAD - vertexStart) in WAD.
    /// @return bps The rate in BPS, rounded to nearest.
    function _perSecondToBPS(
        uint256 ratePerSecond,
        uint256 vertexFactor
    ) internal pure returns (uint256 bps) {
        uint256 wadValue = _mulDiv(ratePerSecond, SECONDS_PER_YEAR * vertexFactor, WAD);
        bps = (wadValue + WAD_TO_BPS / 2) / WAD_TO_BPS;
    }

    /// @notice Converts WAD to BPS with proper rounding.
    /// @param wadValue The value in WAD format.
    /// @return bps The value in BPS, rounded to nearest.
    function _wadToBPS(uint256 wadValue) internal pure returns (uint256 bps) {
        bps = (wadValue + WAD_TO_BPS / 2) / WAD_TO_BPS;
    }

    /// SIMULATION OF DYNAMICIRM CONVERSION (for testing) ///

    /// @notice Simulates how DynamicIRM converts BPS to per-second rate.
    /// @dev Replicates DynamicIRM._updateDynamicIRM logic for baseRatePerSecond.
    function _bpsToPerSecond_Base(
        uint256 rateBPS,
        uint256 vertexStartBPS
    ) internal pure returns (uint64) {
        uint256 rateWAD = rateBPS * WAD_TO_BPS;
        uint256 vertexStartWAD = vertexStartBPS * WAD_TO_BPS;
        return uint64(_mulDiv(rateWAD, WAD, SECONDS_PER_YEAR * vertexStartWAD));
    }

    /// @notice Simulates how DynamicIRM converts BPS to per-second rate for vertex rate.
    /// @dev Replicates DynamicIRM._updateDynamicIRM logic for vertexRatePerSecond.
    function _bpsToPerSecond_Vertex(
        uint256 rateBPS,
        uint256 vertexStartBPS
    ) internal pure returns (uint64) {
        uint256 rateWAD = rateBPS * WAD_TO_BPS;
        uint256 vertexStartWAD = vertexStartBPS * WAD_TO_BPS;
        return uint64(_mulDiv(rateWAD, WAD, SECONDS_PER_YEAR * (WAD - vertexStartWAD)));
    }

    /// @notice Simulates the OLD (truncating) back-conversion used in ProtocolManager.
    function _perSecondToBPS_OLD(
        uint256 ratePerSecond,
        uint256 vertexFactor
    ) internal pure returns (uint256) {
        return _mulDiv(ratePerSecond, SECONDS_PER_YEAR * vertexFactor, WAD) / WAD_TO_BPS;
    }

    /// HELPER: mulDiv (same as ProtocolManager) ///

    function _mulDiv(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 z) {
        assembly {
            if iszero(mul(d, iszero(mul(y, gt(x, div(not(0), y)))))) {
                revert(0, 0)
            }
            z := div(mul(x, y), d)
        }
    }

    /// ═══════════════════════════════════════════════════════════════════════════
    /// FUZZ TESTS: BASE RATE ROUND-TRIP
    /// ═══════════════════════════════════════════════════════════════════════════

    /// @notice Fuzz test: baseRate round-trip should be exact with new helper
    function testFuzz_baseRate_roundTrip_newHelper(
        uint256 baseRateBPS,
        uint256 vertexStartBPS
    ) public pure {
        // Bound to valid DynamicIRM ranges
        baseRateBPS = bound(baseRateBPS, 1, MAX_BASE_RATE_BPS);
        vertexStartBPS = bound(vertexStartBPS, MIN_VERTEX_START_BPS, MAX_VERTEX_START_BPS);

        // Step 1: Convert BPS -> per-second (as DynamicIRM does)
        uint64 perSecond = _bpsToPerSecond_Base(baseRateBPS, vertexStartBPS);

        // Step 2: Convert back using NEW rounding helper
        uint256 vertexStartWAD = vertexStartBPS * WAD_TO_BPS;
        uint256 recoveredBPS = _perSecondToBPS(perSecond, vertexStartWAD);

        // Should be exact match
        assertEq(recoveredBPS, baseRateBPS, "Base rate round-trip should be exact");
    }

    /// @notice Fuzz test: demonstrate OLD helper has rounding loss
    function testFuzz_baseRate_roundTrip_oldHelper_showsLoss(
        uint256 baseRateBPS,
        uint256 vertexStartBPS
    ) public pure {
        baseRateBPS = bound(baseRateBPS, 1, MAX_BASE_RATE_BPS);
        vertexStartBPS = bound(vertexStartBPS, MIN_VERTEX_START_BPS, MAX_VERTEX_START_BPS);

        uint64 perSecond = _bpsToPerSecond_Base(baseRateBPS, vertexStartBPS);
        uint256 vertexStartWAD = vertexStartBPS * WAD_TO_BPS;

        uint256 oldRecovered = _perSecondToBPS_OLD(perSecond, vertexStartWAD);
        uint256 newRecovered = _perSecondToBPS(perSecond, vertexStartWAD);

        // Old method may lose 1 BPS, new method should be exact
        assertTrue(oldRecovered <= baseRateBPS, "Old should truncate (be <= original)");
        assertEq(newRecovered, baseRateBPS, "New should be exact");
    }

    /// ═══════════════════════════════════════════════════════════════════════════
    /// FUZZ TESTS: VERTEX RATE ROUND-TRIP
    /// ═══════════════════════════════════════════════════════════════════════════

    /// @notice Fuzz test: vertexRate round-trip should be exact with new helper
    function testFuzz_vertexRate_roundTrip_newHelper(
        uint256 vertexRateBPS,
        uint256 vertexStartBPS
    ) public pure {
        vertexRateBPS = bound(vertexRateBPS, 1, MAX_VERTEX_RATE_BPS);
        vertexStartBPS = bound(vertexStartBPS, MIN_VERTEX_START_BPS, MAX_VERTEX_START_BPS);

        // Step 1: Convert BPS -> per-second (as DynamicIRM does)
        uint64 perSecond = _bpsToPerSecond_Vertex(vertexRateBPS, vertexStartBPS);

        // Step 2: Convert back using NEW rounding helper
        uint256 vertexStartWAD = vertexStartBPS * WAD_TO_BPS;
        uint256 recoveredBPS = _perSecondToBPS(perSecond, WAD - vertexStartWAD);

        assertEq(recoveredBPS, vertexRateBPS, "Vertex rate round-trip should be exact");
    }

    /// ═══════════════════════════════════════════════════════════════════════════
    /// FUZZ TESTS: VERTEX START ROUND-TRIP
    /// ═══════════════════════════════════════════════════════════════════════════

    /// @notice Fuzz test: vertexStart round-trip should be exact with _wadToBPS
    function testFuzz_vertexStart_roundTrip(uint256 vertexStartBPS) public pure {
        vertexStartBPS = bound(vertexStartBPS, MIN_VERTEX_START_BPS, MAX_VERTEX_START_BPS);

        // Convert to WAD (as DynamicIRM stores it)
        uint256 vertexStartWAD = vertexStartBPS * WAD_TO_BPS;

        // Convert back using new helper
        uint256 recoveredBPS = _wadToBPS(vertexStartWAD);

        assertEq(recoveredBPS, vertexStartBPS, "VertexStart round-trip should be exact");
    }

    /// ═══════════════════════════════════════════════════════════════════════════
    /// FUZZ TESTS: VERTEX MULTIPLIER MAX ROUND-TRIP
    /// ═══════════════════════════════════════════════════════════════════════════

    /// @notice Fuzz test: vertexMultiplierMax round-trip should be exact with _wadToBPS
    function testFuzz_vertexMultiplierMax_roundTrip(uint256 multiplierMaxBPS) public pure {
        multiplierMaxBPS = bound(multiplierMaxBPS, MIN_MULTIPLIER_MAX_BPS, MAX_MULTIPLIER_MAX_BPS);

        // Convert to WAD (as DynamicIRM stores it)
        uint256 multiplierMaxWAD = multiplierMaxBPS * WAD_TO_BPS;

        // Convert back using new helper
        uint256 recoveredBPS = _wadToBPS(multiplierMaxWAD);

        assertEq(recoveredBPS, multiplierMaxBPS, "MultiplierMax round-trip should be exact");
    }

    /// ═══════════════════════════════════════════════════════════════════════════
    /// EDGE CASE TESTS: SPECIFIC VALUES
    /// ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test with the exact values from the original test setup
    function test_edgeCase_originalTestValues() public pure {
        uint256 baseRateBPS = 1000;      // 10%
        uint256 vertexRateBPS = 1000;    // 10%
        uint256 vertexStartBPS = 5000;   // 50%

        uint64 basePerSecond = _bpsToPerSecond_Base(baseRateBPS, vertexStartBPS);
        uint64 vertexPerSecond = _bpsToPerSecond_Vertex(vertexRateBPS, vertexStartBPS);

        uint256 vertexStartWAD = vertexStartBPS * WAD_TO_BPS;

        // Old method (truncating)
        uint256 baseOld = _perSecondToBPS_OLD(basePerSecond, vertexStartWAD);
        uint256 vertexOld = _perSecondToBPS_OLD(vertexPerSecond, WAD - vertexStartWAD);

        // New method (rounding)
        uint256 baseNew = _perSecondToBPS(basePerSecond, vertexStartWAD);
        uint256 vertexNew = _perSecondToBPS(vertexPerSecond, WAD - vertexStartWAD);

        // Old loses 1 BPS
        assertEq(baseOld, 999, "Old baseRate should be 999 (truncated)");
        assertEq(vertexOld, 999, "Old vertexRate should be 999 (truncated)");

        // New is exact
        assertEq(baseNew, 1000, "New baseRate should be 1000 (exact)");
        assertEq(vertexNew, 1000, "New vertexRate should be 1000 (exact)");
    }

    /// @notice Test minimum valid values
    function test_edgeCase_minimumValues() public pure {
        uint256 baseRateBPS = 1;          // Minimum: 0.01%
        uint256 vertexStartBPS = 5000;    // 50%

        uint64 perSecond = _bpsToPerSecond_Base(baseRateBPS, vertexStartBPS);
        uint256 vertexStartWAD = vertexStartBPS * WAD_TO_BPS;
        uint256 recovered = _perSecondToBPS(perSecond, vertexStartWAD);

        assertEq(recovered, baseRateBPS, "Minimum value should round-trip exactly");
    }

    /// @notice Test maximum valid values
    function test_edgeCase_maximumValues() public pure {
        uint256 baseRateBPS = MAX_BASE_RATE_BPS;    // 150%
        uint256 vertexStartBPS = MAX_VERTEX_START_BPS;  // 95%

        uint64 perSecond = _bpsToPerSecond_Base(baseRateBPS, vertexStartBPS);
        uint256 vertexStartWAD = vertexStartBPS * WAD_TO_BPS;
        uint256 recovered = _perSecondToBPS(perSecond, vertexStartWAD);

        assertEq(recovered, baseRateBPS, "Maximum value should round-trip exactly");
    }

    /// @notice Test with minimum vertex start (maximizes rounding opportunity)
    function test_edgeCase_minVertexStart() public pure {
        uint256 baseRateBPS = 1000;
        uint256 vertexStartBPS = MIN_VERTEX_START_BPS;  // 50%

        uint64 perSecond = _bpsToPerSecond_Base(baseRateBPS, vertexStartBPS);
        uint256 vertexStartWAD = vertexStartBPS * WAD_TO_BPS;
        uint256 recovered = _perSecondToBPS(perSecond, vertexStartWAD);

        assertEq(recovered, baseRateBPS, "Min vertexStart should round-trip exactly");
    }

    /// @notice Test with maximum vertex start
    function test_edgeCase_maxVertexStart() public pure {
        uint256 baseRateBPS = 1000;
        uint256 vertexStartBPS = MAX_VERTEX_START_BPS;  // 95%

        uint64 perSecond = _bpsToPerSecond_Base(baseRateBPS, vertexStartBPS);
        uint256 vertexStartWAD = vertexStartBPS * WAD_TO_BPS;
        uint256 recovered = _perSecondToBPS(perSecond, vertexStartWAD);

        assertEq(recovered, baseRateBPS, "Max vertexStart should round-trip exactly");
    }

    /// @notice Test vertex rate with extreme vertex start (small remaining range)
    function test_edgeCase_vertexRate_highVertexStart() public pure {
        uint256 vertexRateBPS = 10000;    // 100%
        uint256 vertexStartBPS = 9500;    // 95% (only 5% range for vertex)

        uint64 perSecond = _bpsToPerSecond_Vertex(vertexRateBPS, vertexStartBPS);
        uint256 vertexStartWAD = vertexStartBPS * WAD_TO_BPS;
        uint256 recovered = _perSecondToBPS(perSecond, WAD - vertexStartWAD);

        assertEq(recovered, vertexRateBPS, "High vertexStart vertex rate should round-trip exactly");
    }

    /// @notice Test all values in a critical range (around 1000 BPS which was failing)
    function test_edgeCase_criticalRange() public pure {
        uint256 vertexStartBPS = 5000;
        uint256 vertexStartWAD = vertexStartBPS * WAD_TO_BPS;

        for (uint256 bps = 990; bps <= 1010; bps++) {
            uint64 perSecond = _bpsToPerSecond_Base(bps, vertexStartBPS);
            uint256 recovered = _perSecondToBPS(perSecond, vertexStartWAD);
            assertEq(recovered, bps, "Critical range value should round-trip exactly");
        }
    }

    /// @notice Test values that are multiples of common numbers
    function test_edgeCase_commonMultiples() public pure {
        uint256 vertexStartBPS = 5000;
        uint256 vertexStartWAD = vertexStartBPS * WAD_TO_BPS;

        uint256[10] memory testValues = [
            uint256(100),   // 1%
            uint256(250),   // 2.5%
            uint256(500),   // 5%
            uint256(1000),  // 10%
            uint256(2000),  // 20%
            uint256(2500),  // 25%
            uint256(5000),  // 50%
            uint256(7500),  // 75%
            uint256(10000), // 100%
            uint256(15000)  // 150%
        ];

        for (uint256 i = 0; i < testValues.length; i++) {
            uint64 perSecond = _bpsToPerSecond_Base(testValues[i], vertexStartBPS);
            uint256 recovered = _perSecondToBPS(perSecond, vertexStartWAD);
            assertEq(recovered, testValues[i], "Common multiple should round-trip exactly");
        }
    }

    /// @notice Test _wadToBPS with edge values
    function test_edgeCase_wadToBPS_boundaries() public pure {
        // Exact conversion (no rounding needed)
        assertEq(_wadToBPS(5000 * WAD_TO_BPS), 5000, "Exact WAD should convert exactly");

        // Just below half boundary (should round down to 5000)
        assertEq(_wadToBPS(5000 * WAD_TO_BPS + WAD_TO_BPS / 2 - 1), 5000, "Just below half should round down");

        // At exactly half boundary: standard "round half up" behavior rounds to 5001
        assertEq(_wadToBPS(5000 * WAD_TO_BPS + WAD_TO_BPS / 2), 5001, "Exactly half rounds up");

        // Just past half (should round up to 5001)
        assertEq(_wadToBPS(5000 * WAD_TO_BPS + WAD_TO_BPS / 2 + 1), 5001, "Past half should round up");
    }

    /// ═══════════════════════════════════════════════════════════════════════════
    /// DIFFERENTIAL TESTS: OLD vs NEW
    /// ═══════════════════════════════════════════════════════════════════════════

    /// @notice Fuzz test showing the improvement: new method always >= old method
    function testFuzz_newMethod_neverWorseThanOld(
        uint256 baseRateBPS,
        uint256 vertexStartBPS
    ) public pure {
        baseRateBPS = bound(baseRateBPS, 1, MAX_BASE_RATE_BPS);
        vertexStartBPS = bound(vertexStartBPS, MIN_VERTEX_START_BPS, MAX_VERTEX_START_BPS);

        uint64 perSecond = _bpsToPerSecond_Base(baseRateBPS, vertexStartBPS);
        uint256 vertexStartWAD = vertexStartBPS * WAD_TO_BPS;

        uint256 oldResult = _perSecondToBPS_OLD(perSecond, vertexStartWAD);
        uint256 newResult = _perSecondToBPS(perSecond, vertexStartWAD);

        // New should always be >= old (since old truncates, new rounds)
        assertTrue(newResult >= oldResult, "New method should never be less than old");

        // And new should always equal original
        assertEq(newResult, baseRateBPS, "New method should equal original");
    }

    /// @notice Fuzz test: quantify the error in old method
    function testFuzz_oldMethod_errorBound(
        uint256 baseRateBPS,
        uint256 vertexStartBPS
    ) public pure {
        baseRateBPS = bound(baseRateBPS, 1, MAX_BASE_RATE_BPS);
        vertexStartBPS = bound(vertexStartBPS, MIN_VERTEX_START_BPS, MAX_VERTEX_START_BPS);

        uint64 perSecond = _bpsToPerSecond_Base(baseRateBPS, vertexStartBPS);
        uint256 vertexStartWAD = vertexStartBPS * WAD_TO_BPS;

        uint256 oldResult = _perSecondToBPS_OLD(perSecond, vertexStartWAD);

        // Old method error should be at most 1 BPS
        uint256 error = baseRateBPS - oldResult;
        assertTrue(error <= 1, "Old method error should be at most 1 BPS");
    }

    /// ═══════════════════════════════════════════════════════════════════════════
    /// COMBINED PARAMETER TESTS
    /// ═══════════════════════════════════════════════════════════════════════════

    /// @notice Fuzz test with all IRM parameters at once
    function testFuzz_allParameters_roundTrip(
        uint256 baseRateBPS,
        uint256 vertexRateBPS,
        uint256 vertexStartBPS,
        uint256 multiplierMaxBPS
    ) public pure {
        // Bound all to valid ranges
        baseRateBPS = bound(baseRateBPS, 1, MAX_BASE_RATE_BPS);
        vertexRateBPS = bound(vertexRateBPS, 1, MAX_VERTEX_RATE_BPS);
        vertexStartBPS = bound(vertexStartBPS, MIN_VERTEX_START_BPS, MAX_VERTEX_START_BPS);
        multiplierMaxBPS = bound(multiplierMaxBPS, MIN_MULTIPLIER_MAX_BPS, MAX_MULTIPLIER_MAX_BPS);

        uint256 vertexStartWAD = vertexStartBPS * WAD_TO_BPS;

        // Test baseRate round-trip
        uint64 basePerSecond = _bpsToPerSecond_Base(baseRateBPS, vertexStartBPS);
        assertEq(_perSecondToBPS(basePerSecond, vertexStartWAD), baseRateBPS, "baseRate");

        // Test vertexRate round-trip
        uint64 vertexPerSecond = _bpsToPerSecond_Vertex(vertexRateBPS, vertexStartBPS);
        assertEq(_perSecondToBPS(vertexPerSecond, WAD - vertexStartWAD), vertexRateBPS, "vertexRate");

        // Test vertexStart round-trip
        assertEq(_wadToBPS(vertexStartWAD), vertexStartBPS, "vertexStart");

        // Test multiplierMax round-trip
        uint256 multiplierMaxWAD = multiplierMaxBPS * WAD_TO_BPS;
        assertEq(_wadToBPS(multiplierMaxWAD), multiplierMaxBPS, "multiplierMax");
    }

    /// ═══════════════════════════════════════════════════════════════════════════
    /// OVERFLOW/UNDERFLOW SAFETY TESTS
    /// ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that helper functions don't overflow with max values
    function test_noOverflow_maxValues() public pure {
        // Maximum realistic per-second rate
        uint256 maxRate = MAX_VERTEX_RATE_BPS;
        uint256 minVertexStart = MIN_VERTEX_START_BPS;

        uint64 perSecond = _bpsToPerSecond_Vertex(maxRate, minVertexStart);
        uint256 vertexStartWAD = minVertexStart * WAD_TO_BPS;

        // This should not overflow
        uint256 result = _perSecondToBPS(perSecond, WAD - vertexStartWAD);
        assertEq(result, maxRate, "Max values should work without overflow");
    }

    /// @notice Test with zero values (edge case)
    function test_zeroHandling() public pure {
        // Zero rate should return zero
        assertEq(_perSecondToBPS(0, 5000 * WAD_TO_BPS), 0, "Zero rate should return zero");
        assertEq(_wadToBPS(0), 0, "Zero WAD should return zero");
    }
}
