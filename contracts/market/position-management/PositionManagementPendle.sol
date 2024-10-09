// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { PositionManagementBase } from "contracts/market/position-management/PositionManagementBase.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPendleRouter, ApproxParams, LimitOrderData } from "contracts/interfaces/external/pendle/IPendleRouter.sol";
import { IPMarket } from "contracts/interfaces/external/pendle/IPMarket.sol";
import { IPPrincipalToken } from "contracts/interfaces/external/pendle/IPPrincipalToken.sol";
import { IPYieldToken } from "contracts/interfaces/external/pendle/IPYieldToken.sol";
import { IStandardizedYield } from "contracts/interfaces/external/pendle/IStandardizedYield.sol";

contract PositionManagementPendle is PositionManagementBase {
    IPendleRouter public router;

    IPMarket public lp;

    IStandardizedYield public sy;

    IPPrincipalToken public pt;

    IPYieldToken public yt;

    address[] underlyingTokens;

    /// @notice Whether a particular token address is an underlying token
    ///         of this Curve 2Pool LP.
    /// @dev Token => Is underlying token.
    mapping(address => bool) public isUnderlyingToken;

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address marketManager_,
        IPendleRouter router_,
        IPMarket lp_
    ) PositionManagementBase(centralRegistry_, marketManager_) {
        router = router_;
        lp = lp_;
        (sy, pt, yt) = lp.readTokens();

        underlyingTokens = sy.getTokensIn();
        uint256 numTokens = underlyingTokens.length;

        for (uint256 i; i < numTokens; ) {
            isUnderlyingToken[underlyingTokens[i++]] = true;
        }
    }

    function _swapBorrowUnderlyingToCollateral(
        LeverageStruct memory leverageData
    ) internal virtual override {
        SwapperLib.Swap memory swapData = leverageData.swapData;
        address borrowUnderlying = leverageData.borrowToken.underlying();
        address collateralUnderlying = leverageData.positionToken.underlying();

        if (swapData.call.length == 0) {
            revert PositionManagementBase__InvalidSwapperParam();
        }

        if (
            swapData.target == address(0) ||
            swapData.inputToken != borrowUnderlying ||
            address(lp) != collateralUnderlying ||
            isUnderlyingToken[swapData.outputToken] == false ||
            swapData.inputAmount != leverageData.borrowAmount
        ) {
            revert PositionManagementBase__InvalidSwapperParam();
        }

        // Swap borrow underlying to collateral underlying
        SwapperLib.swapSafe(centralRegistry, swapData);

        {
            address underlyingToken = swapData.outputToken;
            uint256 balance;

            if (underlyingToken == address(0)) {
                balance = address(this).balance;
                if (balance > 0) {
                    // Mint SY in gas tokens.
                    sy.deposit{ value: balance }(
                        address(this),
                        underlyingToken,
                        balance,
                        0
                    );
                }
            } else {
                balance = IERC20(underlyingToken).balanceOf(address(this));
                if (balance > 0) {
                    SwapperLib._approveTokenIfNeeded(
                        underlyingToken,
                        address(sy),
                        balance
                    );
                    // Mint SY in ERC20s.
                    sy.deposit(address(this), underlyingToken, balance, 0);
                }
            }
        }

        {
            uint256 balance = sy.balanceOf(address(this));
            SwapperLib._approveTokenIfNeeded(
                address(sy),
                address(router),
                balance
            );

            (
                uint256 minLPAmount,
                ApproxParams memory approx,
                LimitOrderData memory limit
            ) = abi.decode(
                    leverageData.data,
                    (uint256, ApproxParams, LimitOrderData)
                );

            // Add liquidity to Pendle lp via SY.
            router.addLiquiditySingleSy(
                address(this),
                address(lp),
                balance,
                minLPAmount,
                approx,
                limit
            );
        }
    }

    function _swapCollateralToBorrowUnderyling(
        DeleverageStruct memory deleverageData
    ) internal virtual override {
        {
            (uint256 minSyOut, LimitOrderData memory limit) = abi.decode(
                deleverageData.data,
                (uint256, LimitOrderData)
            );

            // Remove liquidity from Pendle lp via SY.
            router.removeLiquiditySingleSy(
                address(this),
                address(lp),
                deleverageData.collateralAmount,
                minSyOut,
                limit
            );
        }

        if (deleverageData.swapData.length > 0) {
            for (uint256 i; i < deleverageData.swapData.length; ++i) {
                // Swap Swapper input token for borrow underlying.
                SwapperLib.swapSafe(
                    centralRegistry,
                    deleverageData.swapData[i]
                );
            }
        }
    }
}
