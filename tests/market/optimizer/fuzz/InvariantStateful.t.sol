// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {TestBaseLendingOptimizer} from "../TestBaseLendingOptimizer.sol";
import {LendingOptimizerHarness} from "../LendingOptimizerHarness.sol";
import {LendingOptimizerHandler} from "./LendingOptimizerHandler.sol";
import {
    LendingOptimizer
} from "contracts/market/optimizer/LendingOptimizer.sol";
import {
    MarketManagerIsolated
} from "contracts/market/isolated/MarketManagerIsolated.sol";
import {IBorrowableCToken} from "contracts/interfaces/IBorrowableCToken.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {ICToken} from "contracts/interfaces/ICToken.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {WAD} from "contracts/libraries/ConstantsLib.sol";
import {
    FixedPointMathLib
} from "contracts/libraries/external/FixedPointMathLib.sol";

/// @title InvariantStateful
/// @notice Stateful invariant tests for LendingOptimizer using a handler-based approach.
/// @dev The fuzzer randomly calls handler actions and then checks invariants after each sequence.
contract InvariantStateful is TestBaseLendingOptimizer {
    LendingOptimizerHarness public harness;
    LendingOptimizerHandler public handler;

    address[] public actors;

    function setUp() public override {
        super.setUp();

        // Deploy harness with two markets; the handler can add the third
        // known-good USDC market to exercise market-set mutation statefully.
        address[] memory approvedCTokens = new address[](2);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](2);
        allocationCapsBps[0] = 10_000;
        allocationCapsBps[1] = 10_000;

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
            abi.encodeWithSelector(
                ICentralRegistry.hasMarketPermissions.selector, address(this)
            ),
            abi.encode(true)
        );
        harness.initializeDeposits(cUSDC_WMON_MARKET);

        // Seed initial deposits so the vault has meaningful state.
        deal(USDC_MONAD, address(this), 300_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 300_000e6);
        harness.depositToMarket(100_000e6, address(this), cUSDC_WMON_MARKET);
        harness.depositToMarket(100_000e6, address(this), cUSDC_WBTC_MARKET);

        // Set up actors.
        actors.push(address(1000001));
        actors.push(address(1000002));
        actors.push(address(1000003));
        actors.push(address(1000004));
        actors.push(address(1000005));

        address[] memory candidateMarkets = new address[](3);
        candidateMarkets[0] = cUSDC_WMON_MARKET;
        candidateMarkets[1] = cUSDC_WBTC_MARKET;
        candidateMarkets[2] = cUSDC_WETH_MARKET;

        // Deploy handler.
        handler = new LendingOptimizerHandler(
            harness,
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            actors,
            candidateMarkets
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

    /// @notice Idle underlying donations must not enter optimizer share pricing.
    /// @dev The optimizer accounts listed market positions only; direct
    ///      underlying transfers are idle excess recoverable by DAO via skim().
    function invariant_idleUnderlyingIsUntracked() public view {
        assertEq(
            harness.totalAssets(),
            harness.exposed_totalAssetsIndexed(),
            "INVARIANT VIOLATED: totalAssets must remain cached accounting"
        );
        assertLe(
            harness.totalAssets(),
            _sumListedMarketAssets(),
            "INVARIANT VIOLATED: totalAssets exceeds listed market assets"
        );
    }

    /// @notice Exchange rate ghost must match the current cached accounting.
    function invariant_exchangeRateGhostMatchesAccounting() public view {
        uint256 supply = harness.totalSupply();
        if (supply == 0) return;

        uint256 currentRate =
            FixedPointMathLib.mulDiv(WAD, harness.totalAssets(), supply);
        uint256 lastRate = handler.ghost_lastExchangeRate();

        assertEq(
            currentRate,
            lastRate,
            "INVARIANT VIOLATED: exchange rate ghost drifted"
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
            totalCaps, WAD, "INVARIANT VIOLATED: sum of allocation caps < 100%"
        );
    }

    /// @notice Cached totalAssets must never exceed listed-market ground truth.
    /// @dev Every successful mutating path either syncs `_totalAssets` to the
    ///      listed markets or updates it by the recoverable cToken value; cToken
    ///      rounding can make the listed sum conservatively exceed cached assets.
    function invariant_totalAssetsTracking() public view {
        uint256 sumMarkets = _sumListedMarketAssets();
        uint256 ta = harness.totalAssets();

        assertLe(
            ta,
            sumMarkets,
            "INVARIANT VIOLATED: totalAssets exceeds listed market sum"
        );
    }

    /// @notice This harness keeps optimizer shares out of Curvance markets.
    function invariant_unlistedOptimizerNotRegisteredAsCurvanceMarketAsset()
        public
        view
    {
        assertEq(
            _oracleManager.cTokens(address(harness)),
            address(0),
            "INVARIANT VIOLATED: unlisted optimizer registered as cToken"
        );

        uint256 numMarkets = harness.numApprovedMarkets();
        for (uint256 i; i < numMarkets; ++i) {
            address market = harness.approvedCTokensList(i);
            MarketManagerIsolated mm =
                MarketManagerIsolated(_marketMgrs[market]);

            assertFalse(
                mm.isListed(address(harness)),
                "INVARIANT VIOLATED: optimizer token listed in approved market"
            );
        }
    }

    /// @notice Approved optimizer targets must remain valid Curvance markets.
    function invariant_approvedMarketsRemainValidCurvanceMarkets()
        public
        view
    {
        uint256 numMarkets = harness.numApprovedMarkets();
        for (uint256 i; i < numMarkets; ++i) {
            address market = harness.approvedCTokensList(i);
            address marketManager =
                address(IBorrowableCToken(market).marketManager());
            MarketManagerIsolated mm = MarketManagerIsolated(marketManager);

            assertEq(
                IBorrowableCToken(market).asset(),
                USDC_MONAD,
                "INVARIANT VIOLATED: approved market underlying drifted"
            );
            assertEq(
                _oracleManager.cTokens(market),
                USDC_MONAD,
                "INVARIANT VIOLATED: approved market oracle mapping drifted"
            );
            assertTrue(
                IBorrowableCToken(market).isBorrowable(),
                "INVARIANT VIOLATED: approved market not borrowable"
            );
            assertTrue(
                liveCentralRegistry.isMarketManager(marketManager),
                "INVARIANT VIOLATED: approved market manager not registered"
            );
            assertTrue(
                mm.isListed(market),
                "INVARIANT VIOLATED: approved market not listed"
            );

            _assertMarketDoesNotPairOptimizerShareAsset(mm, market);
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

    /// @notice previewRedeem(maxRedeem(user)) <= maxWithdraw(user).
    /// @dev This checks consistency between redeem and withdraw previews.
    function invariant_maxRedeemConsistency() public view {
        for (uint256 i; i < actors.length; ++i) {
            uint256 mr = harness.maxRedeem(actors[i]);
            if (mr == 0) continue;

            uint256 redeemAssets = harness.previewRedeem(mr);
            uint256 mw = harness.maxWithdraw(actors[i]);

            assertLe(
                redeemAssets,
                mw,
                "INVARIANT VIOLATED: previewRedeem(maxRedeem) > maxWithdraw"
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

    /// @notice initializeDeposits must stay one-shot after setUp initialization.
    function invariant_initializeDepositsIsOneShot() public view {
        assertFalse(
            handler.ghost_reinitialized(),
            "INVARIANT VIOLATED: initializeDeposits succeeded twice"
        );
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

    /// @notice All optimizer shares must be held by known stateful actors.
    /// @dev Valid holders in this harness are dead shares, the test contract
    ///      seed/DAO holder, and the fuzz actors. A mismatch means shares were
    ///      minted to an unexpected holder or totalSupply drifted from balances.
    function invariant_totalSupplyMatchesKnownHolders() public view {
        uint256 knownShares = harness.balanceOf(address(0))
            + harness.balanceOf(address(this)) + _sumActorShareBalances();

        assertEq(
            knownShares,
            harness.totalSupply(),
            "INVARIANT VIOLATED: totalSupply has unknown share holder"
        );
    }

    /// @notice Actor balances must equal successful actor mints less burns.
    /// @dev Transfers between actors preserve the actor aggregate, while DAO fee
    ///      shares accrue to the test contract and stay outside this sum.
    function invariant_actorSharesMatchGhostNetMints() public view {
        uint256 minted = handler.ghost_totalSharesMinted();
        uint256 burned = handler.ghost_totalSharesBurned();

        assertGe(
            minted,
            burned,
            "INVARIANT VIOLATED: ghost burned more actor shares than minted"
        );

        assertEq(
            _sumActorShareBalances(),
            minted - burned,
            "INVARIANT VIOLATED: actor share balances drifted from ghost mints"
        );
    }

    /// @notice Per-market balances must back the optimizer's tracked assets.
    function invariant_perMarketAccountingConsistency() public view {
        uint256 sumMarkets = _sumListedMarketAssets();
        if (sumMarkets == 0) return;

        uint256 numMarkets = harness.numApprovedMarkets();
        for (uint256 i; i < numMarkets; ++i) {
            address market = harness.approvedCTokensList(i);
            uint256 marketAssets = IBorrowableCToken(market)
                .convertToAssets(
                    IBorrowableCToken(market).balanceOf(address(harness))
                );
            assertLe(
                marketAssets,
                sumMarkets,
                "INVARIANT VIOLATED: market assets exceed listed sum"
            );
        }

        assertLe(
            harness.totalAssets(),
            sumMarkets,
            "INVARIANT VIOLATED: totalAssets exceeds listed market sum"
        );
    }

    /// @notice If totalSupply is zero then totalAssets must also be zero.
    /// @dev After initialization, dead shares guarantee totalSupply > 0.
    ///      This invariant catches any scenario where shares are fully burned
    ///      but assets remain stranded in markets.
    function invariant_zeroSupplyImpliesZeroAssets() public view {
        uint256 supply = harness.totalSupply();

        // Dead shares from initializeDeposits guarantee supply > 0.
        assertGt(
            supply,
            0,
            "INVARIANT VIOLATED: totalSupply is zero (dead shares should prevent this)"
        );

        // If somehow supply were zero, assets must also be zero.
        // This is a defensive check complementing invariant_deadSharesExist.
        if (supply == 0) {
            assertEq(
                harness.totalAssets(),
                0,
                "INVARIANT VIOLATED: totalSupply == 0 but totalAssets > 0"
            );
        }
    }

    // ========================================================================
    // HELPERS
    // ========================================================================

    function _sumActorShareBalances()
        internal
        view
        returns (uint256 actorShares)
    {
        for (uint256 i; i < actors.length; ++i) {
            actorShares += harness.balanceOf(actors[i]);
        }
    }

    function _sumListedMarketAssets()
        internal
        view
        returns (uint256 sumMarkets)
    {
        uint256 numMarkets = harness.numApprovedMarkets();
        for (uint256 i; i < numMarkets; ++i) {
            address market = harness.approvedCTokensList(i);
            sumMarkets += IBorrowableCToken(market)
                .convertToAssets(
                    IBorrowableCToken(market).balanceOf(address(harness))
                );
        }
    }

    function _assertMarketDoesNotPairOptimizerShareAsset(
        MarketManagerIsolated mm,
        address approvedMarket
    ) internal view {
        address[] memory listedTokens = mm.queryTokensListed();
        for (uint256 i; i < listedTokens.length; ++i) {
            address listedToken = listedTokens[i];
            if (listedToken == approvedMarket) continue;

            assertNotEq(
                ICToken(listedToken).asset(),
                address(harness),
                "INVARIANT VIOLATED: approved market pairs optimizer shares"
            );
        }
    }
}
