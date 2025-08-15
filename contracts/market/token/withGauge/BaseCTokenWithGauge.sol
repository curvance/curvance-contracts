// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { IGaugeManager } from "contracts/interfaces/IGaugeManager.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @notice Curvance's cTokens (Curvance Tokens) are ERC4626 compliant. However,
///         they follow their own design flow modifying underlying mechanisms
///         such as totalAssets following a vesting mechanism in yield-bearing
///         scenarios and a direct conversion in basic or "simple" vaults.
///
///         The "cToken" employs two different methods of engaging with the
///         Curvance protocol. Users can deposit an unlimited amount of assets,
///         which may or may not benefit from some form of yield.
///
///         Users can at any time, choose to "post" their cTokens as collateral
///         inside the Curvance Protocol, unlocking their ability to borrow
///         against these assets. Posting collateral carries restrictions,
///         not all assets inside Curvance can be collateralized, and if they
///         can, they have a "Collateral Cap" which restricts the total amount of
///         exogeneous risk introduced by each asset into the system.
///
///         These caps can be updated as needed by the DAO and should be
///         configured based on "sticky" onchain liquidity in the corresponding
///         asset.
///
///         Each token can have their minting, collateralization, borrowing,
///         compounding, or redemption functionality paused. Modifying the
///         maximum mint, deposit, withdrawal, or redemptions possible.
///
///         View functions are "safe" by introducing reentry and update
///         protection logic to minimize risks when integrating with Curvance.
///
/// @dev `Asset()` Positions must have all assets ready for withdraw,
///      IE assets can NOT be locked.
///      This way assets can be easily liquidated when loans default.
///
///      All token deposits are recorded in the protocol "Gauge Manager"
///      facilitating the distribution of native tokens both liquid and
///      locked to users based on their contributions to the protocol over
///      time.
abstract contract BaseCTokenWithGauge is BaseCToken {
    /// CONSTANTS ///

    /// @notice Address of the Gauge Manager.
    IGaugeManager public immutable gaugeManager;

    /// ERRORS ///

    error BaseCToken__InvalidGaugeManager();

    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
    /// @param asset_ The address of the underlying asset for this cToken.
    /// @param mm The address of the MarketManager which manages liquidity
    ///           positions between linked cTokens inside a joint market.
    constructor(
        ICentralRegistry cr,
        IERC20 asset_,
        address mm
    ) BaseCToken(cr, asset_, mm) {
        address gaugeManagerAddress = centralRegistry.gaugeManager();

        // Validate Gauge Manager has been set.
        if (gaugeManagerAddress == address(0)) {
            revert BaseCToken__InvalidGaugeManager();
        }
        // Set `gaugeManager`.
        gaugeManager = IGaugeManager(gaugeManagerAddress);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice An optional set of instructions to execute before processing
    ///         a deposit of `receiver`'s shares.
    /// @param shares The amount of cToken shares received by `receiver`.
    /// @param receiver The account that should receive the cToken shares.
    function _afterDepositAction(
        uint256 shares,
        address receiver
    ) internal override {
        // Update Gauge Manager values for `receiver`.
        gaugeManager.deposit(address(this), receiver, shares);
    }

    /// @notice An optional set of instructions to execute before processing
    ///         a withdrawal of `owners`'s shares.
    /// @param shares The amount of assets, quoted in shares received
    ///               by `receiver`.
    /// @param owner The account that will burn their shares to withdraw
    ///              assets.
    function _beforeWithdrawAction(
        uint256 shares,
        address owner
    ) internal override {
        // Update Gauge Manager values for `owner`.
        gaugeManager.withdraw(address(this), owner, shares);
    }

    /// @notice An optional set of instructions to execute before processing
    ///         a transfer of `from`'s shares to `to`.
    /// @param shares The number of shares to transfer from `owner` to
    ///               `receiver`.
    /// @param receiver The address of the destination account to receive
    ///                 `shares` shares.
    /// @param owner The address of the account transferring `shares`
    ///             shares from.
    function _beforeTransferAction(
        uint256 shares,
        address receiver,
        address owner
    ) internal override {
        // Update Gauge Manager values for `owner`.
        gaugeManager.withdraw(address(this), owner, shares);

        // Update Gauge Manager values for `receiver`.
        gaugeManager.deposit(address(this), receiver, shares);
    }

    /// @notice An optional set of instructions to execute before processing
    ///         liquidation of `account`'s collateral.
    /// @param account The account having collateral seized.
    /// @param liquidator The account receiving seized collateral.
    /// @param shares The total number of cTokens shares to seize.
    function _beforeLiqAction(
        uint256 shares,
        address liquidator,
        address account
    ) internal override {
        // Process virtual balance updates and accrued rewards from this
        // liquidation.
        gaugeManager.processLiquidation(
            address(this),
            account,
            liquidator,
            shares
        );
    }
}
