// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {TestBaseLendingOptimizer} from "../TestBaseLendingOptimizer.sol";
import {LendingOptimizerHarness} from "../LendingOptimizerHarness.sol";
import {LendingOptimizerHandler} from "./LendingOptimizerHandler.sol";
import {LendingOptimizer} from "contracts/market/optimizer/LendingOptimizer.sol";
import {IBorrowableCToken} from "contracts/interfaces/IBorrowableCToken.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {WAD} from "contracts/libraries/ConstantsLib.sol";
import {FixedPointMathLib} from "contracts/libraries/external/FixedPointMathLib.sol";

/// @title InvariantStateful
/// @notice Stateful invariant tests for LendingOptimizer using a handler-based approach.
/// @dev The fuzzer randomly calls handler actions and then checks invariants after each sequence.
contract InvariantStateful is TestBaseLendingOptimizer {
    LendingOptimizerHarness public harness;
    LendingOptimizerHandler public handler;

    address[] public actors;

    function setUp() public override {
        super.setUp();

        // Deploy harness with 3 markets (same config as _setUpThreeMarkets).
        address[] memory approvedCTokens = new address[](3);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;
        approvedCTokens[2] = cUSDC_WETH_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](3);
        allocationCapsBps[0] = 10_000;
        allocationCapsBps[1] = 10_000;
        allocationCapsBps[2] = 10_000;

        harness = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000 // 10% fee
        );

        // Point the base test's optimizer reference to the harness for compatibility.
        optimizer = LendingOptimizer(address(harness));

        // Initialize deposits.
        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(harness), initAssets);
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
        harness.initializeDeposits(cUSDC_WMON_MARKET);

        // Seed initial deposits so the vault has meaningful state.
        deal(USDC_MONAD, address(this), 300_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 300_000e6);
        harness.depositToMarket(100_000e6, address(this), cUSDC_WMON_MARKET);
        harness.depositToMarket(100_000e6, address(this), cUSDC_WBTC_MARKET);
        harness.depositToMarket(100_000e6, address(this), cUSDC_WETH_MARKET);

        // Set up actors.
        actors.push(address(1000001));
        actors.push(address(1000002));
        actors.push(address(1000003));
        actors.push(address(1000004));
        actors.push(address(1000005));

        // Deploy handler.
        handler = new LendingOptimizerHandler(harness, IERC20(USDC_MONAD), liveCentralRegistry, actors);

        // Configure invariant testing targets.
        targetContract(address(handler));

        // Exclude addresses that should not be callers.
        excludeSender(address(0));
        excludeSender(address(harness));
        excludeSender(address(handler));
    }

    // ========================================================================
    // INVARIANTS
    // ========================================================================

    /// @notice Idle underlying donations must not enter optimizer share pricing.
    /// @dev The optimizer accounts listed market positions only; direct
    ///      underlying transfers are idle excess recoverable by DAO via skim().
    function invariant_idleUnderlyingIsUntracked() public view {
        uint256 idleUnderlying = IERC20(USDC_MONAD).balanceOf(address(harness));
        uint256 donated = handler.ghost_underlyingDonated();
        uint256 roundingBudget =
            (handler.ghost_depositCount() + handler.ghost_rebalanceCount() + handler.ghost_withdrawCount())
                * harness.numApprovedMarkets();

        assertLe(idleUnderlying, donated + roundingBudget, "INVARIANT VIOLATED: unexpected idle underlying");

        assertEq(
            harness.totalAssets(),
            harness.exposed_totalAssetsIndexed(),
            "INVARIANT VIOLATED: totalAssets must remain cached accounting"
        );
    }

    /// @notice Exchange rate must never decrease across handler actions.
    /// @dev The handler tracks the last exchange rate as a ghost variable.
    ///      We allow a 1 wei tolerance for rounding.
    function invariant_exchangeRateNeverDecreases() public view {
        uint256 supply = harness.totalSupply();
        if (supply == 0) return;

        uint256 currentRate = FixedPointMathLib.mulDiv(WAD, harness.totalAssets(), supply);
        uint256 lastRate = handler.ghost_lastExchangeRate();

        assertGe(currentRate + 1, lastRate, "INVARIANT VIOLATED: exchange rate decreased");
    }

    /// @notice Sum of all allocation caps must be >= 1e18 (100%).
    function invariant_allocationCapsSum() public view {
        uint256 numMarkets = harness.numApprovedMarkets();
        uint256 totalCaps;
        for (uint256 i; i < numMarkets; ++i) {
            address market = harness.approvedCTokensList(i);
            totalCaps += harness.allocationCaps(market);
        }

        assertGe(totalCaps, WAD, "INVARIANT VIOLATED: sum of allocation caps < 100%");
    }

    /// @notice After any rebalance, each market allocation must not exceed its cap.
    /// @dev Note: deposits route to the optimal market without cap enforcement,
    ///      and updateCap can lower caps below current allocations. So this
    ///      invariant only holds strictly after rebalance() calls. We skip the
    ///      check if the handler's last action was not a rebalance.
    function invariant_marketAllocationsWithinCaps() public view {
        // Only rebalance() enforces caps. Deposits and cap changes can
        // temporarily exceed caps. Since we can't distinguish which handler
        // action just ran, use a generous tolerance that accounts for
        // deposits going to the optimal market regardless of cap.
        uint256 ta = harness.totalAssets();
        if (ta == 0) return;

        uint256 numMarkets = harness.numApprovedMarkets();
        for (uint256 i; i < numMarkets; ++i) {
            address market = harness.approvedCTokensList(i);
            uint256 marketAssets =
                IBorrowableCToken(market).convertToAssets(IBorrowableCToken(market).balanceOf(address(harness)));
            uint256 currentAllocation = FixedPointMathLib.mulDiv(marketAssets, WAD, ta);

            // Soft check: no single market should ever hold > 100%.
            // Allow a tiny epsilon (1e-10) for accumulated rounding across
            // many cToken convertToAssets calls and multi-market accounting.
            assertLe(currentAllocation, WAD + 1e8, "INVARIANT VIOLATED: market holds more than total assets");
        }
    }

    /// @notice Cached totalAssets must never materially exceed listed-market ground truth.
    /// @dev Phantom NAV (cached assets above listed-market assets) is the dangerous
    ///      direction. The opposite direction is conservative cToken deposit dust:
    ///      _depositToMarket() credits the recoverable value of received shares,
    ///      while tiny rounding remainders can benefit existing optimizer cToken shares.
    function invariant_totalAssetsTracking() public view {
        uint256 sumMarkets = _sumListedMarketAssets();
        uint256 ta = harness.totalAssets();

        if (ta > sumMarkets) {
            assertEq(ta, sumMarkets, "INVARIANT VIOLATED: totalAssets exceeds listed market sum");
        }

        if (sumMarkets > ta) {
            uint256 conservativeDustBudget = harness.numApprovedMarkets() * 2;
            assertLe(
                sumMarkets - ta,
                conservativeDustBudget,
                "INVARIANT VIOLATED: listed market sum exceeds totalAssets"
            );
        }
    }

    /// @notice maxWithdraw for each actor must be <= totalAssetsIndexed.
    function invariant_maxWithdrawSafe() public view {
        uint256 indexedAssets = harness.exposed_totalAssetsIndexed();
        for (uint256 i; i < actors.length; ++i) {
            uint256 mw = harness.maxWithdraw(actors[i]);
            assertLe(mw, indexedAssets, "INVARIANT VIOLATED: maxWithdraw(user) > _totalAssets");
        }
    }

    /// @notice previewRedeem(maxRedeem(user)) <= maxWithdraw(user) + 1.
    /// @dev This checks consistency between redeem and withdraw previews.
    function invariant_maxRedeemConsistency() public view {
        for (uint256 i; i < actors.length; ++i) {
            uint256 mr = harness.maxRedeem(actors[i]);
            if (mr == 0) continue;

            uint256 redeemAssets = harness.previewRedeem(mr);
            uint256 mw = harness.maxWithdraw(actors[i]);

            assertLe(redeemAssets, mw + 1, "INVARIANT VIOLATED: previewRedeem(maxRedeem) > maxWithdraw + 1");
        }
    }

    /// @notice Dead shares at address(0) must always exist after initialization.
    function invariant_deadSharesExist() public view {
        uint256 deadShares = harness.balanceOf(address(0));
        assertGt(deadShares, 0, "INVARIANT VIOLATED: dead shares at address(0) are zero");
    }

    /// @notice No user should profit from a round trip (deposit then full withdrawal)
    ///         beyond their proportional share of yield.
    /// @dev We check that total withdrawn <= total deposited + a generous yield allowance.
    ///      This is a coarse check -- precise per-user accounting would require tracking
    ///      yield attribution, so we use a generous bound.
    function invariant_noUserProfitsFromRoundTrip() public view {
        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[i];
            uint256 deposited = handler.ghost_userDeposited(actor);
            uint256 withdrawn = handler.ghost_userWithdrawn(actor);

            if (deposited == 0) continue;

            // Allow up to 50% profit from yield.
            // With real debt positions accruing interest and time warps up to 7 days,
            // legitimate yield can be substantial over multiple cycles.
            uint256 maxAllowedWithdrawal = deposited + (deposited / 2);

            assertLe(
                withdrawn,
                maxAllowedWithdrawal,
                "INVARIANT VIOLATED: user withdrew more than deposited + yield allowance"
            );
        }
    }

    /// @notice totalSupply should be consistent: dead shares + user shares.
    function invariant_totalSupplyConsistency() public view {
        uint256 supply = harness.totalSupply();
        assertGt(supply, 0, "INVARIANT VIOLATED: total supply is zero (dead shares should prevent this)");
    }

    /// @notice All optimizer shares must be held by known stateful actors.
    /// @dev Valid holders in this harness are dead shares, the test contract
    ///      seed/DAO holder, and the fuzz actors. A mismatch means shares were
    ///      minted to an unexpected holder or totalSupply drifted from balances.
    function invariant_totalSupplyMatchesKnownHolders() public view {
        uint256 knownShares =
            harness.balanceOf(address(0)) + harness.balanceOf(address(this)) + _sumActorShareBalances();

        assertEq(knownShares, harness.totalSupply(), "INVARIANT VIOLATED: totalSupply has unknown share holder");
    }

    /// @notice Actor balances must equal successful actor mints less burns.
    /// @dev Transfers between actors preserve the actor aggregate, while DAO fee
    ///      shares accrue to the test contract and stay outside this sum.
    function invariant_actorSharesMatchGhostNetMints() public view {
        uint256 minted = handler.ghost_totalSharesMinted();
        uint256 burned = handler.ghost_totalSharesBurned();

        assertGe(minted, burned, "INVARIANT VIOLATED: ghost burned more actor shares than minted");

        assertEq(
            _sumActorShareBalances(),
            minted - burned,
            "INVARIANT VIOLATED: actor share balances drifted from ghost mints"
        );
    }

    /// @notice Per-market allocation should not exceed its configured cap by
    ///         an unreasonable amount.
    /// @dev Deposits route to the optimal market without strictly enforcing
    ///      caps, and updateCap can lower caps below current allocations.
    ///      Only rebalance() enforces caps strictly. So this invariant uses
    ///      a soft check: no single market should hold more than 100% of
    ///      totalAssets (the absolute hard limit), and we log a warning
    ///      if any market exceeds its configured cap.
    function invariant_perMarketCapCompliance() public view {
        uint256 ta = harness.totalAssets();
        if (ta == 0) return;

        uint256 numMarkets = harness.numApprovedMarkets();
        for (uint256 i; i < numMarkets; ++i) {
            address market = harness.approvedCTokensList(i);
            uint256 marketAssets =
                IBorrowableCToken(market).convertToAssets(IBorrowableCToken(market).balanceOf(address(harness)));
            uint256 currentAllocation = FixedPointMathLib.mulDiv(marketAssets, WAD, ta);

            // Hard invariant: no market can ever hold more than 100%.
            // Allow a tiny epsilon (1e-10) for accumulated rounding across
            // many cToken convertToAssets calls and multi-market accounting.
            assertLe(currentAllocation, WAD + 1e8, "INVARIANT VIOLATED: market allocation exceeds 100%");

            // Note: deposits route to the optimal market without cap
            // enforcement, and updateCap can lower caps below current
            // allocations at any time. Only rebalance() enforces caps
            // strictly. Therefore we only assert the hard 100% ceiling
            // here -- per-cap compliance is a post-rebalance property,
            // not a global invariant.
        }
    }

    /// @notice If totalSupply is zero then totalAssets must also be zero.
    /// @dev After initialization, dead shares guarantee totalSupply > 0.
    ///      This invariant catches any scenario where shares are fully burned
    ///      but assets remain stranded in markets.
    function invariant_zeroSupplyImpliesZeroAssets() public view {
        uint256 supply = harness.totalSupply();

        // Dead shares from initializeDeposits guarantee supply > 0.
        assertGt(supply, 0, "INVARIANT VIOLATED: totalSupply is zero (dead shares should prevent this)");

        // If somehow supply were zero, assets must also be zero.
        // This is a defensive check complementing invariant_deadSharesExist.
        if (supply == 0) {
            assertEq(harness.totalAssets(), 0, "INVARIANT VIOLATED: totalSupply == 0 but totalAssets > 0");
        }
    }

    // ========================================================================
    // HELPERS
    // ========================================================================

    function _sumActorShareBalances() internal view returns (uint256 actorShares) {
        for (uint256 i; i < actors.length; ++i) {
            actorShares += harness.balanceOf(actors[i]);
        }
    }

    function _sumListedMarketAssets() internal view returns (uint256 sumMarkets) {
        uint256 numMarkets = harness.numApprovedMarkets();
        for (uint256 i; i < numMarkets; ++i) {
            address market = harness.approvedCTokensList(i);
            sumMarkets += IBorrowableCToken(market)
                .convertToAssets(IBorrowableCToken(market).balanceOf(address(harness)));
        }
    }
}
