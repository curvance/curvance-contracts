// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseCTokenWithYield, FixedPointMathLib, ICentralRegistry, IERC20, WAD } from "contracts/market/token/BaseCTokenWithYield.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";

import { ICToken, AccountSnapshot } from "contracts/interfaces/ICToken.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { IPositionManager } from "contracts/interfaces/IPositionManager.sol";
import { IInterestRateModel } from "contracts/interfaces/IInterestRateModel.sol";
import { IFlashLoan } from "contracts/interfaces/IFlashLoan.sol";

contract BorrowableCToken is BaseCTokenWithYield {
    /// CONSTANTS ///

    /// @notice Maximum percentage fee that can be taken from interest accrued
    ///         from outstanding debt, in `basis points`.
    /// @dev 5000 = 50%.
    uint256 public constant MAX_INTEREST_ACCRUAL_FEE = 5000;

    /// @notice Percentage fee on loan sized borrowed during a flashloan,
    ///         in `WAD`.
    /// @dev .0005e18 = 0.05%.
    uint256 public constant FLASHLOAN_FEE = .0005e18;

    /// @dev Mask of vesting rate entry in `_vestingData`.
    uint256 internal constant _BITMASK_VESTING_RATE = (1 << 96) - 1;
    /// @dev Mask of a timestamp entry in `_vestingData`.
    uint256 internal constant _BITMASK_TIMESTAMP = (1 << 40) - 1;
    /// @dev Mask of bits in `_vestingData` until the start of
    ///      `lastVestingClaim`.
    uint256 internal constant _BITMASK_VEST_END_COMPLEMENT = (1 << 136) - 1;
    /// @dev Mask of all bits in `_vestingData` except the 80 bits
    ///      for a debt index value.
    uint256 internal constant _BITMASK_DEBT_INDEX_COMPLEMENT = (1 << 176) - 1;
    /// @dev The bit position of `vestingPeriodEnd` in `_vestingData`.
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
    IInterestRateModel public interestRateModel;
    /// @notice The portion of interest paid by borrowers that goes to the
    ///         protocol, in `WAD`.
    uint256 public interestFee;
    /// @notice The amount of `asset` that has been borrowed as outstanding
    ///         debt, in assets.
    uint256 public marketOutstandingDebt;

    /// @notice Outstanding debt information associated with an account.
    /// @dev Internal packed debt data:
    ///      Bits Layout:
    ///      - [0..175]   `outstandingDebt`.
    ///      - [176..255] `accountDebtIndex`.
    mapping(address => uint256) internal _debtOf;

    /// EVENTS ///

    event InterestAccrualUpdate(uint256 debtPerSecond, uint256 vestingPeriod);
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
    /// @param interestRateModel_ The address of the interest rate model to
    ///                           manage outstanding loans.
    constructor(
        ICentralRegistry cr,
        IERC20 asset_,
        address mm,
        address interestRateModel_
    ) BaseCTokenWithYield(cr, asset_, mm, IInterestRateModel(
        interestRateModel_
    ).INTEREST_ACCRUAL_PERIOD()) {
        // This essentially redundantly sets vestingPeriod twice since we also set
        // it as part of `BaseCTokenWithYield` deployment, but we want to make sure
        // _setInterestRateModel includes this setter incase the interest rate
        // model is ever changed.
        _setInterestRateModel(IInterestRateModel(interestRateModel_));

        // Assign the portion of interest paid by borrowers that goes to the
        // protocol.
        uint256 newInterestFee = centralRegistry.protocolInterestFee(mm);
        interestFee = newInterestFee;

        emit NewInterestFee(0, newInterestFee);
    }

    function getVestingData() external view returns(
        uint256,
        uint256,
        uint256,
        uint256
    ) {
        uint256 vestingData = _vestingData;
        return (
            uint96(vestingData),
            marketOutstandingDebt,
            uint40(vestingData >> _BITPOS_VEST_END),
            uint40(vestingData >> _BITPOS_LAST_VEST)
        );
    }

    /// @notice Accrues pending interest and updates the interest rate
    ///         model (`interestRateModel`) used by this borrowableCToken.
    /// @dev Admin function to update the interest rate model.
    ///      Emits a {NewIRM} event.
    /// @param newIRM The new interest rate model to determine interest
    ///               paid by borrowers to lenders for outstanding debt.
    function setInterestRateModel(address newIRM) external {
        _checkElevatedPermissions();

        // Accrue interest if needed.
        _accrueIfNeeded();

        _setInterestRateModel(IInterestRateModel(newIRM));
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
        fee = FixedPointMathLib.mulDivUp(assets, FLASHLOAN_FEE, WAD);
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
        marketOutstandingDebt = marketOutstandingDebt + assets;

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
            marketOutstandingDebt -= assets;
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
            marketOutstandingDebt -= result.debtRepaid;
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
    /// @dev May emit a {InterestAccrualUpdate} event.
    function _accrueIfNeeded() internal override {
        uint256 vestingData = _vestingData;
        uint256 lastVestingClaim = uint40(vestingData >> _BITPOS_VEST_END);

        // If no time has passed since the last accrual can exit immediately.
        if (block.timestamp == lastVestingClaim) {
            return;
        }

        uint256 rate = uint96(vestingData);
        uint256 vestingPeriodEnd = uint40(vestingData >> _BITPOS_LAST_VEST);
        uint256 marketDebtIndex = uint80(vestingData >> _BITPOS_DEBT_INDEX);
        uint256 outstandingDebt = marketOutstandingDebt;
        uint256 cachedTa = _totalAssets;
        uint256 yieldToVest = _getPendingYield(
            rate,
            outstandingDebt,
            vestingPeriodEnd,
            lastVestingClaim
        );

        // Update last claim timestamp, stopping at vesting end if vesting
        // period is over.
        lastVestingClaim = block.timestamp > vestingPeriodEnd
            ? vestingPeriodEnd : block.timestamp;

        uint256 protocolFee;

        // Check if it is time to start a new vesting period.
        if (block.timestamp >= vestingPeriodEnd) {
            // Cache interest accrual fee, and vesting period to save gas.
            uint256 accrualPeriod = vestingPeriod;
            uint256 accrualFee = interestFee;

            // Calculate the interest vesting cycles for new vesting period.
            // The weird multiplication logic here is to round down to
            // discrete vesting cycles.
            accrualPeriod = (((block.timestamp - lastVestingClaim) /
                accrualPeriod) * accrualPeriod) + accrualPeriod;
            vestingPeriodEnd = lastVestingClaim + accrualPeriod;

            // Calculate the new interest rate for borrowers, in seconds.
            rate = interestRateModel.getBorrowRateWithUpdate(
                assetsHeld(),
                outstandingDebt
            );

            protocolFee = FixedPointMathLib.mulDivUp(rate, accrualFee, WAD);
            // Check whether the DAO takes a cut of interest, and whether new
            // assets will vest over time the next vesting period.
            if (protocolFee > 0) {
                // `protocolFee` is initially calculated in `rate` giving us
                // fees per second, in assets. Which we can then subtract
                // directly from `rate` so theres no precision loss.
                rate = rate - protocolFee;

                // We can now convert the per second assets value to the
                // amount of assets to be minted by the end of the new
                // `vestingPeriodEnd`. Next we need to discount the amount of
                // assets minted by the future interest to be vested so that
                // the protocol is not overpaid. The discount asset amount can
                // be calculated with:
                // assets * (current assets / current assets + future assets)
                // `rate` is in WAD which means we need to divide the
                // output by WAD to get protocolFee in `assets`.
                // yieldToVest needs to be added to both as we do not want to
                // give the protocol additional rewards for vested interest in
                // the past.
                protocolFee = _mulDiv(
                    protocolFee * accrualPeriod * outstandingDebt,
                    cachedTa,
                    (cachedTa +
                        _mulDiv(rate * accrualPeriod, outstandingDebt, WAD)) * WAD
                );
            }

            emit InterestAccrualUpdate(rate, accrualPeriod);
        }

        // Check if theres new yield to be vested, which could happen if the
        // previous vesting period ended and current block.timestamp extends
        // into the new vesting period.
        uint256 newYieldToVest = _getPendingYield(
            rate,
            outstandingDebt,
            vestingPeriodEnd,
            lastVestingClaim
        );
        // We can reuse `yieldToVest` to store both the current yield to vest
        // and any new yield to vest.
        yieldToVest = yieldToVest + newYieldToVest;

        // If theres fees we need to mint new shares for the protocol.
        if (protocolFee > 0) {
            // Convert assets to shares and mint to protocol address. Calculate
            // before adding the protocols assets so effectively all assets go
            // to the protocol.
            uint256 protocolFeeShares = _convertToShares(protocolFee, cachedTa);
            // Cache the current dao address then mint shares to the dao.
            address daoAddress = centralRegistry.daoAddress();
            _mint(daoAddress, protocolFeeShares);
            _afterDepositAction(protocolFeeShares, daoAddress);
            cachedTa = cachedTa + protocolFee;
        }

        // Vest pending yield, if there is any.
        if (yieldToVest > 0) {
            // `yieldToVest` at this point is $ outstanding debt so we
            // need to redivide by `outstandingDebt` so its in % form.
            marketDebtIndex =
                _mulDiv(yieldToVest, marketDebtIndex, outstandingDebt)
                    + marketDebtIndex;
            // Update marketOutstandingDebt invariant with vested yield.
            marketOutstandingDebt = outstandingDebt + yieldToVest;
            // `cachedTa` already has yieldToVest so we only want to add
            // `newYieldToVest`. 
            cachedTa = cachedTa + newYieldToVest;
        }

        assembly {
            // Mask `rate` to the lower 96 bits, in case
            // the upper bits somehow aren't clean.
            rate := and(rate, _BITMASK_VESTING_RATE)
            // Equals rate | (vestingPeriodEnd << _BITPOS_VEST_END) |
            //        block.timestamp << _BITPOS_LAST_VEST | marketDebtIndex.
            vestingData := or(
                rate,
                or(
                    or(
                        shl(_BITPOS_VEST_END, vestingPeriodEnd),
                        shl(_BITPOS_LAST_VEST, timestamp())
                    ),
                    shl(_BITPOS_DEBT_INDEX, marketDebtIndex)
                )  
            )
        }

        // Update _totalAssets based on new assets recognized by protocol.
        _totalAssets = cachedTa;
        // Update packed vesting data based on new vesting configuration.
        _vestingData = vestingData;
    }

    /// @notice Updates the interest rate model (`interestRateModel`) used
    ///         by this borrowableCToken.
    /// @dev Emits a {NewIRM} event.
    /// @param newIRM The new interest rate model to determine interest paid
    ///               by borrowers to lenders for outstanding debt.
    function _setInterestRateModel(IInterestRateModel newIRM) internal {
        // Ensure we are switching to an actual Interest Rate Model.
        if (
            !ERC165Checker.supportsInterface(
                address(newIRM),
                type(IInterestRateModel).interfaceId
            )
        ) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Cache the current interest rate model for event emission.
        address oldIRM = address(interestRateModel);

        // Set new interest rate model and compound rate.
        interestRateModel = newIRM;
        uint256 newPeriod = newIRM.INTEREST_ACCRUAL_PERIOD();
        vestingPeriod = newPeriod;

        emit NewIRM(oldIRM, address(newIRM), newPeriod);
    }

    /// @notice Updates the fee that the protocol takes on interest paid
    ///         by borrowers.
    /// @dev Emits a {NewInterestFee} event.
    /// @param newInterestFee The portion of interest paid by borrowers that
    ///                       goes to the protocol.
    function _setInterestFee(uint256 newInterestFee) internal {
        // The DAO cannot take more than `MAX_INTEREST_ACCRUAL_FEE` of
        // interest collected.
        if (newInterestFee > MAX_INTEREST_ACCRUAL_FEE) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Cache the old interest fee for event emission.
        uint256 oldInterestFee = interestFee;

        /// `interestFee` is stored is in `WAD` format. So, we need to
        /// multiply by 1e14 to convert from basis points to `WAD`.
        interestFee = newInterestFee * 1e14;

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
        if (interestRateModel.linkedToken() != address(this)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        super._initializeDeposits(by);

        // Calculate `_vestingData` invariant to intended start values.
        _vestingData = (_vestingData & _BITMASK_VESTING_RATE) |
            (block.timestamp << _BITPOS_VEST_END) |
            (block.timestamp << _BITPOS_LAST_VEST) |
            (WAD << _BITPOS_DEBT_INDEX);
    }

    /// @notice Calculates pending yield that have been vested.
    /// @dev If there are no pending yield or the vesting period has ended,
    ///      it returns 0.
    /// @return y The calculated pending yield.
    function _getPendingYield() internal view override returns (uint256 y) {
        // Cache vesting data.
        uint256 vestingData = _vestingData;
        y =  _getPendingYield(
            uint96(vestingData),
            marketOutstandingDebt,
            uint40(vestingData >> _BITPOS_VEST_END),
            uint40(vestingData >> _BITPOS_LAST_VEST)
        );
    }

        /// @notice Calculates pending yield that has been vested.
    /// @dev If there are no pending yield or the vesting period has ended,
    ///      it returns 0.
    /// @return pendingYield The calculated pending yield, in assets.
    function _getPendingYield(
        uint256 vestingRate,
        uint256 outstandingDebt,
        uint256 vestingPeriodEnd,
        uint256 lastVestingClaim
    )
        internal
        view
        returns (uint256 pendingYield)
    {
        // Check whether there are pending yield vesting.
        if (vestingRate > 0 && lastVestingClaim < vestingPeriodEnd) {
            // When calculating pending yield:
            // pendingYield =
            // If the vesting period has not ended:
            // PY = vestingRate * (block.timestamp - lastTimeVestClaimed).
            // If the vesting period has ended:
            // PY = vestingRate * (vestingPeriodEnd - lastTimeVestClaimed)).
            // Then in either case:
            // Divide the pending yield by `WAD` (1e18) for precision.
            pendingYield = _mulDiv(
                block.timestamp < vestingPeriodEnd
                    ? vestingRate * (block.timestamp - lastVestingClaim)
                    : vestingRate * (vestingPeriodEnd - lastVestingClaim),
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