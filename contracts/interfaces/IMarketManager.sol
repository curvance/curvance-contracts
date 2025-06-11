// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IMToken } from "contracts/interfaces/IMToken.sol";

interface IMarketManager {
    /// TYPES ///

    /// @notice Data structure passed communicating the intended liquidation
    ///         scenario to review based on current liquidity levels.
    /// @param eToken Token to potentially repay which is borrowed by
    ///               `account`.
    /// @param cToken Token which was used as collateral by `account` and may
    ///               be seized.
    /// @param numAccounts The number of accounts to be, potentially,
    ///                    liquidated.
    /// @param liquidateExact Whether the liquidator desires a specific
    ///                       liquidation amount.
    /// @param eTokenRepaid Empty variable slot to store how much `eToken`
    ///                     will be repaid as part of a particular
    ///                     liquidation.
    /// @param cTokenLiquidated Empty variable slot to store how much
    ///                         `cToken` will be seized as part of a
    ///                         particular liquidation.
    /// @param badDebt Empty variable slot to store how much bad debt will
    ///                be realized by lenders as part of a particular
    ///                liquidation.
    struct LiqInstructions {
        address eToken;
        address cToken;
        uint256 numAccounts;
        bool liquidateExact;
        uint256 eTokenRepaid;
        uint256 cTokenLiquidated;
        uint256 badDebt;
    }

    /// @notice Data structure returned communicating outcome of a liquidity
    ///         scenario review based on current liquidity levels.
    /// @param liquidatedAmounts An array containing the collateral amounts to
    ///                          liquidate from accounts.
    /// @param debtRepaid The total amount of debt to repay from accounts.
    /// @param badDebtRealized The total amount of debt to realize as losses
    ///                        for lenders inside this market.
    struct LiqResults {
        uint256[] liquidatedAmounts;
        uint256 debtRepaid;
        uint256 badDebtRealized;
    }

    /// @notice Whether mToken minting is paused.
    /// @dev Token => 0 or 1 = unpaused; 2 = paused.
    function mintPaused(address mToken) external view returns (uint256);

    /// @notice Whether mToken collateralization is paused.
    /// @dev Token => 0 or 1 = unpaused; 2 = paused.
    function collateralizationPaused(
        address mToken
    ) external view returns (uint256);

    /// @notice Checks if the account should be allowed to mint tokens
    ///         in the given market.
    /// @param mToken The token to verify mints against.
    function canMint(address mToken) external;

    /// @notice Checks if the account should be allowed to collateralize
    ///         their shares of the given market.
    ///         Prunes unused positions in `account` data.
    /// @dev May emit a {PositionUpdated} event.
    /// @param pToken The position token to verify collateralization of.
    /// @param account The account which would collateralize the asset.
    /// @param newNetCollateral The amount of shares that would be
    ///                         collateralized in total if allowed.
    function canCollateralize(
        address pToken,
        address account,
        uint256 newNetCollateral
    ) external;

    /// @notice Checks if the account should be allowed to redeem tokens
    ///         in the given market.
    /// @param mToken The market to verify the redeem against.
    /// @param account The account which would redeem the tokens.
    /// @param amount The number of mTokens to exchange
    ///               for the underlying asset in the market.
    function canRedeem(
        address mToken,
        address account,
        uint256 amount
    ) external;

    /// @notice Checks if the account should be allowed to redeem tokens
    ///         in the given market, and then redeems.
    /// @dev This can only be called by the mToken itself
    ///      (specifically pTokens, because eTokens are never collateral).
    /// @param mToken The market to verify the redeem against.
    /// @param account The account which would redeem the tokens.
    /// @param balanceOf The current mToken share balance of `account`.
    /// @param collateralPosted The current mToken shares posted as
    ///                         collateral by `account`.
    /// @param amount The number of pToken shares to redeem for the
    ///               underlying asset in the market.
    /// @param forceRedeemCollateral Whether the collateral should be always
    ///                              reduced.
    function canRedeemWithCollateralRemoval(
        address mToken,
        address account,
        uint256 balanceOf,
        uint256 collateralPosted,
        uint256 amount,
        bool forceRedeemCollateral
    ) external returns (uint256);

    /// @notice Checks if the account should be allowed to borrow
    ///         the underlying asset of the given market.
    /// @dev May emit a {TokenPositionCreated} event.
    /// @param eToken The debt token to verify the borrow of.
    /// @param account The account which would borrow the asset.
    /// @param newNetDebt The amount of assets that would be
    ///                   outstanding debt in total if allowed.
    /// @param amount The amount of underlying the account would borrow.
    function canBorrow(
        address eToken,
        address account,
        uint256 newNetDebt,
        uint256 amount
    ) external;

    /// @notice Checks if the account should be allowed to borrow
    ///         the underlying asset of the given market,
    ///         and notifies the market of the borrow.
    /// @dev This can only be called by the market itself.
    /// @param mToken The market to verify the borrow against.
    /// @param account The account which would borrow the asset.
    /// @param newNetDebt The amount of assets that would be
    ///                   outstanding debt in total if allowed.
    /// @param amount The amount of underlying the account would borrow.
    function canBorrowWithNotify(
        address mToken,
        address account,
        uint256 newNetDebt,
        uint256 amount
    ) external;

