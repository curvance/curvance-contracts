// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {
    MarketManagerIsolated
} from "contracts/market/isolated/MarketManagerIsolated.sol";

import {BPS, WAD} from "contracts/libraries/ConstantsLib.sol";

import {
    FixedPointMathLib
} from "contracts/libraries/external/FixedPointMathLib.sol";

import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {ICToken} from "contracts/interfaces/ICToken.sol";
import {IBorrowableCToken} from "contracts/interfaces/IBorrowableCToken.sol";
import {IMarketManager} from "contracts/interfaces/IMarketManager.sol";
import {IDynamicIRM} from "contracts/interfaces/IDynamicIRM.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {ILendingOptimizer} from "contracts/interfaces/ILendingOptimizer.sol";
import {IOracleAdaptor} from "contracts/interfaces/IOracleAdaptor.sol";
import {IOracleManager} from "contracts/interfaces/IOracleManager.sol";
import {
    IChainlink
} from "contracts/interfaces/external/chainlink/IChainlink.sol";
import {
    LendingOptimizer
} from "contracts/market/optimizer/LendingOptimizer.sol";

interface IChainlinkAdaptor {
    function assetConfig(address asset, bool inUSD)
        external
        view
        returns (
            bool isConfigured,
            address aggregatorProxy,
            uint8 decimals,
            uint24 heartbeat
        );
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
        /// @notice Optimizer high-watermark exchange rate used for performance fees.
        uint256 exchangeRateHighWatermark;
        /// @notice Performance fee in BPS.
        uint256 performanceFee;
        /// @notice Number of approved cToken markets for this optimizer.
        uint256 numApprovedMarkets;
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

    struct MarketIncentiveAPYBps {
        /// @notice The cToken market receiving the incentive APY.
        address cToken;
        /// @notice Annual incentive APY in BPS (1000 = 10%, max accepted).
        uint256 incentiveAPYBps;
    }

    /// @dev Internal struct to pack per-market allocation state into a single
    ///      array, avoiding stack-too-deep in _computeIdealAllocation.
    struct MarketAlloc {
        uint256 simAssetsHeld;
        uint256 debt;
        uint256 fees;
        uint256 maxAllocation;
        uint256 hardMaxAllocation;
        uint256 incentiveAPY;
        IDynamicIRM irm;
        bool canWithdraw;
        bool canDeposit;
        bool isBad;
    }

    struct MoveCandidate {
        uint256 sourceIdx;
        uint256 destIdx;
        uint256 amount;
        uint256 score;
        bool found;
    }

    /// ERRORS ///

    error OptimizerReader__Unauthorized();
    error OptimizerReader__InvalidMultiplier();
    error OptimizerReader__InvalidRebalanceChunks();
    error OptimizerReader__InvalidIncentiveData();
    error OptimizerReader__InvalidIncentiveMarket(address cToken);
    error OptimizerReader__InvalidIncentiveAPYBps(
        address cToken, uint256 incentiveAPYBps
    );
    error OptimizerReader__DuplicateIncentiveMarket(address cToken);

    /// EVENTS ///

    event StalenessMultiplierUpdated(
        uint256 oldMultiplier, uint256 newMultiplier
    );

    /// CONSTANTS ///

    uint256 internal constant SECONDS_PER_YEAR = 31_536_000;

    /// @notice Minimum total rebalance value in USD (WAD) below which
    ///         optimalRebalance returns empty arrays. 1e18 = $1.
    uint256 public constant USD_THRESHOLD = 100e18;

    /// @notice Default cap headroom used by optimalRebalance planning.
    uint256 public constant CAP_BUFFER_BPS = 5;
    /// @notice Tiny asset-unit headroom for hard-cap planner moves.
    uint256 internal constant HARD_CAP_ROUNDING_BUFFER = 4;

