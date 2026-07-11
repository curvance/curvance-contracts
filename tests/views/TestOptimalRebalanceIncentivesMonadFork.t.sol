// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    LendingOptimizer
} from "contracts/market/optimizer/LendingOptimizer.sol";
import {OptimizerReader} from "contracts/views/OptimizerReader.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";

interface ICentralRegistryIncentiveFork is ICentralRegistry {
    function emergencyCouncil() external view returns (address);
    function addHarvestPermissions(address account) external;
}

contract TestOptimalRebalanceIncentivesMonadFork is Test {
    address internal constant LENDING_OPTIMIZER =
        0x37Bf94D8Af2Fbbf562Da5a3f1b0787b3515D10dd;
    address internal constant CENTRAL_REGISTRY =
        0x1310f352f1389969Ece6741671c4B919523912fF;

    // Monad mainnet block 75302964, timestamp 2026-05-18 01:51:57 UTC.
    uint256 internal constant FORK_BLOCK = 75_302_964;
    uint256 internal constant DEFAULT_SLIPPAGE_BPS = 100;
    uint256 internal constant REBALANCE_CHUNKS = 200;

    LendingOptimizer internal optimizer;
    OptimizerReader internal reader;

    function setUp() public {
        vm.createSelectFork(
            vm.envString("MON_NODE_URI_MONAD_ARCHIVE"), FORK_BLOCK
        );

        optimizer = LendingOptimizer(LENDING_OPTIMIZER);
        reader = new OptimizerReader(ICentralRegistry(CENTRAL_REGISTRY), 0);

        ICentralRegistryIncentiveFork registry =
            ICentralRegistryIncentiveFork(CENTRAL_REGISTRY);
        vm.prank(registry.emergencyCouncil());
        registry.addHarvestPermissions(address(this));
    }

    function test_incentiveAwarePlanExecutesAgainstPinnedMonadState() public {
        address[] memory markets = optimizer.getApprovedMarkets();
        assertGt(markets.length, 1, "fork needs multiple optimizer markets");

        for (uint256 i; i < markets.length; ++i) {
            uint256 snapshotId = vm.snapshotState();
            if (_planAndExecuteForTarget(markets, markets[i])) return;

            assertTrue(
                vm.revertToState(snapshotId),
                "failed to restore pinned optimizer state"
            );
        }

        assertTrue(false, "no incentive target produced an executable plan");
    }

    function _planAndExecuteForTarget(address[] memory markets, address target)
        internal
        returns (bool)
    {
        OptimizerReader.MarketIncentiveAPYBps[] memory incentives =
            new OptimizerReader.MarketIncentiveAPYBps[](1);
        incentives[0] = OptimizerReader.MarketIncentiveAPYBps({
            cToken: target, incentiveAPYBps: reader.MAX_INCENTIVE_APY_BPS()
        });

        (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        ) = reader.optimalRebalanceWithIncentives(
            LENDING_OPTIMIZER,
            DEFAULT_SLIPPAGE_BPS,
            REBALANCE_CHUNKS,
            incentives
        );

        if (actions.length == 0) return false;

        assertEq(actions.length, markets.length, "action length");
        assertEq(bounds.length, markets.length, "bound length");

        uint256 deposits;
        uint256 withdrawals;
        for (uint256 i; i < markets.length; ++i) {
            assertEq(address(actions[i].cToken), markets[i], "action order");
            assertEq(bounds[i].cToken, markets[i], "bound order");

            int256 amount = actions[i].assetsOrBps;
            if (amount > 0) deposits += uint256(amount);
            else if (amount < 0) withdrawals += uint256(-amount);
        }
        assertEq(deposits, withdrawals, "plan must balance exactly");

        optimizer.rebalance(actions, bounds);
        assertGt(optimizer.totalAssets(), 0, "optimizer accounting emptied");
        return true;
    }
}
