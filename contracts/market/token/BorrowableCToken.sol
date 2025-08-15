// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { BaseCTokenWithYield, FixedPointMathLib, ICentralRegistry, IERC20, WAD } from "contracts/market/token/BaseCTokenWithYield.sol";

import { BPS } from "contracts/libraries/ConstantsLib.sol";

import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";

import { ICToken, AccountSnapshot } from "contracts/interfaces/ICToken.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { IPositionManager } from "contracts/interfaces/IPositionManager.sol";
import { IDynamicIRM } from "contracts/interfaces/IDynamicIRM.sol";
import { IFlashLoan } from "contracts/interfaces/IFlashLoan.sol";

contract BorrowableCToken is BaseCTokenWithYield {
    /// CONSTANTS ///

    /// @notice Maximum percentage fee that can be taken from interest accrued
    ///         from outstanding debt, in `basis points`.
    /// @dev 5000 = 50%.
    uint256 public constant MAX_INTEREST_ACCRUAL_FEE = 5000;

    /// @notice Percentage (%) fee on loan taken during a flashloan, in `BPS`.
    /// @dev 5 bps = 0.05%.
    uint256 public constant FLASHLOAN_FEE = 5;

    /// @dev Mask of vesting rate entry in `_vestingData`.
    uint256 internal constant _BITMASK_VESTING_RATE = (1 << 96) - 1;
    /// @dev The bit position of `vestingEnd` in `_vestingData`.
    uint256 internal constant _BITPOS_VEST_END = 96;
    /// @dev The bit position of `lastVestingClaim` in `_vestingData`.
    uint256 internal constant _BITPOS_LAST_VEST = 136;
    /// @dev The bit position of `marketDebtIndex` in `_vestingData`.
    uint256 internal constant _BITPOS_DEBT_INDEX = 176;
    /// @dev `bytes4(keccak256(bytes("BorrowableCToken__InvalidParameter()")))`
    uint256 internal constant _INVALID_PARAMETER_SELECTOR = 0x8b5fe5a3;
    
    /// STORAGE ///

    /// @notice Address of the current Interest Rate Model used to determine
    ///         interest paid by borrowers to lenders for outstanding debt.
    IDynamicIRM public IRM;
    /// @notice The amount of `asset` that has been borrowed as outstanding
    ///         debt, in assets.
    /// @dev We do not need to worry about uint240 overflow here since we
    ///      limit debt caps to type(uint168).max in the Market Manager.
    uint240 public marketOutstandingDebt;
    /// @notice The portion of interest paid by borrowers that goes to the
    ///         protocol, in `BPS`.
    uint16 public interestFee;

    /// @notice Outstanding debt information associated with an account.
    /// @dev Internal packed debt data:
    ///      Bits Layout:
    ///      - [0..175]   `outstandingDebt`.
    ///      - [176..255] `accountDebtIndex`.
    mapping(address => uint256) internal _debtOf;

    /// EVENTS ///

    event RatesAdjusted(uint256 debtPerSecond, uint256 nextAdjustment);
    event Borrow(uint256 assets, address account);
    event Repay(uint256 assets, address payer, address account);
    event Flashloan(uint256 assets, uint256 assetsFee, address account);
    event BadDebtRecognized(uint256 assets, address liquidator);
    event NewIRM(address oldIRM, address newIRM, uint256 newVestingPeriod);
    event NewInterestFee(uint256 oldInterestFee, uint256 newInterestFee);

    /// ERRORS ///

    error BorrowableCToken__CollateralPositionActive();
    error BorrowableCToken__DebtPositionActive();
    error BorrowableCToken__InvalidParameter();
    error BorrowableCToken__InsufficientAssetsHeld();

    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
    /// @param asset_ The address of the underlying asset for this cToken.
    /// @param mm The address of the MarketManager which manages liquidity
    ///           positions between linked cTokens inside a joint market.
    /// @param IRM_ The interest rate model to determine interest
    ///             paid by borrowers to lenders for outstanding debt.
    constructor(
        ICentralRegistry cr,
        IERC20 asset_,
        address mm,
        address IRM_
    ) BaseCTokenWithYield(cr, asset_, mm, IDynamicIRM(IRM_).ADJUSTMENT_RATE()) {
        // We configure `vestingRate` via both `BaseCTokenWithYield()` and
        // `_setIRM()` but this is only for frontends on onchain contracts to
        // call, its more efficient for us to call `ADJUSTMENT_RATE` inside
        // `IRM` to avoid an sLOAD cost on every adjustment period.
        _setIRM(IDynamicIRM(IRM_));

        // Assign the portion of interest paid by borrowers that goes to the
        // protocol.
        _setInterestFee(centralRegistry.protocolInterestFee(mm));
    }

    /// @notice Returns the current vesting yield information.
    /// @return vestingRate % per second in `asset()`.
    /// @return vestingEnd When the current vesting period ends and interest
    ///                    rates paid will update.
    /// @return lastVestingClaim Last time pending vested yield was claimed.
    function getYieldInformation() external view nonReadReentrant returns (
        uint256 vestingRate,
        uint256 vestingEnd,
        uint256 lastVestingClaim
    ) {
        uint256 vestingData = _vestingData;
        vestingRate = uint96(vestingData);
        vestingEnd = uint40(vestingData >> _BITPOS_VEST_END);
        lastVestingClaim = uint40(vestingData >> _BITPOS_LAST_VEST);
    }

    /// @notice Accrues pending interest and updates the interest rate
    ///         model (`IRM`) used by this borrowableCToken.
    /// @dev Admin function to update the interest rate model.
    ///      Emits a {NewIRM} event.
    /// @param newIRM The new interest rate model to determine interest
    ///               paid by borrowers to lenders for outstanding debt.
    function setIRM(address newIRM) external {
        _checkElevatedPermissions();

        // Accrue interest if needed.
        _accrueIfNeeded();

        _setIRM(IDynamicIRM(newIRM));
    }

    /// @notice Accrues pending interest and updates the fee that the protocol
    ///         takes on interest paid by borrowers.
    /// @dev Admin function to update `interestFee`.
    ///      Emits a {NewInterestFee} event.
    /// @param newInterestFee The portion of interest paid by borrowers that
    ///                       goes to the protocol.
    function setInterestFee(uint256 newInterestFee) external {
        _checkElevatedPermissions();

        // Accrue interest if needed.
        _accrueIfNeeded();

        _setInterestFee(newInterestFee);
    }

    /// @notice Borrows underlying tokens from lenders, based on collateral
    ///         posted inside this market by the caller.
    /// @dev Updates pending interest before executing the borrow.
    /// @param assets The amount of the underlying asset to borrow.
    /// @param receiver The account who will receive the borrowed assets.
    function borrow(uint256 assets, address receiver) external nonReentrant {
        // Accrue interest if needed.
        _accrueIfNeeded();

        // Reverts if borrow not allowed.
        // Notifies the Market Manager that a user is taking on more debt,
        // and to pause user redemptions for 20 minutes.
        marketManager.canBorrowWithNotify(
            address(this),
            assets,
            msg.sender,
            marketOutstandingDebt + assets
        );

        _borrow(assets, receiver, msg.sender);
    }

    /// @notice Used by a delegated user to borrow underlying tokens
    ///         from lenders, based on collateral posted inside this market
    ///         by `account`.
    /// @dev Updates pending interest before executing the borrow.
    ///      NOTE: Be careful who you approve here!
    ///      Not only can they take borrowed funds, but, they can delay
    ///      repayment through repeated borrows preventing withdrawal.
    /// @param assets The amount of the underlying asset to borrow.
    /// @param receiver The account who will receive the borrowed assets.
    /// @param owner The account who will have their assets borrowed
    ///              against.
    function borrowFor(
        uint256 assets,
        address receiver,
        address owner
    ) external nonReentrant {
        _checkDelegate(owner, msg.sender);

        // Accrue interest if needed.
        _accrueIfNeeded();

        // Reverts if borrow not allowed.
        // Notifies the Market Manager that a user is taking on more debt,
        // and to pause user redemptions for 20 minutes.
        marketManager.canBorrowWithNotify(
            address(this),
            assets,
            owner,
            marketOutstandingDebt + assets
        );

        _borrow(assets, receiver, owner);
    }

    /// @notice Used by a Position Manager contract to borrow assets from
    ///         lenders, based on collateralized shares by `account` to
    ///         perform a complex action.
    /// @dev Only Position Manager contract can call this function.
    ///      Updates pending interest before executing the borrow.
    /// @param assets The amount of the underlying asset to borrow.
    /// @param action Instructions for a leverage action containing:
    ///               borrowableCToken Address of the borrowableCToken that
    ///                                will be borrowed from and assets
    ///                                swapped into `cToken` asset.
    ///               borrowAssets The amount borrowed from
    ///                            `borrowableCToken`, in assets.
    ///               cToken Curvance token assets that borrowed funds will be
    ///                      swapped into.
    ///               swapAction Swap action instructions converting debt
    ///                          asset into collateral asset to facilitate
    ///                          leveraging.
    ///               auxData Optional auxiliary data for execution of a
    ///                       leverage action.
    /// @param owner The account address to borrow on behalf of.
    function borrowForPositionManager(
        uint256 assets,
        address owner,
        IPositionManager.LeverageAction memory action
    ) external nonReentrant {
        if (!marketManager.isPositionManager(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        // Accrue interest if needed.
        // This generally is a redundant check due to interest accrual
        // done inside `checkSlippage` modifier inside position manager
        // contracts, but we keep this check in for invariant
        // protection in the case of a incorrectly implemented contract.
        _accrueIfNeeded();

        // Notifies the Market Manager that a user is taking on more debt,
        // and to pause user redemptions for 20 minutes.
        marketManager.notifyBorrow(address(this), owner);

        _borrow(assets, msg.sender, owner);

        // Callback to Position Manager to execute remaining leverage logic.
        IPositionManager(msg.sender).onBorrow(
            address(this),
            assets,
            owner,
            action
        );

        // Fail if terminal position is not allowed with no additional
        // adjustment.
        marketManager.canBorrow(
            address(this),
            0,
            owner,
            marketOutstandingDebt + assets
        );
    }

    /// @notice Repays outstanding debt to lenders, freeing up their
    ///         collateral posted inside this market.
    /// @dev Updates interest before executing the repayment.
    /// @param assets The amount to repay, or 0 for the full outstanding
    ///               amount.
    function repay(uint256 assets) external nonReentrant {
        _repay(assets, msg.sender, msg.sender);
    }

    /// @notice Repays outstanding debt to lenders, on behalf of `owner`,
    ///         freeing up their collateral posted inside this market.
    /// @dev Updates pending interest before executing the repay.
    /// @param assets The amount to repay, or 0 for the full outstanding
    ///               amount.
    /// @param owner The account address to repay on behalf of.
    function repayFor(uint256 assets, address owner) external nonReentrant {
        _repay(assets, msg.sender, owner);
    }

    /// @notice Liquidates `accounts`' collateral by repaying `amount` debt
    ///         and transferring the liquidated collateral to the liquidator.
    /// @dev Updates pending interest before executing the liquidation.
    /// @param debtAmounts The amounts of outstanding debt the liquidator
    ///                    wishes to repay, in underlying assets, empty if
    ///                    intention is to liquidate maximum amount possible
    ///                    for each account.
    /// @param accounts The addresses of the accounts to be liquidated.
    /// @param collateralToken The market in which to seize collateral
    ///                        from `accounts`.
    function liquidateExact(
        uint256[] calldata debtAmounts,
        address[] calldata accounts,
        address collateralToken
    ) external nonReentrant {
        uint256 numAccounts = accounts.length;
        if (numAccounts != debtAmounts.length) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        _liquidate(
            debtAmounts,
            msg.sender,
            accounts,
            collateralToken,
            numAccounts,
            true
        );
    }

    /// @notice Liquidates `accounts` for as much collateral as possible by
    ///         repaying debt and transferring the liquidated collateral
    ///         to the liquidator.
    /// @dev Updates pending interest before executing the liquidation.
    /// @param accounts The addresses of the accounts to be liquidated.
    /// @param collateralToken The market in which to seize collateral
    ///                        from `accounts`.
    function liquidate(
        address[] calldata accounts,
        address collateralToken
    ) external nonReentrant {
        uint256 numAccounts = accounts.length;
        // `debtAmounts` array is empty since the max amount possible
        // will be liquidated.
        uint256[] memory debtAmounts = new uint256[](numAccounts);
        
        _liquidate(
            debtAmounts,
            msg.sender,
            accounts,
            collateralToken,
            numAccounts,
            false
        );
    }

    /// @notice Lends a caller `assets` for a transaction to execute
    ///         desired programmatic logic, full return of lent
    ///         assets + a fee by the end of the transaction is
    ///         required.
    /// @param assets The amount of `asset()` loaned during the flashloan.
    /// @param data Arbitrary calldata passed to flashloan callback to execute
    ///             desired action during the flashloan.
    function flashLoan(uint256 assets, bytes calldata data) external {
        _accrueIfNeeded();

        _checkZeroAmount(assets);
        _checkAssetsHeld(assets);

        address token = address(_asset);
        uint256 fee = flashFee(assets);
        uint256 assetsReturned = assets + fee;
        
        SafeTransferLib.safeTransfer(token, msg.sender, assets);

        IFlashLoan(msg.sender).onFlashLoan(assets, assetsReturned, data);

        SafeTransferLib.safeTransferFrom(
            token,
            msg.sender,
            address(this),
            assetsReturned
        );

        _totalAssets = _totalAssets + fee;

        emit Flashloan(assets, fee, msg.sender);
    }

    /// @notice Get a snapshot of the cToken and `account` data.
    /// @dev Used by marketManager to more efficiently perform
    ///      liquidity checks.
    ///      NOTE: Does not accrue pending interest as part of the call.
    /// @param account The address of the account to snapshot.
    /// @return result The account snapshot of `account`.
    function getSnapshot(
        address account
    ) external view override returns (AccountSnapshot memory result) {
        uint256 outstandingDebt = debtBalance(account);

        result.asset = address(this);
        result.decimals = decimals();
        result.isCollateral = outstandingDebt > 0 ? false : true;
        result.exchangeRate = _convertToAssets(WAD, _getTotalAssets());
        result.collateralPosted = collateralPosted[account];
        result.debtBalance = outstandingDebt;
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
        // Accrue interest if needed.
        _accrueIfNeeded();

        result = marketOutstandingDebt;
    }

    /// @notice Updates pending interest and returns the up-to-date exchange
    ///         rate from the underlying to the BorrowableCToken.
    /// @dev Oracle Manager calculates cToken value from this exchange rate.
    /// @return r The share -> asset exchange rate, in `WAD`.
    function exchangeRateUpdated() external nonReentrant returns (uint256 r) {
        // Accrue interest if needed.
        _accrueIfNeeded();
        
        r = _convertToAssets(WAD, _getTotalAssets());
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
        // Accrue interest if needed.
        _accrueIfNeeded();

        result = debtBalance(account);
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Returns the current debt balance for `account`.
    /// @dev Note: Pending interest is not applied in this calculation.
    /// @param account The address whose debt balance should be calculated.
    /// @return r The current outstanding debt balance of `account`.
    function debtBalance(address account) public view returns (uint256 r) {
        // Cache debt data to save gas.
        uint256 debtOf = _debtOf[account];
        uint256 outstandingDebt = uint176(debtOf);
        
        // If theres no outstanding debt, can return immediately with 0.
        if (outstandingDebt == 0) {
            return r;
        }

        // Calculate debt balance using the debt indexes:
        // Debt balance calculation:
        // ((Account's outstanding debt * Market's debt index) /
        // Account's debt index).
        r = FixedPointMathLib.mulDivUp(
            outstandingDebt,
            uint80(_vestingData >> _BITPOS_DEBT_INDEX), // pull the last 80 bits of vesting data to grab the market debt index
            uint80(debtOf >> _BITPOS_DEBT_INDEX) // pull the last 80 bits of debtOf to grab the account debt index
        );
    }

    /// @notice The fee to be charged for a given flashloan.
    /// @param assets The amount of `asset()` lent during the flashloan.
    /// return The assets of `asset()` to be charged for the flashloan.
    function flashFee(uint256 assets) public pure returns (uint256 fee) {
        fee = FixedPointMathLib.mulDivUp(assets, FLASHLOAN_FEE, BPS);
    }

    /// @notice Gets balance of this contract, in terms of the underlying.
    /// @dev This excludes changes in underlying token balance by the
    ///      current transaction, if any.
    /// @return The quantity of underlying tokens held by the market.
    function assetsHeld() public view returns (uint256) {
        return _asset.balanceOf(address(this));
    }

    /// @notice Returns whether the underlying token can be borrowed.
    /// @dev true = Borrowable; false = Not Borrowable.
    /// @return Whether this token is borrowable or not.
    function isBorrowable() public pure override returns (bool) {
        return true;
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Executes borrowing of assets for `account` from lenders.
    /// @dev Emits a {Borrow} event.
    /// @param assets The amount of the underlying asset to borrow.
    /// @param receiver The account receiving the borrowed assets.
    /// @param owner The account borrowing assets.
    function _borrow(
        uint256 assets,
        address receiver,
        address owner
    ) internal {
        _checkZeroAmount(assets);
        _checkAssetsHeld(assets);
        
        // Cannot borrow if `account` already has posted collateral in this
        // market.
        if (collateralPosted[owner] > 0) {
            revert BorrowableCToken__CollateralPositionActive();
        }

        // Calculate current account debt then add `assets`.
        // Then update account exchange rate, and total borrow balances.
        _setDebtOf(
            owner,
            uint176(debtBalance(owner) + assets),
            uint80(_vestingData >> _BITPOS_DEBT_INDEX)
        );
        marketOutstandingDebt = uint240(marketOutstandingDebt + assets);

        // Transfer underlying to `receiver`.
        SafeTransferLib.safeTransfer(asset(), receiver, assets);

        emit Borrow(assets, owner);
    }

    /// @notice Repays an outstanding loan of `account` through repayment
    ///         by `payer`, who usually is themselves.
    /// @dev Emits a {Repay} event.
    /// @param assets The amount the payer wishes to repay,
    ///               or 0 for the full outstanding amount.
    /// @param payer The address paying down the account debt.
    /// @param owner The account with the debt being paid down.
    /// @return The assets of underlying token debt repaid for `account`.
    function _repay(
        uint256 assets,
        address payer,
        address owner
    ) internal returns (uint256) {
        // Accrue interest if needed.
        _accrueIfNeeded();

        // Validate that the payer is allowed to repay the loan.
        marketManager.canRepay(address(this), owner);

        // Cache how much the account has to save gas.
        uint256 debtOf = debtBalance(owner);

        // If assets == 0, repay max; assets = debtOf.
        assets = assets == 0 ? debtOf : assets;
        _checkZeroAmount(assets);

        // Validate repayment amount is not excessive.
        if (assets > debtOf) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        SafeTransferLib.safeTransferFrom(asset(), payer, address(this), assets);

        // Update the account and market outstanding debt balance data.
        _setDebtOf(
            owner,
            uint176(debtOf - assets),
            uint80(_vestingData >> _BITPOS_DEBT_INDEX)
        );

        // We round user debt in favor of the protocol to prevent exchange
        // rate manipulation, as a result in some cases the last user cannot
        // fully repay their debt.
        if (marketOutstandingDebt < assets) {
            marketOutstandingDebt = 0;
        } else {
            marketOutstandingDebt = uint240(marketOutstandingDebt - assets);
        }

        emit Repay(assets, payer, owner);
        return assets;
    }

    /// @notice Facilitates a liquidator liquidating the borrowers collateral
    ///         by repaying a portion of their debt. The collateral seized
    ///         is transferred to the liquidator.
    /// @dev Emits {Repay} and {Liquidated} events.
    /// @param debtAmounts The amounts of outstanding debt the liquidator
    ///                    wishes to repay, in underlying assets, empty if
    ///                    intention is to liquidate maximum amount possible
    ///                    for each account.
    /// @param liquidator The address repaying the borrow and seizing
    ///                   collateral.
    /// @param accounts The accounts to be liquidated.
    /// @param collateralToken The market in which to seize collateral from
    ///                        the account.
    /// @param numAccounts The number of accounts to be potentially
    ///                    liquidated.
    /// @param exactAmount Whether a specific amount of debt token assets
    ///                    should be liquidated inputting false will attempt
    ///                    to liquidate the maximum amount possible.
    function _liquidate(
        uint256[] memory debtAmounts,
        address liquidator,
        address[] calldata accounts,
        address collateralToken,
        uint256 numAccounts,
        bool exactAmount
    ) internal {
        // Cannot have debt and collateral in the same token, so can revert
        // immediately if someone tries.
        if (collateralToken == address(this)) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Accrue interest if needed.
        _accrueIfNeeded();

        IMarketManager.LiqResult memory result;

        // Fails if liquidation not allowed, trying to repay too much debt
        // will revert.
        (result, debtAmounts) = marketManager.canLiquidate(
            debtAmounts,
            liquidator,
            accounts,
            IMarketManager.LiqAction({
                collateralToken: collateralToken,
                debtToken: address(this),
                numAccounts: numAccounts,
                liquidateExact: exactAmount,
                liquidatedShares: 0,
                debtRepaid: 0,
                badDebt: 0
            })
        );

        SafeTransferLib.safeTransferFrom(
            asset(),
            liquidator,
            address(this),
            result.debtRepaid
        );

        uint80 cachedDebtIndex = uint80(_vestingData >> _BITPOS_DEBT_INDEX);
        uint256 debtAmount;
        address account;

        for (uint256 i; i < numAccounts; ++i) {
            // Cache the repayment amount.
            debtAmount = debtAmounts[i];
            // If theres no debt to repay for this user can
            // skip them.
            if (debtAmount == 0) {
                continue;
            }

            account = accounts[i];

            // Calculate the new `account` outstanding debt, then update the
            // account's debt balance and debt index value.
            // Update the account and market outstanding debt balance data.
            _setDebtOf(
                account,
                uint176(debtBalance(account) - debtAmount),
                cachedDebtIndex
            );
            emit Repay(debtAmount, liquidator, account);
        }

        // We need to update marketOutstandingDebt for the total debt repaid
        // by the liquidator, plus the bad debt being realized. We can reuse
        // debtRepaid variable since the original debt repayment value
        // was already used earlier.
        result.debtRepaid += result.badDebtRealized;
        if (marketOutstandingDebt < result.debtRepaid) {
            // We round user debt in favor of the protocol to prevent exchange
            // rate manipulation, as a result in some cases the last user
            // cannot fully repay their debt.
            marketOutstandingDebt = 0;
        } else {
            marketOutstandingDebt =
                uint240(marketOutstandingDebt - result.debtRepaid);
        }

        // Update total assets to recognize that lenders wont be getting
        // `result.badDebtRealized` back due to realized bad debt.
        // Emit corresponding event recognizing bad debt.
        if (result.badDebtRealized > 0) {
            _totalAssets = _totalAssets - result.badDebtRealized;
            emit BadDebtRecognized(result.badDebtRealized, liquidator);
        }

        ICToken(collateralToken).seize(
            result.liquidatedShares,
            liquidator,
            accounts 
        );
    }

    /// @notice Helper function for posting `shares` as collateral
    ///         for `account` inside this market.
    /// @dev Cannot post collateral if `account` already has outstanding
    ///      debt in this token.
    ///      Emits {CollateralUpdated} event.
    ///      May emit {PositionUpdated} event inside Market Manager.
    /// @param shares The amount of shares to post as collateral.
    /// @param owner The account posting collateral.
    function _postCollateral(uint256 shares, address owner) internal override {
        // Cannot post collateral if `owner` already has outstanding debt
        // in this token.
        if (uint176(_debtOf[owner]) > 0) {
            revert BorrowableCToken__DebtPositionActive();
        }

        super._postCollateral(shares, owner);
    }

    /// @notice Can accrue interest yield, configure next interest accrual
    ///         period, and updates vesting data, if needed.
    /// @dev May emit a {RatesAdjusted} event.
    function _accrueIfNeeded() internal override {
        uint256 vestingData = _vestingData;
        uint256 lastVestingClaim = uint40(vestingData >> _BITPOS_LAST_VEST);

        // If no time has passed since the last vest can exit immediately.
        if (block.timestamp == lastVestingClaim) {
            return;
        }

        uint256 rate = uint96(vestingData);
        uint256 vestingEnd = uint40(vestingData >> _BITPOS_VEST_END);
        uint256 marketDebtIndex = uint80(vestingData >> _BITPOS_DEBT_INDEX);
        uint256 outstandingDebt = marketOutstandingDebt;
        uint256 cachedTa = _totalAssets;
        uint256 assetsToVest = _assetsToVest(
            rate,
            outstandingDebt,
            vestingEnd,
            lastVestingClaim
        );

        // Update `lastVestingClaim`, stopping at vesting end if current
        // vesting period is over.
        lastVestingClaim = block.timestamp > vestingEnd ?
            vestingEnd : block.timestamp;

        // Check if it is time to start a new vesting period.
        if (block.timestamp >= vestingEnd) {
            uint256 adjustmentRate;
            
            // Calculate the new interest rate for borrowers, in seconds.
            (rate, adjustmentRate)
                = IRM.adjustedBorrowRate(assetsHeld(), outstandingDebt);

            // The multiplication logic here is to round down to
            // discrete `adjustmentRate` cycles, e.g. if block.timestamp is 3
            // `adjustmentRate`'s ahead then begin vesting all of them for
            // users at once.
            adjustmentRate = (((block.timestamp - vestingEnd) /
                adjustmentRate) * adjustmentRate) + adjustmentRate;
            vestingEnd = vestingEnd + adjustmentRate;

            emit RatesAdjusted(rate, vestingEnd);

            // Check if theres new yield to be vested from the new vesting
            // period, which could happen if the previous vesting period ended
            // and block.timestamp extends into the new vesting period.
            assetsToVest += _assetsToVest(
                rate,
                outstandingDebt,
                vestingEnd,
                lastVestingClaim
            );
        }

        // Calculate any protocol fee on `assetsToVest`.
        uint256 protocolFee = FixedPointMathLib.mulDivUp(
            assetsToVest,
            interestFee,
            BPS
        );
        // If theres fees we need to mint new shares for the protocol.
        if (protocolFee > 0) {
            // Cache total supply/total shares = ts.
            uint256 ts = totalSupply();
            // We can calculate how many shares the protocol should receive
            // from assetsToVest fee by using the formula:
            // (feeInAssets * ts) / (ta + assetsToVest - feeInAssets).
            // This means that that shares minted will result in an exchange
            // rate matching the amount of vested assets lenders should
            // benefit from.
            uint256 protocolFeeShares = _mulDiv(
                protocolFee,
                ts,
                cachedTa + assetsToVest - protocolFee
            );
            // Cache `daoAddress` then mint shares to dao operator address.
            address daoAddress = centralRegistry.daoAddress();
            _mint(daoAddress, protocolFeeShares);
            _afterDepositAction(protocolFeeShares, daoAddress);
        }

        // Vest pending assets, if there is any.
        if (assetsToVest > 0) {
            // `assetsToVest` is new outstanding debt in assets so we
            // need to divide by `outstandingDebt` so its in % form.
            marketDebtIndex =
                _mulDiv(assetsToVest, marketDebtIndex, outstandingDebt)
                    + marketDebtIndex;
            // Update marketOutstandingDebt invariant with vested assets.
            marketOutstandingDebt = uint240(outstandingDebt + assetsToVest);
            // Update _totalAssets based on new assets recognized by protocol.
            _totalAssets = cachedTa + assetsToVest;
        }

        assembly {
            // Mask `rate` to the lower 96 bits, in case
            // the upper bits somehow aren't clean.
            rate := and(rate, _BITMASK_VESTING_RATE)
            // Equals rate | (vestingEnd << _BITPOS_VEST_END) |
            //        block.timestamp << _BITPOS_LAST_VEST | marketDebtIndex.
            vestingData := or(
                rate,
                or(
                    or(
                        shl(_BITPOS_VEST_END, vestingEnd),
                        shl(_BITPOS_LAST_VEST, timestamp())
                    ),
                    shl(_BITPOS_DEBT_INDEX, marketDebtIndex)
                )  
            )
        }

        // Update packed vesting data based on new vesting configuration.
        _vestingData = vestingData;
    }

    /// @notice Updates the interest rate model (`IRM`) used
    ///         by this borrowableCToken.
    /// @dev Emits a {NewIRM} event.
    /// @param newIRM The new interest rate model to determine interest paid
    ///               by borrowers to lenders for outstanding debt.
    function _setIRM(IDynamicIRM newIRM) internal {
        // Ensure we are switching to an actual Interest Rate Model.
        if (
            !ERC165Checker.supportsInterface(
                address(newIRM),
                type(IDynamicIRM).interfaceId
            )
        ) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Cache the current interest rate model for event emission.
        address oldIRM = address(IRM);

        // Set new interest rate model and compound rate.
        IRM = newIRM;
        uint256 newPeriod = newIRM.ADJUSTMENT_RATE();
        vestingPeriod = newPeriod;

        emit NewIRM(oldIRM, address(newIRM), newPeriod);
    }

    /// @notice Updates the fee that the protocol takes on interest paid
    ///         by borrowers.
    /// @dev Emits a {NewInterestFee} event.
    /// @param newInterestFee The portion of interest paid by borrowers that
    ///                       goes to the protocol, in `BPS`.
    function _setInterestFee(uint256 newInterestFee) internal {
        // The DAO cannot take more than `MAX_INTEREST_ACCRUAL_FEE` of
        // interest collected.
        if (newInterestFee > MAX_INTEREST_ACCRUAL_FEE) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Cache the old interest fee for event emission.
        uint256 oldInterestFee = interestFee;

        interestFee = uint16(newInterestFee);

        emit NewInterestFee(oldInterestFee, interestFee);
    }

    /// @notice Packs `newOutstandingDebt` with current `marketDebtIndex` to
    ///         create new packed `_debtOf` for `account`.
    /// @param account The account to set `_debtOf` value for.
    /// @param newOutstandingDebt The new outstanding debt of `account`.
    /// @param marketDebtIndex The current market debt index value.
    function _setDebtOf(
        address account,
        uint176 newOutstandingDebt,
        uint80 marketDebtIndex
    ) internal {
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

    /// @notice Starts a cToken market, executed via marketManager.
    /// @dev This initial mint is a failsafe against rounding exploits,
    ///      although, we protect against them in many ways,
    ///      better safe than sorry.
    /// @dev Emits a {Deposit} event.
    /// @param by The account initializing deposits.
    function _initializeDeposits(address by) internal override {
        // Validate that the interest rate model is linked to this token.
        if (IRM.linkedToken() != address(this)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        super._initializeDeposits(by);

        // Calculate `_vestingData` invariant to intended start values.
        _vestingData = (_vestingData & _BITMASK_VESTING_RATE) |
            (block.timestamp << _BITPOS_VEST_END) |
            (block.timestamp << _BITPOS_LAST_VEST) |
            (WAD << _BITPOS_DEBT_INDEX);
    }

    /// @notice Calculates pending assets that have been vested.
    /// @dev If there are no pending assets or the vesting period has ended,
    ///      it returns 0.
    /// @return assets The calculated pending assets to vest.
    function _assetsToVest() internal view override returns (uint256 assets) {
        // Cache vesting data.
        uint256 vestingData = _vestingData;
        assets =  _assetsToVest(
            uint96(vestingData),
            marketOutstandingDebt,
            uint40(vestingData >> _BITPOS_VEST_END),
            uint40(vestingData >> _BITPOS_LAST_VEST)
        );
    }

        /// @notice Calculates pending yield that has been vested.
    /// @dev If there are no pending yield or the vesting period has ended,
    ///      it returns 0.
    /// @return assets The calculated pending assets to vest.
    function _assetsToVest(
        uint256 vestingRate,
        uint256 outstandingDebt,
        uint256 vestingEnd,
        uint256 lastVestingClaim
    ) internal view returns (uint256 assets) {
        // Check whether there are pending assets vesting.
        if (vestingRate > 0 && lastVestingClaim < vestingEnd) {
            // When calculating pending yield:
            // assets =
            // If the vesting period has not ended:
            // PY = vestingRate * (block.timestamp - lastTimeVestClaimed).
            // If the vesting period has ended:
            // PY = vestingRate * (vestingEnd - lastTimeVestClaimed)).
            // Then in either case:
            // Divide the pending yield by `WAD` (1e18) for precision.
            assets = _mulDiv(
                block.timestamp < vestingEnd
                    ? vestingRate * (block.timestamp - lastVestingClaim)
                    : vestingRate * (vestingEnd - lastVestingClaim),
                outstandingDebt,
                WAD
            );
        }
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
}