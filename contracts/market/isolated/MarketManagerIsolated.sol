// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import { LiquidityManagerIsolated, ICToken, IOracleManager } from "contracts/market/isolated/LiquidityManagerIsolated.sol";
import { Multicall } from "contracts/libraries/Multicall.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { WAD, WAD_SQUARED } from "contracts/libraries/Constants.sol";
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
        uint256 minEffectiveCloseFactor;
        uint256 maxEffectiveCloseFactor;
        uint256 baseCFactor;
        uint256 collateralCap;
        uint256 debtCap;
    }

    /// CONSTANTS ///

    /// @notice Maximum collateral requirement to avoid liquidation.
    ///         2.34e18 = 234%. Resulting in 1 / (WAD + 2.34 WAD),
    ///         or ~30% maximum LTV soft liquidation level.
    uint256 public constant MAX_COLLATERAL_REQUIREMENT = 2.34e18;
    /// @notice Minimum excess collateral requirement
    ///         on top of liquidation incentive.
    /// @dev .01e18 = 1.0%.
    uint256 public constant MIN_EXCESS_COLLATERAL_REQUIREMENT = .01e18;
    /// @notice Maximum collateralization ratio.
    /// @dev .975e18 = 97.5%.
    uint256 public constant MAX_COLLATERALIZATION_RATIO = .975e18;
    /// @notice The maximum liquidation incentive.
    /// @dev .3e18 = 30%.
    uint256 public constant MAX_LIQUIDATION_INCENTIVE = .3e18;
    /// @notice Buffer to ensure Orderflow auction can do
    ///      interest-triggered liquidations.
    /// @dev 0.999e18 = 99.9%. multiplied then divided
    ///      by WAD = 10 bps buffer.
    uint256 public constant AUCTION_BUFFER = 0.999e18;
    /// @notice The maximum base cFactor.
    /// @dev .5e18 = 50%.
    uint256 public constant MAX_BASE_CFACTOR = .5e18;
    /// @notice The minimum base cFactor.
    /// @dev .1e18 = 10%.
    uint256 public constant MIN_BASE_CFACTOR = .1e18;
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
    /// @dev `bytes4(keccak256(bytes("MarketManager__TokenNotListed()")))`
    uint256 internal constant _TOKEN_NOT_LISTED_SELECTOR = 0x4f3013c5;
    /// @dev `bytes4(keccak256(bytes("MarketManager__Paused()")))`
    uint256 internal constant _PAUSED_SELECTOR = 0xf47323f4;
    /// @dev `bytes4(keccak256(bytes("MarketManager__InvariantError()")))`
    uint256 internal constant _INVARIANT_ERROR_SELECTOR = 0x5518d5cb;
    /// @dev `bytes4(keccak256(bytes("MarketManager__UnauthorizedCollateral()")))`
    uint256 internal constant _UNAUTHORIZED_COLLATERAL_SELECTOR = 0x8ef93120;
    /// @dev A fixed key to use in transient storage for the dynamic penalty.
    bytes32 internal constant _TRANSIENT_PENALTY_KEY
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
    uint256 public liquidationPaused = 1;
    /// @notice Whether token transfers are paused.
    /// @dev 1 = unpaused; 2 = paused.
    uint256 public transferPaused = 1;
    /// @notice Whether token liquidations are paused.
    /// @dev 1 = unpaused; 2 = paused.
    uint256 public seizePaused = 1;
    /// @notice Whether token redemptions are paused.
    /// @dev 1 = unpaused; 2 = paused.
    uint256 public redeemPaused = 1;
    /// @notice Whether token minting is paused.
    /// @dev Token Address => 0 or 1 = unpaused; 2 = paused.
    mapping(address => uint256) public mintPaused;
    /// @notice Whether token collateralization is paused.
    /// @dev Token Address => 0 or 1 = unpaused; 2 = paused.
    mapping(address => uint256) public collateralizationPaused;
    /// @notice Whether token borrowing is paused.
    /// @dev Token Address => 0 or 1 = unpaused; 2 = paused.
    mapping(address => uint256) public borrowPaused;

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
    error MarketManager__UnauthorizedCollateral();

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_
    ) LiquidityManagerIsolated(centralRegistry_) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Returns whether `cToken` is listed in the lending market.
    /// @param cToken Curvance token address.
    function isListed(address cToken) external view returns (bool) {
        return tokenData[cToken].isListed;
    }

    /// @notice Returns the ratio at which `cToken` can be collateralized.
    /// @dev In WAD form e.g. 0.8e18 = 80% collateral value can be borrowed.
    /// @param cToken The address of the Curvance token to return
    ///               collateralization ratio of.
    /// @return The ratio at with debt can be borrowed against collateralized
    ///         assets.
    function collateralizationRatio(
        address cToken
    ) external view returns (uint256) {
        return tokenData[cToken].collRatio;
    }

    /// @notice Helper function for querying the current Curvance tokens listed
    ///         inside this market.
    /// @return Array containing list of all Curvance token addresses listed in
    ///         this market.
    function queryTokensListed() external view returns (address[] memory) {
        return tokensListed;
    }

    /// ACCOUNT SPECIFIC FUNCTIONS ///

    /// @notice Returns the assets an account has entered.
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
    /// by soft liquidation requirements.
    /// @return The total market value of `account`'s collateral offset
    /// by hard liquidation requirements.
    /// @return The total outstanding debt value of `account`.
    function liquidationValuesOf(
        address account
    )
        external
        view
        returns (uint256, uint256, uint256) {
        (
            AccountLiqData memory accountData,,,
        ) = _liquidationValuesOf(account, address(0), address(0));
        return (
            accountData.collateralSoft,
            accountData.collateralHard,
            accountData.debt
        );
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
    )
        public
        view
        returns (
            uint256 lfactor,
            uint256 collateralPrice,
            uint256 debtPrice
        )
    {
        (, lfactor, collateralPrice, debtPrice) = _liquidationValuesOf(
            account,
            collateralToken,
            debtToken
        );
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

        (
            HypotheticalData memory result,
            bool[] memory positionsToClose
        ) = _hypotheticalLiquidityOf(
                account,
                HypotheticalAction({
                    cTokenModified: cTokenModified,
                    redemptionShares: redemptionShares,
                    borrowAssets: borrowAssets,
                    errorCodeBreakpoint: 2
                })
            );
        return (
            result.collateralSurplus,
            result.liquidityDeficit,
            positionsToClose
        );
    }

    /// @notice Checks if the account should be allowed to mint tokens
    ///         in the given market.
    /// @param cToken The Curvance token to verify mintability of.
    function canMint(address cToken) external view virtual {
        if (mintPaused[cToken] == 2) {
            _revert(_PAUSED_SELECTOR);
        }

        _checkIsListedToken(cToken);
    }

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
    ) external {
        _checkIsToken(cToken);
        _checkIsListedToken(cToken);

        if (collateralizationPaused[cToken] == 2) {
            _revert(_PAUSED_SELECTOR);
        }

        // This also acts as a check that collateralization ratio is > 0,
        // since collateralCaps can only be raised above zero if the
        // its collateralization ratio is > 0.
        if (newNetCollateral > collateralCaps[cToken]) {
            revert MarketManager__CapReached();
        }

        // On collateral posting:
        // We need to flip their cooldown flag to prevent flashloan attacks.
        accountAssets[account].cooldownTimestamp = block.timestamp;
        // If `account` does not have a position in `cToken`, open one.
        if (accountPositions[cToken][account] != 2) {
            accountPositions[cToken][account] = 2;
            accountAssets[account].assets.push(cToken);

            emit PositionUpdated(cToken, account, true);
        }
    }

    /// @notice Checks if the account should be allowed to redeem tokens
    ///         in the given market, and then redeems.
    /// @dev This can only be called by the cToken itself.
    /// @param cToken The token to verify the redemption against.
    /// @param account The account which would redeem the tokens.
    /// @param balanceOf The current cToken share balance of `account`.
    /// @param collateralPosted The current cToken shares posted as
    ///                         collateral by `account`.
    /// @param amount The number of cToken shares to redeem for the
    ///               underlying asset in the market.
    /// @param forceRedeemCollateral Whether the collateral should be always
    ///                              reduced.
    function canRedeemWithCollateralRemoval(
        address cToken,
        address account,
        uint256 balanceOf,
        uint256 collateralPosted,
        uint256 amount,
        bool forceRedeemCollateral
    ) external returns (uint256) {
        _checkIsToken(cToken);
        return _canRedeemWithCollateralRemoval(
            cToken,
            account,
            balanceOf,
            collateralPosted,
            amount,
            true,
            forceRedeemCollateral
        );
    }

    /// @notice Checks if the account should be allowed to redeem `amount`
    ///         of `cToken` in the given market state.
    /// @param cToken The Curvance token to verify the redemption for.
    /// @param account The account which would redeem the tokens.
    /// @param amount The number of cTokens to exchange
    ///               for the underlying asset in the market.
    function canRedeem(
        address cToken,
        address account,
        uint256 amount
    ) external view {
        _canRedeem(cToken, account, amount);
    }

    /// @notice Checks if the account should be allowed to borrow
    ///         the underlying asset of the given market.
    ///         Prunes unused positions in `account` data.
    /// @dev May emit a {PositionUpdated} event.
    /// @param cToken The token to verify borrowability of.
    /// @param account The account which would borrow the asset.
    /// @param newNetDebt The amount of assets that would be
    ///                   outstanding debt in total if allowed.
    /// @param amount The amount of underlying the account would borrow.
    function canBorrow(
        address cToken,
        address account,
        uint256 newNetDebt,
        uint256 amount
    ) external {
        _canBorrow(cToken, account, newNetDebt, amount);
    }

    /// @notice Checks if the account should be allowed to borrow
    ///         the underlying asset of the given market,
    ///         and notifies the market of the borrow.
    /// @dev This can only be called by the market itself.
    /// @param cToken The token to verify borrowability of.
    /// @param account The account which would borrow the asset.
    /// @param newNetDebt The amount of assets that would be
    ///                   outstanding debt in total if allowed.
    /// @param amount The amount of underlying the account would borrow.
    function canBorrowWithNotify(
        address cToken,
        address account,
        uint256 newNetDebt,
        uint256 amount
    ) external {
        accountAssets[account].cooldownTimestamp = block.timestamp;
        _canBorrow(cToken, account, newNetDebt, amount);
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
    /// @param accounts The addresses of the accounts to be liquidated.
    /// @param debtAmounts The amounts of underlying asset the liquidator
    ///                    wishes to repay, empty if desired to max liquidate.
    /// @param instructions A LiqInstructions struct containing:
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
    /// @return results A LiqResults struct containing:
    ///                 liquidatedAmounts An array containing the collateral
    ///                                   amounts to liquidate from
    ///                                   `accounts`.
    ///                 debtRepaid The total amount of debt to repay from
    ///                            `accounts`.
    ///                 badDebtRealized The total amount of debt to realize as
    ///                                 losses for lenders inside this market.
    /// @return An array containing the debt amounts to repay from
    ///        `accounts`.
    function canLiquidate(
        address liquidator,
        address[] calldata accounts,
        uint256[] memory debtAmounts,
        IMarketManager.LiqInstructions memory instructions
    ) external view virtual returns (
        IMarketManager.LiqResults memory results,
        uint256[] memory
    ) {
        _checkIsListedToken(instructions.collateralToken);
        _checkIsListedToken(instructions.debtToken);

        (
            CachedLiqData memory cachedData,
            AuctionLiqData memory auctionData
        ) =_getLiquidationConfig(
            instructions.collateralToken,
            instructions.debtToken
        );

        address cachedAccount;
        // Amounts array is empty since the max amount possible
        // will be liquidated.
        results.liquidatedAmounts = new uint256[](instructions.numAccounts);
        for (uint256 i; i < instructions.numAccounts; ++i) {
            cachedAccount = accounts[i];
            
            // Do not let an account liquidate themselves.
            if (liquidator == cachedAccount) {
                _revert(_UNAUTHORIZED_SELECTOR);
            }

            (
                instructions.collateralLiquidated,
                instructions.debtRepaid,
                instructions.badDebt
                ) = _canLiquidate(
                cachedAccount,
                debtAmounts[i],
                cachedData,
                auctionData,
                instructions.liquidateExact
            );

            // If the user is being liquidated update relevant values.
            if (instructions.collateralLiquidated > 0) {
                results.debtRepaid += instructions.debtRepaid;
                results.liquidatedAmounts[i] =
                    instructions.collateralLiquidated;

                if (instructions.badDebt > 0) {
                    results.badDebtRealized += instructions.badDebt;
                    // Add the bad debt to debt to remove from the liquidated
                    // account.
                    instructions.debtRepaid += instructions.badDebt;
                }

                // If its an exact liquidation this will be a redundant setter
                // but anticipation is majority of liquidators will use
                // non-exact so checking for liquidateExact each time is a
                // waste.
                debtAmounts[i] = instructions.debtRepaid;
            }
        }

        // If theres no debt to repay then there were no liquidations.
        if (results.debtRepaid == 0) {
            revert MarketManager__NoLiquidationAvailable();
        }

        return (results, debtAmounts);
    }

    /// @notice Checks if the seizing of `collateral` by repayment of
    ///         `earnToken` should be allowed.
    /// @param collateralToken cToken which was used as collateral
    ///                        and will be seized.
    /// @param debtToken cToken which the account has outstanding debt to.
    function canSeize(address collateralToken, address debtToken) external view {
        if (seizePaused == 2) {
            _revert(_PAUSED_SELECTOR);
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
    /// @param from The account which will transfer the tokens.
    /// @param balanceOf The current balance that `from` has of `cToken`
    ///                  shares.
    /// @param collateralPosted The amount of `cToken` shares posted as
    ///                         collateral by `from`.
    /// @param amount The amount of `cToken` to transfer.
    /// @param isCollateral Boolean indicating whether the token is currently
    ///                     being used as collateral.
    function canTransfer(
        address cToken,
        address from,
        uint256 balanceOf,
        uint256 collateralPosted,
        uint256 amount,
        bool isCollateral
    ) external returns (uint256) {
        _checkIsToken(cToken);
        if (transferPaused == 2) {
            _revert(_PAUSED_SELECTOR);
        }

        return _canRedeemWithCollateralRemoval(
            cToken,
            from,
            balanceOf,
            collateralPosted,
            amount,
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

        uint256 numTokens = tokensListed.length;
        if (numTokens != 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // List the tokens.
        tokenData[token0].isListed = true;
        tokenData[token1].isListed = true;

        // Immediately deposit into the cToken to prevent any rounding
        // exploits.
        if (!ICToken(token0).startMarket(msg.sender)) {
            _revert(_INVARIANT_ERROR_SELECTOR);
        }
        if (!ICToken(token1).startMarket(msg.sender)) {
            _revert(_INVARIANT_ERROR_SELECTOR);
        }

        // At least one of the two tokens has to be borrowable or the
        // market does not make any sense to create.
        if (
            !ICToken(token0).isBorrowable() &&
            !ICToken(token1).isBorrowable()
            ) {
            _revert(_INVARIANT_ERROR_SELECTOR);
        }

        // No need to check whether tokens were listed before since this
        // function can only be called once due to numTokens == 0 check.

        // Update frontend array/emit events.
        tokensListed.push(token0);
        emit TokenListed(token0);
        tokensListed.push(token1);
        emit TokenListed(token1);
    }

    /// @notice Sets market liquidity configuration values for a position
    ///         token inside this market.
    /// @dev Emits a {TokenConfigUpdated} event.
    /// @param config A TokenConfig struct containing:
    ///               cToken The Curvance token to update configuration of.
    ///               collRatio The ratio at which $1 of collateral
    ///                         can be borrowed against, for `cToken`,
    ///                         in basis points.
    ///               collReqSoft The premium of excess collateral
    ///                           required to avoid soft liquidation,
    ///                           in basis points.
    ///               collReqHard The premium of excess collateral
    ///                           required to avoid hard liquidation,
    ///                           in basis points.
    ///               liqIncBase The default liquidation incentive for
    ///                          `cToken`, in basis points.
    ///               liqIncHard The hard liquidation incentive for `cToken`,
    ///                          in basis points.
    ///               liqIncMin The minimum possible liquidation incentive for
    ///                         `cToken`, in basis points.
    ///               liqIncMax The maximum possible liquidation incentive for
    ///                         `cToken`, in basis points.
    function updateTokenConfig(TokenConfig memory config) external {
        _checkMarketPermissions();

        // Convert the parameters from basis points to `WAD` format.
        // While inefficient, we want to minimize potential human error
        // as much as possible, even if it costs a bit extra gas on config.
        config.collRatio = _bpToWad(config.collRatio);
        config.collReqSoft = _bpToWad(config.collReqSoft);
        config.collReqHard = _bpToWad(config.collReqHard);
        config.liqIncBase = _bpToWad(config.liqIncBase);
        config.liqIncHard = _bpToWad(config.liqIncHard);
        config.liqIncMin = _bpToWad(config.liqIncMin);
        config.liqIncMax = _bpToWad(config.liqIncMax);
        config.baseCFactor = _bpToWad(config.baseCFactor);
        config.minEffectiveCloseFactor = _bpToWad(config.minEffectiveCloseFactor);
        config.maxEffectiveCloseFactor = _bpToWad(config.maxEffectiveCloseFactor);

        // Validate collateralization ratio is not above the maximum allowed.
        if (config.collRatio > MAX_COLLATERALIZATION_RATIO) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate soft liquidation collateral requirement is
        // not above the maximum allowed.
        if (config.collReqSoft > MAX_COLLATERAL_REQUIREMENT) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate hard liquidation collateral requirement is not above
        // the soft liquidation requirement. Liquidations occur when
        // collateral dries up so hard liquidation should be less collateral
        // than soft liquidation.
        if (config.collReqHard >= config.collReqSoft) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate hard liquidation incentive is
        // higher than the soft liquidation incentive. Give heavier incentives
        // when collateral is running out to reduce delta exposure.
        if (config.liqIncBase >= config.liqIncHard) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Make sure the maximum dynamic penalty is not greater than the base
        // liquidation incentive and that the minimum dynamic penalty is not
        // less than the base liquidation incentive.
        if (
            config.liqIncBase > config.liqIncMax ||
            config.liqIncBase < config.liqIncMin
            ) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate hard liquidation incentive is
        // not above the maximum allowed.
        if (config.liqIncMax > MAX_LIQUIDATION_INCENTIVE) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate maximum liquidation incentive and default is
        // equal or higher than the minimum liquidation incentive.
        if (config.liqIncMin >= config.liqIncMax) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate hard liquidation collateral requirement is larger
        // than the hard liquidation incentive. We cannot give more incentives
        // than are available. We do not need to check soft liquidation as the
        // restrictions are thinner than this case.
        if (
            config.liqIncHard + MIN_EXCESS_COLLATERAL_REQUIREMENT >
            config.collReqHard
            ) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate hard liquidation collateral requirement is larger
        // than the hard liquidation incentive. We cannot give more incentives
        // than are available. We do not need to check soft liquidation as the
        // restrictions are thinner than this case.
        if (
            config.liqIncMax + MIN_EXCESS_COLLATERAL_REQUIREMENT >
            config.collReqHard
            ) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate that soft liquidation is within acceptable bounds.
        if (
            config.baseCFactor > MAX_BASE_CFACTOR ||
            config.baseCFactor < MIN_BASE_CFACTOR
            ) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate the soft liquidation collateral premium
        // is not more strict than the asset's CR.
        if (config.collRatio > (WAD_SQUARED / (WAD + config.collReqSoft))) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate that collateral is not trying to be turned on without
        // setting a collateralization ratio.
        if (config.collRatio == 0 && config.collateralCap > 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Do not let people borrow assets if they are not intended to be.
        if (config.debtCap > 0) {
            if (
                config.debtCap > _MAX_DEBT_CAP ||
                !ICToken(config.cToken).isBorrowable()
                ) {
                    _revert(_INVALID_PARAMETER_SELECTOR);
            }
        }

        CurvanceToken storage curvanceToken = tokenData[config.cToken];

        // If this token already has collateralization enabled,
        // we cannot turn collateralization off completely as this
        // would cause downstream effects to the DLE.
        if (curvanceToken.collRatio != 0 && config.collRatio == 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        (, uint256 errorCode) = IOracleManager(centralRegistry.oracleManager())
            .getPrice(config.cToken, true, true);

        // Validate that we get a usable price.
        if (errorCode == 2) {
            revert MarketManager__PriceError();
        }

        // Assign new collateralization ratio.
        // Note that a collateralization ratio of 0 corresponds to
        // no collateralization of the cToken.
        curvanceToken.collRatio = config.collRatio;

        // Store the collateral requirement as a premium above `WAD`,
        // that way we can calculate solvency via division
        // efficiently in _liquidationStatusOf.
        curvanceToken.collReqSoft = config.collReqSoft + WAD;
        curvanceToken.collReqHard = config.collReqHard + WAD;

        // We use the liquidation incentive values as a premium in
        // `calculateLiquidatedTokens`, so it needs to be 1 + incentive.
        curvanceToken.liqBaseIncentive = WAD + config.liqIncBase;
        curvanceToken.liqMinIncentive = WAD + config.liqIncMin;
        curvanceToken.liqMaxIncentive = WAD + config.liqIncMax;

        // Store the distance between liquidation incentive A & B,
        // so we can quickly scale between [base, 100%] based on lFactor.
        curvanceToken.liqCurve = config.liqIncHard - config.liqIncBase;

        // Assign the base cFactor
        curvanceToken.baseCFactor = config.baseCFactor;
        // Store the distance between base cFactor and 100%,
        // that way we can quickly scale between [base, 100%] based on lFactor.
        curvanceToken.cFactorCurve = WAD - config.baseCFactor;

        // Assign the min and max effective closeFactor
        curvanceToken.minEffectiveCloseFactor = config.minEffectiveCloseFactor;
        curvanceToken.maxEffectiveCloseFactor = config.maxEffectiveCloseFactor;

        // Assign the collateral cap
        collateralCaps[config.cToken] = config.collateralCap;

        // Assign the debt cap
        debtCaps[config.cToken] = config.debtCap;

        emit TokenConfigUpdated(config);
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

        mintPaused[cToken] = state ? 2 : 1;
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

        collateralizationPaused[cToken] = state ? 2 : 1;
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

        borrowPaused[cToken] = state ? 2 : 1;
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
    /// @param newAddress The address to add position management
    ///                   permissions for.
    function addPositionManager(address newAddress) external {
        _checkElevatedPermissions();

        if (
            !ERC165Checker.supportsInterface(
                newAddress,
                type(IPositionManager).interfaceId
            )
        ) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate `newAddress` does not have permissions.
        if (isPositionManager[newAddress]) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Add `isPositionManager` permissions.
        isPositionManager[newAddress] = true;

        emit PositionManagerUpdated(newAddress, true);
    }

    /// @notice Removes an position management address for complex
    ///         position actions.
    /// @dev Requires timelock authority.
    ///      Emits a {PositionManagerUpdated} event.
    /// @param addressApproved The address to remove position
    ///                        management permissions for.
    function removePositionManager(address addressApproved) external {
        _checkElevatedPermissions();

        // Validate `addressApproved` already has permissions.
        if (!isPositionManager[addressApproved]) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Remove `isPositionManager` permissions.
        delete isPositionManager[addressApproved];

        emit PositionManagerUpdated(addressApproved, false);
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
    /// @dev Transient storage enforces any liquidator outside Auction
    ///      uses the default risk parameters.
    /// @param newPenalty The new penalty value.
    function setAuctionParameters(
        address cToken,
        uint256 newPenalty,
        uint256 newCloseFactor
    ) external {
        _checkAuctionPermissions();
        _checkIsListedToken(cToken);

        CurvanceToken storage cTokenData = tokenData[cToken];

        // Make sure this token actually can be liquidated, by being
        // collateralizable in the first place.
        if (cTokenData.collRatio == 0) {
            _revert(_UNAUTHORIZED_COLLATERAL_SELECTOR);
        }

        // Validate new penalty is within configured allowed penalty.
        if (
            newPenalty < cTokenData.liqMinIncentive ||
            newPenalty > cTokenData.liqMaxIncentive
            ) {
            revert MarketManager__InvalidParameter();
        }

        // Validate new Close Factor value.
        if (
            newCloseFactor < cTokenData.minEffectiveCloseFactor ||
            newCloseFactor > cTokenData.maxEffectiveCloseFactor
            ) {
            revert MarketManager__InvalidParameter();
        }

        // Set new Risk Parameters in transient storage. 
        // tstore(key, value): store `newPenalty` under TRANSIENT_PENALTY_KEY.
        /// @solidity memory-safe-assembly
        assembly {
            tstore(_TRANSIENT_PENALTY_KEY, newPenalty)
        }

        // tstore(key, value): store `newCloseFactor` under
        // TRANSIENT_CLOSE_FACTOR_KEY.
        // @solidity memory-safe-assembly
        assembly {
            tstore(_TRANSIENT_CLOSE_FACTOR_KEY, newCloseFactor)
        }
    }

    /// @notice Resets the Auction risk parameters in transient storage to zero.
    ///         This is redundant since the transient values will be reset 
    ///         after an Auction tx, but helps to ensure expected behaviour. 
    function resetAuctionParameters() external {
        _checkAuctionPermissions();

        /// @solidity memory-safe-assembly
        assembly {
            // Clear the transient storage slot by writing zero. 
            tstore(_TRANSIENT_PENALTY_KEY, 0)
        }

        // Clear the transient storage slot by writing zero.
        /// @solidity memory-safe-assembly
        assembly {
            tstore(_TRANSIENT_CLOSE_FACTOR_KEY, 0)
        }
        
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Returns the current Auction parameters in an active transaction.
    /// @dev If a dynamic penalty or close factor is set in transient storage,
    ///      that value is returned; otherwise, the default penalty or close
    ///      factor is returned.
    ///      NOTE: caller must handle the case where the
    ///      TRANSIENT_CLOSE_FACTOR_KEY is empty, and zero is returned.
    function getLatestAuctionParameters() public view returns (
        uint256 penalty,
        uint256 closeFactor
    ) {
        /// @solidity memory-safe-assembly
        assembly {
            penalty := tload(_TRANSIENT_PENALTY_KEY)
            closeFactor := tload(_TRANSIENT_CLOSE_FACTOR_KEY)
        }
        // NOTE: Fallback scenarios where a parameter(s) MUST based handled
        // separately based on lFactor.
    }

    /// @inheritdoc ERC165
    function supportsInterface(
        bytes4 interfaceId
    ) public view override returns (bool) {
        return
            interfaceId == type(IMarketManager).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Checks if the account should be allowed to borrow
    ///         the underlying asset of the given market.
    /// @dev Will natively revert if a hypothetical borrow will result in a
    ///      loan less than `MIN_ACTIVE_LOAN_SIZE`, set in `LiquidityManager`.
    ///      May emit a {PositionUpdated} event.
    /// @param debtToken The token to borrow from.
    /// @param account The account which would borrow the asset.
    /// @param newNetDebt The amount of assets that would be
    ///                   outstanding debt in total if allowed. 
    /// @param amount The amount of underlying the account would borrow.
    function _canBorrow(
        address debtToken,
        address account,
        uint256 newNetDebt,
        uint256 amount
    ) internal {
        _checkIsToken(debtToken);
        _checkIsListedToken(debtToken);

        if (borrowPaused[debtToken] == 2) {
            _revert(_PAUSED_SELECTOR);
        }

        // Validates that this borrow action will not push net debt
        // above the debt limit.
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
            HypotheticalData memory result,
            bool[] memory positionsToClose
        ) = _hypotheticalLiquidityOf(
                account,
                HypotheticalAction({
                    cTokenModified: debtToken,
                    redemptionShares: 0,
                    borrowAssets: amount,
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
    /// @param account The account which would redeem the tokens.
    /// @param shares The number of `cToken` shares to redeem for
    ///               the underlying asset.
    function _canRedeem(
        address cToken,
        address account,
        uint256 shares
    ) internal view returns (uint256, bool[] memory) {
        if (redeemPaused == 2) {
            _revert(_PAUSED_SELECTOR);
        }

        _checkIsListedToken(cToken);

        if (
            IActionRegistry(address(centralRegistry)).checkTransfersDisabled(
                account
            )
        ) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        _checkHoldPeriod(account);

        // If the account does not have an active position in the token,
        // then we can bypass the liquidity check.
        if (accountPositions[cToken][account] != 2) {
            bool[] memory emptyPositions;
            return (0, emptyPositions);
        }

        // Check account liquidity with hypothetical cToken redemption.
        (
            HypotheticalData memory result,
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
    /// @param account The account which would redeem the tokens.
    /// @param balanceOf The current cToken share balance of `account`.
    /// @param collateralPosted The current cToken shares posted as
    ///                         collateral by `account`.
    /// @param amount The number of cToken shares to redeem for the
    ///               underlying asset in the market.
    /// @param isCollateral Boolean indicating whether the token is currently
    ///                     being used as collateral.
    /// @param forceRedeemCollateral Whether the collateral should be force
    ///                              reduced, used if isCollateral is true.
    function _canRedeemWithCollateralRemoval(
        address cToken,
        address account,
        uint256 balanceOf,
        uint256 collateralPosted,
        uint256 amount,
        bool isCollateral,
        bool forceRedeemCollateral
    ) internal returns (uint256 collateralToRemove) {
        if (isCollateral) {
            // If collateral is being directly removed by user intention,
            // or liquidation we can skip balance checks.
            if (forceRedeemCollateral) {
                collateralToRemove = amount;
            } else {
                // If they want to redeem more `cToken` shares than they have
                // idle, calculate how much collateral will be redeemed from
                // the delta. Otherwise collateralToRemove default value of 0
                // is correct.
                if (collateralPosted + amount >= balanceOf) {
                    collateralToRemove =
                        collateralPosted + amount - balanceOf;
                }
            }
        }
        
        // Validate that the collateral being removed is allowed.
        if (collateralToRemove > 0) {
            (
                uint256 positionClosureNeeded,
                bool[] memory positionsToClose
            ) = _canRedeem(cToken, account, collateralToRemove);
            _closePositionsIfNeeded(
                positionClosureNeeded,
                account,
                positionsToClose
            );
        } else {
            _checkIsListedToken(cToken);

            if (
                IActionRegistry(address(centralRegistry))
                    .checkTransfersDisabled(account)
            ) {
                _revert(_UNAUTHORIZED_SELECTOR);
            }

            _checkHoldPeriod(account);
        }
    }

    /// @notice Determines if an account can be liquidated and calculates
    ///         liquidation parameters. Computes liquidation amounts,
    ///         collateral seizure, and potential bad debt based on `account`
    ///         health.
    /// @param account The address of the account being evaluated for
    ///                liquidation.
    /// @param debtAmount The amount of debt to liquidate, used only if
    ///                   `liquidateExact` is true.
    /// @param cachedData A CachedLiqData struct containing:
    ///                   collateralToken The token which is used as
    ///                                   collateral by `account` and may
    ///                                   be seized.
    ///                   collateralExchangeRate The exchange rate of
    ///                                          `collateralToken` underlying
    ///                                          token to `collateralToken`.
    ///                   collateralReqSoft The collateral requirement where
    ///                                     dipping below this will cause a
    ///                                     soft liquidation.
    ///                   collateralReqHard The collateral requirement where
    ///                                     dipping below this will cause a
    ///                                     hard liquidation.
    ///                   collateralUnderlyingPrice The current price of the
    ///                                             underlying token of
    ///                                             `collateralToken`.
    ///                   collateralDecimals The decimals that 
    ///                                      `collateralToken` is measured in.
    ///                   debtToken The token to potentially repay which has 
    ///                             outstanding debt by `account`.
    ///                   debtDecimals The decimals that `debtToken` is
    ///                                measured in.
    ///                   debtUnderlyingPrice The current price of the
    ///                                       underlying token of `debtToken`
    ///                   auctionBuffer The current buffer that collateralSoft
    ///                                 is multiplied against, 10 bps, or 0
    ///                                 if not an auction liquidation.
    /// @param auctionData An AuctionLiqData struct containing:
    ///                    lFactor Empty variable to hold an account's
    ///                            liquidation factor later.
    ///                    debtBalance Empty variable to hold an account's
    ///                                debt's active debt to
    ///                                `cachedData.debtToken` later.
    ///                    auctionCFactor Maximum % that a liquidator can
    ///                                   repay when soft liquidating an
    ///                                   account.
    ///                    auctionLiqIncentive The ratio at which this token
    ///                                        will be compensated on
    ///                                        liquidation.
    ///                    baseCFactor Maximum % that a liquidator can repay
    ///                                when soft liquidating an account.
    ///                    cFactorCurve cFactor curve length between soft
    ///                                 liquidation and hard liquidation,
    ///                                 should be equal to
    ///                                 100% - `baseCFactor`.
    ///                    liqBaseIncentive The base ratio at which this
    ///                                     token will be compensated on
    ///                                     soft liquidation.
    ///                    liqCurve The liquidation incentive curve length
    ///                             between soft liquidation to hard
    ///                             liquidation.
    /// @param liquidateExact If true, liquidate exactly `debtAmount`; if
    ///                       false, liquidate maximum possible.
    /// @return collateralLiquidated The amount of `cachedData.collateralToken`
    ///                              that will be seized as collateral.
    /// @return uint256 The amount of `debtToken` outstanding debt that will be
    ///                 repaid.
    /// @return badDebt The amount of bad debt to recognize as part of the
    ///                 liquidation (if any).
    function _canLiquidate(
        address account,
        uint256 debtAmount,
        CachedLiqData memory cachedData,
        AuctionLiqData memory auctionData,
        bool liquidateExact
    ) internal view returns (
        uint256 collateralLiquidated,
        uint256,
        uint256 badDebt
    ) {
        // Calculate the users lFactor and bubble up their active debt.
        (
            auctionData.lFactor,
            auctionData.debtBalance
        ) = _liquidationValuesOfCached(
            account,
            cachedData
        );

        if (auctionData.lFactor == 0) {
            return (0, 0, 0);
        }

        // If this liquidation is not part of an auction we need to
        // manually calculate liquidation size and liquidation penalty.
        if (cachedData.auctionBuffer == 0) {
            // Fallback to using the base close factor when
            // _TRANSIENT_CLOSE_FACTOR_KEY is empty.
            auctionData.auctionCFactor = auctionData.baseCFactor +
                ((auctionData.cFactorCurve * auctionData.lFactor) / WAD);
            auctionData.auctionLiqIncentive = auctionData.liqBaseIncentive +
                ((auctionData.liqCurve * auctionData.lFactor) / WAD);
        }
        
        // Get the exchange rate, and calculate the number of collateralized
        // shares to seize.
        uint256 debtToCollateralMultiplier =
            (((auctionData.auctionLiqIncentive *
                cachedData.debtUnderlyingPrice * WAD) /
            (cachedData.collateralUnderlyingPrice *
                cachedData.collateralExchangeRate)) *
            cachedData.collateralDecimals) / cachedData.debtDecimals;
        uint256 maxAmount =
            (auctionData.auctionCFactor * auctionData.debtBalance) / WAD;
        // If they want to liquidate an exact amount, liquidate `debtAmount`,
        // otherwise liquidate the maximum amount possible.
        if (!liquidateExact) {
            debtAmount = maxAmount;
        }
        
        // Calculate how many tokens should be liquidated, adjusting decimals
        // if necessary.
        collateralLiquidated = (debtAmount * debtToCollateralMultiplier) / WAD;

        // Cache `account`'s collateral posted of `cachedData.collateralToken`.
        uint256 collateralAvailable = ICToken(
            cachedData.collateralToken
        ).collateralPosted(account);

        // If the user wants to liquidate an exact amount, make sure theres
        // enough collateral available to liquidate, otherwise
        // liquidate as much as possible.
        if (liquidateExact) {
            if (
                debtAmount > maxAmount ||
                collateralLiquidated > collateralAvailable
            ) {
                // Make sure that the liquidation limit,
                // and collateral posted >= amount.
                _revert(_INVALID_PARAMETER_SELECTOR);
            }
        } else {
            if (collateralLiquidated > collateralAvailable) {
                debtAmount = FixedPointMathLib.mulDivUp(
                    debtAmount,
                    collateralAvailable,
                    collateralLiquidated
                );
                collateralLiquidated = collateralAvailable;
            }
        }

        // If the necessary amount of collateral to liquidate `account`'s
        // overall debt is above their collateral balance, theres bad debt
        // that should be socialized.
        uint256 collateralRequired = 
            (auctionData.debtBalance * debtToCollateralMultiplier) / WAD;
        if (collateralRequired > collateralAvailable) {
            // Get prior ratio between debt/collateral before any
            // liquidation = Shortfall Ratio
            // Bad Debt = End debt - (end collateral * shortfall ratio)
            // NOTE: We round UP on expected user outstanding debt meaning
            // we round down bad debt and thus are in favor of the protocol.
            badDebt = (auctionData.debtBalance - debtAmount) -
            FixedPointMathLib.mulDivUp(
                ((collateralAvailable - collateralLiquidated) *
                    cachedData.collateralExchangeRate) / WAD,
                cachedData.collateralUnderlyingPrice,
                (cachedData.debtUnderlyingPrice * WAD) /
                    cachedData.debtDecimals
            );
        }

        // Calculate the maximum amount of debt that can be liquidated
        // and what collateral will be received. As well as any bad debt
        // to recognize.
        return (collateralLiquidated, debtAmount, badDebt);
    }

    /// @notice Retrieves and caches liquidation configuration data for a
    ///         given token pair.
    /// @param collateralToken The address of the Curvance token to be seized
    ///                        during in the liquidation.
    /// @param debtToken The address of the Curvance token to be repaid during
    ///                  the liquidation.
    /// @return cachedData A CachedLiqData struct containing:
    ///                    collateralToken The token which is used as
    ///                                    collateral by `account` and may
    ///                                    be seized.
    ///                    collateralExchangeRate The exchange rate of
    ///                                           `collateralToken` underlying
    ///                                           token to `collateralToken`.
    ///                    collateralReqSoft The collateral requirement where
    ///                                      dipping below this will cause a
    ///                                      soft liquidation.
    ///                    collateralReqHard The collateral requirement where
    ///                                      dipping below this will cause a
    ///                                      hard liquidation.
    ///                    collateralUnderlyingPrice The current price of the
    ///                                              underlying token of
    ///                                              `collateralToken`.
    ///                    collateralDecimals The decimals that `collateralToken`
    ///                                       is measured in.
    ///                    debtToken The token to potentially repay which has 
    ///                              outstanding debt by `account`.
    ///                    debtDecimals The decimals that `debtToken` is
    ///                                 measured in.
    ///                    debtUnderlyingPrice The current price of the
    ///                                        underlying token of `debtToken`
    ///                    auctionBuffer The current buffer that collateralSoft
    ///                                  is multiplied against, 10 bps, or 0
    ///                                  if not an auction liquidation.
    /// @return auctionData An AuctionLiqData struct containing:
    ///                     lFactor Empty variable to hold an account's
    ///                             liquidation factor later.
    ///                     debtBalance Empty variable to hold an account's
    ///                                 debt's active debt to
    ///                                 `cachedData.debtToken` later.
    ///                     auctionCFactor Maximum % that a liquidator can
    ///                                    repay when soft liquidating an
    ///                                    account.
    ///                     auctionLiqIncentive The ratio at which this token
    ///                                         will be compensated on
    ///                                         liquidation.
    ///                     baseCFactor Maximum % that a liquidator can repay
    ///                                 when soft liquidating an account.
    ///                     cFactorCurve cFactor curve length between soft
    ///                                  liquidation and hard liquidation,
    ///                                  should be equal to
    ///                                  100% - `baseCFactor`.
    ///                     liqBaseIncentive The base ratio at which this
    ///                                      token will be compensated on
    ///                                      soft liquidation.
    ///                     liqCurve The liquidation incentive curve length
    ///                              between soft liquidation to hard
    ///                              liquidation.
    function _getLiquidationConfig(
        address collateralToken,
        address debtToken
    ) internal view returns (
        CachedLiqData memory cachedData,
        AuctionLiqData memory auctionData
    ) {
        CurvanceToken memory collateralData = tokenData[collateralToken];
        // Do not let people liquidate 0% collateralization ratio assets.
        if (collateralData.collRatio == 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Liquidations are only blocked if an error code of 2 (NO_SOURCE)
        // is calculated.
        (
            cachedData.collateralUnderlyingPrice,
            cachedData.debtUnderlyingPrice
        ) = IOracleManager(
            centralRegistry.oracleManager()
        ).getPriceIsolatedPair(collateralToken, debtToken, 2);

        // Cache all variables needed for computing liquidation levels and
        // compress into one struct for stack too deep limits.
        cachedData.collateralToken = collateralToken;
        cachedData.collateralExchangeRate = ICToken(
            collateralToken
        ).exchangeRate();
        cachedData.collateralReqSoft = tokenData[collateralToken].collReqSoft;
        cachedData.collateralReqHard = tokenData[collateralToken].collReqHard;
        cachedData.collateralDecimals = 10 ** IERC20(collateralToken).decimals();
        cachedData.debtToken = debtToken;
        cachedData.debtDecimals = 10 ** IERC20(debtToken).decimals();

        // Will revert if during auction transaction and liquidator has chosen
        // incorrect collateral.
        cachedData.auctionBuffer = _checkCollateralUnlocked(collateralToken);
        // Pull transient storage variables from auctioneer updates.
        (
            auctionData.auctionLiqIncentive,
            auctionData.auctionCFactor
        ) = getLatestAuctionParameters();

        // We only need to read storage and cache these variables if we did
        // not receive cFactor/liqIncentive from the auction.
        if (auctionData.auctionCFactor == 0) {
            auctionData.baseCFactor = collateralData.baseCFactor;
            auctionData.cFactorCurve = collateralData.cFactorCurve;
        }

        if (auctionData.auctionLiqIncentive == 0) {
            auctionData.liqBaseIncentive = collateralData.liqBaseIncentive;
            auctionData.liqCurve = collateralData.liqCurve;
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
        uint256 lastAssetIndex = userAssets.length - 1;
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
        if (!tokenData[token].isListed) {
            _revert(_TOKEN_NOT_LISTED_SELECTOR);
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

    /// @dev Checks whether the caller has sufficient permissions.
    function _checkElevatedPermissions() internal view {
        if (!centralRegistry.hasElevatedPermissions(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }
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

        _checkElevatedPermissions();
    }

    /// @notice Multiplies `value` by 1e14 to convert it from `basis points`
    ///         to WAD.
    /// @dev Internal helper function for easily converting between scalars.
    function _bpToWad(uint256 value) internal pure returns (uint256) {
        return value * 1e14;
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

    /// @notice Will revert and block liquidations of collateral that are not
    ///         currently allowed by Auction, only if this is an Auction tx.
    /// @param collateralTokenToLiquidate The address of the collateral token
    ///                                   to liquidate.
    /// @return buffer The buffer value to apply as a discount to collateral
    ///                during liquidation checks.
    function _checkCollateralUnlocked(
        address collateralTokenToLiquidate
    ) internal view returns (uint256 buffer) {
        uint256 result;
        /// @solidity memory-safe-assembly
        assembly {
            result := tload(_TRANSIENT_COLLATERAL_UNLOCKED_KEY)
        }

        // CASE: This is not an Auction tx, so allow all collaterals,
        // and return no buffer. 
        if (result == 0) {
            return buffer;
        }

        address unlockedCollateral = address(uint160(result));

        // This is an Auction tx, and Auction liquidator attempted wrong
        // collateral so revert.
        if (unlockedCollateral != collateralTokenToLiquidate) {
            _revert(_UNAUTHORIZED_COLLATERAL_SELECTOR);
        }

        // If we reach this point this is an Auction tx and collateral is
        // valid, so return the auction buffer. 
        buffer = AUCTION_BUFFER;
    }
}