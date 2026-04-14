// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { WAD } from "contracts/libraries/ConstantsLib.sol";

import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { IDynamicIRM } from "contracts/interfaces/IDynamicIRM.sol";
import { ILendingOptimizer } from "contracts/interfaces/ILendingOptimizer.sol";
import { IOracleAdaptor } from "contracts/interfaces/IOracleAdaptor.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";
import { ICombinedAggregator } from "contracts/interfaces/ICombinedAggregator.sol";
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

    /// @notice Config for monitoring a collateral asset's price guard.
    /// @param cToken The collateral cToken in the isolated market
    ///               (the non-optimizer side, e.g., earnAUSD cToken).
    /// @param guardType 0 = no guard, 1 = adaptor-level, 2 = aggregator-level.
    struct CollateralGuardConfig {
        address cToken;
        uint256 guardType;
    }

    /// ERRORS ///

    error OptimizerReader__Unauthorized();
    error OptimizerReader__InvalidMultiplier();
    error OptimizerReader__GuardConfigAlreadyExists();
    error OptimizerReader__GuardConfigDoesNotExist();

    /// EVENTS ///

    event GuardConfigAdded(address indexed cToken, uint256 guardType);
    event GuardConfigRemoved(address indexed cToken);
    event StalenessMultiplierUpdated(uint256 oldMultiplier, uint256 newMultiplier);

    /// IMMUTABLES ///

    /// @notice The OracleManager address.
    IOracleManager public immutable ORACLE_MANAGER;

    /// @notice Curvance Protocol Central Registry, used for permissioning.
    ICentralRegistry public immutable centralRegistry;

    /// STORAGE ///

    CollateralGuardConfig[] public guardConfigs;

    /// @notice Collateral cToken => index in guardConfigs.
    /// @dev Maps a collateral cToken to its position in guardConfigs.
    mapping(address => uint256) internal _guardIndex;
    mapping(address => bool) internal _hasGuardConfig;

    /// @notice Multiplier in BPS applied to each oracle's configured heartbeat
    ///         to determine the staleness threshold. 0 = staleness check disabled.
    ///         e.g., 15000 (1.5x) means a feed with a 1h heartbeat is stale after 1.5h.
    uint256 public stalenessMultiplierBps;

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry _centralRegistry,
        CollateralGuardConfig[] memory configs,
        uint256 _stalenessMultiplier
    ) {
        centralRegistry = _centralRegistry;
        ORACLE_MANAGER = IOracleManager(_centralRegistry.oracleManager());
        stalenessMultiplierBps = _stalenessMultiplier;

        for (uint256 i; i < configs.length; ++i) {
            guardConfigs.push(configs[i]);
            _guardIndex[configs[i].cToken] = i;
            _hasGuardConfig[configs[i].cToken] = true;
        }
    }

    /// PERMISSIONED FUNCTIONS ///

    /// @notice Adds a collateral guard config for `cToken`.
    /// @dev Only callable by an address with elevated permissions.
    function addGuardConfig(
        address cToken,
        uint256 guardType
    ) external {
        if (!centralRegistry.hasElevatedPermissions(msg.sender)) {
            revert OptimizerReader__Unauthorized();
        }
        if (_hasGuardConfig[cToken]) {
            revert OptimizerReader__GuardConfigAlreadyExists();
        }

        _guardIndex[cToken] = guardConfigs.length;
        _hasGuardConfig[cToken] = true;
        guardConfigs.push(
            CollateralGuardConfig({ cToken: cToken, guardType: guardType })
        );

        emit GuardConfigAdded(cToken, guardType);
    }

    /// @notice Removes the collateral guard config for `cToken`.
    /// @dev Only callable by an address with elevated permissions.
    ///      Uses swap-and-pop to keep the array compact.
    function removeGuardConfig(address cToken) external {
        if (!centralRegistry.hasElevatedPermissions(msg.sender)) {
            revert OptimizerReader__Unauthorized();
        }
        if (!_hasGuardConfig[cToken]) {
            revert OptimizerReader__GuardConfigDoesNotExist();
        }

        uint256 idx = _guardIndex[cToken];
        uint256 lastIdx = guardConfigs.length - 1;

        if (idx != lastIdx) {
            CollateralGuardConfig memory last = guardConfigs[lastIdx];
            guardConfigs[idx] = last;
            _guardIndex[last.cToken] = idx;
        }

        guardConfigs.pop();
        delete _guardIndex[cToken];
        delete _hasGuardConfig[cToken];

        emit GuardConfigRemoved(cToken);
    }

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
    ///         unsafe due to a collateral price guard breach or a stale
    ///         oracle feed.
    /// @dev For each approved market in the optimizer:
    ///      1. Checks if the collateral's oracle feed is stale (if
    ///         stalenessMultiplier > 0).
    ///      2. Checks if the collateral's price has breached its
    ///         configured price guard floor (if a guard config exists).
    ///      A market is flagged if either condition is met.
    /// @param optimizer The LendingOptimizer address.
    /// @return bad Array of optimizer cToken addresses whose
    ///         collateral has a stale oracle or breached price guard.
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

                address collateralCToken = listed[j];
                address collateralAsset = ICToken(collateralCToken).asset();

                // Check oracle staleness (applies to all markets).
                if (_stalenessMultiplierBps > 0 &&
                    _isOracleStale(collateralAsset, _stalenessMultiplierBps)
                ) {
                    flagged = true;
                    break;
                }

                // Check price guard breach (only if configured).
                if (!_hasGuardConfig[collateralCToken]) continue;

                CollateralGuardConfig storage cfg =
                    guardConfigs[_guardIndex[collateralCToken]];

                // guardType: 0 = none, 1 = adaptor, 2 = aggregator.
                if (cfg.guardType == 0) continue;

                if (_isGuardBreached(collateralAsset, cfg.guardType)) {
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
    ) external returns (OptimizerMarketData[] memory data) {
        uint256 len = optimizers.length;
        data = new OptimizerMarketData[](len);

        for (uint256 i; i < len; ++i) {
            ILendingOptimizer opt = ILendingOptimizer(optimizers[i]);

            data[i]._address = optimizers[i];
            data[i].asset = opt.asset();
            data[i].totalAssets = opt.totalAssets();
            data[i].sharePrice = opt.exchangeRateUpdated();
            data[i].performanceFee = opt.fee();

            address[] memory cTokens = opt.getApprovedMarkets();
            uint256 l = cTokens.length;
            data[i].markets = new OptimizerCTokenData[](l);

            for (uint256 j; j < l; ++j) {
                IBorrowableCToken cToken = IBorrowableCToken(cTokens[j]);
                uint256 allocated = cToken.convertToAssets(
                    _balanceOf(address(cToken), optimizers[i])
                );
                uint256 liquidity = _assetsHeld(cToken);

                data[i].markets[j] = OptimizerCTokenData({
                    _address: cTokens[j],
                    allocatedAssets: allocated,
                    liquidity: liquidity
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
    ) external view returns (uint256 apy) {
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
        address[] memory markets = ILendingOptimizer(optimizer).getApprovedMarkets();

        if (markets.length == 0) return (actions, bounds);

        // Automatically exclude bad markets from allocation.
        address[] memory badMarkets = this.isBad(optimizer);

        uint256[] memory idealAssets;
        uint256[] memory currentAssets;
        (idealAssets, currentAssets,) =
            _computeIdealAllocation(optimizer, markets, badMarkets);

        // Remove dust actions that would revert at the cToken level
        // (convertToShares == 0) and rebalance to maintain zero-sum.
        // Returns empty arrays if no actionable rebalance remains.
        if (!_removeDustActions(markets, idealAssets, currentAssets)) {
            return (actions, bounds);
        }

        actions = new LendingOptimizer.ReallocationAction[](markets.length);
        bounds = new LendingOptimizer.AllocationBound[](markets.length);

        uint256 ta = ILendingOptimizer(optimizer).totalAssets();
        _buildActionsAndBounds(markets, idealAssets, currentAssets, ta, slippageBps, actions, bounds);
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
        address[] memory badMarkets
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
                uint256 ca = ct.convertToAssets(
                    _balanceOf(address(ct), optimizer)
                );
                currentAssets[i] = ca;
                ta += ca;

                uint256 assetsHeld = _assetsHeld(ct);
                m[i].simAssetsHeld = assetsHeld > ca
                    ? assetsHeld - ca
                    : 0;
                m[i].debt = _outstandingDebt(ct);
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
            for (uint256 i; i < numMarkets; ++i) {
                uint256 current = currentAssets[i];
                m[i].maxAllocation = FixedPointMathLib.mulDiv(
                    ta, opt.allocationCaps(markets[i]), WAD
                );

                // Force bad markets to zero allocation.
                if (_isBadMarket(markets[i], badMarkets)) {
                    m[i].maxAllocation = 0;
                    continue;
                }

                MarketManagerIsolated mm = MarketManagerIsolated(address(_marketManager(markets[i])));

                if (mm.redeemPaused() == 2) {
                    m[i].simAssetsHeld += current;
                    lockedAssets += current;
                    idealAssets[i] = current;
                    if (_isMintPaused(markets[i], IMarketManager(address(mm)))) {
                        m[i].maxAllocation = current;
                    } else if (m[i].maxAllocation < current) {
                        m[i].maxAllocation = current;
                    }
                } else {
                    if (_isMintPaused(markets[i], IMarketManager(address(mm)))) {
                        m[i].maxAllocation = 0;
                    }
                }
            }
        }

        // Subtract locked assets from the distributable total.
        ta -= lockedAssets;

        // Chunked greedy allocation: split distributable total into 20 chunks.
        uint256 chunkSize = ta / 20;

        for (uint256 c; c < 20; ++c) {
            uint256 chunk = (c == 19) ? ta - (chunkSize * 19) : chunkSize;
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

        return block.timestamp - updatedAt >
            uint256(heartbeat) * multiplierBps / 10000;
    }

    /// @dev Checks whether a collateral asset's price has breached its
    ///      price guard floor.
    /// @param collateralAsset The underlying collateral asset address.
    /// @param guardType 1 = adaptor-level guard, 2 = aggregator-level guard.
    /// @return True if the price guard has been breached.
    function _isGuardBreached(
        address collateralAsset,
        uint256 guardType
    ) internal view returns (bool) {
        // Get the pricing adaptor for this asset.
        address[] memory adaptors = ORACLE_MANAGER.getPricingAdaptors(
            collateralAsset
        );
        if (adaptors.length == 0) return false;

        address adaptor = adaptors[0];

        uint40 timestampStart;
        uint40 ips;
        uint88 basePrice;
        uint88 minPrice;

        if (guardType == 1) {
            // Adaptor-level price guard.
            IOracleAdaptor.PriceGuard memory pg = IOracleAdaptor(adaptor)
                .getPriceGuard(collateralAsset, true);
            timestampStart = pg.timestampStart;
            ips = pg.ips;
            basePrice = pg.basePrice;
            minPrice = pg.minPrice;
        } else {
            // Aggregator-level price guard (CombinedAggregator).
            // Get the aggregator proxy from the adaptor's asset config.
            (, address aggregatorProxy,,) = IChainlinkAdaptor(adaptor)
                .assetConfig(collateralAsset, true);
            (timestampStart, ips, basePrice, minPrice) =
                ICombinedAggregator(aggregatorProxy).pg();
        }

        // No guard configured if basePrice is 0.
        if (basePrice == 0) return false;

        // Compute effective minimum.
        uint256 effectiveMin;
        if (ips == 0) {
            // Static guard.
            effectiveMin = minPrice;
        } else {
            // Dynamic guard
            uint256 timePassed = block.timestamp - timestampStart;
            effectiveMin = FixedPointMathLib.fullMulDiv(
                minPrice,
                (timePassed * uint256(ips)) + WAD,
                WAD
            );
        }

        // Get current price.
        (uint256 price,) = ORACLE_MANAGER.getPrice(
            collateralAsset, true, true
        );

        return price <= effectiveMin;
    }
}
