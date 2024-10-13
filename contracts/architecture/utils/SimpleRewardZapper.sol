// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { SimplePToken } from "contracts/market/token/SimplePToken.sol";
import { EToken } from "contracts/market/token/EToken.sol";

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { CommonLib } from "contracts/libraries/CommonLib.sol";
import { ReentrancyGuard } from "contracts/libraries/external/ReentrancyGuard.sol";
import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IPluginDelegable } from "contracts/interfaces/IPluginDelegable.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IRewardManager } from "contracts/interfaces/IRewardManager.sol";
import { IMarketManager } from "contracts/interfaces/market/IMarketManager.sol";

contract SimpleRewardZapper is ReentrancyGuard {
    /// CONSTANTS ///

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;
    /// @notice Curvance Reward Manager.
    IRewardManager public immutable rewardManager;
    /// @notice The address of the Reward Manager Reward Token on this chain.
    address public immutable rewardToken;
    /// @notice The address of WETH on this chain.
    address public immutable WETH;

    /// @dev `bytes4(keccak256(bytes("SimpleRewardZapper__Unauthorized()")))`.
    uint256 internal constant _UNAUTHORIZED_SELECTOR = 0xf52eef9e;

    /// STORAGE ///

    /// @notice Whether a market manager is approved for Zapping.
    /// @dev Output token => 2 = yes; 0 or 1 = no.
    mapping(address => uint256) public authorizedMarketManager;

    /// @notice Whether a token is approved for swapping.
    /// @dev Output token => 2 = yes; 0 or 1 = no.
    mapping(address => uint256) public authorizedOutputToken;

    /// ERRORS ///

    error SimpleRewardZapper__PTokenUnderlyingIsNotInputToken();
    error SimpleRewardZapper__UnknownOutputToken();
    error SimpleRewardZapper__IsAlreadyAuthorized();
    error SimpleRewardZapper__IsNotAuthorized();
    error SimpleRewardZapper__InvalidInputAmount();
    error SimpleRewardZapper__InsufficientToRepay();
    error SimpleRewardZapper__ExecutionError();
    error SimpleRewardZapper__Unauthorized();
    error SimpleRewardZapper__InvalidMarketManager();
    error SimpleRewardZapper__InvalidCentralRegistry();
    error SimpleRewardZapper__InvalidRewardManager();

    /// CONSTRUCTOR ///

    receive() external payable {}

    constructor(ICentralRegistry centralRegistry_, address WETH_) {
        if (
            !ERC165Checker.supportsInterface(
                address(centralRegistry_),
                type(ICentralRegistry).interfaceId
            )
        ) {
            revert SimpleRewardZapper__InvalidCentralRegistry();
        }

        address rewardManager_ = centralRegistry_.rewardManager();

        // Validate that Reward Manager is properly configured inside
        // the Central Registry.
        if (rewardManager_ == address(0)) {
            revert SimpleRewardZapper__InvalidRewardManager();
        }

        centralRegistry = centralRegistry_;
        rewardManager = IRewardManager(rewardManager_);
        rewardToken = IRewardManager(rewardManager_).rewardToken();
        WETH = WETH_;
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
        // CommonLib.isETH here.

        // Swap input token must match the reward token from the Reward Manager,
        // rather than hardcoding input here this also acts as check that
        // solver API call instructions have been configured properly.
        if (swapData.inputToken != rewardToken) {
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
        outAmount = SwapperLib.swapUnsafe(centralRegistry, swapData);

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
    ///         `zapperCall.inputToken`, a pToken underlying, and enters
    ///         into Curvance collateral position.
    /// @param swapData Swap instruction data to execute the swap.
    /// @param marketManager The Curvance market manager address which has
    ///                      listed `pToken`.
    /// @param pToken The Curvance pToken address.
    /// @param recipient Address that should receive Zapped deposit.
    /// @return The output amount of pTokens received from Zapping.
    function claimSwapAndDeposit(
        SwapperLib.Swap memory swapData,
        address marketManager,
        address pToken,
        address recipient
    ) external nonReentrant returns (uint256) {
        // Normally in swappers we check whether the input is a network's gas
        // token, but the Reward Manager is built with non gas token
        // stablecoins as reward tokens. Thus we do not need to check
        // CommonLib.isETH here.

        // Swap input token must match the reward token from the Reward Manager,
        // rather than hardcoding input here this also acts as check that
        // solver API call instructions have been configured properly.
        if (swapData.inputToken != rewardToken) {
            revert SimpleRewardZapper__ExecutionError();
        }

        // Validate that the desired Market Manager is approved.
        if (authorizedMarketManager[marketManager] != 2) {
            revert SimpleRewardZapper__UnknownOutputToken();
        }

        // Validate that `pToken` is listed inside the associated
        // Market Manager.
        if (!IMarketManager(marketManager).isListed(pToken)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        // We do not need to check for an output token approval here since all
        // pTokens are natively authorized.

        // Claim caller rewards and cache reward amount.
        uint256 rewards = _processRewards(msg.sender);

        // Validate Zap input amount equals rewards received.
        if (swapData.inputAmount != rewards) {
            revert SimpleRewardZapper__InvalidInputAmount();
        }

        // Execute Swap into pToken.underlying.
        uint256 amount = SwapperLib.swapUnsafe(centralRegistry, swapData);

        // Enter Curvance pToken position.
        return _enterCurvance(pToken, swapData.outputToken, amount, recipient);
    }

    /// @notice Claims Reward Manager rewards, then may swap, then repays
    ///         eToken debt inside Curvance.
    /// @dev Sends any excess eToken underlying to `recipient`.
    ///      Only needs to swap if `rewardToken` != eToken underlying.
    /// @param swapData Optional swap instruction data to execute the repayment.
    /// @param marketManager The Curvance market manager address which has
    ///                      listed `eToken`.
    /// @param eToken The Curvance eToken address.
    /// @param repayAmount The amount of eToken underlying to be repaid.
    /// @param recipient Address that should have its outstanding debt repaid.
    /// @return The excess amount of eToken underlying that was returned
    ///         to `recipient`.
    function claimSwapAndRepay(
        SwapperLib.Swap memory swapData,
        address marketManager,
        address eToken,
        uint256 repayAmount,
        address recipient
    ) external nonReentrant returns (uint256) {
        // Normally in swappers we check whether the input is a network's gas
        // token, but the Reward Manager is built with non gas token
        // stablecoins as reward tokens. Thus we do not need to check
        // CommonLib.isETH here.

        // Swap input token must match the reward token from the Reward Manager,
        // rather than hardcoding input here this also acts as check that
        // solver API call instructions have been configured properly.
        if (swapData.inputToken != rewardToken) {
            revert SimpleRewardZapper__ExecutionError();
        }

        // Validate that the desired Market Manager is approved.
        if (authorizedMarketManager[marketManager] != 2) {
            revert SimpleRewardZapper__UnknownOutputToken();
        }

        // Validate that `eToken` is listed inside the associated
        // Market Manager.
        if (!IMarketManager(marketManager).isListed(eToken)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        // Claim caller rewards and cache reward amount.
        uint256 rewards = _processRewards(msg.sender);

        // Validate swap input amount equals rewards received.
        if (swapData.inputAmount != rewards) {
            revert SimpleRewardZapper__InvalidInputAmount();
        }

        // Cache underlying to minimize external calls.
        address eTokenUnderlying = EToken(eToken).underlying();

        if (rewardToken != eTokenUnderlying) {
            // Validate that if we are swapping that the output token
            // matches the underlying needed.
            if (swapData.outputToken != eTokenUnderlying) {
                revert SimpleRewardZapper__ExecutionError();
            }

            // Swap from reward token into `eTokenUnderlying`.
            SwapperLib.swapUnsafe(centralRegistry, swapData);
        }

        // Repay Curvance eToken debt.
        return _repayDebt(eToken, eTokenUnderlying, repayAmount, recipient);
    }

    /// PERMISSIONED EXTERNAL FUNCTIONS ///

    /// @notice Authorizes a market manager for Zapping.
    /// @dev Only callable on by an entity with elevated DAO permissions.
    ///      Such as the timelock controller.
    /// @param newMarketManager The address of the market manager to authorize.
    function addAuthorizedMarketManager(address newMarketManager) external {
        _checkElevatedPermissions();

        // Validate `newMarketManager` is
        if (authorizedMarketManager[newMarketManager] == 2) {
            revert SimpleRewardZapper__IsAlreadyAuthorized();
        }

        // Validate that `newMarketManager` is configured as a market manager
        // inside the Central Registry.
        if (!centralRegistry.isMarketManager(newMarketManager)) {
            revert SimpleRewardZapper__InvalidMarketManager();
        }

        // Authorize new Market Manager.
        authorizedMarketManager[newMarketManager] = 2;
    }

    /// @notice Removes authorization of market manager for Zapping.
    /// @dev Only callable on by an entity with DAO permissions or higher.
    /// @param currentMarketManager The address of the market manager to deauthorize.
    function removeAuthorizedMarketManager(
        address currentMarketManager
    ) external {
        _checkDaoPermissions();

        if (authorizedMarketManager[currentMarketManager] != 2) {
            revert SimpleRewardZapper__IsNotAuthorized();
        }

        // Deauthorize current Market Manager.
        authorizedMarketManager[currentMarketManager] = 1;
    }

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

    /// @notice Deposits pToken underlying into Curvance pToken contract.
    /// @param pToken The Curvance pToken address.
    /// @param inputToken The input token address, should match
    ///                   pToken.underlying().
    /// @param amount The amount of `inputToken` to deposit into pToken
    ///               position.
    /// @param collateralize Whether the zapped position deposit should be
    ///                      collateralized afterwards.
    /// @param recipient Address that should receive Curvance pTokens.
    /// @return The output amount of pTokens received.
    function _enterCurvance(
        address pToken,
        address inputToken,
        uint256 amount,
        bool collateralize,
        address recipient
    ) internal returns (uint256) {
        // Validate inputToken matches underlying token of pToken contract.
        if (SimplePToken(pToken).underlying() != inputToken) {
            revert SimpleRewardZapper__PTokenUnderlyingIsNotInputToken();
        }

        // Approve pToken to take `inputToken`.
        SwapperLib._approveTokenIfNeeded(inputToken, pToken, amount);

        uint256 priorBalance = IERC20(pToken).balanceOf(recipient);

        // The user is trusting this plugin to not use their delegation
        // approval for nefarious reasons such as keeping them stuck in
        // positions, so lets validate that the recipient is a delegate
        // as well.
        // Enter Curvance pToken position and collateralize,
        // and make sure `recipient` got pTokens.
        if (
            collateralize &&
            IPluginDelegable(pToken).isDelegate(recipient, msg.sender)
            ) {
                if (SimplePToken(pToken).depositAsCollateralFor(
                    amount,
                    recipient
                    ) == 0) {
                        revert SimpleRewardZapper__ExecutionError();
                }
                // Enter Curvance pToken position,
                // and make sure `recipient` got pTokens.
            } else if (SimplePToken(pToken).deposit(amount, recipient) == 0) {
                revert SimpleRewardZapper__ExecutionError();
        }

        // Remove any leftover approval.
        SwapperLib._removeApprovalIfNeeded(pTokenUnderlying, pToken);

        // Bubble up how many pTokens `recipient` received.
        return IERC20(pToken).balanceOf(recipient) - priorBalance;
    }

    /// @notice Repays Curvance lenders eToken underlying owed on behalf
    ///         of `recipient`.
    /// @param eToken The Curvance eToken address.
    /// @param eTokenUnderlying The underlying token for `eToken`.
    /// @param repayAmount The amount of eToken underlying to be repaid.
    /// @param recipient Address that should have outstanding debt repaid.
    /// @return outAmount The excess amount of eToken underlying that was
    ///                   returned to `recipient`.
    function _repayDebt(
        address eToken,
        address eTokenUnderlying,
        uint256 repayAmount,
        address recipient
    ) internal returns (uint256 outAmount) {
        // Manually query balance here since its possible we did not swap if
        // rewardToken == outputToken.
        // We also never need to worry about this capturing other peoples
        // balances since the Zapper should never be holding any reward token,
        // or eToken underlying itself.
        outAmount = IERC20(eTokenUnderlying).balanceOf(address(this));

        // Revert if the swap experienced too much slippage.
        if (outAmount < repayAmount) {
            revert SimpleRewardZapper__InsufficientToRepay();
        }

        // Approve `eTokenUnderlying` to eToken contract, if necessary.
        SwapperLib._approveTokenIfNeeded(
            eTokenUnderlying,
            eToken,
            repayAmount
        );

        // Execute repayment of eToken debt.
        EToken(eToken).repayFor(recipient, repayAmount);

        // Remove any excess approval.
        SwapperLib._removeApprovalIfNeeded(eTokenUnderlying, eToken);

        outAmount -= repayAmount;

        // Transfer any remaining `eTokenUnderlying` to `recipient`.
        if (outAmount > 0) {
            _transferToRecipient(eTokenUnderlying, recipient, outAmount);
        }
    }

    /// @notice Checks whether `user` has rewards, if they do, claim them
    ///         to this contract and bubble up the reward amount.
    /// @param user The address of the user to process rewards for.
    /// @return The amount of rewards received from processing.
    function _processRewards(address user) internal returns (uint256) {
        return rewardManager.manageRewardsFor(user);
    }

    /// @notice Helper function for efficiently transferring tokens
    ///         to desired user.
    /// @param token The token to transfer to `recipient`,
    ///              this can be the network gas token.
    /// @param recipient The user receiving `token`.
    /// @param amount The amount of `token` to be transferred to `recipient`.
    function _transferToRecipient(
        address token,
        address recipient,
        uint256 amount
    ) internal {
        if (CommonLib.isETH(token)) {
            return SafeTransferLib.safeTransferETH(recipient, amount);
        }

        SafeTransferLib.safeTransfer(token, recipient, amount);
    }

    /// @dev Internal helper for reverting efficiently.
    function _revert(uint256 s) internal pure {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, s)
            revert(0x1c, 0x04)
        }
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
