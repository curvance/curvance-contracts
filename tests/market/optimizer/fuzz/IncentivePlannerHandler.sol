// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {LendingOptimizerHarness} from "../LendingOptimizerHarness.sol";
import {
    LendingOptimizer
} from "contracts/market/optimizer/LendingOptimizer.sol";
import {
    MarketManagerIsolated
} from "contracts/market/isolated/MarketManagerIsolated.sol";
import {OptimizerReader} from "contracts/views/OptimizerReader.sol";
import {MockV3Aggregator} from "contracts/mocks/MockV3Aggregator.sol";
import {IBorrowableCToken} from "contracts/interfaces/IBorrowableCToken.sol";
import {IMarketManager} from "contracts/interfaces/IMarketManager.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {BPS} from "contracts/libraries/ConstantsLib.sol";

contract IncentivePlannerHandler is Test {
    LendingOptimizerHarness public immutable optimizer;
    OptimizerReader public immutable reader;
    IERC20 public immutable underlying;
    address public immutable admin;
    address public immutable underlyingAggregator;

    address[] public markets;
    address[] public managers;
    address[] public collateralAggregators;
    uint256[3] public incentiveBps;

    bool public ghost_violation;
    bytes32 public ghost_violationReason;
    uint256 public ghost_planCalls;
    uint256 public ghost_nonemptyPlans;
    uint256 public ghost_executedPlans;
    uint256 public ghost_stateTransitions;

    constructor(
        LendingOptimizerHarness optimizer_,
        OptimizerReader reader_,
        IERC20 underlying_,
        address admin_,
        address[] memory markets_,
        address[] memory managers_,
        address[] memory collateralAggregators_,
        address underlyingAggregator_
    ) {
        optimizer = optimizer_;
        reader = reader_;
        underlying = underlying_;
        admin = admin_;
        markets = markets_;
        managers = managers_;
        collateralAggregators = collateralAggregators_;
        underlyingAggregator = underlyingAggregator_;
    }

    function setIncentives(uint256 bps0, uint256 bps1, uint256 bps2) external {
        incentiveBps[0] = bps0 % 1_001;
        incentiveBps[1] = bps1 % 1_001;
        incentiveBps[2] = bps2 % 1_001;
        ++ghost_stateTransitions;
    }

    function setMintPaused(uint256 marketSeed, bool state) external {
        uint256 index = marketSeed % markets.length;
        vm.prank(admin);
        try MarketManagerIsolated(managers[index])
            .setMintPaused(markets[index], state) {
            ++ghost_stateTransitions;
        } catch {
            _violate("mint pause transition");
        }
    }

    function setRedeemPaused(uint256 marketSeed, bool state) external {
        uint256 index = marketSeed % markets.length;
        vm.prank(admin);
        try MarketManagerIsolated(managers[index]).setRedeemPaused(state) {
            ++ghost_stateTransitions;
        } catch {
            _violate("redeem pause transition");
        }
    }

    function markOneMarketBad(uint256 marketSeed) external {
        uint256 target = marketSeed % markets.length;
        vm.warp(block.timestamp + 3 days);
        MockV3Aggregator(underlyingAggregator).updateAnswer(1e8);
        for (uint256 i; i < collateralAggregators.length; ++i) {
            if (i == target) continue;
            MockV3Aggregator(collateralAggregators[i]).updateAnswer(1e8);
        }
        ++ghost_stateTransitions;
    }

    function refreshAllFeeds() external {
        _refreshAllFeeds();
        ++ghost_stateTransitions;
    }

    function advanceTime(uint256 rawDuration) external {
        uint256 duration = bound(rawDuration, 1, 30 days);
        vm.warp(block.timestamp + duration);
        _refreshAllFeeds();
        try optimizer.accrueIfNeeded() {}
        catch {
            _violate("accrual after time");
        }
        ++ghost_stateTransitions;
    }

    function shockLiquidity(uint256 marketSeed, uint256 rawAssets) external {
        uint256 index = marketSeed % markets.length;
        uint256 assets = bound(rawAssets, 1_000e6, 3_000_000e6);
        address whale = address(0xBEEF);
        deal(address(underlying), whale, assets);
        vm.startPrank(whale);
        underlying.approve(markets[index], assets);
        try IBorrowableCToken(markets[index]).deposit(assets, whale) {
            ++ghost_stateTransitions;
        } catch {
            // A mint-paused target is an expected rejected shock.
        }
        vm.stopPrank();
    }

    function tightenCashByBorrow(uint256 marketSeed, uint256 rawAssets)
        external
    {
        uint256 index = marketSeed % markets.length;
        uint256 assets = bound(rawAssets, 1e6, 50_000e6);
        address borrower = address(
            uint160(uint256(keccak256(abi.encode("borrower", markets[index]))))
        );

        vm.prank(borrower);
        try IBorrowableCToken(markets[index]).borrow(assets, borrower) {
            ++ghost_stateTransitions;
        } catch {
            // Collateral or debt-cap exhaustion is an expected terminal state.
        }
    }

    function planAndExecute(uint256 rawSlippage, uint256 rawChunks) external {
        ++ghost_planCalls;
        uint256 slippageBps = rawSlippage % (BPS + 1);
        uint256 chunks = rawChunks % 500 + 1;
        OptimizerReader.MarketIncentiveAPYBps[] memory incentives =
            _currentIncentives();

        try reader.optimalRebalanceWithIncentives(
            address(optimizer), slippageBps, chunks, incentives
        ) returns (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        ) {
            if (!_validatePlan(actions, bounds)) return;
            if (actions.length == 0) return;

            ++ghost_nonemptyPlans;
            try optimizer.rebalance(actions, bounds) {
                ++ghost_executedPlans;
                _validateFreshAccounting();
            } catch {
                _violate("nonempty plan reverted");
            }
        } catch {
            _violate("planner reverted");
        }
    }

    function _validatePlan(
        LendingOptimizer.ReallocationAction[] memory actions,
        LendingOptimizer.AllocationBound[] memory bounds
    ) internal returns (bool) {
        if (actions.length == 0) {
            if (bounds.length != 0) _violate("empty shape");
            return bounds.length == 0;
        }
        if (
            actions.length != markets.length || bounds.length != markets.length
        ) {
            _violate("nonempty shape");
            return false;
        }

        address[] memory badMarkets = reader.isBad(address(optimizer));
        int256 net;
        for (uint256 i; i < markets.length; ++i) {
            if (
                address(actions[i].cToken) != markets[i]
                    || bounds[i].cToken != markets[i]
            ) {
                _violate("market order");
                return false;
            }

            int256 delta = actions[i].assetsOrBps;
            net += delta;
            uint8 redeemState =
                MarketManagerIsolated(managers[i]).redeemPaused();
            (bool mintPaused,,) =
                IMarketManager(managers[i]).actionsPaused(markets[i]);
            bool bad = _contains(badMarkets, markets[i]);

            if (redeemState == 2 && delta != 0) {
                _violate("redeem-paused movement");
                return false;
            }
            if (delta > 0 && (mintPaused || bad || redeemState == 2)) {
                _violate("forbidden deposit");
                return false;
            }
            if (delta < 0 && redeemState == 2) {
                _violate("forbidden withdrawal");
                return false;
            }
            if (delta == 0) continue;

            uint256 assets = delta > 0 ? uint256(delta) : uint256(-delta);
            IBorrowableCToken cToken = IBorrowableCToken(markets[i]);
            if (cToken.convertToShares(assets) == 0) {
                _violate("dust action");
                return false;
            }
            if (delta < 0 && assets > cToken.assetsHeld()) {
                _violate("source cash");
                return false;
            }
        }

        if (net != 0) {
            _violate("unbalanced plan");
            return false;
        }
        return true;
    }

    function _validateFreshAccounting() internal {
        uint256 freshAssets;
        for (uint256 i; i < markets.length; ++i) {
            IBorrowableCToken cToken = IBorrowableCToken(markets[i]);
            freshAssets += cToken.convertToAssets(
                cToken.balanceOf(address(optimizer))
            );
        }
        if (freshAssets != optimizer.totalAssets()) {
            _violate("stale accounting");
        }
    }

    function _currentIncentives()
        internal
        view
        returns (OptimizerReader.MarketIncentiveAPYBps[] memory incentives)
    {
        incentives = new OptimizerReader
            .MarketIncentiveAPYBps[](markets.length);
        for (uint256 i; i < markets.length; ++i) {
            incentives[i] = OptimizerReader.MarketIncentiveAPYBps({
                cToken: markets[i], incentiveAPYBps: incentiveBps[i]
            });
        }
    }

    function _refreshAllFeeds() internal {
        MockV3Aggregator(underlyingAggregator).updateAnswer(1e8);
        for (uint256 i; i < collateralAggregators.length; ++i) {
            MockV3Aggregator(collateralAggregators[i]).updateAnswer(1e8);
        }
    }

    function _contains(address[] memory values, address value)
        internal
        pure
        returns (bool)
    {
        for (uint256 i; i < values.length; ++i) {
            if (values[i] == value) return true;
        }
        return false;
    }

    function _violate(bytes32 reason) internal {
        if (ghost_violation) return;
        ghost_violation = true;
        ghost_violationReason = reason;
    }
}
