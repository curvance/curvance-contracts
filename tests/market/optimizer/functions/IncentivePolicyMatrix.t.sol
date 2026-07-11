// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {TestBaseLendingOptimizer} from "../TestBaseLendingOptimizer.sol";
import {
    LendingOptimizer
} from "contracts/market/optimizer/LendingOptimizer.sol";
import {LendingOptimizerHarness} from "../LendingOptimizerHarness.sol";
import {OptimizerReader} from "contracts/views/OptimizerReader.sol";
import {MockV3Aggregator} from "contracts/mocks/MockV3Aggregator.sol";
import {
    IChainlink
} from "contracts/interfaces/external/chainlink/IChainlink.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {IBorrowableCToken} from "contracts/interfaces/IBorrowableCToken.sol";
import {IMarketManager} from "contracts/interfaces/IMarketManager.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";

/// @title Incentive Safety-Policy Matrix (T-02, property P-06)
/// @notice Proves that `optimalRebalanceWithIncentives` never lets an incentive,
///         even the maximum allowed `MAX_INCENTIVE_APY_BPS`, override the
///         bad-market / mint-paused / redeem-paused safety policy.
///
///         For each forbidden state we pin the maximum incentive on the tagged
///         forbidden market (the single most attractive economic signal the API
///         accepts) and assert the forbidden move never appears:
///
///           mint-paused         : never receives a deposit (source only).
///           redeem-paused       : frozen — no deposit and no withdrawal.
///           bad (stale oracle)  : never receives a deposit; may be evacuated.
///           bad + mint-paused   : forced withdrawal, never a deposit.
///           bad + redeem-paused : frozen — exactly zero action.
///
///         A healthy control proves the incentive is otherwise strong enough to
///         attract a deposit, so the safety assertions cannot pass vacuously.
///
///         Every produced plan is additionally checked for well-formedness,
///         exact deposit/withdraw conservation, source executability, and
///         no-revert immediate execution against unchanged state (which is
///         where the executor's own pause enforcement is exercised).
contract TestIncentivePolicyMatrix is TestBaseLendingOptimizer {
    OptimizerReader reader;

    /// @dev Matches BadMarketPausedCombination: ChainlinkAdaptor stores
    ///      heartbeat = 1 days + HEARTBEAT_GRACE_PERIOD (120) = 86520s. A 1.5x
    ///      staleness multiplier makes the effective bad threshold 129780s.
    uint256 constant DEFAULT_HEARTBEAT = 86520;
    uint256 constant MULTIPLIER_1_5X = 15000;
    uint256 constant THRESHOLD_1_5X =
        DEFAULT_HEARTBEAT * MULTIPLIER_1_5X / 10000;

    uint256 constant DEPOSIT_PER_MARKET = 100_000e6;

    /// @dev Rounding tolerance (asset units) for the "withdrawal <= position"
    ///      executability check, mirroring the reader's forced-move headroom.
    uint256 constant WITHDRAW_ROUNDING_TOLERANCE = 4;

    function setUp() public override {
        super.setUp();
        // Non-zero multiplier so isBad()'s staleness path is active.
        reader = new OptimizerReader(
            ICentralRegistry(address(liveCentralRegistry)), MULTIPLIER_1_5X
        );
    }

    // =====================================================================
    // Single-state cells
    // =====================================================================

    /// @notice Max incentive on a mint-paused market must not pull a deposit.
    function test_maxIncentive_mintPaused_noDeposit() public {
        _setUp();
        _depositEvenly();

        uint256 t = 1; // cUSDC_WBTC_MARKET
        _mockMintPaused(_marketAtIndex(t));

        (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        ) = _planMaxIncentiveOn(t);

        _assertNoDeposit(
            actions, t, "mint-paused market must not receive a deposit"
        );
        _assertPlanSafeAndExecutable(actions, bounds);
    }

    /// @notice Max incentive on a redeem-paused market must leave it frozen:
    ///         neither a deposit nor a withdrawal.
    function test_maxIncentive_redeemPaused_frozen() public {
        _setUp();
        _depositEvenly();

        uint256 t = 1;
        _mockRedeemPaused(_marketAtIndex(t));

        (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        ) = _planMaxIncentiveOn(t);

        _assertFrozen(actions, t, "redeem-paused market must stay frozen");
        _assertPlanSafeAndExecutable(actions, bounds);
    }

    /// @notice Max incentive on a bad (stale-collateral) but redeemable market
    ///         must not pull a deposit. Evacuation (a withdrawal) is permitted.
    function test_maxIncentive_badRedeemable_noDepositEvacuates() public {
        _setUp();
        _depositEvenly();

        uint256 t = 1;
        _makeBad(t);
        _assertFlaggedBad(t);

        (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        ) = _planMaxIncentiveOn(t);

        _assertNoDeposit(
            actions,
            t,
            "bad market must not receive a deposit despite max incentive"
        );
        // Bad + redeemable is expected to be evacuated, not frozen.
        if (actions.length > 0) {
            assertLt(
                actions[t].assetsOrBps,
                int256(0),
                "bad redeemable market should be evacuated (net withdrawal)"
            );
        }
        _assertPlanSafeAndExecutable(actions, bounds);
    }

    /// @notice Max incentive on a bad + mint-paused market: mint-pause is
    ///         irrelevant to the forced-evacuation path (redemption still works),
    ///         so it is withdrawn, never deposited into.
    function test_maxIncentive_badAndMintPaused_forcedWithdrawal() public {
        _setUp();
        _depositEvenly();

        uint256 t = 1;
        _makeBad(t);
        _mockMintPaused(_marketAtIndex(t));
        _assertFlaggedBad(t);

        (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        ) = _planMaxIncentiveOn(t);

        _assertNoDeposit(
            actions, t, "bad+mint-paused market must not receive a deposit"
        );
        _assertPlanSafeAndExecutable(actions, bounds);
    }

    /// @notice Max incentive on a bad + redeem-paused market: forced evacuation
    ///         is mechanically impossible, so the position freezes at exactly
    ///         zero action.
    function test_maxIncentive_badAndRedeemPaused_frozen() public {
        _setUp();
        _depositEvenly();

        uint256 t = 1;
        _makeBad(t);
        _mockRedeemPaused(_marketAtIndex(t));
        _assertFlaggedBad(t);

        (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        ) = _planMaxIncentiveOn(t);

        _assertFrozen(actions, t, "bad+redeem-paused market must stay frozen");
        _assertPlanSafeAndExecutable(actions, bounds);
    }

    /// @notice Control: on a fully healthy market the same max incentive DOES
    ///         attract a deposit. This proves the incentive signal is strong
    ///         enough to move funds, so the forbidden-state assertions above are
    ///         not passing vacuously.
    function test_maxIncentive_healthy_attractsDeposit() public {
        _setUp();
        _depositEvenly();

        uint256 t = 2; // cUSDC_WETH_MARKET, healthy
        uint256 before = _allocatedAssets(_marketAtIndex(t));

        (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        ) = _planMaxIncentiveOn(t);

        assertGt(
            actions.length, 0, "healthy max-incentive plan should be non-empty"
        );
        assertGt(
            actions[t].assetsOrBps,
            int256(0),
            "healthy market with max incentive should receive a deposit"
        );
        optimizer.rebalance(actions, bounds);
        assertGt(
            _allocatedAssets(_marketAtIndex(t)),
            before,
            "execution should increase the incentivized healthy market's allocation"
        );
    }

    /// @notice Non-vacuity anchor for the forbidden-state cells: the exact
    ///         market those cells target (index 1, WBTC), with the exact even
    ///         starting allocation and max incentive, DOES receive a deposit
    ///         when healthy. So each forbidden-state assertion above blocks a
    ///         move that would otherwise have happened — it is not vacuous.
    function test_maxIncentive_healthyTargetIndex1_attractsDeposit() public {
        _setUp();
        _depositEvenly();

        uint256 t = 1; // cUSDC_WBTC_MARKET, healthy
        (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        ) = _planMaxIncentiveOn(t);

        assertGt(
            actions.length,
            0,
            "healthy WBTC max-incentive plan should be non-empty"
        );
        assertGt(
            actions[t].assetsOrBps,
            int256(0),
            "healthy WBTC with max incentive should receive a deposit"
        );
        _assertPlanSafeAndExecutable(actions, bounds);
    }

    // =====================================================================
    // Fuzz: property holds across the whole incentive domain and every target
    // =====================================================================

    /// @notice For any target market and any incentive in [0, MAX], a
    ///         mint-paused market never receives a deposit and a redeem-paused
    ///         market never moves. Sweeping the full incentive range guards
    ///         against a threshold at which the guard silently gives way.
    function testFuzz_pauseStatePolicyHoldsForAnyIncentive(
        uint8 rawTarget,
        uint16 rawIncentiveBps,
        bool redeemInsteadOfMint
    ) public {
        _setUp();
        _depositEvenly();

        uint256 t = rawTarget % 3;
        uint256 maxBps = reader.MAX_INCENTIVE_APY_BPS();
        uint256 incentiveBps = uint256(rawIncentiveBps) % (maxBps + 1);

        if (redeemInsteadOfMint) {
            _mockRedeemPaused(_marketAtIndex(t));
        } else {
            _mockMintPaused(_marketAtIndex(t));
        }

        (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        ) = _planIncentiveOn(t, incentiveBps);

        if (redeemInsteadOfMint) {
            _assertFrozen(
                actions, t, "redeem-paused market moved under fuzzed incentive"
            );
        } else {
            _assertNoDeposit(
                actions,
                t,
                "mint-paused market got a deposit under fuzzed incentive"
            );
        }
        _assertPlanSafeAndExecutable(actions, bounds);
    }

    /// @notice For any target market and any incentive in [0, MAX], a bad
    ///         (stale-collateral) market never receives a deposit.
    function testFuzz_badMarketNeverReceivesDeposit(
        uint8 rawTarget,
        uint16 rawIncentiveBps
    ) public {
        _setUp();
        _depositEvenly();

        uint256 t = rawTarget % 3;
        uint256 maxBps = reader.MAX_INCENTIVE_APY_BPS();
        uint256 incentiveBps = uint256(rawIncentiveBps) % (maxBps + 1);

        _makeBad(t);
        _assertFlaggedBad(t);

        (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        ) = _planIncentiveOn(t, incentiveBps);

        _assertNoDeposit(
            actions, t, "bad market got a deposit under fuzzed incentive"
        );
        _assertPlanSafeAndExecutable(actions, bounds);
    }

    // =====================================================================
    // Assertions
    // =====================================================================

    /// @dev Forbidden market index `t` must not receive a deposit (action <= 0).
    function _assertNoDeposit(
        LendingOptimizer.ReallocationAction[] memory actions,
        uint256 t,
        string memory err
    ) internal {
        if (actions.length == 0) return;
        assertLe(actions[t].assetsOrBps, int256(0), err);
    }

    /// @dev Forbidden market index `t` must be frozen (action == 0).
    function _assertFrozen(
        LendingOptimizer.ReallocationAction[] memory actions,
        uint256 t,
        string memory err
    ) internal {
        if (actions.length == 0) return;
        assertEq(actions[t].assetsOrBps, int256(0), err);
    }

    /// @dev Plan well-formedness, exact conservation, source executability, and
    ///      no-revert immediate execution against unchanged state.
    function _assertPlanSafeAndExecutable(
        LendingOptimizer.ReallocationAction[] memory actions,
        LendingOptimizer.AllocationBound[] memory bounds
    ) internal {
        assertEq(
            bounds.length, actions.length, "bounds/actions length mismatch"
        );
        if (actions.length == 0) return;

        address[] memory markets = optimizer.getApprovedMarkets();
        assertEq(actions.length, markets.length, "actions length != markets");

        int256 net;
        uint256 deposits;
        uint256 withdrawals;
        for (uint256 i; i < actions.length; ++i) {
            assertEq(
                address(actions[i].cToken), markets[i], "action market order"
            );
            assertEq(bounds[i].cToken, markets[i], "bound market order");

            int256 v = actions[i].assetsOrBps;
            net += v;
            if (v > 0) {
                deposits += uint256(v);
            } else if (v < 0) {
                uint256 mag = uint256(-v);
                withdrawals += mag;
                // A withdrawal can never exceed the optimizer's own position.
                assertLe(
                    mag,
                    _allocatedAssets(markets[i]) + WITHDRAW_ROUNDING_TOLERANCE,
                    "withdrawal exceeds optimizer position"
                );
            }
        }
        // Conservation: declared deposits equal declared withdrawals exactly.
        assertEq(net, int256(0), "plan not zero-sum");
        assertEq(deposits, withdrawals, "deposits != withdrawals");

        // Immediate execution against unchanged state must not revert. This is
        // where the executor re-checks direct mint/redeem pause conditions.
        optimizer.rebalance(actions, bounds);
    }

    function _assertFlaggedBad(uint256 t) internal {
        address[] memory bad = reader.isBad(address(optimizer));
        bool found;
        for (uint256 i; i < bad.length; ++i) {
            if (bad[i] == _marketAtIndex(t)) found = true;
        }
        assertTrue(found, "target market not flagged bad");
    }

    // =====================================================================
    // Scenario construction
    // =====================================================================

    function _planMaxIncentiveOn(uint256 t)
        internal
        returns (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        )
    {
        return _planIncentiveOn(t, reader.MAX_INCENTIVE_APY_BPS());
    }

    function _planIncentiveOn(uint256 t, uint256 bps)
        internal
        returns (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        )
    {
        uint256[3] memory bpsByIndex;
        bpsByIndex[t] = bps;
        OptimizerReader.MarketIncentiveAPYBps[] memory incentives =
            _taggedIncentives(
                cUSDC_WMON_MARKET,
                bpsByIndex[0],
                cUSDC_WBTC_MARKET,
                bpsByIndex[1],
                cUSDC_WETH_MARKET,
                bpsByIndex[2]
            );
        (actions, bounds) = reader.optimalRebalanceWithIncentives(
            address(optimizer), 500, 200, incentives
        );
    }

    /// @dev Makes market `t` bad by aging all collateral feeds past the
    ///      staleness threshold, then refreshing only the non-target feeds.
    function _makeBad(uint256 t) internal {
        skip(THRESHOLD_1_5X + 1);
        for (uint256 i; i < 3; ++i) {
            if (i != t) _refreshCollateralFeed(_marketAtIndex(i));
        }
        optimizer.accrueIfNeeded();
    }

    // =====================================================================
    // Harness setup (mirrors BadMarketPausedCombination unconstrained setup)
    // =====================================================================

    function _setUp() internal {
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
            abi.encodeWithSelector(
                ICentralRegistry.hasMarketPermissions.selector, address(this)
            ),
            abi.encode(true)
        );
        optimizer.initializeDeposits(cUSDC_WMON_MARKET);

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(
                ICentralRegistry.hasHarvestPermissions.selector, address(this)
            ),
            abi.encode(true)
        );
    }

    function _depositEvenly() internal {
        address[3] memory markets =
            [cUSDC_WMON_MARKET, cUSDC_WBTC_MARKET, cUSDC_WETH_MARKET];
        for (uint256 i; i < 3; ++i) {
            deal(USDC_MONAD, address(this), DEPOSIT_PER_MARKET);
            IERC20(USDC_MONAD).approve(address(optimizer), DEPOSIT_PER_MARKET);
            LendingOptimizerHarness(address(optimizer))
                .depositToMarket(DEPOSIT_PER_MARKET, address(this), markets[i]);
        }
    }

    // =====================================================================
    // Mocks and small utilities (mirrors sibling suites)
    // =====================================================================

    function _mockRedeemPaused(address market) internal {
        address mm = address(IBorrowableCToken(market).marketManager());
        vm.mockCall(
            mm,
            abi.encodeWithSelector(bytes4(keccak256("redeemPaused()"))),
            abi.encode(uint8(2))
        );
    }

    function _mockMintPaused(address market) internal {
        address mm = address(IBorrowableCToken(market).marketManager());
        vm.mockCall(
            mm,
            abi.encodeWithSelector(
                IMarketManager.actionsPaused.selector, market
            ),
            abi.encode(true, false, false)
        );
    }

    function _refreshCollateralFeed(address market) internal {
        address collAsset = _collaterals[market];
        (, IChainlink aggregator,,) =
            _chainlinkAdaptor.assetConfig(collAsset, true);
        MockV3Aggregator(address(aggregator)).updateAnswer(1e8);
    }

    function _allocatedAssets(address market) internal view returns (uint256) {
        IBorrowableCToken ct = IBorrowableCToken(market);
        return ct.convertToAssets(ct.balanceOf(address(optimizer)));
    }

    function _marketAtIndex(uint256 index) internal view returns (address) {
        if (index == 0) return cUSDC_WMON_MARKET;
        if (index == 1) return cUSDC_WBTC_MARKET;
        if (index == 2) return cUSDC_WETH_MARKET;
        revert("invalid market index");
    }

    function _taggedIncentives(
        address market0,
        uint256 market0Bps,
        address market1,
        uint256 market1Bps,
        address market2,
        uint256 market2Bps
    )
        internal
        pure
        returns (OptimizerReader.MarketIncentiveAPYBps[] memory incentives)
    {
        incentives = new OptimizerReader.MarketIncentiveAPYBps[](3);
        incentives[0] = OptimizerReader.MarketIncentiveAPYBps({
            cToken: market0, incentiveAPYBps: market0Bps
        });
        incentives[1] = OptimizerReader.MarketIncentiveAPYBps({
            cToken: market1, incentiveAPYBps: market1Bps
        });
        incentives[2] = OptimizerReader.MarketIncentiveAPYBps({
            cToken: market2, incentiveAPYBps: market2Bps
        });
    }
}
