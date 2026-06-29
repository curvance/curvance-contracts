// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {LendingOptimizer} from "contracts/market/optimizer/LendingOptimizer.sol";
import {OptimizerReaderHarness} from "tests/market/optimizer/OptimizerReaderHarness.sol";

import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IBorrowableCToken} from "contracts/interfaces/IBorrowableCToken.sol";

interface ICentralRegistryHighChunksExt is ICentralRegistry {
    function emergencyCouncil() external view returns (address);
    function addHarvestPermissions(address account) external;
}

contract TestOptimizerReaderHighChunksMonadFork is Test {
    address constant LENDING_OPTIMIZER = 0x37Bf94D8Af2Fbbf562Da5a3f1b0787b3515D10dd;
    address constant CENTRAL_REGISTRY = 0x1310f352f1389969Ece6741671c4B919523912fF;

    // Monad mainnet block 75302964, timestamp 2026-05-18 01:51:57 UTC.
    uint256 constant FORK_BLOCK = 75_302_964;
    uint256 constant DEFAULT_SLIPPAGE_BPS = 100;
    uint256 constant FULL_CAP_BPS = 10_000;

    OptimizerReaderHarness reader;
    LendingOptimizer optimizer;
    ICentralRegistryHighChunksExt centralRegistry;

    function setUp() public {
        vm.createSelectFork(vm.envString("MON_NODE_URI_MONAD_ARCHIVE"), FORK_BLOCK);

        optimizer = LendingOptimizer(LENDING_OPTIMIZER);
        centralRegistry = ICentralRegistryHighChunksExt(CENTRAL_REGISTRY);
        reader = new OptimizerReaderHarness(ICentralRegistry(CENTRAL_REGISTRY));

        address ec = centralRegistry.emergencyCouncil();
        address[] memory markets = optimizer.getApprovedMarkets();
        for (uint256 i; i < markets.length; ++i) {
            vm.prank(ec);
            optimizer.updateCap(markets[i], FULL_CAP_BPS);
        }

        vm.prank(ec);
        centralRegistry.addHarvestPermissions(address(this));
    }

    function test_highChunkReaderExecutesAllCapsPlan() public {
        (LendingOptimizer.ReallocationAction[] memory actions, LendingOptimizer.AllocationBound[] memory bounds) =
            reader.optimalRebalance(LENDING_OPTIMIZER, DEFAULT_SLIPPAGE_BPS, 100);

        uint256 moved = _totalMoved(actions);
        console2.log("actions", actions.length);
        console2.log("total moved", moved);
        for (uint256 i; i < actions.length; ++i) {
            console2.log("market", address(actions[i].cToken));
            console2.logInt(actions[i].assetsOrBps);
        }

        assertGt(actions.length, 0, "reader should return actions");
        assertGt(moved, 0, "reader should move assets");

        optimizer.rebalance(actions, bounds);
        _assertEveryMarketUnderCap();
    }

    function _totalMoved(LendingOptimizer.ReallocationAction[] memory actions) internal pure returns (uint256 total) {
        for (uint256 i; i < actions.length; ++i) {
            int256 amount = actions[i].assetsOrBps;
            if (amount > 0) total += uint256(amount);
        }
    }

    function _assertEveryMarketUnderCap() internal view {
        address[] memory markets = optimizer.getApprovedMarkets();
        uint256 ta = optimizer.totalAssets();
        if (ta == 0) return;

        for (uint256 i; i < markets.length; ++i) {
            uint256 shares = IBorrowableCToken(markets[i]).balanceOf(LENDING_OPTIMIZER);
            uint256 assetsAlloc = IBorrowableCToken(markets[i]).convertToAssets(shares);
            uint256 allocWad = (assetsAlloc * 1e18) / ta;
            uint256 cap = optimizer.allocationCaps(markets[i]);
            assertLe(allocWad, cap, "market allocation exceeds cap");
        }
    }
}
