// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";

interface IPositionManager {
    /// TYPES ///

    /// @param borrowableCToken Curvance token that will be borrowed from.
    /// @param borrowAssets The amount of assets borrowed from
    ///                     `borrowableCToken`.
    /// @param cToken Curvance token that borrowed funds will be
    ///                        routed into.
    /// @param swapAction Optional swap action converting debt asset into
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

    /// @param cToken Curvance token that will be routed into
    ///                        `borrowableCToken` asset to repay outstanding
    ///                        debt.
    /// @param collateralAssets The amount of `cToken` that will be
    ///                         deleveraged, in assets.
    /// @param borrowableCToken Address of Curvance token that will have
    ///                         outstanding debt repaid.
    /// @param swapAction Optional swap action converting collateral asset
    ///                   into debt asset to facilitate deleveraging.
    /// @param repayAssets The amount of assets that will be repaid to
    ///                    lenders.
    /// @param auxData Optional auxiliary data for execution of a deleverage
    ///                action.
    struct DeleverageAction {
        ICToken cToken;
        uint256 collateralAssets;
        IBorrowableCToken borrowableCToken;
        uint256 repayAssets;
        SwapperLib.Swap[] swapAction;
        bytes auxData;
    }

    /// @notice Callback function to execute post borrow of
    ///         `borrowableCToken`'s asset and swap it to deposit
    ///         new collateral for `borrower`.
    /// @dev Measures slippage after this callback validating that `borrower`
    ///      is still within acceptable liquidity requirements.
    /// @param borrowableCToken The borrowableCToken borrowed from.
    /// @param borrowAssets The amount of `borrowableCToken`'s asset borrowed.
    /// @param owner The account borrowing that will be swapped into
    ///              collateral assets deposited into Curvance.
    /// @param leverageAction Struct containing information on a leverage
    ///                       action to execute. Containing values:
    ///                       1. Address of `borrowableCToken` that will be
    ///                          borrowed from and assets swapped.
    ///                       2. The amount borrowed from `borrowableCToken`,
    ///                          in assets.
    ///                       3. Curvance token assets that borrowed funds
    ///                          will be swapped into.
    ///                       4. Swap action instructions converting debt
    ///                          asset into collateral asset to facilitate
    ///                          leveraging.
    ///                       5. Optional auxiliary data for execution of a
    ///                          leverage action.
    function onBorrow(
        address borrowableCToken,
        uint256 borrowAssets,
        address owner,
        LeverageAction memory leverageAction
    ) external;

    /// @notice Callback function to execute post redemption of
    ///         `cToken`'s underlying and swap it to repay
    ///         active debt for `redeemer`.
    /// @dev Measures slippage after this callback validating that `redeemer`
    ///      is still within acceptable liquidity requirements.
    /// @param cToken The Curvance token redeemed for its underlying.
    /// @param collateralAssets The amount of `cToken` underlying redeemed.
    /// @param owner The account redeeming collateral that will be used to
    ///              repay their active debt.
    /// @param deleverageAction Struct containing information on a deleverage
    ///                         action to execute. Containing values:
    ///                         1. Address of the cToken whose asset will be
    ///                            routed into debt asset to repay outstanding
    ///                            debt.
    ///                         2. The amount of `cToken` that will
    ///                            be deleveraged.
    ///                         3. Address of borrowableCToken that will have
    ///                            its outstanding debt repaid.
    ///                         4. Swap action instructions converting
    ///                            collateral asset into debt asset to
    ///                            facilitate deleveraging.
    ///                         5. The amount of debt assets that will be
    ///                            repaid to lenders.
    ///                         6. Optional auxiliary data for execution of a
    ///                            deleverage action.
    function onRedeem(
        address cToken,
        uint256 collateralAssets,
        address owner,
        DeleverageAction memory deleverageAction
    ) external;
}
