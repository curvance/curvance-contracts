// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { LiquidityManagerIsolated } from "contracts/market/isolated/LiquidityManagerIsolated.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IVeCVE } from "contracts/interfaces/IVeCVE.sol";

contract AuxiliaryData2 {
    ICentralRegistry public immutable centralRegistry;

    struct StaticMarketAsset {
        address _address;
        string name;
        string symbol;
        uint8 decimals;
        uint256 totalSupply;
    }

    struct StaticMarketToken {
        address _address;
        StaticMarketAsset asset;
        uint256 collateralCap;
        LiquidityManagerIsolated.CurvanceToken config;
        uint256[2] adapters;
        uint256 totalSupply; // totalSupply - reserved
    }

    struct DynamicMarketToken {
        address _address;
        uint256 posted;
        uint256 sharePrice;
        uint256 tokenPrice;
        uint256 tvl;
        uint256 borrowRate;
        uint256 utilizationRate;
        uint256 supplyRate;
        uint256 predicted_supplyRate;
        uint256 liquidity;
    }

    struct DynamicMarketData {
        address _address;
        DynamicMarketToken[] tokens;
    }

    struct StaticMarketData {
        address _address;
        StaticMarketToken[] tokens;
    }

    struct UserMarketToken {
        address _address;
        bool hasPosition;
        uint256 tokenAmount;
        uint256 shareAmount;
        uint256 debt;
    }

    struct UserMarket {
        address _address;
        uint256 debt;
        uint256 collateral;
        uint256 maxDebt;
        uint256 healthFactor;
        uint256 cooldown;
        UserMarketToken[] tokens;
    }

    struct UserLock {
        uint256 lockIndex;
        uint256 amount;
        uint256 unlockTime;
    }

    struct UserData {
        UserLock[] locks;
        UserMarket[] markets;
    }

    constructor(ICentralRegistry centralRegistry_) {
        centralRegistry = centralRegistry_;
    }

    function getAllDynamicState(
        address account
    )
        public
        view
        returns (DynamicMarketData[] memory market, UserData memory user)
    {
        return (getDynamicMarketData(), getUserData(account));
    }

    function getStaticMarketData()
        public
        view
        returns (StaticMarketData[] memory data)
    {
        // address[] memory markets = centralRegistry.marketManagers();
        // getAllMarketData
    }

    function getDynamicMarketData()
        public
        view
        returns (DynamicMarketData[] memory data)
    {
        // address[] memory markets = centralRegistry.marketManagers();
        // getAllMarketData
    }

    function getUserData(
        address account
    ) public view returns (UserData memory data) {
        // Load locks
        (data.locks, ) = IVeCVE(centralRegistry.veCVE()).queryUserLocks(
            account
        );

        // getAllMarketData
        // getAccountState
        return data;
    }

    /// @notice Calculates the hypothetical maximum amount of
    ///         `borrowableCToken` assets `account` can borrow for maximum
    ///         leverage based on a new `cToken` collateralized deposit.
    /// @dev Applies a minor dampening effect to calculated maximum leverage
    ///      via `MAX_LEVERAGE`. Offsets maximum borrowable debt amount if
    ///      there is insufficient liquidity to borrow in the target market.
    /// @param account The account to query maximum borrow amount for.
    /// @param borrowableCToken The token that `account` will borrow assets
    ///                         from to achieve leverage.
    /// @param cToken The token that `account` will deposit to
    ///                        leverage against.
    /// @param assets The amount of `cToken` underlying that
    ///               `account` will deposit to leverage against.
    /// @return maxDebtBorrowable Returns the maximum remaining borrow amount
    ///                           allowed from `borrowableCToken`, measured in
    ///                           underlying token amount, after the new
    ///                           hypothetical deposit.
    /// @return isOffset Whether the maximum borrowable debt amount returned
    ///                  has been offset due to available liquidity or not.
    function hypotheticalMaxRemainingLeverageOf(
        address account,
        address borrowableCToken,
        address cToken,
        uint256 assets
    ) public view returns (uint256 maxDebtBorrowable, bool isOffset) {
        IMarketManager mm = ICToken(borrowableCToken).marketManager();
        (uint256 price, uint256 errorCode) = IOracleManager(
            ICentralRegistry(centralRegistry).oracleManager()
        ).getPrice(address(cToken), true, true);

        // Validate we got a price for `cToken`.
        if (errorCode != 0) {
            revert();
        }

        (uint256 sumCollateral, uint256 maxDebt, uint256 sumDebt) = mm
            .statusOf(account);

        {
            uint256 newCollateral = FixedPointMathLib.mulDiv(
                ICToken(cToken).previewDeposit(assets),
                price,
                10 ** ICToken(cToken).decimals()
            );

            uint256 collRatio = mm.collateralizationRatio(cToken);
            // If the collateral token cannot be borrowed against the hypothetical
            // leverage check will result in 0 meaning nothing new to leverage
            // against.
            if (collRatio == 0) {
                revert();
            }

            sumCollateral += newCollateral;
            maxDebt += FixedPointMathLib.mulDiv(newCollateral, collRatio, WAD);
        }

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
        uint256 maxLeverage = FixedPointMathLib.mulDiv(
            maxDebt - sumDebt,
            sumCollateral * MAX_LEVERAGE,
            sumCollateral - maxDebt
        ) / WAD;

        (price, errorCode) = IOracleManager(
            ICentralRegistry(centralRegistry).oracleManager()
        ).getPrice(address(borrowableCToken), true, false);

        // Validate we got a price for `borrowableCToken`.
        if (errorCode != 0) {
            revert();
        }

        maxDebtBorrowable = FixedPointMathLib.mulDiv(
            FixedPointMathLib.mulDiv(maxLeverage, WAD, price),
            10 ** IERC20(borrowableCToken).decimals(),
            WAD
        );

        uint256 liquidityAvailable = IERC20(ICToken(borrowableCToken).asset())
            .balanceOf(borrowableCToken);

        if (liquidityAvailable < maxDebtBorrowable) {
            maxDebtBorrowable = liquidityAvailable;
            isOffset = true;
        }
    }
}
