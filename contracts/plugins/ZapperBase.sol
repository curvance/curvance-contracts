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
    error ZapperBase__PTokenUnderlyingIsNotInputToken();
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

    /// @notice Routes lp/BPT into Curvance pToken contract.
    /// @param pToken The Curvance pToken address.
    /// @param inputToken The input token address, should match
    ///                   pToken.underlying().
    /// @param amount The amount of `inputToken` to deposit into pToken
    ///               position.
    /// @param collateralize Whether the zapped deposit should be
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
        // pToken not configured so transfer their token back and return.
        if (pToken == address(0)) {
            SafeTransferLib.safeTransfer(inputToken, recipient, amount);
            return amount;
        }

        // Validate inputToken matches underlying token of pToken contract.
        if (IMToken(pToken).underlying() != inputToken) {
            revert ZapperBase__PTokenUnderlyingIsNotInputToken();
        }

        // Approve pToken to take `inputToken`.
        SwapperLib._approveTokenIfNeeded(inputToken, pToken, amount);

        uint256 priorBalance = IERC20(pToken).balanceOf(recipient);

        uint256 shares;
        // The user is trusting this plugin to not use their delegation
        // approval for nefarious reasons such as keeping them stuck in
        // positions, so lets validate that the recipient is a delegate
        // as well.
        if (collateralize) {
            // Enter Curvance pToken position and collateralize.
            if (msg.sender == recipient) {
                // User wants to enter and collateralize a position for
                // themselves.
                shares = IMToken(pToken).depositAsCollateral(
                    amount,
                    msg.sender
                );
            } else {
                // User wants to enter and collateralize a position for
                // someone else, so we need to validate they have plugin authority.
                if (IPluginDelegable(pToken).isDelegate(recipient, msg.sender)) {
                    shares = IMToken(pToken).depositAsCollateralFor(
                        amount,
                        recipient
                    );
                } else {
                    revert ZapperBase__Unauthorized();
                }
            }
        } else {
            // User wants to enter an uncollateralized a position so we dont
            // care if they are zapping for themselves or someone else.
            shares = IMToken(pToken).deposit(amount, recipient);
        }

        // Make sure `recipient` got pTokens.
        if (shares == 0) {
            revert ZapperBase__ExecutionError();
        }

        // Remove any leftover approval.
        SwapperLib._removeApprovalIfNeeded(inputToken, pToken);

        // Bubble up how many pTokens `recipient` received.
        return IERC20(pToken).balanceOf(recipient) - priorBalance;
    }

    /// @notice Exits a Curvance position.
    /// @param pToken The address of the pToken to be exited.
    /// @param shares The amount of shares to redeemed.
    /// @param forceRedeemCollateral Whether the collateral should be always
    ///                              reduced from callers collateralPosted.
    /// @param underlying The expected underlying token of `pToken`.
    /// @param expectedAssets The amount of assets expected to be redeemed
    ///                       on exiting Curvance position.
    function _exitCurvance(
        IMToken pToken,
        uint256 shares,
        bool forceRedeemCollateral,
        address underlying,
        uint256 expectedAssets,
        address recipient
    ) internal {
        if (pToken.underlying() != underlying) {
            revert ZapperBase__ExecutionError();
        }

        uint256 assets;

        // Transfer underlying tokens to the Zapper.
        if (forceRedeemCollateral) {
            assets = pToken.redeemCollateralFor(
                shares,
                address(this),
                msg.sender
            );
        } else {
            assets = pToken.redeemFor(shares, address(this), msg.sender);
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
