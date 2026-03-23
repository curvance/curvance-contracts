// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { WAD } from "contracts/libraries/ConstantsLib.sol";

import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { ICToken } from "contracts/interfaces/ICToken.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { IDynamicIRM } from "contracts/interfaces/IDynamicIRM.sol";
import { ILendingOptimizer } from "contracts/interfaces/ILendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";

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

    /// EXTERNAL FUNCTIONS ///

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

    /// @notice Computes the optimal rebalance actions for a LendingOptimizer.
    /// @dev Uses a chunked greedy algorithm (20 chunks) to determine ideal
    ///      allocation across markets, respecting allocation caps. Returns
    ///      ReallocationAction[] and AllocationBound[] that can be passed
    ///      directly to LendingOptimizer.rebalance().
    ///      Bounds are set to [idealBps - slippageBps, idealBps + slippageBps],
    ///      clamped to [0, 10000].
    /// @param optimizer The LendingOptimizer address.
    /// @param slippageBps Tolerance in BPS around each market's ideal allocation.
    ///                    e.g., 100 = +/- 1%.
    /// @return actions The rebalance actions array matching approvedCTokensList order.
    /// @return bounds The allocation bounds array matching approvedCTokensList order.
    function optimalRebalance(
        address optimizer,
        uint256 slippageBps
    ) external view returns (
        LendingOptimizer.ReallocationAction[] memory actions,
        LendingOptimizer.AllocationBound[] memory bounds
    ) {
        address[] memory markets = ILendingOptimizer(optimizer).getApprovedMarkets();

        actions = new LendingOptimizer.ReallocationAction[](markets.length);
        bounds = new LendingOptimizer.AllocationBound[](markets.length);

        if (markets.length == 0) return (actions, bounds);

        MarketAlloc[] memory m;
        {
            uint256[] memory idealAssets;
            uint256[] memory currentAssets;
            (idealAssets, currentAssets, m) =
                _computeIdealAllocation(optimizer, markets);

            uint256 ta = ILendingOptimizer(optimizer).totalAssets();

            // Diff ideal vs current to produce deposit/withdraw actions,
            // and compute bounds around the ideal allocation percentage.
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

                // Compute bounds around ideal allocation.
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

    }

    /// @dev Chunked greedy allocation: computes the ideal per-market asset
    ///      distribution for a LendingOptimizer, respecting allocation caps
    ///      and market pause states.
    ///      Separated from optimalRebalance to avoid stack-too-deep.
    function _computeIdealAllocation(
        address optimizer,
        address[] memory markets
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

        // Second pass: compute maxAllocation (requires final ta) and adjust
        // for market pause states.
        uint256 lockedAssets;
        {
            ILendingOptimizer opt = ILendingOptimizer(optimizer);
            for (uint256 i; i < numMarkets; ++i) {
                uint256 current = currentAssets[i];
                m[i].maxAllocation = FixedPointMathLib.mulDiv(
                    ta, opt.allocationCaps(markets[i]), WAD
                );

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
}