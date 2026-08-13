// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {LendingOptimizer} from "contracts/market/optimizer/LendingOptimizer.sol";
import {OptimizerReader} from "contracts/views/OptimizerReader.sol";
import {IBorrowableCToken} from "contracts/interfaces/IBorrowableCToken.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";

contract TestHighYieldAUSDOptimizerReaderMonadFork is Test {
    address constant HIGH_YIELD_AUSD_OPTIMIZER =
        0xaD663aC84052b52BE4ed1b27BA416505e84a00Bf;
    address constant CENTRAL_REGISTRY =
        0x1310f352f1389969Ece6741671c4B919523912fF;
    address constant HARVESTER =
        0xD21DC65f42fB039A1c403a38C18C2731211eCBC7;

    uint256 constant DEFAULT_SLIPPAGE_BPS = 500;
    uint256 constant REBALANCE_CHUNKS = 200;

    LendingOptimizer optimizer;
    OptimizerReader reader;

    function setUp() public {
        vm.createSelectFork(vm.envString("MON_NODE_URI_MONAD_ARCHIVE"));

        optimizer = LendingOptimizer(HIGH_YIELD_AUSD_OPTIMIZER);
        reader = new OptimizerReader(ICentralRegistry(CENTRAL_REGISTRY), 0);
    }

    function test_highYieldAUSDLatestPlanRespectsLiquidityAndExecutes() public {
        (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        ) = reader.optimalRebalance(
            HIGH_YIELD_AUSD_OPTIMIZER,
            DEFAULT_SLIPPAGE_BPS,
            REBALANCE_CHUNKS,
            new OptimizerReader.MarketIncentiveAPYBps[](0)
        );

        assertEq(actions.length, bounds.length, "actions/bounds length");
        if (actions.length == 0) return;

        uint256 totalDeposits;
        uint256 totalWithdrawals;
        for (uint256 i; i < actions.length; ++i) {
            int256 amount = actions[i].assetsOrBps;

            if (amount > 0) {
                totalDeposits += uint256(amount);
            } else if (amount < 0) {
                uint256 withdrawal = uint256(-amount);
                totalWithdrawals += withdrawal;
                assertLe(
                    withdrawal,
                    actions[i].cToken.assetsHeld(),
                    "withdraw exceeds cToken assetsHeld"
                );
            }
        }

        assertEq(totalDeposits, totalWithdrawals, "actions must balance");

        vm.prank(HARVESTER);
        optimizer.rebalance(actions, bounds);

        _assertEveryMarketUnderCap();
    }

    function _assertEveryMarketUnderCap() internal view {
        address[] memory markets = optimizer.getApprovedMarkets();
        uint256 totalAssets = optimizer.totalAssets();
        if (totalAssets == 0) return;

        for (uint256 i; i < markets.length; ++i) {
            IBorrowableCToken market = IBorrowableCToken(markets[i]);
            uint256 assets = market.convertToAssets(
                market.balanceOf(HIGH_YIELD_AUSD_OPTIMIZER)
            );
            uint256 allocationWad = (assets * 1e18) / totalAssets;

            assertLe(
                allocationWad,
                optimizer.allocationCaps(markets[i]),
                "market allocation exceeds cap"
            );
        }
    }
}
