// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Multicall } from "contracts/libraries/Multicall.sol";
import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";
import { WAD } from "contracts/libraries/Constants.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { CommonLib } from "contracts/libraries/CommonLib.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { ReentrancyGuard } from "contracts/libraries/external/ReentrancyGuard.sol";
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

    /// @notice Maximum desired leverage output, we choose 99% of what is
    ///         possible to minimize reversion from things like price
    ///         fluctuations, swap fees, and oracle vs pool price divergence,
    ///         in WAD (1e18).
    /// @dev 0.99e18 = 99%.
    uint256 public constant MAX_LEVERAGE = 0.99e18;

    /// @dev `bytes4(keccak256(bytes("BasePositionManager__Unauthorized()")))`
    uint256 internal constant _UNAUTHORIZED_SELECTOR = 0xdb6ad9f5;

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
    ///                 `leverageAction` leverage action, in `WAD`.
    modifier checkSlippage(address account, uint256 slippage) {
        address[] memory assets = marketManager.assetsOf(account);
        uint256 numAssets = assets.length;
        IBorrowableCToken asset;

        for (uint256 i; i < numAssets; ++i) {
            asset = IBorrowableCToken(assets[i]);
            if (asset.isBorrowable()) {
                asset.accrueIfNeeded();
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

    constructor(
        ICentralRegistry centralRegistry_,
        address marketManager_,
        address wrappedNative_
    ) PluginDelegable(centralRegistry_) {
        // Validate that `marketManager_` is configured as a market manager
        // inside the Central Registry.
        if (!centralRegistry_.isMarketManager(marketManager_)) {
            revert BasePositionManager__InvalidMarketManager();
        }

        marketManager = IMarketManager(marketManager_);
        wrappedNative = wrappedNative_;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Allows contract to receive native gas tokens.
    receive() external payable {}

    /// @notice Deposits into a Curvance position and then leverages in favor
    ///         of increasing both collateral and debt inside the system.
    /// @dev Measures slippage through pre/post conditional slippage check
    ///      in `checkSlippage` modifier.
    ///      NOTE: The caller MUST have approved this smart contract to have
    ///      delegated actions inside `leverageAction.cToken` or
    ///      depositAsCollateralFor will only deposit and the leverage
    ///      operation will fail.
    /// @param assets The amount of the underlying assets to deposit.
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
    /// @param slippage Slippage accepted by the user for execution of
    ///                 `leverageAction` leverage action, in WAD (1e18).
    function depositAndLeverage(
        uint256 assets,
        LeverageAction calldata leverageAction,
        uint256 slippage
    ) external checkSlippage(msg.sender, slippage) nonReentrant {
        ICToken cToken = leverageAction.cToken;
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
        _leverage(leverageAction, msg.sender);
    }

    /// @notice Leverages an active Curvance position in favor of increasing
    ///         both collateral and debt inside the system.
    /// @dev Measures slippage through pre/post conditional slippage check
    ///      in `checkSlippage` modifier.
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
    /// @param slippage Slippage accepted by the user for execution of
    ///                 `leverageAction` leverage action, in WAD (1e18).
    function leverage(
        LeverageAction calldata leverageAction,
        uint256 slippage
    ) external checkSlippage(msg.sender, slippage) nonReentrant {
        _leverage(leverageAction, msg.sender);
    }

    /// @notice Leverages an active Curvance position in favor of increasing
    ///         both collateral and debt inside the system, via delegation.
    /// @dev Measures slippage through pre/post conditional slippage check
    ///      in `checkSlippage` modifier.
    ///      NOTE: Be careful who you approve here!
    ///      The caller can select slippage, potentially causing loss of funds
    ///      if delegation is provided to a malicious party.
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
    /// @param account The account to leverage an active Curvance position
    ///                for.
    /// @param slippage Slippage accepted by the user for execution of
    ///                 `leverageAction` leverage action, in WAD (1e18).
    function leverageFor(
        LeverageAction calldata leverageAction,
        address account,
        uint256 slippage
    ) external checkSlippage(account, slippage) nonReentrant {
        _checkDelegate(account, msg.sender);

        _leverage(leverageAction, account);
    }

    /// @notice Deleverages an active Curvance position in favor of decreasing
    ///         both collateral and debt inside the system.
    /// @dev Measures slippage through pre/post conditional slippage check
    ///      in `checkSlippage` modifier.
    ///      NOTE: Be careful who you approve here!
    ///      The caller can select slippage, potentially causing loss of funds
    ///      if delegation is provided to a malicious party.
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
    /// @param slippage Slippage accepted by the user for execution of
    ///                 `deleverageAction` deleverage action, in WAD (1e18).
    function deleverage(
        DeleverageAction calldata deleverageAction,
        uint256 slippage
    ) external checkSlippage(msg.sender, slippage) nonReentrant {
        _deleverage(deleverageAction, msg.sender);
    }

    /// @notice Deleverages an active Curvance position in favor of decreasing
    ///         both collateral and debt inside the system, via delegation.
    /// @dev Measures slippage through pre/post conditional slippage check
    ///      in `checkSlippage` modifier.
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
    /// @param account The account to deleverage an active Curvance position
    ///                for.
    /// @param slippage Slippage accepted by the user for execution of
    ///                 `deleverageAction` deleverage action, in WAD (1e18).
    function deleverageFor(
        DeleverageAction calldata deleverageAction,
        address account,
        uint256 slippage
    ) external checkSlippage(account, slippage) nonReentrant {
        _checkDelegate(account, msg.sender);

        _deleverage(deleverageAction, account);
    }

    /// @notice Callback function to execute post borrow of
    ///         `borrowableCToken`'s asset and swap it to deposit
    ///         new collateral for `borrower`.
    /// @dev Measures slippage after this callback validating that `borrower`
    ///      is still within acceptable liquidity requirements.
    /// @param borrowableCToken The borrow token borrowed from.
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
    ) external override {
        address debtAsset = IBorrowableCToken(borrowableCToken).asset();

        // Take protocol fee, if any.
        uint256 fee = _getFee(
            borrowableCToken,
            borrowAssets,
            address(leverageAction.borrowableCToken),
            leverageAction.borrowAssets,
            debtAsset
        );
        if (fee > 0) {
            leverageAction.borrowAssets -= fee;
            SafeTransferLib.safeTransfer(
                debtAsset,
                centralRegistry.daoAddress(),
                fee
            );
        }

        // We do not need to check whether cToken is listed
        // or not as even if they found a way to input a malicious
        // token here the post conditional solvency check will revert
        // the whole operation.
        ICToken cToken = leverageAction.cToken;

        // Unwrap leverage instructions for collateral deposit.
        address collateralAsset = cToken.asset();

        _swapDebtAssetToCollateralAsset(leverageAction, owner);

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

    /// @notice Callback function to execute post redemption of
    ///         `cToken`'s underlying and swap it to repay
    ///         active debt for `redeemer`.
    /// @dev Measures slippage after this callback validating that `redeemer`
    ///      is still within acceptable liquidity requirements.
    /// @param cToken The cToken redeemed for its underlying.
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
    ) external override {
        // Take protocol fee, if any.
        address collateralAsset = ICToken(cToken).asset();
        uint256 fee = _getFee(
            cToken,
            collateralAssets,
            address(deleverageAction.cToken),
            deleverageAction.collateralAssets,
            collateralAsset
        );
        
        if (fee > 0) {
            deleverageAction.collateralAssets -= fee;
            SafeTransferLib.safeTransfer(
                collateralAsset,
                centralRegistry.daoAddress(),
                fee
            );
        }

        _swapCollateralAssetToDebtAsset(deleverageAction);

        // We do not need to check whether `borrowableCToken` is listed
        // or not as even if they found a way to input a malicious
        // token here the post conditional solvency check will revert
        // the whole operation.
        IBorrowableCToken borrowableCToken = deleverageAction.borrowableCToken;

        // Unwrap deleverage instructions for debt repayment.
        address debtAsset = borrowableCToken.asset();
        uint256 repayAssets = deleverageAction.repayAssets;
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
        if (deleverageAction.swapAction.length > 0) {
            for (uint256 i; i < deleverageAction.swapAction.length; ++i) {
                remaining = IERC20(deleverageAction.swapAction[i].outputToken)
                    .balanceOf(address(this));
                if (remaining > 0) {
                    SafeTransferLib.safeTransfer(
                        deleverageAction.swapAction[i].outputToken,
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

    /// @notice Calculates the hypothetical maximum amount of
    ///         `borrowableCToken` assets `account` can borrow for maximum
    ///         leverage based on a new `cToken` collateralized deposit.
    /// @dev Applies a minor dampening effect to calculated maximum leverage
    ///      via `MAX_LEVERAGE`. Offsets maximum borrowable debt amount if
    ///      there is insufficient liquidity to borrow in the target market.
    /// @param account The account to query maximum borrow amount for.
    /// @param borrowableCToken The token that `account` will borrow assets
    ///                         from to achieve leverage.
    /// @param cToken The token that `account` will deposit to
    ///                        leverage against.
    /// @param assets The amount of `cToken` underlying that
    ///               `account` will deposit to leverage against.
    /// @return maxDebtBorrowable Returns the maximum remaining borrow amount
    ///                           allowed from `borrowableCToken`, measured in
    ///                           underlying token amount, after the new
    ///                           hypothetical deposit.
    /// @return isOffset Whether the maximum borrowable debt amount returned
    ///                  has been offset due to available liquidity or not.
    function hypotheticalMaxRemainingLeverageOf(
        address account,
        address borrowableCToken,
        address cToken,
        uint256 assets
    ) public view returns (uint256 maxDebtBorrowable, bool isOffset) {
        (uint256 price, uint256 errorCode) = IOracleManager(
            ICentralRegistry(centralRegistry).oracleManager()
        ).getPrice(address(cToken), true, true);

        // Validate we got a price for `cToken`.
        if (errorCode != 0) {
            revert BasePositionManager__InvalidTokenPrice();
        }

        (
            uint256 sumCollateral,
            uint256 maxDebt,
            uint256 sumDebt
        ) = marketManager.statusOf(account);

        uint256 newCollateral = _mulDiv(
            ICToken(cToken).previewDeposit(assets),
            price,
            10 ** ICToken(cToken).decimals()
        );

        uint256 collRatio = marketManager.collateralizationRatio(cToken);
        // If the collateral token cannot be borrowed against the hypothetical
        // leverage check will result in 0 meaning nothing new to leverage
        // against.
        if (collRatio == 0) {
            revert BasePositionManager__InvalidParam();
        }

        sumCollateral += newCollateral;
        maxDebt += _mulDiv(newCollateral, collRatio, WAD);

        maxDebtBorrowable = _maxRemainingLeverageOf(
            sumCollateral,
            maxDebt,
            sumDebt,
            borrowableCToken
        );

        uint256 liquidityAvailable = IERC20(ICToken(borrowableCToken).asset())
            .balanceOf(borrowableCToken);

        if (liquidityAvailable < maxDebtBorrowable) {
            maxDebtBorrowable = liquidityAvailable;
            isOffset = true;
        }
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Calculates the maximum amount of `borrowableCToken` `account`
    ///         can borrow for maximum leverage.
    /// @dev Applies a minor dampening effect to calculated maximum leverage
    ///      via `MAX_LEVERAGE`.
    /// @param account The account to query maximum borrow amount for.
    /// @param borrowableCToken The token that `account` will borrow assets
    ///                         from to achieve leverage.
    /// @return result The maximum remaining borrow amount allowed from
    ///                `borrowableCToken`, measured in debt assets.
    function maxRemainingLeverageOf(
        address account,
        address borrowableCToken
    ) public view returns (uint256 result) {
        (
            uint256 sumCollateral,
            uint256 maxDebt,
            uint256 sumDebt
        ) = marketManager.statusOf(account);

        result =_maxRemainingLeverageOf(
            sumCollateral,
            maxDebt,
            sumDebt,
            borrowableCToken
        );
    }

    /// @inheritdoc ERC165
    function supportsInterface(
        bytes4 interfaceId
    ) public view override returns (bool) {
        return
            interfaceId == type(IPositionManager).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Validate action parameters versus function parameters and
    ///         calculate protocol fee.
    function _getFee(
        address cToken,
        uint256 assets,
        address actionToken,
        uint256 actionAssets,
        address collateralAsset
    ) internal view returns (uint256 result) {
        // Validate that the token itself is executing the callback.
        if (msg.sender != cToken) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        // Validate `cToken` is actually listed in this Market Manager.
        if (!marketManager.isListed(cToken)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        if (IERC20(collateralAsset).balanceOf(address(this)) < assets) {
            revert BasePositionManager__InvalidAmount();
        }

        if (cToken != address(actionToken) || assets != actionAssets) {
            revert BasePositionManager__InvalidParam();
        }

        // Fee is rounded up in favor of protocol.
        result = FixedPointMathLib.mulDivUp(
            assets,
            centralRegistry.protocolLeverageFee(),
            WAD
        );
    }

    /// @notice Leverages an active Curvance position in favor of increasing
    ///         both collateral and debt inside the system.
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
    /// @param account The account to leverage an active Curvance position
    ///                for.
    function _leverage(
        LeverageAction memory leverageAction,
        address account
    ) internal {
        IBorrowableCToken borrowableCToken = leverageAction.borrowableCToken;
        uint256 borrowAssets = leverageAction.borrowAssets;

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
            leverageAction
        );
    }

    /// @notice Deleverages an active Curvance position in favor of decreasing
    ///         both collateral and debt inside the system.
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
    /// @param account The account to deleverage an active Curvance position
    ///                for.
    function _deleverage(
        DeleverageAction memory deleverageAction,
        address account
    ) internal {
        deleverageAction.cToken.withdrawByPositionManager(
            deleverageAction.collateralAssets,
            account,
            deleverageAction
        );
    }

    /// @notice Calculates the maximum amount of `borrowableCToken` assets
    ///         `account` can borrow for maximum leverage.
    /// @dev Applies a minor dampening effect to calculated maximum leverage
    ///      via `MAX_LEVERAGE`.
    /// @param sumCollateral Current total collateral amount of the account.
    /// @param maxDebt Max allowed debt amount of account.
    /// @param sumDebt Current outstanding debt amount of the account.
    /// @param borrowableCToken The token that `account` will borrow from
    ///                         to achieve leverage.
    /// @return result The maximum remaining debt amount allowed from
    ///                `borrowableCToken`, measured in debt assets.
    function _maxRemainingLeverageOf(
        uint256 sumCollateral,
        uint256 maxDebt,
        uint256 sumDebt,
        address borrowableCToken
    ) internal view returns (uint256 result) {
        // We can calculate terminal leverage by calculating the infinite
        // series of swapping to maximum LTV over and over, which results
        // in the equation 1 / (1 - LTV).
        //
        // For example, 80% LTV will result in terminal maximum leverage of:
        // 1 / (1 - .8) -> (1 / 0.2) -> 5x leverage.
        // The equation below is equal to this equation,
        // just extrapolated for an account's collateral vs debt.
        //
        // We also embed a `MAX_LEVERAGE` dampening effect to minimize
        // transaction failure from imperfect execution due to things
        // such as price fluctuations, and AMM fees.
        uint256 maxLeverage = _mulDiv(
            maxDebt - sumDebt,
            sumCollateral * MAX_LEVERAGE,
            sumCollateral - maxDebt
        ) / WAD;

        (uint256 price, uint256 errorCode) = IOracleManager(
            ICentralRegistry(centralRegistry).oracleManager()
        ).getPrice(address(borrowableCToken), true, false);

        // Validate we got a price for `borrowableCToken`.
        if (errorCode != 0) {
            revert BasePositionManager__InvalidTokenPrice();
        }

        result = _mulDiv(
            _mulDiv(maxLeverage, WAD, price),
            10 ** IERC20(borrowableCToken).decimals(),
            WAD
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

    /// @dev Internal helper for reverting efficiently.
    function _revert(uint256 s) internal pure {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, s)
            revert(0x1c, 0x04)
        }
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
        LeverageAction memory leverageAction,
        address /* receiver */
    ) internal virtual;

    /// @notice Callback function on redemption of tokens from a Curvance token
    ///         providing instant liquidity in the collateral token underlying
    ///         which is then swapped into the underlying of a debt token that
    ///         a user is currently borrowing from, partially or fully closing
    ///         a leveraged spot position.
    /// @dev MUST be overridden in every Position Manager implementation.
    function _swapCollateralAssetToDebtAsset(
        DeleverageAction memory deleverageAction
    ) internal virtual;
}
