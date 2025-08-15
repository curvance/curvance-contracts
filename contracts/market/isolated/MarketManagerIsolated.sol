// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;
import { LiquidityManagerIsolated, CommonLib, ICToken, IOracleManager } from "contracts/market/isolated/LiquidityManagerIsolated.sol";
import { Multicall } from "contracts/libraries/Multicall.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { BPS, BPS_SQUARED, WAD, WAD_SQUARED, WAD_CUBED_BPS_OFFSET } from "contracts/libraries/ConstantsLib.sol";
import { ERC165 } from "contracts/libraries/external/ERC165.sol";
import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { IPositionManager } from "contracts/interfaces/IPositionManager.sol";
import { IActionRegistry } from "contracts/interfaces/IActionRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

/// @title Curvance DAO Market Manager.
/// @notice Manages risk within the Curvance DAO markets.
/// @dev Curvance Market Managers are built as "thesis driven" micro
///      ecosystems. This means that a market may be focused specifically
///      on interest-bearing stablecoins, or bluechip long market exposure,
///      volatile LP tokens for a particular dex or perpetual platform. This
///      minimizes systemic risk by having many market managers with unique
///      opportunities and risk profiles.
///
///      All management of token actions are managed by the Market Manager.
///      These tokens are collectively referred to as Curvance tokens,
///      or cTokens. Each market has a maximum number of supportable assets
///      this is to minimize systemic risk and gas costs on liquidity checks.
///
///      Curvance offers the ability to store unlimited tokens inside Curvance
///      token contracts while restricting the scale of exogenous risk.
///      Every collateral asset has a "Collateral Cap", measured in shares.
///      As collateral is posted, the `collateralPosted` invariant increases,
///      and is compared to `collateralCaps`. By measuring collateral posted
///      in shares, this allows collateral caps to grow proportionally with
///      any auto compounding mechanism strategy attached to the token.
///
///      It is important to note that, in theory, collateral caps can be
///      decreased below current market collateral posted levels. This would
///      restrict the addition of new exogenous risk being added to the
///      system, but will not result in forced unwinding of user positions.
///
///      Curvance also employs a 20-minute minimum duration of posting of
///      collateral and borrowing of tokens. This restriction improves
///      the security model of Curvance and allows for more advanced
///      interest rate methodology.
///
///      Additionally, a new "Dynamic Liquidation Engine" or DLE
///      allows for more nuanced position management inside the system.
///      The DLE facilitates aggressive asset support and elevated
///      collateralization ratios paired with reduced minimum liquidation
///      penalties. In periods of low volatility, users will experience soft
///      liquidations. But, when volatility is elevated, users may experience
///      more aggressive or complete liquidation of positions.
///
///      Bad debt is minimized via a "Bad Debt Socialization" system.
///      When a user's debt is greater than their collateral assets,
///      the entire user's account can be liquidated with lenders paying any
///      collateral shortfall.
///
contract MarketManagerIsolated is
    LiquidityManagerIsolated,
    IMarketManager,
    ERC165,
    Multicall
{
    /// TYPES ///

    struct TokenConfig {
        address cToken;
        uint256 collRatio;
        uint256 collReqSoft;
        uint256 collReqHard;
        uint256 liqIncBase;
        uint256 liqIncHard;
        uint256 liqIncMin;
        uint256 liqIncMax;
        uint256 closeFactorBase;
        uint256 closeFactorMin;
        uint256 closeFactorMax;
        uint256 collateralCap;
        uint256 debtCap;
    }

    /// CONSTANTS ///

    /// @notice Maximum collateral requirement to avoid liquidation.
    /// @dev 23400 = 234%. Resulting in 1 / (BPS + 2.34 BPS),
    ///      or ~30% maximum LTV soft liquidation level.
    uint256 public constant MAX_COLLATERAL_REQUIREMENT = 23400;
    /// @notice Minimum excess collateral requirement
    ///         on top of liquidation incentive.
    /// @dev 100 = 1.0%.
    uint256 public constant MIN_EXCESS_COLL_REQUIRED = 100;
    /// @notice Maximum collateralization ratio.
    /// @dev 9750 = 97.5%.
    uint256 public constant MAX_COLLATERALIZATION_RATIO = 9750;
    /// @notice The maximum liquidation incentive.
    /// @dev 3000 = 30%.
    uint256 public constant MAX_LIQUIDATION_INCENTIVE = 3000;
    /// @notice Buffer to ensure orderflow auction-based liquidations have
    ///         priority versus basic liquidations.
    /// @dev 9999 = 99.9%. Multiplied then divided by `BPS` = 10 bps buffer.
    uint256 public constant AUCTION_BUFFER = 9999;
    /// @notice The maximum base cFactor.
    /// @dev 5000 = 50%. NOTE: This can NEVER be changed to 100% or offchain
    ///      parameters can be unintentionally ignored.
    uint256 public constant MAX_BASE_CFACTOR = 5000;
    /// @notice The minimum base cFactor.
    /// @dev 1000 = 10%.
    uint256 public constant MIN_BASE_CFACTOR = 1000;
    /// @notice Minimum hold time to minimize external risks, in seconds.
    /// @dev 20 minutes = 1,200 seconds.
    uint256 public constant MIN_HOLD_PERIOD = 20 minutes;

    /// @dev Limit for market debt cap to max sure outstanding user debt
    ///      never overflows `outstandingDebt` value inside _debtOf.
    uint256 internal constant _MAX_DEBT_CAP = type(uint168).max;
    /// @dev `bytes4(keccak256(bytes("MarketManager__InvalidParameter()")))`
    uint256 internal constant _INVALID_PARAMETER_SELECTOR = 0x65513fc1;
    /// @dev `bytes4(keccak256(bytes("MarketManager__Unauthorized()")))`
    uint256 internal constant _UNAUTHORIZED_SELECTOR = 0x37cf6ad5;
    /// @dev `bytes4(keccak256(bytes("MarketManager__InvariantError()")))`
    uint256 internal constant _INVARIANT_ERROR_SELECTOR = 0x5518d5cb;
    /// @dev A fixed key to use in transient storage for the dynamic penalty.
    bytes32 internal constant _TRANSIENT_INCENTIVE_KEY
        = 0xd033e44c9f2a65a460c9f878712895054941eb772c7716e6dee8b66c21be9561;
    /// @dev A fixed key to use in transient storage for dynamic close factor.
    bytes32 internal constant _TRANSIENT_CLOSE_FACTOR_KEY
        = 0x2345678901234567890123456789012345678901234567890123456789012345;
    /// @dev A fixed key to use in transient storage for enforcing a single
    ///      collateral which can be liquidated during Auction tx.
    bytes32 internal constant _TRANSIENT_COLLATERAL_UNLOCKED_KEY
        = 0x3456789012345678901234567890123456789012345678901234567890123456;

    /// STORAGE ///

    /// @notice A list of all tokens inside this market for
    ///         offchain querying.
    address[] public tokensListed;

    /// MARKET STATE

    /// @notice Whether liquidations are paused.
    /// @dev 1 = unpaused; 2 = paused.
    uint8 public liquidationPaused = 1;
    /// @notice Whether token transfers are paused.
    /// @dev 1 = unpaused; 2 = paused.
    uint8 public transferPaused = 1;
    /// @notice Whether token liquidations are paused.
    /// @dev 1 = unpaused; 2 = paused.
    uint8 public seizePaused = 1;
    /// @notice Whether token redemptions are paused.
    /// @dev 1 = unpaused; 2 = paused.
    uint8 public redeemPaused = 1;

    /// @notice The total amount of `cToken` that can be posted as collateral,
    ///         in shares.
    /// @dev Token Address => Market-wide Collateral Cap, in shares.
    mapping(address => uint256) public collateralCaps;
    /// @notice The total amount of `cToken` underlying that can be borrowed,
    ///         in assets.
    /// @dev Token Address => Market-wide Debt Cap, in assets.
    mapping(address => uint256) public debtCaps;

    /// @notice Whether an address is an authorized position manager or not.
    /// @dev Address => Is an approved position management operator.
    mapping(address => bool) public isPositionManager;

    /// EVENTS ///

    event PositionUpdated(address cToken, address account, bool open);
    event TokenListed(address cToken);
    event TokenConfigUpdated(TokenConfig config);
    event PositionManagerUpdated(address positionManager, bool addPerms);
    event ActionPaused(string action, bool pauseState);
    event TokenActionPaused(address cToken, string action, bool pauseState);

    /// ERRORS ///

    error MarketManager__Unauthorized();
    error MarketManager__UnauthorizedLiquidation();
    error MarketManager__TokenNotListed();
    error MarketManager__Paused();
    error MarketManager__InsufficientCollateral();
    error MarketManager__NoLiquidationAvailable();
    error MarketManager__PriceError();
    error MarketManager__CapReached();
    error MarketManager__MarketManagerMismatch();
    error MarketManager__InvalidParameter();
    error MarketManager__MinimumHoldPeriod();
    error MarketManager__InvariantError();
    
    /// CONSTRUCTOR ///

    constructor(ICentralRegistry cr) LiquidityManagerIsolated(cr) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Returns whether `cToken` is listed in the lending market.
    /// @param cToken The address of a token to check for listing status.
    /// @return result Whether `cToken` is listed inside this lending market
    ///                or not.
    function isListed(address cToken) external view returns (bool result) {
        result = _tokenConfig[cToken].isListed;
    }

    /// @notice Returns whether minting, collateralization, borrowing of
    ///         `cToken` is disabled.
    /// @param cToken The address of the Curvance token to return
    ///               action statuses of.
    /// @return mintPaused Whether minting `cToken` is paused or not.
    /// @return collateralizationPaused Whether collateralization `cToken`
    ///                                 is paused or not.
    /// @return borrowPaused Whether borrowing `cToken` is paused or not.
    function actionsPaused(address cToken) external view returns (
        bool mintPaused,
        bool collateralizationPaused,
        bool borrowPaused
    ) {
        CurvanceToken storage c = _tokenConfig[cToken];
        mintPaused = c.mintPaused == 2;
        collateralizationPaused = c.collateralizationPaused == 2;
        borrowPaused = c.borrowPaused == 2;
    }

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
    ) {
        CurvanceToken storage c = _tokenConfig[cToken];
        return (c.collRatio, c.collReqSoft, c.collReqHard);
    }

    /// @notice Returns the current liquidation configuration
    ///         of `cToken`.
    /// @param cToken The address of the Curvance token to return
    ///               liquidation configuration of.
    /// @return The base ratio at which this token will be
    ///         compensated on soft liquidation.
    /// @return The liquidation incentive curve length between soft
    ///         liquidation to hard liquidation, in `BPS`. e.g. 5% base
    ///         incentive with 8% curve length results in 13% liquidation
    ///         incentive on hard liquidation.
    /// @return The minimum possible liquidation incentive for during an
    ///         auction, in `BPS`.
    /// @return The maximum possible liquidation incentive for during an
    ///         auction, in `BPS`.
    /// @return Maximum % that a liquidator can repay when soft
    ///         liquidating an account, in `BPS`.
    /// @return Curve length between soft liquidation and hard liquidation,
    ///         should be equal to 100% - `closeFactorBase`, in `BPS`.
    /// @return The minimum possible close factor for during an auction,
    ///         in `BPS`.
    /// @return The maximum possible close factor for during an auction,
    ///         in `BPS`.
    function liquidationConfig(address cToken) external view returns (
        uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256
    ) {
        CurvanceToken storage c = _tokenConfig[cToken];
        return (
            c.liqIncBase,
            c.liqIncCurve,
            c.liqIncMin,
            c.liqIncMax,
            c.closeFactorBase,
            c.closeFactorCurve,
            c.closeFactorMin,
            c.closeFactorMax
        );
    }

    /// @notice Helper function for querying the current Curvance tokens listed
    ///         inside this market.
    /// @return r Array containing list of all Curvance token addresses
    ///           listed in this market.
    function queryTokensListed() external view returns (address[] memory r) {
        r = tokensListed;
    }

    /// ACCOUNT SPECIFIC FUNCTIONS ///

    /// @notice Returns the assets `account` has an open position in.
    /// @param account The address of the account to pull assets for.
    /// @return result An array containing the assets `account` has
    ///                positions in.
    function assetsOf(
        address account
    ) external view returns (address[] memory result) {
        result = accountAssets[account].assets;
    }

    /// @notice Determine `account`'s current status between collateral,
    ///         debt, and additional liquidity.
    /// @param account The account to determine liquidity for.
    /// @return The current total collateral amount of `account`.
    /// @return The maximum debt amount of `account` can take out with
    ///         their current collateral.
    /// @return The current total borrow amount of `account`.
    function statusOf(
        address account
    ) external view returns (uint256, uint256, uint256) {
        return _statusOf(account);
    }

    /// @notice Determine `account`'s current collateral and debt values
    ///         in the market.
    /// @param account The account to calculate liquidation values for.
    /// @return The total market value of `account`'s collateral offset
    ///         by soft liquidation requirements.
    /// @return The total market value of `account`'s collateral offset
    ///         by hard liquidation requirements.
    /// @return The total outstanding debt value of `account`.
    function liquidationValuesOf(
        address account
    ) external view returns (uint256, uint256, uint256) {
        (AccountLiqResult memory result, , , )
            = _liquidationValuesOf(account, address(0), address(0));
        return (result.cSoft, result.cHard, result.debt);
    }

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
    ) public view returns (
        uint256 lfactor,
        uint256 collateralPrice,
        uint256 debtPrice
    ) {
        (, lfactor, collateralPrice, debtPrice) =
            _liquidationValuesOf(account, collateralToken, debtToken);
    }

    /// @notice Determine what the account liquidity would be if
    ///         the given amounts were redeemed/borrowed.
    /// @dev Will natively revert if a hypothetical borrow will result in a
    ///      loan less than `MIN_ACTIVE_LOAN_SIZE`, set in `LiquidityManager`.
    /// @param account The account to determine liquidity for.
    /// @param cTokenModified The token to hypothetically redeem/borrow.
    /// @param redemptionShares The number of shares to hypothetically redeem.
    /// @param borrowAssets The amount of underlying assets to hypothetically
    ///                     borrow.
    /// @return Hypothetical account liquidity in excess of collateral
    ///         requirements.
    /// @return Hypothetical account liquidity deficit below collateral
    ///         requirements.
    function hypotheticalLiquidityOf(
        address account,
        address cTokenModified,
        uint256 redemptionShares, // in Shares.
        uint256 borrowAssets // in Assets.
    ) external view returns (uint256, uint256, bool[] memory) {
        // Make sure they are not trying to hypothetically borrow
        // a token they are collateralizing.
        if (
            ICToken(cTokenModified).collateralPosted(account) > 0 &&
            borrowAssets > 0
            ) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        (HypotheticalResult memory r, bool[] memory positionsToClose) =
            _hypotheticalLiquidityOf(
                account,
                HypotheticalAction({
                    cTokenModified: cTokenModified,
                    redemptionShares: redemptionShares,
                    borrowAssets: borrowAssets,
                    errorCodeBreakpoint: 2
                })
            );
        return (r.collateralSurplus, r.liquidityDeficit, positionsToClose);
    }

    /// @notice Checks if the account should be allowed to mint tokens
    ///         in the given market.
    /// @param cToken The Curvance token to verify mintability of.
    function canMint(address cToken) external view virtual {
        if (_tokenConfig[cToken].mintPaused == 2) {
            revert MarketManager__Paused();
        }

        _checkIsListedToken(cToken);
    }

    /// @notice Checks if the account should be allowed to collateralize
    ///         their shares of the given market.
    ///         Prunes unused positions in `account` data.
    /// @dev May emit a {PositionUpdated} event.
    /// @param collateralToken The token to verify collateralization of.
    /// @param account The account which would collateralize the asset.
    /// @param newNetCollateral The amount of shares that would be
    ///                         collateralized in total if allowed.
    function canCollateralize(
        address collateralToken,
        address account,
        uint256 newNetCollateral
    ) external {
        _checkIsToken(collateralToken);
        // Can skip token listing check since collateralCaps[collateralToken]
        // can only be set above 0 if `debtToken` is listed already, so we
        // only need to check that `newNetCollateral` != 0 instead, which
        // should be impossible but only costs 2 gas.

        /// @solidity memory-safe-assembly
        assembly {
            if iszero(newNetCollateral) {
                mstore(0x00, _INVARIANT_ERROR_SELECTOR)
                // Return bytes 29-32 for the selector.
                revert(0x1c, 0x04)
            }
        }

        if (_tokenConfig[collateralToken].collateralizationPaused == 2) {
            revert MarketManager__Paused();
        }

        // This also acts as a check that collateralization ratio is > 0,
        // since collateralCaps can only be raised above zero if the
        // its collateralization ratio is > 0.
        if (newNetCollateral > collateralCaps[collateralToken]) {
            revert MarketManager__CapReached();
        }

        // On collateral posting:
        // We need to flip their cooldown flag to prevent flashloan attacks.
        accountAssets[account].cooldownTimestamp = block.timestamp;
        // If `account` does not have a position in `collateralToken`,
        // open one.
        if (accountPositions[collateralToken][account] != 2) {
            accountPositions[collateralToken][account] = 2;
            accountAssets[account].assets.push(collateralToken);

            emit PositionUpdated(collateralToken, account, true);
        }
    }

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
    ) external returns (uint256) {
        _checkIsToken(cToken);
        return _canRedeemWithCollateralRemoval(
            cToken,
            shares,
            account,
            balanceOf,
            collateralPosted,
            true,
            forceRedeemCollateral
        );
    }

    /// @notice Checks if the account should be allowed to redeem `shares`
    ///         of `cToken` in the given market state.
    /// @param cToken The Curvance token to verify the redemption for.
    /// @param shares The number of cTokens to exchange
    ///               for the underlying asset in the market.
    /// @param account The account which would redeem `shares`.
    function canRedeem(
        address cToken,
        uint256 shares,
        address account
    ) external view {
        _canRedeem(cToken, shares, account);
    }

    /// @notice Checks if the account should be allowed to borrow
    ///         the underlying asset of the given market.
    ///         Prunes unused positions in `account` data.
    /// @dev May emit a {PositionUpdated} event.
    /// @param cToken The token to verify borrowability of.
    /// @param assets The amount of underlying the account would borrow.
    /// @param account The account which would borrow the asset.
    /// @param newNetDebt The amount of assets that would be
    ///                   outstanding debt in total if allowed.
    function canBorrow(
        address cToken,
        uint256 assets,
        address account,
        uint256 newNetDebt
    ) external {
        _canBorrow(cToken, assets, account, newNetDebt);
    }

    /// @notice Checks if the account should be allowed to borrow
    ///         the underlying asset of the given market,
    ///         and notifies the market of the borrow.
    /// @dev This can only be called by the market itself.
    /// @param cToken The token to verify borrowability of.
    /// @param assets The amount of underlying the account would borrow.
    /// @param account The account which would borrow the asset.
    /// @param newNetDebt The amount of assets that would be
    ///                   outstanding debt in total if allowed.
    function canBorrowWithNotify(
        address cToken,
        uint256 assets,
        address account,
        uint256 newNetDebt
    ) external {
        accountAssets[account].cooldownTimestamp = block.timestamp;
        _canBorrow(cToken, assets, account, newNetDebt);
    }

    /// @notice Updates `account` cooldownTimestamp to the current block
    ///         timestamp.
    /// @dev The caller must be a listed cToken in the `markets` mapping.
    /// @param cToken The address of the cToken that the account is borrowing.
    /// @param account The address of the account that has just borrowed.
    function notifyBorrow(address cToken, address account) external {
        _checkIsToken(cToken);
        _checkIsListedToken(cToken);

        accountAssets[account].cooldownTimestamp = block.timestamp;
    }

    /// @notice Checks if the account should be allowed to repay a borrow
    ///         in the given market.
    /// @param cToken The Curvance token to verify the repayment of.
    /// @param account The account who will have their loan repaid.
    function canRepay(address cToken, address account) external view {
        _checkIsListedToken(cToken);
        _checkHoldPeriod(account);
    }

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
    /// @param action Instructions for a liquidation action containing:
    ///               collateralToken The token which is used as collateral
    ///                               by `account` and may be seized.
    ///               debtToken The token to potentially repay which has 
    ///                         outstanding debt by `account`.
    ///               numAccounts The number of accounts to be, potentially,
    ///                           liquidated.
    ///               liquidateExact Whether the liquidator desires a
    ///                              specific liquidation amount.
    ///               liquidatedShares Empty variable slot to store how much
    ///                                `collateralToken` will be seized as
    ///                                part of a particular liquidation.
    ///               debtRepaid Empty variable slot to store how much
    ///                          `debtToken` will be repaid as part of a
    ///                          particular liquidation.
    ///               badDebt Empty variable slot to store how much bad debt
    ///                       will be realized as part of a particular
    ///                       liquidation.
    /// @return result Hypothetical results for an action containing:
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
    ) external view virtual returns (
        IMarketManager.LiqResult memory result,
        uint256[] memory
    ) {
        if (liquidationPaused == 2) {
            revert MarketManager__Paused();
        }

        _checkIsListedToken(action.collateralToken);
        _checkIsListedToken(action.debtToken);

        (TokenLiqData memory tData, AccountLiqData memory aData) =
            _getLiquidationConfig(action.collateralToken, action.debtToken);

        address cachedAccount;
        // Amounts array is empty since the max amount possible
        // will be liquidated.
        result.liquidatedShares = new uint256[](action.numAccounts);
        for (uint256 i; i < action.numAccounts; ++i) {
            cachedAccount = accounts[i];
            
            // Do not let an account liquidate themselves.
            if (liquidator == cachedAccount) {
                _revert(_UNAUTHORIZED_SELECTOR);
            }

            (
                action.liquidatedShares,
                action.debtRepaid,
                action.badDebt
            ) = _canLiquidate(
                debtAmounts[i],
                cachedAccount,
                tData,
                aData,
                action.liquidateExact
            );

            // If the user is being liquidated update relevant values.
            if (action.liquidatedShares > 0) {
                result.debtRepaid += action.debtRepaid;
                result.liquidatedShares[i] = action.liquidatedShares;

                if (action.badDebt > 0) {
                    result.badDebtRealized += action.badDebt;
                    // Add the bad debt to debt to remove from the liquidated
                    // account.
                    action.debtRepaid += action.badDebt;
                }

                // If its an exact liquidation this will be a redundant setter
                // but anticipation is majority of liquidators will use
                // non-exact so checking for liquidateExact each time is a
                // waste.
                debtAmounts[i] = action.debtRepaid;
            }
        }

        // If theres no debt to repay then there were no liquidations.
        if (result.debtRepaid == 0) {
            revert MarketManager__NoLiquidationAvailable();
        }

        return (result, debtAmounts);
    }

    /// @notice Checks if the seizing of `collateralToken` by repayment of
    ///         `debtToken` should be allowed.
    /// @param collateralToken The Curvance token which was used as collateral
    ///                        and will be seized.
    /// @param debtToken The Curvance token which has outstanding debt to and
    ///                  would be repaid during `collateralToken` seizure.
    function canSeize(
        address collateralToken,
        address debtToken
    ) external view {
        if (seizePaused == 2) {
            revert MarketManager__Paused();
        }

        _checkIsListedToken(collateralToken);
        _checkIsListedToken(debtToken);

        if (
            ICToken(collateralToken).marketManager() !=
            ICToken(debtToken).marketManager()
        ) {
            revert MarketManager__MarketManagerMismatch();
        }
    }

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
    ) external returns (uint256) {
        _checkIsToken(cToken);
        if (transferPaused == 2) {
            revert MarketManager__Paused();
        }

        return _canRedeemWithCollateralRemoval(
            cToken,
            shares,
            account,
            balanceOf,
            collateralPosted,
            isCollateral,
            false
        );
        
    }

    /// PERMISSIONED EXTERNAL FUNCTIONS ///

    /// @notice List isolated Curvance token pair to the market and enable
    ///         deposits.
    /// @dev Admin function to set isListed for token pair and add support
    ///      for the market. Only callable once due to isolated market design.
    ///      Emits {TokenListed} event twice.
    /// @param token0 The address of the first Curvance token to list in this
    ///               isolated market.
    /// @param token1 The address of the second Curvance token to list in this
    ///               isolated market.
    function listTokens(address token0, address token1) external {
        _checkMarketPermissions();

        // The same token cannot be listed twice in a market.
        if (token0 == token1) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate that tokens are not already listed inside this market.
        if (tokensListed.length != 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // At least one of the two tokens has to be borrowable or the
        // market does not make any sense to create.
        if (!ICToken(token0).isBorrowable() && !ICToken(token1).isBorrowable()) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // List the tokens, we do this prior since some _afterDeposit
        // hooks could require listing.
        _tokenConfig[token0].isListed = true;
        _tokenConfig[token1].isListed = true;

        // Immediately deposits into the cToken before anyone else can,
        // preventing any rounding attack vectors.
        if (!ICToken(token0).initializeDeposits(msg.sender)) {
            _revert(_INVARIANT_ERROR_SELECTOR);
        }
        
        if (!ICToken(token1).initializeDeposits(msg.sender)) {
            _revert(_INVARIANT_ERROR_SELECTOR);
        }

        // Update `tokenListed` array and emit events for any frontends that
        // need this information.
        tokensListed.push(token0);
        tokensListed.push(token1);
        
        emit TokenListed(token0);
        emit TokenListed(token1);
    }

    /// @notice Sets token liquidity configuration values for `c.cToken` a
    ///         listed cToken inside this market.
    /// @dev Emits a {TokenConfigUpdated} event.
    /// @param c A TokenConfig struct containing:
    ///               cToken The Curvance token to update liquidity 
    ///                      configuration values of.
    ///               collRatio The ratio at which $1 of collateral can be
    ///                         borrowed against, for `c.cToken`, in basis
    ///                         points.
    ///               collReqSoft The premium of excess collateral
    ///                           required to avoid soft liquidation,
    ///                           in basis points.
    ///               collReqHard The premium of excess collateral
    ///                           required to avoid hard liquidation,
    ///                           in basis points.
    ///               liqIncBase The default liquidation incentive for
    ///                          `c.cToken`, in basis points.
    ///               liqIncHard The hard liquidation incentive for
    ///                          `c.cToken`, in basis points.
    ///               liqIncMin The minimum possible liquidation incentive for
    ///                         `c.cToken` during an auction, in basis points.
    ///               liqIncMax The maximum possible liquidation incentive for
    ///                         `c.cToken` during an auction, in basis points.
    ///               closeFactorBase Maximum % that a liquidator can repay
    ///                               when soft liquidating `c.cToken` for an
    ///                               account.
    ///               closeFactorMin The minimum possible close factor for
    ///                              `c.cToken` during an auction, in basis
    ///                              points.
    ///               closeFactorMax The maximum possible close factor for
    ///                              `c.cToken` during an auction, in basis
    ///                              points.
    ///               collateralCap The maximum amount of shares that can be
    ///                             collateralized of `c.cToken` inside this
    ///                             market.
    ///               debtCap The maximum amount of assets that can be
    ///                       borrowed of `c.cToken` inside this market.
    function updateTokenConfig(TokenConfig memory c) external {
        _checkIsListedToken(c.cToken);
        _checkMarketPermissions();

        // Validate collateralization ratio is not above the maximum allowed,
        // and that hard liquidation collateral requirement is not above
        // the soft liquidation requirement. Liquidations occur when
        // collateral dries up so hard liquidation should be less collateral
        // than soft liquidation.
        if (
            c.collRatio > MAX_COLLATERALIZATION_RATIO ||
            c.collReqSoft > MAX_COLLATERAL_REQUIREMENT ||
            c.collReqHard >= c.collReqSoft
        ) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate hard liquidation incentive is higher than the soft
        // liquidation incentive. We should give heavier incentives when
        // collateral is running out to reduce lender delta exposure.
        // The maximum dynamic penalty is not greater than the base
        // liquidation incentive and that the minimum dynamic penalty is not
        // less than the base liquidation incentive.
        // Validate maximum liquidation incentive and default is
        // equal or higher than the minimum liquidation incentive.
        if (
            c.liqIncBase >= c.liqIncHard || c.liqIncBase > c.liqIncMax ||
            c.liqIncBase < c.liqIncMin || c.liqIncMin >= c.liqIncMax ||
            c.liqIncMax > MAX_LIQUIDATION_INCENTIVE
        ) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate hard and max liquidation collateral requirements are larger
        // than the hard liquidation incentive. We cannot give more incentives
        // than are available. We do not need to check soft liquidation as the
        // restrictions are thinner than this case.
        if (
            c.liqIncHard + MIN_EXCESS_COLL_REQUIRED > c.collReqHard ||
            c.liqIncMax + MIN_EXCESS_COLL_REQUIRED > c.collReqHard
        ) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate that soft liquidation is within acceptable bounds.
        if (
            c.closeFactorBase > MAX_BASE_CFACTOR ||
            c.closeFactorBase < MIN_BASE_CFACTOR
        ) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate the soft liquidation collateral premium is not stricter
        // than its `collRatio`.
        if (c.collRatio > (BPS_SQUARED / (BPS + c.collReqSoft))) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate that collateral is not trying to be turned on without
        // setting a collateralization ratio.
        if (c.collRatio == 0 && c.collateralCap > 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Do not let people borrow assets if they are not intended to be.
        if (c.debtCap > 0) {
            if (c.debtCap > _MAX_DEBT_CAP || !ICToken(c.cToken).isBorrowable()) {
                _revert(_INVALID_PARAMETER_SELECTOR);
            }
        }

        CurvanceToken storage ct = _tokenConfig[c.cToken];

        // If this token already has collateralization enabled,
        // we cannot turn collateralization off completely as this
        // would cause downstream effects to the DLE.
        if (ct.collRatio != 0 && c.collRatio == 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        (, uint256 errorCode) = CommonLib._oracleManager(centralRegistry)
            .getPrice(c.cToken, true, true);

        // Validate that we get a usable price.
        if (errorCode == 2) {
            revert MarketManager__PriceError();
        }

        // Set new collateralization ratio.
        // Note that a collateralization ratio of 0 corresponds to
        // no collateralization of `cToken`.
        ct.collRatio = uint24(c.collRatio);

        // Store the collateral requirement as a premium above `BPS`,
        // that way we can calculate solvency via division
        // efficiently in _liquidationStatusOf.
        ct.collReqSoft = uint24(c.collReqSoft + BPS);
        ct.collReqHard = uint24(c.collReqHard + BPS);

        // We use the liquidation incentive values as a premium in
        // `calculateLiquidatedTokens`, so it needs to be 1 + incentive.
        ct.liqIncBase = uint16(BPS + c.liqIncBase);
        ct.liqIncMin = uint16(BPS + c.liqIncMin);
        ct.liqIncMax = uint16(BPS + c.liqIncMax);

        // Store the distance between liquidation incentive A & B,
        // so we can quickly scale between [base, 100%] based on lFactor.
        ct.liqIncCurve = uint16(c.liqIncHard - c.liqIncBase);

        // Assign the base cFactor.
        ct.closeFactorBase = uint16(c.closeFactorBase);
        // Store the distance between base cFactor and 100%,
        // that way we can quickly scale between [base, 100%] based on lFactor.
        ct.closeFactorCurve = uint16(BPS - c.closeFactorBase);

        // Assign the min and max effective closeFactor.
        ct.closeFactorMin = uint16(c.closeFactorMin);
        ct.closeFactorMax = uint16(c.closeFactorMax);

        // Assign the collateral posted cap of `c.cToken`.
        collateralCaps[c.cToken] = c.collateralCap;

        // Assign the outstanding debt cap of `c.cToken`.
        debtCaps[c.cToken] = c.debtCap;

        emit TokenConfigUpdated(c);
    }

    /// @notice Admin function to set market-wide liquidation status.
    /// @dev Requires timelock authority if unpausing.
    ///      Emits an {ActionPaused} event.
    /// @param state Whether the desired action is pausing or unpausing.
    function setLiquidationPaused(bool state) external {
        _checkAuthorizedPermissions(state);

        liquidationPaused = state ? 2 : 1;
        emit ActionPaused("Liquidation Paused", state);
    }

    /// @notice Admin function to set Curvance token mint status.
    /// @dev Requires timelock authority if unpausing.
    ///      Emits a {TokenActionPaused} event.
    /// @param cToken The Curvance token to set minting status for.
    /// @param state Whether the desired action is pausing or unpausing.
    function setMintPaused(address cToken, bool state) external {
        _checkAuthorizedPermissions(state);
        _checkIsListedToken(cToken);

        _tokenConfig[cToken].mintPaused = state ? 2 : 1;
        emit TokenActionPaused(cToken, "Mint Paused", state);
    }

    /// @notice Admin function to set Curvance token collateralization status.
    /// @dev Requires timelock authority if unpausing.
    ///      Emits a {TokenActionPaused} event.
    /// @param cToken The Curvance token to set minting status for.
    /// @param state Whether the desired action is pausing or unpausing.
    function setCollateralizationPaused(address cToken, bool state) external {
        _checkAuthorizedPermissions(state);
        _checkIsListedToken(cToken);

        _tokenConfig[cToken].collateralizationPaused = state ? 2 : 1;
        emit TokenActionPaused(cToken, "Collateralization Paused", state);
    }

    /// @notice Admin function to set Curvance token borrow status.
    /// @dev Requires timelock authority if unpausing.
    ///      Emits a {TokenActionPaused} event.
    /// @param cToken The Curvance token to set borrowing status for.
    /// @param state Whether the desired action is pausing or unpausing.
    function setBorrowPaused(address cToken, bool state) external {
        _checkAuthorizedPermissions(state);
        _checkIsListedToken(cToken);

        _tokenConfig[cToken].borrowPaused = state ? 2 : 1;
        emit TokenActionPaused(cToken, "Borrow Paused", state);
    }

    /// @notice Admin function to set market-wide redemption status.
    /// @dev Requires timelock authority if unpausing.
    ///      Emits an {ActionPaused} event.
    /// @param state Whether the desired action is pausing or unpausing.
    function setRedeemPaused(bool state) external {
        _checkAuthorizedPermissions(state);

        redeemPaused = state ? 2 : 1;
        emit ActionPaused("Redeem Paused", state);
    }

    /// @notice Admin function to set market-wide transfer status.
    /// @dev Requires timelock authority if unpausing.
    ///      Emits an {ActionPaused} event.
    /// @param state Whether the desired action is pausing or unpausing.
    function setTransferPaused(bool state) external {
        _checkAuthorizedPermissions(state);

        transferPaused = state ? 2 : 1;
        emit ActionPaused("Transfer Paused", state);
    }

    /// @notice Admin function to set market-wide seize status.
    /// @dev Requires timelock authority if unpausing.
    ///      Emits an {ActionPaused} event.
    /// @param state Whether the desired action is pausing or unpausing.
    function setSeizePaused(bool state) external {
        _checkAuthorizedPermissions(state);

        seizePaused = state ? 2 : 1;
        emit ActionPaused("Seize Paused", state);
    }

    /// @notice Adds an position management address for complex
    ///         position actions.
    /// @dev Requires timelock authority.
    ///      Emits a {PositionManagerUpdated} event.
    /// @param newPM The address to add position manager permissions for.
    function addPositionManager(address newPM) external {
        _checkMarketPermissions();

        if (
            !ERC165Checker.supportsInterface(
                newPM,
                type(IPositionManager).interfaceId
            )
        ) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate `newPM` does not have permissions.
        if (isPositionManager[newPM]) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Add `isPositionManager` permissions to `newPM`.
        isPositionManager[newPM] = true;

        emit PositionManagerUpdated(newPM, true);
    }

    /// @notice Removes an position management address for complex
    ///         position actions.
    /// @dev Requires timelock authority.
    ///      Emits a {PositionManagerUpdated} event.
    /// @param oldPM The address to remove position manager permissions for.
    function removePositionManager(address oldPM) external {
        _checkMarketPermissions();

        // Validate `oldPM` already has permissions.
        if (!isPositionManager[oldPM]) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Remove `isPositionManager` permissions.
        delete isPositionManager[oldPM];

        emit PositionManagerUpdated(oldPM, false);
    }

    /// @notice Called from the Auction DappControl as a post hook
    ///         after liquidations are tried to enable all 
    ///         collateral to be liquidated outside Auction tx.
    function lockAuctionCollateral() external {
        _checkAuctionPermissions();

        /// @solidity memory-safe-assembly
        assembly {
            tstore(_TRANSIENT_COLLATERAL_UNLOCKED_KEY, 0)
        }
    }

    /// @notice Called from the Auction DappControl as a pre hook
    ///         before liquidations are tried to enforce that 
    ///         only a specific collateral can be liquidated.
    function unlockAuctionCollateral(address collateralToUnlock) external {
        _checkAuctionPermissions();

        uint256 collateralToUnlockUint = uint256(uint160(collateralToUnlock));
        /// @solidity memory-safe-assembly
        assembly {
            tstore(_TRANSIENT_COLLATERAL_UNLOCKED_KEY, collateralToUnlockUint)
        }
    }

    /// @notice Sets new dynamic close factor and liquidation penalty
    ///         values in transient storage.
    /// @dev Transient storage enforces any liquidator outside auction-based
    ///      liquidations uses the default risk parameters.
    /// @param cToken The Curvance token to set liquidation incentive and
    ///               close factor for during an auction-based liquidation.
    /// @param incentive The auction liquidation incentive value, in `BPS`.
    /// @param closeFactor The auction close factor value, in `BPS`.
    function setLiquidationConfig(
        address cToken,
        uint256 incentive,
        uint256 closeFactor
    ) external {
        _checkAuctionPermissions();
        _checkIsListedToken(cToken);

        CurvanceToken memory c = _tokenConfig[cToken];

        // Make sure this token actually can be liquidated, by being
        // collateralizable in the first place.
        if (c.collRatio == 0) {
            revert MarketManager__UnauthorizedLiquidation();
        }

        // Validate `incentive` is within configured incentive bounds.
        if (incentive < c.liqIncMin || incentive > c.liqIncMax) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate `closeFactor` is within configured allowed close factor
        // range.
        if (closeFactor < c.closeFactorMin || closeFactor > c.closeFactorMax) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Store new liquidation parameters in transient storage.
        // tstore(key, value):
        // Store `incentive` at `_TRANSIENT_INCENTIVE_KEY`.
        // Store `closeFactor` at `_TRANSIENT_CLOSE_FACTOR_KEY`.
        /// @solidity memory-safe-assembly
        assembly {
            tstore(_TRANSIENT_INCENTIVE_KEY, incentive)
            tstore(_TRANSIENT_CLOSE_FACTOR_KEY, closeFactor)
        }
    }

    /// @notice Resets the liquidation risk parameters in transient storage to
    ///         zero.
    /// @dev This is redundant since the transient values will be reset after
    ///      the liquidation transaction, but can be useful during meta calls
    ///      with multiple liquidations during a single transaction. 
    function resetLiquidationConfig() external {
        _checkAuctionPermissions();

        // Clear the transient storage slots by writing zero.
        /// @solidity memory-safe-assembly
        assembly {
            tstore(_TRANSIENT_INCENTIVE_KEY, 0)
            tstore(_TRANSIENT_CLOSE_FACTOR_KEY, 0)
        }
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Returns the current liquidation values in an active
    ///         transaction.
    /// @dev If a liquidation incentive or close factor is set in
    ///      transient storage, that value is returned (0 if no set value).
    /// @return incentive The liquidation incentive value, in `BPS`.
    /// @return closeFactor The close factor value, in `BPS`.
    function getLiquidationConfig() public view returns (
        uint256 incentive,
        uint256 closeFactor
    ) {
        /// @solidity memory-safe-assembly
        assembly {
            incentive := tload(_TRANSIENT_INCENTIVE_KEY)
            closeFactor := tload(_TRANSIENT_CLOSE_FACTOR_KEY)
        }
    }

    /// @dev Returns true that this contract implements both IMarketManager
    ///      and ERC165 interfaces.
    /// @param interfaceId The interface ID to check.
    /// @return result Whether the contract implements the interface.
    function supportsInterface(
        bytes4 interfaceId
    ) public view override returns (bool result) {
        result = interfaceId == type(IMarketManager).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Checks if the account should be allowed to borrow
    ///         the underlying asset of the given market.
    /// @dev Will natively revert if a hypothetical borrow will result in a
    ///      loan less than `MIN_ACTIVE_LOAN_SIZE`, set in `LiquidityManager`.
    ///      May emit a {PositionUpdated} event.
    /// @param debtToken The token to borrow from.
    /// @param assets The amount of underlying the account would borrow.
    /// @param account The account which would borrow the asset.
    /// @param newNetDebt The amount of assets that would be
    ///                   outstanding debt in total if allowed. 
    function _canBorrow(
        address debtToken,
        uint256 assets,
        address account,
        uint256 newNetDebt
    ) internal {
        _checkIsToken(debtToken);
        // Can skip token listing check since debtCaps[debtToken] can only
        // be set above 0 if `debtToken` is listed already, so we only need
        // to check that `newNetDebt` != 0 instead, which should be impossible
        // but only costs 2 gas.

        /// @solidity memory-safe-assembly
        assembly {
            if iszero(newNetDebt) {
                mstore(0x00, _INVARIANT_ERROR_SELECTOR)
                // Return bytes 29-32 for the selector.
                revert(0x1c, 0x04)
            }
        }

        if (_tokenConfig[debtToken].borrowPaused == 2) {
            revert MarketManager__Paused();
        }

        // Validates that newNetDebt is not an empty value and this borrow
        // action will not push net debt above the debt limit.
        if (newNetDebt > debtCaps[debtToken]) {
            revert MarketManager__CapReached();
        }

        // Check if the user already has an outstanding debt position in
        // `debtToken`.
        if (accountPositions[debtToken][account] != 2) {
            // The account does not have outstanding debt position in
            // `debtToken`, so add `debtToken` as an active position for
            // `account`.
            accountPositions[debtToken][account] = 2;
            accountAssets[account].assets.push(debtToken);

            emit PositionUpdated(debtToken, account, true);
        }

        // Check if the user has sufficient liquidity to borrow,
        // with heavier error code scrutiny.
        (
            HypotheticalResult memory result,
            bool[] memory positionsToClose
        ) = _hypotheticalLiquidityOf(
                account,
                HypotheticalAction({
                    cTokenModified: debtToken,
                    redemptionShares: 0,
                    borrowAssets: assets,
                    errorCodeBreakpoint: 1
                })
            );

        // Validate that `account` will not run out of collateral based
        // on their collateralization ratio(s).
        if (result.liquidityDeficit > 0) {
            revert MarketManager__InsufficientCollateral();
        }

        _closePositionsIfNeeded(
            result.positionClosureNeeded,
            account,
            positionsToClose
        );
    }

    /// @notice Helper function for checking if the account should be allowed
    ///         to redeem `amount` of `cToken` in the given market state.
    /// @param cToken The Curvance token to verify the redemption of.
    /// @param shares The number of `cToken` shares to redeem for
    ///               the underlying asset.
    /// @param account The account which would redeem `shares`.
    function _canRedeem(
        address cToken,
        uint256 shares,
        address account
    ) internal view returns (uint256, bool[] memory) {
        if (redeemPaused == 2) {
            revert MarketManager__Paused();
        }

        _checkIsListedToken(cToken);
        _checkTransfersAllowed(account);

        // If the account does not have an active position in the token,
        // then we can bypass the liquidity check.
        if (accountPositions[cToken][account] != 2) {
            bool[] memory emptyPositions;
            return (0, emptyPositions);
        }

        // Check account liquidity with hypothetical cToken redemption.
        (
            HypotheticalResult memory result,
            bool[] memory positionsToClose
        ) = _hypotheticalLiquidityOf(
                account,
                HypotheticalAction({
                    cTokenModified: cToken,
                    redemptionShares: shares,
                    borrowAssets: 0,
                    errorCodeBreakpoint: 1
                })
            );

        // Validate that `account` will not run out of collateral based
        // on their collateralization ratio(s).
        if (result.liquidityDeficit > 0) {
            revert MarketManager__InsufficientCollateral();
        }

        return (result.positionClosureNeeded, positionsToClose);
    }

    /// @notice Checks if the account should be allowed to redeem tokens
    ///         in the given market, and then redeems.
    /// @dev This can only be called by the cToken itself.
    /// @param cToken The token to verify the redemption against.
    /// @param shares The number of cToken shares to redeem for the
    ///               underlying asset in the market.
    /// @param account The account which would redeem `shares`.
    /// @param balance The current cToken share balance of `account`.
    /// @param collateralPosted The current cToken shares posted as
    ///                         collateral by `account`.
    /// @param isCollateral Boolean indicating whether the token is currently
    ///                     being used as collateral.
    /// @param forceRedeemCollateral Whether the collateral should be force
    ///                              reduced, used if isCollateral is true.
    function _canRedeemWithCollateralRemoval(
        address cToken,
        uint256 shares,
        address account,
        uint256 balance,
        uint256 collateralPosted,
        bool isCollateral,
        bool forceRedeemCollateral
    ) internal returns (uint256 collateralRedeemed) {
        if (isCollateral) {
            // If collateral is being directly removed by user intention,
            // or liquidation we can skip balance checks.
            if (forceRedeemCollateral) {
                collateralRedeemed = shares;
            } else {
                // If they want to redeem more `cToken` shares than they have
                // idle, calculate how much collateral will be redeemed from
                // the delta. Otherwise `collateralRedeemed` default value of 0
                // is correct.
                if (collateralPosted + shares >= balance) {
                    collateralRedeemed = collateralPosted + shares - balance;
                }
            }
        }
        
        // Validate that the collateral being removed is allowed.
        if (collateralRedeemed > 0) {
            (
                uint256 positionClosureNeeded,
                bool[] memory positionsToClose
            ) = _canRedeem(cToken, collateralRedeemed, account);
            _closePositionsIfNeeded(
                positionClosureNeeded,
                account,
                positionsToClose
            );
        } else {
            _checkIsListedToken(cToken);
            _checkTransfersAllowed(account);
        }
    }

    /// @notice Determines if an account can be liquidated and calculates
    ///         liquidation parameters. Computes liquidation amounts,
    ///         collateral seizure, and potential bad debt based on `account`
    ///         health.
    /// @param debtAmount The amount of debt to repay, used only if
    ///                   `liquidateExact` is true, in assets.
    /// @param account The address of the account being evaluated for
    ///                liquidation.
    /// @param tData A TokenLiqData struct containing:
    ///              collateralToken The token which is used as collateral
    ///                               by `account` and may be seized.
    ///              collateralExchangeRate The exchange rate of
    ///                                     `collateralToken` underlying token
    ///                                     to `collateralToken`.
    ///              collateralReqSoft The collateral requirement where
    ///                                dipping below this will cause a soft
    ///                                liquidation.
    ///              collateralReqHard The collateral requirement where
    ///                                dipping below this will cause a hard
    ///                                liquidation.
    ///              collateralUnderlyingPrice The current price of the
    ///                                        underlying token of
    ///                                        `collateralToken`.
    ///              collateralDecimals The decimals that `collateralToken`
    ///                                 is measured in.
    ///              debtToken The token to potentially repay which has
    ///                        outstanding debt by `account`.
    ///              debtDecimals The decimals that `debtToken` is measured
    ///                           in.
    ///              debtUnderlyingPrice The current price of the underlying
    ///                                  token of `debtToken`.
    ///              auctionBuffer The current buffer that `cSoft` is
    ///                            multiplied against, 10 bps, or 0  if not
    ///                            an auction-based liquidation.
    /// @param aData An AccountLiqData struct containing:
    ///              lFactor Empty variable to hold an account's liquidation
    ///                      factor later.
    ///              debtBalance Empty variable to hold an account's debt's 
    ///                          active debt to `tData.debtToken` later.
    ///              liqInc The ratio at which debt repayment will be
    ///                     compensated on liquidation.
    ///              liqIncBase The base ratio at which debt repayment will be
    ///                         compensated on soft liquidation.
    ///              liqIncCurve The liquidation incentive curve length
    ///                          between soft liquidation to hard liquidation.
    ///              closeFactor Maximum debt % that a liquidator can repay
    ///                          during a liquidation of an account.
    ///              closeFactorBase Maximum debt % that a liquidator can
    ///                              repay when soft liquidating an account.
    ///              closeFactorCurve Curve length between soft liquidation
    ///                               and hard liquidation, should be equal
    ///                               to 100% - `closeFactorBase`.
    /// @param liquidateExact If true, liquidate exactly `debtAmount`; if
    ///                       false, liquidate maximum possible.
    /// @return liquidatedShares The amount of `tData.collateralToken`
    ///                          that will be seized as collateral.
    /// @return uint256 The amount of `debtToken` outstanding debt that will be
    ///                 repaid.
    /// @return badDebt The amount of bad debt to recognize as part of the
    ///                 liquidation (if any).
    function _canLiquidate(
        uint256 debtAmount,
        address account,
        TokenLiqData memory tData,
        AccountLiqData memory aData,
        bool liquidateExact
    ) internal view returns (
        uint256 liquidatedShares,
        uint256,
        uint256 badDebt
    ) {
        // Calculate the users lFactor and bubble up their active debt.
        (aData.lFactor, aData.debtBalance) =
            _liquidationValuesOfCached(account, tData);

        if (aData.lFactor == 0) {
            return (0, 0, 0);
        }

        // If this liquidation does not have offchain submitted
        // parameters then closeFactorCurve will not be 0. We know this since
        // closeFactorCurve is BPS - closeFactorBase and closeFactorBase is
        // limited to MAX_BASE_CFACTOR meaning closeFactorCurve cannot ever be
        // 0 unless we did not receive offchain parameters and we need to
        // calculate close factor and liquidation penalty onchain.
        if (aData.closeFactorCurve != 0) {
            aData.closeFactor = aData.closeFactorBase +
                _mulDiv(aData.closeFactorCurve, aData.lFactor, WAD);
            aData.liqInc = aData.liqIncBase +
                _mulDiv(aData.liqIncCurve, aData.lFactor, WAD);
        }
        
        // Get the exchange rate, and calculate the number of collateralized
        // shares to seize.
        // Convert liqInc to WAD via `WAD_CUBED_BPS_OFFSET` so we dont run
        // into precision loss from only multiplying into WAD_SQUARED form.
        uint256 debtToCollateral =
            (((aData.liqInc * tData.debtUnderlyingPrice * WAD_CUBED_BPS_OFFSET) /
            (tData.collateralUnderlyingPrice * tData.collateralExchangeRate)) *
            tData.collateralDecimals) / tData.debtDecimals;
        uint256 maxDebt = (aData.closeFactor * aData.debtBalance) / BPS;
        // If they want to liquidate an exact amount, liquidate `debtAmount`,
        // otherwise liquidate the maximum amount possible.
        if (!liquidateExact) {
            debtAmount = maxDebt;
        }
        
        // Calculate how many shares should be liquidated.
        liquidatedShares = (debtAmount * debtToCollateral) / WAD_SQUARED;

        // Cache `account`'s collateral posted of
        // `tData.collateralToken`.
        uint256 sharesPosted =
            ICToken(tData.collateralToken).collateralPosted(account);

        // If the user wants to liquidate an exact amount, make sure theres
        // enough collateral available to liquidate, otherwise
        // liquidate as much as possible.
        if (liquidateExact) {
            if (debtAmount > maxDebt || liquidatedShares > sharesPosted) {
                // Make sure that the liquidation limit,
                // and collateral posted >= amount.
                _revert(_INVALID_PARAMETER_SELECTOR);
            }
        } else {
            if (liquidatedShares > sharesPosted) {
                debtAmount = FixedPointMathLib.mulDivUp(
                    debtAmount,
                    sharesPosted,
                    liquidatedShares
                );
                liquidatedShares = sharesPosted;
            }
        }

        // If the necessary shares of collateral to liquidate `account`'s
        // overall debt is above their shares posted, theres bad debt
        // that should be socialized among lenders.
        uint256 sharesNeeded = _mulDiv(
            aData.debtBalance,
            debtToCollateral,
            WAD_SQUARED
        );
        if (sharesNeeded > sharesPosted) {
            // Get the ratio at which `account` is undercollateralized
            // by looking at the ratio of `sharesPosted` vs `sharesNeeded`.
            // E.g. `sharesPosted` = `sharesNeeded` / 2 means 50%
            // of debt should be recognized as bad debt.
            badDebt = FixedPointMathLib.fullMulDiv(
                _mulDiv(debtAmount, sharesNeeded, sharesPosted),
                WAD_SQUARED - _mulDiv(WAD_SQUARED, sharesPosted, sharesNeeded),
                WAD_SQUARED
            );

            // If the adjusted debt values round slightly above
            // `aData.debtBalance` (can happen in cases where collateral
            // prices go down to a billionth of a cent we can clamp down
            // badDebt so that invariants are not broken.
            if (badDebt + debtAmount > aData.debtBalance) {
                badDebt = aData.debtBalance - debtAmount;
            }
        }

        // Calculate the maximum amount of debt that can be liquidated
        // and what collateral will be received. As well as any bad debt
        // to recognize.
        return (liquidatedShares, debtAmount, badDebt);
    }

    /// @notice Retrieves and caches liquidation configuration data for a
    ///         given token pair.
    /// @param collateralToken The address of the Curvance token to be seized
    ///                        during in the liquidation.
    /// @param debtToken The address of the Curvance token to be repaid during
    ///                  the liquidation.
    /// @return tData A TokenLiqData struct containing:
    ///               collateralToken The token which is used as collateral
    ///                               by `account` and may be seized.
    ///               collateralExchangeRate The exchange rate of
    ///                                      `collateralToken` underlying
    ///                                      token to `collateralToken`.
    ///               collateralReqSoft The collateral requirement where
    ///                                 dipping below this will cause a soft
    ///                                 liquidation.
    ///               collateralReqHard The collateral requirement where
    ///                                 dipping below this will cause a hard
    ///                                 liquidation.
    ///               collateralUnderlyingPrice The current price of the
    ///                                         underlying token of
    ///                                         `collateralToken`.
    ///               collateralDecimals The decimals that `collateralToken`
    ///                                  is measured in.
    ///               debtToken The token to potentially repay which has
    ///                         outstanding debt by `account`.
    ///               debtDecimals The decimals that `debtToken` is measured
    ///                            in.
    ///               debtUnderlyingPrice The current price of the underlying
    ///                                   token of `debtToken`.
    ///               auctionBuffer The current buffer that `cSoft` is
    ///                             multiplied against, 10 bps, or 0  if not
    ///                             an auction-based liquidation.
    /// @return aData An AccountLiqData struct containing:
    ///               lFactor Empty variable to hold an account's liquidation
    ///                       factor later.
    ///               debtBalance Empty variable to hold an account's debt's 
    ///                           active debt to `tData.debtToken` later.
    ///               liqInc The ratio at which debt repayment will be
    ///                      compensated on liquidation.
    ///               liqIncBase The base ratio at which debt repayment will
    ///                          be compensated on soft liquidation.
    ///               liqIncCurve The liquidation incentive curve length
    ///                           between soft liquidation to hard
    ///                           liquidation.
    ///               closeFactor Maximum debt % that a liquidator can repay
    ///                           during a liquidation of an account.
    ///               closeFactorBase Maximum debt % that a liquidator can
    ///                               repay when soft liquidating an account.
    ///               closeFactorCurve Curve length between soft liquidation
    ///                                and hard liquidation, should be equal
    ///                                to 100% - `closeFactorBase`.
    function _getLiquidationConfig(
        address collateralToken,
        address debtToken
    ) internal view returns (
        TokenLiqData memory tData,
        AccountLiqData memory aData
    ) {
        CurvanceToken memory c = _tokenConfig[collateralToken];
        // Do not let people liquidate 0% collateralization ratio assets.
        if (c.collRatio == 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Liquidations are only blocked if an error code of 2 (NO_SOURCE)
        // is calculated.
        (tData.collateralUnderlyingPrice, tData.debtUnderlyingPrice) =
            CommonLib._oracleManager(centralRegistry)
                .getPriceIsolatedPair(collateralToken, debtToken, 2);

        // Will revert if this liquidation is an attempted auction liquidator
        // and liquidator has chosen incorrect collateral or market.
        tData.auctionBuffer = _checkLiquidationConfig(collateralToken);

        // Cache all variables needed for computing liquidation levels.
        tData.collateralToken = collateralToken;
        tData.collateralExchangeRate = ICToken(collateralToken).exchangeRate();
        tData.collateralReqSoft = c.collReqSoft;
        tData.collateralReqHard = c.collReqHard;
        tData.collateralDecimals = 10 ** IERC20(collateralToken).decimals();
        tData.debtToken = debtToken;
        tData.debtDecimals = 10 ** IERC20(debtToken).decimals();

        // Pull transient storage variables from auctioneer updates.
        (aData.liqInc, aData.closeFactor) = getLiquidationConfig();

        // We only need to cache these variables if we did not receive close
        // factor/liquidation incentive from `getLiquidationConfig`.
        if (aData.closeFactor == 0 || aData.liqInc == 0) {
            aData.closeFactorBase = c.closeFactorBase;
            aData.closeFactorCurve = c.closeFactorCurve;
            aData.liqIncBase = c.liqIncBase;
            aData.liqIncCurve = c.liqIncCurve;
        }
    }

    /// @notice Helper function for closing user positions after liquidity
    ///         checks have been passed.
    /// @dev Used as sort of a garbage collection system for any user
    ///      positions that should be closed to optimize future liquidity
    ///      checks. May emit {PositionUpdated} events.
    /// @param positionsClosureNeeded Whether closing positions is needed
    ///                               for `account`.
    /// @param account The address of the account to close a
    ///                `cToken` position for.
    /// @param positionsToClose Array containing all The address of the asset
    ///                         to be removed.
    function _closePositionsIfNeeded(
        uint256 positionsClosureNeeded,
        address account,
        bool[] memory positionsToClose
    ) internal {
        if (positionsClosureNeeded != 2) {
            return;
        }

        // Cache asset list.
        address[] memory userAssets = accountAssets[account].assets;

        // Cache asset array characteristics.
        uint256 numAssets = userAssets.length;
        uint256 lastAssetIndex = numAssets - 1;
        address token;

        // Copy last item in list to location of item to be removed.
        address[] storage storedAssets = accountAssets[account].assets;

        // Go backwards through position list so swap and pop maintains
        // continuity.
        for (uint256 i = numAssets; i > 0; ) {
            // Subtract 1 from i prior since length starts at 1 but array
            // indices start at 0.
            if (positionsToClose[--i]) {
                // If the asset is not at the end of the array swap and pop
                // entries.
                if (i != lastAssetIndex) {
                    // Switch assets in user asset array, then decrease
                    // lastAssetIndex to account for pop.
                    storedAssets[i] = storedAssets[lastAssetIndex--];
                    // Remove the last element to remove `cToken` from
                    // account asset list.
                    storedAssets.pop();
                } else {
                    // If we are on the last index we don't need to decrement
                    // lastAssetIndex again.
                    if (lastAssetIndex != 0) {
                        --lastAssetIndex;
                    }

                    storedAssets.pop();
                }

                token = userAssets[i];

                // Remove `cToken` account position flag.
                accountPositions[token][account] = 1;
                emit PositionUpdated(token, account, false);
            }
        }
    }

    /// @notice Check whether the hold period is met.
    /// @param account The account to check the hold period for.
    function _checkHoldPeriod(address account) internal view {
        // We require a `minimumHoldPeriod` to break flashloan
        // and multi-block price manipulations if the dynamic dual oracle
        // fails to protect the market somehow.
        if (
            accountAssets[account].cooldownTimestamp + MIN_HOLD_PERIOD >
            block.timestamp
        ) {
            revert MarketManager__MinimumHoldPeriod();
        }
    }

    /// @notice Checks whether `token` is listed in this Market Manager.
    /// @param token The token to check whether it's listed or not.
    function _checkIsListedToken(address token) internal view {
        if (!_tokenConfig[token].isListed) {
            revert MarketManager__TokenNotListed();
        }
    }

    /// @dev Checks whether the caller is `token`.
    function _checkIsToken(address token) internal view {
        /// @solidity memory-safe-assembly
        assembly {
            // Equal to if (msg.sender != token)
            if iszero(eq(caller(), token)) {
                mstore(0x00, _UNAUTHORIZED_SELECTOR)
                // Return bytes 29-32 for the selector.
                revert(0x1c, 0x04)
            }
        }
    }

    /// @dev Checks whether `account` has token transfers enabled.
    function _checkTransfersAllowed(address account) internal view {
        if (centralRegistry.checkTransfersDisabled(account)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        _checkHoldPeriod(account);
    }

    /// @notice Will revert and block liquidations of collateral that are not
    ///         currently allowed by Auction, only if this is an Auction tx.
    /// @param collateralToken The address of the collateral token to
    ///                        liquidate.
    /// @return The buffer priority value to apply as a discount to collateral
    ///         during auctioned liquidations.
    function _checkLiquidationConfig(
        address collateralToken
    ) internal view returns (uint256) {
        uint256 result;
        
        /// @solidity memory-safe-assembly
        assembly {
            result := tload(_TRANSIENT_COLLATERAL_UNLOCKED_KEY)
        }

        bool unlockedMarket = centralRegistry.isMarketUnlocked();
        bool unlockedCollateral = address(uint160(result)) == collateralToken;

        if (unlockedMarket || unlockedCollateral) {
            // This is an attempted auction liquidation, and is configured
            // correctly so give them the auction priority buffer.
            if (unlockedMarket && unlockedCollateral) {
                return AUCTION_BUFFER;
            }

            // This is an attempted auction liquidation, but its misconfigured
            // and unauthorized because of this.
            revert MarketManager__UnauthorizedLiquidation();
        }

        // This is not an attempted auction liquidation, so approve the
        // liquidation, but without the auction priority buffer.
        return 0;
    }

    /// @dev Checks whether the caller has sufficient permissioning.
    function _checkMarketPermissions() internal view virtual {
        if (!centralRegistry.hasMarketPermissions(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }
    }

    /// @dev Checks whether the caller has sufficient permissioning.
    function _checkAuctionPermissions() internal view {
        if (!centralRegistry.hasAuctionPermissions(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }
    }

    /// @dev Checks whether the caller has sufficient permissions based on
    ///      `state`, turning something off is less "risky" than enabling
    ///      something, so `state` = true has reduced permissioning compared
    ///      to `state` = false.
    function _checkAuthorizedPermissions(bool state) internal view {
        if (state) {
            _checkMarketPermissions();
            return;
        }

        if (!centralRegistry.hasElevatedPermissions(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }
    }

    /// @dev Returns the Protocol Central Registry contract in interface
    ///      form.
    function _getCentralRegistry()
        internal
        view
        override
        returns (ICentralRegistry)
    {
        return centralRegistry;
    }
}