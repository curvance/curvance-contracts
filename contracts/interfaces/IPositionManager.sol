// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";

interface IPositionManager {
    /// TYPES ///

    /// @param debtToken Curvance token that will be borrowed from.
    /// @param borrowAssets The amount of underlying tokens from `debtToken`
    ///                     that will be borrowed.
    /// @param collateralToken Curvance token that borrowed funds will be
    ///                        routed into.
    /// @param swapData Swapperlib swapping struct containing instructions
    ///                 on how to handle the necessary eToken swap
    ///                 to facilitate leveraging.
    /// @param auxData Optional auxiliary data for execution of a leverage
    ///                action.
    struct LeverageStruct {
        IBorrowableCToken debtToken;
        uint256 borrowAssets;
        ICToken collateralToken;
        SwapperLib.Swap swapData;
        bytes auxData;
    }

    /// @param collateralToken Curvance token that will be routed into
    ///                        `debtToken` underlying to repay outstanding debt.
    /// @param collateralAssets The amount of `collateralToken` that will be
    ///                         deleveraged.
    /// @param debtToken Address of Curvance token that will have outstanding
    ///                  debt repaid.
    /// @param swapData Optional struct containing instructions on how to
    ///                 handle swapping into debt token to facilitate
    ///                 deleveraging.
    /// @param repayAssets The amount of assets that will be repaid to
    ///                    lenders.
    /// @param auxData Optional auxiliary data for execution of a deleverage
    ///                action.
    struct DeleverageStruct {
        ICToken collateralToken;
        uint256 collateralAssets;
        IBorrowableCToken debtToken;
        uint256 repayAssets;
        SwapperLib.Swap[] swapData;
        bytes auxData;
    }

    /// @notice Callback function to execute post borrow of
    ///         `debtToken`'s underlying and swap it to deposit
    ///         new collateral for `borrower`.
    /// @dev Measures slippage after this callback validating that `borrower`
    ///      is still within acceptable liquidity requirements.
    /// @param debtToken The borrow token borrowed from.
    /// @param assets The amount of `debtToken`'s underlying borrowed.
    /// @param owner The account borrowing that will be swapped into
    ///              collateral assets deposited into Curvance.
    /// @param leverageData Struct containing information on the desired
    ///                     leverage action to execute. Containing values:
    ///                     1. Address of `debtToken` that will be borrowed
    ///                        and swapped.
    ///                     2. The amount of underlying tokens from `debtToken`
    ///                        that will be borrowed.
    ///                     3. Curvance token that borrowed funds will be
    ///                        swapped into.
    ///                     4. Struct containing instructions on how
    ///                        to handle the necessary swap to 
    ///                        facilitate leveraging.
    ///                     5. Optional auxiliary data for execution of a
    ///                        leverage action.
    function onBorrow(
        address debtToken,
        uint256 assets,
        address owner,
        LeverageStruct memory leverageData
    ) external;

    /// @notice Callback function to execute post redemption of
    ///         `collateralToken`'s underlying and swap it to repay
    ///         active debt for `redeemer`.
    /// @dev Measures slippage after this callback validating that `redeemer`
    ///      is still within acceptable liquidity requirements.
    /// @param collateralToken The Curvance token redeemed for its underlying.
    /// @param assets The amount of `collateralToken` underlying redeemed.
    /// @param owner The account redeeming collateral that will be used to
    ///              repay their active debt.
    /// @param deleverageData Struct containing information on the desired
    ///                       deleverage action to execute. Containing values:
    ///                       1. Address of the Curvance token that will be 
    ///                          routed into debt token underlying to repay
    ///                          outstanding debt.
    ///                       2. The amount of `collateralToken` that will be
    ///                          deleveraged.
    ///                       3. Address of Curvance token that will have its
    ///                          outstanding debt repaid.
    ///                       4. Optional struct containing instructions on how
    ///                          to handle swapping into debt token to
    ///                          facilitate deleveraging.
    ///                       5. The amount of underlying tokens that will be
    ///                          repaid to lenders.
    ///                       6. Optional auxiliary data for execution of a
    ///                          deleverage action.
    function onRedeem(
        address collateralToken,
        uint256 assets,
        address owner,
        DeleverageStruct memory deleverageData
    ) external;
}
