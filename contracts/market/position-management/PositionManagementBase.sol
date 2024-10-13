// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { SimplePToken } from "contracts/market/token/SimplePToken.sol";
import { EToken, WAD } from "contracts/market/token/EToken.sol";

import { Multicall } from "contracts/libraries/Multicall.sol";
import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";
import { DENOMINATOR, WAD } from "contracts/libraries/Constants.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { ReentrancyGuard } from "contracts/libraries/external/ReentrancyGuard.sol";
import { ERC165 } from "contracts/libraries/external/ERC165.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";
import { IMarketManager } from "contracts/interfaces/market/IMarketManager.sol";
import { IMToken } from "contracts/interfaces/market/IMToken.sol";
import { IPositionManagement } from "contracts/interfaces/market/IPositionManagement.sol";

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
    ///         in basis points.
    /// @dev 9900 = 99% = 0.99.
    uint256 public constant MAX_LEVERAGE = 9900;

    /// @dev `bytes4(keccak256(bytes("BasePositionManagement__Unauthorized()")))`
    uint256 internal constant _UNAUTHORIZED_SELECTOR = 0xd52ee86d;

    /// @notice Address of the Market Manager linked to this contract.
    IMarketManager public immutable marketManager;

    /// ERRORS ///

    error BasePositionManagement__Unauthorized();
    error BasePositionManagement__InvalidSlippage();
    error BasePositionManagement__InvalidMarketManager();
    error BasePositionManagement__InvalidSwapperParam();
    error BasePositionManagement__InvalidParam();
    error BasePositionManagement__InvalidAmount();
    error BasePositionManagement__InvalidTokenPrice();
    error BasePositionManagement__ExceedsMaximumBorrowAmount(
        uint256 amount,
        uint256 maximum
    );

    /// MODIFIERS ///

    /// @dev Checks slippage on position folding prior and after
    ///      leverage/deleverage action, works similar to reentryguard
    ///      with pre and post checks.
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
                (liquidityBefore * slippage) / DENOMINATOR
            ) {
                revert BasePositionManagement__InvalidSlippage();
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
            revert BasePositionManagement__InvalidMarketManager();
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
    /// @param assets The amount of the underlying assets to deposit.
    /// @param leverageData Struct containing instructions on desired
    ///                     leverage action.
    /// @param slippage Slippage accepted by the user for execution of
    ///                 `leverageData` leverage action, in basis points.
    function depositAndleverage(
        uint256 assets,
        LeverageStruct calldata leverageData,
        uint256 slippage
    ) external checkSlippage(msg.sender, slippage) nonReentrant {
        SimplePToken pToken = leverageData.positionToken;
        address pTokenUnderlying = pToken.asset();
        SafeTransferLib.safeTransferFrom(
            pTokenUnderlying,
            msg.sender,
            address(this),
            assets
        );
        SwapperLib._approveTokenIfNeeded(
            pTokenUnderlying,
            address(pToken),
            assets
        );
        pToken.depositAsCollateralFor(assets, msg.sender);
        _leverage(leverageData, msg.sender);
    }

    /// @notice Leverages an active Curvance position in favor of increasing
    ///         both collateral and debt inside the system.
    /// @dev Measures slippage through pre/post conditional slippage check
    ///      in `checkSlippage` modifier.
    /// @param leverageData Struct containing instructions on desired
    ///                     leverage action.
    /// @param slippage Slippage accepted by the user for execution of
    ///                 `leverageData` leverage action, in basis points.
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
    /// @param leverageData Struct containing instructions on desired
    ///                     leverage action.
    /// @param account The account to leverage an active Curvance position
    ///                for.
    /// @param slippage Slippage accepted by the user for execution of
    ///                 `leverageData` leverage action, in basis points.
    function leverageFor(
        LeverageStruct calldata leverageData,
        address account,
        uint256 slippage
    ) external checkSlippage(account, slippage) nonReentrant {
        if (!_checkIsDelegate(account, msg.sender)) {
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
    /// @param deleverageData Struct containing instructions on desired
    ///                       deleverage action.
    /// @param slippage Slippage accepted by the user for execution of
    ///                 `deleverageData` deleverage action, in basis points.
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
    /// @param deleverageData Struct containing instructions on desired
    ///                       deleverage action.
    /// @param account The account to deleverage an active Curvance position
    ///                for.
    /// @param slippage Slippage accepted by the user for execution of
    ///                 `deleverageData` deleverage action, in basis points.
    function deleverageFor(
        DeleverageStruct calldata deleverageData,
        address account,
        uint256 slippage
    ) external checkSlippage(account, slippage) nonReentrant {
        if (!_checkIsDelegate(account, msg.sender)) {
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
    /// @param leverageData Swap and deposit instructions.
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

        if (
            borrowToken != address(leverageData.borrowToken) ||
            borrowAmount != leverageData.borrowAmount
        ) {
            revert BasePositionManagement__InvalidParam();
        }

        address borrowUnderlying = SimplePToken(borrowToken).underlying();

        if (IERC20(borrowUnderlying).balanceOf(address(this)) < borrowAmount) {
            revert BasePositionManagement__InvalidAmount();
        }

        // Take protocol fee, if any.
        uint256 fee = (borrowAmount * getProtocolLeverageFee()) / WAD;
        if (fee > 0) {
            SafeTransferLib.safeTransfer(
                borrowUnderlying,
                centralRegistry.daoAddress(),
                fee
            );
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
    /// @param deleverageData Swap and repayment instructions.
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

        if (
            positionToken != address(deleverageData.positionToken) ||
            collateralAmount != deleverageData.collateralAmount
        ) {
            revert BasePositionManagement__InvalidParam();
        }

        // Swap position token (pToken underlying) to
        // borrow token (eToken underlying).
        address collateralUnderlying = SimplePToken(positionToken)
            .underlying();

        if (
            IERC20(collateralUnderlying).balanceOf(address(this)) <
            collateralAmount
        ) {
            revert BasePositionManagement__InvalidAmount();
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
        deleverageData.collateralAmount = collateralAmount;
        _swapCollateralToBorrowUnderyling(deleverageData);

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

        // Transfer remaining swap dust back to the user
        if (deleverageData.swapData.length > 0) {
            for (uint256 i = 0; i < deleverageData.swapData.length; ++i) {
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

    /// PUBLIC FUNCTIONS ///

    /// @notice Calculates the maximum amount of `borrowToken` `account` can
    ///         borrow for maximum leverage.
    /// @dev Applies a minor dampening effect to calculated maximum leverage
    ///      via `MAX_LEVERAGE`.
    /// @param account The account to query maximum borrow amount for.
    /// @param borrowToken The eToken that `account` will borrow from
    ///                    to achieve leverage.
    /// @return The maximum borrow amount allowed from eToken, measured in
    ///         underlying token amount.
    function queryAmountToBorrowForLeverageMax(
        address account,
        address borrowToken
    ) public view returns (uint256) {
        (
            uint256 sumCollateral,
            uint256 maxDebt,
            uint256 sumDebt
        ) = marketManager.statusOf(account);

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
            DENOMINATOR;

        (uint256 price, uint256 errorCode) = IOracleManager(
            ICentralRegistry(centralRegistry).oracleManager()
        ).getPrice(address(borrowToken), true, false);

        // Validate we got a price for `borrowToken`.
        if (errorCode != 0) {
            revert BasePositionManagement__InvalidTokenPrice();
        }

        return
            (((maxLeverage * WAD) / price) *
                (10 ** IERC20(borrowToken).decimals())) / WAD;
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
    /// @param leverageData Struct containing instructions on desired
    ///                     leverage action.
    /// @param account The account to leverage an active Curvance position
    ///                for.
    function _leverage(
        LeverageStruct memory leverageData,
        address account
    ) internal {
        EToken borrowToken = leverageData.borrowToken;
        uint256 borrowAmount = leverageData.borrowAmount;
        uint256 maxBorrowAmount = queryAmountToBorrowForLeverageMax(
            account,
            address(borrowToken)
        );

        // Validate that the desired borrow amount is within bounds of what
        // will be allowed by the Market Manager.
        if (borrowAmount > maxBorrowAmount) {
            revert BasePositionManagement__ExceedsMaximumBorrowAmount(
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
    /// @param deleverageData Struct containing instructions on desired
    ///                       deleverage action.
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

    function _swapBorrowUnderlyingToCollateral(
        LeverageStruct memory leverageData
    ) internal virtual;

    function _swapCollateralToBorrowUnderyling(
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

    /// @dev from Multicall
    function _getCentralRegistry()
        internal
        view
        override
        returns (ICentralRegistry)
    {
        return ICentralRegistry(centralRegistry);
    }
}
