// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { WAD } from "contracts/libraries/ConstantsLib.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract TestLFactorFuzzed is TestBaseMarketIsolated {

    function setUp() public override {
        super.setUp();
    }

    function _computeLFactor(uint256 cSoft, uint256 cHard, uint256 debt) internal pure returns (uint256) {
        if (debt <= cSoft) return 0;
        if (debt >= cHard) return WAD;
        return FixedPointMathLib.mulDivUp(debt - cSoft, WAD, cHard - cSoft);
    }

    function test_success_whenLFactorCalculated(uint256 cSoft, uint256 gap, uint256 debtDelta) public view {
        // gap between cSoft and cHard
        gap = bound(gap, 1, 1_000_000e18);

        // bound cSoft and debtDelta to prevent overflows while also testing when debt is above cHard

        // generate collateral soft threshold
        cSoft = bound(cSoft, 0, type(uint256).max - gap - 1);

        // generate debt above soft threshold
        debtDelta = bound(debtDelta, 0, gap + 1);

        uint256 cHard = cSoft + gap;
        uint256 debt = cSoft + debtDelta;

        uint256 expected;
        // No liquidation.
        if (debt <= cSoft) {
            expected = 0;
        }
        // Hard liquidation.
        else if (debt >= cHard) {
            expected = WAD;
        } 
        // Soft liquidation.
        else {
            // Replicate the soft liquidation formula to calculate lFactor.
            expected = FixedPointMathLib.mulDivUp(debt - cSoft, WAD, cHard - cSoft);
        }

        uint256 lFactor = _computeLFactor(cSoft, cHard, debt);
        assertEq(lFactor, expected, "lFactor mismatch vs expected");
        assertTrue(lFactor <= WAD, "lFactor out of bounds");
    }

	// Non-fuzz test to test LFactor rounds up to 1 wei when result is 0
	function test_success_whenLFactorRoundsUpToOneWeiForSoftLiquidation() public view {
		uint256 cSoft = 1e18;
		uint256 cHard = cSoft + (2 * WAD);
		uint256 debt = cSoft + 1;

        // 1e18 / 2e18 = 0.5 rounds down to 0
		uint256 result = FixedPointMathLib.mulDiv(debt - cSoft, WAD, cHard - cSoft);
		assertEq(result, 0, "result should floor to 0");

		result = _computeLFactor(cSoft, cHard, debt);
		assertEq(result, 1, "lFactor must round up to 1 wei");
	}

	function test_success_lFactorDoesNotExceedWAD_withHugeNumbers() public view {
		uint256 cSoft = 1.1e59;
		uint256 cHard = 2.2e59;

		uint256 nearHardLiquidation = _computeLFactor(cSoft, cHard, cHard - 1);
		assertEq(
            nearHardLiquidation,
            WAD,
            "near-hard soft lFactor should be WAD and not round up to WAD + 1"
        );

		uint256 hardLiquidation = _computeLFactor(cSoft, cHard, cHard + 1);
		assertEq(hardLiquidation, WAD, "hard lFactor must equal WAD");

		uint256 maxDebtLiquidation = _computeLFactor(cSoft, cHard, type(uint256).max);
		assertEq(maxDebtLiquidation, WAD, "max-debt lFactor must equal WAD");
	}
}