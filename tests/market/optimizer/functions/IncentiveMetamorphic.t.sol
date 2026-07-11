// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {TestBaseLendingOptimizer} from "../TestBaseLendingOptimizer.sol";
import {
    LendingOptimizer
} from "contracts/market/optimizer/LendingOptimizer.sol";
import {LendingOptimizerHarness} from "../LendingOptimizerHarness.sol";
import {OptimizerReader} from "contracts/views/OptimizerReader.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {BPS} from "contracts/libraries/ConstantsLib.sol";

/// @title Incentive metamorphic properties (T-01, P-01 through P-05)
contract TestIncentiveMetamorphic is TestBaseLendingOptimizer {
    struct Plan {
        LendingOptimizer.ReallocationAction[] actions;
        LendingOptimizer.AllocationBound[] bounds;
    }

    uint256 internal constant MAX_INCENTIVE_BPS = 1_000;

    OptimizerReader internal reader;

    function setUp() public override {
        super.setUp();
        reader = new OptimizerReader(
            ICentralRegistry(address(liveCentralRegistry)), 0
        );
    }

    function testFuzz_defaultOmittedAndExplicitZeroAreEquivalent(
        uint256 scenarioSeed,
        uint16 rawSlippage,
        uint16 rawChunks
    ) public {
        _setUpScenario(scenarioSeed);
        uint256 slippageBps = uint256(rawSlippage) % (BPS + 1);
        uint256 chunks = uint256(rawChunks) % 500 + 1;

        Plan memory defaultPlan;
        (defaultPlan.actions, defaultPlan.bounds) =
            reader.optimalRebalance(address(optimizer), slippageBps, chunks);

        OptimizerReader.MarketIncentiveAPYBps[] memory omitted =
            new OptimizerReader.MarketIncentiveAPYBps[](0);
        Plan memory omittedPlan = _plan(slippageBps, chunks, omitted);

        uint256[3] memory zeroBps;
        Plan memory zeroPlan =
            _plan(slippageBps, chunks, _canonicalIncentives(zeroBps));

        _assertPlansEqual(defaultPlan, omittedPlan, "default vs omitted");
        _assertPlansEqual(defaultPlan, zeroPlan, "default vs explicit zero");
    }

    function testFuzz_tagPermutationIsIrrelevant(
        uint256 scenarioSeed,
        uint256 incentiveSeed,
        uint8 rawPermutation,
        uint16 rawSlippage,
        uint16 rawChunks
    ) public {
        _setUpScenario(scenarioSeed);
        uint256[3] memory incentiveBps = _incentiveBps(incentiveSeed);
        uint256 slippageBps = uint256(rawSlippage) % (BPS + 1);
        uint256 chunks = uint256(rawChunks) % 500 + 1;

        Plan memory canonicalPlan =
            _plan(slippageBps, chunks, _canonicalIncentives(incentiveBps));
        Plan memory permutedPlan = _plan(
            slippageBps,
            chunks,
            _permutedIncentives(incentiveBps, rawPermutation % 6)
        );

        _assertPlansEqual(canonicalPlan, permutedPlan, "tag permutation");
    }

    function testFuzz_sparseTagsEqualExplicitZeros(
        uint256 scenarioSeed,
        uint256 incentiveSeed,
        uint8 rawMask,
        uint16 rawSlippage,
        uint16 rawChunks
    ) public {
        _setUpScenario(scenarioSeed);
        uint8 mask = rawMask & 7;
        uint256[3] memory fullBps = _incentiveBps(incentiveSeed);
        for (uint256 i; i < 3; ++i) {
            if (mask & uint8(1 << i) == 0) fullBps[i] = 0;
        }

        uint256 slippageBps = uint256(rawSlippage) % (BPS + 1);
        uint256 chunks = uint256(rawChunks) % 500 + 1;
        Plan memory fullPlan =
            _plan(slippageBps, chunks, _canonicalIncentives(fullBps));
        Plan memory sparsePlan =
            _plan(slippageBps, chunks, _sparseIncentives(fullBps, mask));

        _assertPlansEqual(fullPlan, sparsePlan, "sparse tags");
    }

    function testFuzz_equalIncentiveShiftPreservesPlan(
        uint256 scenarioSeed,
        uint256 incentiveSeed,
        uint16 rawShift,
        uint16 rawSlippage,
        uint16 rawChunks
    ) public {
        _setUpScenario(scenarioSeed);
        uint256 shift = uint256(rawShift) % (MAX_INCENTIVE_BPS + 1);
        uint256 room = MAX_INCENTIVE_BPS - shift;
        uint256[3] memory baseBps;
        uint256[3] memory shiftedBps;

        for (uint256 i; i < 3; ++i) {
            baseBps[i] = _draw(
                incentiveSeed,
                keccak256(abi.encode("base incentive", i)),
                0,
                room
            );
            shiftedBps[i] = baseBps[i] + shift;
        }

        uint256 slippageBps = uint256(rawSlippage) % (BPS + 1);
        uint256 chunks = uint256(rawChunks) % 500 + 1;
        Plan memory basePlan =
            _plan(slippageBps, chunks, _canonicalIncentives(baseBps));
        Plan memory shiftedPlan =
            _plan(slippageBps, chunks, _canonicalIncentives(shiftedBps));

        _assertPlansEqual(basePlan, shiftedPlan, "equal incentive shift");
    }

    function test_equalIncentiveShift_nonemptyAnchor() public {
        _setUpScenario(17);
        uint256[3] memory zeroBps;
        Plan memory zeroPlan = _plan(250, 200, _canonicalIncentives(zeroBps));
        Plan memory basePlan;
        uint256[3] memory baseBps;
        bool found;

        for (uint256 i; i < 3; ++i) {
            baseBps[i] = 900;
            Plan memory candidate =
                _plan(250, 200, _canonicalIncentives(baseBps));
            if (_plansDiffer(candidate, zeroPlan)) {
                basePlan = candidate;
                found = true;
                break;
            }
            baseBps[i] = 0;
        }

        assertTrue(found, "anchor incentives must change the plan");
        uint256[3] memory shiftedBps;
        for (uint256 i; i < 3; ++i) {
            shiftedBps[i] = baseBps[i] + 100;
        }
        Plan memory shiftedPlan =
            _plan(250, 200, _canonicalIncentives(shiftedBps));

        assertGt(basePlan.actions.length, 0, "anchor plan must be nonempty");
        _assertPlansEqual(basePlan, shiftedPlan, "nonempty equal shift");
    }

    function _plan(
        uint256 slippageBps,
        uint256 chunks,
        OptimizerReader.MarketIncentiveAPYBps[] memory incentives
    ) internal returns (Plan memory plan) {
        (plan.actions, plan.bounds) = reader.optimalRebalanceWithIncentives(
            address(optimizer), slippageBps, chunks, incentives
        );
    }

    function _setUpScenario(uint256 seed) internal {
        _setUpThreeMarkets();
        address[3] memory markets = _markets();

        for (uint256 i; i < 3; ++i) {
            uint256 amount = _draw(
                seed,
                keccak256(abi.encode("optimizer allocation", i)),
                10_000e6,
                500_000e6
            );
            deal(USDC_MONAD, address(this), amount);
            IERC20(USDC_MONAD).approve(address(optimizer), amount);
            LendingOptimizerHarness(address(optimizer))
                .depositToMarket(amount, address(this), markets[i]);
        }
    }

    function _canonicalIncentives(uint256[3] memory incentiveBps)
        internal
        view
        returns (OptimizerReader.MarketIncentiveAPYBps[] memory incentives)
    {
        uint8[3] memory order = [uint8(0), 1, 2];
        return _orderedIncentives(incentiveBps, order);
    }

    function _permutedIncentives(
        uint256[3] memory incentiveBps,
        uint8 permutation
    )
        internal
        view
        returns (OptimizerReader.MarketIncentiveAPYBps[] memory incentives)
    {
        uint8[3] memory order;
        if (permutation == 0) order = [uint8(0), 1, 2];
        else if (permutation == 1) order = [uint8(0), 2, 1];
        else if (permutation == 2) order = [uint8(1), 0, 2];
        else if (permutation == 3) order = [uint8(1), 2, 0];
        else if (permutation == 4) order = [uint8(2), 0, 1];
        else order = [uint8(2), 1, 0];

        return _orderedIncentives(incentiveBps, order);
    }

    function _orderedIncentives(
        uint256[3] memory incentiveBps,
        uint8[3] memory order
    )
        internal
        view
        returns (OptimizerReader.MarketIncentiveAPYBps[] memory incentives)
    {
        address[3] memory markets = _markets();
        incentives = new OptimizerReader.MarketIncentiveAPYBps[](3);
        for (uint256 i; i < 3; ++i) {
            uint256 marketIndex = order[i];
            incentives[i] = OptimizerReader.MarketIncentiveAPYBps({
                cToken: markets[marketIndex],
                incentiveAPYBps: incentiveBps[marketIndex]
            });
        }
    }

    function _sparseIncentives(uint256[3] memory incentiveBps, uint8 mask)
        internal
        view
        returns (OptimizerReader.MarketIncentiveAPYBps[] memory incentives)
    {
        address[3] memory markets = _markets();
        uint256 count;
        for (uint256 i; i < 3; ++i) {
            if (mask & uint8(1 << i) != 0) ++count;
        }

        incentives = new OptimizerReader.MarketIncentiveAPYBps[](count);
        uint256 cursor;
        for (uint256 i; i < 3; ++i) {
            if (mask & uint8(1 << i) == 0) continue;
            incentives[cursor++] = OptimizerReader.MarketIncentiveAPYBps({
                cToken: markets[i], incentiveAPYBps: incentiveBps[i]
            });
        }
    }

    function _incentiveBps(uint256 seed)
        internal
        pure
        returns (uint256[3] memory incentiveBps)
    {
        for (uint256 i; i < 3; ++i) {
            incentiveBps[i] = _draw(
                seed,
                keccak256(abi.encode("incentive", i)),
                0,
                MAX_INCENTIVE_BPS
            );
        }
    }

    function _markets() internal view returns (address[3] memory markets) {
        markets[0] = cUSDC_WMON_MARKET;
        markets[1] = cUSDC_WBTC_MARKET;
        markets[2] = cUSDC_WETH_MARKET;
    }

    function _assertPlansEqual(
        Plan memory left,
        Plan memory right,
        string memory context
    ) internal pure {
        assertEq(left.actions.length, right.actions.length, context);
        assertEq(left.bounds.length, right.bounds.length, context);

        for (uint256 i; i < left.actions.length; ++i) {
            assertEq(
                address(left.actions[i].cToken),
                address(right.actions[i].cToken),
                context
            );
            assertEq(
                left.actions[i].assetsOrBps,
                right.actions[i].assetsOrBps,
                context
            );
            assertEq(left.bounds[i].cToken, right.bounds[i].cToken, context);
            assertEq(left.bounds[i].minBps, right.bounds[i].minBps, context);
            assertEq(left.bounds[i].maxBps, right.bounds[i].maxBps, context);
        }
    }

    function _plansDiffer(Plan memory left, Plan memory right)
        internal
        pure
        returns (bool)
    {
        if (left.actions.length != right.actions.length) return true;
        if (left.bounds.length != right.bounds.length) return true;

        for (uint256 i; i < left.actions.length; ++i) {
            if (
                address(left.actions[i].cToken)
                        != address(right.actions[i].cToken)
                    || left.actions[i].assetsOrBps
                        != right.actions[i].assetsOrBps
                    || left.bounds[i].cToken != right.bounds[i].cToken
                    || left.bounds[i].minBps != right.bounds[i].minBps
                    || left.bounds[i].maxBps != right.bounds[i].maxBps
            ) {
                return true;
            }
        }

        return false;
    }

    function _draw(
        uint256 seed,
        bytes32 salt,
        uint256 minValue,
        uint256 maxValue
    ) internal pure returns (uint256) {
        if (minValue == maxValue) return minValue;
        return minValue + uint256(keccak256(abi.encode(seed, salt)))
            % (maxValue - minValue + 1);
    }
}
