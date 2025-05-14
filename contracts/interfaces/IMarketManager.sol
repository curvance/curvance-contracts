// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IMToken } from "contracts/interfaces/IMToken.sol";

interface IMarketManager {
    /// TYPES ///

    struct LiqInstructions {
        address eToken;
        address pToken;
        uint256 numAccounts;
        bool liquidateExact;
        uint256 eTokenRepaid;
        uint256 pTokenLiquidated;
        uint256 badDebt;
    }

    struct LiqResults {
        uint256[] liquidatedAmounts;
        uint256 debtRepaid;
        uint256 badDebtRealized;
    }

    /// @notice Whether mToken minting is paused.
    /// @dev Token => 0 or 1 = unpaused; 2 = paused.
    function mintPaused(address mToken) external view returns (uint256);

    /// @notice Post collateral for `mToken` inside this market.
    /// @param account The account posting collateral.
    /// @param mToken The address of the mToken to post collateral for.
    /// @param tokens The amount of `mToken` to post as collateral, in shares.
    function postCollateral(
        address account,
        address mToken,
        uint256 tokens
    ) external;

    /// @notice Checks if the account should be allowed to mint tokens
    ///         in the given market.
    /// @param mToken The token to verify mints against.
    function canMint(address mToken) external;

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
    /// @param balance The current mTokens balance of `account`.
    /// @param amount The number of mTokens to exchange
    ///               for the underlying asset in the market.
    /// @param forceRedeemCollateral Whether the collateral should be always
    ///                              reduced.
    function canRedeemWithCollateralRemoval(
        address mToken,
        address account,
        uint256 balance,
        uint256 amount,
        bool forceRedeemCollateral
    ) external;

    /// @notice Checks if the account should be allowed to borrow
    ///         the underlying asset of the given market.
    /// @dev May emit a {TokenPositionCreated} event.
    /// @param eToken The debt token to verify the borrow of.
    /// @param account The account which would borrow the asset.
    /// @param amount The amount of underlying the account would borrow.
    function canBorrowWithPrune(
        address eToken,
        address account,
        uint256 amount
    ) external;

    /// @notice Checks if the account should be allowed to borrow
    ///         the underlying asset of the given market,
    ///         and notifies the market of the borrow.
    /// @dev This can only be called by the market itself.
    /// @param mToken The market to verify the borrow against.
    /// @param account The account which would borrow the asset.
    /// @param amount The amount of underlying the account would borrow.
    function canBorrowWithNotify(
        address mToken,
        address account,
        uint256 amount
    ) external;

    /// @notice Checks if the account should be allowed to repay a borrow
    ///         in the given market.
    /// @param mToken The market to verify the repay against.
    /// @param account The account who will have their loan repaid.
    function canRepay(address mToken, address account) external;

    /// @notice Checks if the liquidation should be allowed to occur
    function canLiquidateWithExecution(
        address liquidator,
        address[] calldata accounts,
        uint256[] memory debtAmounts,
        IMarketManager.LiqInstructions memory liqInstructions
    ) external returns (LiqResults memory, uint256[] memory);

    /// @notice Checks if the seizing of assets should be allowed to occur.
    /// @param pToken Asset which was used as collateral and will be seized.
    /// @param earnToken Asset which was borrowed by the account.
    function canSeize(address pToken, address earnToken) external;

    /// @notice Checks if the account should be allowed to transfer debt
    ///         tokens in the given market.
    /// @param mToken The market to verify the transfer against.
    /// @param from The account which sources the tokens.
    /// @param amount The number of mTokens to transfer.
    function canTransferEToken(
        address mToken,
        address from,
        uint256 amount
    ) external;

    /// @notice Checks if the account should be allowed to transfer collateral
    ///         tokens in the given market.
    /// @param mToken The market token to verify the transfer of.
    /// @param from The account which sources the tokens.
    /// @param amount The number of mTokens to transfer.
    function canTransferPToken(
        address mToken,
        address from,
        uint256 amount
    ) external;

    /// @notice Updates `account` cooldownTimestamp to the current block timestamp.
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

    /// @notice Market token data including listing status,
    ///         token characterists, account position data.
    /// @dev Market Token Address => MarketToken struct.
    function tokenData(address mToken) external view returns (
        bool isListed,
        uint256 collRatio,
        uint256 collReqSoft,
        uint256 collReqHard,
        uint256 liqBaseIncentive,
        uint256 liqCurve,
        uint256 liqMinIncentive,
        uint256 liqMaxIncentive,
        uint256 minEffectiveCloseFactor,
        uint256 maxEffectiveCloseFactor,
        uint256 baseCFactor,
        uint256 cFactorCurve
    );

    /// @notice Amount of pToken that has been posted as collateral,
    ///         in shares.
    function collateralPosted(address pToken) external view returns (uint256);

    /// @notice Amount of pToken that can be posted of collateral,
    ///         in shares.
    function collateralCaps(address pToken) external view returns (uint256);

    /// @notice Returns the assets an account has entered.
    /// @param account The address of the account to pull assets for.
    /// @return A dynamic list with the assets the account has entered.
    function assetsOf(
        address account
    ) external view returns (IMToken[] memory);

    /// @notice Returns if an account has an active position in `mToken`.
    /// @param account The address of the account to check a position of.
    /// @param mToken The address of the market token.
    function tokenDataOf(
        address account,
        address mToken
    ) external view returns (bool, uint256, uint256);

    /// @notice Determine `account`'s current status between collateral,
    ///         debt, and additional liquidity.
    /// @param account The account to determine liquidity for.
    /// @return accountCollateral total collateral amount of account.
    /// @return maxDebt max borrow amount of account.
    /// @return accountDebt total borrow amount of account.
    function statusOf(
        address account
    ) external view returns (uint256, uint256, uint256);

    /// @notice Determine whether `account` can be liquidated,
    ///         by calculating their lFactor, based on their
    ///         collateral versus outstanding debt.
    /// @param account The account to check liquidation status for.
    /// @param eToken The eToken to be repaid during potential liquidation.
    /// @param pToken The pToken to be seized during potential
    ///                        liquidation.
    /// @return lfactor `account`'s current lFactor, an lFactor at or above 1
    ///                 indicates a soft liquidation, with a value of
    ///                 1e18 (WAD) indicating a hard liquidation.
    /// @return earnTokenPrice Current price for `earnToken`.
    /// @return positionTokenPrice Current price for `positionToken`.
    function liquidationStatusOf(
        address account,
        address eToken,
        address pToken
    ) external view returns (uint256, uint256, uint256);

    /// @notice Returns whether `positionContract` is an approved position
    ///         management operator or not.
    /// @param positionContract Address to check for position management
    ///                         authority.
    function positionManagement(
        address positionContract
    ) external view returns (bool);

    /// @notice Locks Atlas OEV liquidations
    /// @dev This function must be called by an authorized Atlas DApp Control
    function lockAtlasOev() external;

    /// @notice Unlocks Atlas OEV liquidations
    /// @dev This function must be called by an authorized Atlas DApp Control
    function unlockAtlasOev() external;
}
