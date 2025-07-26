// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { StrategyCToken, SafeTransferLib, ICentralRegistry, IERC20 } from "contracts/market/token/StrategyCToken.sol";

import { VelodromeLib } from "contracts/libraries/VelodromeLib.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

import { IVeloGauge } from "contracts/interfaces/external/velodrome/IVeloGauge.sol";
import { IVeloRouter } from "contracts/interfaces/external/velodrome/IVeloRouter.sol";
import { IVeloPair } from "contracts/interfaces/external/velodrome/IVeloPair.sol";
import { IVeloPairFactory } from "contracts/interfaces/external/velodrome/IVeloPairFactory.sol";
import { IVeloPool } from "contracts/interfaces/external/velodrome/IVeloPool.sol";

contract VelodromeVolatileCToken is StrategyCToken {
    /// TYPES ///

    /// @title Strategy Data
    /// @notice Data for a Velodrome Volatile LP token.
    /// @param gauge Address of Velodrome Gauge.
    /// @param pairFactory Address of Velodrome Pair Factory.
    /// @param router Address of Velodrome Router.
    /// @param token0 Address of first underlying token.
    /// @param token1 Address of second underlying token.
    struct StrategyData {
        IVeloGauge gauge; 
        IVeloPairFactory pairFactory;
        IVeloRouter router;
        address token0; 
        address token1;
    }

    /// CONSTANTS ///

    /// @notice Reward token contract address, should be VELO or AERO.
    address public immutable rewardToken;
    /// @notice Whether `rewardToken` is an underlying token of the pair
    bool public immutable rewardTokenIsUnderlying;

    /// STORAGE ///

    /// @notice StrategyData packed configuration data
    StrategyData public strategyData;

    /// ERRORS ///

    error VelodromeVolatileCToken__InvalidAssetType();
    error VelodromeVolatileCToken__SlippageError();

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        IERC20 asset_,
        address marketManager_,
        IVeloGauge gauge,
        IVeloPairFactory pairFactory,
        IVeloRouter router,
        uint256 vestingPeriod_
    ) StrategyCToken(
        centralRegistry_,
        asset_,
        marketManager_,
        vestingPeriod_
    ) {
        _validateChainDeployment();

        address chainRewardToken;

        if (block.chainid == 10) {
            chainRewardToken = 0x9560e827aF36c94D2Ac33a39bCE1Fe78631088Db;
        } else if (block.chainid == 8453) {
            chainRewardToken = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
        }

        rewardToken = chainRewardToken;

        if (rewardToken == address(0)) {
            revert BaseCToken__UnsupportedChain();
        }

        // Cache assigned asset address.
        address _asset = asset();
        // Validate that we have the proper gauge linked with the proper LP
        // and pair factory.
        if (gauge.stakingToken() != _asset) {
            revert VelodromeVolatileCToken__InvalidAssetType();
        }

        // Validate the desired underlying lp token is a vAMM.
        if (IVeloPool(_asset).stable()) {
            revert VelodromeVolatileCToken__InvalidAssetType();
        }

        // Query underlying token data from the pool.
        strategyData.token0 = IVeloPool(_asset).token0();
        strategyData.token1 = IVeloPool(_asset).token1();
        // Make sure token0 is VELO if one of underlying tokens is VELO,
        // so that it can be used properly in harvest function.
        if (strategyData.token1 == rewardToken) {
            strategyData.token1 = strategyData.token0;
            strategyData.token0 = rewardToken;
        }
        strategyData.gauge = gauge;
        strategyData.router = router;
        strategyData.pairFactory = pairFactory;

        _isUnderlyingToken[strategyData.token0] = true;
        _isUnderlyingToken[strategyData.token1] = true;

        rewardTokenIsUnderlying = (rewardToken == strategyData.token0 ||
            rewardToken == strategyData.token1);

        if (rewardToken != asset()) {
            _isApprovedAsset[rewardToken] = true;
        }
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Harvests and compounds outstanding vault rewards
    ///         and vests pending rewards.
    /// @dev Only callable by Offchain bots. Passes a block.timestamp
    ///      deadline meaning execution will always get passed, this is due to
    ///      offchain infra calculating calldata right before execution,
    ///      making deadlines irrelevant.
    ///      Emits a {Harvest} event.
    /// @param data Byte array for aggregator swap data.
    /// @return yield The amount of new assets acquired from harvesting
    ///               vault yield.
    function harvest(
        bytes calldata data
    ) external override returns (uint256 yield) {
        // Checks whether the caller can harvest strategy yield.
        _canHarvest();

        // Vest pending yield if there are any.
        _accrueIfNeeded();

        // Can only harvest once previous vesting period is done.
        if (_checkVestingFinished(_vestingData)) {
            _updateVestingPeriodIfNeeded();

            // Cache strategy data.
            StrategyData memory sd = strategyData;

            // Claim pending Velodrome rewards.
            sd.gauge.getReward(address(this));
            (
                SwapperLib.Swap memory swapAction,
                uint256 lpMinOutAmount
            ) = abi.decode(data, (SwapperLib.Swap, uint256));

            uint256 rewardAmount = IERC20(rewardToken).balanceOf(
                address(this)
            );
            // If there are no pending rewards, skip swapping logic.
            if (rewardAmount > 0) {
                // Take protocol fee for token lockers and strategy bot.
                rewardAmount = _applyFee(
                    rewardAmount,
                    rewardToken,
                    centralRegistry.protocolHarvestFee(),
                    centralRegistry.feeManager()
                );

                // Swap from VELO to underlying tokens, if necessary.
                if (!rewardTokenIsUnderlying) {
                    if (
                        !_isApprovedAsset[swapAction.inputToken] ||
                        swapAction.outputToken != sd.token0
                    ) {
                        // This also implicitly checks:
                        // `swapAction.inputToken != rewardToken`.
                        revert StrategyCToken__UnapprovedAssetSwap();
                    }

                    SwapperLib._swapSafe(centralRegistry, swapAction);
                }
            }
            
            uint256 totalAmountA = IERC20(sd.token0).balanceOf(address(this));

            // Make sure swap was routed into token0, or that token0 is VELO.
            if (totalAmountA == 0) {
                revert VelodromeVolatileCToken__SlippageError();
            }

            // Cache asset to minimize storage reads.
            address _asset = asset();
            // Pull reserve data so we can swap half of token0 into token1
            // optimally.
            (uint256 r0, uint256 r1, ) = IVeloPair(_asset).getReserves();
            r0 = sd.token0 == IVeloPair(_asset).token0() ? r0 : r1;

            // On Volatile Pair we only need to input factory, lptoken,
            // amountA, reserveA, stable = false.
            // Decimals are unused and amountB is unused so we can pass 0.
            uint256 swapAmount = VelodromeLib._optimalDeposit(
                address(sd.pairFactory),
                _asset,
                totalAmountA,
                r0,
                0,
                0,
                0,
                false
            );
            // Feed calculated data, and stable = false.
            uint256 totalAmountB = VelodromeLib._swapExactTokensForTokens(
                address(sd.router),
                _asset,
                sd.token0,
                sd.token1,
                swapAmount,
                false
            );
            totalAmountA -= swapAmount;

            // Add liquidity to Velodrome lp with variable params.
            yield = VelodromeLib._addLiquidity(
                address(sd.router),
                sd.token0,
                sd.token1,
                false,
                totalAmountA,
                totalAmountB,
                VelodromeLib.VELODROME_ADD_LIQUIDITY_SLIPPAGE
            );

            if (yield < lpMinOutAmount) {
                revert VelodromeVolatileCToken__SlippageError();
            }

            // Deposit new assets into Velodrome gauge to continue
            // yield farming.
            _afterDeposit(yield, 0);

            // Set new yield vesting data.
            _setVestingData(yield);

            emit Harvest(yield);
        }
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Deposits specified amount of assets into velodrome gauge pool.
    /// @param assets The amount of assets to deposit.
    function _afterDeposit(uint256 assets, uint256) internal override {
        IVeloGauge gauge = strategyData.gauge;
        SafeTransferLib.safeApprove(asset(), address(gauge), assets);
        gauge.deposit(assets);
    }

    /// @notice Withdraws specified amount of assets from velodrome gauge pool.
    /// @param assets The amount of assets to withdraw.
    function _beforeWithdraw(uint256 assets, uint256) internal override {
        strategyData.gauge.withdraw(assets);
    }

    /// @notice Validates whether a contract can be deployed based on
    ///         the current chainid.
    /// @dev This check is so incompatible deployments never occur, such as
    ///      assuming the wrong token address on a deployment.
    function _validateChainDeployment() internal view virtual {
        if (block.chainid != 10) {
            revert BaseCToken__UnsupportedChain();
        }
    }
}