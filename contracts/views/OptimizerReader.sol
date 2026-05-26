// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { BPS, WAD } from "contracts/libraries/ConstantsLib.sol";

import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { IDynamicIRM } from "contracts/interfaces/IDynamicIRM.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ILendingOptimizer } from "contracts/interfaces/ILendingOptimizer.sol";
import { IOracleAdaptor } from "contracts/interfaces/IOracleAdaptor.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";
import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";

interface IChainlinkAdaptor {
    function assetConfig(
        address asset,
        bool inUSD
    ) external view returns (bool isConfigured, address aggregatorProxy, uint8 decimals, uint24 heartbeat);
}

contract OptimizerReader {
    struct OptimizerCTokenData {
        /// @notice The cToken address.
        address _address;
        /// @notice Underlying assets allocated to this cToken by the optimizer.
        uint256 allocatedAssets;
        /// @notice Idle (non-loaned) liquidity available in this cToken market.
        uint256 liquidity;
        /// @notice Allocation cap for this cToken in WAD (1e18 = 100%).
        uint256 allocationCap;
        /// @notice Current allocation relative to the theoretical max allocation
        ///         allowed by the cap, in BPS. 10000 = at cap.
        uint256 allocationCapUtilizationBps;
    }

    struct OptimizerMarketData {
        /// @notice The optimizer address.
        address _address;
        /// @notice The underlying asset address (e.g., USDC).
        address asset;
        /// @notice Total underlying assets held across all markets.
        uint256 totalAssets;
        /// @notice Per-cToken market data.
        OptimizerCTokenData[] markets;
        /// @notice Total idle liquidity across all cToken markets.
        uint256 totalLiquidity;
        /// @notice Optimizer share price (exchange rate) in WAD.
        uint256 sharePrice;
        /// @notice Performance fee in BPS.
        uint256 performanceFee;
        /// @notice Annualized weighted-average supply APY in WAD (1e18 = 100%),
        ///         pre-performance-fee. Matches getOptimizerAPY() semantics.
        uint256 apy;
    }

    struct OptimizerUserData {
        /// @notice The optimizer address.
        address _address;
        /// @notice User's optimizer share balance.
        uint256 shareBalance;
        /// @notice User's redeemable underlying amount (from their optimizer shares).
        uint256 redeemable;
    }

    /// @dev Internal struct to pack per-market allocation state into a single
    ///      array, avoiding stack-too-deep in _computeIdealAllocation.
    struct MarketAlloc {
        uint256 simAssetsHeld;
        uint256 debt;
        uint256 fees;
        uint256 maxAllocation;
        IDynamicIRM irm;
    }

    /// @dev Projected post-accrual cToken state used for view-only rebalance
    ///      planning. Mirrors the accounting touched by BorrowableCToken
    ///      accrual without mutating market state.
    struct ProjectedCTokenState {
        uint256 totalAssets;
        uint256 totalSupply;
        uint256 assetsHeld;
        uint256 debt;
        uint256 protocolFeeShares;
    }

    /// ERRORS ///

    error OptimizerReader__Unauthorized();
    error OptimizerReader__InvalidMultiplier();

    /// EVENTS ///

    event StalenessMultiplierUpdated(uint256 oldMultiplier, uint256 newMultiplier);

    /// CONSTANTS ///

    /// @notice Minimum total rebalance value in USD (WAD) below which
    ///         optimalRebalance returns empty arrays. 1e18 = $1.
    uint256 public constant USD_THRESHOLD = 100e18;

    /// @notice Default cap headroom used by optimalRebalance planning.
    uint256 public constant CAP_BUFFER_BPS = 5;

    /// @notice Number of chunks used by optimalRebalance greedy allocation.
    uint256 public constant REBALANCE_CHUNKS = 100;

    /// @dev BorrowableCToken base reserve held in every initialized market.
    uint256 internal constant _BASE_UNDERLYING_RESERVE = 77777;

    /// IMMUTABLES ///

    /// @notice The OracleManager address.
    IOracleManager public immutable ORACLE_MANAGER;

    /// @notice Curvance Protocol Central Registry, used for permissioning.
    ICentralRegistry public immutable centralRegistry;

    /// @notice Multiplier in BPS applied to each oracle's configured heartbeat
    ///         to determine the staleness threshold. 0 = staleness check disabled.
    ///         e.g., 15000 (1.5x) means a feed with a 1h heartbeat is stale after 1.5h.
    uint256 public stalenessMultiplierBps;

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry _centralRegistry,
        uint256 _stalenessMultiplier
    ) {
        centralRegistry = _centralRegistry;
        ORACLE_MANAGER = IOracleManager(_centralRegistry.oracleManager());
        stalenessMultiplierBps = _stalenessMultiplier;
    }

    /// PERMISSIONED FUNCTIONS ///

    /// @notice Updates the global staleness multiplier.
    /// @dev Only callable by an address with elevated permissions.
    ///      Set to 0 to disable staleness checking.
    /// @param newMultiplierBps The new multiplier in BPS (e.g., 15000 = 1.5x heartbeat).
    function setStalenessMultiplier(uint256 newMultiplierBps) external {
        if (!centralRegistry.hasElevatedPermissions(msg.sender)) {
            revert OptimizerReader__Unauthorized();
        }

        if (newMultiplierBps != 0 && newMultiplierBps < 10_000) {
            revert OptimizerReader__InvalidMultiplier();
        }

        uint256 oldMultiplier = stalenessMultiplierBps;
        stalenessMultiplierBps = newMultiplierBps;

        emit StalenessMultiplierUpdated(oldMultiplier, newMultiplierBps);
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Checks multiple optimizers for bad markets in a single call.
    /// @param optimizers The LendingOptimizer addresses.
    /// @return badOptimizers An array of cToken arrays, where each inner array
    ///         contains the bad markets for the corresponding optimizer.
    function multiIsBadCheck(
        address[] calldata optimizers
    ) external view returns (address[][] memory badOptimizers) {
        uint256 len = optimizers.length;
        badOptimizers = new address[][](len);

        for (uint256 i; i < len; ++i) {
            badOptimizers[i] = this.isBad(optimizers[i]);
        }
    }

    /// @notice Checks whether any approved market should be considered
    ///         unsafe due to a stale oracle feed or breached PriceGuard.
    /// @dev For each approved market in the optimizer:
    ///      1. Checks if the collateral's oracle feed is stale (if
    ///         stalenessMultiplier > 0).
    ///      2. Checks if the collateral's adjusted price is zero. Curvance
    ///         PriceGuards return zero when the guarded price breaches the
    ///         configured floor, so this acts as the PriceGuard breach check.
    ///      A market is flagged if either condition is met.
    /// @param optimizer The LendingOptimizer address.
    /// @return bad Array of optimizer cToken addresses whose
    ///         collateral has a stale oracle or breached PriceGuard.
    function isBad(
        address optimizer
    ) external view returns (address[] memory bad) {
        address[] memory markets = ILendingOptimizer(optimizer).getApprovedMarkets();
        uint256 numMarkets = markets.length;

        // Temporary array sized to max possible flags.
        address[] memory temp = new address[](numMarkets);
        uint256 flagCount;

        uint256 _stalenessMultiplierBps = stalenessMultiplierBps;

        for (uint256 i; i < numMarkets; ++i) {
            // Find the collateral cToken for this market by walking
            // the market manager's listed tokens.
            IMarketManager mm = _marketManager(markets[i]);
            address[] memory listed = mm.queryTokensListed();

            bool flagged;

            for (uint256 j; j < listed.length; ++j) {
                // Skip the optimizer's own cToken — the other token
                // is the collateral.
                if (listed[j] == markets[i]) continue;

                address collateralAsset = ICToken(listed[j]).asset();

                // Check oracle staleness (applies to all markets).
                if (_stalenessMultiplierBps > 0 &&
                    _isOracleStale(collateralAsset, _stalenessMultiplierBps)
                ) {
                    flagged = true;
                    break;
                }

                // A zero adjusted price is the simplified PriceGuard breach
                // signal emitted by oracle adaptors and wrapped aggregators.
                if (_isOraclePriceZero(collateralAsset)) {
                    flagged = true;
                    break;
                }
            }

            if (flagged) {
                temp[flagCount++] = markets[i];
            }
        }

        // Copy to correctly sized array.
        bad = new address[](flagCount);
        for (uint256 i; i < flagCount; ++i) {
            bad[i] = temp[i];
        }
    }

    /// @notice Returns market data for a list of LendingOptimizers.
    /// @param optimizers The LendingOptimizer addresses.
    /// @return data The market data for each optimizer.
    function getOptimizerMarketData(
        address[] calldata optimizers
    ) external view returns (OptimizerMarketData[] memory data) {
        uint256 len = optimizers.length;
        data = new OptimizerMarketData[](len);

        for (uint256 i; i < len; ++i) {
            ILendingOptimizer opt = ILendingOptimizer(optimizers[i]);

            data[i]._address = optimizers[i];
            data[i].asset = opt.asset();
            data[i].totalAssets = opt.totalAssets();
            // View-only exchange rate. Stale relative to unclaimed cToken
            // accruals; drift is wei-scale over seconds and acceptable for
            // display. Callers needing post-accrual precision should call
            // opt.exchangeRateUpdated() directly.
            data[i].sharePrice = opt.exchangeRate();
            data[i].performanceFee = opt.fee();
            data[i].apy = getOptimizerAPY(optimizers[i]);

            address[] memory cTokens = opt.getApprovedMarkets();
            uint256 l = cTokens.length;
            data[i].markets = new OptimizerCTokenData[](l);

            for (uint256 j; j < l; ++j) {
                IBorrowableCToken cToken = IBorrowableCToken(cTokens[j]);
                uint256 allocated = cToken.convertToAssets(
                    _balanceOf(address(cToken), optimizers[i])
                );
                uint256 liquidity = _assetsHeld(cToken);
                uint256 allocationCap = opt.allocationCaps(cTokens[j]);
                uint256 maxAllocation = FixedPointMathLib.mulDiv(
                    data[i].totalAssets,
                    allocationCap,
                    WAD
                );
                uint256 allocationCapUtilizationBps = maxAllocation == 0
                    ? 0
                    : FixedPointMathLib.mulDiv(allocated, BPS, maxAllocation);

                data[i].markets[j] = OptimizerCTokenData({
                    _address: cTokens[j],
                    allocatedAssets: allocated,
                    liquidity: liquidity,
                    allocationCap: allocationCap,
                    allocationCapUtilizationBps: allocationCapUtilizationBps
                });
                data[i].totalLiquidity += liquidity;
            }
        }
    }

    /// @notice Returns user-specific data for a list of LendingOptimizers.
    /// @param optimizers The LendingOptimizer addresses.
    /// @param account The user address to query.
    /// @return data The user data for each optimizer.
    function getOptimizerUserData(
        address[] calldata optimizers,
        address account
    ) external view returns (OptimizerUserData[] memory data) {
        uint256 len = optimizers.length;
        data = new OptimizerUserData[](len);

        for (uint256 i; i < len; ++i) {
            ILendingOptimizer opt = ILendingOptimizer(optimizers[i]);
            uint256 shares = _balanceOf(optimizers[i], account);

            data[i]._address = optimizers[i];
            data[i].shareBalance = shares;
            data[i].redeemable = opt.convertToAssets(shares);
        }
    }

    /// @notice Returns the annualized weighted-average supply APY for a
    ///         LendingOptimizer, in WAD (1e18 = 100%).
    /// @dev Does not account for the optimizer's performance fee.
    /// @param optimizer The LendingOptimizer address.
    /// @return apy The annualized supply APY in WAD.
    function getOptimizerAPY(
        address optimizer
    ) public view returns (uint256 apy) {
        ILendingOptimizer opt = ILendingOptimizer(optimizer);
        uint256 ta = opt.totalAssets();
        if (ta == 0) return 0;

        address[] memory markets = opt.getApprovedMarkets();
        uint256 weightedRate;

        for (uint256 i; i < markets.length; ++i) {
            IBorrowableCToken ct = IBorrowableCToken(markets[i]);
            uint256 allocated = ct.convertToAssets(
                _balanceOf(address(ct), optimizer)
            );

            uint256 rate = _IRM(ct).supplyRate(
                _assetsHeld(ct),
                _outstandingDebt(ct),
                _interestFee(ct)
            );

            weightedRate += FixedPointMathLib.mulDiv(allocated, rate, ta);
        }

        apy = weightedRate * 31_536_000;
    }

    /// @notice Returns `account`'s projected cToken asset balance at `timestamp`.
    /// @dev This is the view-only counterpart to BorrowableCToken accrual,
    ///      including vested interest and protocol fee share dilution.
    /// @param account The account whose cToken shares should be valued.
    /// @param cToken The BorrowableCToken market to project.
    /// @param timestamp The timestamp to project to. Past timestamps clamp
    ///                  to the current block timestamp.
    function assetsAtTimestamp(
        address account,
        address cToken,
        uint256 timestamp
    ) public view returns (uint256 assets) {
        IBorrowableCToken token = IBorrowableCToken(cToken);
        ProjectedCTokenState memory projected = _projectCTokenState(token, timestamp);

        uint256 shares = _balanceOf(cToken, account);
        if (shares == 0 && projected.protocolFeeShares == 0) return 0;

        if (account == centralRegistry.daoAddress()) {
            shares += projected.protocolFeeShares;
        }

        assets = _convertProjectedToAssets(shares, projected.totalAssets, projected.totalSupply);
    }

    /// @notice Computes optimal rebalance actions, automatically excluding
    ///         any markets flagged by isBad(). In normal conditions (no bad
    ///         markets), this is a pure yield-optimization. When bad markets
    ///         exist, it withdraws everything from them and optimally
    ///         redistributes across the remaining good markets.
    ///         Returns empty arrays when no actionable rebalance exists
    ///         (all deltas are zero or dust).
    /// @param optimizer The LendingOptimizer address.
    /// @param slippageBps Tolerance in BPS around each market's ideal allocation.
    ///                    e.g., 100 = +/- 1%.
    /// @return actions The rebalance actions array matching approvedCTokensList order,
    ///                 or empty if no rebalance is needed.
    /// @return bounds The allocation bounds array matching approvedCTokensList order,
    ///                or empty if no rebalance is needed.
    function optimalRebalance(
        address optimizer,
        uint256 slippageBps
    ) external view returns (
        LendingOptimizer.ReallocationAction[] memory actions,
        LendingOptimizer.AllocationBound[] memory bounds
    ) {
        (actions, bounds) = _optimalRebalanceAt(optimizer, slippageBps, block.timestamp);
    }

    /// @notice Computes optimal rebalance actions using projected cToken
    ///         accrual state at `timestamp`.
    /// @param optimizer The LendingOptimizer address.
    /// @param slippageBps Tolerance in BPS around each market's ideal allocation.
    /// @param timestamp Timestamp to project cToken accrual to.
    /// @return actions The rebalance actions array matching approvedCTokensList order,
    ///                 or empty if no rebalance is needed.
    /// @return bounds The allocation bounds array matching approvedCTokensList order,
    ///                or empty if no rebalance is needed.
    function optimalRebalanceAt(
        address optimizer,
        uint256 slippageBps,
        uint256 timestamp
    ) external view returns (
        LendingOptimizer.ReallocationAction[] memory actions,
        LendingOptimizer.AllocationBound[] memory bounds
    ) {
        (actions, bounds) = _optimalRebalanceAt(optimizer, slippageBps, timestamp);
    }

    function _optimalRebalanceAt(
        address optimizer,
        uint256 slippageBps,
        uint256 timestamp
    ) internal view returns (
        LendingOptimizer.ReallocationAction[] memory actions,
        LendingOptimizer.AllocationBound[] memory bounds
    ) {
        address[] memory markets = ILendingOptimizer(optimizer).getApprovedMarkets();

        if (markets.length == 0) return (actions, bounds);

        // Automatically exclude bad markets from allocation.
        address[] memory badMarkets = this.isBad(optimizer);

        uint256[] memory idealAssets;
        uint256[] memory currentAssets;
        uint256 totalAssets;
        (idealAssets, currentAssets,) =
            _computeIdealAllocation(optimizer, markets, badMarkets, timestamp);
        for (uint256 i; i < currentAssets.length; ++i) {
            totalAssets += currentAssets[i];
        }

        // Remove dust actions that would revert at the cToken level
        // (convertToShares == 0) and rebalance to maintain zero-sum.
        // Returns empty arrays if no actionable rebalance remains.
        if (!_removeDustActions(markets, idealAssets, currentAssets)) {
            return (actions, bounds);
        }

        actions = new LendingOptimizer.ReallocationAction[](markets.length);
        bounds = new LendingOptimizer.AllocationBound[](markets.length);

        _buildActionsAndBounds(markets, idealAssets, currentAssets, totalAssets, slippageBps, actions, bounds);

        if (badMarkets.length == 0) {
            address underlying = ILendingOptimizer(optimizer).asset();
            (uint256 price, uint256 errorCode) = ORACLE_MANAGER.getPrice(underlying, true, true);

            // Only apply threshold if price is reliable.
            if (errorCode == 0 && price > 0) {
                uint256 assetDecimals = IERC20(underlying).decimals();

                uint256 totalAbsAssets;
                for (uint256 i; i < actions.length; ++i) {
                    int256 v = actions[i].assetsOrBps;
                    totalAbsAssets += v > 0 ? uint256(v) : uint256(-v);
                }

                // Only half matters (deposits == withdrawals), so divide by 2.
                uint256 usdValue = FixedPointMathLib.mulDiv(
                    totalAbsAssets / 2, price, 10 ** assetDecimals
                );

                if (usdValue < USD_THRESHOLD) {
                    return (
                        new LendingOptimizer.ReallocationAction[](0),
                        new LendingOptimizer.AllocationBound[](0)
                    );
                }
            }
        }
    }

    /// @dev Chunked greedy allocation: computes the ideal per-market asset
    ///      distribution for a LendingOptimizer, respecting allocation caps
    ///      and market pause states.
    ///      When `badMarkets` is non-empty, those markets are forced to
    ///      maxAllocation = 0, causing full withdrawal and optimal
    ///      redistribution across the remaining good markets.
    ///      Separated from the public functions to avoid stack-too-deep.
    function _computeIdealAllocation(
        address optimizer,
        address[] memory markets,
        address[] memory badMarkets,
        uint256 timestamp
    ) internal view returns (
        uint256[] memory idealAssets,
        uint256[] memory currentAssets,
        MarketAlloc[] memory m
    ) {
        uint256 numMarkets = markets.length;
        idealAssets = new uint256[](numMarkets);
        currentAssets = new uint256[](numMarkets);
        m = new MarketAlloc[](numMarkets);

        // First pass: snapshot per-market state and compute total assets.
        uint256 ta;
        {
            for (uint256 i; i < numMarkets; ++i) {
                IBorrowableCToken ct = IBorrowableCToken(markets[i]);
                ProjectedCTokenState memory projected = _projectCTokenState(ct, timestamp);
                uint256 ca = _convertProjectedToAssets(
                    _balanceOf(address(ct), optimizer),
                    projected.totalAssets,
                    projected.totalSupply
                );
                currentAssets[i] = ca;
                ta += ca;

                uint256 assetsHeld = projected.assetsHeld;
                m[i].simAssetsHeld = assetsHeld > ca
                    ? assetsHeld - ca
                    : 0;
                m[i].debt = projected.debt;
                m[i].fees = _interestFee(ct);
                m[i].irm = _IRM(ct);
            }
        }

        if (ta == 0) return (idealAssets, currentAssets, m);

        // Second pass: compute maxAllocation, adjust for pause states,
        // and force bad markets to zero allocation.
        uint256 lockedAssets;
        {
            ILendingOptimizer opt = ILendingOptimizer(optimizer);
            uint256 bufferBps = _selectCapBuffer(opt, markets, badMarkets, currentAssets, ta);
            for (uint256 i; i < numMarkets; ++i) {
                uint256 current = currentAssets[i];
                m[i].maxAllocation = _bufferedMaxAllocation(opt, markets[i], ta, bufferBps);

                MarketManagerIsolated mm = MarketManagerIsolated(address(_marketManager(markets[i])));
                // Two orthogonal constraints drive allocation policy:
                //  - cannotAddMore: bad or mint-paused — no new deposits.
                //  - cannotWithdraw: redeem-paused — must keep current position.
                bool cannotAddMore = _isBadMarket(markets[i], badMarkets)
                    || _isMintPaused(markets[i], IMarketManager(address(mm)));
                bool cannotWithdraw = mm.redeemPaused() == 2;

                if (cannotWithdraw) {
                    // Position is locked; exclude from distributable pool.
                    m[i].simAssetsHeld += current;
                    lockedAssets += current;
                    idealAssets[i] = current;
                    // If also cannot add, freeze at current; otherwise floor at current.
                    if (cannotAddMore) {
                        m[i].maxAllocation = current;
                    } else if (m[i].maxAllocation < current) {
                        m[i].maxAllocation = current;
                    }
                } else if (cannotAddMore) {
                    // Can withdraw, cannot add → drain to 0.
                    m[i].maxAllocation = 0;
                }
                // else: normal greedy allocation at cap-based maxAllocation.
            }
        }

        // Subtract locked assets from the distributable total.
        ta -= lockedAssets;

        // Chunked greedy allocation: split distributable total into fixed-size chunks.
        uint256 chunkSize = ta / REBALANCE_CHUNKS;

        for (uint256 c; c < REBALANCE_CHUNKS; ++c) {
            uint256 chunk = (c == REBALANCE_CHUNKS - 1) ? ta - (chunkSize * (REBALANCE_CHUNKS - 1)) : chunkSize;
            if (chunk == 0) continue;

            uint256 bestRate;
            uint256 bestIdx;
            bool found;

            for (uint256 i; i < numMarkets; ++i) {
                if (idealAssets[i] + chunk > m[i].maxAllocation) continue;

                uint256 rate = m[i].irm.supplyRate(
                    m[i].simAssetsHeld + chunk,
                    m[i].debt,
                    m[i].fees
                );

                if (!found || rate > bestRate) {
                    bestRate = rate;
                    bestIdx = i;
                    found = true;
                }
            }

            if (found) {
                idealAssets[bestIdx] += chunk;
                m[bestIdx].simAssetsHeld += chunk;
            }
        }

        _fillResidualAllocation(idealAssets, m, ta);
    }

    function _fillResidualAllocation(
        uint256[] memory idealAssets,
        MarketAlloc[] memory m,
        uint256 totalAssets
    ) internal view {
        uint256 allocated;
        for (uint256 i; i < idealAssets.length; ++i) {
            allocated += idealAssets[i];
        }

        if (allocated >= totalAssets) return;

        uint256 remaining = totalAssets - allocated;
        while (remaining > 0) {
            uint256 bestRate;
            uint256 bestIdx;
            uint256 bestAmount;
            bool found;

            for (uint256 i; i < idealAssets.length; ++i) {
                if (idealAssets[i] >= m[i].maxAllocation) continue;

                uint256 capacity = m[i].maxAllocation - idealAssets[i];
                uint256 amount = capacity < remaining ? capacity : remaining;
                if (amount == 0) continue;

                uint256 rate = m[i].irm.supplyRate(
                    m[i].simAssetsHeld + amount,
                    m[i].debt,
                    m[i].fees
                );

                if (!found || rate > bestRate) {
                    bestRate = rate;
                    bestIdx = i;
                    bestAmount = amount;
                    found = true;
                }
            }

            if (!found) break;

            idealAssets[bestIdx] += bestAmount;
            m[bestIdx].simAssetsHeld += bestAmount;
            remaining -= bestAmount;
        }

        if (remaining > 0 && remaining <= idealAssets.length) {
            _allocateRoundingResidual(idealAssets, m, remaining);
        }
    }

    function _allocateRoundingResidual(
        uint256[] memory idealAssets,
        MarketAlloc[] memory m,
        uint256 remaining
    ) internal view {
        uint256 bestRate;
        uint256 bestIdx;
        bool found;

        for (uint256 i; i < idealAssets.length; ++i) {
            uint256 rate = m[i].irm.supplyRate(
                m[i].simAssetsHeld + remaining,
                m[i].debt,
                m[i].fees
            );

            if (!found || rate > bestRate) {
                bestRate = rate;
                bestIdx = i;
                found = true;
            }
        }

        if (found) {
            idealAssets[bestIdx] += remaining;
            m[bestIdx].simAssetsHeld += remaining;
        }
    }

    /// @dev Diffs ideal vs current allocations to produce deposit/withdraw
    ///      actions, and computes bounds around each market's ideal BPS.
    function _buildActionsAndBounds(
        address[] memory markets,
        uint256[] memory idealAssets,
        uint256[] memory currentAssets,
        uint256 ta,
        uint256 slippageBps,
        LendingOptimizer.ReallocationAction[] memory actions,
        LendingOptimizer.AllocationBound[] memory bounds
    ) internal pure {
        for (uint256 i; i < markets.length; ++i) {
            if (idealAssets[i] > currentAssets[i]) {
                actions[i] = LendingOptimizer.ReallocationAction(
                    IBorrowableCToken(markets[i]),
                    int256(idealAssets[i] - currentAssets[i])
                );
            } else if (currentAssets[i] > idealAssets[i]) {
                actions[i] = LendingOptimizer.ReallocationAction(
                    IBorrowableCToken(markets[i]),
                    -int256(currentAssets[i] - idealAssets[i])
                );
            } else {
                actions[i] = LendingOptimizer.ReallocationAction(
                    IBorrowableCToken(markets[i]),
                    int256(0)
                );
            }

            if (ta > 0) {
                uint256 idealBps = FixedPointMathLib.mulDiv(idealAssets[i], 10000, ta);
                bounds[i] = LendingOptimizer.AllocationBound(
                    markets[i],
                    idealBps > slippageBps ? idealBps - slippageBps : 0,
                    idealBps + slippageBps > 10000 ? 10000 : idealBps + slippageBps
                );
            } else {
                bounds[i] = LendingOptimizer.AllocationBound(markets[i], 0, 10000);
            }
        }
    }

    function _selectCapBuffer(
        ILendingOptimizer opt,
        address[] memory markets,
        address[] memory badMarkets,
        uint256[] memory currentAssets,
        uint256 totalAssets
    ) internal view returns (uint256 bufferBps) {
        for (uint256 i = CAP_BUFFER_BPS;; --i) {
            if (_hasEnoughBufferedCapacity(opt, markets, badMarkets, currentAssets, totalAssets, i)) {
                return i;
            }

            if (i == 0) return 0;
        }
    }

    function _hasEnoughBufferedCapacity(
        ILendingOptimizer opt,
        address[] memory markets,
        address[] memory badMarkets,
        uint256[] memory currentAssets,
        uint256 totalAssets,
        uint256 bufferBps
    ) internal view returns (bool) {
        uint256 capacity;

        for (uint256 i; i < markets.length; ++i) {
            MarketManagerIsolated mm = MarketManagerIsolated(address(_marketManager(markets[i])));
            bool cannotAddMore = _isBadMarket(markets[i], badMarkets)
                || _isMintPaused(markets[i], IMarketManager(address(mm)));
            bool cannotWithdraw = mm.redeemPaused() == 2;

            if (cannotWithdraw) {
                capacity += currentAssets[i];
            } else if (!cannotAddMore) {
                capacity += _bufferedMaxAllocation(opt, markets[i], totalAssets, bufferBps);
            }

            if (capacity >= totalAssets) return true;
        }

        return false;
    }

    function _bufferedMaxAllocation(
        ILendingOptimizer opt,
        address market,
        uint256 totalAssets,
        uint256 bufferBps
    ) internal view returns (uint256) {
        uint256 cap = opt.allocationCaps(market);
        uint256 buffer = bufferBps * 1e14;
        if (cap <= buffer) return 0;

        return FixedPointMathLib.mulDiv(totalAssets, cap - buffer, WAD);
    }

    function _projectCTokenState(
        IBorrowableCToken token,
        uint256 timestamp
    ) internal view returns (ProjectedCTokenState memory state) {
        uint256 targetTimestamp = timestamp < block.timestamp ? block.timestamp : timestamp;

        state.assetsHeld = _assetsHeld(token);
        uint256 cachedDebt = _outstandingDebt(token);
        uint256 cachedTotalAssets = state.assetsHeld + cachedDebt + _BASE_UNDERLYING_RESERVE;
        state.totalSupply = token.totalSupply();

        (uint256 rate, uint256 vestingEnd, uint256 lastVestingClaim,) = token.getYieldInformation();

        uint256 assetsToVest = _assetsToVestAt(rate, cachedDebt, vestingEnd, lastVestingClaim, targetTimestamp);

        if (targetTimestamp >= vestingEnd) {
            uint256 debtForRate = cachedDebt + assetsToVest;
            IDynamicIRM irm = _IRM(token);
            uint256 adjustmentRate = irm.ADJUSTMENT_RATE();

            rate = irm.borrowRate(state.assetsHeld, debtForRate);
            lastVestingClaim = vestingEnd;
            vestingEnd += (((targetTimestamp - vestingEnd) / adjustmentRate) * adjustmentRate) + adjustmentRate;

            assetsToVest += _assetsToVestAt(rate, debtForRate, vestingEnd, lastVestingClaim, targetTimestamp);
        }

        if (assetsToVest > 0) {
            uint256 protocolFee = FixedPointMathLib.mulDivUp(assetsToVest, _interestFee(token), BPS);

            if (protocolFee > 0 && state.totalSupply > 0) {
                state.protocolFeeShares = FixedPointMathLib.fullMulDivUp(
                    protocolFee,
                    state.totalSupply,
                    cachedTotalAssets + assetsToVest - protocolFee
                );
                state.totalSupply += state.protocolFeeShares;
            }

            state.debt = cachedDebt + assetsToVest;
        } else {
            state.debt = cachedDebt;
        }

        state.totalAssets = cachedTotalAssets + assetsToVest;
    }

    function _assetsToVestAt(
        uint256 rate,
        uint256 debt,
        uint256 vestingEnd,
        uint256 lastVestingClaim,
        uint256 timestamp
    ) internal pure returns (uint256) {
        if (rate == 0 || lastVestingClaim >= vestingEnd) return 0;

        uint256 accrualEnd = timestamp < vestingEnd ? timestamp : vestingEnd;
        if (accrualEnd <= lastVestingClaim) return 0;

        return FixedPointMathLib.mulDiv(rate * (accrualEnd - lastVestingClaim), debt, WAD);
    }

    function _convertProjectedToAssets(
        uint256 shares,
        uint256 totalAssets,
        uint256 totalSupply
    ) internal pure returns (uint256) {
        return totalSupply == 0
            ? shares
            : FixedPointMathLib.fullMulDiv(shares, totalAssets, totalSupply);
    }

    /// @dev Removes dust rebalance deltas — entries whose absolute value
    ///      converts to zero cToken shares (and would revert on-chain).
    ///      Maintains the zero-sum invariant by trimming the smallest
    ///      action on the opposing side. If trimming creates new dust the
    ///      direction flips and the loop continues.
    ///      Modifies `idealAssets` in place.
    /// @return hasActions True if at least one non-zero delta remains.
    function _removeDustActions(
        address[] memory markets,
        uint256[] memory idealAssets,
        uint256[] memory currentAssets
    ) internal view returns (bool hasActions) {
        uint256 numMarkets = markets.length;

        // Phase 1: Zero dust entries and compute signed imbalance.
        // Positive imbalance → excess deposits → must reduce deposits.
        // Negative imbalance → excess withdrawals → must reduce withdrawals.
        int256 imbalance;

        for (uint256 i; i < numMarkets; ++i) {
            if (idealAssets[i] == currentAssets[i]) continue;

            bool isDeposit = idealAssets[i] > currentAssets[i];
            uint256 absDelta = isDeposit
                ? idealAssets[i] - currentAssets[i]
                : currentAssets[i] - idealAssets[i];

            if (IBorrowableCToken(markets[i]).convertToShares(absDelta) == 0) {
                imbalance += isDeposit
                    ? -int256(absDelta)
                    : int256(absDelta);
                idealAssets[i] = currentAssets[i];
            }
        }

        // Phase 2: Rebalance by trimming the smallest entry on the
        // over-represented side. If trimming creates new dust the
        // excess flips direction and the loop continues.
        if (imbalance != 0) {
            uint256 excess = imbalance > 0
                ? uint256(imbalance)
                : uint256(-imbalance);
            bool reduceDeposits = imbalance > 0;

            while (excess > 0) {
                uint256 bestIdx;
                uint256 bestAmt = type(uint256).max;
                bool found;

                for (uint256 i; i < numMarkets; ++i) {
                    if (idealAssets[i] == currentAssets[i]) continue;

                    bool isDeposit = idealAssets[i] > currentAssets[i];
                    if (isDeposit != reduceDeposits) continue;

                    uint256 amt = isDeposit
                        ? idealAssets[i] - currentAssets[i]
                        : currentAssets[i] - idealAssets[i];

                    if (amt < bestAmt) {
                        bestAmt = amt;
                        bestIdx = i;
                        found = true;
                    }
                }

                if (!found) {
                    // Cannot balance — zero all remaining actions.
                    for (uint256 i; i < numMarkets; ++i) {
                        idealAssets[i] = currentAssets[i];
                    }
                    break;
                }

                if (excess >= bestAmt) {
                    // Zero this entry entirely.
                    idealAssets[bestIdx] = currentAssets[bestIdx];
                    excess -= bestAmt;
                } else {
                    // Partially reduce.
                    if (reduceDeposits) {
                        idealAssets[bestIdx] -= excess;
                    } else {
                        idealAssets[bestIdx] += excess;
                    }

                    // Check if the remainder is now dust.
                    uint256 remaining = reduceDeposits
                        ? idealAssets[bestIdx] - currentAssets[bestIdx]
                        : currentAssets[bestIdx] - idealAssets[bestIdx];

                    if (IBorrowableCToken(markets[bestIdx]).convertToShares(remaining) == 0) {
                        // Over-reduced: remainder is dust. Zero it
                        // and flip direction with the leftover.
                        idealAssets[bestIdx] = currentAssets[bestIdx];
                        excess = remaining;
                        reduceDeposits = !reduceDeposits;
                    } else {
                        excess = 0;
                    }
                }
            }
        }

        // Phase 3: Return true if any non-zero delta remains.
        for (uint256 i; i < numMarkets; ++i) {
            if (idealAssets[i] != currentAssets[i]) return true;
        }
        return false;
    }

    /// @dev Returns true if `market` is in the `badMarkets` array.
    function _isBadMarket(
        address market,
        address[] memory badMarkets
    ) internal pure returns (bool) {
        for (uint256 i; i < badMarkets.length; ++i) {
            if (badMarkets[i] == market) return true;
        }
        return false;
    }

    function _balanceOf(
        address token,
        address account
    ) internal view returns (uint256 result) {
        result = ICToken(token).balanceOf(account);
    }

    function _assetsHeld(
        IBorrowableCToken token
    ) internal view returns (uint256 result) {
        result = token.assetsHeld();
    }

    /// @dev Returns true if minting is paused for `cToken`.
    function _isMintPaused(
        address cToken,
        IMarketManager mm
    ) internal view returns (bool mp) {
        (mp,,) = mm.actionsPaused(cToken);
    }

    /// @dev Convenience overload — resolves market manager from cToken.
    function _isMintPaused(address cToken) internal view returns (bool mp) {
        mp = _isMintPaused(cToken, _marketManager(cToken));
    }

    function _marketManager(
        address cToken
    ) internal view returns (IMarketManager mm) {
        mm = ICToken(cToken).marketManager();
    }

    function _IRM(
        IBorrowableCToken token
    ) internal view returns (IDynamicIRM result) {
        result = token.IRM();
    }

    function _outstandingDebt(
        IBorrowableCToken token
    ) internal view returns (uint256 result) {
        result = token.marketOutstandingDebt();
    }

    function _interestFee(
        IBorrowableCToken token
    ) internal view returns (uint256 result) {
        result = token.interestFee();
    }

    /// @dev Checks whether a collateral asset's oracle feed is stale.
    ///      Compares the time since the last oracle update against the
    ///      feed's configured heartbeat scaled by `multiplierBps`.
    /// @param collateralAsset The underlying collateral asset address.
    /// @param multiplierBps The staleness multiplier in BPS (e.g., 15000 = 1.5x).
    /// @return True if the oracle feed is stale.
    function _isOracleStale(
        address collateralAsset,
        uint256 multiplierBps
    ) internal view returns (bool) {
        address[] memory adaptors = ORACLE_MANAGER.getPricingAdaptors(
            collateralAsset
        );

        (, address aggregatorProxy,, uint24 heartbeat) =
            IChainlinkAdaptor(adaptors[0]).assetConfig(collateralAsset, true);

        (,,, uint256 updatedAt,) = IChainlink(aggregatorProxy).latestRoundData();

        unchecked {
            return block.timestamp - updatedAt >
                uint256(heartbeat) * multiplierBps / 10000;
        }
    }

    /// @dev Checks whether a collateral asset's adjusted oracle price is zero,
    ///      which indicates a PriceGuard floor breach in Curvance adaptors.
    function _isOraclePriceZero(
        address collateralAsset
    ) internal view returns (bool) {
        address[] memory adaptors = ORACLE_MANAGER.getPricingAdaptors(
            collateralAsset
        );

        IOracleAdaptor.PricingResult memory result = IOracleAdaptor(adaptors[0])
            .getPrice(
                collateralAsset,
                true,
                true
            );

        return result.price == 0;
    }
}
