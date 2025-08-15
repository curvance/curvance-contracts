// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BaseZapper, ICentralRegistry } from "contracts/plugins/BaseZapper.sol";

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { CommonLib } from "contracts/libraries/CommonLib.sol";

import { IRewardManager } from "contracts/interfaces/IRewardManager.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";

contract SimpleRewardZapper is BaseZapper {
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
    error SimpleRewardZapper__InvalidRewardManager();

    /// CONSTRUCTOR ///

    constructor(ICentralRegistry cr, address wNative) BaseZapper(cr, wNative) {
        address rewardManager_ = cr.rewardManager();

        // Validate that Reward Manager is properly configured inside
        // the Central Registry.
        if (rewardManager_ == address(0)) {
            revert SimpleRewardZapper__InvalidRewardManager();
        }

        rewardManager = IRewardManager(rewardManager_);
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Claims Reward Manager rewards, then swaps and transfers
    ///         `swapAction.outputToken` to `receiver`.
    /// @param swapAction Instructions for a swap action containing:
    ///                   inputToken Address of input token to swap from.
    ///                   inputAmount The amount of `inputToken` to swap.
    ///                   outputToken Address of token to swap into.
    ///                   target Address of the swapper, usually an
    ///                          aggregator.
    ///                   slippage The amount of value-loss acceptable from
    ///                            swapping between tokens.
    ///                   call Swap instruction calldata.
    /// @param receiver Address that should receive `swapAction.outputToken`.
    /// @return outAmount The amount of `swapAction.outputToken` that was
    ///                   received by `receiver`.
    function claimAndSwap(
        SwapperLib.Swap memory swapAction,
        address receiver
    ) external nonReentrant returns (uint256 outAmount) {
        // Normally in swappers we check whether the input is a network's gas
        // token, but the Reward Manager is built with non gas token
        // stablecoins as reward tokens. Thus we do not need to check
        // CommonLib._isNative here.

        // Swap input token must match the reward token from the Reward Manager,
        // rather than hardcoding input here this also acts as check that
        // solver API call instructions have been configured properly.
        if (swapAction.inputToken != _getFeeToken()) {
            revert BaseZapper__ExecutionError();
        }

        // Validate that the desired output token is approved.
        if (authorizedOutputToken[swapAction.outputToken] != 2) {
            revert SimpleRewardZapper__UnknownOutputToken();
        }

        // Claim caller rewards and cache reward amount.
        outAmount = _processRewards(msg.sender);

        // Validate swap input amount equals rewards received.
        if (swapAction.inputAmount != outAmount) {
            revert SimpleRewardZapper__InvalidInputAmount();
        }

        // Check how much in rewards were received from the swap.
        outAmount = SwapperLib._swapUnsafe(centralRegistry, swapAction);

        // Make sure we did not somehow end up with an empty swap through
        // all prior checks, slippage checks are native handled by the solver
        // so we do not need to measure slippage % here.
        if (outAmount == 0) {
            revert BaseZapper__ExecutionError();
        }

        // Transfer output tokens to `receiver`.
        _transferToRecipient(swapAction.outputToken, receiver, outAmount);
    }

    /// @notice Claims Reward Manager rewards, then Zaps, then deposits
    ///         `zapperCall.inputToken`, a cToken asset, enters into Curvance
    ///         position, for `receiver`.
    /// @param cToken The Curvance cToken address to deposit into.
    /// @param swapAction Instructions for executing a swap into collateral
    ///                   asset.
    ///                   Containing:
    ///                   inputToken Address of input token to swap from.
    ///                   inputAmount The amount of `inputToken` to swap.
    ///                   outputToken Address of token to swap into.
    ///                   target Address of the swapper, usually an
    ///                          aggregator.
    ///                   slippage The amount of value-loss acceptable from
    ///                            swapping between tokens.
    ///                   call Swap instruction calldata.
    /// @param expectedShares The minimum expected amount of shares received
    ///                       from depositing `amount` of
    ///                       `swapAction.outputToken` into `cToken` position.
    /// @param collateralize Whether the zapped deposit should be
    ///                      collateralized afterwards.
    /// @param receiver Address that should receive `cToken` shares.
    /// @return outAmount The `cToken` output shares received by `receiver`.
    function claimSwapAndDeposit(
        address cToken,
        SwapperLib.Swap memory swapAction,
        uint256 expectedShares,
        bool collateralize,
        address receiver
    ) external nonReentrant returns (uint256 outAmount) {
        // Normally in swappers we check whether the input is a network's gas
        // token, but the Reward Manager is built with non gas token
        // stablecoins as reward tokens. Thus we do not need to check
        // CommonLib._isNative here.

        // Swap input token must match the fee token from the Reward
        // Manager, rather than hardcoding input here this also acts as check
        // that solver API call instructions have been configured properly.
        if (swapAction.inputToken != _getFeeToken()) {
            revert BaseZapper__ExecutionError();
        }

        // We do not need to check for an output token approval here since all
        // cTokens are natively authorized.

        // Claim caller rewards and cache reward amount.
        outAmount = _processRewards(msg.sender);
        // Validate Zap input amount equals rewards received.
        if (swapAction.inputAmount != outAmount) {
            revert SimpleRewardZapper__InvalidInputAmount();
        }

        if (swapAction.inputToken == swapAction.outputToken) {
            outAmount = swapAction.inputAmount;
        } else {
            // Execute swap into cToken asset.
            outAmount = SwapperLib._swapUnsafe(centralRegistry, swapAction);
        }

        // Enter Curvance cToken position.
        outAmount = _enterCurvanceSafe(
            cToken,
            swapAction.outputToken,
            outAmount,
            expectedShares,
            collateralize,
            receiver
        );
    }

    /// @notice Claims Reward Manager rewards, then may swap, then repays
    ///         outstanding debt inside Curvance.
    /// @dev Sends any excess debt token to `receiver`. Only needs to
    ///      swap if `rewardToken` != `borrowableCToken` asset.
    /// @param swapAction Optional instructions for executing a swap into debt
    ///                   asset.
    ///                   Containing:
    ///                   inputToken Address of input token to swap from.
    ///                   inputAmount The amount of `inputToken` to swap.
    ///                   outputToken Address of token to swap into.
    ///                   target Address of the swapper, usually an
    ///                          aggregator.
    ///                   slippage The amount of value-loss acceptable from
    ///                            swapping between tokens.
    ///                   call Swap instruction calldata.
    /// @param borrowableCToken The Curvance token address to repay debt to.
    /// @param repayAssets The amount of debt to be repaid, in assets.
    /// @param receiver Address that should have its outstanding debt repaid.
    /// @return outAmount The excess amount of debt token that was returned to
    ///                   `receiver`.
    function claimSwapAndRepay(
        SwapperLib.Swap memory swapAction,
        address borrowableCToken,
        uint256 repayAssets,
        address receiver
    ) external nonReentrant returns (uint256 outAmount) {
        // Normally in swappers we check whether the input is a network's gas
        // token, but the Reward Manager is built with non gas token
        // stablecoins as reward tokens. Thus we do not need to check
        // CommonLib._isNative here.

        address rewardToken = _getFeeToken();

        // Swap input token must match the reward token from the Reward
        // Manager, rather than hardcoding input here this also acts as check
        // that solver API call instructions have been configured properly.
        if (swapAction.inputToken != rewardToken) {
            revert BaseZapper__ExecutionError();
        }

        // Claim caller rewards and cache reward amount.
        uint256 rewards = _processRewards(msg.sender);

        // Validate swap input amount equals rewards received.
        if (swapAction.inputAmount != rewards) {
            revert SimpleRewardZapper__InvalidInputAmount();
        }
        
        // Cache `borrowableCToken` asset to minimize external calls.
        address debtAsset = ICToken(borrowableCToken).asset();

        if (rewardToken != debtAsset) {
            // Validate that if we are swapping that the output token
            // matches `debtAsset`.
            if (swapAction.outputToken != debtAsset) {
                revert BaseZapper__ExecutionError();
            }

            // Swap from `rewardToken` into `debtAsset`.
            swapAction.inputAmount = SwapperLib._swapUnsafe(
                centralRegistry,
                swapAction
            );
        }

        // Repay `repayAssets` outstanding debt.
        outAmount = _repayDebt(
            borrowableCToken,
            debtAsset,
            swapAction.inputAmount,
            repayAssets,
            receiver
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
    /// @return result The current fee token address.
    function _getFeeToken() internal view returns (address result) {
        result = centralRegistry.feeToken();
    }

    /// @notice Checks whether `user` has rewards, if they do, claim them
    ///         to this contract and bubble up the reward amount.
    /// @param user The address of the user to process rewards for.
    /// @return result The amount of rewards received from processing.
    function _processRewards(address user) internal returns (uint256 result) {
        result = rewardManager.manageRewardsFor(user);
    }

    /// @dev Checks whether the caller has sufficient permissioning.
    function _checkDaoPermissions() internal view {
        if (!centralRegistry.hasDaoPermissions(msg.sender)) {
            revert BaseZapper__Unauthorized();
        }
    }

    /// @dev Checks whether the caller has sufficient permissioning.
    function _checkElevatedPermissions() internal view {
        if (!centralRegistry.hasElevatedPermissions(msg.sender)) {
            revert BaseZapper__Unauthorized();
        }
    }
}
