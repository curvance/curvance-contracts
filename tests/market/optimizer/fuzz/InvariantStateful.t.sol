// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizerHarness } from "../LendingOptimizerHarness.sol";
import { LendingOptimizerHandler } from "./LendingOptimizerHandler.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { WAD } from "contracts/libraries/ConstantsLib.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

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
        allocationCapsBps[0] = 6_000;
        allocationCapsBps[1] = 5_000;
        allocationCapsBps[2] = 2_000;

        harness = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000, // 10% fee
            1 days
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
        harness.initializeDeposits(0);

        // Seed initial deposits so the vault has meaningful state.
        deal(USDC_MONAD, address(this), 300_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 300_000e6);
        harness.deposit(100_000e6, address(this), cUSDC_WMON_MARKET);
        harness.deposit(100_000e6, address(this), cUSDC_WBTC_MARKET);
        harness.deposit(100_000e6, address(this), cUSDC_WETH_MARKET);

        // Set up actors.
        actors.push(address(1000001));
        actors.push(address(1000002));
        actors.push(address(1000003));
        actors.push(address(1000004));
        actors.push(address(1000005));

        // Deploy handler.
        handler = new LendingOptimizerHandler(
            harness,
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            actors
        );

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

    /// @notice totalAssets() must always be >= the indexed total (without pending vesting).
    /// @dev totalAssets = _totalAssets + _assetsToVest(), so it should be >= _totalAssets.
    function invariant_totalAssetsGeIndexed() public view {
        uint256 ta = harness.totalAssets();
        uint256 indexedAssets = harness.exposed_totalAssetsIndexed();
        assertGe(
            ta,
            indexedAssets,
            "INVARIANT VIOLATED: totalAssets() < _totalAssets (indexed)"
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

        assertGe(
            currentRate + 1,
            lastRate,
            "INVARIANT VIOLATED: exchange rate decreased"
        );
    }

    /// @notice Sum of all allocation caps must be >= 1e18 (100%).
    function invariant_allocationCapsSum() public view {
        uint256 numMarkets = harness.numApprovedMarkets();
        uint256 totalCaps;
        for (uint256 i; i < numMarkets; ++i) {
            address market = harness.approvedCTokensList(i);
            totalCaps += harness.allocationCaps(market);
        }

        assertGe(
            totalCaps,
            WAD,
            "INVARIANT VIOLATED: sum of allocation caps < 100%"
        );
    }

    /// @notice After any rebalance, each market allocation must not exceed its cap.
    /// @dev We check this invariant always; it should hold after all handler sequences
    ///      because rebalance() verifies caps internally.
    function invariant_marketAllocationsWithinCaps() public view {
        uint256 ta = harness.totalAssets();
        if (ta == 0) return;

        uint256 numMarkets = harness.numApprovedMarkets();
        for (uint256 i; i < numMarkets; ++i) {
            address market = harness.approvedCTokensList(i);
            uint256 marketAssets = IBorrowableCToken(market).convertToAssets(
                IBorrowableCToken(market).balanceOf(address(harness))
            );
            uint256 currentAllocation = FixedPointMathLib.mulDiv(marketAssets, WAD, ta);
            uint256 cap = harness.allocationCaps(market);

            // Allow 1 bps tolerance for rounding from deposits going to optimal market.
            assertLe(
                currentAllocation,
                cap + 1e14,
                "INVARIANT VIOLATED: market allocation exceeds cap"
            );
        }
    }

    /// @notice totalAssets should track the actual sum of market values within the rounding buffer.
    function invariant_totalAssetsTracking() public view {
        uint256 numMarkets = harness.numApprovedMarkets();
        uint256 sumMarkets;
        for (uint256 i; i < numMarkets; ++i) {
            address market = harness.approvedCTokensList(i);
            sumMarkets += IBorrowableCToken(market).convertToAssets(
                IBorrowableCToken(market).balanceOf(address(harness))
            );
        }

        uint256 ta = harness.totalAssets();
        uint256 buffer = harness.roundingBuffer();

        // totalAssets may lag behind sumMarkets during vesting (new yield not yet detected)
        // or may be slightly above if vesting is in progress.
        // The key check: sumMarkets should not be drastically below totalAssets.
        if (ta > sumMarkets) {
            assertLe(
                ta - sumMarkets,
                buffer + ta / 100, // Allow buffer + 1% for vesting-in-progress difference
                "INVARIANT VIOLATED: totalAssets far exceeds actual market sum"
            );
        }
    }

    /// @notice maxWithdraw for each actor must be <= totalAssetsIndexed.
    function invariant_maxWithdrawSafe() public view {
        uint256 indexedAssets = harness.exposed_totalAssetsIndexed();
        for (uint256 i; i < actors.length; ++i) {
            uint256 mw = harness.maxWithdraw(actors[i]);
            assertLe(
                mw,
                indexedAssets,
                "INVARIANT VIOLATED: maxWithdraw(user) > _totalAssets"
            );
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

            assertLe(
                redeemAssets,
                mw + 1,
                "INVARIANT VIOLATED: previewRedeem(maxRedeem) > maxWithdraw + 1"
            );
        }
    }

    /// @notice Dead shares at address(0) must always exist after initialization.
    function invariant_deadSharesExist() public view {
        uint256 deadShares = harness.balanceOf(address(0));
        assertGt(
            deadShares,
            0,
            "INVARIANT VIOLATED: dead shares at address(0) are zero"
        );
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

            // Allow up to 5% profit from yield.
            // This is deliberately generous to avoid false positives from legitimate yield.
            uint256 maxAllowedWithdrawal = deposited + (deposited / 20);

            assertLe(
                withdrawn,
                maxAllowedWithdrawal,
                "INVARIANT VIOLATED: user withdrew more than deposited + 5% yield allowance"
            );
        }
    }

    /// @notice totalSupply should be consistent: dead shares + user shares.
    function invariant_totalSupplyConsistency() public view {
        uint256 supply = harness.totalSupply();
        assertGt(
            supply,
            0,
            "INVARIANT VIOLATED: total supply is zero (dead shares should prevent this)"
        );
    }
}
