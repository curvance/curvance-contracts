// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { BasePToken, SafeTransferLib } from "contracts/market/token/BasePToken.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPositionManagement } from "contracts/interfaces/IPositionManagement.sol";

/// @notice Vault Positions must have all assets ready for withdraw,
///         IE assets can NOT be locked.
///         This way assets can be easily liquidated when loans default.
/// @dev Built to support assets that do not generate rewards in external,
///      claimable tokens. Meaning SimplePToken is built for assets such as:
///      WETH, LSTs, LRTs, PTs, UNI, USDC, sDAI, etc.
contract SimplePToken is BasePToken {
    /// ERRORS ///

    error SimplePToken__RedeemMoreThanMax();
    error SimplePToken__WithdrawMoreThanMax();
    error SimplePToken__ZeroShares();
    error SimplePToken__ZeroAssets();

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        IERC20 asset_,
        address marketManager_
    ) BasePToken(centralRegistry_, asset_, marketManager_) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Helper function for Position Management contract to
    ///         redeem assets.
    /// @param owner The owner address of assets to redeem.
    /// @param assets The amount of the underlying assets to redeem.
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
    function withdrawByPositionManagement(
        address owner,
        uint256 assets,
        IPositionManagement.DeleverageStruct memory deleverageData
    ) external override nonReentrant {
        // Validate that the position folding contract is calling.
        if (!marketManager.positionManagement(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        // Cache _totalAssets and balanceOf.
        uint256 ta = _totalAssets;
        uint256 balancePrior = balanceOf(owner);

        // We use a modified version of maxWithdraw which more directly
        // checks whether `assets` is allowed.
        if (assets > _convertToAssets(balancePrior, ta)) {
            // revert with "SimplePToken__WithdrawMoreThanMax".
            _revert(0x7549b48a);
        }

        // No need to check for rounding error, previewWithdraw rounds up.
        uint256 shares = _previewWithdraw(assets, ta);

        // We don't need to precheck approval since position folding will
        // always call based on msg.sender, so there is no trust system.
        // Process withdraw on behalf of `owner`.
        _processWithdraw(
            msg.sender,
            msg.sender,
            owner,
            assets,
            shares,
            ta,
            0
        );

        // Callback to PositionManagement that executes pToken specific logic.
        IPositionManagement(msg.sender).onRedeem(
            address(this),
            owner,
            assets,
            deleverageData
        );

        // Fails if redemption not allowed.
        marketManager.canRedeemWithCollateralRemoval(
            address(this),
            owner,
            balancePrior,
            shares,
            false
        );
    }

    // PERMISSIONED FUNCTIONS

    /// @notice Starts a pToken market, executed via marketManager.
    /// @dev This initial mint is a failsafe against rounding exploits,
    ///      although, we protect against them in many ways,
    ///      better safe than sorry.
    /// @param by The account initializing the pToken market.
    /// @return Returns with true when successful.
    function startMarket(
        address by
    ) external override nonReentrant returns (bool) {
        _startMarket(by);
        return true;
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Deposits `assets` and mints shares to `receiver`.
    /// @param assets The amount of the underlying asset to supply.
    /// @param receiver The account that should receive the pToken shares.
    /// @return shares The amount of pToken shares received by `receiver`.
    function _deposit(
        uint256 assets,
        address receiver
    ) internal override returns (uint256 shares) {
        if (assets == 0) {
            revert SimplePToken__ZeroAssets();
        }

        // Fails if deposit not allowed, this stands in for a maxDeposit
        // check reviewing isListed and mintPaused != 2.
        marketManager.canMint(address(this));

        // Cache _totalAssets.
        uint256 ta = _totalAssets;

        // Check for rounding error, since we round down in previewDeposit.
        if ((shares = _previewDeposit(assets, ta)) == 0) {
            revert SimplePToken__ZeroShares();
        }

        // Execute deposit.
        _processDeposit(msg.sender, receiver, assets, shares, ta, 0);
        _afterProcessDeposit(receiver, shares);
    }

    /// @notice Deposits assets and mints `shares` to `receiver`.
    /// @param shares The amount of the underlying assets quoted in shares
    ///               to supply.
    /// @param receiver The account that should receive the pToken shares.
    /// @return assets The amount of pToken shares quoted in assets received
    ///                by `receiver`.
    function _mint(
        uint256 shares,
        address receiver
    ) internal override returns (uint256 assets) {
        if (shares == 0) {
            revert SimplePToken__ZeroShares();
        }

        // Fail if mint not allowed, this stands in for a maxMint
        // check reviewing isListed and mintPaused != 2.
        marketManager.canMint(address(this));

        // Cache _totalAssets.
        uint256 ta = _totalAssets;

        // No need to check for rounding error, previewMint rounds up.
        assets = _previewMint(shares, ta);

        // Execute deposit.
        _processDeposit(msg.sender, receiver, assets, shares, ta, 0);
        _afterProcessDeposit(receiver, shares);
    }

    /// @notice Withdraws `assets` to `receiver` from the market and burns
    ///         `owner` shares.
    /// @param assets The amount of the underlying asset to withdraw.
    /// @param receiver The account that should receive the assets.
    /// @param owner The account that will burn their shares to withdraw
    ///              assets.
    /// @param forceRedeemCollateral Whether the collateral should be always
    ///                              reduced from `owner`'s collateralPosted.
    /// @return shares The amount of assets, quoted in shares received
    ///                by `receiver`.
    function _withdraw(
        uint256 assets,
        address receiver,
        address owner,
        bool forceRedeemCollateral
    ) internal override returns (uint256 shares) {
        // Cache _totalAssets.
        uint256 ta = _totalAssets;

        // We use a modified version of maxWithdraw which more directly
        // checks whether `assets` is allowed.
        if (assets > _convertToAssets(balanceOf(owner), ta)) {
            // revert with "SimplePToken__WithdrawMoreThanMax".
            _revert(0x7549b48a);
        }

        // No need to check for rounding error, previewWithdraw rounds up.
        shares = _previewWithdraw(assets, ta);

        // Validate caller is allowed to withdraw `shares` on behalf of
        // `owner`.
        _updateAllowance(owner, shares);

        // Validate that `owner` can redeem `shares`.
        marketManager.canRedeemWithCollateralRemoval(
            address(this),
            owner,
            balanceOf(owner),
            shares,
            forceRedeemCollateral
        );

        // Execute withdrawal.
        _processWithdraw(
            msg.sender,
            receiver,
            owner,
            assets,
            shares,
            ta,
            0
        );
    }

    /// @notice Redeems assets to `receiver` from the market and burns
    ///         `owner` `shares`.
    /// @param shares The amount of shares to burn to withdraw assets.
    /// @param receiver The account that should receive the assets.
    /// @param owner The account that will burn their shares to withdraw
    ///              assets.
    /// @param delegatedAction Whether the action is delegated and should
    ///                        use delegation system instead of normal
    ///                        approval system.
    /// @param forceRedeemCollateral Whether the collateral should be always
    ///                              reduced from `owner`'s collateralPosted.
    /// @return assets The amount of assets received by `receiver`.
    function _redeem(
        uint256 shares,
        address receiver,
        address owner,
        bool delegatedAction,
        bool forceRedeemCollateral
    ) internal override returns (uint256 assets) {
        // Validate caller is allowed to withdraw `shares` on behalf of
        // `owner`. Or whether the caller has delegated approval or not.
        if (delegatedAction) {
            _checkDelegate(owner, msg.sender);
        } else {
            _updateAllowance(owner, shares);
        }

        // Check whether `shares` is above max allowed redemption.
        if (shares > maxRedeem(owner)) {
            // revert with "SimplePToken__RedeemMoreThanMax".
            _revert(0xf2cb1343);
        }

        // Validate that `owner` can redeem `shares`.
        marketManager.canRedeemWithCollateralRemoval(
            address(this),
            owner,
            balanceOf(owner),
            shares,
            forceRedeemCollateral
        );

        // Cache _totalAssets.
        uint256 ta = _totalAssets;

        // Check for rounding error, since we round down in previewRedeem.
        if ((assets = _previewRedeem(shares, ta)) == 0) {
            revert SimplePToken__ZeroAssets();
        }

        // Execute withdrawal.
        _processWithdraw(
            msg.sender,
            receiver,
            owner,
            assets,
            shares,
            ta,
            0
        );
    }

    /// @notice Updates asset values for a pending deposit request.
    /// @param assets The amount of the underlying asset to deposit.
    /// @param ta The current total number of assets for assets to shares
    ///           conversion.
    function _updateAssetsForDeposit(
        uint256 assets,
        uint256 ta,
        uint256 /* pending */
    ) internal override {
        // Document addition of `assets` to `ta` due to deposit.
        unchecked {
            _totalAssets = ta + assets;
        }
    }

    /// @notice Updates asset values for a pending withdrawal request.
    /// @param assets The amount of the underlying asset to withdraw.
    /// @param ta The current total number of assets for assets to shares
    ///           conversion.
    function _updateAssetsForWithdrawal(
        uint256 assets,
        uint256 ta,
        uint256 /* pending */
    ) internal override {
        // Document removal of `assets` from `ta` due to withdrawal.
        _totalAssets = ta - assets;
    }
}
