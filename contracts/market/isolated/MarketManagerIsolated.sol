// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { LiquidityManager } from "contracts/market/isolated/LiquidityManagerIsolated.sol";
import { Multicall } from "contracts/libraries/Multicall.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { WAD, WAD_SQUARED } from "contracts/libraries/Constants.sol";
import { ERC165 } from "contracts/libraries/external/ERC165.sol";
import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { IMToken } from "contracts/interfaces/IMToken.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";
import { IPositionManagement } from "contracts/interfaces/IPositionManagement.sol";
import { IActionRegistry } from "contracts/interfaces/IActionRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IEToken } from "contracts/interfaces/IEToken.sol";
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
    LiquidityManager,
    ERC165,
    Multicall
{
    /// CONSTANTS ///

    /// @dev A fixed key to use in transient storage for the dynamic penalty.
    bytes32 constant TRANSIENT_PENALTY_KEY = 0xd033e44c9f2a65a460c9f878712895054941eb772c7716e6dee8b66c21be9561;
    /// @dev A fixed key to use in transient storage for Atlas OEV status
    bytes32 internal constant TRANSIENT_ATLAS_OEV_KEY = 0x1234567890123456789012345678901234567890123456789012345678901234;
    /// @dev A fixed key to use in transient storage for dynamic close factor
    bytes32 internal constant TRANSIENT_CLOSE_FACTOR_KEY = 0x2345678901234567890123456789012345678901234567890123456789012345;
    /// @dev A fixed key to use in transient storage for collateral tracking
    bytes32 internal constant TRANSIENT_COLLATERAL_UNLOCKED_KEY = 0x3456789012345678901234567890123456789012345678901234567890123456;
    /// @notice Maximum collateral requirement to avoid liquidation.
    ///         2.34e18 = 234%. Resulting in 1 / (WAD + 2.34 WAD),
    ///         or ~30% maximum LTV soft liquidation level.
    uint256 public constant MAX_COLLATERAL_REQUIREMENT = 2.34e18;
    /// @notice Minimum excess collateral requirement
    ///         on top of liquidation incentive.
    /// @dev .015e18 = 1.5%.
    uint256 public constant MIN_EXCESS_COLLATERAL_REQUIREMENT = .015e18;
    /// @notice Maximum collateralization ratio.
    /// @dev .91e18 = 91%.
    uint256 public constant MAX_COLLATERALIZATION_RATIO = .91e18;
    /// @notice The maximum liquidation incentive.
    /// @dev .3e18 = 30%.
    uint256 public constant MAX_LIQUIDATION_INCENTIVE = .3e18;
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

    /// STORAGE ///

    /// @notice The supported position token inside this isolated market.
    address public positionToken;

    /// @notice A list of all tokens inside this market for
    ///         offchain querying.
    address[] public tokensListed;

    /// @notice Whether an address is an authorized position management
    ///         operator or not.
    /// @dev Address => Is an approved position management operator.
    mapping(address => bool) public positionManagement;

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
    /// @notice Whether eToken borrowing is paused.
    /// @dev Token => 0 or 1 = unpaused; 2 = paused.
    mapping(address => uint256) public borrowPaused;

    /// COLLATERAL POSTING INVARIANTS

    /// @notice Amount of pToken that has been posted as collateral,
    ///         in shares.
    /// @dev Token => Collateral Posted.
    mapping(address => uint256) public collateralPosted;
    /// @notice Amount of pToken that can be posted of collateral, in shares.
    /// @dev Token => Collateral Cap, in shares.
    mapping(address => uint256) public collateralCaps;

    // Atlas OEV DAppControl
    mapping(address => bool) public hasAtlasPermissions;

    /// EVENTS ///

    event TokenListed(address mToken);
    event CollateralAdjusted(
        address account,
        address pToken,
        uint256 amount,
        bool increase
    );
    event PositionAdjusted(address mToken, address account, bool open);
    event PositionTokenUpdated(
        address mToken,
        uint256 collRatio,
        uint256 collReqSoft,
        uint256 collReqHard,
        uint256 liqIncBase,
        uint256 liqIncMin,
        uint256 liqIncMax,
        uint256 baseCFactor
    );
    event ActionPaused(string action, bool pauseState);
    event TokenActionPaused(address mToken, string action, bool pauseState);
    event NewCollateralCap(address mToken, uint256 newCollateralCap);
    event NewPositionManagementContract(address newPositionManager);

    event AtlasDappControlUpdated(address atlasDappControlAddress, bool isAdded);

    /// ERRORS ///

    error MarketManager__Unauthorized();
    error MarketManager__TokenNotListed();
    error MarketManager__Paused();
    error MarketManager__InsufficientCollateral();
    error MarketManager__NoLiquidationAvailable();
    error MarketManager__PriceError();
    error MarketManager__CollateralCapReached();
    error MarketManager__MarketManagerMismatch();
    error MarketManager__InvalidParameter();
    error MarketManager__MinimumHoldPeriod();
    error MarketManager__InvariantError();

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_
    ) LiquidityManager(centralRegistry_) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Returns whether `mToken` is listed in the lending market.
    /// @param mToken market token address.
    function isListed(address mToken) external view returns (bool) {
        return tokenData[mToken].isListed;
    }

    function queryTokensListed() external view returns (address[] memory) {
        return tokensListed;
    }

    /// @notice Sets a new dynamic penalty value in transient storage.
    /// @dev Transient storage enforces any liquidator not using
    ///      dappcontrol/auction uses the default penalty.
    /// @param newPenalty The new penalty value.
    function setAtlasParameters(uint256 newPenalty, uint256 newCloseFactor) external {
        if (!hasAtlasPermissions[msg.sender]) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        MarketToken storage pToken = tokenData[positionToken];
        // Validate new penalty is within configured allowed penalty.
        if (
            newPenalty < pToken.liqMinIncentive ||
            newPenalty > pToken.liqMaxIncentive
            ) {
            revert MarketManager__InvalidParameter();
        }

        // TODO: validate close factors also with a max and min same as penalties

        // tstore(key, value): store `newPenalty` under TRANSIENT_PENALTY_KEY.
        assembly {
            tstore(TRANSIENT_PENALTY_KEY, newPenalty)
        }

        // tstore(key, value): store `newCloseFactor` under TRANSIENT_CLOSE_FACTOR_KEY.
        assembly {
            tstore(TRANSIENT_CLOSE_FACTOR_KEY, newCloseFactor)
        }
    }

    /// @notice Resets the dynamic penalty value in transient storage to zero.
    function resetAtlasParameters() external {
        if (!hasAtlasPermissions[msg.sender]) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        assembly {
            // Clear the transient storage slot by writing zero. 
            tstore(TRANSIENT_PENALTY_KEY, 0)
        }

        // Clear the transient storage slot by writing zero.
        assembly {
            tstore(TRANSIENT_CLOSE_FACTOR_KEY, 0)
        }
        
    }

    /// @notice Returns the current penalty.
    /// @dev If a dynamic penalty is set in transient storage, 
    ///      that value is returned; otherwise, the default penalty
    ///      is returned.
    function getLatestPenalty() public view returns (uint256 result) {
        assembly {
            // Load dynamic penalty from transient storage.
            result := tload(TRANSIENT_PENALTY_KEY)
        }

        // If no dynamic penalty is set (assumed to be zero), return the
        // liqBaseIncentive.
        // Note that this renders 0 as an invalid dynamic penalty value.
        if (result == 0) {
            return tokenData[positionToken].liqBaseIncentive;
        }
    }

    /// @notice Returns the current close factor.
    /// @dev If a dynamic close factor is set in transient storage, 
    ///      that value is returned; otherwise, the default close factor
    ///      is returned.
    function getLatestCloseFactor() public view returns (uint256 result) {
        assembly {
            // Load dynamic close factor from transient storage.
            result := tload(TRANSIENT_CLOSE_FACTOR_KEY)
        }

        // TODO: fallback to returning default close factor if TRANSIENT_CLOSE_FACTOR_KEY is empty.
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

    /// @notice Returns if an account has an active position in `mToken`.
    /// @param account The address of the account to check a position of.
    /// @param mToken The address of the market token.
    function tokenDataOf(
        address account,
        address mToken
    )
        external
        view
        returns (
            bool hasPosition,
            uint256 balanceOf,
            uint256 collateralPostedOf
        )
    {
        AccountPosition memory accountPositions = tokenData[mToken]
            .accountPositions[account];
        hasPosition = accountPositions.activePosition == 2;
        balanceOf = IMToken(mToken).balanceOf(account);
        collateralPostedOf = accountPositions.collateralPosted;
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
    /// @return accountCollateral The total market value of `account`'s
    ///                           collateral.
    /// @return accountCollateralSoft The total market value of `account`'s
    ///                               collateral offset by soft liquidation
    ///                               requirements.
    /// @return accountCollateralHard The total market value of `account`'s
    ///                               collateral offset by hard liquidation
    ///                               requirements.
    /// @return accountDebt The total outstanding debt value of `account`.
    function liquidationValuesOf(
        address account
    )
        external
        view
        returns (
            uint256 accountCollateral,
            uint256 accountCollateralSoft,
            uint256 accountCollateralHard,
            uint256 accountDebt
        )
    {
        (
            accountCollateral,
            accountCollateralSoft,
            accountCollateralHard,
            accountDebt,
            ,

        ) = _liquidationValuesOf(account, address(0), address(0));
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
        LiqData memory result = _liquidationStatusOf(
            account,
            eToken,
            pToken
        );
        return (
            result.lFactor,
            result.earnTokenPrice,
            result.positionTokenPrice
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

    /// @notice Posts `tokens` of `pToken` as collateral inside this market.
    /// @dev The position token must have collateralization
    ///      enabled (collRatio > 0).
    /// @param account The account posting collateral.
    /// @param pToken The address of the pToken to post collateral for.
    /// @param tokens The amount of `pToken` to post as collateral, in shares.
    function postCollateral(
        address account,
        address pToken,
        uint256 tokens
    ) external {
        if (tokens == 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // If they are trying to post collateral for someone else,
        // make sure it is done via the pToken contract itself.
        if (msg.sender != account) {
            _checkIsToken(pToken);
        }

        _checkIsListedToken(pToken);
        _checkIsPToken(pToken);

        AccountPosition storage accountPositions = tokenData[pToken]
            .accountPositions[account];

        // Precondition invariant check.
        if (
            accountPositions.collateralPosted + tokens >
            IMToken(pToken).balanceOf(account)
        ) {
            revert MarketManager__InsufficientCollateral();
        }

        _postCollateral(account, accountPositions, pToken, tokens);
    }

    /// @notice Removes collateral posted for `pToken` inside this market.
    /// @param pToken The address of the pToken to remove collateral for.
    /// @param tokens The number of tokens that are posted of collateral
    ///               that should be removed, in shares.
    function removeCollateral(address pToken, uint256 tokens) external {
        if (tokens == 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        AccountPosition storage accountPositions = tokenData[pToken]
            .accountPositions[msg.sender];

        // We can check this instead of .isListed because any unlisted token
        // will always have activePosition == 0,
        // and this lets us check for any invariant errors.
        if (accountPositions.activePosition != 2) {
            _revert(_INVARIANT_ERROR_SELECTOR);
        }

        _checkIsPToken(pToken);

        if (accountPositions.collateralPosted < tokens) {
            revert MarketManager__InsufficientCollateral();
        }

        // Fail if the sender is not permitted to redeem `tokens`.
        // Note: `tokens` is in shares.
        (
            uint256 positionClosureNeeded,
            bool[] memory positionsToClose
        ) = _canRedeem(pToken, msg.sender, tokens);
        _removeCollateral(msg.sender, accountPositions, pToken, tokens);

        _closePositionsIfNeeded(
            positionClosureNeeded,
            msg.sender,
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

    /// @notice Checks if the account should be allowed to redeem tokens
    ///         in the given market, and then redeems.
    /// @dev This can only be called by the mToken itself
    ///      (specifically pTokens, because eTokens are never collateral).
    /// @param mToken The market token to verify the redemption against.
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
    ) external {
        _checkIsToken(mToken);
        _canRedeemWithCollateralRemoval(
            mToken,
            account,
            balance,
            amount,
            forceRedeemCollateral
        );
    }

    /// @notice Checks if the account should be allowed to borrow
    ///         the underlying asset of the given market.
    ///         Prunes unused positions in `account` data.
    /// @dev May emit a {TokenPositionCreated} event.
    /// @param eToken The debt token to verify the borrow of.
    /// @param account The account which would borrow the asset.
    /// @param amount The amount of underlying the account would borrow.
    function canBorrowWithPrune(
        address eToken,
        address account,
        uint256 amount
    ) external {
        _checkIsToken(eToken);

        _canBorrow(eToken, account, amount);
    }

    /// @notice Checks if the account should be allowed to borrow
    ///         the underlying asset of the given market,
    ///         and notifies the market of the borrow.
    /// @dev This can only be called by the market itself.
    /// @param eToken The market token to verify the borrow for.
    /// @param account The account which would borrow the asset.
    /// @param amount The amount of underlying the account would borrow.
    function canBorrowWithNotify(
        address eToken,
        address account,
        uint256 amount
    ) external {
        _checkIsToken(eToken);
        accountAssets[account].cooldownTimestamp = block.timestamp;

        _canBorrow(eToken, account, amount);
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
    /// @param eToken Debt token to repay which is borrowed by `account`.
    /// @param pToken Position token collateralized by `account` and will
    ///               be seized.
    /// @param account The address of the account to be liquidated.
    /// @param amount The amount of `earnToken` underlying being repaid.
    /// @param liquidateExact Whether the liquidator desires a specific
    ///                       liquidation amount.
    /// @return The amount of `earnToken` underlying to be repaid on
    ///         liquidation.
    /// @return The number of `positionToken` tokens to be seized in a
    ///         liquidation.
    function canLiquidate(
        address eToken,
        address pToken,
        address account,
        uint256 amount,
        bool liquidateExact
    ) external view returns (uint256, uint256) {
        return _canLiquidate(eToken, pToken, account, amount, liquidateExact);
    }

    /// @notice Checks if the liquidation should be allowed to occur,
    ///         and returns how many position tokens should be seized
    ///         on liquidation.
    /// @param eToken Debt token to repay which is borrowed by `account`.
    /// @param pToken Position token which was used as collateral and will
    ///        be seized.
    /// @param account The address of the account to be liquidated.
    /// @param amount The amount of `earnToken` underlying being repaid.
    /// @param liquidateExact Whether the liquidator desires a specific
    ///                       liquidation amount.
    /// @return The amount of `earnToken` underlying to be repaid on
    ///         liquidation.
    /// @return The number of `positionToken` tokens to be seized in a
    ///         liquidation.
    function canLiquidateWithExecution(
        address eToken,
        address pToken,
        address liquidator,
        address account,
        uint256 amount,
        bool liquidateExact
    ) external returns (uint256, uint256) {
        _checkIsToken(eToken);

        (uint256 eTokenRepaid, uint256 pTokenLiquidated) = _canLiquidate(
            eToken,
            pToken,
            account,
            amount,
            liquidateExact
        );

        // We can pass balance = 0 here since we are forcing collateral closure
        // and balance will never be lower than collateral posted.
        (
            uint256 collateralToRemove,
            AccountPosition storage accountPositions
        ) = _checkCollateralToRemove(
                account,
                pToken,
                0,
                pTokenLiquidated,
                true
            );
        if (collateralToRemove > 0) {
            _removeCollateral(
                account,
                accountPositions,
                pToken,
                collateralToRemove
            );
        }

        return (eTokenRepaid, pTokenLiquidated);
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

    /// @notice Checks if the account should be allowed to transfer collateral
    ///         tokens in the given market.
    /// @param mToken The market token to verify the transfer of.
    /// @param from The account which will transfer the tokens.
    /// @param amount The number of mTokens to transfer.
    function canTransferPToken(
        address mToken,
        address from,
        uint256 amount
    ) external {
        _checkIsToken(mToken);
        if (transferPaused == 2) {
            _revert(_PAUSED_SELECTOR);
        }

        _canRedeemWithCollateralRemoval(
            mToken,
            from,
            IMToken(mToken).balanceOf(from),
            amount,
            false
        );
    }

    // /// @notice Queues a token specific liquidation for `account` liquidating
    // ///         `pToken` by repaying active debt in `eToken`.
    // /// @dev Called by the eToken itself to validate that liquidation is
    // ///      allowed based on `account`'s current liquidity.
    // /// @param eToken The earning token debt position to be from
    // ///               `account`.
    // /// @param pToken The position token to be liquidated from
    // ///               `account`.
    // /// @param liquidator The account to execute the liquidation once queued.
    // /// @param account The account being liquidated and debt repaid on behalf
    // ///                of.
    // function queueLiquidation(
    //     address eToken,
    //     address pToken,
    //     address liquidator,
    //     address account
    // ) external {
    //     // Verify caller is actually the eToken.
    //     _checkIsToken(eToken);

    //     // Verify the liquidation is valid.
    //     _canLiquidate(eToken, pToken, account, 0, false);

    //     // Queue the liquidation for execution.
    //     _queueLiquidation(liquidator, account);
    // }

    // /// @notice Queues an account liquidation for `account` liquidating
    // ///         `pToken` by repaying a portion of `account`'s active debt.
    // /// @dev Called by the liquidator themselves to queue up a different
    // ///      account's liquidation.
    // /// @param account The account being liquidated and debt repaid on behalf
    // ///                of.
    // function queueAccountLiquidation(address account) external {
    //     _getUpdatedLiquidationStatusOf(account);

    //     // Queue the liquidation for execution.
    //     _queueLiquidation(msg.sender, account);
    // }

    /// @notice Liquidates an entire account by partially paying down debts,
    ///         distributing all `account` collateral and recognize remaining
    ///         debt as bad debt.
    /// @dev Updates `account` EToken interest before solvency is checked.
    ///      Extensive run invariant checks are made to prevent potential
    ///      asset callback exploits.
    ///      Emits a {CollateralRemoved} event.
    /// @param account The address to liquidate completely.
    function liquidateAccount(address account) external {
        if (liquidationPaused == 2) {
            _revert(_PAUSED_SELECTOR);
        }


        (
            BadDebtData memory data,
            uint256[] memory assetBalances
        ) = _getUpdatedLiquidationStatusOf(account);

        uint256 repayRatio = (data.debtToPay * WAD) / data.debt;
        uint256 debt;

        IMToken[] memory accountAssetsPrior = accountAssets[account].assets;
        uint256 numAssetsPrior = accountAssetsPrior.length;
        IMToken mToken;

        // Repay `account`'s debt and recognize bad debt.
        for (uint256 i = 0; i < numAssetsPrior; ++i) {
            // Cache `account` mToken.
            mToken = accountAssetsPrior[i];
            if (!mToken.isPToken()) {
                debt = IEToken(address(mToken)).debtBalanceCached(account);

                // If the debt balance now does not match initial
                // debt balance, there has been an attempt at
                // invariant manipulation, revert.
                if (debt != assetBalances[i]) {
                    _revert(_INVARIANT_ERROR_SELECTOR);
                }

                // Make sure this eToken actually has outstanding debt.
                if (debt > 0) {
                    // Repay `account`'s debt where:
                    // debtToPay = totalCollateral / (1 - liquidationPenalty).
                    // badDebt = totalDebt - debtToPay.
                    // Thus:
                    // totalDebt = debtToPay + badDebt.
                    // Where debtToPay is what caller repays to receive collateral,
                    // badDebt is loss to lenders by offsetting
                    // totalBorrows (total estimated outstanding debt).
                    IEToken(address(mToken)).repayWithBadDebt(
                        msg.sender,
                        account,
                        repayRatio
                    );
                }
            }
        }

        uint256 collateral;

        // Seize `account`'s collateral and remove posted collateral.
        for (uint256 i = 0; i < numAssetsPrior; ++i) {
            // Cache `account` mToken.
            mToken = accountAssetsPrior[i];
            if (mToken.isPToken()) {
                AccountPosition storage collateralData = tokenData[
                    address(mToken)
                ].accountPositions[account];
                // Cache `account` collateral posted.
                collateral = collateralData.collateralPosted;

                // If the collateral posted now does not match initial
                // collateral posted, there has been an attempt at
                // invariant manipulation, revert.
                if (collateral != assetBalances[i]) {
                    _revert(_INVARIANT_ERROR_SELECTOR);
                }

                // Make sure this pToken is actually being used as collateral.
                // Without this check a user would be immune to bad debt
                // liquidation.
                if (collateral > 0) {
                    // Remove `account` posted collateral,
                    // as their account is completely closed out.
                    delete collateralData.collateralPosted;

                    // Update collateralPosted invariant.
                    collateralPosted[address(mToken)] =
                        collateralPosted[address(mToken)] -
                        collateral;
                    emit CollateralAdjusted(
                        account,
                        address(mToken),
                        collateral,
                        false
                    );
                    // Seize `account`'s collateral and give to caller.
                    IPToken(address(mToken)).seizeAccountLiquidation(
                        msg.sender,
                        account,
                        collateral
                    );
                }
            }
        }

        IMToken[] memory accountAssetsPost = accountAssets[account].assets;
        uint256 numAssetsPost = accountAssetsPost.length;

        // If a user somehow manipulated their assets via ERC777 or some
        // other callbacks we can validate that no changes occurred to
        // user assets, as we've already validated collateral posted/debt
        // balances above.
        if (numAssetsPost != numAssetsPrior) {
            _revert(_INVARIANT_ERROR_SELECTOR);
        }

        for (uint256 i = 0; i < numAssetsPrior; ++i) {
            if (accountAssetsPost[i] != accountAssetsPrior[i]) {
                _revert(_INVARIANT_ERROR_SELECTOR);
            }
        }
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
    /// @param liqIncMin The minimum possible liquidation incentive for
    ///                  `positionToken`, in basis points.
    /// @param liqIncMax The maximum possible liquidation incentive for
    ///                  `positionToken`, in basis points.
    function updatePositionToken(
        uint256 collRatio,
        uint256 collReqSoft,
        uint256 collReqHard,
        uint256 liqIncBase,
        uint256 liqIncMin,
        uint256 liqIncMax,
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
        liqIncMin = _bpToWad(liqIncMin);
        liqIncMax = _bpToWad(liqIncMax);
        baseCFactor = _bpToWad(baseCFactor);

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

        // Assign the base cFactor
        marketToken.baseCFactor = baseCFactor;
        // Store the distance between base cFactor and 100%,
        // that way we can quickly scale between [base, 100%] based on lFactor.
        marketToken.cFactorCurve = WAD - baseCFactor;

        emit PositionTokenUpdated(
            pToken,
            collRatio,
            collReqSoft,
            collReqHard,
            liqIncBase,
            liqIncMin,
            liqIncMax,
            baseCFactor
        );
    }

    /// @notice Set `newCollateralizationCaps` for the given `pTokens`.
    /// @dev Can emit {NewCollateralCap} events.
    /// @param pTokens The addresses of the markets (tokens) to
    ///                change the borrow caps for.
    /// @param newCollateralCaps The new collateral cap values in underlying
    ///                          to be set, in  shares.
    function setPTokenCollateralCaps(
        address[] calldata pTokens,
        uint256[] calldata newCollateralCaps
    ) external {
        _checkDaoPermissions();

        uint256 numTokens = pTokens.length;

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
            // Make sure the pToken is a pToken.
            _checkIsPToken(pTokens[i]);

            // Do not let people collateralize assets
            // with collateralization ratio of 0.
            if (tokenData[pTokens[i]].collRatio == 0) {
                _revert(_INVALID_PARAMETER_SELECTOR);
            }

            collateralCaps[pTokens[i]] = newCollateralCaps[i];
            emit NewCollateralCap(pTokens[i], newCollateralCaps[i]);
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

    // /// @notice Updates status of unique liquidation sequencing to
    // ///         `sequencingActive`.
    // function setSequencingStatus(bool sequencingActive) external {
    //     _checkIsCentralRegistry();
    //     _setSequencingStatus(sequencingActive);
    // }

    // /// @notice Updates OEV liquidation duration delays.
    // function setDelays(
    //     uint256 newPriorityDelay,
    //     uint256 newRegularDelay,
    //     uint256 newEndDelay
    // ) external {
    //     _checkIsCentralRegistry();
    //     _setDelays(newPriorityDelay, newRegularDelay, newEndDelay);
    // }

    /// PUBLIC FUNCTIONS ///

    /// @inheritdoc ERC165
    function supportsInterface(
        bytes4 interfaceId
    ) public view override returns (bool) {
        return
            interfaceId == type(IMarketManager).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Update pending interest in markts and determine `account`'s
    ///         current status between collateral, debt, and additional
    ///         liquidity and whether theres associated bad debt available
    ///         warranting an account liquidation.
    /// @param account The account to determine bad debt status.
    /// @return Array of the amount of collateral posted and debt balances for
    ///         each user position.
    function _getUpdatedLiquidationStatusOf(
        address account
    ) internal returns (BadDebtData memory, uint256[] memory) {
        // Make sure `account` is not trying to liquidate themselves.
        if (msg.sender == account) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        // Make sure liquidations are not paused.
        if (seizePaused == 2) {
            _revert(_PAUSED_SELECTOR);
        }

        IMToken[] memory accountAssetsPrior = accountAssets[account].assets;
        uint256 numAssetsPrior = accountAssetsPrior.length;
        IMToken mToken;

        // Update pending interest in markets.
        for (uint256 i; i < numAssetsPrior; ) {
            // Cache `account` mToken then increment i.
            mToken = accountAssetsPrior[i++];
            if (!mToken.isPToken()) {
                // Update EToken interest if necessary.
                IEToken(address(mToken)).accrueInterest();
            }
        }

        (
            BadDebtData memory data,
            uint256[] memory assetBalances
        ) = _accountLiquidationStatusOf(account);

        // If an account has no collateral or debt this will revert.
        if (data.collateral >= data.debt) {
            revert MarketManager__NoLiquidationAvailable();
        }

        return (data, assetBalances);
    }

    /// @notice Helper function for posting `tokens` of `pToken`
    ///         as collateral for `account` inside this market.
    /// @dev Emits {CollateralPosted} and, potentially,
    ///      {TokenPositionCreated} events.
    /// @param account The account posting collateral.
    /// @param accountPositions Cached account metadata of `account.`
    /// @param pToken The address of the pToken to post collateral for.
    /// @param tokens The amount of `pToken` to post as collateral, in shares.
    function _postCollateral(
        address account,
        AccountPosition storage accountPositions,
        address pToken,
        uint256 tokens
    ) internal {
        // This also acts as a check that the pToken collateralization ratio
        // is > 0, since collateralCaps can only be raised above zero if a
        // pToken's collateralization ratio is > 0.
        if (collateralPosted[pToken] + tokens > collateralCaps[pToken]) {
            revert MarketManager__CollateralCapReached();
        }

        // On collateral posting:
        // We need to flip their cooldown flag to prevent flashloan attacks.
        accountAssets[account].cooldownTimestamp = block.timestamp;
        collateralPosted[pToken] = collateralPosted[pToken] + tokens;
        accountPositions.collateralPosted =
            accountPositions.collateralPosted +
            tokens;
        emit CollateralAdjusted(account, pToken, tokens, true);

        // If `account` does not have a position in `pToken`, open one.
        if (accountPositions.activePosition != 2) {
            accountPositions.activePosition = 2;
            accountAssets[account].assets.push(IMToken(pToken));

            emit PositionAdjusted(pToken, account, true);
        }
    }

    /// @notice Helper function for removing `pToken` collateral posted for
    ///         `account` inside this market.
    /// @dev Emits a {CollateralRemoved} event.
    /// @param account The address of the account to reduce `mToken`
    ///                collateral posted for.
    /// @param accountPositions Cached account metadata of `account.`
    /// @param pToken The address of the pToken to remove collateral for.
    /// @param tokens The number of tokens that are posted of collateral
    ///               that should be removed, in shares.
    function _removeCollateral(
        address account,
        AccountPosition storage accountPositions,
        address pToken,
        uint256 tokens
    ) internal {
        accountPositions.collateralPosted =
            accountPositions.collateralPosted -
            tokens;
        collateralPosted[pToken] = collateralPosted[pToken] - tokens;
        emit CollateralAdjusted(account, pToken, tokens, false);
    }

    /// @notice Checks if the account should be allowed to borrow
    ///         the underlying asset of the given market.
    /// @dev Will natively revert if a hypothetical borrow will result in a
    ///      loan less than `MIN_ACTIVE_LOAN_SIZE`, set in `LiquidityManager`.
    ///      May emit a {TokenPositionCreated} event.
    /// @param eToken The debt token to verify the borrow of.
    /// @param account The account which would borrow the asset.
    /// @param amount The amount of underlying the account would borrow.
    function _canBorrow(
        address eToken,
        address account,
        uint256 amount
    ) internal {
        if (borrowPaused[eToken] == 2) {
            _revert(_PAUSED_SELECTOR);
        }

        _checkIsListedToken(eToken);

        // Check if the user already has an active borrow in the eToken.
        if (tokenData[eToken].accountPositions[account].activePosition != 2) {
            // The account does not have an active borrow in the eToken,
            // so update this so borrow position is monitored in liquidity
            // checks.
            tokenData[eToken].accountPositions[account].activePosition = 2;
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
        if (tokenData[mToken].accountPositions[account].activePosition != 2) {
            bool[] memory emptyPositions;
            return (0, emptyPositions);
        }

        // Check account liquidity with hypothetical sToken redemption.
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
    /// @param balance The current mTokens balance of `account`.
    /// @param amount The number of mTokens to exchange
    ///               for the underlying asset in the market.
    /// @param forceRedeemCollateral Whether the collateral should be always
    ///                              reduced.
    function _canRedeemWithCollateralRemoval(
        address pToken,
        address account,
        uint256 balance,
        uint256 amount,
        bool forceRedeemCollateral
    ) internal {
        // Check how much collateral should be removed, if any.
        (
            uint256 collateralToRemove,
            AccountPosition storage accountPositions
        ) = _checkCollateralToRemove(
                account,
                pToken,
                balance,
                amount,
                forceRedeemCollateral
            );

        // Execute removal of collateral posted, if needed.
        if (collateralToRemove > 0) {
            (
                uint256 positionClosureNeeded,
                bool[] memory positionsToClose
            ) = _canRedeem(pToken, account, collateralToRemove);

            _removeCollateral(
                account,
                accountPositions,
                pToken,
                collateralToRemove
            );

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

    /// @notice Helper function for checking if the liquidation should be
    ///         allowed to occur.
    /// @param eToken Asset which was borrowed by the borrower.
    /// @param pToken Asset which was used as collateral and will
    ///                        be seized.
    /// @param account The address of the account to be liquidated.
    /// @param debtAmount The amount of `eToken` desired to liquidate.
    ///                   When `liquidateExact` is false, this value is
    ///                   replaced with the maximum executable liquidation
    ///                   amount.
    /// @param liquidateExact Whether the liquidator wants to liquidate a
    ///                       specific amount of debt, used in conjunction
    ///                       with `debtAmount`.
    /// @return The amount of `eToken` underlying to be repaid on
    ///         liquidation.
    /// @return The number of `pToken` tokens to be seized in a
    ///         liquidation.
    function _canLiquidate(
        address eToken,
        address pToken,
        address account,
        uint256 debtAmount,
        bool liquidateExact
    ) internal view returns (uint256, uint256) {
        _checkIsListedToken(eToken);
        _checkIsListedToken(pToken);

        _checkCollateralUnlocked(eToken);

        MarketToken storage pTokenData = tokenData[pToken];

        // Do not let people liquidate 0 collateralization ratio assets.
        if (pTokenData.collRatio == 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Calculate the users lFactor.
        LiqData memory data = _liquidationStatusOf(
            account,
            eToken,
            pToken
        );

        // Validate that `account` has a liquidation available.
        if (data.lFactor == 0) {
            revert MarketManager__NoLiquidationAvailable();
        }

        uint256 maxAmount;
        uint256 debtToCollateralRatio;
        {
            uint256 cFactor = pTokenData.baseCFactor +
                ((pTokenData.cFactorCurve * data.lFactor) / WAD);

            // check for dynamic penalty in transient storage
            uint256 incentive = getLatestPenalty();
            
            maxAmount =
            (cFactor * IEToken(eToken).debtBalanceCached(account)) /
                 WAD;

            // Get the exchange rate, and calculate the number of
            // position tokens to seize.
            debtToCollateralRatio =
                (incentive * data.earnTokenPrice * WAD) /
                (data.positionTokenPrice *
                    IPToken(pToken).exchangeRateCached());
        }

        // If they want to liquidate an exact amount, liquidate `debtAmount`,
        // otherwise liquidate the maximum amount possible.
        if (!liquidateExact) {
            debtAmount = maxAmount;
        }

        // Adjust decimals if necessary.
        uint256 amountAdjusted = (debtAmount *
            (10 ** IERC20(pToken).decimals())) /
            (10 ** IERC20(eToken).decimals());
        // Calculate how many pTokens should be liquidated.
        uint256 liquidatedTokens = (amountAdjusted * debtToCollateralRatio) /
            WAD;

        // Cache `account`'s collateral posted of `pToken`.
        uint256 collateralAvailable = pTokenData
            .accountPositions[account]
            .collateralPosted;
        // If the user wants to liquidate an exact amount, make sure theres
        // enough collateral available to liquidate,
        // otherwise liquidate as much as possible.
        if (liquidateExact) {
            if (
                debtAmount > maxAmount ||
                liquidatedTokens > collateralAvailable
            ) {
                // Make sure that the liquidation limit,
                // and collateral posted >= amount.
                _revert(_INVALID_PARAMETER_SELECTOR);
            }
        } else {
            if (liquidatedTokens > collateralAvailable) {
                debtAmount = FixedPointMathLib.mulDivUp(
                    debtAmount,
                    collateralAvailable,
                    liquidatedTokens
                );
                liquidatedTokens = collateralAvailable;
            }
        }

        // Calculate the maximum amount of debt that can be liquidated
        // and what collateral will be received.
        return (debtAmount, liquidatedTokens);
    }

    /// @notice Helper function for closing user positions after liquidity
    ///         checks have been passed.
    /// @dev Used as sort of a garbage collection system for any user positions
    ///      that should be closed to optimize future liquidity checks.
    ///      May emit {TokenPositionClosed} events.
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
                tokenData[cachedToken]
                    .accountPositions[account]
                    .activePosition = 1;
                emit PositionAdjusted(cachedToken, account, false);
            }
        }
    }

    /// @notice Helper function to calculate how much collateral should
    ///         be removed for their desired action.
    /// @param account The account to potential reduce posted collateral for.
    /// @param pToken The pToken address to potentially reduce collateral for.
    /// @param balance The pToken share balance of `account`.
    /// @param amount The maximum amount of shares that could be removed as
    ///               collateral.
    /// @param forceReduce Whether to force reduce `account`'s collateral
    ///                    for not.
    function _checkCollateralToRemove(
        address account,
        address pToken,
        uint256 balance,
        uint256 amount,
        bool forceReduce
    ) internal view returns (uint256, AccountPosition storage) {
        AccountPosition storage accountPositions = tokenData[pToken]
            .accountPositions[account];

        // If collateral removal amount is 0, we can skip balance checks.
        if (amount == 0) {
            return (0, accountPositions);
        }

        // If collateral is being directly removed by user intention,
        // or liquidation we can skip balance checks.
        if (forceReduce) {
            return (amount, accountPositions);
        }

        uint256 reductionAmount;

        // If they want to redeem more pTokens than they have used,
        // calculate the delta between the two values.
        if (accountPositions.collateralPosted + amount >= balance) {
            reductionAmount =
                (accountPositions.collateralPosted + amount) -
                balance;
        }

        return (reductionAmount, accountPositions);
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

    /// @notice Check whether token is pToken.
    /// @param token The token to check whether it's pToken or not.
    function _checkIsPToken(address token) internal view {
        if (!IMToken(token).isPToken()) {
            _revert(_INVALID_PARAMETER_SELECTOR);
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

    ////////// Atlas functionality //////////////

    /// @notice Authorizes an address to lock and unlock Atlas OEV.
    /// @dev Only callable on a 7 day delay or by the Emergency Council.
    ///      Cannot be a supported Atlas controller address prior.
    ///      Emits a {AtlasControlAuthorized} event.
    /// @param newAtlasController The new address to allow control of Atlas
    ///                           support for use in Curvance.
    function addAuthorizedAtlasDAppControl(
        address newAtlasController
    ) external {
        _checkElevatedPermissions();

        // Validate `newAtlasController` is not currently supported.
        if (hasAtlasPermissions[newAtlasController]) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        hasAtlasPermissions[newAtlasController] = true;

        emit AtlasDappControlUpdated(newAtlasController, true);
    }

    /// @notice Deauthorizes an address to lock and unlock Atlas OEV.
    /// @dev Only callable on a 7 day delay or by the Emergency Council.
    ///      Cannot be a supported Atlas controller address prior.
    ///      Emits a {AtlasControlAuthorized} event.
    /// @param currentAtlasController The address to remove control of Atlas
    ///                           support from inside Curvance.
    function removeAuthorizedAtlasDAppControl(
        address currentAtlasController
    ) external {
        _checkElevatedPermissions();

        // Validate `currentAtlasController` is currently supported.
        if (!hasAtlasPermissions[currentAtlasController]) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        delete hasAtlasPermissions[currentAtlasController];

        emit AtlasDappControlUpdated(currentAtlasController, false);
    }

    /// @notice Called from the Atlas DappControl as a pre hook
    ///         before liquidations are tried.
    function lockAtlasOev() external {
        if (!hasAtlasPermissions[msg.sender]) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        assembly {
            tstore(TRANSIENT_ATLAS_OEV_KEY, 0)
        }

        assembly {
            tstore(TRANSIENT_COLLATERAL_UNLOCKED_KEY, 0)
        }
    }

    /// @notice Called from the Atlas DappControl as a post hook
    ///         after liquidations are tried.
    function unlockAtlasOev(uint256 collateralToUnlock) external {
        if (!hasAtlasPermissions[msg.sender]) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        assembly {
            tstore(TRANSIENT_ATLAS_OEV_KEY, 1)
        }

        assembly {
            tstore(TRANSIENT_COLLATERAL_UNLOCKED_KEY, collateralToUnlock)
        }
    }

    /// @notice Whether current transaction is from Atlas DappControl.
    /// TODO: override was removed, maybe it should be in a lower level contract?
    function _checkCollateralUnlocked(address eTokenToLiquidate) internal view {
        uint256 result;
        assembly {
            result := tload(TRANSIENT_COLLATERAL_UNLOCKED_KEY)
        }

        if (result == 0) {
            return;
        }

        address unlockedCollateral = address(uint160(result));

        if (unlockedCollateral != eTokenToLiquidate) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }
    }

    function _checkAtlasOevAllowed() internal view returns (bool) {
        uint256 result;
        assembly {
            result := tload(TRANSIENT_ATLAS_OEV_KEY)
        }
        return result == 1;
    }
}