    /// @notice Checks if the account should be allowed to repay a borrow
    ///         in the given market.
    /// @param mToken The market to verify the repay against.
    /// @param account The account who will have their loan repaid.
    function canRepay(address mToken, address account) external;

    /// @notice Checks if the liquidation should be allowed to occur,
    ///         and returns how many position tokens should be seized
    ///         on liquidation.
    /// @param accounts The addresses of the accounts to be liquidated.
    /// @param debtAmounts The amounts of underlying asset the liquidator
    ///                    wishes to repay, empty if desired to max liquidate.
    /// @param instructions A LiqInstructions struct containing:
    ///               eToken Debt token to repay which is borrowed by
    ///                      `account`.
    ///               cToken Position token which was used as collateral
    ///                      and will be seized.
    ///               numAccounts The number of accounts to be potentially
    ///                           liquidated.
    ///               liquidateExact Whether the liquidator desires a
    ///                              specific liquidation amount.
    function canLiquidate(
        address liquidator,
        address[] calldata accounts,
        uint256[] memory debtAmounts,
        IMarketManager.LiqInstructions memory instructions
    ) external view returns (LiqResults memory, uint256[] memory);

    /// @notice Checks if the seizing of assets should be allowed to occur.
    /// @param cToken Asset which was used as collateral and will be seized.
    /// @param earnToken Asset which was borrowed by the account.
    function canSeize(address cToken, address earnToken) external;

    /// @notice Checks if the account should be allowed to transfer collateral
    ///         tokens in the given market.
    /// @param mToken The market token to verify the transfer of.
    /// @param from The account which will transfer the tokens.
    /// @param balanceOf The current balance that `from` has of `cToken`
    ///                  shares.
    /// @param collateralPosted The amount of `mToken` shares posted as
    ///                         collateral by `from`.
    /// @param amount The amount of `mToken` to transfer.
    function canTransferCToken(
        address mToken,
        address from,
        uint256 balanceOf,
        uint256 collateralPosted,
        uint256 amount
    ) external returns (uint256);

    /// @notice Checks if the account should be allowed to transfer debt
    ///         tokens in the given market.
    /// @param mToken The market token to verify the transfer of.
    /// @param from The account which the tokens will be transferred from.
    /// @param amount The amount of `mToken` to transfer.
    function canTransferEToken(
        address mToken,
        address from,
        uint256 amount
    ) external;

    /// @notice Updates `account` cooldownTimestamp to the current block
    ///         timestamp.
    /// @dev The caller must be a listed MToken in the `markets` mapping.
    /// @param mToken The address of the eToken that the account is borrowing.
    /// @param account The address of the account that has just borrowed.
    function notifyBorrow(address mToken, address account) external;

    /// @notice A list of all tokens inside this market for
    ///         offchain querying.
    function queryTokensListed() external view returns (address[] memory);

    /// @notice Returns whether `mToken` is listed in the lending market.
    /// @param mToken market token address.
    function isListed(address mToken) external view returns (bool);

    /// @notice Returns the ratio at which `mToken` can be collateralized.
    /// @return Ratio returned in `WAD`, e.g. 0.8e18 = 80% collateral value.
    function collateralizationRatio(
        address mToken
    ) external view returns (uint256);

    /// @notice The total amount of `mToken` that can be posted as collateral,
    ///         in shares.
    function collateralCaps(address mToken) external view returns (uint256);

    /// @notice The total amount of `mToken` underlying that can be borrowed,
    ///         in assets.
    function debtCaps(address mToken) external view returns (uint256);

    /// @notice Returns the assets an account has entered.
    /// @param account The address of the account to pull assets for.
    /// @return A dynamic list with the assets `account` has entered.
    function assetsOf(
        address account
    ) external view returns (IMToken[] memory);

    /// @notice Determine `account`'s current status between collateral,
    ///         debt, and additional liquidity.
    /// @param account The account to determine liquidity for.
    /// @return The current total collateral amount of `account`.
    /// @return The maximum debt amount of `account` can take out with
    ///         their current collateral.
    /// @return The current total borrow amount of `account`.
    function statusOf(
        address account
    ) external view returns (uint256, uint256, uint256);

    /// @notice Determine whether `account` can be liquidated,
    ///         by calculating their lFactor, based on their
    ///         collateral versus outstanding debt.
    /// @param account The account to check liquidation status for.
    /// @param eToken The eToken to be repaid during potential liquidation.
    /// @param cToken The cToken to be seized during potential
    ///                        liquidation.
    /// @return lfactor `account`'s current lFactor, an lFactor at or above 1
    ///                 indicates a soft liquidation, with a value of
    ///                 1e18 (WAD) indicating a hard liquidation.
    /// @return earnTokenPrice Current price for `earnToken`.
    /// @return positionTokenPrice Current price for `cToken`.
    function liquidationStatusOf(
        address account,
        address eToken,
        address cToken
    ) external view returns (uint256, uint256, uint256);

    /// @notice Returns whether `addressToCheck` is an approved position
    ///         manager or not.
    /// @param addressToCheck Address to check for position management
    ///                       authority.
    function isPositionManager(
        address addressToCheck
    ) external view returns (bool);
}
