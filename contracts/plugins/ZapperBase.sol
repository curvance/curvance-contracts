// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { CommonLib } from "contracts/libraries/CommonLib.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";
import { ReentrancyGuard } from "contracts/libraries/external/ReentrancyGuard.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPluginDelegable } from "contracts/interfaces/IPluginDelegable.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IMToken } from "contracts/interfaces/IMToken.sol";
import { IWETH } from "contracts/interfaces/IWETH.sol";

abstract contract ZapperBase is ReentrancyGuard {
    /// TYPES ///

    /// @param pToken The address of the pToken corresponding to Curve lp
    ///               token to be exited.
    /// @param shares The amount of shares to redeemed.
    /// @param forceRedeemCollateral Whether the collateral should be always
    ///                              reduced from callers collateralPosted.
    struct RedemptionData {
        address mToken;
        uint256 shares;
        bool forceRedeemCollateral;
    }

    /// CONSTANTS ///

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;
    /// @notice The address of wrapped native token on this chain.
    address public immutable wrappedNative;

    /// ERRORS ///

    error ZapperBase__Unauthorized();
    error ZapperBase__UnderlyingTokenIsNotInputToken();
    error ZapperBase__ExecutionError();
    error ZapperBase__InsufficientToRepay();
    error ZapperBase__InvalidCentralRegistry();

    /// CONSTRUCTOR ///

    receive() external payable {}

    constructor(
        ICentralRegistry centralRegistry_,
        address wrappedNative_
    ) {
        if (
            !ERC165Checker.supportsInterface(
                address(centralRegistry_),
                type(ICentralRegistry).interfaceId
            )
        ) {
            revert ZapperBase__InvalidCentralRegistry();
        }

        centralRegistry = centralRegistry_;
        wrappedNative = wrappedNative_;
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Routes `underlying` token into Curvance mToken contract.
    ///         Either as a pToken position or eToken position.
    /// @param mToken The Curvance pToken address.
    /// @param underlying The input token address, should match
    ///                   mToken.underlying().
    /// @param isPToken Whether `mToken` is a pToken or not.
    /// @param assets The amount of `underlying` to deposit into mToken
    ///               position.
    /// @param expectedShares The minimum expected amount of shares received
    ///                       from depositing `assets` of `underlying` into
    ///                       `mToken` position.
    /// @param collateralize Whether the zapped deposit should be
    ///                      collateralized afterwards.
    /// @param recipient Address that should receive Curvance mTokens.
    /// @return The output amount of shares received.
    function _enterCurvance(
        address mToken,
        address underlying,
        bool isPToken,
        uint256 assets,
        uint256 expectedShares,
        bool collateralize,
        address recipient
    ) internal returns (uint256) {
        // Validate `mToken` exists, otherwise transfer their tokens
        // back and return.
        if (mToken == address(0)) {
            SafeTransferLib.safeTransfer(underlying, recipient, assets);
            return assets;
        }

        // Validate `underlying` matches underlying token of mToken contract.
        if (IMToken(mToken).underlying() != underlying) {
            revert ZapperBase__UnderlyingTokenIsNotInputToken();
        }

        // Approve `mToken` to take `underlying`.
        SwapperLib._approveTokenIfNeeded(underlying, mToken, assets);

        uint256 priorBalance = IERC20(mToken).balanceOf(recipient);
        uint256 shares;

        if (isPToken) {
            // The user is trusting this plugin to not use their delegation
            // approval for nefarious reasons such as keeping them stuck in
            // positions, so lets validate that the recipient is a delegate
            // as well.
            if (collateralize) {
                // Enter Curvance pToken position and collateralize.
                if (msg.sender == recipient) {
                    // User wants to enter and collateralize a position for
                    // themselves.
                    shares = IMToken(mToken).depositAsCollateral(
                        assets,
                        msg.sender
                    );
                } else {
                    // User wants to enter and collateralize a position for
                    // someone else, so we need to validate they have plugin
                    // authority.
                    if (IPluginDelegable(mToken).isDelegate(recipient, msg.sender)) {
                        shares = IMToken(mToken).depositAsCollateralFor(
                            assets,
                            recipient
                        );
                    } else {
                        revert ZapperBase__Unauthorized();
                    }
                }
            } else {
                // User wants to enter an uncollateralized a position so we dont
                // care if they are zapping for themselves or someone else.
                shares = IMToken(mToken).deposit(assets, recipient);
            }
        } else {
            // Depositing into a lending position is permissionless so we can
            // just directly mint for the recipient.
            shares = IMToken(mToken).mintFor(assets, recipient);
        }

        // Make sure `recipient` got sufficient shares.
        if (shares < expectedShares) {
            revert ZapperBase__ExecutionError();
        }

        // Remove any leftover approval.
        SwapperLib._removeApprovalIfNeeded(underlying, mToken);

        // Bubble up how many mTokens `recipient` received.
        return IERC20(mToken).balanceOf(recipient) - priorBalance;
    }

    /// @notice Exits a Curvance position.
    /// @param mToken The address of the mToken to be redeemed from.
    /// @param underlying The expected underlying token of `mToken`.
    /// @param shares The amount of shares to redeemed.
    /// @param expectedAssets The amount of assets expected to be redeemed
    ///                       on exiting Curvance position.
    /// @param forceRedeemCollateral Whether the collateral should be always
    ///                              reduced from callers collateralPosted.
    /// @param recipient Address that should receive redeemed assets.
    function _exitCurvance(
        IMToken mToken,
        address underlying,
        uint256 shares,
        uint256 expectedAssets,
        bool forceRedeemCollateral,
        address recipient
    ) internal {
        // Validate `underlying` matches underlying token of mToken contract.
        if (mToken.underlying() != underlying) {
            revert ZapperBase__ExecutionError();
        }

        uint256 assets;

        // Transfer underlying tokens to the Zapper.
        // We do not care whether `mToken` is a pToken or mToken here because
        // uncollateralized redemption looks the same for both tokens, whereas
        // only pTokens would ever use "forceRedeemCollateral".
        if (forceRedeemCollateral) {
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
            revert ZapperBase__ExecutionError();
        }

        // Return any excess assets remaining back to the user.
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
    /// @param eTokenUnderlying The underlying token for `eToken`.
    /// @param amount The amount of eToken underlying on hand.
    /// @param repayAmount The amount of eToken underlying to be repaid.
    /// @param recipient Address that should have outstanding debt repaid.
    /// @return The excess amount of eToken underlying that was
    ///         returned to `recipient`.
    function _repayDebt(
        address eToken,
        address eTokenUnderlying,
        uint256 amount,
        uint256 repayAmount,
        address recipient
    ) internal returns (uint256) {
        // Revert if the swap experienced too much slippage.
        if (amount < repayAmount) {
            revert ZapperBase__InsufficientToRepay();
        }

        // Approve `eTokenUnderlying` to eToken contract, if necessary.
        SwapperLib._approveTokenIfNeeded(
            eTokenUnderlying,
            eToken,
            repayAmount
        );

        // Execute repayment of eToken debt.
        IMToken(eToken).repayFor(recipient, repayAmount);

        // Remove any excess approval.
        SwapperLib._removeApprovalIfNeeded(eTokenUnderlying, eToken);

        amount -= repayAmount;

        // Transfer any remaining `eTokenUnderlying` to `recipient`.
        if (amount > 0) {
            _transferToRecipient(eTokenUnderlying, recipient, amount);
        }

        return amount;
    }

    /// @notice Prepares for an upcoming swap based on input parameters
    ///         accounting for both native gas token routing versus
    ///         erc20s.
    /// @param inputToken The token being inputted into the upcoming swap.
    /// @param inputAmount The amount of `inputToken` to be swapped.
    /// @param depositAsWrappedNative Used if `inputToken` is the chain's
    ///                               native gas token and should be wrapped
    ///                               before execution.
    function _prepareSwap(
        address inputToken,
        uint256 inputAmount,
        bool depositAsWrappedNative
    ) internal {
        if (CommonLib.isETH(inputToken)) {
            // Validate message has gas token attached.
            if (inputAmount != msg.value) {
                revert ZapperBase__ExecutionError();
            }

            if (depositAsWrappedNative) {
                IWETH(wrappedNative).deposit{ value: inputAmount }();
            }
            return;
        }
        
        SafeTransferLib.safeTransferFrom(
            inputToken,
            msg.sender,
            address(this),
            inputAmount
        );
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
}
