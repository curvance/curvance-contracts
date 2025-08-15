// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import { StrategyCToken, SafeTransferLib, ICentralRegistry, IERC20 } from "contracts/market/token/StrategyCToken.sol";

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

import { IBooster } from "contracts/interfaces/external/convex/IBooster.sol";
import { IBaseRewardPool } from "contracts/interfaces/external/convex/IBaseRewardPool.sol";
import { IRewards } from "contracts/interfaces/external/convex/IRewards.sol";
import { IBalancerVault } from "contracts/interfaces/external/balancer/IBalancerVault.sol";
import { IBalancerPool } from "contracts/interfaces/external/balancer/IBalancerPool.sol";
import { IStashWrapper } from "contracts/interfaces/external/aura/IStashWrapper.sol";

contract AuraCToken is StrategyCToken {
    /// TYPES ///

    /// @param balancerVault Address of Balancer Vault.
    /// @param balancerPoolId Bytes32 encoded Balancer pool id.
    /// @param pid Aura pool id value.
    /// @param rewarder Address of Aura Rewarder.
    /// @param booster Address of Aura Booster.
    /// @param rewardTokens Array of Aura reward tokens.
    /// @param underlyingTokens Balancer LP underlying tokens.
    struct StrategyData {
        IBalancerVault balancerVault;
        bytes32 balancerPoolId;
        uint256 pid;
        IBaseRewardPool rewarder;
        IBooster booster;
        address[] rewardTokens;
        address[] underlyingTokens;
    }

    /// CONSTANTS ///

    /// @dev These addresses are for Ethereum mainnet so make sure to update
    ///      them if Balancer/Aura is being supported on another chain.
    address private constant _BAL = 0xba100000625a3754423978a60c9317c58a424e3D;
    address private constant _AURA =
        0xC0c293ce456fF0ED870ADd98a0828Dd4d2903DBF;

    /// STORAGE ///

    /// @notice StrategyData packed configuration data.
    StrategyData public strategyData;

    /// ERRORS ///

    error AuraCToken__UnsafePool();
    error AuraCToken__InvalidVaultConfig();
    error AuraCToken__NoYield();

    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
    /// @param asset_ The address of the underlying asset for this cToken.
    /// @param mm The address of the MarketManager which manages liquidity
    ///           positions between linked cTokens inside a joint market.
    /// @param vestingPeriod_ The length of time a vesting period will last,
    ///                       in seconds.
    constructor(
        ICentralRegistry cr,
        IERC20 asset_,
        address mm,
        uint256 pid_,
        address rewarder_,
        address booster_,
        uint256 vestingPeriod_
    ) StrategyCToken(cr, asset_, mm, vestingPeriod_) {
        if (block.chainid != 1) {
            revert AuraCToken__UnsafePool();
        }

        strategyData.pid = pid_;
        strategyData.booster = IBooster(booster_);

        // Query actual Aura pool configuration data.
        (address pidToken, , , address balRewards, , bool shutdown) = IBooster(
            booster_
        ).poolInfo(strategyData.pid);

        // Validate that the pool is still active and that the lp token
        // and rewarder in Aura matches what we are configuring for.
        if (pidToken != asset() || shutdown || balRewards != rewarder_) {
            revert AuraCToken__InvalidVaultConfig();
        }

        strategyData.rewarder = IBaseRewardPool(rewarder_);
        strategyData.balancerVault = IBalancerVault(
            IBalancerPool(pidToken).getVault()
        );
        strategyData.balancerPoolId = IBalancerPool(pidToken).getPoolId();

        _queryTokens();
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Requeries reward and underlying tokens directly from
    ///         Aura's smart contracts.
    /// @dev This can be permissionless since this data is 1:1 with dependent
    ///      contracts and takes no parameter values.
    function reQueryTokens() public {
        // Cache current reward tokens.
        address[] memory strategyRewardTokens = strategyData.rewardTokens;
        uint256 numTokens = strategyRewardTokens.length;

        // Clear reward token data fields.

        // Remove approved tokens for harvesting.
        for (uint256 i; i < numTokens; ) {
            _isApprovedAsset[strategyRewardTokens[i++]] = false;
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
            _isUnderlyingToken[currentTokens[i++]] = false;
        }

        _queryTokens();
    }

    /// @notice Returns this strategies reward tokens.
    /// @return An array of reward token addresses.
    function rewardTokens() external view returns (address[] memory) {
        return strategyData.rewardTokens;
    }

    /// @notice Returns this strategies base assets underlying tokens.
    /// @return An array of underlying token addresses.
    function underlyingTokens() external view returns (address[] memory) {
        return strategyData.underlyingTokens;
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Harvests and compounds outstanding vault rewards
    ///         and vests pending rewards.
    /// @dev Only callable by Offchain bots.
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

            // Claim pending Aura rewards.
            sd.rewarder.getReward(address(this), true);

            {
                // Use scoping to avoid stack too deep.
                uint256 numRewardTokens = sd.rewardTokens.length;
                address rewardToken;
                uint256 rewardAmount;
                // Cache DAO Central Registry values to minimize runtime
                // gas costs.
                address feeManager = centralRegistry.feeManager();
                uint256 feePct = centralRegistry.protocolHarvestFee();

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

                    // Take protocol fee for token lockers and strategy bot.
                    rewardAmount = _applyFee(
                        rewardAmount,
                        rewardToken,
                        feePct,
                        feeManager
                    );
                }
            }

            (SwapperLib.Swap[] memory swapActions, uint256 minLPAmount) = abi
                .decode(data, (SwapperLib.Swap[], uint256));
            {
                uint256 numSwapActions = swapActions.length;
                for (uint256 i; i < numSwapActions; ++i) {
                    if (
                        !_isApprovedAsset[swapActions[i].inputToken] ||
                        !_isUnderlyingToken[swapActions[i].outputToken]
                    ) {
                        revert StrategyCToken__UnapprovedAssetSwap();
                    }

                    SwapperLib._swapSafe(centralRegistry, swapActions[i]);
                }
            }

            // Prep liquidity for Balancer Pool.
            {
                // Use scoping to avoid stack too deep.
                uint256 numUnderlyingTokens = sd.underlyingTokens.length;
                address[] memory assets = new address[](numUnderlyingTokens);
                uint256[] memory maxAmountsIn = new uint256[](
                    numUnderlyingTokens
                );
                address underlyingToken;

                for (uint256 i; i < numUnderlyingTokens; ++i) {
                    underlyingToken = sd.underlyingTokens[i];
                    assets[i] = underlyingToken;
                    maxAmountsIn[i] = IERC20(underlyingToken).balanceOf(
                        address(this)
                    );

                    SwapperLib._approveIfNeeded(
                        underlyingToken,
                        address(sd.balancerVault),
                        maxAmountsIn[i]
                    );
                }

                // Deposit assets into Balancer Pool.
                sd.balancerVault.joinPool(
                    sd.balancerPoolId,
                    address(this),
                    address(this),
                    IBalancerVault.JoinPoolRequest(
                        assets,
                        maxAmountsIn,
                        abi.encode(
                            IBalancerVault
                                .JoinKind
                                .EXACT_TOKENS_IN_FOR_BPT_OUT,
                            maxAmountsIn,
                            minLPAmount
                        ),
                        false // do not use internal balances
                    )
                );
            }

            // Deposit assets into Aura.
            yield = IERC20(asset()).balanceOf(address(this));
            if (yield == 0) {
                revert AuraCToken__NoYield();
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

            // Set new yield vesting data.
            _setVestingData(yield);

            emit Harvest(yield);
        }
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Queries reward and underlying tokens directly from
    ///         Aura's smart contracts, then populates storage values.
    function _queryTokens() internal {
        // Query and populate reward token data fields.

        // Add BAL as a reward token, then let Aura tell you what rewards
        // the vault will receive.
        strategyData.rewardTokens.push() = _BAL;
        _isApprovedAsset[_BAL] = true;

        // Add AURA as a reward token, since some vaults do not list AURA
        // as a reward token.
        strategyData.rewardTokens.push() = _AURA;
        _isApprovedAsset[_AURA] = true;

        IBaseRewardPool rewarder = strategyData.rewarder;
        uint256 numTokens = rewarder.extraRewardsLength();

        for (uint256 i; i < numTokens; ) {
            address rewardToken = IStashWrapper(
                IRewards(rewarder.extraRewards(i++)).rewardToken()
            ).baseToken();

            // We do not expect BAL/AURA to be listed as extra rewards,
            // but hypothetically its possible and we do not want to
            // needlessly attempt to double claim.
            if (rewardToken != _BAL && rewardToken != _AURA) {
                strategyData.rewardTokens.push() = rewardToken;
                if (address(rewardToken) != asset()) {
                    _isApprovedAsset[rewardToken] = true;
                }
            }
        }

        // Query and populate underlying token data fields.
        (address[] memory poolTokens, , ) = strategyData
            .balancerVault
            .getPoolTokens(strategyData.balancerPoolId);

        strategyData.underlyingTokens = poolTokens;
        numTokens = poolTokens.length;

        // Add `isUnderlyingToken` mapping value to new
        // flagged underlying tokens.
        for (uint256 i; i < numTokens; ) {
            _isUnderlyingToken[poolTokens[i++]] = true;
        }
    }

    /// @notice Deposits specified amount of assets into Aura
    ///         booster contract.
    /// @param assets The amount of assets to deposit.
    function _afterDeposit(uint256 assets, uint256) internal override {
        IBooster booster = strategyData.booster;
        SafeTransferLib.safeApprove(asset(), address(booster), assets);
        booster.deposit(strategyData.pid, assets, true);
    }

    /// @notice Withdraws specified amount of assets from Aura reward pool.
    /// @param assets The amount of assets to withdraw.
    function _beforeWithdraw(uint256 assets, uint256) internal override {
        strategyData.rewarder.withdrawAndUnwrap(assets, false);
    }
}
