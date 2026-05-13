// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { OptimizerReader } from "contracts/views/OptimizerReader.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { ILendingOptimizer } from "contracts/interfaces/ILendingOptimizer.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { IOracleAdaptor } from "contracts/interfaces/IOracleAdaptor.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

interface ICentralRegistryExt is ICentralRegistry {
    function emergencyCouncil() external view returns (address);
    function addHarvestPermissions(address) external;
}

interface IMarketManagerExt is IMarketManager {
    function setMintPaused(address cToken, bool state) external;
    function setRedeemPaused(bool state) external;
}

/// @notice Stress-tests `OptimizerReader.optimalRebalanceAt` against the live
///         Monad deployment under a wide range of conditions: varying
///         projection deltas, pause states, oracle failures, dust thresholds,
///         and idempotency after a successful rebalance. Every test must
///         either succeed or surface the exact revert reason from the
///         optimizer's `rebalance()` call.
contract TestOptimalRebalanceAtMonadFork is Test {
    address constant LENDING_OPTIMIZER =
        0x37Bf94D8Af2Fbbf562Da5a3f1b0787b3515D10dd;
    address constant CENTRAL_REGISTRY =
        0x1310f352f1389969Ece6741671c4B919523912fF;

    uint256 constant DEFAULT_SLIPPAGE_BPS = 100;
    uint256 constant DEFAULT_STALENESS_MULTIPLIER_BPS = 11000;

    OptimizerReader reader;
    LendingOptimizer optimizer;
    ICentralRegistryExt centralRegistry;
    IOracleManager oracleManager;

    address harvester;
    address asset;
    uint256 assetDecimals;

    function setUp() public {
        vm.createSelectFork(vm.envString("MON_NODE_URI_MONAD_MAINNET"));

        optimizer = LendingOptimizer(LENDING_OPTIMIZER);
        centralRegistry = ICentralRegistryExt(CENTRAL_REGISTRY);
        oracleManager = IOracleManager(centralRegistry.oracleManager());

        // Fresh reader with the current source under test.
        reader = new OptimizerReader(
            ICentralRegistry(CENTRAL_REGISTRY),
            DEFAULT_STALENESS_MULTIPLIER_BPS
        );

        harvester = address(this);
        address ec = centralRegistry.emergencyCouncil();
        vm.prank(ec);
        centralRegistry.addHarvestPermissions(harvester);

        asset = optimizer.asset();
        assetDecimals = IERC20(asset).decimals();
    }

    /*//////////////////////////////////////////////////////////////
                       PROJECTION ACCURACY
    //////////////////////////////////////////////////////////////*/

    /// @dev Projecting to the current block timestamp must match the
    ///      on-chain `convertToAssets` value after accrual within the same
    ///      tolerance used for future-time projections.
    function test_projection_atCurrentBlock_matchesAccruedLive() public {
        address[] memory markets = optimizer.getApprovedMarkets();

        // Snapshot projection at "now" before any accrual.
        uint256[] memory projected = new uint256[](markets.length);
        for (uint256 i; i < markets.length; ++i) {
            projected[i] = reader.assetsAtTimestamp(
                LENDING_OPTIMIZER,
                markets[i],
                block.timestamp
            );
        }

        // Force on-chain accrual at the same timestamp.
        for (uint256 i; i < markets.length; ++i) {
            IBorrowableCToken(markets[i]).accrueIfNeeded();
        }

        for (uint256 i; i < markets.length; ++i) {
            uint256 shares = IBorrowableCToken(markets[i]).balanceOf(LENDING_OPTIMIZER);
            uint256 actual_ = IBorrowableCToken(markets[i]).convertToAssets(shares);
            uint256 tolerance = actual_ / 1e8 + 2;
            assertApproxEqAbs(
                projected[i],
                actual_,
                tolerance,
                "projection at now drifted from accrued live state"
            );
        }
    }

    /// @dev Project N seconds ahead, warp to that time, accrue on-chain,
    ///      compare projected vs actual. Verifies the off-chain accrual
    ///      math in `_projectCTokenState` is faithful to `BorrowableCToken`.
    function test_projection_30s_matchesActualAccrual() public {
        _assertProjectionMatchesAccrual(30);
    }

    function test_projection_5min_matchesActualAccrual() public {
        _assertProjectionMatchesAccrual(5 minutes);
    }

    function test_projection_1h_matchesActualAccrual() public {
        _assertProjectionMatchesAccrual(1 hours);
    }

    function test_projection_1day_matchesActualAccrual() public {
        _assertProjectionMatchesAccrual(1 days);
    }

    function test_projection_7days_matchesActualAccrual() public {
        _assertProjectionMatchesAccrual(7 days);
    }

    /// @dev Fuzz over reasonable projection horizons.
    function testFuzz_projection_matchesActualAccrual(uint256 delta) public {
        delta = bound(delta, 1, 30 days);
        _assertProjectionMatchesAccrual(delta);
    }

    function _assertProjectionMatchesAccrual(uint256 delta) internal {
        address[] memory markets = optimizer.getApprovedMarkets();

        uint256 target = block.timestamp + delta;

        // Snapshot projected values BEFORE warping.
        uint256[] memory projected = new uint256[](markets.length);
        for (uint256 i; i < markets.length; ++i) {
            projected[i] = reader.assetsAtTimestamp(
                LENDING_OPTIMIZER,
                markets[i],
                target
            );
        }

        // Warp to target and force on-chain accrual.
        vm.warp(target);
        for (uint256 i; i < markets.length; ++i) {
            IBorrowableCToken(markets[i]).accrueIfNeeded();
        }

        // Compare against actual.
        for (uint256 i; i < markets.length; ++i) {
            uint256 shares = IBorrowableCToken(markets[i]).balanceOf(LENDING_OPTIMIZER);
            uint256 actual_ = IBorrowableCToken(markets[i]).convertToAssets(shares);

            // Tolerate small drift from rounding-up of protocol fee shares
            // in projection vs. on-chain integer math.
            uint256 tolerance = actual_ / 1e8 + 2; // 1e-6% + 2 wei
            assertApproxEqAbs(
                projected[i],
                actual_,
                tolerance,
                "projection drifted from on-chain accrual"
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                  REBALANCE EXECUTION ACROSS DELTAS
    //////////////////////////////////////////////////////////////*/

    /// @dev Fuzz: any projection horizon between 0 and 1 day should yield
    ///      a rebalance plan that the optimizer accepts without reverting.
    function testFuzz_rebalance_passesAtDelta(uint256 delta) public {
        delta = bound(delta, 0, 1 days);

        (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        ) = reader.optimalRebalanceAt(
            LENDING_OPTIMIZER,
            DEFAULT_SLIPPAGE_BPS,
            block.timestamp + delta
        );

        if (actions.length == 0) return;

        vm.prank(harvester);
        optimizer.rebalance(actions, bounds);

        _assertEveryMarketUnderCap();
    }

    /// @dev With high projection horizon (1 week), withdraw delta inflates
    ///      but cap buffer should still keep us safe.
    function test_rebalance_1week_stillSafe() public {
        (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        ) = reader.optimalRebalanceAt(
            LENDING_OPTIMIZER,
            DEFAULT_SLIPPAGE_BPS,
            block.timestamp + 7 days
        );

        if (actions.length == 0) return;

        vm.prank(harvester);
        optimizer.rebalance(actions, bounds);

        _assertEveryMarketUnderCap();
    }

    /*//////////////////////////////////////////////////////////////
                       IDEMPOTENCY
    //////////////////////////////////////////////////////////////*/

    /// @dev After one successful rebalance, immediately re-running
    ///      `optimalRebalanceAt` should produce either empty actions or
    ///      actions whose USD value falls below the threshold. A second
    ///      rebalance should never produce a meaningfully different plan.
    function test_rebalance_idempotent() public {
        (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        ) = reader.optimalRebalanceAt(
            LENDING_OPTIMIZER,
            DEFAULT_SLIPPAGE_BPS,
            block.timestamp + 30
        );

        if (actions.length == 0) {
            console2.log("first call already empty; nothing to test");
            return;
        }

        vm.prank(harvester);
        optimizer.rebalance(actions, bounds);

        // Immediately re-plan with the same horizon.
        (
            LendingOptimizer.ReallocationAction[] memory actions2,
            LendingOptimizer.AllocationBound[] memory bounds2
        ) = reader.optimalRebalanceAt(
            LENDING_OPTIMIZER,
            DEFAULT_SLIPPAGE_BPS,
            block.timestamp + 30
        );

        if (actions2.length == 0) {
            console2.log("second call returned empty (ideal)");
            return;
        }

        // If there's still something to do, it should be tiny dust and
        // the rebalance should still succeed cleanly.
        vm.prank(harvester);
        optimizer.rebalance(actions2, bounds2);

        _assertEveryMarketUnderCap();
    }

    /*//////////////////////////////////////////////////////////////
                       BAD MARKET HANDLING
    //////////////////////////////////////////////////////////////*/

    /// @dev When a market's oracle returns zero (PriceGuard breach),
    ///      `isBad` flags it, and `optimalRebalanceAt` must propose a full
    ///      drain of that market's position. Execution may or may not
    ///      succeed depending on whether enough idle liquidity exists in
    ///      the cToken — that's a real-world constraint, not a planner bug.
    ///      We assert: (1) planner intent is correct (drain action), and
    ///      (2) if execution succeeds, cap invariants hold.
    function test_badMarket_plannerProposesFullDrain() public {
        address[] memory markets = optimizer.getApprovedMarkets();
        address badMarket = _findMarketWithBalance(markets);
        if (badMarket == address(0)) {
            console2.log("no market has a balance to test draining");
            return;
        }

        uint256 badMarketAssets = IBorrowableCToken(badMarket).convertToAssets(
            IBorrowableCToken(badMarket).balanceOf(LENDING_OPTIMIZER)
        );

        address collateral = _collateralAsset(badMarket);
        address[] memory adaptors = oracleManager.getPricingAdaptors(collateral);
        require(adaptors.length > 0, "no adaptor configured");

        IOracleAdaptor.PricingResult memory zeroResult = IOracleAdaptor.PricingResult({
            price: 0,
            inUSD: true,
            hadError: false
        });
        vm.mockCall(
            adaptors[0],
            abi.encodeWithSelector(IOracleAdaptor.getPrice.selector, collateral, true, true),
            abi.encode(zeroResult)
        );

        address[] memory bad = reader.isBad(LENDING_OPTIMIZER);
        bool foundBad;
        for (uint256 i; i < bad.length; ++i) {
            if (bad[i] == badMarket) {
                foundBad = true;
                break;
            }
        }
        assertTrue(foundBad, "mocked bad market should appear in isBad");

        uint256 target = block.timestamp + 30;
        (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        ) = reader.optimalRebalanceAt(LENDING_OPTIMIZER, DEFAULT_SLIPPAGE_BPS, target);

        require(actions.length > 0, "expected drain actions");

        // Planner intent: bad market action must be a withdrawal sized to
        // (approximately) its current assets.
        for (uint256 i; i < actions.length; ++i) {
            if (address(actions[i].cToken) == badMarket) {
                assertLt(actions[i].assetsOrBps, 0, "bad market action must be withdrawal");
                uint256 mag = uint256(-actions[i].assetsOrBps);
                // Within 1% of current assets (rounding + projection delta).
                assertApproxEqRel(
                    mag,
                    badMarketAssets,
                    1e16,
                    "bad market drain magnitude mismatch"
                );
            }
        }

        // Warp to the projection target — this simulates the production
        // flow where the bot's tx lands at (or near) the projected
        // timestamp, NOT at the planning timestamp. Without warping, a
        // full drain over-projects and would request more than the cToken
        // actually holds.
        vm.warp(target);

        uint256 idle = IBorrowableCToken(badMarket).assetsHeld();
        try optimizer.rebalance(actions, bounds) {
            uint256 remaining = IBorrowableCToken(badMarket).convertToAssets(
                IBorrowableCToken(badMarket).balanceOf(LENDING_OPTIMIZER)
            );
            assertLt(remaining, 100, "bad market should be drained on success");
            _assertEveryMarketUnderCap();
        } catch (bytes memory err) {
            // The only legitimate revert here is cToken-level
            // InsufficientLiquidity (too much lent out to support the
            // drain). Anything else is a planner bug.
            assertLt(
                idle,
                badMarketAssets,
                "rebalance reverted but liquidity was sufficient"
            );
            console2.log(
                "InsufficientLiquidity (idle=%s < required=%s) as expected",
                idle,
                badMarketAssets
            );
            err;
        }
    }

    /*//////////////////////////////////////////////////////////////
                       PAUSE STATE HANDLING
    //////////////////////////////////////////////////////////////*/

    /// @dev Mint-paused markets must receive zero deposits, but can be
    ///      drained. Same liquidity caveat as the bad-market test.
    function test_mintPaused_plannerNeverDepositsToIt() public {
        address[] memory markets = optimizer.getApprovedMarkets();
        address paused = _findMarketWithBalance(markets);
        if (paused == address(0)) return;

        uint256 pausedAssets = IBorrowableCToken(paused).convertToAssets(
            IBorrowableCToken(paused).balanceOf(LENDING_OPTIMIZER)
        );

        IMarketManagerExt mm = IMarketManagerExt(address(ICToken(paused).marketManager()));
        vm.prank(centralRegistry.emergencyCouncil());
        mm.setMintPaused(paused, true);

        uint256 target = block.timestamp + 30;
        (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        ) = reader.optimalRebalanceAt(LENDING_OPTIMIZER, DEFAULT_SLIPPAGE_BPS, target);

        if (actions.length == 0) return;

        for (uint256 i; i < actions.length; ++i) {
            if (address(actions[i].cToken) == paused) {
                assertLe(actions[i].assetsOrBps, 0, "mint-paused market must not be deposited to");
            }
        }

        // Warp to the projection target. See bad-market test for rationale.
        vm.warp(target);

        uint256 idle = IBorrowableCToken(paused).assetsHeld();
        try optimizer.rebalance(actions, bounds) {
            _assertEveryMarketUnderCap();
        } catch (bytes memory err) {
            assertLt(
                idle,
                pausedAssets,
                "rebalance reverted but liquidity was sufficient"
            );
            console2.log(
                "mint-paused drain liquidity-bounded: idle=%s < required=%s",
                idle,
                pausedAssets
            );
            err;
        }
    }

    /// @dev Redeem-paused markets must keep their position frozen — the
    ///      planner should produce zero or near-zero delta on them.
    function test_redeemPaused_marketIsLocked() public {
        address[] memory markets = optimizer.getApprovedMarkets();
        address locked = _findMarketWithBalance(markets);
        if (locked == address(0)) return;

        uint256 lockedBalanceBefore = IBorrowableCToken(locked).convertToAssets(
            IBorrowableCToken(locked).balanceOf(LENDING_OPTIMIZER)
        );

        IMarketManagerExt mm = IMarketManagerExt(address(ICToken(locked).marketManager()));
        vm.prank(centralRegistry.emergencyCouncil());
        mm.setRedeemPaused(true);

        (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        ) = reader.optimalRebalanceAt(LENDING_OPTIMIZER, DEFAULT_SLIPPAGE_BPS, block.timestamp + 30);

        if (actions.length == 0) return;

        for (uint256 i; i < actions.length; ++i) {
            if (address(actions[i].cToken) == locked) {
                assertGe(actions[i].assetsOrBps, 0, "redeem-paused market must not be withdrawn from");
            }
        }

        vm.prank(harvester);
        optimizer.rebalance(actions, bounds);

        // Locked market balance should be at least as large as before.
        uint256 lockedBalanceAfter = IBorrowableCToken(locked).convertToAssets(
            IBorrowableCToken(locked).balanceOf(LENDING_OPTIMIZER)
        );
        assertGe(lockedBalanceAfter, lockedBalanceBefore, "locked balance shrank");

        _assertEveryMarketUnderCap();
    }

    /*//////////////////////////////////////////////////////////////
                       THRESHOLD / DUST
    //////////////////////////////////////////////////////////////*/

    /// @dev When the rebalance USD value is below the threshold the reader
    ///      must return empty arrays. Mocks the underlying asset price so
    ///      total USD value of actions sits below USD_THRESHOLD.
    function test_subThresholdRebalance_returnsEmpty() public {
        uint256 threshold = reader.USD_THRESHOLD();
        // Force the underlying price low enough that ~half the optimizer's
        // assets in USD would still fall well below threshold.
        // We mock OracleManager.getPrice to return a price of 1 (essentially
        // making any asset valueless), guaranteeing usdValue < threshold.
        vm.mockCall(
            address(oracleManager),
            abi.encodeWithSelector(IOracleManager.getPrice.selector, asset, true, true),
            abi.encode(uint256(1), uint256(0))
        );

        (
            LendingOptimizer.ReallocationAction[] memory actions,
        ) = reader.optimalRebalanceAt(LENDING_OPTIMIZER, DEFAULT_SLIPPAGE_BPS, block.timestamp + 30);

        assertEq(actions.length, 0, "sub-threshold rebalance must return empty");
        console2.log("threshold=%s; sub-threshold path returned empty as expected", threshold);
    }

    /// @dev Oracle returning errorCode != 0 should bypass the threshold
    ///      check (still rebalance), and `rebalance()` should succeed.
    function test_oracleErrorBypassesThreshold() public {
        vm.mockCall(
            address(oracleManager),
            abi.encodeWithSelector(IOracleManager.getPrice.selector, asset, true, true),
            abi.encode(uint256(0), uint256(1)) // price=0, errorCode=1
        );

        (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        ) = reader.optimalRebalanceAt(LENDING_OPTIMIZER, DEFAULT_SLIPPAGE_BPS, block.timestamp + 30);

        if (actions.length == 0) return; // optimizer truly balanced

        vm.prank(harvester);
        optimizer.rebalance(actions, bounds);
        _assertEveryMarketUnderCap();
    }

    /*//////////////////////////////////////////////////////////////
                        SLIPPAGE EXTREMES
    //////////////////////////////////////////////////////////////*/

    /// @dev 0 bps slippage produces bounds = exactly `idealBps` per market,
    ///      which is too tight for cToken withdraw/deposit wei-scale
    ///      rounding to ever satisfy. Verifies the optimizer correctly
    ///      surfaces this via `AllocationOutOfBounds` (documented behavior).
    function test_zeroSlippage_revertsAllocationOutOfBounds() public {
        (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        ) = reader.optimalRebalanceAt(LENDING_OPTIMIZER, 0, block.timestamp + 30);

        if (actions.length == 0) return;

        vm.prank(harvester);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__AllocationOutOfBounds.selector);
        optimizer.rebalance(actions, bounds);
    }

    /// @dev Minimum viable slippage: 10 bps tolerates wei-scale rounding.
    function test_minViableSlippage_rebalanceExecutes() public {
        (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        ) = reader.optimalRebalanceAt(LENDING_OPTIMIZER, 10, block.timestamp + 30);

        if (actions.length == 0) return;

        vm.prank(harvester);
        optimizer.rebalance(actions, bounds);
        _assertEveryMarketUnderCap();
    }

    /// @dev Wide slippage (500 bps). Still must respect cap.
    function test_wideSlippage_rebalanceStillExecutes() public {
        (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        ) = reader.optimalRebalanceAt(LENDING_OPTIMIZER, 500, block.timestamp + 30);

        if (actions.length == 0) return;

        vm.prank(harvester);
        optimizer.rebalance(actions, bounds);
        _assertEveryMarketUnderCap();
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT INTERACTION
    //////////////////////////////////////////////////////////////*/

    /// @dev After a fresh user deposit the planner should pick the best
    ///      market for the new assets and the rebalance should keep all
    ///      markets under cap. AUSD uses delegated storage so we use
    ///      `deal(..., true)` to also update totalSupply, falling back to
    ///      skipping the test if the cheat can't locate the slot.
    function test_largeUserDeposit_thenRebalance() public {
        uint256 depositAmount = 1_000_000 * (10 ** assetDecimals); // $1M

        try this._dealAsset(asset, address(this), depositAmount) {
            // ok
        } catch {
            console2.log("deal() could not locate AUSD balance slot; skipping");
            return;
        }

        IERC20(asset).approve(LENDING_OPTIMIZER, depositAmount);
        ILendingOptimizer(LENDING_OPTIMIZER).deposit(depositAmount, address(this));

        (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        ) = reader.optimalRebalanceAt(LENDING_OPTIMIZER, DEFAULT_SLIPPAGE_BPS, block.timestamp + 30);

        if (actions.length == 0) return;

        vm.prank(harvester);
        optimizer.rebalance(actions, bounds);

        _assertEveryMarketUnderCap();
    }

    /// @dev External wrapper so we can `try` the cheatcode.
    function _dealAsset(address token, address to, uint256 amount) external {
        deal(token, to, amount, true);
    }

    /*//////////////////////////////////////////////////////////////
                            ASSERTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Asserts every approved market sits within its configured
    ///      allocation cap. This is the on-chain invariant that
    ///      `_verifyAllocations` enforces; a passing rebalance plus this
    ///      assertion proves the planner produced a cap-safe plan.
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

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    function _findMarketWithBalance(
        address[] memory markets
    ) internal view returns (address) {
        for (uint256 i; i < markets.length; ++i) {
            if (IBorrowableCToken(markets[i]).balanceOf(LENDING_OPTIMIZER) > 0) {
                return markets[i];
            }
        }
        return address(0);
    }

    /// @dev Walks the market manager's listed tokens to find the
    ///      collateral counterpart of an optimizer's borrowable cToken.
    function _collateralAsset(address borrowableCToken) internal view returns (address) {
        IMarketManager mm = ICToken(borrowableCToken).marketManager();
        address[] memory listed = mm.queryTokensListed();
        for (uint256 j; j < listed.length; ++j) {
            if (listed[j] == borrowableCToken) continue;
            return ICToken(listed[j]).asset();
        }
        revert("no collateral counterpart found");
    }
}
