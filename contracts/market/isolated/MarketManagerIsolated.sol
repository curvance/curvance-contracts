// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import { LiquidityManagerIsolated, IMToken, IEToken, IOracleManager } from "contracts/market/isolated/LiquidityManagerIsolated.sol";
import { Multicall } from "contracts/libraries/Multicall.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { WAD, WAD_SQUARED } from "contracts/libraries/Constants.sol";
import { ERC165 } from "contracts/libraries/external/ERC165.sol";
import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { IPositionManagement } from "contracts/interfaces/IPositionManagement.sol";
import { IActionRegistry } from "contracts/interfaces/IActionRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IPToken } from "contracts/interfaces/IPToken.sol";

/// @title Curvance DAO Market Manager.
/// @notice Manages risk within the Curvance DAO markets.
/// @dev Curvance Market Managers are built as "thesis driven" micro
///      ecosystems. This means that a market may be focused specifically
///      on interest-bearing stablecoins, or bluechip long market exposure,
///      volatile LP tokens for a particular dex or perpetual platform. This
///      minimizes systemic risk by having many market managers with unique
///      opportunities and risk profiles.
///
///      There are two types of tokens inside Curvance:
///      Position tokens, aka pTokens that can be posted as collateral.
///      Debt tokens, aka eTokens that can be lent out to pToken depositors.
///      Unique to Curvance, rehypothecation of position token deposits
///      is disabled, this decision was made to allow for vastly improved
///      market risk modeling and the expansion of supportable assets to
///      nearly any erc20 in existence.
///
///      All management of both pTokens and eTokens actions are managed by
///      the Market Manager. These tokens are collectively referred to as
///      Market Tokens, or mTokens. All pTokens and eTokens are mTokens but,
///      not all pTokens are eTokens, and vice versa. Listing of pTokens and
///      eTokens also restrict token collision, meaning a pToken and eToken
///      cannot have the same underlying token in the same market. Each market
///      has a maximum number of supportable assets, this is to minimize
///      systemic risk and gas costs on liquidity checks.
///
///      Curvance offers the ability to store unlimited collateral inside
///      pToken contracts while restricting the scale of exogenous risk.
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
///      pToken collateral, and lending of eTokens. This restriction improves
///      the security model of Curvance and allows for more mature interest
///      rate models.
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
    bytes32 internal constant _TRANSIENT_PENALTY_KEY = 0xd033e44c9f2a65a460c9f878712895054941eb772c7716e6dee8b66c21be9561;
    /// @dev A fixed key to use in transient storage for dynamic close factor.
    bytes32 internal constant _TRANSIENT_CLOSE_FACTOR_KEY = 0x2345678901234567890123456789012345678901234567890123456789012345;
    /// @dev A fixed key to use in transient storage for enforcing a single
    ///      collateral which can be liquidated during Atlas tx.
    bytes32 internal constant _TRANSIENT_COLLATERAL_UNLOCKED_KEY = 0x3456789012345678901234567890123456789012345678901234567890123456;

    /// STORAGE ///

    /// @notice The supported position token inside this isolated market.
    address public positionToken;

    /// @notice A list of all tokens inside this market for
    ///         offchain querying.
    address[] public tokensListed;

    /// MARKET STATE

    /// @notice Whether liquidations are paused.
    /// @dev 1 = unpaused; 2 = paused.
    uint256 public liquidationPaused = 1;
    /// @notice Whether mToken transfers are paused.
    /// @dev 1 = unpaused; 2 = paused.
    uint256 public transferPaused = 1;
    /// @notice Whether pToken liquidations are paused.
    /// @dev 1 = unpaused; 2 = paused.
    uint256 public seizePaused = 1;
    /// @notice Whether mToken redemptions are paused.
    /// @dev 1 = unpaused; 2 = paused.
    uint256 public redeemPaused = 1;
    /// @notice Whether mToken minting is paused.
    /// @dev Token => 0 or 1 = unpaused; 2 = paused.
    mapping(address => uint256) public mintPaused;
    /// @notice Whether pToken minting is paused.
    /// @dev Token => 0 or 1 = unpaused; 2 = paused.
    mapping(address => uint256) public collateralizationPaused;
    /// @notice Whether eToken borrowing is paused.
    /// @dev Token => 0 or 1 = unpaused; 2 = paused.
    mapping(address => uint256) public borrowPaused;

    /// @notice Amount of pToken that can be posted of collateral,
    ///         in shares.
    /// @dev Token => Market-wide Collateral Cap, in shares.
    mapping(address => uint256) public collateralCaps;

    /// @notice Amount of eToken underlying that can be borrowed,
    ///         in assets.
    /// @dev Token => Market-wide Debt Cap, in assets.
    mapping(address => uint256) public debtCaps;

    /// @notice Whether an address is an authorized position management
    ///         operator or not.
    /// @dev Address => Is an approved position management operator.
    mapping(address => bool) public positionManagement;

    /// EVENTS ///

    event TokenListed(address mToken);
    event PositionAdjusted(address mToken, address account, bool open);
    event PositionTokenUpdated(
        address mToken,
        uint256 collRatio,
        uint256 collReqSoft,
        uint256 collReqHard,
        uint256 liqIncBase,
        uint256 liqIncHard,
        uint256 liqIncMin,
        uint256 liqIncMax,
        uint256 minEffectiveCFactor,
        uint256 maxEffectiveCFactor,
        uint256 baseCFactor
    );
    event ActionPaused(string action, bool pauseState);
    event TokenActionPaused(address mToken, string action, bool pauseState);
    event CollateralCapUpdated(address mToken, uint256 newCollateralCap);
    event DebtCapUpdated(address mToken, uint256 newDebtCap);
    event NewPositionManagementContract(address newPositionManager);

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

    /// @notice Returns whether `mToken` is listed in the lending market.
    /// @param mToken market token address.
    function isListed(address mToken) external view returns (bool) {
        return tokenData[mToken].isListed;
    }

    /// @notice Returns the ratio at which `mToken` can be collateralized.
    /// @return Ratio returned in `WAD`, e.g. 0.8e18 = 80% collateral value.
    function collateralizationRatio(
        address mToken
    ) external view returns (uint256) {
        return tokenData[mToken].collRatio;
    }

    function queryTokensListed() external view returns (address[] memory) {
        return tokensListed;
    }

    /// ACCOUNT SPECIFIC FUNCTIONS ///

    /// @notice Returns the assets an account has entered.
    /// @param account The address of the account to pull assets for.
    /// @return A dynamic list with the assets the account has entered.
    function assetsOf(
        address account
    ) external view returns (IMToken[] memory) {
        return accountAssets[account].assets;
    }

    /// @notice Determine `account`'s current status between collateral,
    ///         debt, and additional liquidity.
    /// @param account The account to determine liquidity for.
    /// @return accountCollateral total collateral amount of account.
    /// @return maxDebt max borrow amount of account.
    /// @return accountDebt total borrow amount of account.
    function statusOf(
        address account
    ) external view returns (uint256, uint256, uint256) {
        return _statusOf(account);
    }

    /// @notice Determine `account`'s current collateral and debt values
    ///         in the market.
    /// @param account The account to check bad debt status for.
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
            accountData.accountCollateralSoft,
            accountData.accountCollateralHard,
            accountData.accountDebt
        );
    }

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
    )
        public
        view
        returns (
            uint256 lfactor,
            uint256 earnTokenPrice,
            uint256 positionTokenPrice
        )
    {
        (, lfactor, earnTokenPrice, positionTokenPrice) = _liquidationValuesOf(
            account,
            eToken,
            pToken
        );
    }

    /// @notice Determine what the account liquidity would be if
    ///         the given amounts were redeemed/borrowed.
    /// @dev Will natively revert if a hypothetical borrow will result in a
    ///      loan less than `MIN_ACTIVE_LOAN_SIZE`, set in `LiquidityManager`.
    /// @param account The account to determine liquidity for.
    /// @param mTokenModified The market to hypothetically redeem/borrow in.
    /// @param redeemTokens The number of tokens to hypothetically redeem.
    /// @param borrowAmount The amount of underlying to hypothetically borrow.
    /// @return Hypothetical account liquidity in excess of collateral
    ///         requirements.
    /// @return Hypothetical account liquidity deficit below collateral
    ///         requirements.
    function hypotheticalLiquidityOf(
        address account,
        address mTokenModified,
        uint256 redeemTokens, // in Shares.
        uint256 borrowAmount // in Assets.
    ) external view returns (uint256, uint256, bool[] memory) {
        // Make sure they are not trying to hypothetically borrow
        // a position token.
        if (IMToken(mTokenModified).isPToken() && borrowAmount > 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        (
            HypotheticalData memory result,
            bool[] memory positionsToClose
        ) = _hypotheticalLiquidityOf(
                account,
                HypotheticalAction({
                    mTokenModified: mTokenModified,
                    redeemTokens: redeemTokens,
                    borrowAmount: borrowAmount,
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
    /// @param mToken The market token to verify minting status for.
    function canMint(address mToken) external view {
        if (mintPaused[mToken] == 2) {
            _revert(_PAUSED_SELECTOR);
        }

        _checkIsListedToken(mToken);
    }

    /// @notice Checks if the account should be allowed to collateralize
    ///         their shares of the given market.
    ///         Prunes unused positions in `account` data.
    /// @dev May emit a {PositionAdjusted} event.
    /// @param pToken The position token to verify collateralization of.
    /// @param account The account which would collateralize the asset.
    /// @param newNetCollateral The amount of shares that would be
    ///                         collateralized in total if allowed.
    function canCollateralize(
        address pToken,
        address account,
        uint256 newNetCollateral
    ) external {
        _checkIsToken(pToken);
        _checkIsListedToken(pToken);

        if (collateralizationPaused[pToken] == 2) {
            _revert(_PAUSED_SELECTOR);
        }

        // This also acts as a check that the pToken is a pToken and 
        // collateralization ratio is > 0, since collateralCaps can only
        // be raised above zero if the token is a pToken and pToken's
        // collateralization ratio is > 0.
        if (newNetCollateral > collateralCaps[pToken]) {
            revert MarketManager__CapReached();
        }

        // On collateral posting:
        // We need to flip their cooldown flag to prevent flashloan attacks.
        accountAssets[account].cooldownTimestamp = block.timestamp;
        // If `account` does not have a position in `pToken`, open one.
        if (accountPositions[pToken][account] != 2) {
            accountPositions[pToken][account] = 2;
            accountAssets[account].assets.push(IMToken(pToken));

            emit PositionAdjusted(pToken, account, true);
        }
    }

    /// @notice Checks if the account should be allowed to redeem tokens
    ///         in the given market, and then redeems.
    /// @dev This can only be called by the mToken itself
    ///      (specifically pTokens, because eTokens are never collateral).
    /// @param mToken The market token to verify the redemption against.
    /// @param account The account which would redeem the tokens.
    /// @param balanceOf The current pToken share balance of `account`.
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
    ) external returns (uint256) {
        _checkIsToken(mToken);
        return _canRedeemWithCollateralRemoval(
            mToken,
            account,
            balanceOf,
            collateralPosted,
            amount,
            forceRedeemCollateral
        );
    }

    /// @notice Checks if the account should be allowed to redeem `amount`
    ///         of `mToken` in the given market state.
    /// @param mToken The market token to verify the redemption for.
    /// @param account The account which would redeem the tokens.
    /// @param amount The number of mTokens to exchange
    ///               for the underlying asset in the market.
    function canRedeem(
        address mToken,
        address account,
        uint256 amount
    ) external view {
        _canRedeem(mToken, account, amount);
    }

    /// @notice Checks if the account should be allowed to borrow
    ///         the underlying asset of the given market.
    ///         Prunes unused positions in `account` data.
    /// @dev May emit a {PositionAdjusted} event.
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
    ) external {
        _canBorrow(eToken, account, newNetDebt, amount);
    }

    /// @notice Checks if the account should be allowed to borrow
    ///         the underlying asset of the given market,
    ///         and notifies the market of the borrow.
    /// @dev This can only be called by the market itself.
    /// @param eToken The market token to verify the borrow for.
    /// @param account The account which would borrow the asset.
    /// @param newNetDebt The amount of assets that would be
    ///                   outstanding debt in total if allowed.
    /// @param amount The amount of underlying the account would borrow.
    function canBorrowWithNotify(
        address eToken,
        address account,
        uint256 newNetDebt,
        uint256 amount
    ) external {
        accountAssets[account].cooldownTimestamp = block.timestamp;
        _canBorrow(eToken, account, newNetDebt, amount);
    }

    /// @notice Updates `account` cooldownTimestamp to the current block timestamp.
    /// @dev The caller must be a listed MToken in the `markets` mapping.
    /// @param mToken The address of the eToken that the account is borrowing.
    /// @param account The address of the account that has just borrowed.
    function notifyBorrow(address mToken, address account) external {
        _checkIsToken(mToken);
        _checkIsListedToken(mToken);

        accountAssets[account].cooldownTimestamp = block.timestamp;
    }

    /// @notice Checks if the account should be allowed to repay a borrow
    ///         in the given market.
    /// @param mToken The market token to verify the repayment of.
    /// @param account The account who will have their loan repaid.
    function canRepay(address mToken, address account) external view {
        _checkIsListedToken(mToken);

        _checkHoldPeriod(account);
    }

    /// @notice Checks if the liquidation should be allowed to occur,
    ///         and returns how many position tokens should be seized
    ///         on liquidation.
    /// @param accounts The addresses of the accounts to be liquidated.
    /// @param debtAmounts The amounts of underlying asset the liquidator
    ///                    wishes to repay, empty if desired to max liquidate.
    /// @param instructions A LiqInstructions struct containing:
    ///               eToken Debt token to repay which is borrowed by
    ///                      `account`.
    ///               pToken Position token which was used as collateral
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
    ) external view returns (
        IMarketManager.LiqResults memory results,
        uint256[] memory
    ) {
        _checkIsToken(instructions.eToken);
        (
            CachedLiqData memory cachedData,
            AuctionLiqData memory auctionData
        ) =_getLiquidationConfig(instructions.eToken, instructions.pToken);

        address cachedAccount;
        // Amounts array is empty since the max amount possible
        // will be liquidated.
        results.liquidatedAmounts = new uint256[](instructions.numAccounts);
        for (uint256 i; i < instructions.numAccounts; ++i) {
            cachedAccount = accounts[i];
            if (liquidator == cachedAccount) {
                _revert(_UNAUTHORIZED_SELECTOR);
            }

            (
                instructions.eTokenRepaid,
                instructions.pTokenLiquidated,
                instructions.badDebt
                ) = _canLiquidate(
                cachedAccount,
                debtAmounts[i],
                cachedData,
                auctionData,
                instructions.liquidateExact
            );

            // If the user is being liquidated update relevant values.
            if (instructions.pTokenLiquidated > 0) {
                results.debtRepaid += instructions.eTokenRepaid;
                results.liquidatedAmounts[i] = instructions.pTokenLiquidated;

                if (instructions.badDebt > 0) {
                    results.badDebtRealized += instructions.badDebt;
                    // Add the bad debt to debt to remove from the liquidated
                    // account.
                    instructions.eTokenRepaid += instructions.badDebt;
                }

                // If its an exact liquidation this will be a redundant setter
                // but anticipation is majority of liquidators will use
                // non-exact so checking for liquidateExact each time is a
                // waste.
                debtAmounts[i] = instructions.eTokenRepaid;
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
    /// @param pToken pToken which was used as collateral
    ///               and will be seized.
    /// @param eToken eToken which was borrowed by the account
    ///               and will repaid.
    function canSeize(address pToken, address eToken) external view {
        if (seizePaused == 2) {
            _revert(_PAUSED_SELECTOR);
        }

        _checkIsListedToken(pToken);
        _checkIsListedToken(eToken);

        if (
            IMToken(pToken).marketManager() != IMToken(eToken).marketManager()
        ) {
            revert MarketManager__MarketManagerMismatch();
        }
    }

    /// @notice Checks if the account should be allowed to transfer collateral
    ///         tokens in the given market.
    /// @param mToken The market token to verify the transfer of.
    /// @param from The account which will transfer the tokens.
    /// @param balanceOf The current pToken share balance of `account`.
    /// @param collateralPosted The current mToken shares posted as
    ///                         collateral by `account`.
    /// @param amount The number of mTokens to transfer.
    function canTransferPToken(
        address mToken,
        address from,
        uint256 balanceOf,
        uint256 collateralPosted,
        uint256 amount
    ) external returns (uint256) {
        _checkIsToken(mToken);
        if (transferPaused == 2) {
            _revert(_PAUSED_SELECTOR);
        }

        return _canRedeemWithCollateralRemoval(
            mToken,
            from,
            balanceOf,
            collateralPosted,
            amount,
            false
        );
        
    }

    /// @notice Checks if the account should be allowed to transfer debt
    ///         tokens in the given market.
    /// @param mToken The market token to verify the transfer of.
    /// @param from The account which will transfer the tokens.
    /// @param amount The number of mTokens to transfer.
    function canTransferEToken(
        address mToken,
        address from,
        uint256 amount
    ) external {
        _checkIsToken(mToken);

        if (transferPaused == 2) {
            _revert(_PAUSED_SELECTOR);
        }

        (
            uint256 positionClosureNeeded,
            bool[] memory positionsToClose
        ) = _canRedeem(mToken, from, amount);

        _closePositionsIfNeeded(positionClosureNeeded, from, positionsToClose);
    }

    /// PERMISSIONED EXTERNAL FUNCTIONS ///

    /// @notice Add isolated market token pair to the market and set it as
    ///         listed.
    /// @dev Admin function to set isListed for token pair and add support
    ///      for the market. Only callable once due to isolated market design.
    ///      Emits two {TokenListed} events.
    /// @param pToken The address of the market position token to list.
    /// @param eToken The address of the market earn token to list.
    function listTokens(address pToken, address eToken) external {
        _checkDaoPermissions();

        uint256 numTokens = tokensListed.length;
        if (numTokens != 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        if (!IMToken(pToken).isPToken() ||  IMToken(eToken).isPToken()) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // List the tokens.
        tokenData[pToken].isListed = true;
        tokenData[eToken].isListed = true;

        // Immediately deposit into the market to prevent any rounding
        // exploits.
        if (!IMToken(pToken).startMarket(msg.sender)) {
            _revert(_INVARIANT_ERROR_SELECTOR);
        }
        if (!IMToken(eToken).startMarket(msg.sender)) {
            _revert(_INVARIANT_ERROR_SELECTOR);
        }

        // Redundantly store position token address for dynamic penalty
        // checks.
        positionToken = pToken;

        // No need to check whether tokens were listed before since this
        // function can only be called once due to numTokens == 0 check.

        // Update frontend array/emit events.
        tokensListed.push(pToken);
        emit TokenListed(pToken);
        tokensListed.push(eToken);
        emit TokenListed(eToken);
    }

    /// @notice Sets market liquidity configuration values for a position
    ///         token inside this market.
    /// @dev Emits a {PositionTokenUpdated} event.
    /// @param collRatio The ratio at which $1 of collateral can be borrowed
    ///                  against, for `pToken`, in basis points.
    /// @param collReqSoft The premium of excess collateral required to
    ///                    avoid soft liquidation, in basis points.
    /// @param collReqHard The premium of excess collateral required to
    ///                    avoid hard liquidation, in basis points.
    /// @param liqIncBase The default liquidation incentive for
    ///                   `positionToken`, in basis points.
    /// @param liqIncHard The hard liquidation incentive for `pToken`,
    ///                   in basis points.
    /// @param liqIncMin The minimum possible liquidation incentive for
    ///                  `positionToken`, in basis points.
    /// @param liqIncMax The maximum possible liquidation incentive for
    ///                  `positionToken`, in basis points.
    function updatePositionToken(
        uint256 collRatio,
        uint256 collReqSoft,
        uint256 collReqHard,
        uint256 liqIncBase,
        uint256 liqIncHard,
        uint256 liqIncMin,
        uint256 liqIncMax,
        uint256 minEffectiveCloseFactor,
        uint256 maxEffectiveCloseFactor,
        uint256 baseCFactor
    ) external {
        _checkElevatedPermissions();

        // Convert the parameters from basis points to `WAD` format.
        // While inefficient, we want to minimize potential human error
        // as much as possible, even if it costs a bit extra gas on config.
        collRatio = _bpToWad(collRatio);
        collReqSoft = _bpToWad(collReqSoft);
        collReqHard = _bpToWad(collReqHard);
        liqIncBase = _bpToWad(liqIncBase);
        liqIncHard = _bpToWad(liqIncHard);
        liqIncMin = _bpToWad(liqIncMin);
        liqIncMax = _bpToWad(liqIncMax);
        baseCFactor = _bpToWad(baseCFactor);
        minEffectiveCloseFactor = _bpToWad(minEffectiveCloseFactor);
        maxEffectiveCloseFactor = _bpToWad(maxEffectiveCloseFactor);

        // Validate collateralization ratio is not above the maximum allowed.
        if (collRatio > MAX_COLLATERALIZATION_RATIO) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate soft liquidation collateral requirement is
        // not above the maximum allowed.
        if (collReqSoft > MAX_COLLATERAL_REQUIREMENT) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate hard liquidation collateral requirement is not above
        // the soft liquidation requirement. Liquidations occur when
        // collateral dries up so hard liquidation should be less collateral
        // than soft liquidation.
        if (collReqHard >= collReqSoft) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate hard liquidation incentive is
        // higher than the soft liquidation incentive. Give heavier incentives
        // when collateral is running out to reduce delta exposure.
        if (liqIncBase >= liqIncHard) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Make sure the maximum dynamic penalty is not greater than the base
        // liquidation incentive and that the minimum dynamic penalty is not
        // less than the base liquidation incentive.
        if (liqIncBase > liqIncMax || liqIncBase < liqIncMin) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate hard liquidation incentive is
        // not above the maximum allowed.
        if (liqIncMax > MAX_LIQUIDATION_INCENTIVE) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate maximum liquidation incentive and default is
        // equal or higher than the minimum liquidation incentive.
        if (liqIncMin >= liqIncMax) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate hard liquidation collateral requirement is larger
        // than the hard liquidation incentive. We cannot give more incentives
        // than are available. We do not need to check soft liquidation as the
        // restrictions are thinner than this case.
        if (liqIncHard + MIN_EXCESS_COLLATERAL_REQUIREMENT > collReqHard) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate hard liquidation collateral requirement is larger
        // than the hard liquidation incentive. We cannot give more incentives
        // than are available. We do not need to check soft liquidation as the
        // restrictions are thinner than this case.
        if (liqIncMax + MIN_EXCESS_COLLATERAL_REQUIREMENT > collReqHard) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate that soft liquidation is within acceptable bounds.
        if (baseCFactor > MAX_BASE_CFACTOR || baseCFactor < MIN_BASE_CFACTOR) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate the soft liquidation collateral premium
        // is not more strict than the asset's CR.
        if (collRatio > (WAD_SQUARED / (WAD + collReqSoft))) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Cache positionToken storage address.
        address pToken = positionToken;
        MarketToken storage marketToken = tokenData[pToken];

        // If this token already has collateralization enabled,
        // we cannot turn collateralization off completely as this
        // would cause downstream effects to the DLE.
        if (marketToken.collRatio != 0 && collRatio == 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        (, uint256 errorCode) = IOracleManager(centralRegistry.oracleManager())
            .getPrice(pToken, true, true);

        // Validate that we get a usable price.
        if (errorCode == 2) {
            revert MarketManager__PriceError();
        }

        // Assign new collateralization ratio.
        // Note that a collateralization ratio of 0 corresponds to
        // no collateralization of the pToken.
        marketToken.collRatio = collRatio;

        // Store the collateral requirement as a premium above `WAD`,
        // that way we can calculate solvency via division
        // efficiently in _liquidationStatusOf.
        marketToken.collReqSoft = collReqSoft + WAD;
        marketToken.collReqHard = collReqHard + WAD;

        // We use the liquidation incentive values as a premium in
        // `calculateLiquidatedTokens`, so it needs to be 1 + incentive.
        marketToken.liqBaseIncentive = WAD + liqIncBase;
        marketToken.liqMinIncentive = WAD + liqIncMin;
        marketToken.liqMaxIncentive = WAD + liqIncMax;

        // Store the distance between liquidation incentive A & B,
        // so we can quickly scale between [base, 100%] based on lFactor.
        marketToken.liqCurve = liqIncHard - liqIncBase;

        // Assign the base cFactor
        marketToken.baseCFactor = baseCFactor;
        // Store the distance between base cFactor and 100%,
        // that way we can quickly scale between [base, 100%] based on lFactor.
        marketToken.cFactorCurve = WAD - baseCFactor;

        // Assign the min and max effective closeFactor
        marketToken.minEffectiveCloseFactor = minEffectiveCloseFactor;
        marketToken.maxEffectiveCloseFactor = maxEffectiveCloseFactor;

        emit PositionTokenUpdated(
            pToken,
            collRatio,
            collReqSoft,
            collReqHard,
            liqIncBase,
            liqIncHard,
            liqIncMin,
            liqIncMax,
            minEffectiveCloseFactor,
            maxEffectiveCloseFactor,
            baseCFactor
        );
    }

    /// @notice Set `newCollateralizationCaps` for the given `pTokens`.
    /// @dev Can emit {NewCollateralCap} event(s).
    /// @param pTokens The addresses of the tokens to change the collateral
    ///                caps for.
    /// @param newCollateralCaps The new collateral cap values to be
    ///                          set, in shares.
    function setCollateralCaps(
        address[] calldata pTokens,
        uint256[] calldata newCollateralCaps
    ) external {
        _checkDaoPermissions();

        uint256 numTokens = pTokens.length;

        /// @solidity memory-safe-assembly
        assembly {
            if iszero(numTokens) {
                // store the error selector to location 0x0.
                mstore(0x0, _INVALID_PARAMETER_SELECTOR)
                // return bytes 29-32 for the selector.
                revert(0x1c, 0x04)
            }
        }

        if (numTokens != newCollateralCaps.length) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        for (uint256 i; i < numTokens; ++i) {
            // Do not let people collateralize assets
            // with a collateralization ratio of 0.
            if (tokenData[pTokens[i]].collRatio == 0) {
                _revert(_INVALID_PARAMETER_SELECTOR);
            }

            collateralCaps[pTokens[i]] = newCollateralCaps[i];
            emit CollateralCapUpdated(pTokens[i], newCollateralCaps[i]);
        }
    }

    /// @notice Set `newDebtCaps` for the given `eTokens`.
    /// @dev Can emit {NewDebtCap} event(s).
    /// @param eTokens The addresses of the tokens to change the
    ///                debt caps for.
    /// @param newDebtCaps The new collateral cap values to be
    ///                          set, in assets.
    function setDebtCaps(
        address[] calldata eTokens,
        uint256[] calldata newDebtCaps
    ) external {
        _checkDaoPermissions();

        uint256 numTokens = eTokens.length;

        /// @solidity memory-safe-assembly
        assembly {
            if iszero(numTokens) {
                // store the error selector to location 0x0.
                mstore(0x0, _INVALID_PARAMETER_SELECTOR)
                // return bytes 29-32 for the selector.
                revert(0x1c, 0x04)
            }
        }

        if (numTokens != newDebtCaps.length) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        for (uint256 i; i < numTokens; ++i) {
            // Do not let people borrow assets if they are not intended to be.
            if (!IMToken(eTokens[i]).isBorrowable()) {
                _revert(_INVALID_PARAMETER_SELECTOR);
            }

            debtCaps[eTokens[i]] = newDebtCaps[i];
            emit DebtCapUpdated(eTokens[i], newDebtCaps[i]);
        }
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

    /// @notice Admin function to set market token mint status.
    /// @dev Requires timelock authority if unpausing.
    ///      Emits a {TokenActionPaused} event.
    /// @param mToken The market token to set minting status for.
    /// @param state Whether the desired action is pausing or unpausing.
    function setMintPaused(address mToken, bool state) external {
        _checkAuthorizedPermissions(state);
        _checkIsListedToken(mToken);

        mintPaused[mToken] = state ? 2 : 1;
        emit TokenActionPaused(mToken, "Mint Paused", state);
    }

    /// @notice Admin function to set market token collateralization status.
    /// @dev Requires timelock authority if unpausing.
    ///      Emits a {TokenActionPaused} event.
    /// @param mToken The market token to set minting status for.
    /// @param state Whether the desired action is pausing or unpausing.
    function setCollateralizationPaused(address mToken, bool state) external {
        _checkAuthorizedPermissions(state);
        _checkIsListedToken(mToken);

        collateralizationPaused[mToken] = state ? 2 : 1;
        emit TokenActionPaused(mToken, "Collateralization Paused", state);
    }

    /// @notice Admin function to set market token borrow status.
    /// @dev Requires timelock authority if unpausing.
    ///      Emits a {TokenActionPaused} event.
    /// @param mToken The market token to set borrowing status for.
    /// @param state Whether the desired action is pausing or unpausing.
    function setBorrowPaused(address mToken, bool state) external {
        _checkAuthorizedPermissions(state);
        _checkIsListedToken(mToken);

        borrowPaused[mToken] = state ? 2 : 1;
        emit TokenActionPaused(mToken, "Borrow Paused", state);
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

    /// @notice Used to set the position folding address to allow
    ///         complex position actions.
    /// @dev Requires timelock authority.
    ///      Emits a {NewPositionManagementContract} event.
    /// @param newPositionManagement The new position management address.
    function setPositionManagement(address newPositionManagement) external {
        _checkElevatedPermissions();

        if (
            !ERC165Checker.supportsInterface(
                newPositionManagement,
                type(IPositionManagement).interfaceId
            )
        ) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Assign new position folding contract.
        positionManagement[newPositionManagement] = true;

        emit NewPositionManagementContract(newPositionManagement);
    }

    /// @notice Called from the Atlas DappControl as a post hook
    ///         after liquidations are tried to enable all 
    ///         collateral to be liquidated outside Atlas tx.
    function lockAtlasCollateral() external {
        _checkAtlasPermissions();

        /// @solidity memory-safe-assembly
        assembly {
            tstore(_TRANSIENT_COLLATERAL_UNLOCKED_KEY, 0)
        }
    }

    /// @notice Called from the Atlas DappControl as a pre hook
    ///         before liquidations are tried to enforce that 
    ///         only a specific collateral can be liquidated.
    function unlockAtlasCollateral(address collateralToUnlock) external {
        uint256 collateralToUnlockUint = uint256(uint160(collateralToUnlock));
        _checkAtlasPermissions();

        /// @solidity memory-safe-assembly
        assembly {
            tstore(_TRANSIENT_COLLATERAL_UNLOCKED_KEY, collateralToUnlockUint)
        }
    }

    /// @notice Sets new dynamic close factor and liquidation penalty
    ///         values in transient storage.
    /// @dev Transient storage enforces any liquidator outside Atlas
    ///      uses the default risk parameters.
    /// @param newPenalty The new penalty value.
    function setAtlasParameters(
        uint256 newPenalty,
        uint256 newCloseFactor
    ) external {
        _checkAtlasPermissions();

        // Validate new Liquidation Penalty value. 
        MarketToken storage pToken = tokenData[positionToken];
        // Validate new penalty is within configured allowed penalty.
        if (newPenalty < pToken.liqMinIncentive || newPenalty > pToken.liqMaxIncentive) {
            revert MarketManager__InvalidParameter();
        }

        // Validate new Close Factor value.
        if (
            newCloseFactor < pToken.minEffectiveCloseFactor ||
            newCloseFactor > pToken.maxEffectiveCloseFactor
            ) {
            revert MarketManager__InvalidParameter();
        }

        // Set new Risk Parameters in transient storage. 
        // tstore(key, value): store `newPenalty` under TRANSIENT_PENALTY_KEY.
        /// @solidity memory-safe-assembly
        assembly {
            tstore(_TRANSIENT_PENALTY_KEY, newPenalty)
        }

        // tstore(key, value): store `newCloseFactor` under TRANSIENT_CLOSE_FACTOR_KEY.
        /// @solidity memory-safe-assembly
        assembly {
            tstore(_TRANSIENT_CLOSE_FACTOR_KEY, newCloseFactor)
        }
    }

    /// @notice Resets the Atlas risk parameters in transient storage to zero.
    ///         This is redundant since the transient values will be reset 
    ///         after an Atlas tx, but helps to ensure expected behaviour. 
    function resetAtlasParameters() external {
        _checkAtlasPermissions();

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

    /// @notice Returns the current Atlas parameters in an active transaction.
    /// @dev If a dynamic penalty or close factor is set in transient storage,
    ///      that value is returned; otherwise, the default penalty or close
    ///      factor is returned.
    ///      NOTE: caller must handle the case where the
    ///      TRANSIENT_CLOSE_FACTOR_KEY is empty, and zero is returned.
    function getLatestAtlasParameters() public view returns (
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
    ///      May emit a {PositionAdjusted} event.
    /// @param eToken The debt token to verify the borrow of.
    /// @param account The account which would borrow the asset.
    /// @param newNetDebt The amount of assets that would be
    ///                   outstanding debt in total if allowed. 
    /// @param amount The amount of underlying the account would borrow.
    function _canBorrow(
        address eToken,
        address account,
        uint256 newNetDebt,
        uint256 amount
    ) internal {
        _checkIsToken(eToken);
        _checkIsListedToken(eToken);

        if (borrowPaused[eToken] == 2) {
            _revert(_PAUSED_SELECTOR);
        }

        // Validates that this borrow action will not push net debt
        // above the debt limit.
        if (newNetDebt > debtCaps[eToken]) {
            revert MarketManager__CapReached();
        }

        // Check if the user already has an active borrow in the eToken.
        if (accountPositions[eToken][account] != 2) {
            // The account does not have an active borrow in the eToken,
            // so update this so borrow position is monitored in liquidity
            // checks.
            accountPositions[eToken][account] = 2;
            accountAssets[account].assets.push(IMToken(eToken));

            emit PositionAdjusted(eToken, account, true);
        }

        // Check if the user has sufficient liquidity to borrow,
        // with heavier error code scrutiny.
        (
            HypotheticalData memory result,
            bool[] memory positionsToClose
        ) = _hypotheticalLiquidityOf(
                account,
                HypotheticalAction({
                    mTokenModified: eToken,
                    redeemTokens: 0,
                    borrowAmount: amount,
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
    ///         to redeem `amount` of `mToken` in the given market state.
    /// @param mToken The market token to verify the redemption of.
    /// @param account The account which would redeem the tokens.
    /// @param amount The number of `mToken` to redeem for
    ///               the underlying asset in the market.
    function _canRedeem(
        address mToken,
        address account,
        uint256 amount
    ) internal view returns (uint256, bool[] memory) {
        if (redeemPaused == 2) {
            _revert(_PAUSED_SELECTOR);
        }

        _checkIsListedToken(mToken);

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
        // This will result in skipping a liquidity check for eToken
        // redemptions because active positions are not given for lent
        // positions.
        if (accountPositions[mToken][account] != 2) {
            bool[] memory emptyPositions;
            return (0, emptyPositions);
        }

        // Check account liquidity with hypothetical mToken redemption.
        (
            HypotheticalData memory result,
            bool[] memory positionsToClose
        ) = _hypotheticalLiquidityOf(
                account,
                HypotheticalAction({
                    mTokenModified: mToken,
                    redeemTokens: amount,
                    borrowAmount: 0,
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
    /// @dev This can only be called by the mToken itself
    ///      (specifically pTokens, because eTokens are never collateral).
    /// @param pToken The position token to verify the redemption against.
    /// @param account The account which would redeem the tokens.
    /// @param balanceOf The current mToken share balance of `account`.
    /// @param collateralPosted The current mToken shares posted as
    ///                         collateral by `account`.
    /// @param amount The number of pToken shares to redeem for the
    ///               underlying asset in the market.
    /// @param forceRedeemCollateral Whether the collateral should be always
    ///                              reduced.
    function _canRedeemWithCollateralRemoval(
        address pToken,
        address account,
        uint256 balanceOf,
        uint256 collateralPosted,
        uint256 amount,
        bool forceRedeemCollateral
    ) internal returns (uint256 collateralToRemove) {
        // If collateral is being directly removed by user intention,
        // or liquidation we can skip balance checks.
        if (forceRedeemCollateral) {
            collateralToRemove = amount;
        } else {
            // If they want to redeem more pTokens than they have idle,
            // calculate how much collateral will be redeemed from
            // the delta. Otherwise collateralToRemove default value of 0
            // is correct.
            if (collateralPosted + amount >= balanceOf) {
                collateralToRemove = collateralPosted + amount - balanceOf;
            }
        }

        // Validate that the collateral being removed is allowed.
        if (collateralToRemove > 0) {
            (
                uint256 positionClosureNeeded,
                bool[] memory positionsToClose
            ) = _canRedeem(pToken, account, collateralToRemove);
            _closePositionsIfNeeded(
                positionClosureNeeded,
                account,
                positionsToClose
            );
        } else {
            _checkIsListedToken(pToken);

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
    ///                   pToken The address of the position token
    ///                          (collateral token) involved in the
    ///                          liquidation.
    ///                   eToken The address of the earn token (debt token)
    ///                          involved in the liquidation.
    ///                   pTokenExchangeRate The exchange rate of pToken's
    ///                                      underlying token to the pToken
    ///                                      itself.
    ///                   pTokenCollReqSoft The collateral requirement where
    ///                                     dipping below this will cause a
    ///                                     soft liquidation.
    ///                   pTokenCollReqHard The collateral requirement where
    ///                                     dipping below this will cause a
    ///                                     hard liquidation.
    ///                   pTokenUnderlyingPrice The current price of the
    ///                                         underlying token of the
    ///                                         pToken.
    ///                   pTokenDecimals The decimals that `pToken` is
    ///                                  measured in.
    ///                   eTokenDecimals The decimals that `eToken` is
    ///                                  measured in.
    ///                   eTokenUnderlyingPrice The current price of the
    ///                                         underlying token of the
    ///                                         eToken.
    ///                   auctionBuffer The current buffer that
    ///                                 accountCollateralSoft is multiplied
    ///                                 against, 10 bps or 0 if not an
    ///                                 auction liquidation.
    /// @param auctionData An AuctionLiqData struct containing:
    ///                    lFactor Empty variable to hold an account's
    ///                            liquidation factor later.
    ///                    debtBalance Empty variable to hold an account's
    ///                                debt's active debt to `eToken` later.
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
    /// @return uint256 The actual amount of debt that will be liquidated.
    /// @return liquidatedPTokens The amount of position tokens (pTokens) that
    ///                           will be seized as collateral.
    /// @return badDebt The amount of bad debt to recognize as part of the
    ///                 liquidation (if any).
    function _canLiquidate(
        address account,
        uint256 debtAmount,
        CachedLiqData memory cachedData,
        AuctionLiqData memory auctionData,
        bool liquidateExact
    ) internal view returns (
        uint256,
        uint256 liquidatedPTokens,
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
        
        // Get the exchange rate, and calculate the number of
        // position tokens to seize.
        uint256 debtToCollateralMultiplier =
            (((auctionData.auctionLiqIncentive * cachedData.eTokenUnderlyingPrice * WAD) /
            (cachedData.pTokenUnderlyingPrice * cachedData.pTokenExchangeRate)) *
            cachedData.pTokenDecimals) / cachedData.eTokenDecimals;
        uint256 maxAmount =
            (auctionData.auctionCFactor * auctionData.debtBalance) / WAD;
        // If they want to liquidate an exact amount, liquidate `debtAmount`,
        // otherwise liquidate the maximum amount possible.
        if (!liquidateExact) {
            debtAmount = maxAmount;
        }
        
        // Calculate how many pTokens should be liquidated, adjusting decimals
        // if necessary.
        liquidatedPTokens = (debtAmount * debtToCollateralMultiplier) / WAD;

        // Cache `account`'s collateral posted of `pToken`.
        uint256 collateralAvailable = IPToken(
            cachedData.pToken
        ).collateralPosted(account);

        // If the user wants to liquidate an exact amount, make sure theres
        // enough collateral available to liquidate, otherwise
        // liquidate as much as possible.
        if (liquidateExact) {
            if (
                debtAmount > maxAmount ||
                liquidatedPTokens > collateralAvailable
            ) {
                // Make sure that the liquidation limit,
                // and collateral posted >= amount.
                _revert(_INVALID_PARAMETER_SELECTOR);
            }
        } else {
            if (liquidatedPTokens > collateralAvailable) {
                debtAmount = FixedPointMathLib.mulDivUp(
                    debtAmount,
                    collateralAvailable,
                    liquidatedPTokens
                );
                liquidatedPTokens = collateralAvailable;
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
                ((collateralAvailable - liquidatedPTokens) * cachedData.pTokenExchangeRate) / WAD,
                cachedData.pTokenUnderlyingPrice,
                (cachedData.eTokenUnderlyingPrice * WAD) / cachedData.eTokenDecimals
            );
        }

        // Calculate the maximum amount of debt that can be liquidated
        // and what collateral will be received. As well as any bad debt
        // to recognize.
        return (debtAmount, liquidatedPTokens, badDebt);
    }

    /// @notice Retrieves and caches liquidation configuration data for a
    ///         given token pair.
    /// @param eToken The address of the earn token (debt token) involved
    ///               in the liquidation.
    /// @param pToken The address of the position token (collateral token)
    ///               involved in the liquidation.
    /// @return cachedData A CachedLiqData struct containing:
    ///                    pToken The address of the position token
    ///                           (collateral token) involved in the
    ///                           liquidation.
    ///                    eToken The address of the earn token (debt token)
    ///                           involved in the liquidation.
    ///                    pTokenExchangeRate The exchange rate of pToken's
    ///                                       underlying token to the pToken
    ///                                       itself.
    ///                    pTokenCollReqSoft The collateral requirement where
    ///                                      dipping below this will cause a
    ///                                      soft liquidation.
    ///                    pTokenCollReqHard The collateral requirement where
    ///                                      dipping below this will cause a
    ///                                      hard liquidation.
    ///                    pTokenUnderlyingPrice The current price of the
    ///                                          underlying token of the
    ///                                          pToken.
    ///                    pTokenDecimals The decimals that `pToken` is
    ///                                   measured in.
    ///                    eTokenDecimals The decimals that `eToken` is
    ///                                   measured in.
    ///                    eTokenUnderlyingPrice The current price of the
    ///                                          underlying token of the
    ///                                          eToken.
    ///                    auctionBuffer The current buffer that
    ///                                  accountCollateralSoft is multiplied
    ///                                  against, 10 bps or 0 if not an
    ///                                  auction liquidation.
    /// @return auctionData An AuctionLiqData struct containing:
    ///                     lFactor Empty variable to hold an account's
    ///                             liquidation factor later.
    ///                     debtBalance Empty variable to hold an account's
    ///                                 debt's active debt to `eToken` later.
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
        address eToken,
        address pToken
    ) internal view returns (
        CachedLiqData memory cachedData,
        AuctionLiqData memory auctionData
    ) {
        _checkIsListedToken(eToken);
        _checkIsListedToken(pToken);

        MarketToken memory pTokenData = tokenData[pToken];
        // Do not let people liquidate 0 collateralization ratio assets.
        if (pTokenData.collRatio == 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Liquidations are only blocked if an error code of 2 (NO_SOURCE)
        // is calculated.
        (
            cachedData.eTokenUnderlyingPrice,
            cachedData.pTokenUnderlyingPrice
        ) = IOracleManager(
            centralRegistry.oracleManager()
        ).getPriceIsolatedPair(eToken, pToken, 2);

        // Cache all variables needed for computing liquidation levels and
        // compress into one struct for stack too deep limits.
        cachedData.pToken = pToken;
        cachedData.pTokenExchangeRate = IPToken(pToken).exchangeRateCached();
        cachedData.pTokenCollReqSoft = tokenData[pToken].collReqSoft;
        cachedData.pTokenCollReqHard = tokenData[pToken].collReqHard;
        cachedData.pTokenDecimals = 10 ** IERC20(pToken).decimals();
        cachedData.eToken = eToken;
        cachedData.eTokenDecimals = 10 ** IERC20(eToken).decimals();

        // Will revert if during auction transaction and liquidator has chosen
        // incorrect collateral.
        cachedData.auctionBuffer = _checkCollateralUnlocked(eToken);
        // Pull transient storage variables from auctioneer updates.
        (
            auctionData.auctionLiqIncentive,
            auctionData.auctionCFactor
        ) = getLatestAtlasParameters();

        // We only need to read storage and cache these variables if we did
        // not receive cFactor/liqIncentive from the auction.
        if (auctionData.auctionCFactor == 0) {
            auctionData.baseCFactor = pTokenData.baseCFactor;
            auctionData.cFactorCurve = pTokenData.cFactorCurve;
        }

        if (auctionData.auctionLiqIncentive == 0) {
            auctionData.liqBaseIncentive = pTokenData.liqBaseIncentive;
            auctionData.liqCurve = pTokenData.liqCurve;
        }
    }

    /// @notice Helper function for closing user positions after liquidity
    ///         checks have been passed.
    /// @dev Used as sort of a garbage collection system for any user
    ///      positions that should be closed to optimize future liquidity
    ///      checks. May emit {PositionAdjusted} events.
    /// @param positionsClosureNeeded Whether closing positions is needed
    ///                               for `account`.
    /// @param account The address of the account to close a
    ///                `mToken` position for.
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
        IMToken[] memory userAssets = accountAssets[account].assets;

        // Cache asset array characteristics.
        uint256 numAssets = userAssets.length;
        uint256 lastAssetIndex = userAssets.length - 1;
        address cachedToken;

        // Copy last item in list to location of item to be removed.
        IMToken[] storage storedAssets = accountAssets[account].assets;

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
                    // Remove the last element to remove `mToken` from
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

                cachedToken = address(userAssets[i]);

                // Remove `mToken` account position flag.
                accountPositions[cachedToken][account] = 1;
                emit PositionAdjusted(cachedToken, account, false);
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

    /// @dev Checks whether the caller is the Central Registry.
    function _checkIsCentralRegistry() internal view {
        if (msg.sender != address(centralRegistry)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }
    }

    /// @notice Multiplies `value` by 1e14 to convert it from `basis points`
    ///         to WAD.
    /// @dev Internal helper function for easily converting between scalars.
    function _bpToWad(uint256 value) internal pure returns (uint256) {
        return value * 1e14;
    }

    /// @dev Checks whether the caller has sufficient permissioning.
    function _checkDaoPermissions() internal view {
        if (!centralRegistry.hasDaoPermissions(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }
    }

    /// @dev Checks whether the caller has sufficient permissions.
    function _checkElevatedPermissions() internal view {
        if (!centralRegistry.hasElevatedPermissions(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }
    }

    /// @dev Checks whether the caller has sufficient permissioning.
    function _checkAtlasPermissions() internal view {
        if (!centralRegistry.hasAtlasPermissions(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }
    }

    /// @dev Checks whether the caller has sufficient permissions based on `state`,
    /// turning something off is less "risky" than enabling something,
    /// so `state` = true has reduced permissioning compared to `state` = false.
    function _checkAuthorizedPermissions(bool state) internal view {
        if (state) {
            _checkDaoPermissions();
            return;
        }

        _checkElevatedPermissions();
    }

    /// @dev Checks whether the caller is the desired mToken contract.
    function _checkIsToken(address mToken) internal view {
        /// @solidity memory-safe-assembly
        assembly {
            // Equal to if (msg.sender != mToken)
            if iszero(eq(caller(), mToken)) {
                mstore(0x00, _UNAUTHORIZED_SELECTOR)
                // Return bytes 29-32 for the selector.
                revert(0x1c, 0x04)
            }
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

    /// @notice Will revert and block liquidations of collateral that are not
    ///         currently allowed by Atlas, only if this is an Atlas tx.
    function _checkCollateralUnlocked(
        address eTokenToLiquidate
    ) internal view returns (uint256) {
        uint256 result;
        /// @solidity memory-safe-assembly
        assembly {
            result := tload(_TRANSIENT_COLLATERAL_UNLOCKED_KEY)
        }

        // CASE: This is not an Atlas tx, so allow all collaterals,
        // and return no buffer. 
        if (result == 0) {
            return 0;
        }

        address unlockedCollateral = address(uint160(result));

        // This is an Atlas tx, and Atlas liquidator attempted wrong
        // collateral so revert.
        if (unlockedCollateral != eTokenToLiquidate) {
            _revert(_UNAUTHORIZED_COLLATERAL_SELECTOR);
        }

        // if we reach this point this is an Atlas tx and collateral is valid,
        // so return the atlas buffer. 
        return AUCTION_BUFFER;
    }
}