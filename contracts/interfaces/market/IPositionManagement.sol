// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { SimplePToken } from "contracts/market/token/SimplePToken.sol";
import { EToken } from "contracts/market/token/EToken.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

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
        EToken borrowToken;
        uint256 borrowAmount;
        SimplePToken positionToken;
        SwapperLib.Swap swapData;
        bytes auxData;
    }

    /// @param positionToken Address of pToken that will be routed into
    ///                      eToken underlying to repay debt.
    /// @param collateralAmount The amount of pTokens that will be
    ///                         deleveraged.
    /// @param borrowToken Address of eToken that will have its underlying
    ///                    token debt repaid.
    /// @param swapData Optional Swapperlib swapping struct containing
    ///                 instructions on how to handle zapping into eToken
    ///                 underlying to facilitate deleveraging.
    /// @param repayAmount The amount of underlying tokens from eToken that
    ///                    will be repaid.
    /// @param auxData Optional auxiliary data for execution of a deleverage
    ///                action.
    struct DeleverageStruct {
        SimplePToken positionToken;
        uint256 collateralAmount;
        EToken borrowToken;
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
    /// @param borrower The user borrowing that will be swapped into
    ///                 collateral assets deposited into Curvance.
    /// @param borrowAmount The amount of `borrowToken`'s underlying borrowed.
    /// @param leverageData Swap and deposit instructions.
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
    /// @param redeemer The user redeeming collateral that will be used to
    ///                 repay their active debt.
    /// @param collateralAmount The amount of `positionToken` underlying
    ///                         redeemed.
    /// @param deleverageData Swap and repayment instructions.
    function onRedeem(
        address positionToken,
        address redeemer,
        uint256 collateralAmount,
        DeleverageStruct memory deleverageData
    ) external;
}
