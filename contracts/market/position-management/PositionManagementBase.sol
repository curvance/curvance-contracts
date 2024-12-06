// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { SimplePToken } from "contracts/market/token/SimplePToken.sol";
import { EToken, WAD } from "contracts/market/token/EToken.sol";

import { Multicall } from "contracts/libraries/Multicall.sol";
import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";
import { WAD } from "contracts/libraries/Constants.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { ReentrancyGuard } from "contracts/libraries/external/ReentrancyGuard.sol";
import { ERC165 } from "contracts/libraries/external/ERC165.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { IMToken } from "contracts/interfaces/IMToken.sol";
import { IPositionManagement } from "contracts/interfaces/IPositionManagement.sol";

/// @dev The Curvance Position Folding contract enshrines actions that
///      usually would require multiple looped actions to facilitate,
///      namely leveraging a position up or deleveraging it for withdrawal.
///
///      PToken and EToken contracts facilitate these operations through
///      integration with Position Foldings callback functions.
abstract contract PositionManagementBase is
    IPositionManagement,
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

    /// @dev `bytes4(keccak256(bytes("PositionManagementBase__Unauthorized()")))`
    uint256 internal constant _UNAUTHORIZED_SELECTOR = 0xdb6ad9f5;

    /// @notice Address of the Market Manager linked to this contract.
    IMarketManager public immutable marketManager;

    /// ERRORS ///

    error PositionManagementBase__Unauthorized();
    error PositionManagementBase__InvalidSlippage();
    error PositionManagementBase__InvalidMarketManager();
    error PositionManagementBase__InvalidSwapperParam();
    error PositionManagementBase__InvalidParam();
    error PositionManagementBase__InvalidAmount();
    error PositionManagementBase__InvalidTokenPrice();
    error PositionManagementBase__ExceedsMaximumBorrowAmount(
        uint256 amount,
        uint256 maximum
    );

    /// MODIFIERS ///

    /// @dev Checks slippage on position folding prior and after
    ///      leverage/deleverage action, works similar to reentryguard
    ///      with pre and post checks.
    /// @param slippage Slippage accepted by the user for execution of
    ///                 `leverageData` leverage action, in WAD (1e18).
    modifier checkSlippage(address account, uint256 slippage) {
        IMToken[] memory mTokens = marketManager.assetsOf(account);
        uint256 numTokens = mTokens.length;
        for (uint256 i; i < numTokens; ++i) {
            if (!mTokens[i].isPToken()) {
                mTokens[i].accrueInterest();
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
                revert PositionManagementBase__InvalidSlippage();
            }
        }
    }

    receive() external payable {}

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address marketManager_
    ) PluginDelegable(centralRegistry_) {
        // Validate that `marketManager_` is configured as a market manager
        // inside the Central Registry.
        if (!centralRegistry_.isMarketManager(marketManager_)) {
            revert PositionManagementBase__InvalidMarketManager();
        }

        marketManager = IMarketManager(marketManager_);
    }

    /// @notice Lightweight getter for any associated leverage fee.
    function getProtocolLeverageFee() public view returns (uint256) {
        return centralRegistry.protocolLeverageFee();
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Deposits into a Curvance position and then leverages in favor
    ///         of increasing both collateral and debt inside the system.
    /// @dev Measures slippage through pre/post conditional slippage check
    ///      in `checkSlippage` modifier. 
    ///      NOTE: The caller MUST have approved this smart contract to have
    ///      delegated actions inside `leverageData.positionToken` or
    ///      depositAsCollateralFor will only deposit and the leverage
    ///      operation will fail.
    /// @param assets The amount of the underlying assets to deposit.
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
    /// @param slippage Slippage accepted by the user for execution of
    ///                 `leverageData` leverage action, in WAD (1e18).
    function depositAndLeverage(
        uint256 assets,
        LeverageStruct calldata leverageData,
        uint256 slippage
    ) external checkSlippage(msg.sender, slippage) nonReentrant {
        SimplePToken pToken = leverageData.positionToken;
        address pTokenUnderlying = pToken.asset();
        // Transfer the underlying tokens to deposit.
        SafeTransferLib.safeTransferFrom(
            pTokenUnderlying,
            msg.sender,
            address(this),
            assets
        );

        // Approve pToken to process a deposit.
        SwapperLib._approveTokenIfNeeded(
            pTokenUnderlying,
            address(pToken),
            assets
        );

        // Deposit and Collateralize the underlying tokens in pToken
        // contract.
        pToken.depositAsCollateralFor(assets, msg.sender);

        // Execute leverage operation.
        _leverage(leverageData, msg.sender);
    }

    /// @notice Leverages an active Curvance position in favor of increasing
    ///         both collateral and debt inside the system.
    /// @dev Measures slippage through pre/post conditional slippage check
    ///      in `checkSlippage` modifier.
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
    /// @param account The account to leverage an active Curvance position
    ///                for.
    /// @param slippage Slippage accepted by the user for execution of
    ///                 `leverageData` leverage action, in WAD (1e18).
    function leverageFor(
        LeverageStruct calldata leverageData,
        address account,
        uint256 slippage
    ) external checkSlippage(account, slippage) nonReentrant {
        if (!isDelegate(account, msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

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
    /// @param account The account to deleverage an active Curvance position
    ///                for.
    /// @param slippage Slippage accepted by the user for execution of
    ///                 `deleverageData` deleverage action, in WAD (1e18).
    function deleverageFor(
        DeleverageStruct calldata deleverageData,
        address account,
        uint256 slippage
    ) external checkSlippage(account, slippage) nonReentrant {
        if (!isDelegate(account, msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        _deleverage(deleverageData, account);
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
    ) external override {
        // Validate that the debt token itself is executing
        // the callback.
        if (msg.sender != borrowToken) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        // Validate the debt token is actually listed to this
        // Market Manager.
        if (!marketManager.isListed(borrowToken)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        address borrowUnderlying = SimplePToken(borrowToken).underlying();

        if (IERC20(borrowUnderlying).balanceOf(address(this)) < borrowAmount) {
            revert PositionManagementBase__InvalidAmount();
        }

        // Take protocol fee, if any.
        uint256 fee = (borrowAmount * getProtocolLeverageFee()) / WAD;
        if (fee > 0) {
            borrowAmount -= fee;
            SafeTransferLib.safeTransfer(
                borrowUnderlying,
                centralRegistry.daoAddress(),
                fee
            );
        }

        if (
            borrowToken != address(leverageData.borrowToken) ||
            borrowAmount != leverageData.borrowAmount
        ) {
            revert PositionManagementBase__InvalidParam();
        }

        // We do not need to check whether positionToken is listed
        // or not as even if they found a way to input a malicious
        // token here the post conditional solvency check will revert
        // the whole operation.
        SimplePToken positionToken = leverageData.positionToken;

        // Unwrap leverage instructions for collateral deposit.
        address collateralUnderlying = positionToken.underlying();

        _swapBorrowUnderlyingToCollateral(leverageData);

        uint256 amount = IERC20(collateralUnderlying).balanceOf(address(this));

        // Approve `amount` of `collateralUnderlying` to pToken contract.
        SwapperLib._approveTokenIfNeeded(
            collateralUnderlying,
            address(positionToken),
            amount
        );

        // Enter Curvance.
        positionToken.depositAsCollateral(amount, borrower);

        uint256 remaining = IERC20(borrowUnderlying).balanceOf(address(this));

        // Transfer remaining borrow underlying back to the user.
        if (remaining > 0) {
            SafeTransferLib.safeTransfer(
                borrowUnderlying,
                borrower,
                remaining
            );
        }

        // Remove any excess approval.
        SwapperLib._removeApprovalIfNeeded(
            borrowUnderlying,
            address(borrowToken)
        );
    }

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
    ) external override {
        // Validate that the position token itself is executing
        // the callback.
        if (msg.sender != positionToken) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        // Validate the position token is actually listed to this
        // Market Manager.
        if (!marketManager.isListed(positionToken)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        // Swap position token (pToken underlying) to
        // borrow token (eToken underlying).
        address collateralUnderlying = SimplePToken(positionToken)
            .underlying();

        if (
            IERC20(collateralUnderlying).balanceOf(address(this)) <
            collateralAmount
        ) {
            revert PositionManagementBase__InvalidAmount();
        }

        // Take protocol fee, if any.
        uint256 fee = (collateralAmount * getProtocolLeverageFee()) / WAD;
        if (fee > 0) {
            collateralAmount -= fee;
            SafeTransferLib.safeTransfer(
                collateralUnderlying,
                centralRegistry.daoAddress(),
                fee
            );
        }

        if (
            positionToken != address(deleverageData.positionToken) ||
            collateralAmount != deleverageData.collateralAmount
        ) {
            revert PositionManagementBase__InvalidParam();
        }

        _swapCollateralToBorrowUnderlying(deleverageData);

        // We do not need to check whether borrowToken is listed
        // or not as even if they found a way to input a malicious
        // token here the post conditional solvency check will revert
        // the whole operation.
        EToken borrowToken = deleverageData.borrowToken;

        // Unwrap deleverage instructions for debt repayment.
        address borrowUnderlying = borrowToken.underlying();
        uint256 repayAmount = deleverageData.repayAmount;
        uint256 remaining = IERC20(borrowUnderlying).balanceOf(address(this)) -
            repayAmount;

        // Approve `repayAmount` of `borrowUnderlying` to eToken contract.
        SwapperLib._approveTokenIfNeeded(
            borrowUnderlying,
            address(borrowToken),
            repayAmount
        );

        // Repay debt.
        borrowToken.repayFor(redeemer, repayAmount);

        // Transfer remaining borrow underlying back to user.
        if (remaining > 0) {
            SafeTransferLib.safeTransfer(
                borrowUnderlying,
                redeemer,
                remaining
            );
        }

        remaining = IERC20(collateralUnderlying).balanceOf(address(this));

        // Transfer remaining collateral underlying back to the user.
        if (remaining > 0) {
            SafeTransferLib.safeTransfer(
                collateralUnderlying,
                redeemer,
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
                        redeemer,
                        remaining
                    );
                }
            }
        }

        // Remove any excess approval.
        SwapperLib._removeApprovalIfNeeded(
            borrowUnderlying,
            address(borrowToken)
        );
    }

    /// @notice Calculates the hypothetical maximum amount of `borrowToken`
    ///         `account` can borrow for maximum leverage based on a new
    ///         position token deposit and collateralized.
    /// @dev Applies a minor dampening effect to calculated maximum leverage
    ///      via `MAX_LEVERAGE`. Offsets maximum borrowable debt amount if
    ///      there is insufficient liquidity to borrow in the target market.
    /// @param account The account to query maximum borrow amount for.
    /// @param borrowToken The eToken that `account` will borrow from
    ///                    to achieve leverage.
    /// @param positionToken The pToken that `account` will deposit to
    ///                      leverage against.
    /// @param collateralAmount The amount of underlying pToken that `account`
    ///                         will deposit to leverage against.
    /// @return Returns the maximum remaining borrow amount allowed from
    ///         `borrowToken`, measured in underlying token amount, after
    ///         the new hypothetical deposit.
    function hypotheticalMaxRemainingLeverageOf(
        address account,
        address borrowToken,
        address positionToken,
        uint256 collateralAmount
    ) public view returns (uint256) {
        (uint256 price, uint256 errorCode) = IOracleManager(
            ICentralRegistry(centralRegistry).oracleManager()
        ).getPrice(address(positionToken), true, true);

        // Validate we got a price for `positionToken`.
        if (errorCode != 0) {
            revert PositionManagementBase__InvalidTokenPrice();
        }

        (
            uint256 sumCollateral,
            uint256 maxDebt,
            uint256 sumDebt
        ) = marketManager.statusOf(account);

        uint256 newCollateral = FixedPointMathLib.mulDiv(
            IMToken(positionToken).previewDeposit(collateralAmount),
            price,
            10 ** IMToken(positionToken).decimals()
        );

        (, uint256 collRatio,,,,,,,) = marketManager.tokenData(positionToken);

        // If the position token cannot be borrowed against the hypothetical
        // leverage check will result in 0 meaning nothing new to leverage
        // against.
        if (collRatio == 0) {
            revert PositionManagementBase__InvalidParam();
        }

        sumCollateral += newCollateral;
        maxDebt += FixedPointMathLib.mulDiv(newCollateral, collRatio, WAD);

        uint256 maxDebtBorrowable = _maxRemainingLeverageOf(
            sumCollateral,
            maxDebt,
            sumDebt,
            borrowToken
        );

        uint256 liquidityAvailable = IERC20(
            IMToken(borrowToken).underlying()
        ).balanceOf(borrowToken);

        if (liquidityAvailable < maxDebtBorrowable) {
            maxDebtBorrowable = liquidityAvailable;
        }

        return maxDebtBorrowable;
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Calculates the maximum amount of `borrowToken` `account` can
    ///         borrow for maximum leverage.
    /// @dev Applies a minor dampening effect to calculated maximum leverage
    ///      via `MAX_LEVERAGE`.
    /// @param account The account to query maximum borrow amount for.
    /// @param borrowToken The eToken that `account` will borrow from
    ///                    to achieve leverage.
    /// @return Returns the maximum remaining borrow amount allowed from
    ///         `borrowToken`, measured in underlying token amount.
    function maxRemainingLeverageOf(
        address account,
        address borrowToken
    ) public view returns (uint256) {
        (
            uint256 sumCollateral,
            uint256 maxDebt,
            uint256 sumDebt
        ) = marketManager.statusOf(account);

        return _maxRemainingLeverageOf(
            sumCollateral,
            maxDebt,
            sumDebt,
            borrowToken
        );
    }

    /// @inheritdoc ERC165
    function supportsInterface(
        bytes4 interfaceId
    ) public view override returns (bool) {
        return
            interfaceId == type(IPositionManagement).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Leverages an active Curvance position in favor of increasing
    ///         both collateral and debt inside the system.
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
    /// @param account The account to leverage an active Curvance position
    ///                for.
    function _leverage(
        LeverageStruct memory leverageData,
        address account
    ) internal {
        EToken borrowToken = leverageData.borrowToken;
        uint256 borrowAmount = leverageData.borrowAmount;
        uint256 maxBorrowAmount = maxRemainingLeverageOf(
            account,
            address(borrowToken)
        );

        // Validate that the desired borrow amount is within bounds of what
        // will be allowed by the Market Manager.
        if (borrowAmount > maxBorrowAmount) {
            revert PositionManagementBase__ExceedsMaximumBorrowAmount(
                borrowAmount,
                maxBorrowAmount
            );
        }

        borrowToken.borrowForPositionManagement(
            account,
            borrowAmount,
            leverageData
        );
    }

    /// @notice Deleverages an active Curvance position in favor of decreasing
    ///         both collateral and debt inside the system.
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
    /// @param account The account to deleverage an active Curvance position
    ///                for.
    function _deleverage(
        DeleverageStruct memory deleverageData,
        address account
    ) internal {
        deleverageData.positionToken.withdrawByPositionManagement(
            account,
            deleverageData.collateralAmount,
            deleverageData
        );
    }

    /// @notice Calculates the maximum amount of `borrowToken` `account` can
    ///         borrow for maximum leverage.
    /// @dev Applies a minor dampening effect to calculated maximum leverage
    ///      via `MAX_LEVERAGE`.
    /// @param sumCollateral total collateral amount of account.
    /// @param maxDebt max borrow amount of account.
    /// @param sumDebt total borrow amount of account.
    /// @param borrowToken The eToken that `account` will borrow from
    ///                    to achieve leverage.
    /// @return Returns the maximum remaining borrow amount allowed from
    ///         `borrowToken`, measured in underlying token amount.
    function _maxRemainingLeverageOf(
        uint256 sumCollateral,
        uint256 maxDebt,
        uint256 sumDebt,
        address borrowToken
    ) internal view returns(uint256) {
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
        ).getPrice(address(borrowToken), true, false);

        // Validate we got a price for `borrowToken`.
        if (errorCode != 0) {
            revert PositionManagementBase__InvalidTokenPrice();
        }

        return
            (((maxLeverage * WAD) / price) *
                (10 ** IERC20(borrowToken).decimals())) / WAD;
    }

    /// @notice Callback function on borrowing tokens from an eToken contract
    ///         providing instant liquidity in the eToken underlying which is
    ///         then swapped into the underlying of a pToken that a user is
    ///         currently putting up as collateral against the eToken debt
    ///         position, creating a leveraged spot position.
    /// @dev MUST be overridden in every position management contract's
    ///      implementation.
    function _swapBorrowUnderlyingToCollateral(
        LeverageStruct memory leverageData
    ) internal virtual;

    /// @notice Callback function on redemption of tokens from a pToken vault
    ///         providing instant liquidity in the pToken underlying which is
    ///         then swapped into the underlying of an eToken that a user is
    ///         currently borrowing from, partially or fully closing a
    ///         leveraged spot position.
    /// @dev MUST be overridden in every position management contract's
    ///      implementation.
    function _swapCollateralToBorrowUnderlying(
        DeleverageStruct memory deleverageData
    ) internal virtual;

    /// @dev Internal helper for reverting efficiently.
    function _revert(uint256 s) internal pure {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, s)
            revert(0x1c, 0x04)
        }
    }

    /// @notice Returns the Protocol Central Registry contract in interface
    ///         form.
    function _getCentralRegistry()
        internal
        view
        override
        returns (ICentralRegistry)
    {
        return ICentralRegistry(centralRegistry);
    }
}
