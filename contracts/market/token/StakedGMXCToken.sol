// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { StrategyCToken, SafeTransferLib, ICentralRegistry, IERC20 } from "contracts/market/token/StrategyCToken.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

import { IRewardRouter } from "contracts/interfaces/external/gmx/IRewardRouter.sol";

contract StakedGMXCToken is StrategyCToken {
    /// CONSTANTS ///

    /// @notice The address of WETH on this chain.
    IERC20 public immutable WETH;

    /// @notice Chain ID for Arbitrum Mainnet where this should be deployed.
    uint256 internal constant _ARBITRUM_CHAIN_ID = 42161;

    /// STORAGE ///

    /// @notice The address of the GMX reward router that distributes WETH
    ///         yield to staked GMX positions.
    IRewardRouter public rewardRouter;

    /// ERRORS ///

    error StakedGMXCToken__SlippageError();
    error StakedGMXCToken__InvalidRewardRouter();
    error StakedGMXCToken__InvalidWETH();
    error StakedGMXCToken__ChainIsNotSupported();

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        IERC20 asset_, // GMX
        address marketManager_,
        address rewardRouter_,
        address weth_,
        uint256 vestPeriod_
    ) StrategyCToken(
        centralRegistry_,
        asset_,
        marketManager_,
        vestPeriod_
    ) {
        if (block.chainid != _ARBITRUM_CHAIN_ID) {
            revert StakedGMXCToken__ChainIsNotSupported();
        }
        if (weth_ == address(0)) {
            revert StakedGMXCToken__InvalidWETH();
        }

        _setRewardRouter(rewardRouter_);

        WETH = IERC20(weth_);

        _isApprovedAsset[weth_] = true;
    }

    /// EXTERNAL FUNCTIONS ///

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

            // Claim pending Staked GMX rewards.
            rewardRouter.handleRewards(
                false, //shouldClaimGmx
                false, //shouldStakeGmx
                false, //shouldClaimEsGmx
                false, //shouldStakeEsGmx
                true, //shouldStakeMultiplierPoints
                true, //shouldClaimWeth
                false //shouldConvertWethToETH
            );
            uint256 rewardAmount = WETH.balanceOf(address(this));

            // If there are no pending rewards, skip swapping logic.
            if (rewardAmount > 0) {
                // Take protocol fee for token lockers and strategy bot.
                rewardAmount = _applyFee(
                    rewardAmount,
                    address(WETH),
                    centralRegistry.protocolHarvestFee(),
                    centralRegistry.feeManager()
                );

                SwapperLib.Swap memory swapData = abi.decode(
                    data,
                    (SwapperLib.Swap)
                );

                if (!_isApprovedAsset[swapData.inputToken]) {
                    // this will be the same check: `swapData.inputToken != address(WETH)`
                    revert StrategyCToken__UnapprovedAssetSwap();
                }

                yield = SwapperLib._swapSafe(centralRegistry, swapData);

                // Make sure swap was routed into GMX.
                if (yield == 0) {
                    revert StakedGMXCToken__SlippageError();
                }
            }

            // Deposit new assets into Staked GMX contract to continue
            // yield farming.
            _afterDeposit(yield, 0);

            // Set new yield vesting data.
            _setVestingData(yield);

            emit Harvest(yield);
        }
    }

    /// @notice Set Reward Router address.
    function setRewardRouter(address newRouter) external {
        _checkDaoPermissions();

        _setRewardRouter(newRouter);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Set Reward Router address.
    function _setRewardRouter(address newRouter) internal {
        if (newRouter == address(0)) {
            revert StakedGMXCToken__InvalidRewardRouter();
        }

        rewardRouter = IRewardRouter(newRouter);
    }

    /// @notice Deposits specified amount of assets into Staked GMX contract.
    /// @param assets The amount of assets to deposit.
    function _afterDeposit(uint256 assets, uint256) internal override {
        SafeTransferLib.safeApprove(
            asset(),
            rewardRouter.stakedGmxTracker(),
            assets
        );
        rewardRouter.stakeGmx(assets);
    }

    /// @notice Withdraws specified amount of assets from Staked GMX contract.
    /// @param assets The amount of assets to withdraw.
    function _beforeWithdraw(uint256 assets, uint256) internal override {
        rewardRouter.unstakeGmx(assets);
    }
}
