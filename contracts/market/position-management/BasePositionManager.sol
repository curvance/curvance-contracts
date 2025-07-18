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
    /// @dev 0.99e18 = 99% = 0.99.
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
    ///                 `leverageData` leverage action, in WAD (1e18).
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
        uint256 liquidityBefore = collateralBefore - debtBefore;

        _;

        (uint256 sumCollateral, , uint256 sumDebt) = marketManager.statusOf(
            account
        );

        uint256 liquidityAfter = sumCollateral - sumDebt;
        // If there was slippage, make sure its within slippage tolerance.
        if (liquidityBefore > liquidityAfter) {
            if (
                liquidityBefore - liquidityAfter >=
                (liquidityBefore * slippage) / WAD
            ) {
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

    /// @notice Lightweight getter for any associated leverage fee.
    function getProtocolLeverageFee() public view returns (uint256) {
        return centralRegistry.protocolLeverageFee();
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Allows contract to receive native gas tokens.
    receive() external payable {}

    /// @notice Deposits into a Curvance position and then leverages in favor
    ///         of increasing both collateral and debt inside the system.
    /// @dev Measures slippage through pre/post conditional slippage check
    ///      in `checkSlippage` modifier.
    ///      NOTE: The caller MUST have approved this smart contract to have
    ///      delegated actions inside `leverageData.collateralToken` or
    ///      depositAsCollateralFor will only deposit and the leverage
    ///      operation will fail.
    /// @param assets The amount of the underlying assets to deposit.
    /// @param leverageData Struct containing information on the desired
    ///                     leverage action to execute. Containing values:
    ///                     1. Address of `debtToken` that will be borrowed
    ///                        and swapped.
    ///                     2. The amount of underlying tokens from
    ///                        `debtToken` that will be borrowed, in assets.
    ///                     3. Curvance token that borrowed funds will be
    ///                        swapped into.
    ///                     4. Struct containing instructions on how
    ///                        to handle the necessary swap to 
    ///                        facilitate leveraging.
    ///                     5. Optional auxiliary data for execution of a
    ///                        leverage action.
    /// @param slippage Slippage accepted by the user for execution of
    ///                 `leverageData` leverage action, in WAD (1e18).
    function depositAndLeverage(
        uint256 assets,
        LeverageStruct calldata leverageData,
        uint256 slippage
    ) external checkSlippage(msg.sender, slippage) nonReentrant {
        ICToken cToken = leverageData.collateralToken;
        address cTokenUnderlying = cToken.asset();
        // Transfer the underlying tokens to deposit.
        SafeTransferLib.safeTransferFrom(
            cTokenUnderlying,
            msg.sender,
            address(this),
            assets
        );

        // Approve cToken to process a deposit.
        SwapperLib._approveTokenIfNeeded(
            cTokenUnderlying,
            address(cToken),
            assets
        );

        // Deposit and Collateralize the underlying tokens in cToken
        // contract.
        cToken.depositAsCollateralFor(assets, msg.sender);

        // Execute leverage operation.
        _leverage(leverageData, msg.sender);
    }

    /// @notice Leverages an active Curvance position in favor of increasing
    ///         both collateral and debt inside the system.
    /// @dev Measures slippage through pre/post conditional slippage check
    ///      in `checkSlippage` modifier.
    /// @param leverageData Struct containing information on the desired
    ///                     leverage action to execute. Containing values:
    ///                     1. Address of `debtToken` that will be borrowed
    ///                        and swapped.
    ///                     2. The amount of underlying tokens from
    ///                        `debtToken` that will be borrowed, in assets.
    ///                     3. Curvance token that borrowed funds will be
    ///                        swapped into.
    ///                     4. Struct containing instructions on how
    ///                        to handle the necessary swap to 
    ///                        facilitate leveraging.
    ///                     5. Optional auxiliary data for execution of a
    ///                        leverage action.
    /// @param slippage Slippage accepted by the user for execution of
    ///                 `leverageData` leverage action, in WAD (1e18).
    function leverage(
        LeverageStruct calldata leverageData,
        uint256 slippage
    ) external checkSlippage(msg.sender, slippage) nonReentrant {
        _leverage(leverageData, msg.sender);
    }

    /// @notice Leverages an active Curvance position in favor of increasing
    ///         both collateral and debt inside the system, via delegation.
    /// @dev Measures slippage through pre/post conditional slippage check
    ///      in `checkSlippage` modifier.
    ///      NOTE: Be careful who you approve here!
    ///      The caller can select slippage, potentially causing loss of funds
    ///      if delegation is provided to a malicious party.
    /// @param leverageData Struct containing information on the desired
    ///                     leverage action to execute. Containing values:
    ///                     1. Address of `debtToken` that will be borrowed
    ///                        and swapped.
    ///                     2. The amount of underlying tokens from
    ///                        `debtToken` that will be borrowed, in assets.
    ///                     3. Curvance token that borrowed funds will be
    ///                        swapped into.
    ///                     4. Struct containing instructions on how
    ///                        to handle the necessary swap to 
    ///                        facilitate leveraging.
    ///                     5. Optional auxiliary data for execution of a
    ///                        leverage action.
    /// @param account The account to leverage an active Curvance position
    ///                for.
    /// @param slippage Slippage accepted by the user for execution of
    ///                 `leverageData` leverage action, in WAD (1e18).
    function leverageFor(
        LeverageStruct calldata leverageData,
        address account,
        uint256 slippage
    ) external checkSlippage(account, slippage) nonReentrant {
        _checkDelegate(account, msg.sender);
        _leverage(leverageData, account);
    }

    /// @notice Deleverages an active Curvance position in favor of decreasing
    ///         both collateral and debt inside the system.
    /// @dev Measures slippage through pre/post conditional slippage check
    ///      in `checkSlippage` modifier.
    ///      NOTE: Be careful who you approve here!
    ///      The caller can select slippage, potentially causing loss of funds
    ///      if delegation is provided to a malicious party.
    /// @param deleverageData Struct containing information on the desired
    ///                       deleverage action to execute. Containing values:
    ///                       1. Address of the Curvance token that will be 
    ///                          routed into debt token underlying to repay
    ///                          outstanding debt.
    ///                       2. The amount of `collateralToken` that will be
    ///                          deleveraged, in assets.
    ///                       3. Address of Curvance token that will have its
    ///                          outstanding debt repaid.
    ///                       4. Optional struct containing instructions on
    ///                          how to handle swapping into debt token to
    ///                          facilitate deleveraging.
    ///                       5. The amount of underlying tokens that will be
    ///                          repaid to lenders.
    ///                       6. Optional auxiliary data for execution of a
    ///                          deleverage action.
    /// @param slippage Slippage accepted by the user for execution of
    ///                 `deleverageData` deleverage action, in WAD (1e18).
    function deleverage(
        DeleverageStruct calldata deleverageData,
        uint256 slippage
    ) external checkSlippage(msg.sender, slippage) nonReentrant {
        _deleverage(deleverageData, msg.sender);
    }

    /// @notice Deleverages an active Curvance position in favor of decreasing
    ///         both collateral and debt inside the system, via delegation.
    /// @dev Measures slippage through pre/post conditional slippage check
    ///      in `checkSlippage` modifier.
    /// @param deleverageData Struct containing information on the desired
    ///                       deleverage action to execute. Containing values:
    ///                       1. Address of the Curvance token that will be 
    ///                          routed into debt token underlying to repay
    ///                          outstanding debt.
    ///                       2. The amount of `collateralToken` that will be
    ///                          deleveraged, in assets.
    ///                       3. Address of Curvance token that will have its
    ///                          outstanding debt repaid.
    ///                       4. Optional struct containing instructions on
    ///                          how to handle swapping into debt token to
    ///                          facilitate deleveraging.
    ///                       5. The amount of underlying tokens that will be
    ///                          repaid to lenders.
    ///                       6. Optional auxiliary data for execution of a
    ///                          deleverage action.
    /// @param account The account to deleverage an active Curvance position
    ///                for.
    /// @param slippage Slippage accepted by the user for execution of
    ///                 `deleverageData` deleverage action, in WAD (1e18).
    function deleverageFor(
        DeleverageStruct calldata deleverageData,
        address account,
        uint256 slippage
    ) external checkSlippage(account, slippage) nonReentrant {
        _checkDelegate(account, msg.sender);
        _deleverage(deleverageData, account);
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
    ///                     2. The amount of underlying tokens from
    ///                        `debtToken` that will be borrowed, in assets.
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
    ) external override {
        address borrowUnderlying = IBorrowableCToken(debtToken).asset();
        // Take protocol fee, if any.
        uint256 fee = _getFee(
            debtToken,
            assets,
            address(leverageData.debtToken),
            leverageData.borrowAssets,
            borrowUnderlying
        );
        if (fee > 0) {
            leverageData.borrowAssets -= fee;
            SafeTransferLib.safeTransfer(
                borrowUnderlying,
                centralRegistry.daoAddress(),
                fee
            );
        }

        // We do not need to check whether collateralToken is listed
        // or not as even if they found a way to input a malicious
        // token here the post conditional solvency check will revert
        // the whole operation.
        ICToken collateralToken = leverageData.collateralToken;

        // Unwrap leverage instructions for collateral deposit.
        address collateralUnderlying = collateralToken.asset();

        _swapBorrowUnderlyingToCollateral(leverageData, owner);

        uint256 amount = IERC20(collateralUnderlying).balanceOf(address(this));

        // Approve `amount` of `collateralUnderlying` to `collateralToken` contract.
        SwapperLib._approveTokenIfNeeded(
            collateralUnderlying,
            address(collateralToken),
            amount
        );

        // Enter Curvance.
        collateralToken.depositAsCollateral(amount, owner);

        uint256 remaining = IERC20(borrowUnderlying).balanceOf(address(this));

        // Transfer remaining borrow underlying back to the user.
        if (remaining > 0) {
            SafeTransferLib.safeTransfer(
                borrowUnderlying,
                owner,
                remaining
            );
        }

        // Remove any excess approval.
        SwapperLib._removeApprovalIfNeeded(
            borrowUnderlying,
            address(debtToken)
        );
    }

    /// @notice Callback function to execute post redemption of
    ///         `collateralToken`'s underlying and swap it to repay
    ///         active debt for `redeemer`.
    /// @dev Measures slippage after this callback validating that `redeemer`
    ///      is still within acceptable liquidity requirements.
    /// @param collateralToken The cToken redeemed for its underlying.
    /// @param assets The amount of `collateralToken` underlying redeemed.
    /// @param owner The account redeeming collateral that will be used to
    ///              repay their active debt.
    /// @param deleverageData Struct containing information on the desired
    ///                       deleverage action to execute. Containing values:
    ///                       1. Address of the Curvance token that will be 
    ///                          routed into debt token underlying to repay
    ///                          outstanding debt.
    ///                       2. The amount of `collateralToken` that will be
    ///                          deleveraged, in assets.
    ///                       3. Address of Curvance token that will have its
    ///                          outstanding debt repaid.
    ///                       4. Optional struct containing instructions on
    ///                          how to handle swapping into debt token to
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
    ) external override {
        // Take protocol fee, if any.
        address collateralUnderlying = ICToken(collateralToken).asset();
        uint256 fee = _getFee(
            collateralToken,
            assets,
            address(deleverageData.collateralToken),
            deleverageData.collateralAssets,
            collateralUnderlying
        );
        if (fee > 0) {
            deleverageData.collateralAssets -= fee;
            SafeTransferLib.safeTransfer(
                collateralUnderlying,
                centralRegistry.daoAddress(),
                fee
            );
        }

        _swapCollateralToBorrowUnderlying(deleverageData);

        // We do not need to check whether debtToken is listed
        // or not as even if they found a way to input a malicious
        // token here the post conditional solvency check will revert
        // the whole operation.
        IBorrowableCToken debtToken = deleverageData.debtToken;

        // Unwrap deleverage instructions for debt repayment.
        address borrowUnderlying = debtToken.asset();
        uint256 repayAssets = deleverageData.repayAssets;
        uint256 borrowUnderlyingBalance = IERC20(borrowUnderlying).balanceOf(
            address(this)
        );
        if (repayAssets > borrowUnderlyingBalance) {
            revert BasePositionManager__InsufficientAssetsForRepayment();
        }
        uint256 remaining = borrowUnderlyingBalance - repayAssets;

        // Approve `repayAssets` of `borrowUnderlying` to `debtToken` contract.
        SwapperLib._approveTokenIfNeeded(
            borrowUnderlying,
            address(debtToken),
            repayAssets
        );

        // Repay debt.
        debtToken.repayFor(repayAssets, owner);

        // Transfer remaining borrow underlying back to user.
        if (remaining > 0) {
            SafeTransferLib.safeTransfer(
                borrowUnderlying,
                owner,
                remaining
            );
        }

        remaining = IERC20(collateralUnderlying).balanceOf(address(this));

        // Transfer remaining collateral underlying back to the user.
        if (remaining > 0) {
            SafeTransferLib.safeTransfer(
                collateralUnderlying,
                owner,
                remaining
            );
        }

        // Transfer remaining swap dust back to the user.
        if (deleverageData.swapData.length > 0) {
            for (uint256 i; i < deleverageData.swapData.length; ++i) {
                remaining = IERC20(deleverageData.swapData[i].outputToken)
                    .balanceOf(address(this));
                if (remaining > 0) {
                    SafeTransferLib.safeTransfer(
                        deleverageData.swapData[i].outputToken,
                        owner,
                        remaining
                    );
                }
            }
        }

        // Remove any excess approval.
        SwapperLib._removeApprovalIfNeeded(
            borrowUnderlying,
            address(debtToken)
        );
    }

    /// @notice Calculates the hypothetical maximum amount of `debtToken`
    ///         `account` can borrow for maximum leverage based on a new
    ///         position token deposit and collateralized.
    /// @dev Applies a minor dampening effect to calculated maximum leverage
    ///      via `MAX_LEVERAGE`. Offsets maximum borrowable debt amount if
    ///      there is insufficient liquidity to borrow in the target market.
    /// @param account The account to query maximum borrow amount for.
    /// @param debtToken The token that `account` will borrow from
    ///                  to achieve leverage.
    /// @param collateralToken The token that `account` will deposit to
    ///                        leverage against.
    /// @param assets The amount of `collateralToken` underlying that
    ///               `account` will deposit to leverage against.
    /// @return maxDebtBorrowable Returns the maximum remaining borrow amount
    ///                           allowed from `debtToken`, measured in
    ///                           underlying token amount, after the new
    ///                           hypothetical deposit.
    /// @return isOffset Whether the maximum borrowable debt amount returned
    ///                  has been offset due to available liquidity or not.
    function hypotheticalMaxRemainingLeverageOf(
        address account,
        address debtToken,
        address collateralToken,
        uint256 assets
    ) public view returns (uint256 maxDebtBorrowable, bool isOffset) {
        (uint256 price, uint256 errorCode) = IOracleManager(
            ICentralRegistry(centralRegistry).oracleManager()
        ).getPrice(address(collateralToken), true, true);

        // Validate we got a price for `collateralToken`.
        if (errorCode != 0) {
            revert BasePositionManager__InvalidTokenPrice();
        }

        (
            uint256 sumCollateral,
            uint256 maxDebt,
            uint256 sumDebt
        ) = marketManager.statusOf(account);

        uint256 newCollateral = FixedPointMathLib.mulDiv(
            ICToken(collateralToken).previewDeposit(assets),
            price,
            10 ** ICToken(collateralToken).decimals()
        );

        uint256 collRatio = marketManager.collateralizationRatio(
            collateralToken
        );
        // If the position token cannot be borrowed against the hypothetical
        // leverage check will result in 0 meaning nothing new to leverage
        // against.
        if (collRatio == 0) {
            revert BasePositionManager__InvalidParam();
        }

        sumCollateral += newCollateral;
        maxDebt += FixedPointMathLib.mulDiv(newCollateral, collRatio, WAD);

        maxDebtBorrowable = _maxRemainingLeverageOf(
            sumCollateral,
            maxDebt,
            sumDebt,
            debtToken
        );

        uint256 liquidityAvailable = IERC20(ICToken(debtToken).asset())
            .balanceOf(debtToken);

        if (liquidityAvailable < maxDebtBorrowable) {
            maxDebtBorrowable = liquidityAvailable;
            isOffset = true;
        }
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Calculates the maximum amount of `debtToken` `account` can
    ///         borrow for maximum leverage.
    /// @dev Applies a minor dampening effect to calculated maximum leverage
    ///      via `MAX_LEVERAGE`.
    /// @param account The account to query maximum borrow amount for.
    /// @param debtToken The token that `account` will borrow from
    ///                  to achieve leverage.
    /// @return Returns the maximum remaining borrow amount allowed from
    ///         `debtToken`, measured in underlying token amount.
    function maxRemainingLeverageOf(
        address account,
        address debtToken
    ) public view returns (uint256) {
        (
            uint256 sumCollateral,
            uint256 maxDebt,
            uint256 sumDebt
        ) = marketManager.statusOf(account);

        return
            _maxRemainingLeverageOf(
                sumCollateral,
                maxDebt,
                sumDebt,
                debtToken
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
        address underlying
    ) internal view returns (uint256) {
        // Validate that the token itself is executing the callback.
        if (msg.sender != cToken) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        // Validate `cToken` is actually listed in this Market Manager.
        if (!marketManager.isListed(cToken)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        if (IERC20(underlying).balanceOf(address(this)) < assets) {
            revert BasePositionManager__InvalidAmount();
        }

        if (cToken != address(actionToken) || assets != actionAssets) {
            revert BasePositionManager__InvalidParam();
        }

        // Fee is rounded up in favor of protocol.
        return
            FixedPointMathLib.mulDivUp(assets, getProtocolLeverageFee(), WAD);
    }

    /// @notice Leverages an active Curvance position in favor of increasing
    ///         both collateral and debt inside the system.
    /// @param leverageData Struct containing information on the desired
    ///                     leverage action to execute. Containing values:
    ///                     1. Address of `debtToken` that will be borrowed
    ///                        and swapped.
    ///                     2. The amount of underlying tokens from
    ///                        `debtToken` that will be borrowed, in assets.
    ///                     3. Curvance token that borrowed funds will be
    ///                        swapped into.
    ///                     4. Struct containing instructions on how
    ///                        to handle the necessary swap to 
    ///                        facilitate leveraging.
    ///                     5. Optional auxiliary data for execution of a
    ///                        leverage action.
    /// @param account The account to leverage an active Curvance position
    ///                for.
    function _leverage(
        LeverageStruct memory leverageData,
        address account
    ) internal {
        IBorrowableCToken debtToken = leverageData.debtToken;
        uint256 borrowAssets = leverageData.borrowAssets;
        uint256 maxBorrowAssets = maxRemainingLeverageOf(
            account,
            address(debtToken)
        );

        // Validate that the desired borrow amount is within bounds of what
        // will be allowed by the Market Manager.
        if (borrowAssets > maxBorrowAssets) {
            revert BasePositionManager__ExceedsMaximumBorrowAllowed();
        }

        debtToken.borrowForPositionManager(
            borrowAssets,
            account,
            leverageData
        );
    }

    /// @notice Deleverages an active Curvance position in favor of decreasing
    ///         both collateral and debt inside the system.
    /// @param deleverageData Struct containing information on the desired
    ///                       deleverage action to execute. Containing values:
    ///                       1. Address of the Curvance token that will be 
    ///                          routed into debt token underlying to repay
    ///                          outstanding debt.
    ///                       2. The amount of `collateralToken` that will be
    ///                          deleveraged, in assets.
    ///                       3. Address of Curvance token that will have its
    ///                          outstanding debt repaid.
    ///                       4. Optional struct containing instructions on
    ///                          how to handle swapping into debt token to
    ///                          facilitate deleveraging.
    ///                       5. The amount of underlying tokens that will be
    ///                          repaid to lenders.
    ///                       6. Optional auxiliary data for execution of a
    ///                          deleverage action.
    /// @param account The account to deleverage an active Curvance position
    ///                for.
    function _deleverage(
        DeleverageStruct memory deleverageData,
        address account
    ) internal {
        deleverageData.collateralToken.withdrawByPositionManager(
            deleverageData.collateralAssets,
            account,
            deleverageData
        );
    }

    /// @notice Calculates the maximum amount of `debtToken` `account` can
    ///         borrow for maximum leverage.
    /// @dev Applies a minor dampening effect to calculated maximum leverage
    ///      via `MAX_LEVERAGE`.
    /// @param sumCollateral Current total collateral amount of the account.
    /// @param maxDebt Max allowed debt amount of account.
    /// @param sumDebt Current outstanding debt amount of the account.
    /// @param debtToken The token that `account` will borrow from
    ///                  to achieve leverage.
    /// @return Returns the maximum remaining debt amount allowed from
    ///         `debtToken`, measured in underlying token amount.
    function _maxRemainingLeverageOf(
        uint256 sumCollateral,
        uint256 maxDebt,
        uint256 sumDebt,
        address debtToken
    ) internal view returns (uint256) {
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
        uint256 maxLeverage = ((maxDebt - sumDebt) *
            MAX_LEVERAGE *
            sumCollateral) /
            (sumCollateral - maxDebt) /
            WAD;

        (uint256 price, uint256 errorCode) = IOracleManager(
            ICentralRegistry(centralRegistry).oracleManager()
        ).getPrice(address(debtToken), true, false);

        // Validate we got a price for `debtToken`.
        if (errorCode != 0) {
            revert BasePositionManager__InvalidTokenPrice();
        }

        return
            (((maxLeverage * WAD) / price) *
                (10 ** IERC20(debtToken).decimals())) / WAD;
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
    function _swapBorrowUnderlyingToCollateral(
        LeverageStruct memory leverageData,
        address /* receiver */
    ) internal virtual;

    /// @notice Callback function on redemption of tokens from a Curvance token
    ///         providing instant liquidity in the collateral token underlying
    ///         which is then swapped into the underlying of a debt token that
    ///         a user is currently borrowing from, partially or fully closing
    ///         a leveraged spot position.
    /// @dev MUST be overridden in every Position Manager implementation.
    function _swapCollateralToBorrowUnderlying(
        DeleverageStruct memory deleverageData
    ) internal virtual;
}
