// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";

interface IPositionManager {
    /// TYPES ///

    /// @notice Instructions for a leverage action.
    /// @param borrowableCToken Address of the borrowableCToken that will be
    ///                         borrowed from and assets swapped into `cToken`
    ///                         asset.
    /// @param borrowAssets The amount borrowed from `borrowableCToken`,
    ///                     in assets.
    /// @param cToken Curvance token assets that borrowed funds will be
    ///               swapped into.
    /// @param swapAction Swap action instructions converting debt asset into
    ///                   collateral asset to facilitate leveraging.
    /// @param auxData Optional auxiliary data for execution of a leverage
    ///                action.
    struct LeverageAction {
        IBorrowableCToken borrowableCToken;
        uint256 borrowAssets;
        ICToken cToken;
        SwapperLib.Swap swapAction;
        bytes auxData;
    }

    /// @notice Instructions for a deleverage action.
    /// @param cToken Address of the cToken that will be redeemed from and
    ///               assets swapped into `borrowableCToken` asset.
    /// @param collateralAssets The amount of `cToken` that will be
    ///                         deleveraged, in assets.
    /// @param borrowableCToken Address of the borrowableCToken that will
    ///                         have its debt paid.
    /// @param repayAssets The amount of `borrowableCToken` asset that will
    ///                    be repaid to lenders.
    /// @param swapActions Swap actions instructions converting collateral
    ///                    asset into debt asset to facilitate deleveraging.
    /// @param auxData Optional auxiliary data for execution of a deleverage
    ///                action.
    struct DeleverageAction {
        ICToken cToken;
        uint256 collateralAssets;
        IBorrowableCToken borrowableCToken;
        uint256 repayAssets;
        SwapperLib.Swap[] swapActions;
        bytes auxData;
    }

    /// @notice Callback function to execute post borrow of
    ///         `borrowableCToken`'s asset and swap it to deposit
    ///         new collateralized shares for `owner`.
    /// @dev Measures slippage after this callback validating that `owner`
    ///      is still within acceptable liquidity requirements.
    /// @param borrowableCToken The borrowableCToken borrowed from.
    /// @param borrowAssets The amount of `borrowableCToken`'s asset borrowed.
    /// @param owner The account borrowing that will be swapped into
    ///              collateral assets deposited into Curvance.
    /// @param action Instructions for a leverage action containing:
    ///               borrowableCToken Address of the borrowableCToken that
    ///                                will be borrowed from and assets
    ///                                swapped into `cToken` asset.
    ///               borrowAssets The amount borrowed from
    ///                            `borrowableCToken`, in assets.
    ///               cToken Curvance token assets that borrowed funds will be
    ///                      swapped into.
    ///               swapAction Swap action instructions converting debt
    ///                          asset into collateral asset to facilitate
    ///                          leveraging.
    ///               auxData Optional auxiliary data for execution of a
    ///                       leverage action.
    function onBorrow(
        address borrowableCToken,
        uint256 borrowAssets,
        address owner,
        LeverageAction memory action
    ) external;

    /// @notice Callback function to execute post redemption of `cToken`'s
    ///         asset and swap it to repay outstanding debt for `owner`.
    /// @dev Measures slippage after this callback validating that `owner`
    ///      is still within acceptable liquidity requirements.
    /// @param cToken The Curvance token redeemed for its underlying.
    /// @param collateralAssets The amount of `cToken` underlying redeemed.
    /// @param owner The account redeeming collateral that will be used to
    ///              repay their active debt.
    /// @param action Instructions for a deleverage action containing:
    ///               cToken Address of the cToken that will be redeemed from
    ///                      and assets swapped into `borrowableCToken` asset.
    ///               collateralAssets The amount of `cToken` that will be
    ///                                deleveraged, in assets.
    ///               borrowableCToken Address of the borrowableCToken that
    ///                                will have its debt paid.
    ///               repayAssets The amount of `borrowableCToken` asset that
    ///                           will be repaid to lenders.
    ///               swapAction Swap actions instructions converting
    ///                          collateral asset into debt asset to
    ///                          facilitate deleveraging.
    ///               auxData Optional auxiliary data for execution of a
    ///                       deleverage action.
    function onRedeem(
        address cToken,
        uint256 collateralAssets,
        address owner,
        DeleverageAction memory action
    ) external;
}
