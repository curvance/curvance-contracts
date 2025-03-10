// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { CompoundingPToken } from "contracts/market/token/CompoundingPToken.sol";

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

import { IPendleRouter, ApproxParams, LimitOrderData } from "contracts/interfaces/external/pendle/IPendleRouter.sol";
import { IPMarket } from "contracts/interfaces/external/pendle/IPMarket.sol";
import { IPPrincipalToken } from "contracts/interfaces/external/pendle/IPPrincipalToken.sol";
import { IPYieldToken } from "contracts/interfaces/external/pendle/IPYieldToken.sol";
import { IStandardizedYield } from "contracts/interfaces/external/pendle/IStandardizedYield.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract PendleLPPToken is CompoundingPToken {
    /// TYPES ///

    /// @param router Address of Pendle Router.
    /// @param lp Address of PToken underlying Pendle lp token.
    /// @param sy Address of Standardized Yield for minting pt/yt.
    /// @param pt Address of Pendle principal token.
    /// @param yt Address of Pendle yield token.
    /// @param rewardTokens Array of Pendle reward tokens.
    /// @param underlyingTokens Pendle LP underlying tokens.
    struct StrategyData {
        IPendleRouter router;
        IPMarket lp;
        IStandardizedYield sy;
        IPPrincipalToken pt;
        IPYieldToken yt;
        address[] rewardTokens;
        address[] underlyingTokens;
    }

    /// CONSTANTS ///

    /// STORAGE ///

    /// @notice StrategyData packed configuration data.
    StrategyData public strategyData;

    /// @notice Whether a particular token address is an underlying token
    ///         of this Pendle LP token.
    /// @dev Token => Is underlying token.
    mapping(address => bool) public isUnderlyingToken;

    /// EVENTS ///

    event Harvest(uint256 yield);

    /// CONSTRUCTOR ///

    receive() external payable {}

    constructor(
        ICentralRegistry centralRegistry_,
        IERC20 asset_,
        address marketManager_,
        IPendleRouter router_
    ) CompoundingPToken(centralRegistry_, asset_, marketManager_) {
        strategyData.router = router_;
        strategyData.lp = IPMarket(address(asset_));
        // Query actual Pendle pool configuration data.
        (strategyData.sy, strategyData.pt, strategyData.yt) = strategyData
            .lp
            .readTokens();

        _queryTokens();
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Requeries reward and underlying tokens directly from
    ///         Pendle's smart contracts.
    /// @dev This can be permissionless since this data is 1:1 with dependent
    ///      contracts and takes no parameter values.
    function reQueryTokens() external {
        // Cache current reward tokens.
        address[] memory currentTokens = strategyData.rewardTokens;
        uint256 numTokens = currentTokens.length;

        // Clear reward token data fields.

        // Remove approved tokens for harvester compounding.
        for (uint256 i; i < numTokens; ) {
            isApprovedAsset[currentTokens[i++]] = false;
        }

        delete strategyData.rewardTokens;

        // Cache current underlying tokens.
        currentTokens = strategyData.underlyingTokens;
        numTokens = currentTokens.length;

        // Clear underlying token data fields.

        // Remove `isUnderlyingToken` mapping value from current
        // flagged underlying tokens.
        for (uint256 i; i < numTokens; ) {
            isUnderlyingToken[currentTokens[i++]] = false;
        }

        _queryTokens();
    }

    /// @notice Returns this strategies reward tokens.
    function rewardTokens() external view returns (address[] memory) {
        return strategyData.rewardTokens;
    }

    /// @notice Returns this strategies base assets underlying tokens.
    function underlyingTokens() external view returns (address[] memory) {
        return strategyData.underlyingTokens;
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

            // Claim pending Pendle rewards.
            sd.lp.redeemRewards(address(this));

            (
                SwapperLib.Swap[] memory swapDataArray,
                uint256 minLPAmount,
                ApproxParams memory approx,
                LimitOrderData memory limit
            ) = abi.decode(
                    data,
                    (SwapperLib.Swap[], uint256, ApproxParams, LimitOrderData)
                );

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

            {
                uint256 numSwapData = swapDataArray.length;
                for (uint256 i; i < numSwapData; ++i) {
                    if (
                        !isApprovedAsset[swapDataArray[i].inputToken] ||
                        !isUnderlyingToken[swapDataArray[i].outputToken]
                    ) {
                        revert CompoundingPToken__UnapprovedAssetSwap();
                    }

                    SwapperLib.swapSafe(centralRegistry, swapDataArray[i]);
                }
            }

            {
                uint256 numUnderlyingTokens = sd.underlyingTokens.length;
                address underlyingToken;
                uint256 balance;
                for (uint256 i; i < numUnderlyingTokens; ++i) {
                    underlyingToken = sd.underlyingTokens[i];

                    if (underlyingToken == address(0)) {
                        balance = address(this).balance;
                        if (balance > 0) {
                            // Mint SY in gas tokens.
                            sd.sy.deposit{ value: balance }(
                                address(this),
                                underlyingToken,
                                balance,
                                0
                            );
                        }
                    } else {
                        balance = IERC20(underlyingToken).balanceOf(
                            address(this)
                        );
                        if (balance > 0) {
                            SwapperLib._approveTokenIfNeeded(
                                underlyingToken,
                                address(sd.sy),
                                balance
                            );
                            // Mint SY in ERC20s.
                            sd.sy.deposit(
                                address(this),
                                underlyingToken,
                                balance,
                                0
                            );
                        }
                    }
                }
            }

            {
                uint256 balance = sd.sy.balanceOf(address(this));
                SwapperLib._approveTokenIfNeeded(
                    address(sd.sy),
                    address(sd.router),
                    balance
                );

                // Add liquidity to Pendle lp via SY.
                (yield, ) = sd.router.addLiquiditySingleSy(
                    address(this),
                    address(sd.lp),
                    balance,
                    minLPAmount,
                    approx,
                    limit
                );
            }

            // Update vesting info, query `vestPeriod` here to cache it.
            _setNewVaultData(yield, vestPeriod);

            emit Harvest(yield);
        }
    }

    /// @notice Queries reward and underlying tokens directly from
    ///         Pendle's smart contracts, then populates storage values.
    function _queryTokens() internal {
        // Query and populate reward token data fields.

        // Query Reward tokens from lp contract.
        address[] memory currentTokens = strategyData.lp.getRewardTokens();
        strategyData.rewardTokens = currentTokens;
        uint256 numTokens = currentTokens.length;

        // Approve reward tokens for harvester compounding.
        for (uint256 i; i < numTokens; ) {
            address rewardToken = currentTokens[i++];
            if (rewardToken != asset()) {
                isApprovedAsset[rewardToken] = true;
            }
        }

        // Query and populate underlying token data fields.

        // Query LPs underlying tokens from the standardized yield contract.
        currentTokens = strategyData.sy.getTokensIn();
        strategyData.underlyingTokens = currentTokens;
        numTokens = currentTokens.length;

        for (uint256 i; i < numTokens; ) {
            isUnderlyingToken[currentTokens[i++]] = true;
        }
    }
}
