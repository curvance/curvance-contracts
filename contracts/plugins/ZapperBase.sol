// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { CommonLib } from "contracts/libraries/CommonLib.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";
import { ReentrancyGuard } from "contracts/libraries/external/ReentrancyGuard.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPluginDelegable } from "contracts/interfaces/IPluginDelegable.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IWETH } from "contracts/interfaces/IWETH.sol";

abstract contract ZapperBase is ReentrancyGuard {
    /// TYPES ///

    /// @param cToken The address of the cToken corresponding to the proposed
    ///               redemption.
    /// @param shares The amount of shares to redeemed.
    /// @param forceRedeemCollateral Whether the collateral should be always
    ///                              reduced from callers collateralPosted.
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

    /// @dev `bytes4(keccak256(bytes("ZapperBase__Unauthorized()")))`.
    uint256 internal constant _UNAUTHORIZED_SELECTOR = 0xa1b2f000;

    /// ERRORS ///

    error ZapperBase__Unauthorized();
    error ZapperBase__UnderlyingTokenIsNotInputToken();
    error ZapperBase__ExecutionError();
    error ZapperBase__InsufficientToRepay();
    error ZapperBase__InvalidCentralRegistry();

    /// CONSTRUCTOR ///

    constructor(ICentralRegistry centralRegistry_, address wrappedNative_) {
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

    /// EXTERNAL FUNCTIONS ///

    /// @notice Allows contract to receive native tokens.
    receive() external payable {}

    /// INTERNAL FUNCTIONS ///

    /// @notice Routes `underlying` token into a Curvance token contract.
    /// @param cToken The Curvance cToken address.
    /// @param underlying The input token address, should match
    ///                   `cToken`.asset().
    /// @param assets The amount of `underlying` to deposit into cToken
    ///               position.
    /// @param expectedShares The minimum expected amount of shares received
    ///                       from depositing `assets` of `underlying` into
    ///                       `cToken` position.
    /// @param collateralizeFor Whether the deposit should be collateralized,
    ///                         requires plugin approval.
    /// @param receiver Address that should receive Curvance cTokens.
    /// @return shares The output amount of shares received.
    function _enterCurvanceSafe(
        address cToken,
        address underlying,
        uint256 assets,
        uint256 expectedShares,
        bool collateralizeFor,
        address receiver
    ) internal returns (uint256 shares) {
        _checkAddresses(cToken, underlying);

        shares = _enterCurvance(
            cToken,
            underlying,
            assets,
            expectedShares,
            collateralizeFor,
            receiver
        );
    }

    /// @notice Routes `underlying` token into a Curvance token contract.
    /// @param cToken The Curvance cToken address.
    /// @param underlying The input token address, should match
    ///                   `cToken`.asset().
    /// @param assets The amount of `underlying` to deposit into cToken
    ///               position.
    /// @param expectedShares The minimum expected amount of shares received
    ///                       from depositing `assets` of `underlying` into
    ///                       `cToken` position.
    /// @param collateralizeFor Whether the deposit should be collateralized,
    ///                         requires plugin approval.
    /// @param receiver Address that should receive Curvance cTokens.
    /// @return shares The output amount of shares received.
    function _enterCurvance(
        address cToken,
        address underlying,
        uint256 assets,
        uint256 expectedShares,
        bool collateralizeFor,
        address receiver
    ) internal returns (uint256 shares) {
        // Approve `cToken` to take `underlying`.
        SwapperLib._approveIfNeeded(underlying, cToken, assets);

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
                IPluginDelegable(cToken).isDelegate(
                    receiver,
                    msg.sender
                )
            ) {
                shares = ICToken(cToken).depositAsCollateralFor(
                    assets,
                    receiver
                );
            } else {
                _revert(_UNAUTHORIZED_SELECTOR);
            }
        } else {
            // User wants to enter an uncollateralized a position so we dont
            // care if they are zapping for themselves or someone else.
            shares = ICToken(cToken).deposit(assets, receiver);
        }

        // Make sure `receiver` got sufficient shares.
        if (shares < expectedShares) {
            revert ZapperBase__ExecutionError();
        }

        // Remove any leftover approval.
        SwapperLib._removeApprovalIfNeeded(underlying, cToken);
    }

    /// @notice Exits a Curvance position.
    /// @param cToken The address of the cToken to be redeemed from.
    /// @param underlying The expected underlying token of `cToken`.
    /// @param shares The amount of shares to redeemed.
    /// @param expectedAssets The amount of assets expected to be redeemed
    ///                       on exiting Curvance position.
    /// @param forceRedeemCollateral Whether the collateral should be always
    ///                              reduced from callers collateralPosted.
    /// @param receiver Address that should receive redeemed assets.
    function _exitCurvanceSafe(
        address cToken,
        address underlying,
        uint256 shares,
        uint256 expectedAssets,
        bool forceRedeemCollateral,
        address receiver
    ) internal {
        _checkAddresses(cToken, underlying);

        _exitCurvance(
            cToken,
            underlying,
            shares,
            expectedAssets,
            forceRedeemCollateral,
            receiver
        );
    }

    /// @notice Exits a Curvance position.
    /// @param cToken The address of the cToken to be redeemed from.
    /// @param underlying The expected underlying token of `cToken`.
    /// @param shares The amount of shares to redeemed.
    /// @param expectedAssets The amount of assets expected to be redeemed
    ///                       on exiting Curvance position.
    /// @param forceRedeemCollateral Whether the collateral should be always
    ///                              reduced from callers collateralPosted.
    /// @param receiver Address that should receive redeemed assets.
    function _exitCurvance(
        address cToken,
        address underlying,
        uint256 shares,
        uint256 expectedAssets,
        bool forceRedeemCollateral,
        address receiver
    ) internal {
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

        // Validate output of redemption is sufficient.
        if (assets < expectedAssets) {
            revert ZapperBase__ExecutionError();
        }

        // Return any excess assets remaining back to the user.
        if (assets > expectedAssets) {
            _transferToRecipient(
                underlying,
                receiver,
                assets - expectedAssets
            );
        }
    }

    /// @notice Repays Curvance lenders outstanding debt owed on behalf
    ///         of `receiver`.
    /// @param borrowableCToken The Curvance token address to repay
    ///                         outstanding debt to.
    /// @param debtAsset The underlying token for `borrowableCToken` to repay
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
        // Revert if the swap experienced too much slippage.
        if (assetsHeld < repayAssets) {
            revert ZapperBase__InsufficientToRepay();
        }

        // Approve `debtAsset` transfer to cToken contract, if needed.
        SwapperLib._approveIfNeeded(
            debtAsset,
            borrowableCToken,
            repayAssets
        );

        // Execute repayment of outstanding debt.
        IBorrowableCToken(borrowableCToken).repayFor(repayAssets, receiver);

        // Remove any excess approval.
        SwapperLib._removeApprovalIfNeeded(debtAsset, borrowableCToken);

        assetsHeld -= repayAssets;

        // Transfer any remaining `debtAsset` to `receiver`.
        if (assetsHeld > 0) {
            _transferToRecipient(debtAsset, receiver, assetsHeld);
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

    /// @notice Checks whether address parameters for a particular zapper action on valid.
    /// @param cToken The Curvance cToken address.
    /// @param underlying The input token address, should match `cToken`.asset().
    function _checkAddresses(
        address cToken,
        address underlying
    ) internal view returns (address asset) {
        // Validate `cToken` exists, otherwise transfer their tokens
        // back and return.
        if (cToken == address(0)) {
            revert ZapperBase__ExecutionError ();
        }

        asset = ICToken(cToken).asset();

        // Validate `underlying` matches underlying token of cToken contract.
        if (asset != underlying) {
            revert ZapperBase__UnderlyingTokenIsNotInputToken();
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
        if (CommonLib._isNative(token)) {
            return SafeTransferLib.safeTransferETH(receiver, amount);
        }

        SafeTransferLib.safeTransfer(token, receiver, amount);
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
