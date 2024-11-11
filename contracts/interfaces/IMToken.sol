// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { IInterestRateModel } from "contracts/interfaces/IInterestRateModel.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { Multicall } from "contracts/libraries/Multicall.sol";

struct AccountSnapshot {
    address asset;
    bool isPToken;
    uint8 decimals;
    uint256 debtBalance;
    uint256 exchangeRate;
}

interface IMToken {
    /// @notice Starts a mToken market, executed via marketManager.
    /// @dev This initial mint is a failsafe against rounding exploits,
    ///      although, we protect against them in many ways,
    ///      better safe than sorry.
    /// @param by The account initializing the market.
    function startMarket(address by) external returns (bool);

    /// @notice Address of the current Interest Rate Model.
    function interestRateModel() external view returns (IInterestRateModel);

    /// @notice Applies pending interest to all holders, updating
    ///         `totalBorrows` and `totalReserves`.
    /// @dev This calculates interest accrued from the last checkpoint
    ///      up to the latest available checkpoint, if `compoundRate`
    ///      seconds has passed.
    ///      Emits a {InterestAccrued} event.
    function accrueInterest() external;

    /// @notice Updates pending interest and returns the up-to-date exchange
    ///         rate from the underlying to the eToken.
    /// @return Calculated exchange rate, in `WAD`.
    function exchangeRateWithUpdate() external returns (uint256);

    /// @notice Returns the address of the underlying asset.
    function underlying() external view returns (address);

    /// @notice Returns the decimals of the mToken.
    /// @dev We pull directly from underlying incase its a proxy contract,
    ///      and changes decimals on us.
    /// @return The number of decimals for this mToken,
    ///         matching the underlying token.
    function decimals() external view returns (uint8);

    /// @notice Returns the type of Curvance token.
    /// @dev true = Collateral token; false = Debt token.
    /// @return Whether this token is a pToken or not.
    function isPToken() external view returns (bool);

    /// @notice The eToken balance of an account.
    /// @dev Account address => account token balance.
    /// @param user User to query eToken balance for.
    function balanceOf(address user) external view returns (uint256);

    /// @notice Caller deposits assets into the market and receives shares.
    /// @param assets The amount of the underlying assets to deposit.
    /// @param receiver The account that should receive the pToken shares.
    /// @return shares The amount of pToken shares received by `receiver`.
    function deposit(
        uint256 assets,
        address receiver
    ) external returns (uint256 shares);

    /// @notice Caller deposits assets into the market, `receivier` receives
    ///         shares, and turns on collateralization of the assets.
    /// @dev Requires that `receiver` approves the caller prior to
    ///      collateralize on their behalf.
    ///      NOTE: Be careful who you approve here!
    ///      They can delay redemption of assets through repeated
    ///      collateralization preventing withdrawal.
    ///      If the caller is not approved to collateralize the function will
    ///      simply deposit assets on behalf of `receiver`.
    /// @param assets The amount of the underlying assets to deposit.
    /// @param receiver The account that should receive the pToken shares.
    /// @return shares The amount of pToken shares received by `receiver`.
    function depositAsCollateralFor(
        uint256 assets,
        address receiver
    ) external returns (uint256 shares);

    /// @notice Deposits underlying assets into the market,
    ///         and receives eTokens.
    /// @dev Updates pending interest before executing the mint inside
    ///      the internal helper function.
    /// @param amount The amount of the underlying assets to deposit.
    /// @return Returns the amount of eTokens minted.
    function mint(uint256 amount) external returns (uint256);

    /// @notice Deposits underlying assets into the market,
    ///         and `recipient` receives eTokens.
    /// @dev Updates pending interest before executing the mint inside
    ///      the internal helper function.
    /// @param amount The amount of the underlying assets to deposit.
    /// @param recipient The account that should receive the eTokens.
    /// @return tokens Returns the amount of eTokens minted.
    function mintFor(
        uint256 amount,
        address recipient
    ) external returns (uint256);

    /// @notice Redeems eTokens in exchange for the underlying asset.
    /// @dev Updates pending interest before executing the redemption.
    /// @param tokens The number of eTokens to redeem for underlying tokens.
    /// @return Returns amount of underlying asset redeemed.
    function redeem(uint256 tokens) external returns (uint256);

    /// @notice Transfers collateral tokens (this pToken) from `account`
    ///         to `liquidator`.
    /// @dev Will fail unless called by a eToken during the process
    ///      of liquidation.
    /// @param liquidator The account receiving seized collateral.
    /// @param account The account having collateral seized.
    /// @param liquidatedTokens The total number of pTokens to seize.
    /// @param protocolTokens The number of pTokens to seize for the protocol.
    function seize(
        address liquidator,
        address account,
        uint256 liquidatedTokens,
        uint256 protocolTokens
    ) external;

