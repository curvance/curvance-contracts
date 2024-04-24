// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { CTokenPrimitive } from "contracts/market/collateral/CTokenPrimitive.sol";
import { DToken } from "contracts/market/collateral/DToken.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

interface IPositionFolding {
    /// TYPES ///

    /// @param borrowToken Address of dToken that will be borrowed from.
    /// @param borrowAmount The amount of underlying tokens from dToken
    ///                     that will be borrowed.
    /// @param collateralToken Address of cToken that will borrowed funds
    ///                        will be routed into.
    /// @param swapData Swapperlib swapping struct containing instructions
    ///                 on how to handle the necessary dToken swap
    ///                 to facilitate leveraging.
    /// @param swapZap Swapperlib zapping struct containing instructions
    ///                   on how to handle the necessary cToken zap
    ///                   to facilitate leveraging.
    struct LeverageStruct {
        DToken borrowToken;
        uint256 borrowAmount;
        CTokenPrimitive collateralToken;
        SwapperLib.Swap swapData;
        SwapperLib.Swap swapZap;
    }

    /// @param collateralToken Address of cToken that will be routed into
    ///                        dToken underlying to repay debt.
    /// @param collateralAmount The amount of cTokens that will be
    ///                         deleveraged.
    /// @param borrowToken Address of dToken that will have its underlying
    ///                    token debt repaid.
    /// @param swapZap Swapperlib zapping struct containing instructions
    ///                   on how to handle the necessary cToken outward zap
    ///                   to a single token (e.g. dToken underlying) to
    ///                   facilitate deleveraging.
    /// @param swapData Optional Swapperlib swapping struct containing
    ///                 instructions on how to handle zapping into dToken
    ///                 underlying to facilitate deleveraging.
    /// @param repayAmount The amount of underlying tokens from dToken that
    ///                    will be repaid.
    struct DeleverageStruct {
        CTokenPrimitive collateralToken;
        uint256 collateralAmount;
        DToken borrowToken;
        SwapperLib.Swap swapZap;
        SwapperLib.Swap swapData;
        uint256 repayAmount;
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
    ///         `collateralToken`'s underlying and swap it to repay
    ///         active debt for `redeemer`.
    /// @dev Measures slippage after this callback validating that `redeemer`
    ///      is still within acceptable liquidity requirements.
    /// @param collateralToken The cToken redeemed for its underlying.
    /// @param redeemer The user redeeming collateral that will be used to
    ///                 repay their active debt.
    /// @param collateralAmount The amount of `collateralToken` underlying
    ///                         redeemed.
    /// @param deleverageData Swap and repayment instructions.
    function onRedeem(
        address collateralToken,
        address redeemer,
        uint256 collateralAmount,
        DeleverageStruct memory deleverageData
    ) external;
}