    /// @notice Maximum accepted off-chain incentive APY, in BPS. 1000 = 10%.
    uint256 public constant MAX_INCENTIVE_APY_BPS = 1_000;

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
    function multiIsBadCheck(address[] calldata optimizers)
        external
        view
        returns (address[][] memory badOptimizers)
    {
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
    function isBad(address optimizer)
        external
        view
        returns (address[] memory bad)
    {
        address[] memory markets =
            ILendingOptimizer(optimizer).getApprovedMarkets();
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
                if (
                    _stalenessMultiplierBps > 0
                        && _isOracleStale(
                            collateralAsset, _stalenessMultiplierBps
                        )
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
    function getOptimizerMarketData(address[] calldata optimizers)
        external
        returns (OptimizerMarketData[] memory data)
    {
        uint256 len = optimizers.length;
        data = new OptimizerMarketData[](len);

        for (uint256 i; i < len; ++i) {
            ILendingOptimizer opt = ILendingOptimizer(optimizers[i]);

            data[i]._address = optimizers[i];
            data[i].asset = opt.asset();
            data[i].sharePrice = opt.exchangeRateUpdated();
            data[i].totalAssets = opt.totalAssets();
            data[i].exchangeRateHighWatermark = opt.exchangeRateHighWatermark();
            data[i].performanceFee = opt.fee();
            data[i].apy = _getOptimizerAPY(optimizers[i]);

            address[] memory cTokens = opt.getApprovedMarkets();
            uint256 l = cTokens.length;
            data[i].numApprovedMarkets = l;
            data[i].markets = new OptimizerCTokenData[](l);

            for (uint256 j; j < l; ++j) {
                IBorrowableCToken cToken = IBorrowableCToken(cTokens[j]);
                uint256 allocated = cToken.convertToAssets(
                    _balanceOf(address(cToken), optimizers[i])
                );
                uint256 liquidity = _assetsHeld(cToken);
                uint256 allocationCap = opt.allocationCaps(cTokens[j]);
                uint256 maxAllocation = FixedPointMathLib.mulDiv(
                    data[i].totalAssets, allocationCap, WAD
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
    ) external returns (OptimizerUserData[] memory data) {
        uint256 len = optimizers.length;
        data = new OptimizerUserData[](len);

        for (uint256 i; i < len; ++i) {
            ILendingOptimizer opt = ILendingOptimizer(optimizers[i]);
            opt.accrueIfNeeded();
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
    function getOptimizerAPY(address optimizer) public returns (uint256 apy) {
        ILendingOptimizer(optimizer).accrueIfNeeded();
        apy = _getOptimizerAPY(optimizer);
    }

    function _getOptimizerAPY(address optimizer)
        internal
        view
        returns (uint256 apy)
    {
        ILendingOptimizer opt = ILendingOptimizer(optimizer);
        uint256 ta = opt.totalAssets();
        if (ta == 0) return 0;

        address[] memory markets = opt.getApprovedMarkets();
        uint256 weightedRate;

        for (uint256 i; i < markets.length; ++i) {
            IBorrowableCToken ct = IBorrowableCToken(markets[i]);
            uint256 allocated =
                ct.convertToAssets(_balanceOf(address(ct), optimizer));

            uint256 rate = _IRM(ct)
                .supplyRate(
                    _assetsHeld(ct), _outstandingDebt(ct), _interestFee(ct)
                );

            weightedRate += FixedPointMathLib.mulDiv(allocated, rate, ta);
        }

        apy = weightedRate * SECONDS_PER_YEAR;
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
    /// @param rebalanceChunks Number of chunks used by the greedy allocation.
    /// @return actions The rebalance actions array matching approvedCTokensList order,
    ///                 or empty if no rebalance is needed.
    /// @return bounds The allocation bounds array matching approvedCTokensList order,
    ///                or empty if no rebalance is needed.
    function optimalRebalance(
        address optimizer,
        uint256 slippageBps,
        uint256 rebalanceChunks
    )
        external
        returns (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        )
    {
        if (rebalanceChunks == 0) {
            revert OptimizerReader__InvalidRebalanceChunks();
        }

        ILendingOptimizer(optimizer).accrueIfNeeded();
        address[] memory markets =
            ILendingOptimizer(optimizer).getApprovedMarkets();
        return _optimalRebalance(
            optimizer, slippageBps, rebalanceChunks, markets, new uint256[](0)
        );
    }

    /// @notice Computes optimal rebalance actions while adding address-tagged
    ///         off-chain incentive APYs to each market's marginal supply score.
    /// @dev Incentives may be provided in any order. Each `cToken` must be an
    ///      approved market for `optimizer`, and duplicate cTokens revert.
    ///      Missing approved markets receive zero incentive APY. Values are
    ///      annual APYs in BPS and must not exceed MAX_INCENTIVE_APY_BPS.
    /// @param optimizer The LendingOptimizer address.
    /// @param slippageBps Tolerance in BPS around each market's ideal allocation.
    /// @param rebalanceChunks Number of chunks used by the greedy allocation.
    /// @param marketIncentives Annual incentive APYs in BPS, tagged by cToken.
    /// @return actions The rebalance actions array matching approvedCTokensList order,
    ///                 or empty if no rebalance is needed.
    /// @return bounds The allocation bounds array matching approvedCTokensList order,
    ///                or empty if no rebalance is needed.
    function optimalRebalanceWithIncentives(
        address optimizer,
        uint256 slippageBps,
        uint256 rebalanceChunks,
        MarketIncentiveAPYBps[] calldata marketIncentives
    )
        external
        returns (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        )
    {
        if (rebalanceChunks == 0) {
            revert OptimizerReader__InvalidRebalanceChunks();
        }

        ILendingOptimizer(optimizer).accrueIfNeeded();
        address[] memory markets =
            ILendingOptimizer(optimizer).getApprovedMarkets();
        uint256[] memory marketIncentiveAPYsBps =
            _alignTaggedIncentives(markets, marketIncentives);

        return _optimalRebalance(
            optimizer,
            slippageBps,
            rebalanceChunks,
            markets,
            marketIncentiveAPYsBps
        );
    }

    function _optimalRebalance(
        address optimizer,
        uint256 slippageBps,
        uint256 rebalanceChunks,
        address[] memory markets,
        uint256[] memory marketIncentiveAPYsBps
    )
        internal
        view
        returns (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        )
    {
        if (
            marketIncentiveAPYsBps.length != 0
                && marketIncentiveAPYsBps.length != markets.length
        ) {
            revert OptimizerReader__InvalidIncentiveData();
        }

        if (markets.length == 0) return (actions, bounds);

        // Automatically exclude bad markets from allocation.
        address[] memory badMarkets = this.isBad(optimizer);

        uint256[] memory idealAssets;
        uint256[] memory currentAssets;
        uint256 totalAssets;
        (idealAssets, currentAssets,) = _computeIdealAllocation(
            optimizer,
            markets,
            badMarkets,
            rebalanceChunks,
            marketIncentiveAPYsBps
        );
        for (uint256 i; i < currentAssets.length; ++i) {
            totalAssets += currentAssets[i];
        }

        if (!_fullyAllocated(idealAssets, totalAssets)) {
            return (actions, bounds);
        }

        // Remove dust actions that would revert at the cToken level
        // (convertToShares == 0) and rebalance to maintain zero-sum.
        // Returns empty arrays if no actionable rebalance remains.
        if (!_removeDustActions(markets, idealAssets, currentAssets)) {
            return (actions, bounds);
        }

        (actions, bounds) = _buildValidatedPlan(
            optimizer, markets, idealAssets, currentAssets, slippageBps
        );
        if (actions.length == 0) return (actions, bounds);

        if (badMarkets.length == 0) {
            address underlying = ILendingOptimizer(optimizer).asset();
            (uint256 price, uint256 errorCode) =
                ORACLE_MANAGER.getPrice(underlying, true, true);

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

    function _alignTaggedIncentives(
        address[] memory markets,
        MarketIncentiveAPYBps[] calldata marketIncentives
    ) internal pure returns (uint256[] memory marketIncentiveAPYsBps) {
        marketIncentiveAPYsBps = new uint256[](markets.length);
        bool[] memory seen = new bool[](markets.length);

        for (uint256 i; i < marketIncentives.length; ++i) {
            address cToken = marketIncentives[i].cToken;
            uint256 incentiveAPYBps = marketIncentives[i].incentiveAPYBps;
            bool found;

            for (uint256 j; j < markets.length; ++j) {
                if (cToken != markets[j]) continue;

                if (seen[j]) {
                    revert OptimizerReader__DuplicateIncentiveMarket(cToken);
                }

                if (incentiveAPYBps > MAX_INCENTIVE_APY_BPS) {
                    revert OptimizerReader__InvalidIncentiveAPYBps(
                        cToken, incentiveAPYBps
                    );
                }

                seen[j] = true;
                marketIncentiveAPYsBps[j] = incentiveAPYBps;
                found = true;
                break;
            }

            if (!found) {
                revert OptimizerReader__InvalidIncentiveMarket(cToken);
            }
        }
    }

    /// @dev Chunked greedy rebalancing: starts from current allocations and
    ///      applies executable source-to-destination moves in memory.
    ///      Normal moves require the destination post-move APY to be strictly
    ///      greater than the source post-move APY. Bad-market and cap-repair
    ///      moves are forced safety paths and can use hard cap room.
    ///      Separated from the public functions to avoid stack-too-deep.
    function _computeIdealAllocation(
        address optimizer,
        address[] memory markets,
        address[] memory badMarkets,
        uint256 rebalanceChunks,
        uint256[] memory marketIncentiveAPYsBps
    )
        internal
        view
        returns (
            uint256[] memory idealAssets,
            uint256[] memory currentAssets,
            MarketAlloc[] memory m
        )
    {
        uint256 numMarkets = markets.length;
        idealAssets = new uint256[](numMarkets);
        currentAssets = new uint256[](numMarkets);
        m = new MarketAlloc[](numMarkets);

        // First pass: snapshot per-market state and compute total assets.
        uint256 ta = _snapshotMarketAllocations(
            optimizer,
            markets,
            marketIncentiveAPYsBps,
            idealAssets,
            currentAssets,
            m
        );

        if (ta == 0) return (idealAssets, currentAssets, m);

        // Second pass: compute soft/hard caps and market eligibility flags.
        {
            ILendingOptimizer opt = ILendingOptimizer(optimizer);
            uint256 bufferBps =
                _selectCapBuffer(opt, markets, badMarkets, currentAssets, ta);
            for (uint256 i; i < numMarkets; ++i) {
                m[i].maxAllocation =
                    _bufferedMaxAllocation(opt, markets[i], ta, bufferBps);
                m[i].hardMaxAllocation = _maxAllocation(opt, markets[i], ta);
                m[i].isBad = _isBadMarket(markets[i], badMarkets);

                MarketManagerIsolated mm =
                    MarketManagerIsolated(address(_marketManager(markets[i])));
                // Two orthogonal constraints drive allocation policy:
                //  - cannotAddMore: bad, mint-paused, or redeem-paused —
                //    no new deposits into non-redeemable markets.
                //  - cannotWithdraw: redeem-paused — must keep current position.
                bool canRedeem = mm.redeemPaused() != 2;
                m[i].canWithdraw = canRedeem;
                m[i].canDeposit = canRedeem && !m[i].isBad
                    && !_isMintPaused(markets[i], IMarketManager(address(mm)));

                // Redeem-paused positions are locked and frozen at current.
                // Can withdraw, cannot add -> drain to 0.
                // else: normal greedy allocation at cap-based maxAllocation.
            }
        }

        uint256 chunkSize = ta / rebalanceChunks;
        if (chunkSize == 0) chunkSize = 1;
        uint256 maxIterations = rebalanceChunks * numMarkets * 2;

        _applyForcedMoves(idealAssets, m, chunkSize, maxIterations, true);
        _applyForcedMoves(idealAssets, m, chunkSize, maxIterations, false);
        _applyNormalMoves(idealAssets, m, chunkSize, maxIterations);

        if (!_allWithinHardCaps(idealAssets, m)) {
            for (uint256 i; i < numMarkets; ++i) {
                idealAssets[i] = currentAssets[i];
            }
        }
    }

    function _snapshotMarketAllocations(
        address optimizer,
        address[] memory markets,
        uint256[] memory marketIncentiveAPYsBps,
        uint256[] memory idealAssets,
        uint256[] memory currentAssets,
        MarketAlloc[] memory m
    ) internal view returns (uint256 ta) {
        bool hasIncentives =
            marketIncentiveAPYsBps.length != 0;

        for (uint256 i; i < markets.length; ++i) {
            IBorrowableCToken ct = IBorrowableCToken(markets[i]);
            uint256 ca = ct.convertToAssets(_balanceOf(address(ct), optimizer));
            currentAssets[i] = ca;
            idealAssets[i] = ca;
            ta += ca;

            m[i].simAssetsHeld = _assetsHeld(ct);
            m[i].debt = _outstandingDebt(ct);
            m[i].fees = _interestFee(ct);
            m[i].irm = _IRM(ct);
            if (hasIncentives) {
                m[i].incentiveAPY = FixedPointMathLib.mulDiv(
                    marketIncentiveAPYsBps[i], WAD, BPS
                );
            }
        }
    }

    function _applyForcedMoves(
        uint256[] memory idealAssets,
        MarketAlloc[] memory m,
        uint256 chunkSize,
        uint256 maxIterations,
        bool badOnly
    ) internal view {
        for (uint256 i; i < maxIterations; ++i) {
            MoveCandidate memory move_ =
                _bestForcedMove(idealAssets, m, chunkSize, badOnly);
            if (!move_.found) return;

            _applyMove(idealAssets, m, move_);
        }
    }

    function _applyNormalMoves(
        uint256[] memory idealAssets,
        MarketAlloc[] memory m,
        uint256 chunkSize,
        uint256 maxIterations
    ) internal view {
        for (uint256 i; i < maxIterations; ++i) {
            MoveCandidate memory move_ =
                _bestNormalMove(idealAssets, m, chunkSize);
            if (!move_.found) return;

            _applyMove(idealAssets, m, move_);
        }
    }

    function _bestForcedMove(
        uint256[] memory idealAssets,
        MarketAlloc[] memory m,
        uint256 chunkSize,
        bool badOnly
    ) internal view returns (MoveCandidate memory best) {
        uint256 numMarkets = idealAssets.length;

        for (uint256 i; i < numMarkets; ++i) {
            uint256 sourceRoom = _forcedSourceRoom(idealAssets, m, i, badOnly);
            if (sourceRoom == 0) continue;

            for (uint256 j; j < numMarkets; ++j) {
                if (i == j) continue;

                uint256 amount = _moveAmount(
                    chunkSize,
                    sourceRoom,
                    _destinationRoom(idealAssets, m, j, true)
                );
                if (amount == 0) continue;

                uint256 score =
                    _allocationScore(m[j], m[j].simAssetsHeld + amount);

                if (!best.found || score > best.score) {
                    best = MoveCandidate(i, j, amount, score, true);
                }
            }
        }
    }

    function _bestNormalMove(
        uint256[] memory idealAssets,
        MarketAlloc[] memory m,
        uint256 chunkSize
    ) internal view returns (MoveCandidate memory best) {
        uint256 numMarkets = idealAssets.length;

        for (uint256 i; i < numMarkets; ++i) {
            uint256 sourceRoom = _normalSourceRoom(idealAssets, m, i);
            if (sourceRoom == 0) continue;

            for (uint256 j; j < numMarkets; ++j) {
                if (i == j) continue;

                uint256 amount = _moveAmount(
                    chunkSize,
                    sourceRoom,
                    _destinationRoom(idealAssets, m, j, false)
                );
                if (amount == 0) continue;

                uint256 sourceScoreAfter =
                    _allocationScore(m[i], m[i].simAssetsHeld - amount);
                uint256 destScoreAfter =
                    _allocationScore(m[j], m[j].simAssetsHeld + amount);

                if (destScoreAfter <= sourceScoreAfter) continue;

                uint256 spread = destScoreAfter - sourceScoreAfter;
                if (!best.found || spread > best.score) {
                    best = MoveCandidate(i, j, amount, spread, true);
                }
            }
        }
    }

    function _forcedSourceRoom(
        uint256[] memory idealAssets,
        MarketAlloc[] memory m,
        uint256 i,
        bool badOnly
    ) internal pure returns (uint256) {
        if (!m[i].canWithdraw) return 0;

        if (badOnly) {
            if (!m[i].isBad) return 0;
            return _min(idealAssets[i], m[i].simAssetsHeld);
        }

        if (m[i].isBad || idealAssets[i] <= m[i].hardMaxAllocation) {
            return 0;
        }

        uint256 hardRepairTarget = m[i].hardMaxAllocation
            > HARD_CAP_ROUNDING_BUFFER
            ? m[i].hardMaxAllocation - HARD_CAP_ROUNDING_BUFFER
            : 0;
        uint256 repairTarget = _min(m[i].maxAllocation, hardRepairTarget);

        return _min(idealAssets[i] - repairTarget, m[i].simAssetsHeld);
    }

    function _normalSourceRoom(
        uint256[] memory idealAssets,
        MarketAlloc[] memory m,
        uint256 i
    ) internal pure returns (uint256) {
        if (m[i].isBad || !m[i].canWithdraw) return 0;
        return _min(idealAssets[i], m[i].simAssetsHeld);
    }

    function _destinationRoom(
        uint256[] memory idealAssets,
        MarketAlloc[] memory m,
        uint256 i,
        bool hardCap
    ) internal pure returns (uint256) {
        if (!m[i].canDeposit) return 0;

        uint256 maxAllocation =
            hardCap ? m[i].hardMaxAllocation : m[i].maxAllocation;
        if (idealAssets[i] >= maxAllocation) return 0;

        uint256 room = maxAllocation - idealAssets[i];
        if (hardCap) {
            if (room <= HARD_CAP_ROUNDING_BUFFER) return 0;
            unchecked {
                room -= HARD_CAP_ROUNDING_BUFFER;
            }
        }

        return room;
    }

    function _moveAmount(
        uint256 chunkSize,
        uint256 sourceRoom,
        uint256 destRoom
    ) internal pure returns (uint256) {
        return _min(chunkSize, _min(sourceRoom, destRoom));
    }

    function _applyMove(
        uint256[] memory idealAssets,
        MarketAlloc[] memory m,
        MoveCandidate memory move_
    ) internal pure {
        idealAssets[move_.sourceIdx] -= move_.amount;
        m[move_.sourceIdx].simAssetsHeld -= move_.amount;
        idealAssets[move_.destIdx] += move_.amount;
        m[move_.destIdx].simAssetsHeld += move_.amount;
    }

    function _allWithinHardCaps(
        uint256[] memory idealAssets,
        MarketAlloc[] memory m
    ) internal pure returns (bool) {
        for (uint256 i; i < idealAssets.length; ++i) {
            if (idealAssets[i] > m[i].hardMaxAllocation) return false;
        }

        return true;
    }

    function _allocationScore(MarketAlloc memory m, uint256 assetsHeld)
        internal
        view
        returns (uint256)
    {
        uint256 supplyRate = m.irm.supplyRate(assetsHeld, m.debt, m.fees);
        uint256 nativeAPY = supplyRate > type(uint256).max / SECONDS_PER_YEAR
            ? type(uint256).max
            : supplyRate * SECONDS_PER_YEAR;

        return _saturatingAdd(nativeAPY, m.incentiveAPY);
    }

    function _saturatingAdd(uint256 a, uint256 b)
        internal
        pure
        returns (uint256)
    {
        return a > type(uint256).max - b ? type(uint256).max : a + b;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _fullyAllocated(uint256[] memory idealAssets, uint256 totalAssets)
        internal
        pure
        returns (bool)
    {
        uint256 allocated;
        for (uint256 i; i < idealAssets.length; ++i) {
            allocated += idealAssets[i];
        }

        return allocated >= totalAssets;
    }

    /// @dev Diffs ideal vs current allocations to produce deposit/withdraw
    ///      actions, and computes bounds around the projected executed BPS.
    function _buildActionsAndBounds(
        address[] memory markets,
        uint256[] memory idealAssets,
        uint256[] memory currentAssets,
        uint256[] memory postAssets,
        uint256 postTotal,
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
                    IBorrowableCToken(markets[i]), int256(0)
                );
            }

            if (postTotal > 0) {
                uint256 postBpsDown = FixedPointMathLib.fullMulDiv(
                    postAssets[i], BPS, postTotal
                );
                uint256 postBpsUp = FixedPointMathLib.fullMulDivUp(
                    postAssets[i], BPS, postTotal
                );
                uint256 maxBps = postBpsUp;
                if (maxBps < BPS) {
                    maxBps += _min(slippageBps, BPS - maxBps);
                }

                bounds[i] = LendingOptimizer.AllocationBound(
                    markets[i],
                    postBpsDown > slippageBps ? postBpsDown - slippageBps : 0,
                    maxBps
                );
            } else {
                bounds[i] =
                    LendingOptimizer.AllocationBound(markets[i], 0, BPS);
            }
        }
    }

    function _buildValidatedPlan(
        address optimizer,
        address[] memory markets,
        uint256[] memory idealAssets,
        uint256[] memory currentAssets,
        uint256 slippageBps
    )
        internal
        view
        returns (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        )
    {
        (uint256[] memory postAssets, uint256 postTotal) = _projectPostActionAssets(
            optimizer, markets, currentAssets, idealAssets
        );

        if (!_postActionWithinHardCaps(
                ILendingOptimizer(optimizer), markets, postAssets, postTotal
            )) {
            return (actions, bounds);
        }

        actions = new LendingOptimizer.ReallocationAction[](markets.length);
        bounds = new LendingOptimizer.AllocationBound[](markets.length);
        _buildActionsAndBounds(
            markets,
            idealAssets,
            currentAssets,
            postAssets,
            postTotal,
            slippageBps,
            actions,
            bounds
        );
    }

    function _postActionWithinHardCaps(
        ILendingOptimizer opt,
        address[] memory markets,
        uint256[] memory postAssets,
        uint256 postTotal
    ) internal view returns (bool) {
        if (postTotal == 0) return true;

        for (uint256 i; i < markets.length; ++i) {
            uint256 allocationWad =
                FixedPointMathLib.fullMulDiv(postAssets[i], WAD, postTotal);
            if (allocationWad > opt.allocationCaps(markets[i])) return false;
        }

        return true;
    }

    function _projectPostActionAssets(
        address optimizer,
        address[] memory markets,
        uint256[] memory currentAssets,
        uint256[] memory idealAssets
    ) internal view returns (uint256[] memory postAssets, uint256 postTotal) {
        postAssets = new uint256[](markets.length);

        for (uint256 i; i < markets.length; ++i) {
            postAssets[i] = _postActionAssets(
                optimizer, markets[i], currentAssets[i], idealAssets[i]
            );
            postTotal += postAssets[i];
        }
    }

    function _postActionAssets(
        address optimizer,
        address market,
        uint256 currentAssets,
        uint256 idealAssets
    ) internal view returns (uint256) {
        IBorrowableCToken ct = IBorrowableCToken(market);
        uint256 currentShares = _balanceOf(market, optimizer);

        if (idealAssets > currentAssets) {
            uint256 assetsToDeposit = idealAssets - currentAssets;
            uint256 sharesToMint = ct.previewDeposit(assetsToDeposit);
            return FixedPointMathLib.fullMulDiv(
                currentShares + sharesToMint,
                ct.totalAssets() + assetsToDeposit,
                ct.totalSupply() + sharesToMint
            );
        }

        if (currentAssets > idealAssets) {
            uint256 assetsToWithdraw = currentAssets - idealAssets;
            uint256 sharesToBurn = ct.previewWithdraw(assetsToWithdraw);
            if (sharesToBurn >= currentShares) return 0;

            uint256 totalShares = ct.totalSupply();
            if (sharesToBurn >= totalShares) return 0;

            return FixedPointMathLib.fullMulDiv(
                currentShares - sharesToBurn,
                ct.totalAssets() - assetsToWithdraw,
                totalShares - sharesToBurn
            );
        }

        return currentAssets;
    }

    function _selectCapBuffer(
        ILendingOptimizer opt,
        address[] memory markets,
        address[] memory badMarkets,
        uint256[] memory currentAssets,
        uint256 totalAssets
    ) internal view returns (uint256 bufferBps) {
        for (uint256 i = CAP_BUFFER_BPS;; --i) {
            if (_hasEnoughBufferedCapacity(
                    opt, markets, badMarkets, currentAssets, totalAssets, i
                )) {
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
            MarketManagerIsolated mm =
                MarketManagerIsolated(address(_marketManager(markets[i])));
            bool cannotAddMore = _isBadMarket(markets[i], badMarkets)
                || _isMintPaused(markets[i], IMarketManager(address(mm)));
            bool cannotWithdraw = mm.redeemPaused() == 2;

            if (cannotWithdraw) {
                capacity += currentAssets[i];
            } else if (!cannotAddMore) {
                capacity += _bufferedMaxAllocation(
                    opt, markets[i], totalAssets, bufferBps
                );
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

    function _maxAllocation(
        ILendingOptimizer opt,
        address market,
        uint256 totalAssets
    ) internal view returns (uint256) {
        return FixedPointMathLib.mulDiv(
            totalAssets, opt.allocationCaps(market), WAD
        );
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
                imbalance += isDeposit ? -int256(absDelta) : int256(absDelta);
                idealAssets[i] = currentAssets[i];
            }
        }

        // Phase 2: Rebalance by trimming the smallest entry on the
        // over-represented side. If trimming creates new dust the
        // excess flips direction and the loop continues.
        if (imbalance != 0) {
            uint256 excess =
                imbalance > 0 ? uint256(imbalance) : uint256(-imbalance);
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

                    if (
                        IBorrowableCToken(markets[bestIdx])
                                .convertToShares(remaining) == 0
                    ) {
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
    function _isBadMarket(address market, address[] memory badMarkets)
        internal
        pure
        returns (bool)
    {
        for (uint256 i; i < badMarkets.length; ++i) {
            if (badMarkets[i] == market) return true;
        }
        return false;
    }

    function _balanceOf(address token, address account)
        internal
        view
        returns (uint256 result)
    {
        result = ICToken(token).balanceOf(account);
    }

    function _assetsHeld(IBorrowableCToken token)
        internal
        view
        returns (uint256 result)
    {
        result = token.assetsHeld();
    }

    /// @dev Returns true if minting is paused for `cToken`.
    function _isMintPaused(address cToken, IMarketManager mm)
        internal
        view
        returns (bool mp)
    {
        (mp,,) = mm.actionsPaused(cToken);
    }

    /// @dev Convenience overload — resolves market manager from cToken.
    function _isMintPaused(address cToken) internal view returns (bool mp) {
        mp = _isMintPaused(cToken, _marketManager(cToken));
    }

    function _marketManager(address cToken)
        internal
        view
        returns (IMarketManager mm)
    {
        mm = ICToken(cToken).marketManager();
    }

    function _IRM(IBorrowableCToken token)
        internal
        view
        returns (IDynamicIRM result)
    {
        result = token.IRM();
    }

    function _outstandingDebt(IBorrowableCToken token)
        internal
        view
        returns (uint256 result)
    {
        result = token.marketOutstandingDebt();
    }

    function _interestFee(IBorrowableCToken token)
        internal
        view
        returns (uint256 result)
    {
        result = token.interestFee();
    }

    /// @dev Checks whether a collateral asset's oracle feed is stale.
    ///      Compares the time since the last oracle update against the
    ///      feed's configured heartbeat scaled by `multiplierBps`.
    /// @param collateralAsset The underlying collateral asset address.
    /// @param multiplierBps The staleness multiplier in BPS (e.g., 15000 = 1.5x).
    /// @return True if the oracle feed is stale.
    function _isOracleStale(address collateralAsset, uint256 multiplierBps)
        internal
        view
        returns (bool)
    {
        address[] memory adaptors =
            ORACLE_MANAGER.getPricingAdaptors(collateralAsset);

        (, address aggregatorProxy,, uint24 heartbeat) =
            IChainlinkAdaptor(adaptors[0]).assetConfig(collateralAsset, true);

        (,,, uint256 updatedAt,) =
            IChainlink(aggregatorProxy).latestRoundData();

        unchecked {
            return block.timestamp - updatedAt
                > uint256(heartbeat) * multiplierBps / 10000;
        }
    }

    /// @dev Checks whether a collateral asset's adjusted oracle price is zero,
    ///      which indicates a PriceGuard floor breach in Curvance adaptors.
    function _isOraclePriceZero(address collateralAsset)
        internal
        view
        returns (bool)
    {
        address[] memory adaptors =
            ORACLE_MANAGER.getPricingAdaptors(collateralAsset);

        IOracleAdaptor.PricingResult memory result =
            IOracleAdaptor(adaptors[0]).getPrice(collateralAsset, true, true);

        return result.price == 0;
    }
}
