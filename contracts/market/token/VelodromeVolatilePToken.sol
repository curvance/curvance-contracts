// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { CompoundingPToken, FixedPointMathLib, SafeTransferLib, IERC20, ICentralRegistry } from "contracts/market/token/CompoundingPToken.sol";

import { VelodromeLib } from "contracts/libraries/VelodromeLib.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

import { IVeloGauge } from "contracts/interfaces/external/velodrome/IVeloGauge.sol";
import { IVeloRouter } from "contracts/interfaces/external/velodrome/IVeloRouter.sol";
import { IVeloPair } from "contracts/interfaces/external/velodrome/IVeloPair.sol";
import { IVeloPairFactory } from "contracts/interfaces/external/velodrome/IVeloPairFactory.sol";
import { IVeloPool } from "contracts/interfaces/external/velodrome/IVeloPool.sol";

contract VelodromeVolatilePToken is CompoundingPToken {
    /// TYPES ///

    struct StrategyData {
        IVeloGauge gauge; // Velodrome Gauge contract
        IVeloPairFactory pairFactory; // Velodrome Pair Factory contract
        IVeloRouter router; // Velodrome Router contract
        address token0; // LP first token address
        address token1; // LP second token address
    }

    /// CONSTANTS ///

    /// @notice Reward token contract address, should be VELO or AERO.
    address public immutable rewardToken;
    /// @notice Whether `rewardToken` is an underlying token of the pair
    bool public immutable rewardTokenIsUnderlying;

    /// STORAGE ///

    /// @notice StrategyData packed configuration data
    StrategyData public strategyData;

    /// @notice Token => underlying token of the vAMM LP or not
    mapping(address => bool) public isUnderlyingToken;

    /// EVENTS ///

    event Harvest(uint256 yield);

    /// ERRORS ///

    error VelodromeVolatilePToken__InvalidAssetType();
    error VelodromeVolatilePToken__SlippageError();

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        IERC20 asset_,
        address marketManager_,
        IVeloGauge gauge,
        IVeloPairFactory pairFactory,
        IVeloRouter router
    ) CompoundingPToken(centralRegistry_, asset_, marketManager_) {
        _validateChainDeployment();

        address chainRewardToken;

        if (block.chainid == 10) {
            chainRewardToken = 0x9560e827aF36c94D2Ac33a39bCE1Fe78631088Db;
        } else if (block.chainid == 8453) {
            chainRewardToken = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
        }

        rewardToken = chainRewardToken;

        if (rewardToken == address(0)) {
            revert BasePToken__UnsupportedChain();
        }

        // Cache assigned asset address.
        address _asset = asset();
        // Validate that we have the proper gauge linked with the proper LP
        // and pair factory.
        if (gauge.stakingToken() != _asset) {
            revert VelodromeVolatilePToken__InvalidAssetType();
        }

        // Validate the desired underlying lp token is a vAMM.
        if (IVeloPool(_asset).stable()) {
            revert VelodromeVolatilePToken__InvalidAssetType();
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

        isUnderlyingToken[strategyData.token0] = true;
        isUnderlyingToken[strategyData.token1] = true;

        rewardTokenIsUnderlying = (rewardToken == strategyData.token0 ||
            rewardToken == strategyData.token1);

        if (rewardToken != asset()) {
            isApprovedAsset[rewardToken] = true;
        }
    }

    /// PUBLIC FUNCTIONS ///

    // REWARD AND HARVESTING LOGIC

    /// @notice Harvests and compounds outstanding vault rewards
    ///         and vests pending rewards.
    /// @dev Only callable by Offchain bots. Passes a block.timestamp
    ///      deadline meaning execution will always get passed, this is due to
    ///      offchain infra calculating calldata right before execution,
    ///      making deadlines irrelevant.
    ///      Emits a {Harvest} event.
    /// @param data Byte array for aggregator swap data.
    /// @return yield The amount of new assets acquired from compounding
    ///               vault yield.
    function harvest(
        bytes calldata data
    ) external override returns (uint256 yield) {
        // Checks whether the caller can compound the vault yield.
        _canCompound();

        // Vest pending rewards if there are any.
        _vestIfNeeded();

        // Can only harvest once previous reward period is done.
        if (_checkVestStatus(_vaultData)) {
            _updateVestingPeriodIfNeeded();

            // Cache strategy data.
            StrategyData memory sd = strategyData;

            // Claim pending Velodrome rewards.
            sd.gauge.getReward(address(this));

            {
                uint256 rewardAmount = IERC20(rewardToken).balanceOf(
                    address(this)
                );
                // If there are no pending rewards, skip swapping logic.
                if (rewardAmount > 0) {
                    // Take protocol fee for veCVE lockers and auto
                    // compounding bot.
                    uint256 protocolFee = FixedPointMathLib.mulDivUp(
                        rewardAmount,
                        centralRegistry.protocolHarvestFee(),
                        1e18
                    );
                    rewardAmount -= protocolFee;
                    SafeTransferLib.safeTransfer(
                        rewardToken,
                        centralRegistry.feeManager(),
                        protocolFee
                    );

                    // Swap from VELO to underlying tokens, if necessary.
                    if (!rewardTokenIsUnderlying) {
                        SwapperLib.Swap memory swapData = abi.decode(
                            data,
                            (SwapperLib.Swap)
                        );

                        if (
                            !isApprovedAsset[swapData.inputToken] ||
                            swapData.outputToken != sd.token0
                            ) {
                            // this will be the same check: `swapData.inputToken != rewardToken`
                            revert CompoundingPToken__UnapprovedAssetSwap();
                        }

                        SwapperLib.swapSafe(centralRegistry, swapData);
                    }
                }
            }

            uint256 totalAmountA = IERC20(sd.token0).balanceOf(address(this));

            // Make sure swap was routed into token0, or that token0 is VELO.
            if (totalAmountA == 0) {
                revert VelodromeVolatilePToken__SlippageError();
            }

            // Cache asset to minimize storage reads.
            address _asset = asset();
            // Pull reserve data so we can swap half of token0 into token1
            // optimally.
            (uint256 r0, uint256 r1, ) = IVeloPair(_asset).getReserves();
            uint256 reserveA = sd.token0 == IVeloPair(_asset).token0()
                ? r0
                : r1;

            // On Volatile Pair we only need to input factory, lptoken,
            // amountA, reserveA, stable = false.
            // Decimals are unused and amountB is unused so we can pass 0.
            uint256 swapAmount = VelodromeLib._optimalDeposit(
                address(sd.pairFactory),
                _asset,
                totalAmountA,
                reserveA,
                0,
                0,
                0,
                false
            );
            // Feed calculated data, and stable = false.
            VelodromeLib._swapExactTokensForTokens(
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
                IERC20(sd.token1).balanceOf(address(this)), // totalAmountB
                VelodromeLib.VELODROME_ADD_LIQUIDITY_SLIPPAGE
            );

            // Deposit new assets into Velodrome gauge to continue
            // yield farming.
            _afterDeposit(yield, 0);

            // Update vesting info, query `vestPeriod` here to cache it.
            _setNewVaultData(yield, vestPeriod);

            emit Harvest(yield);
        }
    }

    /// INTERNAL FUNCTIONS ///

    // INTERNAL POSITION LOGIC

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
            revert BasePToken__UnsupportedChain();
        }
    }
}
