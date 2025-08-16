// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Multicall } from "contracts/libraries/Multicall.sol";
import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";
import { BPS, WAD } from "contracts/libraries/ConstantsLib.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { CommonLib } from "contracts/libraries/CommonLib.sol";
import { ReentrancyGuard } from "contracts/libraries/ReentrancyGuardTransient.sol";

import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { ERC165 } from "contracts/libraries/external/ERC165.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IPositionManager } from "contracts/interfaces/IPositionManager.sol";
import { IWETH } from "contracts/interfaces/IWETH.sol";

/// @dev Curvance Position Manager contracts enshrine actions that
///      usually would require multiple sequential actions to facilitate,
///      namely leveraging a position up or deleveraging it for withdrawal.
///
///      Curvance token contracts facilitate these operations through
///      enshrined integrations with Position Manager callback functions.
abstract contract BasePositionManager is
    IPositionManager,
    PluginDelegable,
    ERC165,
    ReentrancyGuard,
    Multicall
{
    /// CONSTANTS ///

    /// @notice The address of wrapped native token on this chain.
    address public immutable wrappedNative;
    /// @notice Address of the Market Manager linked to this contract.
    IMarketManager public immutable marketManager;

    /// ERRORS ///

    error BasePositionManager__Unauthorized();
    error BasePositionManager__InvalidSlippage();
    error BasePositionManager__InvalidMarketManager();
    error BasePositionManager__InvalidParam();
    error BasePositionManager__InvalidAmount();
    error BasePositionManager__InvalidTokenPrice();
    error BasePositionManager__ExceedsMaximumBorrowAllowed();
    error BasePositionManager__InsufficientAssetsForRepayment();

    /// MODIFIERS ///

    /// @dev Checks slippage prior to and after leverage/deleverage action,
    ///      works similar to reentryguard with pre and post checks.
    /// @param slippage Slippage accepted by the user for execution of
    ///                 `action` leverage action, in `WAD`.
    modifier checkSlippage(address account, uint256 slippage) {
        // Scoping to avoid stack too deep.
        {
            address[] memory assets = marketManager.assetsOf(account);
            uint256 numAssets = assets.length;
            IBorrowableCToken asset;

            for (uint256 i; i < numAssets; ++i) {
                asset = IBorrowableCToken(assets[i]);
                if (asset.isBorrowable()) {
                    asset.accrueIfNeeded();
                }
            }
        }

        (uint256 collateralBefore, , uint256 debtBefore) = marketManager
            .statusOf(account);
        uint256 valueIn = collateralBefore - debtBefore;

        _;

        (uint256 collateralAfter, , uint256 debtAfter) = marketManager
            .statusOf(account);
        uint256 valueOut = collateralAfter - debtAfter;

        // If there was slippage, make sure its within slippage tolerance.
        if (valueIn > valueOut) {
            if ((valueIn - valueOut) > _mulDiv(valueIn, slippage, WAD)) {
                revert BasePositionManager__InvalidSlippage();
            }
        }
    }

    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
    /// @param mm The address of the MarketManager which manages liquidity
    ///           positions between linked cTokens inside a joint market.
    /// @param wNative The address of wrapped native token.
    constructor(
        ICentralRegistry cr,
        address mm,
        address wNative
    ) PluginDelegable(cr) {
        // Validate that `mm` is configured as a Market Manager inside the
        // Protocol Central Registry.
        if (!cr.isMarketManager(mm)) {
            revert BasePositionManager__InvalidMarketManager();
        }

        marketManager = IMarketManager(mm);
        wrappedNative = wNative;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Allows contract to receive native gas tokens.
    receive() external payable {}

    /// @notice Deposits into a Curvance position and then leverages in favor
    ///         of increasing both collateral and debt inside the system.
    /// @dev Measures slippage through pre/post conditional slippage check
    ///      in `checkSlippage` modifier.
    ///      NOTE: The caller MUST have approved this smart contract to have
    ///      delegated actions inside `action.cToken` or
    ///      depositAsCollateralFor will only deposit and the leverage
    ///      operation will fail.
    /// @param assets The amount of the underlying assets to deposit.
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
    /// @param slippage Slippage accepted by the user for execution of
    ///                 `action` leverage action, in WAD (1e18).
    function depositAndLeverage(
        uint256 assets,
        LeverageAction calldata action,
        uint256 slippage
    ) external checkSlippage(msg.sender, slippage) nonReentrant {
        ICToken cToken = action.cToken;
        address collateralAsset = cToken.asset();
        
        // Transfer `collateralAsset` to deposit.
        SafeTransferLib.safeTransferFrom(
            collateralAsset,
            msg.sender,
            address(this),
            assets
        );

        // Approve cToken to process a deposit.
        SwapperLib._approveIfNeeded(collateralAsset, address(cToken), assets);

        // Deposit and collateralize `collateralAsset` in cToken contract.
        cToken.depositAsCollateralFor(assets, msg.sender);

        // Execute leverage operation.
        _leverage(action, msg.sender);
    }

    /// @notice Leverages an active Curvance position in favor of increasing
    ///         both collateral and debt inside the system.
    /// @dev Measures slippage through pre/post conditional slippage check
    ///      in `checkSlippage` modifier.
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
    /// @param slippage Slippage accepted by the user for execution of
    ///                 `action` leverage action, in WAD (1e18).
    function leverage(
        LeverageAction calldata action,
        uint256 slippage
    ) external checkSlippage(msg.sender, slippage) nonReentrant {
        _leverage(action, msg.sender);
    }

    /// @notice Leverages an active Curvance position in favor of increasing
    ///         both collateral and debt inside the system, via delegation.
    /// @dev Measures slippage through pre/post conditional slippage check
    ///      in `checkSlippage` modifier.
    ///      NOTE: Be careful who you approve here!
    ///      The caller can select slippage, potentially causing loss of funds
    ///      if delegation is provided to a malicious party.
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
    /// @param account The account to leverage an active Curvance position
    ///                for.
    /// @param slippage Slippage accepted by the user for execution of
    ///                 `action` leverage action, in WAD (1e18).
    function leverageFor(
        LeverageAction calldata action,
        address account,
        uint256 slippage
    ) external checkSlippage(account, slippage) nonReentrant {
        _checkDelegate(account, msg.sender);
        _leverage(action, account);
    }

    /// @notice Deleverages an active Curvance position in favor of decreasing
    ///         both collateral and debt inside the system.
    /// @dev Measures slippage through pre/post conditional slippage check
    ///      in `checkSlippage` modifier.
    ///      NOTE: Be careful who you approve here!
    ///      The caller can select slippage, potentially causing loss of funds
    ///      if delegation is provided to a malicious party.
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
    /// @param slippage Slippage accepted by the user for execution of
    ///                 `action` deleverage action, in WAD (1e18).
    function deleverage(
        DeleverageAction calldata action,
        uint256 slippage
    ) external checkSlippage(msg.sender, slippage) nonReentrant {
        _deleverage(action, msg.sender);
    }

    /// @notice Deleverages an active Curvance position in favor of decreasing
    ///         both collateral and debt inside the system, via delegation.
    /// @dev Measures slippage through pre/post conditional slippage check
    ///      in `checkSlippage` modifier.
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
    /// @param account The account to deleverage an active Curvance position
    ///                for.
    /// @param slippage Slippage accepted by the user for execution of
    ///                 `action` deleverage action, in WAD (1e18).
    function deleverageFor(
        DeleverageAction calldata action,
        address account,
        uint256 slippage
    ) external checkSlippage(account, slippage) nonReentrant {
        _checkDelegate(account, msg.sender);
        _deleverage(action, account);
    }

    /// @notice Callback function to execute post borrow of
    ///         `borrowableCToken`'s asset and swap it to deposit
    ///         new collateralized shares for `owner`.
    /// @dev Measures slippage after this callback validating that `owner`
    ///      is still within acceptable liquidity requirements.
    /// @param borrowableCToken The borrowable token borrowed from.
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
    ) external override {
        address debtAsset = IBorrowableCToken(borrowableCToken).asset();
        // Take protocol fee, if any.
        action.borrowAssets = _validateInputsAndApplyFee(
            borrowableCToken,
            borrowAssets,
            address(action.borrowableCToken),
            action.borrowAssets,
            debtAsset
        );

        // We do not need to check whether cToken is listed
        // or not as even if they found a way to input a malicious
        // token here the post conditional solvency check will revert
        // the whole operation.
        ICToken cToken = action.cToken;

        // Unwrap leverage instructions for collateral deposit.
        address collateralAsset = cToken.asset();

        _swapDebtAssetToCollateralAsset(action, owner);

        uint256 amount = IERC20(collateralAsset).balanceOf(address(this));

        // Approve `amount` of `collateralAsset` to `cToken` contract.
        SwapperLib._approveIfNeeded(
            collateralAsset,
            address(cToken),
            amount
        );

        // Enter Curvance collateral position.
        cToken.depositAsCollateral(amount, owner);

        uint256 remaining = IERC20(debtAsset).balanceOf(address(this));

        // Transfer remaining borrow underlying back to the user.
        if (remaining > 0) {
            SafeTransferLib.safeTransfer(debtAsset, owner, remaining);
        }

        // Remove any excess approval.
        SwapperLib._removeApprovalIfNeeded(
            debtAsset,
            address(borrowableCToken)
        );
    }

    /// @notice Callback function to execute post redemption of `cToken`'s
    ///         asset and swap it to repay outstanding debt for `owner`.
    /// @dev Measures slippage after this callback validating that `owner`
    ///      is still within acceptable liquidity requirements.
    /// @param cToken The cToken redeemed for its underlying.
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
    ///               swapActions Swap actions instructions converting
    ///                           collateral asset into debt asset to
    ///                           facilitate deleveraging.
    ///               auxData Optional auxiliary data for execution of a
    ///                       deleverage action.
    function onRedeem(
        address cToken,
        uint256 collateralAssets,
        address owner,
        DeleverageAction memory action
    ) external override {
        address collateralAsset = ICToken(cToken).asset();
        // Take protocol fee, if any.
        action.collateralAssets = _validateInputsAndApplyFee(
            cToken,
            collateralAssets,
            address(action.cToken),
            action.collateralAssets,
            collateralAsset
        );

        _swapCollateralAssetToDebtAsset(action);

        // We do not need to check whether `borrowableCToken` is listed
        // or not as even if they found a way to input a malicious
        // token here the post conditional solvency check will revert
        // the whole operation.
        IBorrowableCToken borrowableCToken = action.borrowableCToken;

        // Unwrap deleverage instructions for debt repayment.
        address debtAsset = borrowableCToken.asset();
        uint256 repayAssets = action.repayAssets;
        uint256 assetsHeld = IERC20(debtAsset).balanceOf(address(this));
        if (repayAssets > assetsHeld) {
            revert BasePositionManager__InsufficientAssetsForRepayment();
        }
        uint256 remaining = assetsHeld - repayAssets;

        // Approve `repayAssets` of `debtAsset` to `borrowableCToken` contract.
        SwapperLib._approveIfNeeded(
            debtAsset,
            address(borrowableCToken),
            repayAssets
        );

        // Repay debt.
        borrowableCToken.repayFor(repayAssets, owner);

        // Transfer remaining borrow underlying back to user.
        if (remaining > 0) {
            SafeTransferLib.safeTransfer(debtAsset, owner, remaining);
        }

        remaining = IERC20(collateralAsset).balanceOf(address(this));

        // Transfer remaining collateral underlying back to the user.
        if (remaining > 0) {
            SafeTransferLib.safeTransfer(collateralAsset, owner, remaining);
        }

        // Transfer remaining swap dust back to the user.
        if (action.swapActions.length > 0) {
            for (uint256 i; i < action.swapActions.length; ++i) {
                remaining = IERC20(action.swapActions[i].outputToken)
                    .balanceOf(address(this));
                if (remaining > 0) {
                    SafeTransferLib.safeTransfer(
                        action.swapActions[i].outputToken,
                        owner,
                        remaining
                    );
                }
            }
        }

        // Remove any excess approval.
        SwapperLib._removeApprovalIfNeeded(
            debtAsset,
            address(borrowableCToken)
        );
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Calculates the maximum amount of `borrowableCToken` `account`
    ///         can borrow for maximum leverage.
    /// @dev NOTE: This can overestimate maximum executeable leverage when
    ///            swapping due to AMM fees and slippage.
    /// @param account The account to calculate the maximum amount of
    ///                `borrowableCToken` that can be borrowed for maximum
    ///                leverage.
    /// @param borrowableCToken The token that `account` will borrow assets
    ///                         from to achieve leverage.
    /// @return result The maximum remaining debt amount allowed from
    ///                `borrowableCToken`, measured in debt assets.
    function maxRemainingLeverageOf(
        address account,
        address borrowableCToken
    ) public view returns (uint256 result) {
        (uint256 sumCollateral, uint256 maxDebt, uint256 sumDebt) =
            marketManager.statusOf(account);

        (uint256 price, uint256 errorCode) =
            CommonLib._oracleManager(centralRegistry)
                .getPrice(address(borrowableCToken), true, false);

        // Validate we got a price for `borrowableCToken`.
        if (errorCode != 0) {
            revert BasePositionManager__InvalidTokenPrice();
        }

        // We can calculate terminal leverage by calculating the infinite
        // series of swapping to maximum LTV over and over, which results
        // in the equation 1 / (1 - LTV).
        //
        // For example, 80% LTV will result in terminal maximum leverage of:
        // 1 / (1 - .8) -> (1 / 0.2) -> 5x leverage.
        // The equation below is equal to this equation,
        // just extrapolated for an account's collateral vs debt.
        /// NOTE: This can overestimate maximum executeable leverage when
        ///       swapping due to AMM fees and slippage.
        uint256 maxLeverage = _mulDiv(
            maxDebt - sumDebt,
            sumCollateral,
            sumCollateral - maxDebt
        );

        result = _mulDiv(
            _mulDiv(maxLeverage, WAD, price),
            10 ** IERC20(borrowableCToken).decimals(),
            WAD
        );
    }

    /// @inheritdoc ERC165
    function supportsInterface(
        bytes4 interfaceId
    ) public view override returns (bool result) {
        result = interfaceId == type(IPositionManager).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Validate `action` parameters versus function parameters and
    ///         apply any protocol fee.
    /// @param cToken The Curvance token given from function parameters,
    ///               should be token used during the callback action.
    /// @param assets The amount of `cTokenUnderlying` given from function
    ///               parameters to be used during the callback action.
    /// @param actionToken The Curvance token given from `action` parameters,
    ///                    should be token used during the callback action.
    /// @param actionAssets The amount of `cTokenUnderlying` given from
    ///                     `action` parameters to be used during the callback
    ///                     action.
    /// @param cTokenUnderlying The `asset()` token of `cToken`.
    /// @return The `cTokenUnderlying` assets for callback action potentially
    ///         with fee applied.
    function _validateInputsAndApplyFee(
        address cToken,
        uint256 assets,
        address actionToken,
        uint256 actionAssets,
        address cTokenUnderlying
    ) internal returns (uint256) {
        // Validate that the token itself is executing the callback and
        // `cToken` is actually listed in this Market Manager.
        if (msg.sender != cToken || !marketManager.isListed(cToken)) {
            revert BasePositionManager__Unauthorized();
        }

        if (IERC20(cTokenUnderlying).balanceOf(address(this)) < assets) {
            revert BasePositionManager__InvalidAmount();
        }

        if (cToken != address(actionToken) || assets != actionAssets) {
            revert BasePositionManager__InvalidParam();
        }

        // Fee is rounded up in favor of protocol.
        uint256 fee = FixedPointMathLib.mulDivUp(
            actionAssets,
            centralRegistry.protocolLeverageFee(),
            BPS
        );

        // Apply protocol fee, if any to apply.
        if (fee > 0) {
            actionAssets -= fee;
            SafeTransferLib.safeTransfer(
                cTokenUnderlying,
                centralRegistry.daoAddress(),
                fee
            );
        }

        // Return `cTokenUnderlying` assets for callback action potentially
        // with fee applied.
        return actionAssets;
    }

    /// @notice Leverages an active Curvance position in favor of increasing
    ///         both collateral and debt inside the system.
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
    /// @param account The account to leverage an active Curvance position
    ///                for.
    function _leverage(
        LeverageAction memory action,
        address account
    ) internal {
        IBorrowableCToken borrowableCToken = action.borrowableCToken;
        uint256 borrowAssets = action.borrowAssets;

        // Validate that the desired borrow amount is within bounds of what
        // will be allowed by the Market Manager.
        if (
            borrowAssets >
            maxRemainingLeverageOf(account, address(borrowableCToken))
            ) {
            revert BasePositionManager__ExceedsMaximumBorrowAllowed();
        }

        borrowableCToken.borrowForPositionManager(
            borrowAssets,
            account,
            action
        );
    }

    /// @notice Deleverages an active Curvance position in favor of decreasing
    ///         both collateral and debt inside the system.
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
    ///                            facilitate deleveraging.
    ///               auxData Optional auxiliary data for execution of a
    ///                       deleverage action.
    /// @param account The account to deleverage an active Curvance position
    ///                for.
    function _deleverage(
        DeleverageAction memory action,
        address account
    ) internal {
        action.cToken.withdrawByPositionManager(
            action.collateralAssets,
            account,
            action
        );
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
        // If the token to refund is the chains' native gas token we wrap
        // then transfer it to prevent callback attack vectors.
        if (CommonLib._isNative(token)) {
            IWETH(wrappedNative).deposit{ value: amount }();
            token = wrappedNative;
        }

        SafeTransferLib.safeTransfer(token, recipient, amount);
    }

    /// @dev Returns `floor(x * y / d)`.
    /// Reverts if `x * y` overflows, or `d` is zero.
    function _mulDiv(
        uint256 x,
        uint256 y,
        uint256 d
    ) internal pure returns (uint256 z) {
        z = FixedPointMathLib.mulDiv(x, y, d);
    }

    /// @notice Returns the Central Registry contract in interface form.
    function _getCentralRegistry()
        internal
        view
        override
        returns (ICentralRegistry)
    {
        return centralRegistry;
    }

    /// INTERNAL FUNCTIONS TO OVERRIDE ///

    /// @notice Callback function on borrowing tokens from a Curvance token
    ///         providing instant liquidity in the debt token underlying which
    ///         is then swapped into the underlying of a collateral token that
    ///         a user currently has collateralized against the debt position,
    ///         creating/increasing a leveraged spot position.
    /// @dev MUST be overridden in every Position Manager implementation.
    function _swapDebtAssetToCollateralAsset(
        LeverageAction memory, /* action */
        address /* receiver */
    ) internal virtual;

    /// @notice Callback function on redemption of tokens from a Curvance token
    ///         providing instant liquidity in the collateral token underlying
    ///         which is then swapped into the underlying of a debt token that
    ///         a user is currently borrowing from, partially or fully closing
    ///         a leveraged spot position.
    /// @dev MUST be overridden in every Position Manager implementation.
    function _swapCollateralAssetToDebtAsset(
        DeleverageAction memory /* action */
    ) internal virtual;
}
