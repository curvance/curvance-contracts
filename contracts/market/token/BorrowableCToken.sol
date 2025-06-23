// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseCTokenWithYield, FixedPointMathLib, ICentralRegistry, IERC20, WAD } from "contracts/market/token/BaseCTokenWithYield.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";

import { ICToken, AccountSnapshot } from "contracts/interfaces/ICToken.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { IPositionManager } from "contracts/interfaces/IPositionManager.sol";
import { IInterestRateModel } from "contracts/interfaces/IInterestRateModel.sol";

contract BorrowableCToken is BaseCTokenWithYield {
    /// TYPES ///

    /// @notice Struct form of `_vestingData`, a bitshifted packed variable.
    ///         With data related to lenders vesting data from outstanding
    ///         debt.
    /// @param vestingRate The rate that the vault vests fresh yield.
    /// @param vestingPeriodEnd When the current vesting period ends.
    /// @param lastVestingClaim Last time vesting yield was claimed.
    /// @param marketDebtIndex The most up to date debt index for
    ///                        calculating account outstanding debt.
    struct VestingData {
        uint96 vestingRate;
        uint40 vestingPeriodEnd;
        uint40 lastVestingClaim;
        uint80 marketDebtIndex;
    }

    /// @notice Struct form of `_debtOf`, a bitshifted packed variable.
    ///         With data related to borrowers vesting data from outstanding
    ///         debt.
    /// @param outstandingDebt Outstanding account debt based on
    ///                        `accountDebtIndex`.
    /// @param accountDebtIndex Current debt index for the account.
    struct DebtData {
        uint176 outstandingDebt;
        uint80 accountDebtIndex;
    }

    /// CONSTANTS ///

    /// @notice Maximum percentage fee that can be taken from interest accrued
    ///         from outstanding debt, in `basis points`.
    /// @dev 5000 = 50%.
    uint256 public constant MAX_INTEREST_ACCRUAL_FEE = 5000;

    /// @dev Mask of vesting rate entry in `_vestingData`.
    uint256 internal constant _BITMASK_VESTING_RATE = (1 << 96) - 1;
    /// @dev Mask of a timestamp entry in `_vestingData`.
    uint256 internal constant _BITMASK_TIMESTAMP = (1 << 40) - 1;
    /// @dev Mask of all bits in packed vault data except the 40 bits
    ///      for `lastVestingClaim`.
    uint256 internal constant _BITMASK_VEST_END_COMPLEMENT = (1 << 136) - 1;
    /// @dev Mask of all bits in packed vault data except the 40 bits
    ///      for `lastVestingClaim`.
    uint256 internal constant _BITMASK_OUTSTANDING_DEBT_COMPLEMENT = (1 << 176) - 1;
    /// @dev The bit position of `vestingPeriodEnd` in `_vestingData`.
    uint256 internal constant _BITPOS_VEST_END = 96;
    /// @dev The bit position of `lastVestingClaim` in `_vestingData`.
    uint256 internal constant _BITPOS_LAST_VEST = 136;
    /// @dev The bit position of `marketDebtIndex` in `_vestingData`.
    uint256 internal constant _BITPOS_DEBT_INDEX = 176;
    /// @dev `bytes4(keccak256(bytes("BorrowableCToken__InvalidParameter()")))`
    uint256 internal constant _INVALID_PARAMETER_SELECTOR = 0x8b5fe5a3;
    
    /// STORAGE ///

    /// @notice Address of the current Interest Rate Model.
    IInterestRateModel public interestRateModel;
    /// @notice Fee that goes to protocol for interested generated for
    ///         lenders, in `WAD`.
    uint256 public interestFee;
    /// @notice The amount of tokens that has been borrowed as debt,
    ///         in assets.
    uint256 public marketOutstandingDebt;

    /// @notice Outstanding debt information associated with an account.
    /// @dev Internal packed debt data:
    ///      Bits Layout:
    ///      - [0..175]   `outstandingDebt`.
    ///      - [176..255] `accountDebtIndex`.
    mapping(address => uint256) internal _debtOf;

    /// EVENTS ///

    event InterestAccrued(
        uint256 debtAccumulated,
        uint256 newMarketDebtIndex,
        uint256 marketOutstandingDebt
    );
    event Borrow(address account, uint256 amount);
    event Repay(address payer, address account, uint256 amount);
    event BadDebtRecognized(address liquidator, uint256 amount);
    event NewMarketInterestRateModel(
        address oldInterestRateModel,
        address newInterestRateModel,
        uint256 newInterestAccrualPeriod
    );
    event NewInterestFee(
        uint256 oldInterestFee,
        uint256 newInterestFee
    );

    /// ERRORS ///

    error BorrowableCToken__InvalidParameter();
    error BorrowableCToken__InsufficientAssetsHeld();

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        IERC20 asset_,
        address marketManager_,
        address interestRateModel_
    ) BaseCTokenWithYield(
        centralRegistry_,
        asset_,
        marketManager_,
        IInterestRateModel(interestRateModel_).accrualPeriod()
    ) {

        // This essentially redundantly sets vestingPeriod twice since we also set
        // it as part of `BaseCTokenWithYield` deployment, but we want to make sure
        // _setInterestRateModel includes this setter incase the interest rate
        // model is ever changed.
        _setInterestRateModel(IInterestRateModel(interestRateModel_));

        // Assign the interest accrual fee for interest generated
        // inside this market.
        uint256 newInterestFee = centralRegistry.protocolInterestFee(
            marketManager_
        );
        interestFee = newInterestFee;

        emit NewInterestFee(0, newInterestFee);
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
    /// @param newInterestFee The new interest factor for this
    ///                          eToken to use.
    function setInterestFee(uint256 newInterestFee) external {
        _checkElevatedPermissions();

        // Update pending interest.
        accrueInterest();

        _setInterestFee(newInterestFee);
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
        marketManager.canBorrowWithNotify(
            address(this),
            msg.sender,
            marketOutstandingDebt + amount,
            amount
        );

        _borrow(msg.sender, amount, msg.sender);
    }

    /// @notice Used by a delegated user to borrow underlying tokens
    ///         from lenders, based on collateral posted inside this market
    ///         by `account`.
    /// @dev Updates pending interest before executing the borrow.
    ///      NOTE: Be careful who you approve here!
    ///      Not only can they take borrowed funds, but, they can delay
    ///      repayment through repeated borrows preventing withdrawal.
    /// @param account The account who will have their assets borrowed
    ///                against.
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
        marketManager.canBorrowWithNotify(
            address(this),
            account,
            marketOutstandingDebt + amount,
            amount
        );

        _borrow(account, amount, recipient);
    }

    /// @notice Used by the position management contract to borrow underlying
    ///         tokens from lenders, based on collateral posted inside this
    ///         market by `account` to apply a complex action.
    /// @dev Only Position Management contract can call this function.
    ///      Updates pending interest before executing the borrow.
    /// @param account The account address to borrow on behalf of.
    /// @param amount The amount of the underlying asset to borrow.
    /// @param leverageData Callback calldata to execute after borrow.
    function borrowForPositionManager(
        address account,
        uint256 amount,
        IPositionManager.LeverageStruct memory leverageData
    ) external nonReentrant {
        if (!marketManager.isPositionManager(msg.sender)) {
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
        IPositionManager(msg.sender).onBorrow(
            address(this),
            account,
            amount,
            leverageData
        );

        // Fail if terminal position is not allowed with no additional
        // adjustment.
        marketManager.canBorrow(
            address(this),
            account,
            marketOutstandingDebt + amount,
            0
        );
    }

    /// @notice Repays underlying tokens to lenders, freeing up their
    ///         collateral posted inside this market.
    /// @dev Updates interest before executing the repayment.
    /// @param amount The amount to repay, or 0 for the full outstanding
    ///               amount.
    function repay(uint256 amount) external nonReentrant {
        // Update pending interest.
        accrueInterest();

        _repay(msg.sender, msg.sender, amount);
    }

    /// @notice Repays underlying tokens to lenders, on behalf of `account`,
    ///         freeing up their collateral posted inside this market.
    /// @dev Updates pending interest before executing the repay.
    /// @param account The account address to repay on behalf of.
    /// @param amount The amount to repay, or 0 for the full outstanding
    ///               amount.
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
            _revert(_INVALID_PARAMETER_SELECTOR);
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

    /// @notice Get a snapshot of the cToken and `account` data.
    /// @dev Used by marketManager to more efficiently perform
    ///      liquidity checks.
    ///      NOTE: Does not accrue pending interest as part of the call.
    /// @param account The address of the account to snapshot.
    /// @return The account snapshot of `account`.
    function getSnapshot(
        address account
    ) external view override returns (AccountSnapshot memory) {
        return (
            AccountSnapshot({
                asset: address(this),
                decimals: decimals(),
                collateralPosted: collateralPosted[account],
                debtOutstanding: debtBalanceCached(account),
                exchangeRate: _convertToAssets(WAD, _getTotalAssets())
            })
        );
    }

    /// @notice Updates pending interest and then returns the current
    ///         market-wide outstanding debt.
    /// @dev Used for third party integrations.
    /// @return result Total market-wide outstanding debt of asset(), with
    ///                pending interest applied.
    function marketOutstandingDebtUpdated()
        external
        nonReentrant
        returns (uint256 result)
    {
        // Update pending interest.
        accrueInterest();

        result = marketOutstandingDebt;
    }

    /// @notice Updates pending interest and returns the current outstanding
    ///         debt owed by `account`.
    /// @dev Used for third party integrations.
    /// @param account The address whose debt balance should be calculated.
    /// @return result The current outstanding debt of `account`, with pending
    ///                interest applied.
    function debtBalanceUpdated(
        address account
    ) external nonReentrant returns (uint256 result) {
        // Update pending interest.
        accrueInterest();

        result = debtBalanceCached(account);
    }

    /// @notice Returns the current debt balance for `account`.
    /// @dev Note: Pending interest is not applied in this calculation.
    /// @param account The address whose debt balance should be calculated.
    /// @return result The current outstanding debt balance of `account`.
    function debtBalanceCached(
        address account
    ) public view returns (uint256 result) {
        // Cache debt data to save gas.
        uint256 debtOf = _debtOf[account];
        uint256 outstandingDebt = uint176(debtOf);
        
        // If theres no outstanding debt, can return immediately with 0.
        if (outstandingDebt == 0) {
            return result;
        }

        // Calculate debt balance using the debt indexes:
        // debtBalanceCached calculation:
        // ((Account's outstanding debt * Market's debt index) /
        // Account's debt index).
        result =
            FixedPointMathLib.mulDivUp(
                outstandingDebt,
                uint80(_vestingData >> _BITPOS_DEBT_INDEX), // pull the last 80 bits of vesting data to grab the market debt index
                uint80(debtOf >> _BITPOS_DEBT_INDEX) // pull the last 80 bits of debtOf to grab the account debt index
            );
    }

    /// @notice Applies pending interest to all holders, updating
    ///         `totalBorrows` and `totalReserves`.
    /// @dev This calculates interest accrued from the last checkpoint
    ///      up to the latest available checkpoint, if `accrualPeriod`
    ///      seconds has passed.
    ///      Emits a {InterestAccrued} event.
    function accrueInterest() public {}

    /// @notice Gets balance of this contract, in terms of the underlying.
    /// @dev This excludes changes in underlying token balance by the
    ///      current transaction, if any.
    /// @return The quantity of underlying tokens held by the market.
    function assetsHeld() public view returns (uint256) {
        return _asset.balanceOf(address(this));
    }

    /// INTERNAL FUNCTIONS ///

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
        _checkAssetsHeld(amount);

        // Calculate current account debt then add `amount`.
        // Then update account exchange rate, and total borrow balances.
        _setDebtOf(account, uint176(debtBalanceCached(account) + amount));
        marketOutstandingDebt = marketOutstandingDebt + amount;

        // Transfer underlying to `recipient`.
        SafeTransferLib.safeTransfer(asset(), recipient, amount);

        emit Borrow(account, amount);
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
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        SafeTransferLib.safeTransferFrom(
            asset(),
            payer,
            address(this),
            amount
        );

        // Update the account and market outstanding debt balance data.
        _setDebtOf(account, uint176(accountDebt - amount));

        // We round user debt in favor of the protocol to prevent exchange
        // rate manipulation, as a result in some cases the last user cannot
        // fully repay their debt.
        if (marketOutstandingDebt < amount) {
            marketOutstandingDebt = 0;
        } else {
            marketOutstandingDebt -= amount;
        }

        emit Repay(payer, account, amount);
        return amount;
    }

    /// @notice Facilitates a liquidator liquidating the borrowers collateral
    ///         by repaying a portion of their debt. The collateral seized
    ///         is transferred to the liquidator.
    /// @dev Emits {Repay} and {Liquidated} events.
    /// @param liquidator The address repaying the borrow and seizing
    ///                   collateral.
    /// @param accounts The accounts to be liquidated.
    /// @param amounts The amounts of the underlying borrowed asset to repay,
    ///                if exact liquidation, otherwise an empty array to
    ///                populate real liquidation amounts after calculations.
    /// @param collateralToken The market in which to seize collateral from
    ///                        the account.
    /// @param numAccounts The number of accounts to be potentially
    ///                    liquidated.
    /// @param exactAmount Whether a specific amount of debt token assets
    ///                    should be liquidated inputting false will attempt
    ///                    to liquidate the maximum amount possible.
    function _liquidate(
        address liquidator,
        address[] memory accounts,
        uint256[] memory amounts,
        address collateralToken,
        uint256 numAccounts,
        bool exactAmount
    ) internal {
        if (collateralToken == address(this)) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        if (!ICToken(collateralToken).isCollateralizable()) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate that the token is listed inside the market (token has
        // been enabled).
        if (!marketManager.isListed(address(this))) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Update pending interest.
        accrueInterest();

        IMarketManager.LiqResults memory liqResults;

        // Fail if liquidate not allowed,
        // trying to pay too much debt with excessive `amount` will revert.
        (
            liqResults,
            amounts
        ) = marketManager.canLiquidate(
            liquidator,
            accounts,
            amounts,
            IMarketManager.LiqInstructions({
                eToken: address(this),
                pToken: collateralToken,
                numAccounts: numAccounts,
                liquidateExact: exactAmount,
                eTokenRepaid: 0,
                pTokenLiquidated: 0,
                badDebt: 0
            })
        );

        SafeTransferLib.safeTransferFrom(
            asset(),
            liquidator,
            address(this),
            liqResults.debtRepaid
        );

        uint256 cachedDebtIndex = uint80(_vestingData >> _BITPOS_DEBT_INDEX);
        uint256 cachedAmount;
        address cachedAccount;
        uint256 newDebtOf;
        // Self liquidation check moved to Market Manager

        for (uint256 i; i < numAccounts; ++i) {
            // Cache the repayment amount.
            cachedAmount = amounts[i];
            // If theres no debt to repay for this user can
            // skip them.
            if (cachedAmount == 0) {
                continue;
            }

            // Calculate the new `account` outstanding debt, then update the
            // account's debt exchange rate index.
            // NOTE: We dont use _getDebtOf because we already cached market's
            // debt exchange rate index and we do not want to repeatedly load
            // that storage slot.
            newDebtOf = debtBalanceCached(
                cachedAccount = accounts[i]
            ) - cachedAmount;
            /// @solidity memory-safe-assembly
            assembly {
                // Mask `newDebtOf` to the lower 176 bits,
                // in case the upper bits somehow aren't clean.
                // Then create the new debtOf variable with:
                // `newDebtOf | cachedDebtIndex`.
                newDebtOf := or(
                    and(newDebtOf, _BITMASK_OUTSTANDING_DEBT_COMPLEMENT),
                    shl(_BITPOS_DEBT_INDEX, cachedDebtIndex)
                )
            }

            // Update `account`'s new debt balance and update their account
            // specific exchange rate index.
            _debtOf[cachedAccount] = newDebtOf;
            emit Repay(liquidator, cachedAccount, cachedAmount);
        }

        // We need to update marketOutstandingDebt for the total debt repaid
        // by the liquidator, plus the bad debt being realized. We can reuse
        // debtRepaid variable since the original debt repayment value
        // was already used earlier.
        liqResults.debtRepaid += liqResults.badDebtRealized;
        if (marketOutstandingDebt < liqResults.debtRepaid) {
            // We round user debt in favor of the protocol to prevent exchange
            // rate manipulation, as a result in some cases the last user
            // cannot fully repay their debt.
            marketOutstandingDebt = 0;
        } else {
            marketOutstandingDebt -= liqResults.debtRepaid;
        }

        // Emit event recognizing any bad debt. 
        if (liqResults.badDebtRealized > 0) {
            emit BadDebtRecognized(liquidator, liqResults.badDebtRealized);
        }

        // We check above that the mToken must be a position token,
        // so we cant seize this mToken as it is a debt token,
        // so there is no reEntry risk.
        ICToken(collateralToken).seize(
            liquidator,
            accounts,
            liqResults.liquidatedAmounts
        );
    }

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
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Cache the current interest rate model to save gas.
        address oldInterestRateModel = address(interestRateModel);

        // Set new interest rate model and compound rate.
        interestRateModel = newInterestRateModel;
        uint256 newVestingPeriod = newInterestRateModel.accrualPeriod();
        vestingPeriod = newVestingPeriod;

        emit NewMarketInterestRateModel(
            oldInterestRateModel,
            address(newInterestRateModel),
            newVestingPeriod
        );
    }

    /// @notice Updates the interest factor.
    /// @dev Emits a {NewInterestFee} event.
    /// @param newInterestFee The new interest factor for this
    ///                          eToken to use.
    function _setInterestFee(uint256 newInterestFee) internal {
        // The DAO cannot take more than 50% of interest collected.
        if (newInterestFee > MAX_INTEREST_ACCRUAL_FEE) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Cache the other interest factor for event emission.
        uint256 oldInterestFee = interestFee;

        /// The Interest Rate Factor should be stored is in `WAD` format.
        /// So, we need to multiply by 1e14 to convert from basis points
        /// to `WAD`.
        interestFee = newInterestFee * 1e14;

        emit NewInterestFee(oldInterestFee, interestFee);
    }

    /// @notice Starts a cToken market, executed via marketManager.
    /// @dev This initial mint is a failsafe against rounding exploits,
    ///      although, we protect against them in many ways,
    ///      better safe than sorry.
    /// @dev Emits a {Deposit} event.
    /// @param by The account initializing the cToken market.
    function _startMarket(address by) internal override {
        // Validate that the interest rate model has been properly linked
        // to this earn token contract.
        if (interestRateModel.linkedToken() != address(this)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        super._startMarket(by);

        // Calculate `_vestingData` invariant to intended start values.
        _vestingData = (_vestingData & _BITMASK_VESTING_RATE) |
            (block.timestamp << _BITPOS_VEST_END) |
            (block.timestamp << _BITPOS_LAST_VEST) |
            (WAD << _BITPOS_DEBT_INDEX);
    }

    /// @notice Checks whether there is sufficient assets to handle
    ///         a withdrawal of `assets` based on assets currently held in
    ///         this contract.
    /// @param assets The amount of assets to withdraw which is checked
    ///               against current assets held in the contract.
    function _checkAssetsHeld(uint256 assets) internal view override {
        // Check if we have enough underlying held to support the withdrawal.
        // We add _BASE_UNDERLYING_RESERVE to the calculation to ensure that
        // the market never actually runs out of assets and may introduce
        // invariant manipulation.
        // This also acts as a protective mechanism against trying to
        // manipulate marketOutstandingDebt above total underlying assets
        // inside the system since there will always be at least
        // _BASE_UNDERLYING_RESERVE excess inside the market.
        if (assetsHeld() < assets + _BASE_UNDERLYING_RESERVE) {
            revert BorrowableCToken__InsufficientAssetsHeld();
        }
    }

    /// @notice Packs `newOutstandingDebt` with current `marketDebtIndex` to
    ///         create new packed `_debtOf` for `account`.
    /// @param account The account to set `_debtOf` value for.
    /// @param newOutstandingDebt The new outstanding debt of `account`.
    function _setDebtOf(
        address account,
        uint176 newOutstandingDebt
    ) internal {
        uint256 marketDebtIndex = uint80(_vestingData >> _BITPOS_DEBT_INDEX);
        uint256 newDebtOf;
        // Cast `newDebtOf` with assembly to avoid redundant masking.
        /// @solidity memory-safe-assembly
        assembly {
            newDebtOf := newOutstandingDebt
    
            // `newDebtOf | marketDebtIndex`.
            newDebtOf := or(
                newDebtOf,
                shl(_BITPOS_DEBT_INDEX, marketDebtIndex)
            )
        }

        _debtOf[account] = newDebtOf;
    }

    /// @notice Sets a new `_vestingData` invariant based on `yieldToVest`,
    ///         and `periodToVest` parameters together with the current
    ///         block timestamp.
    /// @param yieldToVest The yield to vest over `periodToVest`.
    /// @param periodToVest The period in which `yieldToVest` is vested
    ///                     over to users.
    function _setNewVestingData(
        uint256 yieldToVest,
        uint256 periodToVest
    ) internal {}

    /// @notice Packs parameters together with current block timestamp to
    ///         calculate the new packed vault data value.
    /// @param newlastVestTimestamp The timestamp of when the last vest occurred.
    /// @param newDebtExchangeRate The new exchange rate for debt to be
    ///                            calculated at.
    /// @return result The new packed vault data value.
    function _vestInterest(
        uint256 newlastVestTimestamp,
        uint256 newDebtExchangeRate
    ) internal view virtual returns (uint256 result) {}

    /// @notice Returns whether the current vesting period has ended,
    ///         based on the last vest timestamp.
    /// @param packedVestingData Current packed vault data value.
    /// @return result Boolean value indicating whether the current
    ///                vesting period has ended or not.
    function _checkVestStatus(
        uint256 packedVestingData
    ) internal pure override returns (bool result) {}

    /// @notice Calculates pending yield that have been vested.
    /// @dev If there are no pending yield or the vesting period has ended,
    ///      it returns 0.
    /// @return pendingYield The calculated pending yield.
    function _calculatePendingYield()
        internal
        view
        override
        returns (uint256 pendingYield) {}

    /// @notice Vests pending yield, and updates vesting data.
    function _vestYield(uint256 /* newTotalAssets */) internal override {}

}
