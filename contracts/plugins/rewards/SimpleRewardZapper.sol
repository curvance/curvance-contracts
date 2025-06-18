// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ZapperBase } from "contracts/plugins/ZapperBase.sol";

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { CommonLib } from "contracts/libraries/CommonLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IRewardManager } from "contracts/interfaces/IRewardManager.sol";
import { IMToken } from "contracts/interfaces/IMToken.sol";

contract SimpleRewardZapper is ZapperBase {
    /// CONSTANTS ///

    /// @notice Curvance Reward Manager.
    IRewardManager public immutable rewardManager;

    /// STORAGE ///

    /// @notice Whether a token is approved for swapping.
    /// @dev Output token => 2 = yes; 0 or 1 = no.
    mapping(address => uint256) public authorizedOutputToken;

    /// ERRORS ///

    error SimpleRewardZapper__UnknownOutputToken();
    error SimpleRewardZapper__IsAlreadyAuthorized();
    error SimpleRewardZapper__IsNotAuthorized();
    error SimpleRewardZapper__InvalidInputAmount();
    error SimpleRewardZapper__ExecutionError();
    error SimpleRewardZapper__InvalidRewardManager();

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address wrappedNative_
    ) ZapperBase(centralRegistry_, wrappedNative_) {
        address rewardManager_ = centralRegistry_.rewardManager();

        // Validate that Reward Manager is properly configured inside
        // the Central Registry.
        if (rewardManager_ == address(0)) {
            revert SimpleRewardZapper__InvalidRewardManager();
        }

        rewardManager = IRewardManager(rewardManager_);
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Claims Reward Manager rewards, then swaps and transfers
    ///         `swapData.outputToken` to `recipient`.
    /// @param swapData Swap instruction data.
    /// @param recipient Address that should receive swapped output.
    /// @return outAmount The output amount received from swapping.
    function claimAndSwap(
        SwapperLib.Swap memory swapData,
        address recipient
    ) external nonReentrant returns (uint256 outAmount) {
        // Normally in swappers we check whether the input is a network's gas
        // token, but the Reward Manager is built with non gas token
        // stablecoins as reward tokens. Thus we do not need to check
        // CommonLib._isETH here.

        // Swap input token must match the reward token from the Reward Manager,
        // rather than hardcoding input here this also acts as check that
        // solver API call instructions have been configured properly.
        if (swapData.inputToken != _getFeeToken()) {
            revert SimpleRewardZapper__ExecutionError();
        }

        // Validate that the desired output token is approved.
        if (authorizedOutputToken[swapData.outputToken] != 2) {
            revert SimpleRewardZapper__UnknownOutputToken();
        }

        // Claim caller rewards and cache reward amount.
        uint256 rewards = _processRewards(msg.sender);

        // Validate swap input amount equals rewards received.
        if (swapData.inputAmount != rewards) {
            revert SimpleRewardZapper__InvalidInputAmount();
        }

        // Check how much in rewards were received from the swap.
        outAmount = SwapperLib._swapUnsafe(centralRegistry, swapData);

        // Make sure we did not somehow end up with an empty swap through
        // all prior checks, slippage checks are native handled by the solver
        // so we do not need to measure slippage % here.
        if (outAmount == 0) {
            revert SimpleRewardZapper__ExecutionError();
        }

        // Transfer output tokens to `recipient`.
        _transferToRecipient(swapData.outputToken, recipient, outAmount);
    }

    /// @notice Claims Reward Manager rewards, then Zaps, then deposits
    ///         `zapperCall.inputToken`, a mToken underlying, and enters
    ///         into Curvance collateral position.
    /// @param mToken The Curvance mToken address.
    /// @param isPToken Whether `mToken` is a pToken or not.
    /// @param swapData Swap instruction data to execute the swap.
    /// @param expectedShares The minimum expected amount of shares received
    ///                       from depositing `amount` of `swapData.outputToken`
    ///                       into `mToken` position.
    /// @param collateralize Whether the zapped deposit should be
    ///                      collateralized afterwards.
    /// @param recipient Address that should receive Zapped deposit.
    /// @return The output amount of mToken shares received from Zapping.
    function claimSwapAndDeposit(
        address mToken,
        bool isPToken,
        SwapperLib.Swap memory swapData,
        uint256 expectedShares,
        bool collateralize,
        address recipient
    ) external nonReentrant returns (uint256) {
        // Normally in swappers we check whether the input is a network's gas
        // token, but the Reward Manager is built with non gas token
        // stablecoins as reward tokens. Thus we do not need to check
        // CommonLib._isETH here.

        // Swap input token must match the reward token from the Reward Manager,
        // rather than hardcoding input here this also acts as check that
        // solver API call instructions have been configured properly.
        if (swapData.inputToken != _getFeeToken()) {
            revert SimpleRewardZapper__ExecutionError();
        }

        // We do not need to check for an output token approval here since all
        // pTokens are natively authorized.

        // Claim caller rewards and cache reward amount.
        uint256 rewards = _processRewards(msg.sender);
        // Validate Zap input amount equals rewards received.
        if (swapData.inputAmount != rewards) {
            revert SimpleRewardZapper__InvalidInputAmount();
        }

        if (swapData.inputToken == swapData.outputToken) {
            rewards = swapData.inputAmount;
        } else {
            // Execute swap into mToken underlying.
            rewards = SwapperLib._swapUnsafe(centralRegistry, swapData);
        }

        // Enter Curvance mToken position.
        return
            _enterCurvance(
                mToken,
                swapData.outputToken,
                isPToken,
                rewards,
                expectedShares,
                collateralize,
                recipient
            );
    }

    /// @notice Claims Reward Manager rewards, then may swap, then repays
    ///         eToken debt inside Curvance.
    /// @dev Sends any excess eToken underlying to `recipient`.
    ///      Only needs to swap if `rewardToken` != eToken underlying.
    /// @param swapData Optional swap instruction data to execute the repayment.
    /// @param eToken The Curvance eToken address.
    /// @param repayAmount The amount of eToken underlying to be repaid.
    /// @param recipient Address that should have its outstanding debt repaid.
    /// @return The excess amount of eToken underlying that was returned
    ///         to `recipient`.
    function claimSwapAndRepay(
        SwapperLib.Swap memory swapData,
        address eToken,
        uint256 repayAmount,
        address recipient
    ) external nonReentrant returns (uint256) {
        // Normally in swappers we check whether the input is a network's gas
        // token, but the Reward Manager is built with non gas token
        // stablecoins as reward tokens. Thus we do not need to check
        // CommonLib._isETH here.

        address rewardToken = _getFeeToken();

        // Swap input token must match the reward token from the Reward Manager,
        // rather than hardcoding input here this also acts as check that
        // solver API call instructions have been configured properly.
        if (swapData.inputToken != rewardToken) {
            revert SimpleRewardZapper__ExecutionError();
        }

        // Claim caller rewards and cache reward amount.
        uint256 rewards = _processRewards(msg.sender);

        // Validate swap input amount equals rewards received.
        if (swapData.inputAmount != rewards) {
            revert SimpleRewardZapper__InvalidInputAmount();
        }

        // Cache underlying to minimize external calls.
        address eTokenUnderlying = IMToken(eToken).asset();

        if (rewardToken != eTokenUnderlying) {
            // Validate that if we are swapping that the output token
            // matches the underlying needed.
            if (swapData.outputToken != eTokenUnderlying) {
                revert SimpleRewardZapper__ExecutionError();
            }

            // Swap from reward token into `eTokenUnderlying`.
            swapData.inputAmount = SwapperLib._swapUnsafe(
                centralRegistry,
                swapData
            );
        }

        // Repay Curvance eToken debt.
        return
            _repayDebt(
                eToken,
                eTokenUnderlying,
                swapData.inputAmount,
                repayAmount,
                recipient
            );
    }

    /// PERMISSIONED EXTERNAL FUNCTIONS ///

    /// @notice Authorizes a new reward token.
    /// @dev Only callable on by an entity with elevated DAO permissions.
    ///      Such as the timelock controller.
    /// @param outputToken The address of the token to authorize.
    function addAuthorizedOutputToken(address outputToken) external {
        _checkElevatedPermissions();

        if (outputToken == address(0)) {
            revert SimpleRewardZapper__UnknownOutputToken();
        }

        if (authorizedOutputToken[outputToken] == 2) {
            revert SimpleRewardZapper__IsAlreadyAuthorized();
        }

        authorizedOutputToken[outputToken] = 2;
    }

    /// @notice Removes an authorized reward token.
    /// @dev Only callable on by an entity with DAO permissions or higher.
    /// @param outputToken The address of the token to deauthorize.
    function removeAuthorizedOutputToken(address outputToken) external {
        _checkDaoPermissions();

        if (outputToken == address(0)) {
            revert SimpleRewardZapper__UnknownOutputToken();
        }

        if (authorizedOutputToken[outputToken] != 2) {
            revert SimpleRewardZapper__IsNotAuthorized();
        }

        authorizedOutputToken[outputToken] = 1;
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Returns the current fee token address.
    /// @return The current fee token address.
    function _getFeeToken() internal view returns (address) {
        return centralRegistry.feeToken();
    }

    /// @notice Checks whether `user` has rewards, if they do, claim them
    ///         to this contract and bubble up the reward amount.
    /// @param user The address of the user to process rewards for.
    /// @return The amount of rewards received from processing.
    function _processRewards(address user) internal returns (uint256) {
        return rewardManager.manageRewardsFor(user);
    }

    /// @dev Checks whether the caller has sufficient permissioning.
    function _checkDaoPermissions() internal view {
        if (!centralRegistry.hasDaoPermissions(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }
    }

    /// @dev Checks whether the caller has sufficient permissioning.
    function _checkElevatedPermissions() internal view {
        if (!centralRegistry.hasElevatedPermissions(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }
    }
}
