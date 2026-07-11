// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {TestBaseLendingOptimizer} from "../TestBaseLendingOptimizer.sol";
import {LendingOptimizerHarness} from "../LendingOptimizerHarness.sol";
import {IncentivePlannerHandler} from "./IncentivePlannerHandler.sol";
import {OptimizerReader} from "contracts/views/OptimizerReader.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {
    IChainlink
} from "contracts/interfaces/external/chainlink/IChainlink.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {BPS} from "contracts/libraries/ConstantsLib.sol";

contract IncentivePlannerInvariant is TestBaseLendingOptimizer {
    IncentivePlannerHandler public handler;
    LendingOptimizerHarness public harness;
    OptimizerReader public reader;

    function setUp() public override {
        super.setUp();

        address[] memory markets = new address[](3);
        markets[0] = cUSDC_WMON_MARKET;
        markets[1] = cUSDC_WBTC_MARKET;
        markets[2] = cUSDC_WETH_MARKET;
        uint256[] memory caps = new uint256[](3);
        caps[0] = BPS;
        caps[1] = BPS;
        caps[2] = BPS;

        harness = new LendingOptimizerHarness(
            IERC20(USDC_MONAD), liveCentralRegistry, markets, caps, 0
        );
        optimizer = harness;
        deal(USDC_MONAD, address(this), 77777);
        IERC20(USDC_MONAD).approve(address(harness), 77777);
        harness.initializeDeposits(cUSDC_WMON_MARKET);

        for (uint256 i; i < markets.length; ++i) {
            deal(USDC_MONAD, address(this), 100_000e6);
            IERC20(USDC_MONAD).approve(address(harness), 100_000e6);
            harness.depositToMarket(100_000e6, address(this), markets[i]);
        }

        reader = new OptimizerReader(liveCentralRegistry, 15_000);
        address[] memory managers = new address[](3);
        address[] memory collateralAggregators = new address[](3);
        for (uint256 i; i < markets.length; ++i) {
            managers[i] = _marketMgrs[markets[i]];
            (, IChainlink aggregator,,) =
                _chainlinkAdaptor.assetConfig(_collaterals[markets[i]], true);
            collateralAggregators[i] = address(aggregator);
        }
        (, IChainlink underlyingAggregator,,) =
            _chainlinkAdaptor.assetConfig(USDC_MONAD, true);

        handler = new IncentivePlannerHandler(
            harness,
            reader,
            IERC20(USDC_MONAD),
            address(this),
            markets,
            managers,
            collateralAggregators,
            address(underlyingAggregator)
        );
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(
                ICentralRegistry.hasHarvestPermissions.selector,
                address(handler)
            ),
            abi.encode(true)
        );

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = IncentivePlannerHandler.setIncentives.selector;
        selectors[1] = IncentivePlannerHandler.setMintPaused.selector;
        selectors[2] = IncentivePlannerHandler.setRedeemPaused.selector;
        selectors[3] = IncentivePlannerHandler.markOneMarketBad.selector;
        selectors[4] = IncentivePlannerHandler.refreshAllFeeds.selector;
        selectors[5] = IncentivePlannerHandler.advanceTime.selector;
        selectors[6] = IncentivePlannerHandler.shockLiquidity.selector;
        selectors[7] = IncentivePlannerHandler.planAndExecute.selector;
        selectors[8] = IncentivePlannerHandler.tightenCashByBorrow.selector;
        targetContract(address(handler));
        targetSelector(
            FuzzSelector({addr: address(handler), selectors: selectors})
        );
        excludeSender(address(0));
        excludeSender(address(handler));
        excludeSender(address(harness));
    }

    function invariant_noForbiddenOrUnexecutablePlan() public view {
        assertFalse(
            handler.ghost_violation(),
            "stateful incentive planner recorded a violation"
        );
        assertEq(
            handler.ghost_executedPlans(),
            handler.ghost_nonemptyPlans(),
            "every nonempty plan must execute"
        );
        assertLe(
            handler.ghost_nonemptyPlans(),
            handler.ghost_planCalls(),
            "nonempty plans exceed planner calls"
        );
    }

    function test_statefulIncentivePlanner_smokeTransitions() public {
        handler.setIncentives(0, 1_000, 500);
        handler.planAndExecute(0, 200);
        handler.setMintPaused(1, true);
        handler.planAndExecute(500, 100);
        handler.setRedeemPaused(0, true);
        handler.markOneMarketBad(2);
        handler.planAndExecute(250, 300);
        handler.setRedeemPaused(0, false);
        handler.setMintPaused(1, false);
        handler.refreshAllFeeds();
        handler.shockLiquidity(2, 1_000_000e6);
        handler.tightenCashByBorrow(1, 25_000e6);
        handler.advanceTime(7 days);
        handler.planAndExecute(BPS, 500);

        assertFalse(handler.ghost_violation(), "smoke transition violation");
        assertEq(handler.ghost_planCalls(), 4, "unexpected smoke plan count");
    }
}
