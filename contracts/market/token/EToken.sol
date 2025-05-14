// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Multicall } from "contracts/libraries/Multicall.sol";
import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";
import { WAD } from "contracts/libraries/Constants.sol";
import { ReentrancyGuard } from "contracts/libraries/external/ReentrancyGuard.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { RescueLib } from "contracts/libraries/RescueLib.sol";
import { ERC165 } from "contracts/libraries/external/ERC165.sol";
import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { IInterestRateModel } from "contracts/interfaces/IInterestRateModel.sol";
import { IPositionManagement } from "contracts/interfaces/IPositionManagement.sol";
import { IMToken, AccountSnapshot } from "contracts/interfaces/IMToken.sol";
import { IPToken } from "contracts/interfaces/IPToken.sol";
/// @title Curvance's Earn Token Contract.
/// @dev Curvance's eTokens are ERC20 compliant with a close relation
///      to ERC4626. However, they follow their own design flow, without an
///      inherited base contract. This is done intentionally, to maximize
///      security in an age of rapidly developing security attack vectors.
///
///      The "eToken" employs a share/asset structure with slightly different
///      configuration, and terminology (to prevent confusion). The variable
///      terms "tokens", and "amount" are used to refer to eTokens values,
///      and underlying asset values. When you see "Tokens" that is associated
///      with eTokens, when you see "amount" that is associated with
///      underlying assets.
///
///      Users who have active positions inside a eToken are referred to
///      as accounts. For actions that can be performed by an external party,
///      that will not result in active positions for themselves, more general
///      terms are used such as "Liquidator", "Minter", or "Payer".
///
///      "Safe" versions of functions have been added that introduce
///      additional reentry and update protection logic to minimize risks
///      when integrating Curvance into external protocols.
///
contract EToken is PluginDelegable, ERC165, ReentrancyGuard, Multicall {
    // TYPES ///

    /// @title Debt Data
    /// @dev Data for a user's debt. 
    /// @param principal Principal total balance (with accrued interest).
    /// @param accountExchangeRate Current exchange rate for account.
    struct DebtData {
        uint256 principal;
        uint256 accountExchangeRate;
    }

    /// @title Market Data
    /// @dev Data for a market. 
    /// @param lastTimestampUpdated Timestamp interest was last update.
    /// @param exchangeRate Borrow exchange rate at `lastTimestampUpdated`.
    /// @param compoundRate Rate at which interest compounds, in seconds.
    struct MarketData {
        uint40 lastTimestampUpdated;
        uint216 exchangeRate;
        uint256 compoundRate;
    }

    /// CONSTANTS ///

    /// @notice The underlying asset for the EToken, cannot be a fee-on-transfer token.
    address public immutable underlying;
    /// @notice Address of the Market Manager linked to this contract.
    IMarketManager public immutable marketManager;

    /// @dev `bytes4(keccak256(bytes("EToken__Unauthorized()")))`.
    uint256 internal constant _UNAUTHORIZED_SELECTOR = 0xc7e7bc18;
    /// @dev `bytes4(keccak256(bytes("EToken__ValidationFailed()")))`.
    uint256 internal constant _VALIDATION_FAILED_SELECTOR = 0xdb8f0ad;
    /// @dev The base underlying asset requirement held in order to minimize
    ///      rounding exploits, and more generally, invariant manipulation.
    uint256 internal constant _BASE_UNDERLYING_RESERVE = 42069;

    /// STORAGE ///

    /// @notice token name metadata.
    string public name;
    /// @notice token symbol metadata.
    string public symbol;
    /// @notice Total number of tokens in circulation.
    uint256 public totalSupply;
    /// @notice Returns total amount of outstanding borrows of the
    ///         underlying in this eToken market.
    uint256 public totalBorrows;
    /// @notice Total protocol reserves of underlying.
    uint256 public totalReserves;
    /// @notice Interest rate reserve factor.
    uint256 public interestFactor;
    /// @notice Address of the current Interest Rate Model.
    IInterestRateModel public interestRateModel;
    /// @notice Information corresponding to borrow exchange rate.
    MarketData public marketData;

    /// @notice The eToken balance of an account.
    /// @dev Account address => Account token balance.
    mapping(address => uint256) public balanceOf;
    /// @notice The allowance on token transfers a spender has for an account.
    /// @dev Account address => Spender address => Approved token amount.
    mapping(address => mapping(address => uint256)) public allowance;
    /// @notice Debt information associated with an account.
    /// @dev Account address => DebtData struct.
    mapping(address => DebtData) internal _debtOf;

    /// EVENTS ///

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );
    event InterestAccrued(
        uint256 debtAccumulated,
        uint256 exchangeRate,
        uint256 totalBorrows
    );
    event Borrow(address account, uint256 amount);
    event Repay(address payer, address account, uint256 amount);
    event BadDebtRecognized(address liquidator, uint256 amount);
    event NewMarketInterestRateModel(
        address oldInterestRateModel,
        address newInterestRateModel,
        uint256 newInterestCompoundRate
    );
    event NewInterestFactor(
        uint256 oldInterestFactor,
        uint256 newInterestFactor
    );
    /// ERRORS ///

    error EToken__Unauthorized();
    error EToken__EmptyAction();
    error EToken__ExcessiveValue();
    error EToken__TransferError();
    error EToken__InsufficientUnderlyingHeld();
    error EToken__ValidationFailed();
    error EToken__MarketManagerIsNotLendingMarket();

    /// CONSTRUCTOR ///

    /// @param centralRegistry_ The address of Curvances Central Registry.
    /// @param underlying_ The address of the underlying asset
    ///                    for this eToken.
    /// @param marketManager_ The address of the MarketManager.
    /// @param interestRateModel_ The address of the interest rate model.
    constructor(
        ICentralRegistry centralRegistry_,
        address underlying_,
        address marketManager_,
        address interestRateModel_
    ) PluginDelegable(centralRegistry_) {
        // Set the marketManager after consulting Central Registry.
        // Ensure that marketManager parameter is a marketManager.
        if (!centralRegistry.isMarketManager(marketManager_)) {
            revert EToken__MarketManagerIsNotLendingMarket();
        }

        // Set new marketManager.
        marketManager = IMarketManager(marketManager_);

        // Initialize timestamp and borrow index.
        marketData.lastTimestampUpdated = uint40(block.timestamp);
        marketData.exchangeRate = uint216(WAD);

        _setInterestRateModel(IInterestRateModel(interestRateModel_));

        // Assign the interest factor for interest generated
        // inside this market.
        uint256 newInterestFactor = centralRegistry.protocolInterestFactor(
            marketManager_
        );
        interestFactor = newInterestFactor;

        emit NewInterestFactor(0, newInterestFactor);

        underlying = underlying_;
        name = string.concat(
            "Curvance interest-bearing ",
            IERC20(underlying_).name()
        );
        symbol = string.concat("c", IERC20(underlying_).symbol());

        // Sanity check underlying so that we know users will not need to
        // mint anywhere close to exchange rate, in `WAD`.
        if (IERC20(underlying).totalSupply() >= type(uint232).max) {
            _revert(_VALIDATION_FAILED_SELECTOR);
        }
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Rescue any token sent by mistake.
    /// @dev Restricts the ability to rescue underlying tokens inside the
    ///      market since Curvance is non-custodial.
    /// @param token The token to rescue.
    /// @param amount The amount of `token` to rescue, 0 indicates to
    ///               rescue all.
    function rescueToken(address token, uint256 amount) external {
        _checkDaoPermissions();

        if (token == underlying) {
            revert EToken__TransferError();
        }

        RescueLib.rescueToken(centralRegistry, token, amount);
    }

    /// @notice Accrues pending interest and updates the interest rate model.
    /// @dev Admin function to update the interest rate model.
    /// @param newInterestRateModel The new interest rate model for this
    ///                             eToken to use.
    function setInterestRateModel(address newInterestRateModel) external {
        _checkElevatedPermissions();

        // Update pending interest.
        accrueInterest();

        _setInterestRateModel(IInterestRateModel(newInterestRateModel));
    }

    /// @notice Accrues pending interest and updates the interest factor.
    /// @dev Admin function to update the interest factor value.
    /// @param newInterestFactor The new interest factor for this
    ///                          eToken to use.
    function setInterestFactor(uint256 newInterestFactor) external {
        _checkElevatedPermissions();

        // Update pending interest.
        accrueInterest();

        _setInterestFactor(newInterestFactor);
    }

    //// @notice Starts a eToken market, executed via marketManager.
    /// @dev This initial mint is a failsafe against rounding exploits,
    ///      although, we protect against them in many ways,
    ///      better safe than sorry.
    /// @dev Emits a {Transfer} event.
    /// @param by The account initializing the eToken market.
    /// @return Returns with true when successful.
    function startMarket(address by) external nonReentrant returns (bool) {
        if (msg.sender != address(marketManager)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        // Validate that the interest rate model has been properly linked
        // to this earn token contract.
        if (interestRateModel.linkedEToken() != address(this)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        uint256 amount = _BASE_UNDERLYING_RESERVE;

        // We do not need to calculate exchange rate here,
        // `by` will always be the first depositor with totalSupply = 0.
        // Total Supply and contract's balance should always be 0 prior,
        // but we increment incase somehow invariants have been modified.
        _processMint(by, address(this), amount, amount);

        return true;
    }

    /// @notice Transfers `amount` eTokens from caller to `to`.
    /// @param to The address to receive `amount` eTokens.
    /// @param tokens The number of eTokens to transfer.
    /// @return Returns true on success.
    function transfer(
        address to,
        uint256 tokens
    ) external nonReentrant returns (bool) {
        _transfer(msg.sender, msg.sender, to, tokens);
        return true;
    }

    /// @notice Transfers `amount` tokens from `from` to `to`.
    /// @param from The address of to transfer `amount` eTokens.
    /// @param to The address to receive `amount` eTokens.
    /// @param tokens The number of eTokens to transfer.
    /// @return Returns true on success.
    function transferFrom(
        address from,
        address to,
        uint256 tokens
    ) external nonReentrant returns (bool) {
        _transfer(msg.sender, from, to, tokens);
        return true;
    }

    /// @notice Borrows underlying tokens from lenders, based on collateral
    ///         posted inside this market.
    /// @dev Updates pending interest before executing the borrow.
    /// @param amount The amount of the underlying asset to borrow.
    function borrow(uint256 amount) external nonReentrant {
        // Update pending interest.
        accrueInterest();

        // Reverts if borrow not allowed.
        // Notifies the Market Manager that a user is taking on more debt,
        // and to pause user redemptions for 20 minutes.
        marketManager.canBorrowWithNotify(address(this), msg.sender, amount);

        _borrow(msg.sender, amount, msg.sender);
    }

    /// @notice Used by a delegated user to borrow underlying tokens
    ///         from lenders, based on collateral posted inside this market
    ///         by `account`.
    /// @dev Updates pending interest before executing the borrow.
    ///      NOTE: Be careful who you approve here!
    ///      Not only can they take borrowed funds, but, they can delay
    ///      repayment through repeated borrows preventing withdrawal.
    /// @param account The account who will have their assets borrowed against.
    /// @param recipient The account who will receive the borrowed assets.
    /// @param amount The amount of the underlying asset to borrow.
    function borrowFor(
        address account,
        address recipient,
        uint256 amount
    ) external nonReentrant {
        _checkDelegate(account, msg.sender);

        // Update pending interest.
        accrueInterest();

        // Reverts if borrow not allowed.
        // Notifies the Market Manager that a user is taking on more debt,
        // and to pause user redemptions for 20 minutes.
        marketManager.canBorrowWithNotify(address(this), account, amount);

        _borrow(account, amount, recipient);
    }

    /// @notice Used by the position management contract to borrow underlying tokens
    ///         from lenders, based on collateral posted inside this market
    ///         by `account` to apply a complex action.
    /// @dev Only Position Management contract can call this function.
    ///      Updates pending interest before executing the borrow.
    /// @param account The account address to borrow on behalf of.
    /// @param amount The amount of the underlying asset to borrow.
    /// @param leverageData Callback calldata to execute after borrow.
    function borrowForPositionManagement(
        address account,
        uint256 amount,
        IPositionManagement.LeverageStruct memory leverageData
    ) external nonReentrant {
        if (!marketManager.positionManagement(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        // Update pending interest.
        // This generally is a redundant check due to interest accrual
        // done inside checkSlippage check in position management contract
        // implementations, but we keep this check in for invariant
        // protection in the case of a incorrectly implemented position
        // management contract.
        accrueInterest();

        // Notifies the Market Manager that a user is taking on more debt,
        // and to pause user redemptions for 20 minutes.
        marketManager.notifyBorrow(address(this), account);

        _borrow(account, amount, msg.sender);

        // Callback to position folding to execute additional action.
        IPositionManagement(msg.sender).onBorrow(
            address(this),
            account,
            amount,
            leverageData
        );

        // Fail if terminal position is not allowed with no additional
        // adjustment.
        marketManager.canBorrowWithPrune(address(this), account, 0);
    }

    /// @notice Repays underlying tokens to lenders, freeing up their
    ///         collateral posted inside this market.
    /// @dev Updates interest before executing the repayment.
    /// @param amount The amount to repay, or 0 for the full outstanding amount.
    function repay(uint256 amount) external nonReentrant {
        // Update pending interest.
        accrueInterest();

        _repay(msg.sender, msg.sender, amount);
    }

    /// @notice Repays underlying tokens to lenders, on behalf of `account`,
    ///         freeing up their collateral posted inside this market.
    /// @dev Updates pending interest before executing the repay.
    /// @param account The account address to repay on behalf of.
    /// @param amount The amount to repay, or 0 for the full outstanding amount.
    function repayFor(address account, uint256 amount) external nonReentrant {
        // Update pending interest.
        accrueInterest();

        _repay(msg.sender, account, amount);
    }

    /// @notice Liquidates `account`'s collateral by repaying `amount` debt
    ///         and transferring the liquidated collateral to the liquidator.
    /// @dev Updates pending interest before executing the liquidation.
    /// @param accounts The addresses of the accounts to be liquidated.
    /// @param amounts The amounts of underlying asset the liquidator
    ///                wishes to repay.
    /// @param pToken The market in which to seize collateral from `account`.
    function liquidateExact(
        address[] calldata accounts,
        uint256[] calldata amounts,
        address pToken
    ) external nonReentrant {
        uint256 numAccounts = accounts.length;
        if (numAccounts != amounts.length) {
            _revert(_VALIDATION_FAILED_SELECTOR);
        }

        _liquidate(msg.sender, accounts, amounts, pToken, numAccounts, true);
    }

    /// @notice Liquidates `account`'s as much collateral as possible by
    ///         repaying debt and transferring the liquidated collateral
    ///         to the liquidator.
    /// @dev Updates pending interest before executing the liquidation.
    /// @param accounts The addresses of the accounts to be liquidated.
    /// @param pToken The market in which to seize collateral from `account`.
    function liquidate(
        address[] calldata accounts,
        address pToken
    ) external nonReentrant {
        uint256 numAccounts = accounts.length;
        // Amounts array is empty since the max amount possible
        // will be liquidated.
        uint256[] memory amounts = new uint256[](numAccounts);
        
        _liquidate(
            msg.sender,
            accounts,
            amounts,
            pToken,
            numAccounts,
            false
        );
    }

    /// @notice Redeems eTokens in exchange for the underlying asset.
    /// @dev Updates pending interest before executing the redemption.
    /// @param tokens The number of eTokens to redeem for underlying tokens.
    /// @param recipient The account who will receive the underlying assets.
    /// @return amount Returns amount of underlying asset redeemed.
    function redeem(
        uint256 tokens,
        address recipient
    ) external nonReentrant returns (uint256 amount) {
        // Update pending interest.
        accrueInterest();

        // Validate that `tokens` can be redeemed based on holding time.
        marketManager.canRedeem(address(this), msg.sender, tokens);

        amount = _redeem(
            msg.sender,
            recipient,
            tokens,
            convertToAssets(tokens)
        );
    }

    /// @notice Used by a delegated user to redeem eTokens in exchange for
    ///         the underlying asset, on behalf of `account`.
    /// @dev Updates pending interest before executing the redemption.
    ///      NOTE: Be careful who you approve here!
    ///      Not only can they take borrowed funds, but, they can delay
    ///      repayment through repeated borrows preventing withdrawal.
    /// @param tokens The number of eTokens to redeem for underlying tokens.
    /// @param recipient The account who will receive the underlying assets.
    /// @param account The account who will have their eTokens redeemed.
    /// @return amount Returns amount of underlying asset redeemed.
    function redeemFor(
        uint256 tokens,
        address recipient,
        address account
    ) external nonReentrant returns (uint256 amount) {
        _checkDelegate(account, msg.sender);

        // Update pending interest.
        accrueInterest();

        // Validate that `tokens` can be redeemed and maintain collateral
        // requirements.
        marketManager.canRedeem(address(this), account, tokens);

        amount = _redeem(account, recipient, tokens, convertToAssets(tokens));
    }

    /// @notice Used by the position management contract to redeem underlying tokens
    ///         from the market, on behalf of `account` to apply a complex action.
    /// @dev Only Position folding contract can call this function.
    ///      Updates interest before executing the redemption.
    ///      This function may seem weird at first since eTokens can not be
    ///      collateralized, but with this technology a user can redeem lent
    ///      assets and route them directly into collateral deposits in a
    ///      single transaction.
    /// @param account The account address to redeem eTokens on behalf of.
    /// @param amount The amount of the underlying asset to redeem.
    /// @param params Callback calldata to execute after redemption.
    function redeemUnderlyingForPositionManagement(
        address account,
        uint256 amount,
        IPositionManagement.DeleverageStruct memory params
    ) external nonReentrant {
        if (!marketManager.positionManagement(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        // Update pending interest.
        accrueInterest();

        _redeem(account, msg.sender, convertToShares(amount), amount);

        IPositionManagement(msg.sender).onRedeem(
            address(this),
            account,
            amount,
            params
        );

        // Fail if redeem not allowed, after position folding
        // has executed `account`'s extra actions.
        marketManager.canRedeem(address(this), account, 0);
    }

    /// @notice Deposits underlying assets into the market,
    ///         and receives eTokens.
    /// @dev Updates pending interest before executing the mint inside
    ///      the internal helper function.
    /// @param amount The amount of the underlying assets to deposit.
    /// @return tokens Returns the amount of eTokens minted.
    function mint(
        uint256 amount
    ) external nonReentrant returns (uint256 tokens) {
        tokens = _mint(msg.sender, msg.sender, amount);
    }

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
    ) external nonReentrant returns (uint256 tokens) {
        tokens = _mint(msg.sender, recipient, amount);
    }

    /// @notice Adds reserves by transferring from Curvance DAO
    ///         to the market.
    /// @dev Updates pending interest before executing the reserve deposit.
    /// @param amount The amount of underlying tokens to add as reserves,
    ///               in assets.
    function depositReserves(uint256 amount) external nonReentrant {
        _checkDaoPermissions();
        _checkZeroAmount(amount);

        // Update pending interest.
        accrueInterest();

        // Calculate asset -> shares exchange rate.
        uint256 tokens = convertToShares(amount);

        // On success, the market will deposit `amount` to the market.
        SafeTransferLib.safeTransferFrom(
            underlying,
            msg.sender,
            address(this),
            amount
        );

        // Query current DAO operating address.
        address daoAddress = centralRegistry.daoAddress();

        _afterDepositAction(daoAddress, tokens);
        // Update reserves.
        totalReserves = totalReserves + tokens;
    }

    /// @notice Reduces reserves by withdrawing from the market
    ///         and transfers them to Curvance DAO.
    /// @dev If daoAddress is going to be moved all reserves should be
    ///      withdrawn first. Updates pending interest before executing
    ///      the reserve withdrawal.
    /// @param amount Amount of reserves to withdraw, in assets.
    function withdrawReserves(uint256 amount) external nonReentrant {
        _checkDaoPermissions();

        // Update pending interest.
        accrueInterest();

        // Convert `amount` assets to shares to match totalReserves
        // denomination.
        uint256 tokens = convertToShares(amount);

        _withdrawReserves(tokens, amount);
    }

    /// @notice Withdraws all reserves from the market and transfers them to
    ///         Curvance DAO.
    /// @dev If daoAddress is going to be moved all reserves should be
    ///      withdrawn first. Updates pending interest before executing
    ///      the reserve withdrawal.
    function processWithdrawReserves() external {
        // Only callable via the DAO Operator via Central Registry.
        if (msg.sender != address(centralRegistry)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        // Update pending interest.
        accrueInterest();

        uint256 tokens = totalReserves;
        uint256 amount = convertToAssets(tokens);

        _withdrawReserves(tokens, amount);
    }

    /// @notice Sets `amount` as the allowance of `spender` over the
    ///         caller's tokens.
    /// @dev Emits an {Approval} event.
    /// @param spender The address that will be approved to spend `amount`
    ///                eTokens on behalf of the caller.
    /// @param tokens The amount of eTokens that should be approved
    ///               for spending by `spender`.
    /// @return Returns true on success.
    function approve(address spender, uint256 tokens) external returns (bool) {
        allowance[msg.sender][spender] = tokens;

        emit Approval(msg.sender, spender, tokens);
        return true;
    }

    /// @notice Updates pending interest and returns the up-to-date balance
    ///         of `account`, in underlying assets, safely.
    /// @param account The account address to have their balance measured.
    /// @return The amount of underlying owned by `account`.
    function balanceOfUnderlyingSafe(
        address account
    ) external returns (uint256) {
        return ((exchangeRateWithUpdateSafe() * balanceOf[account]) / WAD);
    }

    /// @notice Get a snapshot of the account's balances, and the cached
    ///         exchange rate.
    /// @dev This is used by marketManager to more efficiently perform
    ///      liquidity checks.
    /// @param account The address of the account to snapshot.
    /// @return Account token balance.
    /// @return Account debt balance.
    /// @return Token => Underlying exchange rate, in `WAD`.
    function getSnapshot(
        address account
    ) external view returns (uint256, uint256, uint256) {
        return (
            balanceOf[account],
            debtBalanceCached(account),
            exchangeRateCached()
        );
    }

    /// @notice Get a snapshot of the eToken and `account` data.
    /// @dev Used by marketManager to more efficiently perform
    ///      liquidity checks.
    ///      NOTE: Exchange Rate returns 0 to save gas in marketManager
    ///            since its unused.
    /// @param account The address of the account to snapshot.
    /// @return The account snapshot of `account`.
    function getSnapshotPacked(
        address account
    ) external view returns (AccountSnapshot memory) {
        return (
            AccountSnapshot({
                asset: address(this),
                isPToken: false,
                decimals: decimals(),
                debtBalance: debtBalanceCached(account),
                exchangeRate: 0 // Unused in marketManager.
            })
        );
    }

    /// @notice Updates pending interest and then returns the current
    ///         total borrows, safely.
    /// @dev Used for third party integrations.
    /// @return Total borrows underlying token, with pending interest applied.
    function totalBorrowsWithUpdateSafe()
        external
        nonReentrant
        returns (uint256)
    {
        // Update pending interest.
        accrueInterest();

        return totalBorrows;
    }

    /// @notice Updates pending interest and returns the current debt balance
    ///         for `account`, safely.
    /// @param account The address whose debt balance should be calculated.
    /// @return The current balance index of `account`, with pending interest
    ///         applied.
    function debtBalanceWithUpdateSafe(
        address account
    ) external nonReentrant returns (uint256) {
        // Update pending interest.
        accrueInterest();

        return debtBalanceCached(account);
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Returns the future debt balance for `account` assuming
    ///         interest rates do not change.
    /// @param account The address whose debt balance should be calculated.
    /// @param timestamp The unix timestamp to calculate `account` debt
    ///                  balance with.
    /// @return The debt balance at the given timestamp.
    function debtBalanceAtTimestamp(
        address account,
        uint256 timestamp
    ) public view returns (uint256) {
        // Cache current exchange rate data.
        MarketData memory cachedData = marketData;
        // If `timestamp` is before block.timestamp, use current timestamp.
        timestamp = timestamp < block.timestamp ? block.timestamp : timestamp;

        // If we are up to date there is no reason to continue.
        if (
            cachedData.lastTimestampUpdated + cachedData.compoundRate >
            timestamp
        ) {
            return debtBalanceCached(account);
        }

        // Cache borrow data to save gas.
        DebtData memory accountDebt = _debtOf[account];

        if (accountDebt.principal == 0) {
            return 0;
        }

        // Cache current values to save gas.
        uint256 borrowsPrior = totalBorrows;
        uint256 reservesPrior = totalReserves;
        uint256 exchangeRatePrior = cachedData.exchangeRate;

        // Calculate the current borrow interest rate.
        uint256 borrowRate = interestRateModel.getBorrowRate(
            marketUnderlyingHeld(),
            borrowsPrior,
            reservesPrior
        );

        // Calculate the interest compound cycles to update,
        // in `interestCompounds`. Rounds down natively.
        uint256 interestCompounds = (timestamp -
            cachedData.lastTimestampUpdated) / cachedData.compoundRate;
        // Calculate the interest and debt accumulated.
        uint256 interestAccumulated = borrowRate * interestCompounds;
        uint256 exchangeRateNew = ((interestAccumulated * exchangeRatePrior) /
            WAD) + exchangeRatePrior;

        // Calculate debt balance using the interest index:
        // debtBalanceCached calculation:
        // ((Account's principal * EToken's exchange rate) /
        // Account's exchange rate).
        return
            FixedPointMathLib.mulDivUp(
                accountDebt.principal,
                exchangeRateNew,
                accountDebt.accountExchangeRate
            );
    }

    /// @notice Returns the current debt balance for `account`.
    /// @dev Note: Pending interest is not applied in this calculation.
    /// @param account The address whose debt balance should be calculated.
    /// @return The current balance index of `account`.
    function debtBalanceCached(address account) public view returns (uint256) {
        // Cache borrow data to save gas.
        DebtData memory accountDebt = _debtOf[account];

        // If theres no principal owed, can return immediately.
        if (accountDebt.principal == 0) {
            return 0;
        }

        // Calculate debt balance using the interest index:
        // debtBalanceCached calculation:
        // ((Account's principal * EToken's exchange rate) /
        // Account's exchange rate).
        return
            FixedPointMathLib.mulDivUp(
                accountDebt.principal,
                marketData.exchangeRate,
                accountDebt.accountExchangeRate
            );
    }

    /// @notice Returns the decimals of the eToken.
    /// @dev We pull directly from underlying incase its a proxy contract,
    ///      and changes decimals on us.
    /// @return The number of decimals for this eToken,
    ///         matching the underlying token.
    function decimals() public view returns (uint8) {
        return IERC20(underlying).decimals();
    }

    /// @notice Gets balance of this contract, in terms of the underlying.
    /// @dev This excludes changes in underlying token balance by the
    ///      current transaction, if any.
    /// @return The quantity of underlying tokens held by the market.
    function marketUnderlyingHeld() public view returns (uint256) {
        return IERC20(underlying).balanceOf(address(this));
    }

    /// @notice Returns the type of Curvance token.
    /// @dev true = Position token; false = Debt token.
    /// @return Whether this token is a pToken or not.
    function isPToken() public pure returns (bool) {
        return false;
    }

    /// @notice Updates pending interest and returns the up-to-date exchange
    ///         rate from the underlying to the eToken.
    /// @return Calculated exchange rate, in `WAD`.
    function exchangeRateWithUpdate() public returns (uint256) {
        // Update pending interest.
        accrueInterest();
        return exchangeRateCached();
    }

    /// @notice Updates pending interest and returns the up-to-date exchange
    ///         rate from the underlying to the eToken, safely.
    /// @return Calculated exchange rate, in `WAD`.
    function exchangeRateWithUpdateSafe()
        public
        nonReentrant
        returns (uint256)
    {
        // Update pending interest.
        accrueInterest();
        return exchangeRateCached();
    }

    /// @notice Returns the up-to-date exchange rate from the underlying
    ///         to the eToken.
    /// @return Cached exchange rate, in `WAD`.
    function exchangeRateCached() public view returns (uint256) {
        // We do not need to check for totalSupply = 0, because,
        // when we list a market we mint `_BASE_UNDERLYING_RESERVE` initially.
        // exchangeRate calculation:
        // (Underlying Held + Total Borrows) / (Total Supply + Total Reserves).
        return
            FixedPointMathLib.mulDiv(
                marketUnderlyingHeld() + totalBorrows,
                WAD,
                totalSupply + totalReserves
            );
    }

    /// @notice Returns the amount of tokens that would be exchanged
    ///         by the vault for `amount` provided.
    /// @param amount The number of underlying to theoretically use
    ///               for conversion to tokens.
    /// @return The number of tokens a user would receive for converting
    ///         `amount`.
    function convertToShares(uint256 amount) public view returns (uint256) {
        return FixedPointMathLib.mulDiv(amount, WAD, exchangeRateCached());
    }

    /// @notice Returns the amount of underlying that would be exchanged
    ///         by the vault for `tokens` provided.
    /// @param tokens The number of tokens to theoretically use
    ///               for conversion to underlying.
    /// @return The number of underlying a user would receive for converting
    ///         `tokens`.
    function convertToAssets(uint256 tokens) public view returns (uint256) {
        return FixedPointMathLib.mulDiv(tokens, exchangeRateCached(), WAD);
    }

    /// @inheritdoc ERC165
    /// @param interfaceId The interface ID to check.
    /// @return Whether the contract implements the interface.
    function supportsInterface(
        bytes4 interfaceId
    ) public view override returns (bool) {
        return
            interfaceId == type(IMToken).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// @notice Applies pending interest to all holders, updating
    ///         `totalBorrows` and `totalReserves`.
    /// @dev This calculates interest accrued from the last checkpoint
    ///      up to the latest available checkpoint, if `compoundRate`
    ///      seconds has passed.
    ///      Emits a {InterestAccrued} event.
    function accrueInterest() public {
        // Cache current exchange rate data.
        MarketData memory cachedData = marketData;

        // If we are up to date there is no reason to continue.
        if (
            cachedData.lastTimestampUpdated + cachedData.compoundRate >
            block.timestamp
        ) {
            return;
        }

        // Cache current values to save gas.
        uint256 borrowsPrior = totalBorrows;
        uint256 reservesPrior = totalReserves;
        uint256 exchangeRatePrior = cachedData.exchangeRate;

        // Calculate the current borrow interest rate.
        uint256 borrowRate = interestRateModel.getBorrowRateWithUpdate(
            marketUnderlyingHeld(),
            borrowsPrior,
            convertToAssets(reservesPrior)
        );

        // Calculate the interest compound cycles to update,
        // in `interestCompounds`. Rounds down natively.
        uint256 interestCompounds = (block.timestamp -
            cachedData.lastTimestampUpdated) / cachedData.compoundRate;
        // Calculate the interest and debt accumulated.
        uint256 interestAccumulated = borrowRate * interestCompounds;
        uint256 debtAccumulated = (interestAccumulated * borrowsPrior) / WAD;
        // Calculate new borrows, and the new exchange rate, based on
        // accumulation values above.
        uint256 totalBorrowsNew = debtAccumulated + borrowsPrior;
        uint256 exchangeRateNew = ((interestAccumulated * exchangeRatePrior) /
            WAD) + exchangeRatePrior;
        // Update update timestamp, exchange rate, and total outstanding
        // borrows.
        marketData.lastTimestampUpdated = uint40(
            cachedData.lastTimestampUpdated +
                (interestCompounds * cachedData.compoundRate)
        );
        marketData.exchangeRate = uint216(exchangeRateNew);

        // Check whether the DAO takes a cut of interest, and whether new debt
        // has accumulated (!= 0). Then update reserves if necessary.
        uint256 newReserves = ((interestFactor *
            convertToShares(debtAccumulated)) / WAD);

        totalBorrows = totalBorrowsNew;
        if (newReserves > 0) {
            totalReserves = newReserves + reservesPrior;
            _afterDepositAction(centralRegistry.daoAddress(), newReserves);
        }

        emit InterestAccrued(
            debtAccumulated,
            exchangeRateNew,
            totalBorrowsNew
        );
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Updates the interest rate model.
    /// @dev Emits a {NewMarketInterestRateModel} event.
    /// @param newInterestRateModel The new interest rate model for this
    ///                             eToken to use.
    function _setInterestRateModel(
        IInterestRateModel newInterestRateModel
    ) internal {
        // Ensure we are switching to an actual Interest Rate Model.
        if (
            !ERC165Checker.supportsInterface(
                address(newInterestRateModel),
                type(IInterestRateModel).interfaceId
            )
        ) {
            _revert(_VALIDATION_FAILED_SELECTOR);
        }

        // Cache the current interest rate model to save gas.
        address oldInterestRateModel = address(interestRateModel);

        // Set new interest rate model and compound rate.
        interestRateModel = newInterestRateModel;
        marketData.compoundRate = newInterestRateModel.compoundRate();

        emit NewMarketInterestRateModel(
            oldInterestRateModel,
            address(newInterestRateModel),
            marketData.compoundRate
        );
    }

    /// @notice Updates the interest factor.
    /// @dev Emits a {NewInterestFactor} event.
    /// @param newInterestFactor The new interest factor for this
    ///                          eToken to use.
    function _setInterestFactor(uint256 newInterestFactor) internal {
        // The DAO cannot take more than 50% of interest collected.
        if (newInterestFactor > 5000) {
            revert EToken__ExcessiveValue();
        }

        // Cache the other interest factor for event emission.
        uint256 oldInterestFactor = interestFactor;

        /// The Interest Rate Factor should be stored is in `WAD` format.
        /// So, we need to multiply by 1e14 to convert from basis points
        /// to `WAD`.
        interestFactor = newInterestFactor * 1e14;

        emit NewInterestFactor(oldInterestFactor, interestFactor);
    }

    /// @notice Transfers `tokens` tokens from `from` to `to`, executed by
    ///         `spender`.
    /// @dev Emits a {Transfer} event.
    /// @param spender The address of the account executing the transfer.
    /// @param from The address of to transfer `amount` eTokens.
    /// @param to The address to receive `amount` eTokens.
    /// @param tokens The number of tokens to transfer.
    function _transfer(
        address spender,
        address from,
        address to,
        uint256 tokens
    ) internal {
        // Do not allow self-transfers.
        if (from == to) {
            revert EToken__TransferError();
        }
        _checkZeroAmount(tokens);

        // Fails if transfer not allowed.
        marketManager.canTransferEToken(address(this), from, tokens);

        // Get the allowance, if the spender is not the `from` address.
        if (spender != from) {
            // Validate that spender has enough allowance
            // for the transfer with underflow check.
            allowance[from][spender] = allowance[from][spender] - tokens;
        }

        _beforeTransferAction(from, to, tokens);

        // Update account token balances.
        balanceOf[from] = balanceOf[from] - tokens;
        // We know that from balance wont overflow
        // due to underflow check above.
        unchecked {
            balanceOf[to] = balanceOf[to] + tokens;
        }

        // We emit a Transfer event.
        emit Transfer(from, to, tokens);
    }

    /// @notice Mints eTokens to `recipient`, based on the deposit of
    ///         underlying assets into the market by `minter`.
    /// @dev Updates pending interest before executing the mint.
    ///      Emits a {Transfer} event.
    /// @param minter The address of the account which is supplying the assets.
    /// @param recipient The address of the account which will receive eToken.
    /// @param amount The amount of the underlying asset to supply.
    /// @return tokens The number of eTokens minted.
    function _mint(
        address minter,
        address recipient,
        uint256 amount
    ) internal returns (uint256) {
        _checkZeroAmount(amount);

        // Update pending interest.
        accrueInterest();

        // Fail if mint not allowed.
        marketManager.canMint(address(this));

        // Calculate eTokens to be minted.
        uint256 tokens = convertToShares(amount);

        return _processMint(minter, recipient, tokens, amount);
    }

    /// @notice Redeems eTokens, in exchange for the underlying asset.
    /// @dev Emits a {Transfer} event.
    /// @param account The address of the account which is redeeming the eTokens.
    /// @param recipient The address of the account which will receive the
    ///                  underlying tokens.
    /// @param tokens The number of eTokens to redeem for underlying tokens.
    /// @param amount The number of underlying tokens to distribute to `recipient`.
    /// @return The number of underlying tokens distributed to `recipient`.
    function _redeem(
        address account,
        address recipient,
        uint256 tokens,
        uint256 amount
    ) internal returns (uint256) {
        _checkZeroAmount(amount);
        _checkUnderlyingHeld(totalReserves, amount);

        // Update account balance and totalSupply.
        balanceOf[account] = balanceOf[account] - tokens;
        // We have account underflow check above so we do not need
        // a redundant check here.
        unchecked {
            totalSupply = totalSupply - tokens;
        }

        _beforeWithdrawAction(account, tokens);
        // Transfer underlying to `recipient`.
        SafeTransferLib.safeTransfer(underlying, recipient, amount);

        emit Transfer(account, address(0), tokens);
        return amount;
    }

    /// @notice Executes borrowing of assets for `account` from lenders.
    /// @dev Emits a {Borrow} event.
    /// @param account The account borrowing assets.
    /// @param amount The amount of the underlying asset to borrow.
    /// @param recipient The account receiving the borrowed assets.
    function _borrow(
        address account,
        uint256 amount,
        address recipient
    ) internal {
        _checkZeroAmount(amount);
        _checkUnderlyingHeld(totalReserves, amount);

        // Calculate current account debt then add `amount`.
        // Then update account exchange rate, and total borrow balances.
        _debtOf[account].principal = debtBalanceCached(account) + amount;
        _debtOf[account].accountExchangeRate = marketData.exchangeRate;
        totalBorrows = totalBorrows + amount;

        // Transfer underlying to `recipient`.
        SafeTransferLib.safeTransfer(underlying, recipient, amount);

        emit Borrow(account, amount);
    }

    /// @notice Mints eTokens to `recipient`, based on the deposit of
    ///         underlying assets into the market by `minter`.
    /// @dev Updates pending interest before executing the mint.
    ///      Emits a {Transfer} event.
    /// @param minter The address of the account which is supplying the assets.
    /// @param recipient The address of the account which will receive eToken.
    /// @param amount The amount of the eTokens to be minted.
    /// @param amount The amount of the underlying asset to supply.
    /// @return The number of eTokens minted.
    function _processMint(
        address minter,
        address recipient,
        uint256 tokens,
        uint256 amount
    ) internal returns (uint256) {
        // Transfer underlying into the eToken contract.
        SafeTransferLib.safeTransferFrom(
            underlying,
            minter,
            address(this),
            amount
        );

        // Update totalSupply, and recipient balance.
        unchecked {
            totalSupply = totalSupply + tokens;
            /// Calculate their new balance.
            balanceOf[recipient] = balanceOf[recipient] + tokens;
        }

        _afterDepositAction(recipient, tokens);
        emit Transfer(address(0), recipient, tokens);
        return tokens;
    }

    /// @notice Repays an outstanding loan of `account` through repayment
    ///         by `payer`, who usually is themselves.
    /// @dev Emits a {Repay} event.
    /// @param payer The address paying down the account debt.
    /// @param account The account with the debt being paid down.
    /// @param amount The amount the payer wishes to repay,
    ///               or 0 for the full outstanding amount.
    /// @return The amount of underlying token debt repaid for `account`.
    function _repay(
        address payer,
        address account,
        uint256 amount
    ) internal returns (uint256) {
        // Validate that the payer is allowed to repay the loan.
        marketManager.canRepay(address(this), account);

        // Cache how much the account has to save gas.
        uint256 accountDebt = debtBalanceCached(account);

        // If amount == 0, repay max; amount = accountDebt.
        amount = amount == 0 ? accountDebt : amount;
        _checkZeroAmount(amount);

        // Validate repayment amount is not excessive.
        if (amount > accountDebt) {
            revert EToken__ExcessiveValue();
        }

        SafeTransferLib.safeTransferFrom(
            underlying,
            payer,
            address(this),
            amount
        );

        // We calculate the new account and total borrow balances,
        // we check that amount is <= accountDebt so we can skip
        // underflow check here.
        unchecked {
            _debtOf[account].principal = accountDebt - amount;
        }
        _debtOf[account].accountExchangeRate = marketData.exchangeRate;
        // We round user debt in favor of the protocol to prevent exchange
        // rate manipulation, as a result in some cases the last user cannot
        // fully repay their debt.
        if (totalBorrows < amount) {
            totalBorrows = 0;
        } else {
            totalBorrows -= amount;
        }

        emit Repay(payer, account, amount);
        return amount;
    }

    /// @notice Facilitates a liquidator liquidating the borrowers collateral
    ///         by repaying a portion of their debt. The collateral seized
    ///         is transferred to the liquidator.
    /// @dev Emits {Repay} and {Liquidated} events.
    /// @param liquidator The address repaying the borrow and seizing collateral.
    /// @param accounts The accounts to be liquidated.
    /// @param amounts The amounts of the underlying borrowed asset to repay,
    ///                if exact liquidation, otherwise an empty array to
    ///                populate real liquidation amounts after calculations.
    /// @param pToken The market in which to seize collateral from
    ///               the account.
    /// @param numAccounts The number of accounts to be potentially
    ///                    liquidated.
    /// @param exactAmount Whether a specific amount of debt token assets
    ///                    should be liquidated inputting false will attempt
    ///                    to liquidate the maximum amount possible.
    function _liquidate(
        address liquidator,
        address[] memory accounts,
        uint256[] memory amounts,
        address pToken,
        uint256 numAccounts,
        bool exactAmount
    ) internal {
        // Update pending interest.
        accrueInterest();

        // The MToken must be a position token.
        if (!IPToken(pToken).isPToken()) {
            _revert(_VALIDATION_FAILED_SELECTOR);
        }

        // Validate that the token is listed inside the market.
        if (!marketManager.isListed(address(this))) {
            _revert(_VALIDATION_FAILED_SELECTOR);
        }

        IMarketManager.LiqResults memory liqResults;

        // Fail if liquidate not allowed,
        // trying to pay too much debt with excessive `amount` will revert.
        (
            liqResults,
            amounts
        ) = marketManager.canLiquidateWithExecution(
            liquidator,
            accounts,
            amounts,
            IMarketManager.LiqInstructions({
                eToken: address(this),
                pToken: pToken,
                numAccounts: numAccounts,
                liquidateExact: exactAmount,
                eTokenRepaid: 0,
                pTokenLiquidated: 0,
                badDebt: 0
            })
        );

        SafeTransferLib.safeTransferFrom(
            underlying,
            liquidator,
            address(this),
            liqResults.debtRepaid
        );

        uint256 currentExchangeRate = marketData.exchangeRate;
        uint256 cachedAmount;
        address cachedAccount;
        // Self liquidation check moved to Market Manager

        for (uint256 i; i < numAccounts; ++i) {
            cachedAmount = amounts[i];
            // If theres no debt to repay for this user can
            // skip them.
            if (cachedAmount == 0) {
                continue;
            }

            cachedAccount = accounts[i];

            uint256 accountDebt = debtBalanceCached(accounts[i]);
            // We do not need to check `amounts[i]` against `accountDebt`
            // because amounts are already sanitized inside
            // canLiquidateWithExecution.

            // We calculate the new account and total borrow balances,
            // we check that amount is <= accountDebt inside
            // canLiquidateWithExecution but we redundantly leave in
            // underflow check incase invariants are broken.
            _debtOf[cachedAccount].principal = accountDebt - cachedAmount;

            // Update the account specific exchange rate.
            _debtOf[cachedAccount].accountExchangeRate = currentExchangeRate;
            emit Repay(liquidator, cachedAccount, cachedAmount);
        }

        // We need to update totalBorrows for the total debt repaid by the
        // liquidator, plus the bad debt being realized. We can reuse
        // debtRepaid variable since the original debt repayment value
        // was already used earlier.
        liqResults.debtRepaid += liqResults.badDebtRealized;
        if (totalBorrows < liqResults.debtRepaid) {
            // We round user debt in favor of the protocol to prevent exchange
            // rate manipulation, as a result in some cases the last user cannot
            // fully repay their debt.
            totalBorrows = 0;
        } else {
            totalBorrows -= liqResults.debtRepaid;
        }

        // We check above that the mToken must be a position token,
        // so we cant seize this mToken as it is a debt token,
        // so there is no reEntry risk.
        IPToken(pToken).seize(
            liquidator, accounts,
            liqResults.liquidatedAmounts,
            address(this)
        );

        if (liqResults.badDebtRealized > 0) {
            emit BadDebtRecognized(liquidator, liqResults.badDebtRealized);
        }
    }

    /// @notice Withdraws reserves from the market and transfers them to
    ///         Curvance DAO.
    /// @param tokens Amount of reserves to withdraw, in shares.
    /// @param amount Amount of reserves to withdraw, in assets.
    function _withdrawReserves(uint256 tokens, uint256 amount) internal {
        _checkZeroAmount(amount);

        // We can pass 0 reserves to hold since we are redeeming from
        // reserves here directly instead of user driven borrows/redemptions.
        _checkUnderlyingHeld(0, amount);

        // Update reserves with underflow check.
        totalReserves = totalReserves - tokens;

        // Query current DAO operating address.
        address daoAddress = centralRegistry.daoAddress();

        // Withdraw reserves, in shares.
        _beforeWithdrawAction(daoAddress, tokens);
        // Transfer underlying to DAO, in assets.
        SafeTransferLib.safeTransfer(underlying, daoAddress, amount);
    }

    /// @dev Helper function for reverting efficiently.
    function _revert(uint256 s) internal pure {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, s)
            revert(0x1c, 0x04)
        }
    }

    /// @notice Checks whether there is sufficient underlying tokens to handle
    ///         a redemption/borrow of `underlyingToWithdraw` based on any
    ///         protocol reserves held.
    /// @param reservesToHold Protocol Reserves to hold on to, requiring
    ///                       underlying to be held in reserve.
    /// @param underlyingToWithdraw The amount of underlying tokens to
    ///                             redeem/borrow against current underlying
    ///                             held in the eToken contract.
    function _checkUnderlyingHeld(
        uint256 reservesToHold,
        uint256 underlyingToWithdraw
    ) internal view {
        // Check if we have enough underlying held to support the redemption.
        // We add _BASE_UNDERLYING_RESERVE to the calculation to ensure that
        // the market never actually runs out of assets and may introduce
        // invariant manipulation.
        // This also acts as a protective mechanism against trying to
        // manipulate totalBorrows above total underlying assets inside
        // the system since there will always be at least
        // _BASE_UNDERLYING_RESERVE excess inside the market.
        if (
            marketUnderlyingHeld() - convertToAssets(reservesToHold) <
            underlyingToWithdraw + _BASE_UNDERLYING_RESERVE
        ) {
            revert EToken__InsufficientUnderlyingHeld();
        }
    }

    /// @notice Check whether the account and token are valid.
    /// @param account The account to check.
    /// @param token The token to check.
    function _checkAccountAndToken(
        address account,
        address token
    ) internal view {
        // Fail if account = liquidator.
        assembly {
            if eq(account, caller()) {
                // revert with EToken__Unauthorized().
                mstore(0x00, 0xc7e7bc18)
                revert(0x1c, 0x04)
            }
        }

        // The MToken must be a position token.
        if (!IPToken(token).isPToken()) {
            _revert(_VALIDATION_FAILED_SELECTOR);
        }
    }

    /// @notice Checks to make sure an action is not an empty action.
    function _checkZeroAmount(uint256 amount) internal pure {
        if (amount == 0) {
            revert EToken__EmptyAction();
        }
    }

    /// @dev Checks whether the caller has sufficient permissioning.
    function _checkDaoPermissions() internal view {
        if (!centralRegistry.hasDaoPermissions(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }
    }

    /// @dev Checks whether the caller has sufficient permissioning.
    function _checkElevatedPermissions() internal view {
        if (!centralRegistry.hasElevatedPermissions(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }
    }

    /// @dev from Multicall
    /// @return The central registry.
    function _getCentralRegistry()
        internal
        view
        override
        returns (ICentralRegistry)
    {
        return centralRegistry;
    }

    /// INTERNAL FUNCTIONS WHICH CAN BE OVERRIDDEN ///

    /// @notice An optional set of instructions to execute before processing
    ///         a deposit of `to`'s assets.
    function _afterDepositAction(
        address /* to */,
        uint256 /* assets */
    ) internal virtual {}

    /// @notice An optional set of instructions to execute before processing
    ///         a withdrawal of `owners`'s shares.
    function _beforeWithdrawAction(
        address /* owner */,
        uint256 /* shares */
    ) internal virtual {}

    /// @notice An optional set of instructions to execute before processing
    ///         a transfer of `from`'s shares to `to`.
    /// @param amount The number of tokens to transfer from `from` to `to`.
    function _beforeTransferAction(
        address /* from */,
        address /* to */,
        uint256 amount
    ) internal virtual {}
}
