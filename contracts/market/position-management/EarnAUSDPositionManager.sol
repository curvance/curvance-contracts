// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ICentralRegistry } from "contracts/market/position-management/BasePositionManager.sol";
import { SingleSidedVaultPositionManager } from "contracts/market/position-management/SingleSidedVaultPositionManager.sol";
import { IEarnAUSDVault } from "contracts/interfaces/external/Upshift/IEarnAUSDVault.sol";
import { IEarnAUSDReceiptToken } from "contracts/interfaces/external/Upshift/IEarnAUSDReceiptToken.sol";

/// @title Curvance EarnAUSD Position Manager.
/// @notice EarnAUSD-specific contract for executing leverage related actions.
/// @dev Curvance Position Manager contracts enshrine actions that
///      usually would require multiple sequential actions to facilitate,
///      specifically leveraging a position up or deleveraging it for
///      withdrawal.
///
///      Curvance token contracts facilitate these operations through
///      enshrined integrations with Position Manager callback functions.
///
///      Typical workflow for:
///      Leverage -> borrow assets from a borrowableCToken -> swap debt assets
///      into collateral assets -> deposit collateral assets and collateralize
///      received shares -> check that there is no liquidity shortfall from
///      the initial assets borrowed versus the new collateralized shares.
///
///      Deleverage -> redeem collateralized shares from a cToken for assets
///      -> swap collateral assets for debt assets -> repay outstanding debt
///      with debt assets -> check that there is no liquidity shortfall from
///      the initial shares redeemed versus the newly decreased outstanding
///      debt.
///
///      The "EarnAUSD" contract is the position manager for working with
///      Upshift's unique dual vault architecture, and a redemption
///      cooldown period. No type specific "_swapCollateralAssetToDebtAsset"
///      is written, execution is intended to be the same as the "simple"
///      position manager where collateral is simply swapped via dex
///      aggregator.
///
contract EarnAUSDVaultPositionManager is SingleSidedVaultPositionManager {
    /// CONSTANTS ///

    /// @notice The address of AUSD on this chain.
    address public immutable AUSD;

    /// @notice The address of EarnAUSD's vault on this chain.
    address public immutable earnAUSDVault;

    /// @notice The address of EarnAUSD's receipt token on this chain.
    address public immutable earnAUSDReceiptToken;

    /// ERRORS ///

    error EarnAUSDPositionManager__InvalidUnderlying();
    error EarnAUSDPositionManager__InvalidReceiptToken();
    error EarnAUSDPositionManager__InvalidVault();

    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
    /// @param mm The address of the MarketManager which manages liquidity
    ///           positions between linked cTokens inside a joint market.
    /// @param wNative The address of wrapped native token.
    constructor(
        ICentralRegistry cr,
        address mm,
        address wNative,
        address _AUSD,
        address _earnAUSDVault,
        address _earnAUSDReceiptToken
    ) SimplePositionManager(cr, mm, wNative) {
        IIEarnAUSDReceiptToken receiptToken =
            IEarnAUSDReceiptToken(_earnAUSDReceiptToken);
        IEarnAUSDVault vault = IEarnAUSDVault(_earnAUSDVault);
        // Validate that `_earnAUSDVault` has mint/burn perms.
        if (
            !receiptToken.minters(_earnAUSDVault) ||
            !receiptToken.burners(_earnAUSDVault)
        ) {
            revert EarnAUSDPositionManager__InvalidVault();
        }

        // Validate that the vault's expected asset is `_AUSD`.
        if (vault.asset() != _AUSD) {
            revert EarnAUSDPositionManager__InvalidUnderlying();
        }

        // Validate that the vault's LP token is `_earnAUSDReceiptToken`.
        if (vault.lpTokenAddress() != _earnAUSDReceiptToken) {
            revert EarnAUSDPositionManager__InvalidReceiptToken();
        }

        AUSD = _AUSD;
        earnAUSDVault = _earnAUSDVault;
        earnAUSDReceiptToken = _earnAUSDReceiptToken;
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Simple helper for getting vault address and corresponding
    ///         underlying token, potentially overridden in child
    ///         implementations for dual contract vault structures such as
    ///         Upshift.
    /// @param cTokenAddress The Curvance token address corresponding to a
    ///                      vault receipt token contract.
    /// @return vault The receipt token's vault address.
    /// @return underlying The address of the underlying asset of the receipt
    ///                    token of `vault`.
    function _getVaultAndUnderlying(
        address cTokenAddress
    ) internal override view returns (address vault, address underlying) {
        if (cTokenAddress != earnAUSDReceiptToken) {
            revert EarnAUSDPositionManager__InvalidReceiptToken();
        }

        vault = earnAUSDVault;
        underlying = AUSD;
    }
}