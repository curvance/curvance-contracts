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
import { IMarketManager } from "contracts/interfaces/market/IMarketManager.sol";

contract SimpleZapper is ReentrancyGuard {
    /// TYPES ///

    /// @param pToken The address of the pToken corresponding to Curve lp
    ///               token to be exited.
    /// @param shares The amount of shares to be redeemed.
    /// @param forceRedeemCollateral Whether the collateral should be always
    ///                              reduced from callers collateralPosted.
    struct RedemptionData {
        address pToken;
        uint256 shares;
        bool forceRedeemCollateral;
    }

    /// CONSTANTS ///

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;
    /// @notice Address of the Market Manager linked to this contract.
    IMarketManager public immutable marketManager;
    /// @notice The address of WETH on this chain.
    address public immutable WETH;

    /// ERRORS ///

    error SimpleZapper__PTokenUnderlyingIsNotInputToken();
    error SimpleZapper__ExecutionError();
    error SimpleZapper__InvalidCentralRegistry();
    error SimpleZapper__InvalidMarketManager();
    error SimpleZapper__Unauthorized();
    error SimpleZapper__InsufficientToRepay();

    /// CONSTRUCTOR ///

    receive() external payable {}

    constructor(
        ICentralRegistry centralRegistry_,
        address marketManager_,
        address WETH_
    ) {
        if (
            !ERC165Checker.supportsInterface(
                address(centralRegistry_),
                type(ICentralRegistry).interfaceId
            )
        ) {
            revert SimpleZapper__InvalidCentralRegistry();
        }

        centralRegistry = centralRegistry_;

        // Validate that `marketManager_` is configured as a market manager
        // inside the Central Registry.
        if (!centralRegistry.isMarketManager(marketManager_)) {
            revert SimpleZapper__InvalidMarketManager();
        }

        marketManager = IMarketManager(marketManager_);
        WETH = WETH_;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Swaps then deposits `swapData.outputToken`, a pToken
    ///         underlying, and enters into Curvance position,
    ///         for `recipient`.
    /// @param swapData Swap instruction data to execute the swap.
    /// @param pToken The Curvance pToken address.
    /// @param collateralize Whether the zapped deposit should be
    ///                      collateralized afterwards.
    /// @param recipient Address that should receive Zapped deposit.
    /// @return The output amount received from Zapping.
    function swapAndDeposit(
        SwapperLib.Swap memory swapData,
        address pToken,
        bool collateralize,
        address recipient
    ) external payable nonReentrant returns (uint256) {
        if (CommonLib.isETH(swapData.inputToken)) {
            // Validate message has gas token attached.
            if (swapData.inputAmount != msg.value) {
                revert SimpleZapper__ExecutionError();
            }
        } else {
            SafeTransferLib.safeTransferFrom(
                swapData.inputToken,
                msg.sender,
                address(this),
                swapData.inputAmount
            );
        }

        // Validate that `pToken` is listed inside the associated
        // Market Manager.
        if (!marketManager.isListed(pToken)) {
            revert SimpleZapper__Unauthorized();
        }

        // Execute Swap into pToken.underlying.
        uint256 amount = SwapperLib.swapUnsafe(centralRegistry, swapData);

        // Enter Curvance pToken position.
        return _enterCurvance(pToken, swapData.outputToken, amount, recipient);
    }

    /// @notice Swaps then repays eToken debt inside Curvance for `recipient`.
    /// @dev Sends any excess eToken underlying to `recipient`.
    /// @param swapData Swap instruction data to execute the repayment.
    /// @param eToken The Curvance eToken address.
    /// @param repayAmount The amount of eToken underlying to be repaid.
    /// @param recipient Address that should have its outstanding debt repaid.
    /// @return The excess amount of eToken underlying that was returned
    ///         to `recipient`.
    function swapAndRepay(
        SwapperLib.Swap memory swapData,
        address eToken,
        uint256 repayAmount,
        address recipient
    ) external payable nonReentrant returns (uint256) {
        if (CommonLib.isETH(swapData.inputToken)) {
            // Validate message has gas token attached.
            if (swapData.inputAmount != msg.value) {
                revert SimpleZapper__ExecutionError();
            }
        } else {
            SafeTransferLib.safeTransferFrom(
                swapData.inputToken,
                msg.sender,
                address(this),
                swapData.inputAmount
            );
        }

        // Validate that `eToken` is listed inside the associated
        // Market Manager.
        if (!marketManager.isListed(eToken)) {
            revert SimpleZapper__Unauthorized();
        }

        // Execute swap into eToken underlying.
        SwapperLib.swapUnsafe(centralRegistry, swapData);

        return _repayDebt(eToken, repayAmount, recipient);
    }

    /// @notice Withdraws a Curvance position, and swaps it into
    ///         desired token (swapData.outputToken).
    /// @param redemptionData Struct containing information on redemption action
    ///                       to execute. Containing values:
    ///                       1. The address of the mToken corresponding to
    ///                          position to be exited.
    ///                       2. The amount of shares to redeemed.
    ///                       3. Whether the collateral should be always
    ///                          reduced from callers collateralPosted.
    /// @param swapData Swap instruction data to execute the repayment.
    /// @param recipient Address that should have its outstanding debt repaid.
    /// @return The excess amount of eToken underlying that was returned
    ///         to `recipient`.
    function redeemAndSwap(
        RedemptionData calldata redemptionData,
        SwapperLib.Swap memory swapData,
        address recipient
    ) external nonReentrant returns (uint256) {
        // Exit Curvance position.
        _exitCurvance(
            SimplePToken(redemptionData.pToken),
            redemptionData.shares,
            redemptionData.forceRedeemCollateral,
            swapData.inputToken,
            swapData.inputAmount,
            recipient
        );

        // Execute swap into `swapData.outputToken`.
        uint256 outAmount = SwapperLib.swapUnsafe(
            centralRegistry,
            swapData
        );

        _transferToRecipient(swapData.outputToken, recipient, outAmount);

        return outAmount;
    }

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
            revert SimpleZapper__PTokenUnderlyingIsNotInputToken();
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
                        revert SimpleZapper__ExecutionError();
                }
                // Enter Curvance pToken position,
                // and make sure `recipient` got pTokens.
            } else if (SimplePToken(pToken).deposit(amount, recipient) == 0) {
                revert SimpleZapper__ExecutionError();
        }

        // Remove any leftover approval.
        SwapperLib._removeApprovalIfNeeded(pTokenUnderlying, pToken);

        // Bubble up how many pTokens `recipient` received.
        return IERC20(pToken).balanceOf(recipient) - priorBalance;
    }

    /// @notice Exits a Curvance position.
    /// @param mToken The address of the mToken to be exited.
    /// @param shares The amount of shares to redeemed.
    /// @param forceRedeemCollateral Whether the collateral should be always
    ///                              reduced from callers collateralPosted.
    /// @param underlying The expected underlying token of `pToken`.
    /// @param expectedAssets The amount of assets expected to be redeemed
    ///                       on exiting Curvance position.
    function _exitCurvance(
        SimplePToken mToken,
        uint256 shares,
        bool forceRedeemCollateral,
        address underlying,
        uint256 expectedAssets,
        address recipient
    ) internal {
        if (mToken.underlying() != underlying) {
            revert SimpleZapper__ExecutionError();
        }

        uint256 assets;

        // Transfer underlying tokens to the Zapper.
        if (forceRedeemCollateral && mToken.isPToken()) {
            assets = mToken.redeemCollateralFor(
                shares,
                address(this),
                msg.sender
            );
        } else {
            assets = mToken.redeemFor(shares, address(this), msg.sender);
        }

        // Validate output of redemption is sufficient.
        if (assets < expectedAssets) {
            revert SimpleZapper__ExecutionError();
        }

        // Return any excess assets backed to user.
        if (assets > expectedAssets) {
            _transferToRecipient(
                underlying,
                recipient,
                assets - expectedAssets
            );
        }
    }

    /// @notice Repays Curvance lenders eToken underlying owed on behalf
    ///         of `recipient`.
    /// @param eToken The Curvance eToken address.
    /// @param repayAmount The amount of eToken underlying to be repaid.
    /// @param recipient Address that should have outstanding debt repaid.
    /// @return outAmount The excess amount of eToken underlying that was
    ///                   returned to `recipient`.
    function _repayDebt(
        address eToken,
        uint256 repayAmount,
        address recipient
    ) internal returns (uint256 outAmount) {
        address eTokenUnderlying = EToken(eToken).underlying();
        // We never need to worry about this capturing other peoples balances
        // since the Zapper should never be holding any eToken underlying
        // itself.
        outAmount = IERC20(eTokenUnderlying).balanceOf(address(this));

        // Revert if the swap experienced too much slippage.
        if (outAmount < repayAmount) {
            revert SimpleZapper__InsufficientToRepay();
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
}
