// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { OptimizerReader } from "contracts/views/OptimizerReader.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { ILendingOptimizer } from "contracts/interfaces/ILendingOptimizer.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

interface ICentralRegistryExt is ICentralRegistry {
    function emergencyCouncil() external view returns (address);
    function addHarvestPermissions(address) external;
}

interface IOptimizerReaderAt {
    function optimalRebalanceAt(
        address optimizer,
        uint256 slippageBps,
        uint256 timestamp
    ) external view returns (
        LendingOptimizer.ReallocationAction[] memory actions,
        LendingOptimizer.AllocationBound[] memory bounds
    );
}

/// @notice Reproduces the live-mainnet optimalRebalance + rebalance flow on
///         a Monad fork to investigate the current rebalance failure.
contract TestOptimizerReaderRebalanceMonadFork is Test {
    address constant OPTIMIZER_READER =
        0x9245b84D2e0Ca8FCC89747932D26a65a644e8870;
    address constant LENDING_OPTIMIZER =
        0x37Bf94D8Af2Fbbf562Da5a3f1b0787b3515D10dd;
    address constant CENTRAL_REGISTRY =
        0x1310f352f1389969Ece6741671c4B919523912fF;

    OptimizerReader reader;
    OptimizerReader localReader;
    LendingOptimizer optimizer;
    ICentralRegistryExt centralRegistry;

    address harvester;

    function setUp() public {
        vm.createSelectFork(vm.envString("MON_NODE_URI_MONAD_MAINNET"));

        reader = OptimizerReader(OPTIMIZER_READER);
        optimizer = LendingOptimizer(LENDING_OPTIMIZER);
        centralRegistry = ICentralRegistryExt(CENTRAL_REGISTRY);

        // Deploy a fresh OptimizerReader from the locally edited source so we
        // can compare behavior against the already-deployed reader.
        localReader = new OptimizerReader(
            ICentralRegistry(CENTRAL_REGISTRY),
            11000
        );

        // Grant this contract harvester permissions through the emergency
        // council (which has elevated permissions on the live registry).
        harvester = address(this);
        address ec = centralRegistry.emergencyCouncil();
        vm.prank(ec);
        centralRegistry.addHarvestPermissions(harvester);
        assertTrue(
            centralRegistry.hasHarvestPermissions(harvester),
            "harvester perms not granted"
        );
    }

    function test_optimalRebalance_thenRebalance_fromDeployedReader() public {
        _runRebalance(reader, "DEPLOYED reader");
    }

    function test_optimalRebalance_thenRebalance_fromLocalReader() public {
        _runRebalance(localReader, "LOCAL reader");
    }

    function test_optimalRebalanceAt_targetPlus10s() public {
        _runRebalanceAt(10);
    }

    function test_optimalRebalanceAt_targetPlus30s() public {
        _runRebalanceAt(30);
    }

    function test_optimalRebalanceAt_targetPlus5min() public {
        _runRebalanceAt(300);
    }

    function test_optimalRebalanceAt_targetPlus1h() public {
        _runRebalanceAt(3600);
    }

    function test_optimalRebalanceAt_targetPlus1day() public {
        _runRebalanceAt(86400);
    }

    function _runRebalanceAt(uint256 deltaSeconds) internal {
        console2.log("--- optimalRebalanceAt(+%ss) ---", deltaSeconds);

        uint256 target = block.timestamp + deltaSeconds;

        (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        ) = IOptimizerReaderAt(address(localReader)).optimalRebalanceAt(
            LENDING_OPTIMIZER,
            100,
            target
        );

        if (actions.length == 0) {
            console2.log("returned empty - nothing to do");
            return;
        }

        for (uint256 i; i < actions.length; ++i) {
            console2.log("action[%s]:", i);
            console2.logInt(actions[i].assetsOrBps);
        }

        vm.prank(harvester);
        optimizer.rebalance(actions, bounds);

        console2.log(">>> rebalance() OK at +%ss delta", deltaSeconds);
        _logOptimizerState();
    }

    function _runRebalance(OptimizerReader r, string memory label) internal {
        console2.log("---", label, "---");

        // Log pre-rebalance state.
        _logOptimizerState();

        (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        ) = r.optimalRebalance(LENDING_OPTIMIZER, 100);

        console2.log("actions.length:", actions.length);
        console2.log("bounds.length:", bounds.length);

        if (actions.length == 0) {
            console2.log("optimalRebalance returned empty arrays - nothing to do");
            return;
        }

        int256 sumDeltas;
        for (uint256 i; i < actions.length; ++i) {
            console2.log("  action[%s] cToken:", i, address(actions[i].cToken));
            console2.logInt(actions[i].assetsOrBps);
            sumDeltas += actions[i].assetsOrBps;
        }
        console2.log("sum(assetsOrBps) (must be 0):");
        console2.logInt(sumDeltas);

        for (uint256 i; i < bounds.length; ++i) {
            console2.log(
                "  bound[%s] cToken:",
                i,
                bounds[i].cToken
            );
            console2.log("    minBps:", bounds[i].minBps);
            console2.log("    maxBps:", bounds[i].maxBps);
        }

        // Now actually call rebalance on the live optimizer as the harvester
        // and surface whatever revert reason it produces.
        vm.prank(harvester);
        optimizer.rebalance(actions, bounds);

        console2.log(">>> rebalance() succeeded");
        _logOptimizerState();
    }

    function _logOptimizerState() internal view {
        address asset = optimizer.asset();
        uint256 dec = IERC20(asset).decimals();
        uint256 ta = optimizer.totalAssets();
        console2.log("asset:", asset, "decimals:", dec);
        console2.log("totalAssets (raw):", ta);

        address[] memory markets = optimizer.getApprovedMarkets();
        for (uint256 i; i < markets.length; ++i) {
            IBorrowableCToken ct = IBorrowableCToken(markets[i]);
            uint256 shares = ct.balanceOf(LENDING_OPTIMIZER);
            uint256 assets = ct.convertToAssets(shares);
            uint256 cap = optimizer.allocationCaps(markets[i]);
            console2.log("market[%s] addr:", i, markets[i]);
            console2.log("    shares:", shares);
            console2.log("    assets allocated:", assets);
            console2.log("    allocationCap (WAD):", cap);
        }
    }
}
