// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Multicall } from "contracts/libraries/Multicall.sol";
import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { CommonLib } from "contracts/libraries/CommonLib.sol";
import { ReentrancyGuard } from "contracts/libraries/ReentrancyGuardTransient.sol";

import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPluginDelegable } from "contracts/interfaces/IPluginDelegable.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IWETH } from "contracts/interfaces/IWETH.sol";

/// @title Curvance Base Zapper.
/// @notice Base contract for executing zap related actions.
/// @dev Curvance zapper contracts enshrine actions that
///      usually would require multiple sequential actions to facilitate,
///      specifically swapping, depositing, redemptions, and repayments.
///
///      Curvance token contracts facilitate these operations through our
///      standard contract interfaces and the plugin system.
///
///      Actions that include collateralization require plugin approval to the
///      corresponding zapper contract, to collateralize on behalf of another
///      user via a zapper both the zapper and the caller must have plugin
///      approval from the account being collateralized on behalf of.
///
///      The "base" contract is the basis on which all zapper contracts are
///      built on top of.
///
///      NOTE: Multicalling swapAndDeposit to perform multiple sequential
///            actions or to update oracle prices is blocked for native gas
///            token denominated actions to prevent double spend transaction
///            failures from delegate call.
///
abstract contract BaseZapper is Multicall, ReentrancyGuard {
    /// TYPES ///

    /// @param cToken The address of the cToken corresponding to the
    ///               redemption action.
    /// @param shares The amount of shares to redeemed.
    /// @param forceRedeemCollateral Whether the collateral should be always
    ///                              reduced from caller's collateralized
    ///                              shares.
    struct RedeemAction {
        address cToken;
        uint256 shares;
        bool forceRedeemCollateral;
    }

    /// CONSTANTS ///

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;
    /// @notice The address of wrapped native token on this chain.
    address public immutable wrappedNative;

    /// ERRORS ///

    error BaseZapper__Unauthorized();
    error BaseZapper__UnderlyingTokenIsNotInputToken();
    error BaseZapper__ExecutionError();
    error BaseZapper__InsufficientAssetsForRepayment();

    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
    /// @param wNative The address of wrapped native token.
    constructor(ICentralRegistry cr, address wNative) {
        CentralRegistryLib._isCentralRegistry(cr);
        centralRegistry = cr;
        wrappedNative = wNative;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Allows contract to receive native tokens.
    receive() external payable {}

    /// INTERNAL FUNCTIONS ///

    /// @notice Routes `asset` token into `cToken`, for `receiver`.
    /// @param cToken The Curvance cToken address.
    /// @param asset The input token address, should match
    ///                   `cToken`.asset().
    /// @param assets The amount of `asset` to deposit into cToken
    ///               position.
    /// @param expectedShares The minimum expected amount of shares received
    ///                       from depositing `assets` of `asset` into
    ///                       `cToken` position.
    /// @param collateralizeFor Whether the deposit should be collateralized,
    ///                         requires plugin approval.
    /// @param receiver Address that should receive Curvance cTokens.
    /// @return shares The output amount of shares received.
    function _enterCurvance(
        address cToken,
        address asset,
        uint256 assets,
        uint256 expectedShares,
        bool collateralizeFor,
        address receiver
    ) internal returns (uint256 shares) {
        _checkAddresses(cToken, asset);

        // Approve `cToken` to take `asset`.
        SwapperLib._approveIfNeeded(asset, cToken, assets);

        // The user is trusting this plugin to not use their delegation
        // approval for nefarious reasons such as keeping them stuck in
        // positions, so lets validate that the receiver is a delegate
        // as well.
        if (collateralizeFor) {
            // Enter Curvance position and collateralize it.
            // This requires plugin approval for this zapper, and
            // if its a different user calling on behalf of `receiver`
            // we make sure that user also has delegation approved.
            if (
                msg.sender == receiver ||
                IPluginDelegable(cToken).isDelegate(receiver, msg.sender)
            ) {
                shares = ICToken(cToken).depositAsCollateralFor(
                    assets,
                    receiver
                );
            } else {
                revert BaseZapper__Unauthorized();
            }
        } else {
            // User wants to enter an uncollateralized a position so we dont
            // care if they are zapping for themselves or someone else.
            shares = ICToken(cToken).deposit(assets, receiver);
        }

        // Make sure sufficient shares were received from deposit action.
        if (shares < expectedShares) {
            revert BaseZapper__ExecutionError();
        }

        // Remove any leftover approval, if any.
        SwapperLib._removeApprovalIfNeeded(asset, cToken);
    }

    /// @notice Exits a Curvance position.
    /// @param cToken The address of the cToken to be redeemed from.
    /// @param asset The expected asset of `cToken`.
    /// @param shares The amount of shares to redeemed.
    /// @param expectedAssets The amount of assets expected to be redeemed
    ///                       on exiting Curvance position.
    /// @param forceRedeemCollateral Whether the collateral should be always
    ///                              reduced from callers collateralPosted.
    /// @param receiver Address that should receive redeemed assets.
    function _exitCurvance(
        address cToken,
        address asset,
        uint256 shares,
        uint256 expectedAssets,
        bool forceRedeemCollateral,
        address receiver
    ) internal {
        _checkAddresses(cToken, asset);
        uint256 assets;

        // Transfer tokens exited to the Zapper.
        if (forceRedeemCollateral) {
            assets = ICToken(cToken).redeemCollateralFor(
                shares,
                address(this),
                msg.sender
            );
        } else {
            assets = ICToken(cToken).redeemFor(
                shares,
                address(this),
                msg.sender
            );
        }

        // Make sure sufficient assets were received from redemption action.
        if (assets < expectedAssets) {
            revert BaseZapper__ExecutionError();
        }

        // Return any excess assets remaining back to the user.
        if (assets > expectedAssets) {
            _transferToRecipient(asset, receiver, assets - expectedAssets);
        }
    }

    /// @notice Repays Curvance lenders outstanding debt owed on behalf
    ///         of `receiver`.
    /// @param borrowableCToken The Curvance token address to repay
    ///                         outstanding debt to.
    /// @param debtAsset The asset token for `borrowableCToken` to repay
    ///                  debt in.
    /// @param assetsHeld The amount of `debtAsset` on hand.
    /// @param repayAssets The amount of debt to be repaid.
    /// @param receiver Address that should have outstanding debt repaid.
    /// @return The amount of `debtAsset` that was returned to `receiver`.
    function _repayDebt(
        address borrowableCToken,
        address debtAsset,
        uint256 assetsHeld,
        uint256 repayAssets,
        address receiver
    ) internal returns (uint256) {
        _checkAddresses(borrowableCToken, debtAsset);

        uint256 totalDebt = IBorrowableCToken(borrowableCToken)
            .debtBalanceUpdated(receiver);

        // Make sure we received at least `repayAssets`.
        if (repayAssets > assetsHeld) {
            revert BaseZapper__InsufficientAssetsForRepayment();
        }

        // Repay as much as possible, up to `totalDebt`.
        repayAssets = assetsHeld > totalDebt ? totalDebt : assetsHeld;

        // Approve `debtAsset` transfer to cToken contract, if needed.
        SwapperLib._approveIfNeeded(debtAsset, borrowableCToken, repayAssets);

        // Execute repayment of outstanding debt.
        IBorrowableCToken(borrowableCToken).repayFor(repayAssets, receiver);

        // Remove any leftover approval, if any.
        SwapperLib._removeApprovalIfNeeded(debtAsset, borrowableCToken);
        assetsHeld -= repayAssets;

        // Transfer any remaining `debtAsset` to caller, we return funds to
        // caller instead of `receiver` for teams integrating on top of
        // Curvance and may want to keep those funds.
        if (assetsHeld > 0) {
            _transferToRecipient(debtAsset, msg.sender, assetsHeld);
        }

        return assetsHeld;
    }

    /// @notice Prepares for an upcoming swap based on input parameters
    ///         accounting for both native gas token routing versus
    ///         erc20s.
    /// @param inputToken The token being inputted into the upcoming swap.
    /// @param inputAmount The amount of `inputToken` to be swapped.
    /// @param depositAsWrappedNative Used when `inputToken` is the native gas
    ///                               token, indicates depositing native token
    ///                               into wrapped version or not.
    function _prepareSwap(
        address inputToken,
        uint256 inputAmount,
        bool depositAsWrappedNative
    ) internal {
        if (CommonLib._isNative(inputToken)) {
            // Validate `inputAmount` token attached equal to `msg.value`.
            if (inputAmount != msg.value) {
                revert BaseZapper__ExecutionError();
            }

            if (depositAsWrappedNative) {
                IWETH(wrappedNative).deposit{ value: inputAmount }();
            }
            return;
        }

        // For ERC20 input flows, there should be no msg.value.
        if (msg.value != 0) {
            revert BaseZapper__ExecutionError();
        }

        SafeTransferLib.safeTransferFrom(
            inputToken,
            msg.sender,
            address(this),
            inputAmount
        );
    }

    /// @notice Checks whether address parameters for a particular zapper
    ///         action on valid.
    /// @param cToken The Curvance cToken address.
    /// @param asset The input token address, should match `cToken`.asset().
    function _checkAddresses(address cToken, address asset) internal view {
        // Validate `cToken` is not the zero address.
        if (cToken == address(0)) {
            revert BaseZapper__ExecutionError();
        }

        // Validate `cToken` is listed in the Market Manager.
        IMarketManager mm = ICToken(cToken).marketManager();
        if (
            !centralRegistry.isMarketManager(address(mm)) ||
            !mm.isListed(cToken)
        ) {
            revert BaseZapper__Unauthorized();
        }

        // Validate `asset` matches asset of cToken contract.
        if (asset != ICToken(cToken).asset()) {
            revert BaseZapper__UnderlyingTokenIsNotInputToken();
        }
    }

    /// @notice Helper function for efficiently transferring tokens
    ///         to desired user.
    /// @param token The token to transfer to `receiver`,
    ///              this can be the network gas token.
    /// @param receiver The user receiving `token`.
    /// @param amount The amount of `token` to be transferred to `receiver`.
    function _transferToRecipient(
        address token,
        address receiver,
        uint256 amount
    ) internal {
        // If the token to refund is the chains' native gas token we wrap
        // then transfer it to prevent callback attack vectors.
        if (CommonLib._isNative(token)) {
            IWETH(wrappedNative).deposit{ value: amount }();
            token = wrappedNative;
        }

        SafeTransferLib.safeTransfer(token, receiver, amount);
    }

    /// @notice Returns the Central Registry contract in interface form.
    function _getCentralRegistry()
        internal
        view
        override
        returns (ICentralRegistry)
    {
        return centralRegistry;
    }
}
