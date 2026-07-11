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
import {
    FixedPointMathLib
} from "contracts/libraries/external/FixedPointMathLib.sol";
import {BPS, WAD} from "contracts/libraries/ConstantsLib.sol";

contract TestIncentiveMaxMarketStress is TestBaseLendingOptimizer {
    OptimizerReader internal reader;

    function setUp() public override {
        super.setUp();
        reader = new OptimizerReader(
            ICentralRegistry(address(liveCentralRegistry)), 0
        );
    }

    function test_stress_eightMarketsFiveHundredChunks_executesAndMeasures()
        public
    {
        address[] memory markets = _deployEightMarketOptimizer();
        OptimizerReader.MarketIncentiveAPYBps[] memory incentives =
            _incentives(markets);

        uint256 plannerGas100 = _measurePlannerGas(incentives, 100);
        uint256 plannerGas200 = _measurePlannerGas(incentives, 200);
        uint256 gasBefore = gasleft();
        (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        ) = reader.optimalRebalanceWithIncentives(
            address(optimizer), 0, 500, incentives
        );
        uint256 plannerGas = gasBefore - gasleft();
        emit log_named_uint(
            "eight-market planner gas, 100 chunks", plannerGas100
        );
        emit log_named_uint(
            "eight-market planner gas, 200 chunks", plannerGas200
        );
        emit log_named_uint("eight-market planner gas", plannerGas);
        emit log_named_uint("top-level planner RPC calls", 1);

        assertEq(actions.length, 8, "stress plan should be nonempty");
        assertEq(bounds.length, 8, "stress bounds length");
        _assertPlanShape(actions, bounds, markets);

        optimizer.rebalance(actions, bounds);
        _assertPostExecutionCaps(markets);

        (
            LendingOptimizer.ReallocationAction[] memory secondActions,
            LendingOptimizer.AllocationBound[] memory secondBounds
        ) = reader.optimalRebalanceWithIncentives(
            address(optimizer), 0, 500, incentives
        );
        assertEq(secondActions.length, 0, "second stress plan should be empty");
        assertEq(
            secondBounds.length, 0, "second stress bounds should be empty"
        );
        assertGt(plannerGas, 0, "planner gas was not measured");
    }

    function _measurePlannerGas(
        OptimizerReader.MarketIncentiveAPYBps[] memory incentives,
        uint256 chunks
    ) internal returns (uint256 gasUsed) {
        uint256 gasBefore = gasleft();
        reader.optimalRebalanceWithIncentives(
            address(optimizer), 0, chunks, incentives
        );
        gasUsed = gasBefore - gasleft();
    }

    function _deployEightMarketOptimizer()
        internal
        returns (address[] memory markets)
    {
        markets = new address[](8);
        markets[0] = cUSDC_WMON_MARKET;
        markets[1] = cUSDC_WBTC_MARKET;
        markets[2] = cUSDC_WETH_MARKET;

        for (uint256 i = 3; i < 8; ++i) {
            markets[i] = _deployMarket(
                500 + i * 100, 2_000 + i * 100, 8_000, 1_000, 100, 100_000
            );
        }

        uint256[] memory caps = new uint256[](8);
        for (uint256 i; i < 8; ++i) {
            caps[i] = 2_000;
        }
        optimizer = new LendingOptimizerHarness(
            IERC20(USDC_MONAD), liveCentralRegistry, markets, caps, 0
        );
        assertEq(optimizer.numApprovedMarkets(), 8, "not at MAX_MARKETS");

        deal(USDC_MONAD, address(this), 77777);
        IERC20(USDC_MONAD).approve(address(optimizer), 77777);
        optimizer.initializeDeposits(markets[0]);

        for (uint256 i; i < 8; ++i) {
            uint256 assets = i == 0 ? 400_000e6 : 50_000e6;
            deal(USDC_MONAD, address(this), assets);
            IERC20(USDC_MONAD).approve(address(optimizer), assets);
            LendingOptimizerHarness(address(optimizer))
                .depositToMarket(assets, address(this), markets[i]);
        }

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(
                ICentralRegistry.hasHarvestPermissions.selector, address(this)
            ),
            abi.encode(true)
        );
    }

    function _incentives(address[] memory markets)
        internal
        pure
        returns (OptimizerReader.MarketIncentiveAPYBps[] memory incentives)
    {
        incentives = new OptimizerReader
            .MarketIncentiveAPYBps[](markets.length);
        for (uint256 i; i < markets.length; ++i) {
            incentives[i] = OptimizerReader.MarketIncentiveAPYBps({
                cToken: markets[i], incentiveAPYBps: i * 100
            });
        }
    }

    function _assertPlanShape(
        LendingOptimizer.ReallocationAction[] memory actions,
        LendingOptimizer.AllocationBound[] memory bounds,
        address[] memory markets
    ) internal view {
        int256 net;
        for (uint256 i; i < markets.length; ++i) {
            assertEq(address(actions[i].cToken), markets[i], "action order");
            assertEq(bounds[i].cToken, markets[i], "bound order");
            net += actions[i].assetsOrBps;

            int256 delta = actions[i].assetsOrBps;
            if (delta == 0) continue;
            uint256 assets = delta > 0 ? uint256(delta) : uint256(-delta);
            assertGt(
                IBorrowableCToken(markets[i]).convertToShares(assets),
                0,
                "stress action is dust"
            );
            if (delta < 0) {
                assertLe(
                    assets,
                    IBorrowableCToken(markets[i]).assetsHeld(),
                    "stress withdrawal exceeds cash"
                );
            }
        }
        assertEq(net, 0, "stress plan is unbalanced");
    }

    function _assertPostExecutionCaps(address[] memory markets) internal view {
        uint256 totalAssets;
        uint256[] memory allocations = new uint256[](markets.length);
        for (uint256 i; i < markets.length; ++i) {
            IBorrowableCToken cToken = IBorrowableCToken(markets[i]);
            allocations[i] =
                cToken.convertToAssets(cToken.balanceOf(address(optimizer)));
            totalAssets += allocations[i];
        }

        assertEq(
            optimizer.totalAssets(), totalAssets, "stress accounting drift"
        );
        for (uint256 i; i < markets.length; ++i) {
            uint256 allocationWad =
                FixedPointMathLib.fullMulDiv(allocations[i], WAD, totalAssets);
            assertLe(
                allocationWad,
                optimizer.allocationCaps(markets[i]),
                "stress allocation exceeds cap"
            );
        }
    }
}
