// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { IEToken } from "contracts/interfaces/IEToken.sol";
import { IPToken } from "contracts/interfaces/IPToken.sol";

interface IPositionManagement {
    /// TYPES ///

    /// @param borrowToken Address of eToken that will be borrowed from.
    /// @param borrowAmount The amount of underlying tokens from eToken
    ///                     that will be borrowed.
    /// @param positionToken Address of pToken that borrowed funds
    ///                      will be routed into.
    /// @param swapData Swapperlib swapping struct containing instructions
    ///                 on how to handle the necessary eToken swap
    ///                 to facilitate leveraging.
    /// @param auxData Optional auxiliary data for execution of a leverage
    ///                action.
    struct LeverageStruct {
        IEToken borrowToken;
        uint256 borrowAmount;
        IPToken positionToken;
        SwapperLib.Swap swapData;
        bytes auxData;
    }

    /// @param positionToken Address of pToken that will be routed into
    ///                      eToken underlying to repay outstanding debt.
    /// @param collateralAmount The amount of pTokens that will be
    ///                         deleveraged.
    /// @param borrowToken Address of eToken that will have its underlying
    ///                    token debt repaid.
    /// @param swapData Optional struct containing instructions on how to
    ///                 handle swapping into eToken underlying to facilitate
    ///                 deleveraging.
    /// @param repayAmount The amount of underlying tokens that will be
    ///                    repaid to the eToken lenders.
    /// @param auxData Optional auxiliary data for execution of a deleverage
    ///                action.
    struct DeleverageStruct {
        IPToken positionToken;
        uint256 collateralAmount;
        IEToken borrowToken;
        SwapperLib.Swap[] swapData;
        uint256 repayAmount;
        bytes auxData;
    }

    /// @notice Callback function to execute post borrow of
    ///         `borrowToken`'s underlying and swap it to deposit
    ///         new collateral for `borrower`.
    /// @dev Measures slippage after this callback validating that `borrower`
    ///      is still within acceptable liquidity requirements.
    /// @param borrowToken The borrow token borrowed from.
    /// @param borrower The account borrowing that will be swapped into
    ///                 collateral assets deposited into Curvance.
    /// @param borrowAmount The amount of `borrowToken`'s underlying borrowed.
    /// @param leverageData Struct containing information on the desired
    ///                     leverage action to execute. Containing values:
    ///                     1. Address of eToken that will be borrowed from.
    ///                     2. The amount of underlying tokens from eToken
    ///                        that will be borrowed.
    ///                     3. Address of pToken that borrowed funds
    ///                        will be swapped into.
    ///                     4. Struct containing instructions
    ///                        on how to handle the necessary eToken swap
    ///                        to facilitate leveraging.
    ///                     5. Optional auxiliary data for execution of a
    ///                        leverage action.
    function onBorrow(
        address borrowToken,
        address borrower,
        uint256 borrowAmount,
        LeverageStruct memory leverageData
    ) external;

    /// @notice Callback function to execute post redemption of
    ///         `positionToken`'s underlying and swap it to repay
    ///         active debt for `redeemer`.
    /// @dev Measures slippage after this callback validating that `redeemer`
    ///      is still within acceptable liquidity requirements.
    /// @param positionToken The pToken redeemed for its underlying.
    /// @param redeemer The account redeeming collateral that will be used to
    ///                 repay their active debt.
    /// @param collateralAmount The amount of `positionToken` underlying
    ///                         redeemed.
    /// @param deleverageData Struct containing information on the desired
    ///                       deleverage action to execute. Containing values:
    ///                       1. Address of pToken that will be routed into
    ///                          eToken underlying to repay outstanding debt.
    ///                       2. The amount of pTokens that will be
    ///                          deleveraged.
    ///                       3. Address of eToken that will have its underlying
    ///                          token debt repaid.
    ///                       4. Optional struct containing instructions on how
    ///                          to handle swapping into eToken underlying to
    ///                          facilitate deleveraging.
    ///                       5. The amount of underlying tokens that will be
    ///                          repaid to the eToken lenders.
    ///                       6. Optional auxiliary data for execution of a
    ///                          deleverage action.
    function onRedeem(
        address positionToken,
        address redeemer,
        uint256 collateralAmount,
        DeleverageStruct memory deleverageData
    ) external;
}
