// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {TestBaseLendingOptimizer} from "../TestBaseLendingOptimizer.sol";
import {
    LendingOptimizer
} from "contracts/market/optimizer/LendingOptimizer.sol";
import {LendingOptimizerHarness} from "../LendingOptimizerHarness.sol";
import {OptimizerReader} from "contracts/views/OptimizerReader.sol";
import {IBorrowableCToken} from "contracts/interfaces/IBorrowableCToken.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {BPS} from "contracts/libraries/ConstantsLib.sol";

/// @title Incentive-aware rounding and second-plan stability (T-07, P-11/P-14)
contract TestIncentiveRebalanceStability is TestBaseLendingOptimizer {
    struct Plan {
        LendingOptimizer.ReallocationAction[] actions;
        LendingOptimizer.AllocationBound[] bounds;
    }

    OptimizerReader internal reader;

    function setUp() public override {
        super.setUp();
        reader = new OptimizerReader(
            ICentralRegistry(address(liveCentralRegistry)), 0
        );
    }

    function testFuzz_immediateSecondPlanIsStable(
        uint256 allocationSeed,
        uint256 incentiveSeed,
        uint16 rawDays,
        uint16 rawSlippage,
        uint16 rawChunks
    ) public {
        _setUpOptimizer();
        _depositScenario(allocationSeed);
        skip(uint256(rawDays) % 3_651 * 1 days);

        _executeAndAssertStable(
            _incentives(incentiveSeed),
            uint256(rawSlippage) % (BPS + 1),
            uint256(rawChunks) % 500 + 1
        );
    }

    function test_highExchangeRateIncentivePlanIsStable() public {
        _setUpOptimizer();
        uint256[3] memory allocations =
            [uint256(500_000e6), 10_000e6, 25_000e6];
        _depositAllocations(allocations);
        skip(10 * 365 days);

        uint256[3] memory incentiveBps = [uint256(1_000), 500, 0];
        Plan memory first =
            _executeAndAssertStable(_taggedIncentives(incentiveBps), 0, 500);

        assertGt(
            first.actions.length, 0, "high-rate anchor must execute a plan"
        );
    }

    function testFuzz_repeatedLiquidityShocksRemainStable(uint256 seed)
        public
    {
        _setUpOptimizer();
        uint256[3] memory allocations =
            [uint256(100_000e6), 100_000e6, 100_000e6];
        _depositAllocations(allocations);
        address[3] memory markets = _markets();
        address whale = address(0xBEEF);

        for (uint256 round; round < 3; ++round) {
            uint256 marketIndex = _draw(
                seed, keccak256(abi.encode("shock market", round)), 0, 2
            );
            uint256 shockAssets = _draw(
                seed,
                keccak256(abi.encode("shock assets", round)),
                100_000e6,
                3_000_000e6
            );
            deal(USDC_MONAD, whale, shockAssets);
            vm.startPrank(whale);
            IERC20(USDC_MONAD).approve(markets[marketIndex], shockAssets);
            IBorrowableCToken(markets[marketIndex]).deposit(shockAssets, whale);
            vm.stopPrank();

            uint256 daysToSkip =
                _draw(seed, keccak256(abi.encode("days", round)), 0, 30);
            skip(daysToSkip * 1 days);

            _executeAndAssertStable(
                _incentives(
                    uint256(keccak256(abi.encode(seed, "incentives", round)))
                ),
                _draw(seed, keccak256(abi.encode("slippage", round)), 0, BPS),
                _draw(seed, keccak256(abi.encode("chunks", round)), 1, 500)
            );
        }
    }

    function _executeAndAssertStable(
        OptimizerReader.MarketIncentiveAPYBps[] memory incentives,
        uint256 slippageBps,
        uint256 chunks
    ) internal returns (Plan memory first) {
        first = _plan(incentives, slippageBps, chunks);
        _assertPlanWellFormed(first);

        if (first.actions.length > 0) {
            optimizer.rebalance(first.actions, first.bounds);
            _assertFreshAccounting();
        }

        Plan memory second = _plan(incentives, slippageBps, chunks);
        assertEq(
            second.actions.length,
            0,
            "immediate second plan should be threshold-suppressed or empty"
        );
        assertEq(second.bounds.length, 0, "second bounds should also be empty");
    }

    function _assertPlanWellFormed(Plan memory plan) internal view {
        assertEq(plan.actions.length, plan.bounds.length, "plan shape");
        if (plan.actions.length == 0) return;

        address[3] memory markets = _markets();
        int256 net;
        for (uint256 i; i < 3; ++i) {
            assertEq(
                address(plan.actions[i].cToken), markets[i], "action order"
            );
            assertEq(plan.bounds[i].cToken, markets[i], "bound order");

            int256 delta = plan.actions[i].assetsOrBps;
            net += delta;
            if (delta == 0) continue;

            uint256 assets = delta > 0 ? uint256(delta) : uint256(-delta);
            assertGt(
                IBorrowableCToken(markets[i]).convertToShares(assets),
                0,
                "nonzero action must mint or burn shares"
            );
            if (delta < 0) {
                assertLe(
                    assets,
                    IBorrowableCToken(markets[i]).assetsHeld(),
                    "withdrawal exceeds source cash"
                );
            }
        }

        assertEq(net, 0, "plan must be exactly balanced");
    }

    function _assertFreshAccounting() internal view {
        address[3] memory markets = _markets();
        uint256 freshAssets;
        for (uint256 i; i < 3; ++i) {
            IBorrowableCToken cToken = IBorrowableCToken(markets[i]);
            freshAssets += cToken.convertToAssets(
                cToken.balanceOf(address(optimizer))
            );
        }
        assertEq(
            optimizer.totalAssets(),
            freshAssets,
            "optimizer accounting is stale"
        );
    }

    function _setUpOptimizer() internal {
        address[3] memory listed = _markets();
        address[] memory markets = new address[](3);
        uint256[] memory caps = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            markets[i] = listed[i];
            caps[i] = BPS;
        }

        optimizer = new LendingOptimizerHarness(
            IERC20(USDC_MONAD), liveCentralRegistry, markets, caps, 0
        );
        deal(USDC_MONAD, address(this), 77777);
        IERC20(USDC_MONAD).approve(address(optimizer), 77777);
        optimizer.initializeDeposits(cUSDC_WMON_MARKET);

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(
                ICentralRegistry.hasHarvestPermissions.selector, address(this)
            ),
            abi.encode(true)
        );
    }

    function _depositScenario(uint256 seed) internal {
        uint256[3] memory allocations;
        for (uint256 i; i < 3; ++i) {
            allocations[i] = _draw(
                seed,
                keccak256(abi.encode("allocation", i)),
                10_000e6,
                500_000e6
            );
        }
        _depositAllocations(allocations);
    }

    function _depositAllocations(uint256[3] memory allocations) internal {
        address[3] memory markets = _markets();
        for (uint256 i; i < 3; ++i) {
            deal(USDC_MONAD, address(this), allocations[i]);
            IERC20(USDC_MONAD).approve(address(optimizer), allocations[i]);
            LendingOptimizerHarness(address(optimizer))
                .depositToMarket(allocations[i], address(this), markets[i]);
        }
    }

    function _plan(
        OptimizerReader.MarketIncentiveAPYBps[] memory incentives,
        uint256 slippageBps,
        uint256 chunks
    ) internal returns (Plan memory plan) {
        (plan.actions, plan.bounds) =
            reader.optimalRebalanceWithIncentives(
                    address(optimizer), slippageBps, chunks, incentives
                );
    }

    function _incentives(uint256 seed)
        internal
        view
        returns (OptimizerReader.MarketIncentiveAPYBps[] memory)
    {
        uint256[3] memory incentiveBps;
        for (uint256 i; i < 3; ++i) {
            incentiveBps[i] =
                _draw(seed, keccak256(abi.encode("incentive", i)), 0, 1_000);
        }
        return _taggedIncentives(incentiveBps);
    }

    function _taggedIncentives(uint256[3] memory incentiveBps)
        internal
        view
        returns (OptimizerReader.MarketIncentiveAPYBps[] memory incentives)
    {
        address[3] memory markets = _markets();
        incentives = new OptimizerReader.MarketIncentiveAPYBps[](3);
        for (uint256 i; i < 3; ++i) {
            incentives[i] = OptimizerReader.MarketIncentiveAPYBps({
                cToken: markets[i], incentiveAPYBps: incentiveBps[i]
            });
        }
    }

    function _markets() internal view returns (address[3] memory markets) {
        markets[0] = cUSDC_WMON_MARKET;
        markets[1] = cUSDC_WBTC_MARKET;
        markets[2] = cUSDC_WETH_MARKET;
    }

    function _draw(
        uint256 seed,
        bytes32 salt,
        uint256 minValue,
        uint256 maxValue
    ) internal pure returns (uint256) {
        return minValue + uint256(keccak256(abi.encode(seed, salt)))
            % (maxValue - minValue + 1);
    }
}
