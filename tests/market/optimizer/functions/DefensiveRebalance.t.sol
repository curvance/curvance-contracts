// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { LendingOptimizerHarness } from "../LendingOptimizerHarness.sol";
import { OptimizerReader } from "contracts/views/OptimizerReader.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { WAD } from "contracts/libraries/ConstantsLib.sol";

contract TestDefensiveRebalance is TestBaseLendingOptimizer {

    OptimizerReader reader;

    function setUp() public override {
        super.setUp();
        reader = new OptimizerReader(
            ICentralRegistry(address(liveCentralRegistry)),
            new OptimizerReader.CollateralGuardConfig[](0),
            0
        );
    }

    // ============ Basic Return Shape ============

    function test_optimalRebalance_defensive_success_returnsCorrectArrayLengths() public {
        _setUpThreeMarkets();
        _depositToAllMarkets(50_000e6);

        _mockIsBad(_noBadMarkets());

        (LendingOptimizer.ReallocationAction[] memory actions,
         LendingOptimizer.AllocationBound[] memory bounds) = reader.optimalRebalance(address(optimizer), 500);

        assertEq(actions.length, 3, "Actions should have 3 markets");
        assertEq(bounds.length, 3, "Bounds should have 3 markets");
    }

    function test_optimalRebalance_defensive_success_marketsMatchApprovedList() public {
        _setUpThreeMarkets();
        _depositToAllMarkets(50_000e6);

        _mockIsBad(_noBadMarkets());

        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500);

        assertEq(address(actions[0].cToken), cUSDC_WMON_MARKET, "Market 0 mismatch");
        assertEq(address(actions[1].cToken), cUSDC_WBTC_MARKET, "Market 1 mismatch");
        assertEq(address(actions[2].cToken), cUSDC_WETH_MARKET, "Market 2 mismatch");
    }

    // ============ No Bad Markets — Same As Optimal ============

    function test_optimalRebalance_defensive_success_noBadMarketsMatchesOptimal() public {
        _setUpThreeMarkets();
        _depositToAllMarkets(50_000e6);

        _mockIsBad(_noBadMarkets());

        (LendingOptimizer.ReallocationAction[] memory defActions,
         LendingOptimizer.AllocationBound[] memory defBounds) =
            reader.optimalRebalance(address(optimizer), 500);

        // Clear mock so optimalRebalance uses the real (empty) path.
        vm.clearMockedCalls();

        (LendingOptimizer.ReallocationAction[] memory optActions,
         LendingOptimizer.AllocationBound[] memory optBounds) =
            reader.optimalRebalance(address(optimizer), 500);

        for (uint256 i; i < defActions.length; ++i) {
            assertEq(
                defActions[i].assetsOrBps,
                optActions[i].assetsOrBps,
                string.concat("Action mismatch at index ", vm.toString(i))
            );
            assertEq(defBounds[i].minBps, optBounds[i].minBps, "Min bound mismatch");
            assertEq(defBounds[i].maxBps, optBounds[i].maxBps, "Max bound mismatch");
        }
    }

    // ============ One Bad Market — Full Withdrawal ============

    /// @dev Uses constrained setup with market 2 (20% cap) as bad.
    ///      Remaining caps: 60% + 50% = 110%, so redistribution fits.
    function test_optimalRebalance_defensive_success_oneBadMarketFullyWithdrawn() public {
        _setUpThreeMarkets();
        _depositToAllMarkets(50_000e6);

        _mockIsBad(_singleBadMarket(cUSDC_WETH_MARKET));

        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500);

        // Bad market (index 2) should have a full withdrawal (negative action).
        assertLt(actions[2].assetsOrBps, 0, "Bad market should have negative action");

        // The withdrawn amount should equal the current allocation.
        uint256 currentBadAlloc = IBorrowableCToken(cUSDC_WETH_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WETH_MARKET).balanceOf(address(optimizer))
        );
        assertApproxEqAbs(
            uint256(-actions[2].assetsOrBps),
            currentBadAlloc,
            optimizer.totalAssets() / 20 + 1,
            "Bad market withdrawal should approximate current allocation"
        );
    }

    function test_optimalRebalance_defensive_success_oneBadMarketZeroBounds() public {
        _setUpThreeMarkets();
        _depositToAllMarkets(50_000e6);

        _mockIsBad(_singleBadMarket(cUSDC_WETH_MARKET));

        (, LendingOptimizer.AllocationBound[] memory bounds) =
            reader.optimalRebalance(address(optimizer), 500);

        // Bad market's ideal allocation is 0, so bounds should be [0, slippageBps].
        assertEq(bounds[2].minBps, 0, "Bad market minBps should be 0");
        assertLe(bounds[2].maxBps, 500, "Bad market maxBps should be <= slippageBps");
    }

    function test_optimalRebalance_defensive_success_oneBadMarketGoodMarketsReceiveDeposits() public {
        _setUpThreeMarkets();
        _depositToAllMarkets(50_000e6);

        _mockIsBad(_singleBadMarket(cUSDC_WETH_MARKET));

        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500);

        // At least one good market should receive deposits.
        bool hasDeposit;
        for (uint256 i; i < 2; ++i) {
            if (actions[i].assetsOrBps > 0) {
                hasDeposit = true;
                break;
            }
        }
        assertTrue(hasDeposit, "Good markets should receive deposits");
    }

    // ============ Balance of Flows ============

    function test_optimalRebalance_defensive_success_totalDepositsEqualWithdrawals() public {
        _setUpUnconstrainedOptimizer();
        _depositToAllMarketsUnconstrained(50_000e6);

        _mockIsBad(_singleBadMarket(cUSDC_WMON_MARKET));

        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500);

        uint256 totalDeposits;
        uint256 totalWithdrawals;
        for (uint256 i; i < actions.length; ++i) {
            if (actions[i].assetsOrBps > 0) {
                totalDeposits += uint256(actions[i].assetsOrBps);
            } else if (actions[i].assetsOrBps < 0) {
                totalWithdrawals += uint256(-actions[i].assetsOrBps);
            }
        }

        assertApproxEqAbs(
            totalDeposits,
            totalWithdrawals,
            optimizer.totalAssets() / 20 + 1,
            "Deposits and withdrawals should roughly balance"
        );
    }

    // ============ Cap Compliance ============

    function test_optimalRebalance_defensive_success_idealAllocationRespectsAllCaps() public {
        _setUpUnconstrainedOptimizer();
        _depositToAllMarketsUnconstrained(50_000e6);

        _mockIsBad(_singleBadMarket(cUSDC_WETH_MARKET));

        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500);

        uint256 ta = optimizer.totalAssets();

        for (uint256 i; i < actions.length; ++i) {
            IBorrowableCToken ct = actions[i].cToken;
            uint256 current = ct.convertToAssets(ct.balanceOf(address(optimizer)));

            uint256 ideal;
            if (actions[i].assetsOrBps > 0) {
                ideal = current + uint256(actions[i].assetsOrBps);
            } else if (actions[i].assetsOrBps < 0) {
                ideal = current - uint256(-actions[i].assetsOrBps);
            } else {
                ideal = current;
            }

            uint256 cap = optimizer.allocationCaps(address(actions[i].cToken));
            uint256 maxAllowed = FixedPointMathLib.mulDiv(ta, cap, WAD);

            assertLe(
                ideal,
                maxAllowed + 1,
                string.concat("Market ", vm.toString(i), " ideal exceeds cap")
            );
        }
    }

    // ============ Integration: Actions Execute Rebalance ============

    function test_optimalRebalance_defensive_success_actionsExecuteRebalance() public {
        _setUpUnconstrainedOptimizer();
        _depositToAllMarketsUnconstrained(50_000e6);

        _mockIsBad(_singleBadMarket(cUSDC_WMON_MARKET));

        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500);

        uint256 totalAssetsBefore = optimizer.totalAssets();

        // Execute with unconstrained bounds — should not revert.
        _rebalance(optimizer, actions, _unconstrainedBounds());

        uint256 totalAssetsAfter = optimizer.totalAssets();
        assertApproxEqAbs(
            totalAssetsAfter,
            totalAssetsBefore,
            actions.length * 2,
            "Total assets should be preserved"
        );
    }

    function test_optimalRebalance_defensive_success_postRebalanceBadMarketEmpty() public {
        _setUpUnconstrainedOptimizer();
        _depositToAllMarketsUnconstrained(50_000e6);

        _mockIsBad(_singleBadMarket(cUSDC_WMON_MARKET));

        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500);

        _rebalance(optimizer, actions, _unconstrainedBounds());

        // Bad market should have near-zero allocation after rebalance.
        uint256 badAlloc = IBorrowableCToken(cUSDC_WMON_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer))
        );
        assertLe(badAlloc, 1, "Bad market should be empty after defensive rebalance");
    }

    function test_optimalRebalance_defensive_success_postRebalanceAllocationWithinCaps() public {
        _setUpUnconstrainedOptimizer();
        _depositToAllMarketsUnconstrained(50_000e6);

        _mockIsBad(_singleBadMarket(cUSDC_WMON_MARKET));

        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500);

        _rebalance(optimizer, actions, _unconstrainedBounds());

        uint256 ta = optimizer.totalAssets();
        for (uint256 i; i < actions.length; ++i) {
            IBorrowableCToken ct = actions[i].cToken;
            uint256 allocated = ct.convertToAssets(ct.balanceOf(address(optimizer)));
            uint256 allocationWad = FixedPointMathLib.mulDiv(allocated, WAD, ta);
            uint256 cap = optimizer.allocationCaps(address(actions[i].cToken));

            assertLe(
                allocationWad,
                cap,
                string.concat("Market ", vm.toString(i), " allocation exceeds cap post-rebalance")
            );
        }
    }

    // ============ Reader Bounds Are Executable ============

    function test_optimalRebalance_defensive_success_boundsPassRebalance() public {
        _setUpUnconstrainedOptimizer();

        // Deposit unevenly to force meaningful actions.
        deal(USDC_MONAD, address(this), 50_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 50_000e6);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(30_000e6, address(this), cUSDC_WMON_MARKET);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(10_000e6, address(this), cUSDC_WBTC_MARKET);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(10_000e6, address(this), cUSDC_WETH_MARKET);

        _mockIsBad(_singleBadMarket(cUSDC_WMON_MARKET));

        (LendingOptimizer.ReallocationAction[] memory actions,
         LendingOptimizer.AllocationBound[] memory bounds) =
            reader.optimalRebalance(address(optimizer), 500);

        // Should succeed — reader-computed bounds match the actions.
        _rebalance(optimizer, actions, bounds);
    }

    // ============ Multiple Bad Markets ============

    function test_optimalRebalance_defensive_success_twoBadMarketsFullyWithdrawn() public {
        _setUpUnconstrainedOptimizer();
        _depositToAllMarketsUnconstrained(50_000e6);

        // Mark markets 0 and 2 as bad.
        address[] memory bad = new address[](2);
        bad[0] = cUSDC_WMON_MARKET;
        bad[1] = cUSDC_WETH_MARKET;
        _mockIsBad(bad);

        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500);

        // Both bad markets should have negative actions.
        assertLt(actions[0].assetsOrBps, 0, "Bad market 0 should withdraw");
        assertLt(actions[2].assetsOrBps, 0, "Bad market 2 should withdraw");

        // Good market 1 should receive deposits.
        assertGt(actions[1].assetsOrBps, 0, "Good market should receive deposits");
    }

    function test_optimalRebalance_defensive_success_twoBadMarketsExecutable() public {
        _setUpUnconstrainedOptimizer();
        _depositToAllMarketsUnconstrained(50_000e6);

        address[] memory bad = new address[](2);
        bad[0] = cUSDC_WMON_MARKET;
        bad[1] = cUSDC_WETH_MARKET;
        _mockIsBad(bad);

        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500);

        uint256 totalAssetsBefore = optimizer.totalAssets();
        _rebalance(optimizer, actions, _unconstrainedBounds());
        uint256 totalAssetsAfter = optimizer.totalAssets();

        assertApproxEqAbs(
            totalAssetsAfter,
            totalAssetsBefore,
            actions.length * 2,
            "Total assets should be preserved"
        );

        // Both bad markets should be empty.
        assertLe(
            IBorrowableCToken(cUSDC_WMON_MARKET).convertToAssets(
                IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer))
            ),
            1,
            "Bad market 0 should be empty"
        );
        assertLe(
            IBorrowableCToken(cUSDC_WETH_MARKET).convertToAssets(
                IBorrowableCToken(cUSDC_WETH_MARKET).balanceOf(address(optimizer))
            ),
            1,
            "Bad market 2 should be empty"
        );
    }

    // ============ Concentrated Allocation + Bad Market ============

    function test_optimalRebalance_defensive_success_concentratedInBadMarket() public {
        _setUpUnconstrainedOptimizer();

        // Concentrate everything in market 0, then mark it bad.
        deal(USDC_MONAD, address(this), 500_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 500_000e6);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(500_000e6, address(this), cUSDC_WMON_MARKET);

        _mockIsBad(_singleBadMarket(cUSDC_WMON_MARKET));

        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500);

        // Market 0 should fully withdraw.
        assertLt(actions[0].assetsOrBps, 0, "Concentrated bad market should withdraw");

        // Other markets should receive deposits.
        uint256 totalDeposits;
        for (uint256 i = 1; i < actions.length; ++i) {
            if (actions[i].assetsOrBps > 0) {
                totalDeposits += uint256(actions[i].assetsOrBps);
            }
        }
        assertGt(totalDeposits, 0, "Good markets should receive redistributed assets");
    }

    function test_optimalRebalance_defensive_success_concentratedInBadMarketExecutable() public {
        _setUpUnconstrainedOptimizer();

        deal(USDC_MONAD, address(this), 500_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 500_000e6);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(500_000e6, address(this), cUSDC_WMON_MARKET);

        _mockIsBad(_singleBadMarket(cUSDC_WMON_MARKET));

        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500);

        _rebalance(optimizer, actions, _unconstrainedBounds());

        // Bad market should be empty.
        assertLe(
            IBorrowableCToken(cUSDC_WMON_MARKET).convertToAssets(
                IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer))
            ),
            1,
            "Concentrated bad market should be empty after rebalance"
        );
    }

    // ============ Full Round-Trip ============

    function test_optimalRebalance_defensive_success_fullRoundTrip() public {
        _setUpUnconstrainedOptimizer();
        _depositToAllMarketsUnconstrained(100_000e6);

        uint256 sharesBefore = optimizer.balanceOf(address(this));

        // Defensive rebalance with market 2 bad.
        _mockIsBad(_singleBadMarket(cUSDC_WETH_MARKET));

        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500);

        _rebalance(optimizer, actions, _unconstrainedBounds());

        // Shares unchanged (rebalance doesn't mint/burn).
        assertEq(
            optimizer.balanceOf(address(this)),
            sharesBefore,
            "Shares should be unchanged after rebalance"
        );

        // User can still redeem.
        uint256 redeemShares = sharesBefore / 2;
        uint256 redeemed = optimizer.redeem(redeemShares, address(this), address(this));
        assertGt(redeemed, 0, "Should be able to redeem after defensive rebalance");
    }

    // ============ Bounds Well-Formed ============

    function test_optimalRebalance_defensive_success_boundsAreWellFormed() public {
        _setUpThreeMarkets();
        _depositToAllMarkets(10_000e6);

        _mockIsBad(_singleBadMarket(cUSDC_WETH_MARKET));

        (, LendingOptimizer.AllocationBound[] memory bounds) =
            reader.optimalRebalance(address(optimizer), 200);

        for (uint256 i; i < bounds.length; ++i) {
            assertLe(bounds[i].minBps, bounds[i].maxBps, "minBps > maxBps");
            assertLe(bounds[i].maxBps, 10000, "maxBps exceeds 100%");
        }
    }

    // ============ Fuzz Tests ============

    function testFuzz_optimalRebalance_defensive_capsRespected(
        uint256 m0Deposit,
        uint256 m1Deposit,
        uint256 m2Deposit,
        uint256 badIndex
    ) public {
        _setUpUnconstrainedOptimizer();

        m0Deposit = bound(m0Deposit, 1e6, 500_000e6);
        m1Deposit = bound(m1Deposit, 1e6, 500_000e6);
        m2Deposit = bound(m2Deposit, 1e6, 500_000e6);
        badIndex = bound(badIndex, 0, 2);

        deal(USDC_MONAD, address(this), m0Deposit);
        IERC20(USDC_MONAD).approve(address(optimizer), m0Deposit);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(m0Deposit, address(this), cUSDC_WMON_MARKET);

        deal(USDC_MONAD, address(this), m1Deposit);
        IERC20(USDC_MONAD).approve(address(optimizer), m1Deposit);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(m1Deposit, address(this), cUSDC_WBTC_MARKET);

        deal(USDC_MONAD, address(this), m2Deposit);
        IERC20(USDC_MONAD).approve(address(optimizer), m2Deposit);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(m2Deposit, address(this), cUSDC_WETH_MARKET);

        address badMarket;
        if (badIndex == 0) badMarket = cUSDC_WMON_MARKET;
        else if (badIndex == 1) badMarket = cUSDC_WBTC_MARKET;
        else badMarket = cUSDC_WETH_MARKET;

        _mockIsBad(_singleBadMarket(badMarket));

        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500);

        uint256 ta = optimizer.totalAssets();

        for (uint256 i; i < actions.length; ++i) {
            IBorrowableCToken ct = actions[i].cToken;
            uint256 current = ct.convertToAssets(ct.balanceOf(address(optimizer)));
            uint256 ideal;
            if (actions[i].assetsOrBps > 0) {
                ideal = current + uint256(actions[i].assetsOrBps);
            } else if (actions[i].assetsOrBps < 0) {
                ideal = current - uint256(-actions[i].assetsOrBps);
            } else {
                ideal = current;
            }
            uint256 cap = optimizer.allocationCaps(address(actions[i].cToken));
            uint256 maxAllowed = FixedPointMathLib.mulDiv(ta, cap, WAD);

            assertLe(
                ideal,
                maxAllowed + 1,
                string.concat("Market ", vm.toString(i), " ideal exceeds cap")
            );
        }
    }

    function testFuzz_optimalRebalance_defensive_badMarketWithdrawn(
        uint256 depositAmount,
        uint256 badIndex
    ) public {
        _setUpUnconstrainedOptimizer();

        depositAmount = bound(depositAmount, 10_000e6, 200_000e6);
        badIndex = bound(badIndex, 0, 2);

        // Deposit evenly.
        for (uint256 i; i < 3; ++i) {
            address market;
            if (i == 0) market = cUSDC_WMON_MARKET;
            else if (i == 1) market = cUSDC_WBTC_MARKET;
            else market = cUSDC_WETH_MARKET;

            deal(USDC_MONAD, address(this), depositAmount);
            IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
            LendingOptimizerHarness(address(optimizer)).depositToMarket(depositAmount, address(this), market);
        }

        address badMarket;
        if (badIndex == 0) badMarket = cUSDC_WMON_MARKET;
        else if (badIndex == 1) badMarket = cUSDC_WBTC_MARKET;
        else badMarket = cUSDC_WETH_MARKET;

        _mockIsBad(_singleBadMarket(badMarket));

        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500);

        // The bad market should have a negative (withdrawal) action.
        assertLt(
            actions[badIndex].assetsOrBps,
            0,
            "Bad market should have negative action"
        );
    }

    // ============ Helpers ============

    function _noBadMarkets() internal pure returns (address[] memory) {
        return new address[](0);
    }

    function _singleBadMarket(address market) internal pure returns (address[] memory bad) {
        bad = new address[](1);
        bad[0] = market;
    }

    /// @dev Mocks the external isBad() call that defensiveRebalance makes on itself.
    function _mockIsBad(address[] memory badMarkets) internal {
        vm.mockCall(
            address(reader),
            abi.encodeWithSelector(OptimizerReader.isBad.selector, address(optimizer)),
            abi.encode(badMarkets)
        );
    }

    /// @dev Sets up 3 markets with 100% caps and harvest permissions.
    function _setUpUnconstrainedOptimizer() internal {
        address[] memory approvedCTokens = new address[](3);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;
        approvedCTokens[2] = cUSDC_WETH_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](3);
        allocationCapsBps[0] = 10_000;
        allocationCapsBps[1] = 10_000;
        allocationCapsBps[2] = 10_000;

        optimizer = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            0
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets);
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
        optimizer.initializeDeposits(cUSDC_WMON_MARKET);

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(
                ICentralRegistry.hasHarvestPermissions.selector,
                address(this)
            ),
            abi.encode(true)
        );
    }

    /// @dev Deposits the same amount into each of the 3 markets (unconstrained setup).
    function _depositToAllMarketsUnconstrained(uint256 amountPerMarket) internal {
        address[3] memory markets = [cUSDC_WMON_MARKET, cUSDC_WBTC_MARKET, cUSDC_WETH_MARKET];

        for (uint256 i = 0; i < 3; i++) {
            deal(USDC_MONAD, address(this), amountPerMarket);
            IERC20(USDC_MONAD).approve(address(optimizer), amountPerMarket);
            LendingOptimizerHarness(address(optimizer)).depositToMarket(
                amountPerMarket, address(this), markets[i]
            );
        }
    }
}
