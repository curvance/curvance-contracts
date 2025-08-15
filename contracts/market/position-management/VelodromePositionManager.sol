// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { BasePositionManager, SwapperLib, ICentralRegistry } from "contracts/market/position-management/BasePositionManager.sol";
import { VelodromeLib } from "contracts/libraries/VelodromeLib.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IVeloPool } from "contracts/interfaces/external/velodrome/IVeloPool.sol";

contract VelodromePositionManager is BasePositionManager {
    /// STORAGE ///
    
    /// @notice The address of the Velodrome pair factory.
    address public pairFactory;
    /// @notice The address of the Velodrome router.
    address public router;

    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
    /// @param mm The address of the MarketManager which manages liquidity
    ///           positions between linked cTokens inside a joint market.
    /// @param wNative The address of wrapped native token.
    constructor(
        ICentralRegistry cr,
        address mm,
        address wNative,
        address router_,
        address pairFactory_
    ) BasePositionManager(cr, mm, wNative) {
        router = router_;
        pairFactory = pairFactory_;
    }

    /// @notice Callback function on borrowing tokens from an borrowableCToken
    ///         contract providing instant liquidity in the borrowableCToken
    ///         underlying which is then swapped into the underlying of a
    ///         cToken that a user is currently putting up as collateral
    ///         against the borrowableCToken debt position, creating a
    ///         leveraged spot position.
    /// @dev Slippage is checked inside enterVelodrome call to VelodromeLib
    ///      with the slippage value being encoded in the `aux` field of
    ///      `action`.
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
    /// @param receiver The address who will receive the remaining dust post
    ///                 swap, if any.
    function _swapDebtAssetToCollateralAsset(
        LeverageAction memory action,
        address receiver
    ) internal virtual override {
        address pool = action.cToken.asset();
        address debtAsset = action.borrowableCToken.asset();
        address token0 = IVeloPool(pool).token0();
        address token1 = IVeloPool(pool).token1();
        
        // If the token being borrowed isn't token0 or token1 we will need to swap
        // into it.
        if (debtAsset != token0 && debtAsset != token1) {
            SwapperLib.Swap memory swapAction = action.swapAction;

            // Make sure there is swap instructions.
            if (swapAction.call.length == 0) {
                revert BasePositionManager__InvalidParam();
            }

            // Make sure the swap instructions are safe.
            if (
                swapAction.target == address(0) ||
                swapAction.inputToken != debtAsset ||
                (swapAction.outputToken != token0 &&
                    swapAction.outputToken != token1) ||
                swapAction.inputAmount != action.borrowAssets
            ) {
                revert BasePositionManager__InvalidParam();
            }

            // Swap borrow underlying to token0.
            SwapperLib._swapSafe(centralRegistry, swapAction);
        }

        uint256 totalAmountA = IERC20(token0).balanceOf(address(this));
        uint256 totalAmountB = IERC20(token1).balanceOf(address(this));
        // Validate swap was routed into token0/token1, or borrow token was token0/token1.
        if (totalAmountA == 0 && totalAmountB == 0) {
            revert BasePositionManager__InvalidSlippage();
        }
        
        uint256 minLpAmount = abi.decode(action.auxData, (uint256));

        VelodromeLib._enterVelodrome(
            router,
            pairFactory,
            pool,
            totalAmountA,
            totalAmountB,
            minLpAmount
        );

        // We can reuse totalAmount variables to avoid stack too deep error
        // and minimize storage warming from 0 -> number.
        totalAmountA = IERC20(token0).balanceOf(address(this));
        totalAmountB = IERC20(token1).balanceOf(address(this));

        if (totalAmountA > 0) {
            _transferToRecipient(token0, receiver, totalAmountA);
        }

        if (totalAmountB > 0) {
            _transferToRecipient(token1, receiver, totalAmountB);
        }
    }

    /// @notice Callback function on redemption of tokens from a cToken vault
    ///         providing instant liquidity in the cToken underlying which is
    ///         then swapped into the underlying of an borrowableCToken that a
    ///         user is currently borrowing from, partially or fully closing a
    ///         leveraged spot position.
    /// @param action Instructions for a deleverage action containing:
    ///               cToken Address of the cToken that will be redeemed from
    ///                      and assets swapped into `borrowableCToken` asset.
    ///               collateralAssets The amount of `cToken` that will be
    ///                                deleveraged, in assets.
    ///               borrowableCToken Address of the borrowableCToken that
    ///                                will have its debt paid.
    ///               repayAssets The amount of `borrowableCToken` asset that
    ///                           will be repaid to lenders.
    ///               swapActions Swap actions instructions converting
    ///                           collateral asset into debt asset to
    ///                           facilitate deleveraging.
    ///               auxData Optional auxiliary data for execution of a
    ///                       deleverage action.
    function _swapCollateralAssetToDebtAsset(
        DeleverageAction memory action
    ) internal virtual override {
        address pool = action.cToken.asset();
        address debtAsset = action.borrowableCToken.asset();
        SwapperLib.Swap[] memory swapActions = action.swapActions;

        VelodromeLib._exitVelodrome(router, pool, action.collateralAssets);
        uint256 numSwaps = swapActions.length;

        // Check to make sure there is calldata attached to execute the swap.
        if (numSwaps > 0) {
            address token0 = IVeloPool(pool).token0();
            address token1 = IVeloPool(pool).token1();

            if (
                (swapActions[0].inputToken != token0 &&
                swapActions[0].inputToken != token1) ||
                swapActions[numSwaps - 1].outputToken != debtAsset
            ) {
                revert BasePositionManager__InvalidParam();
            }

            // Swap output token for debt asset.
            for (uint256 i; i < numSwaps; ++i) {
                SwapperLib._swapSafe(centralRegistry, swapActions[i]);
            }
        }
    }
}
