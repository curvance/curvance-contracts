// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IMarketManager {
    /// TYPES ///

    /// @notice Data structure passed communicating the intended liquidation
    ///         scenario to review based on current liquidity levels.
    /// @param collateralToken The token which was used as collateral
    ///                        by `account` and may be seized.
    /// @param debtToken The token to potentially repay which has
    ///                  outstanding debt by `account`.
    /// @param numAccounts The number of accounts to be, potentially,
    ///                    liquidated.
    /// @param liquidateExact Whether the liquidator desires a specific
    ///                       liquidation amount.
    /// @param liquidatedShares Empty variable slot to store how much
    ///                         `collateralToken` will be seized as
    ///                         part of a particular liquidation.
    /// @param debtRepaid Empty variable slot to store how much
    ///                   `debtToken` will be repaid as part of a
    ///                   particular liquidation.
    /// @param badDebt Empty variable slot to store how much bad debt will
    ///                be realized by lenders as part of a particular
    ///                liquidation.
    struct LiqAction {
        address collateralToken;
        address debtToken;
        uint256 numAccounts;
        bool liquidateExact;
        uint256 liquidatedShares;
        uint256 debtRepaid;
        uint256 badDebt;
    }

    /// @notice Data structure returned communicating outcome of a liquidity
    ///         scenario review based on current liquidity levels.
    /// @param liquidatedShares An array containing the collateral amounts to
    ///                         liquidate from accounts, in shares.
    /// @param debtRepaid The total amount of debt to repay from accounts,
    ///                   in assets.
    /// @param badDebtRealized The total amount of debt to realize as losses
    ///                        for lenders, in assets.
    struct LiqResult {
        uint256[] liquidatedShares;
        uint256 debtRepaid;
        uint256 badDebtRealized;
    }

    /// @notice Returns the cooldown period for a specific account.
    /// @param account The address of the account to query.
    /// @return The cooldown period for the specified account, which is 0 if not set
    function cooldown(
        address account
    ) external view returns (uint256);

    /// @notice Returns whether minting, collateralization, borrowing of
    ///         `cToken` is paused.
    /// @param cToken The address of the Curvance token to return
    ///               action statuses of.
    /// @return bool Whether minting `cToken` is paused or not.
    /// @return bool Whether collateralization `cToken` is paused or not.
    /// @return bool Whether borrowing `cToken` is paused or not.
    function actionsPaused(
        address cToken
    ) external view returns (bool, bool, bool);

    /// @notice Returns the current collateralization configuration
    ///         of `cToken`.
    /// @param cToken The address of the Curvance token to return
    ///               collateralization configuration of.
    /// @return The ratio at which this token can be borrowed against
    ///         when collateralized.
    /// @return The collateral requirement where dipping below this
    ///         will cause a soft liquidation.
    /// @return The collateral requirement where dipping below
    ///         this will cause a hard liquidation.
    function collConfig(address cToken) external view returns (
         uint256, uint256, uint256
    );

    /// @notice Returns the current liquidation configuration
    ///         of `cToken`.
    /// @param cToken The address of the Curvance token to return
    ///               liquidation configuration of.
    /// @return The base ratio at which this token will be
    ///         compensated on soft liquidation.
    /// @return The liquidation incentive curve length between soft
    ///         liquidation to hard liquidation, in `WAD`. e.g. 5% base
    ///         incentive with 8% curve length results in 13% liquidation
    ///         incentive on hard liquidation.
    /// @return The minimum possible liquidation incentive for during an
    ///         auction, in `WAD`.
    /// @return The maximum possible liquidation incentive for during an
    ///         auction, in `WAD`.
    /// @return Maximum % that a liquidator can repay when soft
    ///         liquidating an account, in `WAD`.
    /// @return Curve length between soft liquidation and hard liquidation,
    ///         should be equal to 100% - `closeFactorBase`, in `WAD`.
    /// @return The minimum possible close factor for during an auction,
    ///         in `WAD`.
    /// @return The maximum possible close factor for during an auction,
    ///         in `WAD`.
    function liquidationConfig(address cToken) external view returns (
        uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256
    );

    /// @notice Checks if the account should be allowed to mint tokens
    ///         in the given market.
    /// @param cToken The token to verify mints against.
    function canMint(address cToken) external;

    /// @notice Checks if the account should be allowed to collateralize
    ///         their shares of the given market.
    ///         Prunes unused positions in `account` data.
    /// @dev May emit a {PositionUpdated} event.
    /// @param cToken The token to verify collateralization of.
    /// @param account The account which would collateralize the asset.
    /// @param newNetCollateral The amount of shares that would be
    ///                         collateralized in total if allowed.
    function canCollateralize(
        address cToken,
        address account,
        uint256 newNetCollateral
    ) external;

    /// @notice Checks if the account should be allowed to redeem tokens
    ///         in the given market.
    /// @param cToken The market to verify the redeem against.
    /// @param shares The number of cTokens to exchange
    ///               for the underlying asset in the market.
    /// @param account The account which would redeem `shares`.
    function canRedeem(
        address cToken,
        uint256 shares,
        address account
    ) external;

    /// @notice Checks if the account should be allowed to redeem tokens
    ///         in the given market, and then redeems.
    /// @dev This can only be called by the cToken itself.
    /// @param cToken The token to verify the redemption against.
    /// @param shares The number of cToken shares to redeem for the
    ///               underlying asset in the market.
    /// @param account The account which would redeem `shares`.
    /// @param balanceOf The current cToken share balance of `account`.
    /// @param collateralPosted The current cToken shares posted as
    ///                         collateral by `account`.
    /// @param forceRedeemCollateral Whether the collateral should be always
    ///                              reduced.
    function canRedeemWithCollateralRemoval(
        address cToken,
        uint256 shares,
        address account,
        uint256 balanceOf,
        uint256 collateralPosted,
        bool forceRedeemCollateral
    ) external returns (uint256);

    /// @notice Checks if the account should be allowed to borrow
    ///         the underlying asset of the given market.
    ///         Prunes unused positions in `account` data.
    /// @dev May emit a {PositionUpdated} event.
    /// @param cToken The token to verify borrowability of.
    /// @param assets The amount of underlying assets `account` would borrow.
    /// @param account The account which would borrow the asset.
    /// @param newNetDebt The amount of assets that would be
    ///                   outstanding debt in total if allowed.
    function canBorrow(
        address cToken,
        uint256 assets,
        address account,
        uint256 newNetDebt
    ) external;

    /// @notice Checks if the account should be allowed to borrow
    ///         the underlying asset of the given market,
    ///         and notifies the market of the borrow.
    /// @dev This can only be called by the market itself.
    /// @param cToken The market to verify the borrow against.
    /// @param assets The amount of underlying assets `account` would borrow.
    /// @param account The account which would borrow the asset.
    /// @param newNetDebt The amount of assets that would be
    ///                   outstanding debt in total if allowed.
    function canBorrowWithNotify(
        address cToken,
        uint256 assets,
        address account,
        uint256 newNetDebt
    ) external;

    /// @notice Checks if the account should be allowed to repay a borrow
    ///         in the given market.
    /// @param cToken The market to verify the repay against.
    /// @param account The account who will have their loan repaid.
    function canRepay(address cToken, address account) external;

    /// @notice Checks if the liquidation should be allowed to occur,
    ///         and returns how many collateralized shares should be seized
    ///         on liquidation.
    /// @param debtAmounts The amounts of outstanding debt the liquidator
    ///                    wishes to repay, in underlying assets, empty if
    ///                    intention is to liquidate maximum amount possible
    ///                    for each account.
    /// @param liquidator The address of the account trying to liquidate
    ///                   `accounts`.
    /// @param accounts The addresses of the accounts to be liquidated.
    /// @param action A LiqAction struct containing:
    ///               collateralToken The token which is used as collateral
    ///                               by `account` and may be seized.
    ///               debtToken The token to potentially repay which has
    ///                         outstanding debt by `account`.
    ///               numAccounts The number of accounts to be, potentially,
    ///                           liquidated.
    ///               liquidateExact Whether the liquidator desires a
    ///                              specific liquidation amount.
    ///               collateralLiquidated Empty variable slot to store how
    ///                                    much `collateralToken` will be
    ///                                    seized as part of a particular
    ///                                    liquidation.
    ///               debtRepaid Empty variable slot to store how much
    ///                          `debtToken` will be repaid as part of a
    ///                          particular liquidation.
    ///               badDebt Empty variable slot to store how much bad debt
    ///                       will be realized as part of a particular
    ///                       liquidation.
    /// @return result A LiqResult struct containing:
    ///                liquidatedShares An array containing the collateral
    ///                                 amounts to liquidate from
    ///                                 `accounts`.
    ///                debtRepaid The total amount of debt to repay from
    ///                           `accounts`.
    ///                badDebtRealized The total amount of debt to realize as
    ///                                losses for lenders inside this market.
    /// @return An array containing the debt amounts to repay from
    ///        `accounts`, in assets.
    function canLiquidate(
        uint256[] memory debtAmounts,
        address liquidator,
        address[] calldata accounts,
        IMarketManager.LiqAction memory action
    ) external view returns (LiqResult memory, uint256[] memory);

    /// @notice Checks if the seizing of `collateralToken` by repayment of
    ///         `debtToken` should be allowed.
    /// @param collateralToken The Curvance token which was used as collateral
    ///                        and will be seized.
    /// @param debtToken The Curvance token which has outstanding debt to and
    ///                  would be repaid during `collateralToken` seizure.
    function canSeize(address collateralToken, address debtToken) external;

    /// @notice Checks if the account should be allowed to transfer collateral
    ///         tokens in the given market.
    /// @param cToken The Curvance token to verify the transfer of.
    /// @param shares The amount of `cToken` to transfer.
    /// @param account The account which will transfer `shares`.
    /// @param balanceOf The current balance that `account` has of `cToken`
    ///                  shares.
    /// @param collateralPosted The amount of `cToken` shares posted as
    ///                         collateral by `account`.
    /// @param isCollateral Boolean indicating whether the token is currently
    ///                     being used as collateral.
    function canTransfer(
        address cToken,
        uint256 shares,
        address account,
        uint256 balanceOf,
        uint256 collateralPosted,
        bool isCollateral
    ) external returns (uint256);

    /// @notice Updates `account` cooldownTimestamp to the current block
    ///         timestamp.
    /// @dev The caller must be a listed cToken in the `markets` mapping.
    /// @param cToken The address of the token that the account is borrowing.
    /// @param account The address of the account that has just borrowed.
    function notifyBorrow(address cToken, address account) external;

    /// @notice A list of all tokens inside this market for
    ///         offchain querying.
    function queryTokensListed() external view returns (address[] memory);

    /// @notice Returns whether `cToken` is listed in the lending market.
    /// @param cToken market token address.
    function isListed(address cToken) external view returns (bool);

    /// @notice The total amount of `cToken` that can be posted as collateral,
    ///         in shares.
    function collateralCaps(address cToken) external view returns (uint256);

    /// @notice The total amount of `cToken` underlying that can be borrowed,
    ///         in assets.
    function debtCaps(address cToken) external view returns (uint256);

    /// @notice Returns the assets an account has entered.
    /// @param account The address of the account to pull assets for.
    /// @return A dynamic list with the assets `account` has entered.
    function assetsOf(
        address account
    ) external view returns (address[] memory);

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
    /// @param collateralToken The address of the Curvance token to be seized
    ///                        during in the liquidation.
    /// @param debtToken The address of the Curvance token to be repaid during
    ///                  the liquidation.
    /// @return lfactor `account`'s current lFactor, an lFactor at or above 1
    ///                 indicates a soft liquidation, with a value of
    ///                 1e18 (WAD) indicating a hard liquidation.
    /// @return collateralPrice Current price for `collateralToken`.
    /// @return debtPrice Current price for `debtToken`.
    function liquidationStatusOf(
        address account,
        address collateralToken,
        address debtToken
    ) external view returns (uint256, uint256, uint256);

    /// @notice Returns whether `addressToCheck` is an approved position
    ///         manager or not.
    /// @param addressToCheck Address to check for position management
    ///                       authority.
    function isPositionManager(
        address addressToCheck
    ) external view returns (bool);

    /// @notice Determine `account`'s current collateral and debt values
    ///         in the market.
    /// @param account The account to calculate liquidation values for.
    /// @return The total market value of `account`'s collateral offset
    /// by soft liquidation requirements.
    /// @return The total market value of `account`'s collateral offset
    /// by hard liquidation requirements.
    /// @return The total outstanding debt value of `account`.
    function liquidationValuesOf(
        address account
    ) external view returns (uint256, uint256, uint256);
}
