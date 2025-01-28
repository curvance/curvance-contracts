// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { CompoundingPToken, FixedPointMathLib, SafeTransferLib, IERC20, ICentralRegistry } from "contracts/market/token/CompoundingPToken.sol";

import { CommonLib } from "contracts/libraries/CommonLib.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

import { IBooster } from "contracts/interfaces/external/convex/IBooster.sol";
import { IBaseRewardPool } from "contracts/interfaces/external/convex/IBaseRewardPool.sol";
import { IRewards } from "contracts/interfaces/external/convex/IRewards.sol";
import { ICurveFi } from "contracts/interfaces/external/curve/ICurveFi.sol";

contract Convex2PoolPToken is CompoundingPToken {
    /// TYPES ///

    /// @param curvePool Address of Curve Pool.
    /// @param pid Convex pool id value.
    /// @param rewarder Address of Convex Rewarder.
    /// @param booster Address of Convex Booster.
    /// @param rewardTokens Array of Convex reward tokens.
    /// @param underlyingTokens Curve LP underlying tokens.
    struct StrategyData {
        ICurveFi curvePool;
        uint256 pid;
        IBaseRewardPool rewarder;
        IBooster booster;
        address[] rewardTokens;
        address[] underlyingTokens;
    }

    /// CONSTANTS ///

    /// @dev This address is for Ethereum mainnet so make sure to update
    ///      it if Curve/Convex is being supported on another chain.
    address private constant _CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    /// @dev This address is for Ethereum mainnet so make sure to update
    ///      it if Curve/Convex is being supported on another chain.
    address private constant _CVX = 0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B;

    /// STORAGE ///

    /// @notice StrategyData packed configuration data.
    StrategyData public strategyData;

    /// @notice Whether a particular token address is an underlying token
    ///         of this Curve 2Pool LP.
    /// @dev Token => Is underlying token.
    mapping(address => bool) public isUnderlyingToken;

    /// EVENTS ///

    event Harvest(uint256 yield);

    /// ERRORS ///

    error Convex2PoolPToken__UnsafePool();
    error Convex2PoolPToken__InvalidVaultConfig();
    error Convex2PoolPToken__InvalidCoinLength();
    error Convex2PoolPToken__NoYield();

    /// CONSTRUCTOR ///

    receive() external payable {}

    constructor(
        ICentralRegistry centralRegistry_,
        IERC20 asset_,
        address marketManager_,
        uint256 pid_,
        address rewarder_,
        address booster_
    ) CompoundingPToken(centralRegistry_, asset_, marketManager_) {
        if (block.chainid != 1) {
            revert Convex2PoolPToken__UnsafePool();
        }

        // We only support Curves new ng pools with read only
        // reentry protection. This may be adjusted in the future.
        if (pid_ <= 176) {
            revert Convex2PoolPToken__UnsafePool();
        }

        strategyData.pid = pid_;
        strategyData.booster = IBooster(booster_);

        // Query actual Convex pool configuration data.
        (address pidToken, , , address crvRewards, , bool shutdown) = IBooster(
            booster_
        ).poolInfo(strategyData.pid);

        // Validate that the pool is still active and that the lp token
        // and rewarder in Convex matches what we are configuring for.
        if (
            pidToken != address(asset_) || shutdown || crvRewards != rewarder_
        ) {
            revert Convex2PoolPToken__InvalidVaultConfig();
        }

        strategyData.rewarder = IBaseRewardPool(rewarder_);
        strategyData.curvePool = ICurveFi(pidToken);

        _queryTokens();
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Requeries reward and underlying tokens directly from
    ///         Convex's smart contracts.
    /// @dev This can be permissionless since this data is 1:1 with dependent
    ///      contracts and takes no parameter values.
    function reQueryTokens() public {
        // Cache current reward tokens.
        address[] memory rewardTokens = strategyData.rewardTokens;
        uint256 numTokens = rewardTokens.length;

        // Clear reward token data fields.

        // Remove approved tokens for harvester compounding.
        for (uint256 i; i < numTokens; ) {
            isApprovedAsset[rewardTokens[i++]] = false;
        }

        // Wipe current reward tokens data.
        delete strategyData.rewardTokens;

        // Cache current underlying tokens.
        address[] memory currentTokens = strategyData.underlyingTokens;
        numTokens = currentTokens.length;

        // Clear underlying token data fields.

        // Remove `isUnderlyingToken` mapping value from current
        // flagged underlying tokens.
        for (uint256 i; i < numTokens; ) {
            isUnderlyingToken[currentTokens[i++]] = false;
        }

        // Wipe current underlying tokens data.
        delete strategyData.underlyingTokens;

        _queryTokens();
    }

    /// PUBLIC FUNCTIONS ///

    // REWARD AND HARVESTING LOGIC

    /// @notice Harvests and compounds outstanding vault rewards
    ///         and vests pending rewards.
    /// @dev Only callable by Offchain bots.
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

            // Claim pending Convex rewards.
            sd.rewarder.getReward(address(this), true);

            uint256 numRewardTokens = sd.rewardTokens.length;
            address rewardToken;
            uint256 rewardAmount;
            uint256 protocolFee;

            {
                // Cache DAO Central Registry values to minimize runtime
                // gas costs.
                address feeManager = centralRegistry.feeManager();
                uint256 harvestFee = centralRegistry.protocolHarvestFee();

                for (uint256 i; i < numRewardTokens; ++i) {
                    rewardToken = sd.rewardTokens[i];
                    rewardAmount = IERC20(rewardToken).balanceOf(
                        address(this)
                    );

                    // If there are no pending rewards for this token,
                    // can skip to next reward token.
                    if (rewardAmount == 0) {
                        continue;
                    }

                    // Take protocol fee for veCVE lockers and auto
                    // compounding bot.
                    protocolFee = FixedPointMathLib.mulDiv(
                        rewardAmount,
                        harvestFee,
                        1e18
                    );
                    rewardAmount -= protocolFee;
                    SafeTransferLib.safeTransfer(
                        rewardToken,
                        feeManager,
                        protocolFee
                    );
                }
            }

            // Prep liquidity for Curve Pool.
            (SwapperLib.Swap[] memory swapDataArray, uint256 minLPAmount) = abi
                .decode(data, (SwapperLib.Swap[], uint256));
            {
                uint256 numSwapData = swapDataArray.length;
                for (uint256 i; i < numSwapData; ++i) {
                    if (!isApprovedAsset[swapDataArray[i].inputToken]) {
                        revert CompoundingPToken__UnapprovedAssetSwap();
                    }

                    SwapperLib.swapSafe(centralRegistry, swapDataArray[i]);
                }
            }

            // Deposit assets into Curve Pool.
            _addLiquidityToCurve(minLPAmount);

            // Deposit assets into Convex.
            yield = IERC20(asset()).balanceOf(address(this));
            if (yield == 0) {
                revert Convex2PoolPToken__NoYield();
            }

            (, , , , , bool isShutdown) = strategyData.booster.poolInfo(
                strategyData.pid
            );

            if (isShutdown) {
                SafeTransferLib.safeTransfer(
                    asset(),
                    centralRegistry.daoAddress(),
                    yield
                );
                yield = 0;
            } else {
                _afterDeposit(yield, 0);
            }

            // Update vesting info, query `vestPeriod` here to cache it.
            _setNewVaultData(yield, vestPeriod);

            emit Harvest(yield);
        }
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Queries reward and underlying tokens directly from
    ///         Convex's smart contracts, then populates storage values.
    function _queryTokens() internal {
        // Query and populate reward token data fields.

        // Add CRV as a reward token, then let Convex tell you what rewards
        // the vault will receive.
        strategyData.rewardTokens.push() = _CRV;
        isApprovedAsset[_CRV] = true;

        // Add CVX as a reward token, since some vaults do not list CVX
        // as a reward token.
        strategyData.rewardTokens.push() = _CVX;
        isApprovedAsset[_CVX] = true;

        IBaseRewardPool rewarder = strategyData.rewarder;
        uint256 numTokens = rewarder.extraRewardsLength();
        address currentToken;

        for (uint256 i; i < numTokens; ) {
            currentToken = IRewards(rewarder.extraRewards(i++)).rewardToken();

            // We do not expect CRV/CVX to be listed as extra rewards,
            // but hypothetically its possible and we do not want to
            // needlessly attempt to double claim.
            if (currentToken != _CRV && currentToken != _CVX) {
                strategyData.rewardTokens.push() = currentToken;
                if (address(currentToken) != asset()) {
                    isApprovedAsset[currentToken] = true;
                }
            }
        }

        ICurveFi vaultAsset = ICurveFi(asset());
        numTokens = 0;

        // Figure out how many tokens are in the Curve pool.
        while (true) {
            try vaultAsset.coins(numTokens) {
                ++numTokens;
            } catch {
                break;
            }
        }

        // Validate that the liquidity pool is actually a 2Pool.
        if (numTokens != 2) {
            revert Convex2PoolPToken__InvalidCoinLength();
        }

        for (uint256 i; i < numTokens; ) {
            currentToken = vaultAsset.coins(i++);
            strategyData.underlyingTokens.push() = currentToken;
            isUnderlyingToken[currentToken] = true;
        }
    }

    // INTERNAL POSITION LOGIC

    /// @notice Deposits specified amount of assets into Convex
    ///         booster contract.
    /// @param assets The amount of assets to deposit.
    function _afterDeposit(uint256 assets, uint256) internal override {
        IBooster booster = strategyData.booster;
        SafeTransferLib.safeApprove(asset(), address(booster), assets);
        booster.deposit(strategyData.pid, assets, true);
    }

    /// @notice Withdraws specified amount of assets from Convex reward pool.
    /// @param assets The amount of assets to withdraw.
    function _beforeWithdraw(uint256 assets, uint256) internal override {
        strategyData.rewarder.withdrawAndUnwrap(assets, false);
    }

    /// @notice Adds underlying tokens to the vaults Curve 2Pool LP.
    /// @param minLPAmount Minimum LP token amount that should be received
    ///                    on adding liquidity, this acts as a slippage check.
    function _addLiquidityToCurve(uint256 minLPAmount) internal {
        address underlyingToken;
        uint256[2] memory amounts;

        bool liquidityAvailable;
        uint256 value;
        for (uint256 i; i < 2; ++i) {
            underlyingToken = strategyData.underlyingTokens[i];
            amounts[i] = CommonLib.getTokenBalance(underlyingToken);

            if (CommonLib.isETH(underlyingToken)) {
                value = amounts[i];
            }

            SwapperLib._approveTokenIfNeeded(
                underlyingToken,
                address(strategyData.curvePool),
                amounts[i]
            );

            if (amounts[i] > 0) {
                liquidityAvailable = true;
            }
        }

        if (liquidityAvailable) {
            strategyData.curvePool.add_liquidity{ value: value }(
                amounts,
                minLPAmount
            );
        }
    }
}
