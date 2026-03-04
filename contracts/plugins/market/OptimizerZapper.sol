// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { CommonLib } from "contracts/libraries/CommonLib.sol";
import { ReentrancyGuard } from "contracts/libraries/ReentrancyGuardTransient.sol";

import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IWETH } from "contracts/interfaces/IWETH.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ILendingOptimizer } from "contracts/interfaces/ILendingOptimizer.sol";

/// @title Curvance Lending Optimizer Zapper.
/// @notice Swaps an arbitrary token and deposits the result into a
///         LendingOptimizer vault in a single transaction.
/// @dev Standalone zapper — does not inherit BaseZapper. Copies only
///      the shared infra needed: `_prepareSwap` and ReentrancyGuard.
///
///      Flow:
///      1. Pull input token (ERC20) or receive native gas token.
///      2. Swap into the optimizer's underlying asset (skip if already matching).
///      3. Approve optimizer, call `deposit(assets, receiver, targetMarket)`.
///      4. Verify minimum shares received.
///      5. Refund any dust remaining in the zapper to the caller.
///
contract OptimizerZapper is ReentrancyGuard {

    /// CONSTANTS ///

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;
    /// @notice Wrapped native token on this chain.
    address public immutable wrappedNative;

    /// ERRORS ///

    error OptimizerZapper__ExecutionError();
    error OptimizerZapper__AssetMismatch();

    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
    /// @param wNative The address of the wrapped native token.
    constructor(ICentralRegistry cr, address wNative) {
        CentralRegistryLib._isCentralRegistry(cr);
        centralRegistry = cr;
        wrappedNative = wNative;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Allows contract to receive native tokens.
    receive() external payable {}

    /// @notice Swaps `swapAction.inputToken` into the optimizer's underlying
    ///         asset and deposits into a LendingOptimizer vault.
    /// @param optimizer The LendingOptimizer vault to deposit into.
    /// @param targetMarket The cToken market address within the optimizer
    ///                     (computed offchain, passed to optimizer's 3-arg deposit).
    /// @param depositAsWrappedNative When `inputToken` is the native gas token,
    ///                               indicates wrapping before swap/deposit.
    /// @param swapAction Swap instructions. If inputToken == outputToken the
    ///                   swap is skipped and the full inputAmount is deposited.
    /// @param expectedShares Minimum shares the receiver must receive.
    ///                       Reverts if actual shares < expectedShares.
    /// @param receiver Address that receives the minted optimizer shares.
    /// @return shares The amount of optimizer shares minted to `receiver`.
    function swapAndDeposit(
        address optimizer,
        address targetMarket,
        bool depositAsWrappedNative,
        SwapperLib.Swap memory swapAction,
        uint256 expectedShares,
        address receiver
    ) external payable nonReentrant returns (uint256 shares) {
        if (receiver == address(0)) revert OptimizerZapper__ExecutionError();

        _prepareSwap(
            swapAction.inputToken,
            swapAction.inputAmount,
            depositAsWrappedNative
        );

        // If depositing native as wrapped, switch input reference so the
        // matching-token check below works against the ERC20 address.
        if (
            CommonLib._isNative(swapAction.inputToken)
                && depositAsWrappedNative
        ) {
            swapAction.inputToken = wrappedNative;
        }

        uint256 assets;
        if (
            CommonLib._isMatchingToken(
                swapAction.inputToken,
                swapAction.outputToken
            )
        ) {
            assets = swapAction.inputAmount;
        } else {
            assets = SwapperLib._swapUnsafe(centralRegistry, swapAction);
        }

        // Validate swap output matches the optimizer's underlying asset.
        address underlying = ILendingOptimizer(optimizer).asset();
        if (swapAction.outputToken != underlying) {
            revert OptimizerZapper__AssetMismatch();
        }

        // Approve optimizer to pull underlying, deposit, clean up approval.
        SwapperLib._approveIfNeeded(underlying, optimizer, assets);
        shares = ILendingOptimizer(optimizer).deposit(
            assets,
            receiver,
            targetMarket
        );
        SwapperLib._removeApprovalIfNeeded(underlying, optimizer);

        // Slippage guard.
        if (shares < expectedShares) {
            revert OptimizerZapper__ExecutionError();
        }

        // Refund any underlying dust left in the zapper (e.g. from swap
        // over-delivery). Input token dust is consumed by the aggregator.
        uint256 dust = IERC20(underlying).balanceOf(address(this));
        if (dust > 0) {
            SafeTransferLib.safeTransfer(underlying, msg.sender, dust);
        }
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Pulls input tokens or wraps native gas token for an
    ///         upcoming swap.
    /// @param inputToken The token being swapped from.
    /// @param inputAmount The amount of `inputToken` to swap.
    /// @param depositAsWrappedNative When true and `inputToken` is native,
    ///                               wraps into WETH before proceeding.
    function _prepareSwap(
        address inputToken,
        uint256 inputAmount,
        bool depositAsWrappedNative
    ) internal {
        if (CommonLib._isNative(inputToken)) {
            if (inputAmount != msg.value) {
                revert OptimizerZapper__ExecutionError();
            }

            if (depositAsWrappedNative) {
                IWETH(wrappedNative).deposit{ value: inputAmount }();
            }
            return;
        }

        // ERC20 flow — no msg.value allowed.
        if (msg.value != 0) {
            revert OptimizerZapper__ExecutionError();
        }

        SafeTransferLib.safeTransferFrom(
            inputToken,
            msg.sender,
            address(this),
            inputAmount
        );
    }

}
