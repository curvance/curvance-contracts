// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ICentralRegistry } from "contracts/market/position-management/BasePositionManager.sol";
import { DualSidedVaultPositionManager } from "contracts/market/position-management/DualSidedVaultPositionManager.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IUpshiftVault } from "contracts/interfaces/external/upshift/IUpshiftVault.sol";

/// @title Curvance Upshift Vault Position Manager.
/// @notice Position manager for Upshift vaults (e.g., sAUSD) that use
///         `requestRedeem` for instant withdrawals.
/// @dev Extends DualSidedVaultPositionManager because Upshift vaults have
///      instant redemption (lagDuration == 0), allowing deleverage without
///      external swaps when the debt asset matches the vault's underlying.
///
///      Upshift vaults disable standard ERC4626 `withdraw()` and `redeem()`
///      functions (they revert with `WithdrawalRequestRequired`). Instead,
///      withdrawals must use `requestRedeem()` which is instant when the
///      vault's `lagDuration` is zero.
///
///      This contract overrides `_vaultRedeem` to use `requestRedeem`
///      instead of the standard ERC4626 withdraw pattern.
///
contract UpshiftVaultPositionManager is DualSidedVaultPositionManager {
    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
    /// @param mm The address of the MarketManager which manages liquidity
    ///           positions between linked cTokens inside a joint market.
    /// @param wNative The address of wrapped native token.
    constructor(
        ICentralRegistry cr,
        address mm,
        address wNative
    ) DualSidedVaultPositionManager(cr, mm, wNative) {}

    /// INTERNAL FUNCTIONS ///

    /// @notice Simple helper for redeeming from the Upshift vault using
    ///         requestRedeem for instant redemption.
    /// @param vault The vault address.
    /// @param shares The amount of shares to redeem from `vault`.
    /// @return assetsReceived The actual amount of underlying assets received.
    function _vaultRedeem(
        address vault,
        uint256 shares
    ) internal override returns (uint256 assetsReceived) {
        IERC20 underlying = IERC20(IUpshiftVault(vault).asset());
        uint256 assetsBefore = underlying.balanceOf(address(this));

        (assetsReceived, ) = IUpshiftVault(vault).requestRedeem(
            shares,
            address(this),
            address(this)
        );

        if (underlying.balanceOf(address(this)) - assetsBefore < assetsReceived) {
            revert BasePositionManager__InvalidParam();
        }
    }
}