    /// @notice Used by the market manager contract to repay a portion
    ///         of underlying token debt to lenders, remaining debt shortfall
    ///        is recognized equally by lenders due to `account` default.
    /// @dev Only market manager contract can call this function.
    ///      Updates pending interest prior to execution of the repay,
    ///      inside the market manager contract.
    /// @param liquidator The account liquidating `account`'s collateral,
    ///                   and repaying a portion of `account`'s debt.
    /// @param account The account being liquidated and repaid on behalf of.
    /// @param repayRatio The ratio of outstanding debt that `liquidator`
    ///                   will repay from `account`'s obligations,
    ///                   out of 100%, in `WAD`.
    function repayWithBadDebt(
        address liquidator,
        address account,
        uint256 repayRatio
    ) external;

    /// @notice Transfers collateral tokens (this market) to the liquidator.
    /// @dev Will fail unless called by the MarketManager itself during
    ///      the process of liquidation.
    ///      NOTE: The protocol never takes a fee on account liquidation
    ///            as lenders already are bearing a burden.
    /// @param liquidator The account receiving seized collateral.
    /// @param account The account having collateral seized.
    /// @param shares The total number of pTokens shares to seize.
    function seizeAccountLiquidation(
        address liquidator,
        address account,
        uint256 shares
    ) external;

    /// @notice Withdraws all reserves from the gauge and transfers them to
    ///         Curvance DAO.
    /// @dev If daoAddress is going to be moved all reserves should be
    ///      withdrawn first. Updates pending interest before executing
    ///      the reserve withdrawal.
    function processWithdrawReserves() external;

    /// @notice Get a snapshot of the account's balances,
    ///         and the cached exchange rate.
    /// @dev Used by MarketManager to efficiently perform liquidity checks.
    /// @param account Address of the account to snapshot.
    /// @return Current account shares balance.
    /// @return Current account borrow balance, which will be 0,
    ///         kept for composability.
    /// @return Current exchange rate between assets and shares, in `WAD`.
    function getSnapshot(
        address account
    ) external view returns (uint256, uint256, uint256);

    /// @notice Returns a snapshot of the pToken and `account` data.
    /// @dev Used by MarketManager to efficiently perform liquidity checks.
    /// NOTE: debtBalance always return 0 to runtime gas in MarketManager
    ///       since it is unused.
    /// @return Snapshot struct containing packed information.
    function getSnapshotPacked(
        address account
    ) external view returns (AccountSnapshot memory);

    /// @notice Total number of mTokens in circulation.
    function totalSupply() external view returns (uint256);

    /// @notice Returns total amount of outstanding borrows of the
    ///         underlying in this eToken market.
    function totalBorrows() external view returns (uint256);

    /// @notice Returns the current debt balance for `account`.
    /// @dev Note: Pending interest is not applied in this calculation.
    /// @param account The address whose balance should be calculated.
    /// @return The current balance index of `account`.
    function debtBalanceCached(
        address account
    ) external view returns (uint256);

    /// @notice Calculates the current eToken utilization rate.
    /// @dev Used for third party integrations, and frontends.
    /// @return The utilization rate, in `WAD`.
    function utilizationRate() external view returns (uint256);

    /// @notice Returns the current eToken borrow interest rate per year.
    /// @dev Used for third party integrations, and frontends.
    /// @return The borrow interest rate per year, in `WAD`.
    function borrowRatePerYear() external view returns (uint256);

    /// @notice Returns predicted upcoming eToken borrow interest rate
    ///         per year.
    /// @dev Used for third party integrations, and frontends.
    /// @return The predicted borrow interest rate per year, in `WAD`.
    function predictedBorrowRatePerYear() external view returns (uint256);

    /// @notice Returns the current eToken supply interest rate per year.
    /// @dev Used for third party integrations, and frontends.
    /// @return The supply interest rate per year, in `WAD`.
    function supplyRatePerYear() external view returns (uint256);

    /// @notice Address of the Market Manager linked to this contract.
    function marketManager() external view returns (IMarketManager);

    /// @notice Returns share -> asset exchange rate, in `WAD`.
    /// @dev Oracle Manager calculates mToken value from this exchange rate.
    function exchangeRateCached() external view returns (uint256);

    /// @notice Executes multiple calls in a single transaction.
    ///         This can be used to update oracle prices before
    ///         a liquidity dependent action.
    function multicall(
        Multicall.MulticallData[] memory calls
    ) external returns (bytes[] memory results);
}
