// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Multicall } from "contracts/libraries/Multicall.sol";
import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";
import { RescueLib } from "contracts/libraries/RescueLib.sol";
import { WAD } from "contracts/libraries/ConstantsLib.sol";
import { ReentrancyGuard } from "contracts/libraries/ReentrancyGuardTransient.sol";

import { ERC4626 } from "contracts/libraries/external/ERC4626.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { ICToken, AccountSnapshot } from "contracts/interfaces/ICToken.sol";
import { IPositionManager } from "contracts/interfaces/IPositionManager.sol";

/// @notice Curvance's cTokens (Curvance Tokens) are ERC4626 compliant.
///         However, they follow their own design modifying underlying
///         mechanisms such as `totalAssets` following an asset vesting system
///         in both external strategies and lender interest accrual from
///         borrowers.
///
///         The "cToken" employs two different methods of engaging with the
///         Curvance protocol. Users can deposit an unlimited amount of assets,
///         which may or may not benefit from some form of yield.
///
///         Users can at any time, choose to "post" their cTokens as collateral
///         inside the Curvance Protocol, unlocking their ability to borrow
///         against these assets. Posting collateral carries restrictions,
///         not all assets inside Curvance can be collateralized, and if they
///         can, they have a "Collateral Cap" which restricts the total amount of
///         exogeneous risk introduced by each asset into the system.
///
///         These caps can be updated as needed by the DAO and should be
///         configured based on "sticky" onchain liquidity in the corresponding
///         asset.
///
///         Each token can have their minting, collateralization, borrowing,
///         compounding, liquidations, and redemption functionality paused.
///         Modifying the maximum mint, deposit, withdrawal, or redemptions
///         possible.
///
///         View functions are "safe" by introducing reentry and update
///         protection to minimize risks when integrating with Curvance.
///
/// @dev `Asset()` Positions must have all assets ready for withdraw,
///      IE assets can NOT be locked.
///      This way assets can be easily liquidated when loans default.
abstract contract BaseCToken is
    ERC4626,
    PluginDelegable,
    ReentrancyGuard,
    Multicall
{
    /// CONSTANTS ///

    /// @dev `bytes4(keccak256(bytes("BaseCToken__Unauthorized()")))`
    uint256 internal constant _UNAUTHORIZED_SELECTOR = 0x471656c5;
    /// @dev `bytes4(keccak256(bytes("BaseCToken__InsufficientLiquidity()")))`
    uint256 internal constant _INSUFFICIENT_LIQUIDITY_SELECTOR = 0xe6c95926;
    /// @dev `keccak256(bytes("Transfer(address,address,uint256)"))`.
    uint256 internal constant _TRANSFER_EVENT_SIGNATURE =
        0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;
    /// @dev The balance slot of `owner` is given by:
    /// ```
    ///     mstore(0x0c, _BALANCE_SLOT_SEED)
    ///     mstore(0x00, owner)
    ///     let balanceSlot := keccak256(0x0c, 0x20)
    /// ```
    uint256 internal constant _BALANCE_SLOT_SEED = 0x87a211a2;
    /// @dev The base underlying asset requirement held in order to minimize
    ///      rounding exploits, and more generally, invariant manipulation.
    uint256 internal constant _BASE_UNDERLYING_RESERVE = 77777;

    /// @notice Address of the Market Manager linked to this contract.
    IMarketManager public immutable marketManager;

    /// @notice Underlying asset for this token.
    /// @dev CANNOT be a fee-on-transfer token.
    IERC20 internal immutable _asset;
    /// @notice Token decimal precision.
    uint8 internal immutable _decimals;

    /// STORAGE ///

    /// @notice Amount of tokens that has been posted as collateral,
    ///         in shares.
    uint256 public marketCollateralPosted;

    /// @notice Token name metadata.
    string internal _name;
    /// @notice Token symbol metadata.
    string internal _symbol;
    /// @notice Total amount of `asset()` in this vault, minus pending
    ///         vesting.
    uint256 internal _totalAssets;

    /// @notice Shares of this token that an account has posted as collateral.
    /// @dev Account address => Collateral data.
    mapping(address => uint256) public collateralPosted;
    
    /// EVENTS ///

    event CollateralUpdated(uint256 shares, bool increased, address account);
    event Liquidated(uint256 shares, address liquidator, address account);

    /// ERRORS ///

    error BaseCToken__ZeroAmount();
    error BaseCToken__TransferError();
    error BaseCToken__InsufficientLiquidity();
    error BaseCToken__Unauthorized();
    error BaseCToken__UnsupportedChain();
    error BaseCToken__UnsupportedAsset();
    error BaseCToken__InvalidMarketManager();

    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
    /// @param asset_ The address of the underlying asset for this cToken.
    /// @param mm The address of the MarketManager which manages liquidity
    ///           positions between linked cTokens inside a joint market.
    constructor(
        ICentralRegistry cr,
        IERC20 asset_,
        address mm
    ) PluginDelegable(cr) {
        _asset = asset_;
        _name = string.concat("Curvance ", asset_.name());
        _symbol = string.concat("c", asset_.symbol());
        _decimals = asset_.decimals();

        // Validate that `mm` is configured as a Market Manager inside the
        // Protocol Central Registry.
        if (!centralRegistry.isMarketManager(mm)) {
            revert BaseCToken__InvalidMarketManager();
        }

        // Sanity check of `asset_` so that we know users will not need to
        // mint anywhere close to causing an overflow.
        if (asset_.totalSupply() >= type(uint216).max) {
            revert BaseCToken__UnsupportedAsset();
        }

        // Set `marketManager`.
        marketManager = IMarketManager(mm);
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Enables a token's functionality inside a market, executed
    ///         via marketManager.
    /// @dev This initial mint is a failsafe against rounding exploits,
    ///      although, we protect against them in many ways,
    ///      better safe than sorry.
    ///      NOTE: ONLY CALLED ONCE DURING TOKEN LISTING BY DAO AUTHORIZED
    ///            ADDRESS FROM THE MARKET MANAGER.
    /// @param by The account initializing deposits.
    /// @return Returns with true when successful.
    function initializeDeposits(
        address by
    ) external nonReentrant returns (bool) {
        _initializeDeposits(by);
        return true;
    }

    /// @notice Used by a Position Manager contract to redeem assets from
    ///         collateralized shares by `account` to perform a complex
    ///         action.
    /// @param assets The amount of the underlying assets to redeem.
    /// @param owner The owner address of assets to redeem.
    /// @param action Instructions for a deleverage action containing:
    ///               cToken Address of the cToken that will be redeemed from
    ///                      and assets swapped into `borrowableCToken` asset.
    ///               collateralAssets The amount of `cToken` that will be
    ///                                deleveraged, in assets.
    ///               borrowableCToken Address of the borrowableCToken that
    ///                                will have its debt paid.
    ///               repayAssets The amount of `borrowableCToken` asset that
    ///                           will be repaid to lenders.
    ///               swapActions Swap actions instructions converting
    ///                           collateral asset into debt asset to
    ///                           facilitate deleveraging.
    ///               auxData Optional auxiliary data for execution of a
    ///                       deleverage action.
    function withdrawByPositionManager(
        uint256 assets,
        address owner,
        IPositionManager.DeleverageAction memory action
    ) external nonReentrant {
        // Validate that a position manager is calling.
        if (!marketManager.isPositionManager(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        _accrueIfNeeded();

        // We can pull _totalAssets directly here since any pending
        // yield are already vested via _accrueIfNeeded().
        uint256 ta = _totalAssets;
        uint256 balance = _checkRedemption(assets, owner, ta);
        // No need to check for rounding error, previewWithdraw rounds up.
        uint256 shares = _previewWithdraw(assets, ta);

        _processWithdraw(assets, shares, msg.sender, msg.sender, owner);

        // Process the position manager redemption leg.
        _processPositionManagerRedemption(
            assets,
            shares,
            owner,
            balance,
            action
        );
    }

    /// @notice Caller deposits `assets` into the market, `receiver` receives
    ///         shares, and collateralization of `assets` is enabled.
    /// @dev The caller must be depositing for themselves, or be managing
    ///      their position through a Position Manager contract.
    /// @param assets The amount of the underlying assets to deposit.
    /// @param receiver The account that should receive the cToken shares.
    /// @return shares The amount of cToken shares received by `receiver`.
    function depositAsCollateral(
        uint256 assets,
        address receiver
    ) external nonReentrant returns (uint256 shares) {
        if (
            msg.sender != receiver &&
            !marketManager.isPositionManager(msg.sender)
        ) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        shares = _deposit(assets, receiver);

        // Can skip _checkPostCollateral since we know that `shares` is not
        // 0 and `receiver` has shares to post as collateral due to prior
        // _deposit action.
        _postCollateral(shares, receiver);
    }

    /// @notice Caller deposits `assets` into the market, `receiver` receives
    ///         shares, and collateralization of `assets` is enabled.
    /// @dev Requires that `receiver` approves the caller prior to
    ///      collateralize on their behalf.
    ///      NOTE: Be careful who you approve here!
    ///      They can delay redemption of assets through repeated
    ///      collateralization preventing withdrawal.
    ///      If the caller is not approved to collateralize the function will
    ///      simply deposit assets on behalf of `receiver`.
    /// @param assets The amount of the underlying assets to deposit.
    /// @param receiver The account that should receive the cToken shares.
    /// @return shares The amount of cToken shares received by `receiver`.
    function depositAsCollateralFor(
        uint256 assets,
        address receiver
    ) external nonReentrant returns (uint256 shares) {
        _checkDelegate(receiver, msg.sender);

        shares = _deposit(assets, receiver);

        // Can skip _checkPostCollateral since we know that `shares` is not
        // 0 and `receiver` has shares to post as collateral due to prior
        // _deposit action.
        _postCollateral(shares, receiver);
    }

    /// @notice Caller withdraws assets from the market and burns their shares.
    /// @dev Forces collateral to be withdrawn from `owner` collateralPosted.
    /// @param assets The amount of the underlying assets to withdraw.
    /// @param receiver The account that should receive the assets.
    /// @param owner The account that will burn their shares to withdraw assets.
    /// @return shares the amount of cToken shares redeemed by `owner`.
    function withdrawCollateral(
        uint256 assets,
        address receiver,
        address owner
    ) external nonReentrant returns (uint256 shares) {
        shares = _withdraw(assets, receiver, owner, true);
    }

    /// @notice Caller withdraws assets from the market and burns their shares.
    /// @dev Forces collateral to be withdrawn from `owner` collateralPosted.
    /// @param shares The amount of shares to redeemed.
    /// @param receiver The account that should receive the assets.
    /// @param owner The account that will burn their shares to withdraw assets.
    /// @return assets the amount of assets redeemed by `owner`.
    function redeemCollateral(
        uint256 shares,
        address receiver,
        address owner
    ) external nonReentrant returns (uint256 assets) {
        assets = _redeem(shares, receiver, owner, false, true);
    }

    /// @notice Caller withdraws assets from the market and burns their
    ///         shares, on behalf of `owner`.
    /// @dev Forces collateral to be withdrawn from `owner` collateralPosted.
    /// @param shares The amount of shares to redeemed.
    /// @param receiver The account that should receive the assets.
    /// @param owner The account that will burn their shares to withdraw
    ///              assets.
    /// @return assets The amount of assets redeemed by `owner` and sent to
    ///                `receiver`.
    function redeemCollateralFor(
        uint256 shares,
        address receiver,
        address owner
    ) external nonReentrant returns (uint256 assets) {
        assets = _redeem(shares, receiver, owner, true, true);
    }

    /// @notice Posts `shares` as collateral inside this market.
    /// @dev The cToken must have collateralization enabled (collRatio > 0),
    ///      and its collateral cap set (above 0).
    /// @param shares The amount of shares to post as collateral.
    function postCollateral(uint256 shares) external nonReentrant {
        _checkPostCollateral(shares, msg.sender);

        _postCollateral(shares, msg.sender);
    }

    /// @notice Posts `shares` as collateral inside this market
    ///         for `account`.
    /// @dev The cToken must have collateralization enabled (collRatio > 0),
    ///      and its collateral cap set (above 0).
    /// @param shares The number of shares to post as collateral from `owner`.
    /// @param owner The address of the account posting `shares`
    ///              as collateral.
    function postCollateralFor(
        uint256 shares,
        address owner
    ) external nonReentrant {
        _checkDelegate(owner, msg.sender);
        _checkPostCollateral(shares, owner);

        _postCollateral(shares, owner);
    }

    /// @notice Removes `shares` of collateral posted inside this market.
    /// @param shares The number of shares that are posted of collateral
    ///               that will be removed.
    function removeCollateral(uint256 shares) external nonReentrant {
        _checkRemoveCollateral(shares, msg.sender);

        _removeCollateral(shares, msg.sender);
    }

    /// @notice Removes `shares` of collateral posted inside this market
    ///         for `account`.
    /// @param shares The number of shares to remove as collateral
    ///               from `owner`.
    /// @param owner The address of the account removing `shares`
    ///              as collateral.
    function removeCollateralFor(
        uint256 shares,
        address owner
    ) external nonReentrant {
        _checkDelegate(owner, msg.sender);
        _checkRemoveCollateral(shares, owner);

        _removeCollateral(shares, owner);
    }

    /// @notice Transfers collateralized cToken shares from `accounts`
    ///         to `liquidator` as part of a liquidation.
    /// @dev Will fail unless called by a different listed cToken
    ///      during the process of liquidation.
    ///      May emit {CollateralUpdated} and {Liquidated} events.
    /// @param liquidatedShares An array containing the number of
    ///                         collateralized cTokens to seize, in shares.
    /// @param liquidator The account receiving `liquidatedShares` cTokens.
    /// @param accounts An array containing the accounts having collateral
    ///                 seized.
    function seize(
        uint256[] calldata liquidatedShares,
        address liquidator,
        address[] calldata accounts
    ) external nonReentrant {
        // Fails if seizure not allowed.
        marketManager.canSeize(address(this), msg.sender);

        // We know that `accounts` and `liquidatedShares` arrays are the same
        // length since we validate it inside the cToken getting debt repaid
        // as part of this liquidation.

        uint256 numAccounts = accounts.length;
        uint256 totalShares;
        uint256 shares;
        address account;

        for (uint256 i; i < numAccounts; ++i) {
            shares = liquidatedShares[i];
            // If theres no shares to liquidate for this account can
            // skip them.
            if (shares == 0) {
                continue;
            }

            account = accounts[i];

            // Execute any prior liquidation action.
            _beforeLiqAction(shares, liquidator, account);
            totalShares += shares;

            // Update `account` collateral posted invariant and transfer
            // their collateral shares.
            collateralPosted[account] = collateralPosted[account] - shares;
            emit CollateralUpdated(shares, false, account);

            // Transfer liquidated shares from `account` to `liquidator`.
            _transferFromWithoutAllowance(account, liquidator, shares);
            emit Liquidated(shares, liquidator, account);
        }

        // Update market collateral posted invariant for the liquidated
        // shares.
        marketCollateralPosted = marketCollateralPosted - totalShares;
    }

    /// @notice Rescue any token sent by mistake.
    /// @param token token to rescue.
    /// @param amount amount of `token` to rescue, 0 indicates to rescue all.
    function rescueToken(address token, uint256 amount) external {
        _checkDaoPermissions();

        if (token == asset()) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        RescueLib._rescueToken(centralRegistry, token, amount);
    }

    /// @notice Returns share -> asset exchange rate, in `WAD`.
    /// @dev Oracle Manager calculates cToken value from this exchange rate.
    /// @return r The share -> asset exchange rate, in `WAD`.
    function exchangeRate() external view nonReadReentrant returns (uint256 r) {
        r = _convertToAssets(WAD, _getTotalAssets());
    }

    /// @notice Returns a snapshot of the cToken and `account` data.
    /// @dev Used by MarketManager to efficiently perform liquidity checks.
    /// NOTE: debtBalance always return 0 to runtime gas in MarketManager
    ///       since it is unused.
    /// @return result The snapshot of the cToken and `account` data.
    function getSnapshot(
        address account
    ) external view virtual returns (AccountSnapshot memory result) {
        result.asset = address(this);
        result.decimals = decimals();
        // Can only be true for non-BorrowableCTokens.
        result.isCollateral = true;
        result.exchangeRate = _convertToAssets(WAD, _getTotalAssets());
        result.collateralPosted = collateralPosted[account];
        // result.debtBalance is 0 for non-BorrowableCTokens, no need to set.
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Returns the name of the token.
    /// @return The name of the token.
    function name() public view override returns (string memory) {
        return _name;
    }

    /// @notice Returns the symbol of the token.
    /// @return The symbol of the token.
    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /// @notice Returns the address of the underlying asset.
    /// @return The address of the underlying asset.
    function asset() public view override returns (address) {
        return address(_asset);
    }

    /// @notice Returns the maximum assets that can be deposited at a time.
    /// @dev If depositing is disabled maxAssets should be equal to 0,
    ///      according to ERC4626 spec.
    /// @param receiver The address who would receive minted shares.
    /// @return maxAssets The maximum assets that can be deposited at a time.
    function maxDeposit(
        address receiver
    ) public view override returns (uint256 maxAssets) {
        (bool mintPaused, , ) = marketManager.actionsPaused(address(this));
        if (!marketManager.isListed(address(this)) || mintPaused) {
            // We do not need to set maxAssets here since its initialized
            // as 0 so we can just return.
            return maxAssets;
        }
        maxAssets = super.maxDeposit(receiver);
    }

    /// @notice Returns the maximum shares that can be minted at a time.
    /// @dev If depositing is disabled minMint should be equal to 0,
    ///      according to ERC4626 spec.
    /// @param receiver The address who would receive minted shares.
    /// @return maxShares The maximum shares that can be minted at a time.
    function maxMint(
        address receiver
    ) public view override returns (uint256 maxShares) {
        (bool mintPaused, , ) = marketManager.actionsPaused(address(this));
        if (!marketManager.isListed(address(this)) || mintPaused) {
            // We do not need to set maxShares here since its initialized
            // as 0 so we can just return.
            return maxShares;
        }
        maxShares = super.maxMint(receiver);
    }

    /// @notice Caller deposits `assets` into the market and `receiver`
    ///         receives shares.
    /// @param assets The amount of the underlying assets to deposit.
    /// @param receiver The account that should receive the cToken shares.
    /// @return shares The amount of cToken shares received by `receiver`.
    function deposit(
        uint256 assets,
        address receiver
    ) public override nonReentrant returns (uint256 shares) {
        shares = _deposit(assets, receiver);
    }

    /// @notice Caller deposits `shares` into the market and `receiver`
    ///         receives shares.
    /// @param shares The amount of the underlying assets quoted in shares
    ///               to deposit.
    /// @param receiver The account that should receive the cToken shares.
    /// @return assets The amount of cToken shares quoted in assets received
    ///                by `receiver`.
    function mint(
        uint256 shares,
        address receiver
    ) public override nonReentrant returns (uint256 assets) {
        assets = _mint(shares, receiver);
    }

    /// @notice Withdraws `assets` from the market, and burns `owner` shares.
    /// @dev Does not force collateral posted to be withdrawn.
    /// @param assets The amount of the underlying assets to withdraw.
    /// @param receiver The account that should receive the assets.
    /// @param owner The account that will burn their shares to withdraw
    ///              assets.
    /// @return shares The amount of cToken shares redeemed by `owner`.
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override nonReentrant returns (uint256 shares) {
        shares = _withdraw(assets, receiver, owner, false);
    }

    /// @notice Withdraws assets, quoted in `shares` from the market,
    ///         and burns `owner` shares.
    /// @dev Does not force collateral to be withdrawn.
    /// @param shares The amount of shares to be redeemed.
    /// @param receiver The account that should receive the assets.
    /// @param owner The account that will burn their shares to withdraw
    ///              assets.
    /// @return assets The amount of assets redeemed by `owner`.
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override nonReentrant returns (uint256 assets) {
        assets = _redeem(shares, receiver, owner, false, false);
    }

    /// @notice Withdraws assets, quoted in `shares` from the market,
    ///         and burns `owner` shares, sending assets to `receiver`.
    /// @dev Does not force collateral to be withdrawn.
    /// @param shares The amount of shares to redeemed.
    /// @param receiver The account that should receive the assets.
    /// @param owner The account that will burn their shares to withdraw
    ///              assets.
    /// @return assets The amount of assets redeemed by `owner` and sent to
    ///                `receiver`.
    function redeemFor(
        uint256 shares,
        address receiver,
        address owner
    ) public nonReentrant returns (uint256 assets) {
        assets = _redeem(shares, receiver, owner, true, false);
    }

    /// @notice Transfers `amount` tokens from caller to `to`.
    /// @param receiver The address of the destination account to receive
    ///                 `shares` shares.
    /// @param shares The number of shares to transfer from caller to
    ///               `receiver`.
    /// @return Whether or not the transfer succeeded or not.
    function transfer(
        address receiver,
        uint256 shares
    ) public override nonReentrant returns (bool) {
        _checkTransfer(shares, receiver, msg.sender);

        // Execute transfer.
        super.transfer(receiver, shares);
        return true;
    }

    /// @notice Transfers `amount` tokens from `owner` to `receiver`.
    /// @param owner The address of the account transferring `shares`
    ///              shares from.
    /// @param receiver The address of the destination account to receive
    ///                 `shares` shares.
    /// @param shares The number of shares to transfer from `owner` to
    ///               `receiver`.
    /// @return Whether or not the transfer succeeded or not.
    function transferFrom(
        address owner,
        address receiver,
        uint256 shares
    ) public override nonReentrant returns (bool) {
        _checkTransfer(shares, receiver, owner);

        // Execute transfer.
        super.transferFrom(owner, receiver, shares);
        return true;
    }

    /// @notice Returns whether the underlying token can be borrowed.
    /// @dev true = Borrowable; false = Not Borrowable.
    /// @return Whether this token is borrowable or not.
    function isBorrowable() public pure virtual returns (bool) {
        return false;
    }

    /// @dev Returns true that this contract implements both ERC4626
    ///      and ICToken interfaces.
    /// @param interfaceId The interface ID to check.
    /// @return result Whether the contract implements the interface.
    function supportsInterface(
        bytes4 interfaceId
    ) public pure virtual returns (bool result) {
        result = interfaceId == type(ICToken).interfaceId ||
            interfaceId == type(ERC4626).interfaceId;
    }

    /// @notice Returns the total number of assets backing shares.
    /// @return The total number of assets backing shares.
    function totalAssets() public view nonReadReentrant override returns (
        uint256
    ) {
        return _getTotalAssets();
    }

    /// @notice Returns the amount of shares that would be exchanged
    ///         by the vault for `assets` provided.
    /// @param assets The number of assets to theoretically use
    ///               for conversion to shares.
    /// @return The number of shares a user would receive for converting
    ///         `assets`.
    function convertToShares(
        uint256 assets
    ) public view nonReadReentrant override returns (uint256) {
        return _convertToShares(assets, _getTotalAssets());
    }

    /// @notice Returns the amount of assets that would be exchanged
    ///         by the vault for `shares` provided.
    /// @param shares The number of shares to theoretically use
    ///               for conversion to assets.
    /// @return The number of assets a user would receive for converting
    ///         `shares`.
    function convertToAssets(
        uint256 shares
    ) public view nonReadReentrant override returns (uint256) {
        return _convertToAssets(shares, _getTotalAssets());
    }

    /// @notice Allows users to simulate the effects of their deposit at
    ///         the current block.
    /// @param assets The number of assets to preview a deposit call.
    /// @return The shares received for depositing `assets`.
    function previewDeposit(
        uint256 assets
    ) public view override returns (uint256) {
        return _convertToShares(assets, _getTotalAssets());
    }

    /// @notice Allows users to simulate the effects of their mint at
    ///         the current block.
    /// @param shares The number of assets, quoted as shares to preview
    ///               a mint call.
    /// @return The shares received quoted as assets for depositing `shares`.
    function previewMint(
        uint256 shares
    ) public view override returns (uint256) {
        return _previewMint(shares, _getTotalAssets());
    }

    /// @notice Allows users to simulate the effects of their withdraw
    ///         at the current block.
    /// @param assets The number of assets to preview a withdraw call.
    /// @return The assets received quoted as shares for withdrawing `assets`.
    function previewWithdraw(
        uint256 assets
    ) public view virtual override returns (uint256) {
        return _previewWithdraw(assets, _getTotalAssets());
    }

    /// @notice Allows users to simulate the effects of their redeem at
    ///         the current block.
    /// @param shares The number of assets, quoted as shares to preview
    ///               a redeem call.
    /// @return The assets received for withdrawing `shares`.
    function previewRedeem(
        uint256 shares
    ) public view virtual override returns (uint256) {
        return _convertToAssets(shares, _getTotalAssets());
    }

    /// @notice Can accrue pending yield, configure next vesting
    ///         period, and updates vesting data, if needed.
    /// @dev May emit a {RatesAdjusted} event.
    function accrueIfNeeded() external nonReentrant {
        _accrueIfNeeded();
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Deposits `assets` and mints shares to `receiver`.
    /// @param assets The amount of the underlying asset to supply.
    /// @param receiver The account that should receive the cToken shares.
    /// @return shares The amount of cToken shares received by `receiver`.
    function _deposit(
        uint256 assets,
        address receiver
    ) internal virtual returns (uint256 shares) {
        _accrueIfNeeded();

        // Check for rounding error by converting assets to shares,
        // since we round down in previewDeposit.
        _checkZeroAmount(shares = _convertToShares(assets, _getTotalAssets()));
        _checkDeposit(receiver);

        // Fails if deposit not allowed, this stands in for a maxDeposit
        // check reviewing isListed and mintPaused != 2.
        marketManager.canMint(address(this));

        // Execute deposit.
        _processDeposit(assets, shares, msg.sender, receiver);
    }

    /// @notice Deposits assets and mints `shares` to `receiver`.
    /// @param shares The amount of the underlying assets quoted in shares
    ///               to supply.
    /// @param receiver The account that should receive the cToken shares.
    /// @return assets The amount of cToken shares quoted in assets received
    ///                by `receiver`.
    function _mint(
        uint256 shares,
        address receiver
    ) internal virtual returns (uint256 assets) {
        _accrueIfNeeded();

        _checkZeroAmount(shares);
        _checkDeposit(receiver);

        // Fail if mint not allowed, this stands in for a maxMint
        // check reviewing isListed and mintPaused != 2.
        marketManager.canMint(address(this));

        // Execute deposit.
        // No need to check for rounding error, previewMint rounds up.
        // We can pull _totalAssets directly here since any pending
        // rewards are already vested via _accrueIfNeeded().
        _processDeposit(
            assets = _previewMint(shares, _totalAssets),
            shares,
            msg.sender,
            receiver
        );
    }

    /// @notice Withdraws `assets` to `receiver` from the market and burns
    ///         `owner` shares.
    /// @dev Withdraw calls do not support the delegation system intentionally
    ///      to minimize code attack surface.
    /// @param assets The amount of the underlying asset to withdraw.
    /// @param receiver The account that should receive the assets.
    /// @param owner The account that will burn their shares to withdraw
    ///              assets.
    /// @param forceRedeemCollateral Whether the collateral should be always
    ///                              reduced from `owner`'s collateralPosted.
    /// @return shares The amount of assets, quoted in shares received
    ///                by `receiver`.
    function _withdraw(
        uint256 assets,
        address receiver,
        address owner,
        bool forceRedeemCollateral
    ) internal virtual returns (uint256 shares) {
        _accrueIfNeeded();

        // We can pull _totalAssets directly here since any pending
        // rewards are already vested via _accrueIfNeeded().
        uint256 ta = _totalAssets;
        uint256 balance = _checkRedemption(assets, owner, ta);

        // Validate caller is allowed to withdraw `shares` on behalf of
        // `owner`.
        _updateAllowance(owner, shares = _previewWithdraw(assets, ta));

        // Validate that `owner` can redeem `shares`.
        uint256 collateralRedeemed = marketManager.canRedeemWithCollateralRemoval(
            address(this),
            shares,
            owner,
            balance,
            collateralPosted[owner],
            forceRedeemCollateral
        );

        if (collateralRedeemed > 0) {
            _removeCollateral(collateralRedeemed, owner);
        }

        // Execute withdrawal.
        _processWithdraw(
            assets,
            shares,
            msg.sender,
            receiver,
            owner
        );
    }

    /// @notice Redeems assets to `receiver` from the market and burns
    ///         `owner` `shares`.
    /// @dev Redemption calls support the delegation system, allowing
    ///      an alternative approval system in parallel with the native
    ///      erc20 system.
    /// @param shares The amount of shares to burn to withdraw assets.
    /// @param receiver The account that should receive the assets.
    /// @param owner The account that will burn their shares to withdraw
    ///              assets.
    /// @param delegatedAction Whether the action is delegated and should
    ///                        use delegation system instead of normal
    ///                        approval system.
    /// @param forceRedeemCollateral Whether the collateral should be always
    ///                              reduced from `owner`'s collateralPosted.
    /// @return assets The amount of assets received by `receiver`.
    function _redeem(
        uint256 shares,
        address receiver,
        address owner,
        bool delegatedAction,
        bool forceRedeemCollateral
    ) internal virtual returns (uint256 assets) {
        _accrueIfNeeded();

        // We can pull _totalAssets directly here since any pending
        // rewards are already vested via _accrueIfNeeded().
        uint256 ta = _totalAssets;
        uint256 balance = _checkRedemption(
            assets = _convertToAssets(shares, ta),
            owner,
            ta
        );
        
        // Validate caller is allowed to withdraw `shares` on behalf of
        // `owner`. Or whether the caller has delegated approval
        // via plugin system or not.
        if (delegatedAction) {
            _checkDelegate(owner, msg.sender);
        } else {
            _updateAllowance(owner, shares);
        }

        // Validate that `owner` can redeem `shares`.
        uint256 collateralRedeemed = marketManager.canRedeemWithCollateralRemoval(
            address(this),
            shares,
            owner,
            balance,
            collateralPosted[owner],
            forceRedeemCollateral
        );

        if (collateralRedeemed > 0) {
            _removeCollateral(collateralRedeemed, owner);
        }

        // Execute withdrawal.
        _processWithdraw(assets, shares, msg.sender, receiver, owner);
    }

    /// @notice Helper function for posting `shares` as collateral
    ///         for `account` inside this market.
    /// @dev Emits {CollateralUpdated} event.
    ///      May emit {PositionUpdated} event inside Market Manager.
    /// @param owner The account posting collateral.
    /// @param shares The amount of shares to post as collateral.
    function _postCollateral(
        uint256 shares,
        address owner
    ) internal virtual {
        uint256 newNetCollateral = marketCollateralPosted + shares;
        marketManager.canCollateralize(address(this), owner, newNetCollateral);
        // Update user and market collateral posted invariants.
        collateralPosted[owner] = collateralPosted[owner] + shares;
        marketCollateralPosted = newNetCollateral;
        emit CollateralUpdated(shares, true, owner);
    }

    /// @notice Helper function for removing `shares` collateral posted for
    ///         `account` inside this market.
    /// @dev Emits a {CollateralUpdated} event.
    ///      May emit {PositionUpdated} event inside Market Manager.
    /// @param shares The number of shares that are posted of collateral
    ///               that should be removed.
    /// @param owner The address of the account to reduce collateral
    ///              posted from.
    function _removeCollateral(uint256 shares, address owner) internal {
        // Update user and market collateral posted invariants.
        collateralPosted[owner] = collateralPosted[owner] - shares;
        marketCollateralPosted = marketCollateralPosted - shares;
        emit CollateralUpdated(shares, false, owner);
    }

    /// @notice Can accrue yield, configure next vesting
    ///         period, and updates vesting data, if needed.
    function _accrueIfNeeded() internal virtual {}

    /// @notice Processes a deposit of `assets` from the market and mints
    ///         shares to `owner`, then increases `ta` by `assets`,
    ///         and vests rewards if `pending` > 0.
    /// @dev Emits a {Deposit} event.
    /// @param assets The amount of the underlying asset to deposit.
    /// @param shares The amount of shares minted to `to`.
    /// @param by The account that is executing the deposit.
    /// @param receiver The account that should receive `shares`.
    function _processDeposit(
        uint256 assets,
        uint256 shares,
        address by,
        address receiver
    ) internal {
        // Need to transfer before minting or ERC777s could reenter.
        SafeTransferLib.safeTransferFrom(asset(), by, address(this), assets);

        // Vests any rewards,if there are any, then update `_totalAssets`
        // invariant and prepare assets for withdrawal.
        _updateAssetsForDeposit(assets);

        // Mint `shares` to `receiver`.
        // NOTE: This is the erc20 mint function, meaning this is effectively
        //       super._mint().
        _mint(receiver, shares);

        emit Deposit(by, receiver, assets, shares);
        _afterDepositAction(shares, receiver);
    }

    /// @notice Processes a withdrawal of `shares` from the market by burning
    ///         `owner` shares and transferring `assets` to `receiver`, then
    ///         decreases `ta` by `assets`, and vests rewards if
    ///         `pending` > 0.
    /// @dev Emits a {Withdraw} event.
    /// @param assets The amount of the underlying asset to withdraw.
    /// @param shares The amount of shares redeemed from `owner`.
    /// @param by The account that is executing the withdrawal.
    /// @param receiver The account that should receive `assets`.
    /// @param owner The account that will have `shares` burned to withdraw
    ///              `assets`.
    function _processWithdraw(
        uint256 assets,
        uint256 shares,
        address by,
        address receiver,
        address owner
    ) internal virtual {
        _beforeWithdrawAction(shares, owner);

        // Burn `owner` `shares`.
        _burn(owner, shares);

        // Vests any rewards, if there are any, then update `_totalAssets`.
        // invariant and prepare assets for withdrawal.
        _updateAssetsForWithdrawal(assets);

        // Transfer the underlying assets to `receiver`.
        SafeTransferLib.safeTransfer(asset(), receiver, assets);

        emit Withdraw(by, receiver, owner, assets, shares);
    }

    /// @notice Used by a Position Manager contract to redeem assets from
    ///         collateralized shares by `account` to perform a complex
    ///         action.
    /// @param assets The amount of the underlying assets to redeem.
    /// @param shares The amount of the shares to redeem.
    /// @param owner The owner address of assets to redeem.
    /// @param balancePrior The balance of shares `owner` has before this
    ///                     redemption.
    /// @param action Instructions for a deleverage action containing:
    ///               cToken Address of the cToken that will be redeemed from
    ///                      and assets swapped into `borrowableCToken` asset.
    ///               collateralAssets The amount of `cToken` that will be
    ///                                deleveraged, in assets.
    ///               borrowableCToken Address of the borrowableCToken that
    ///                                will have its debt paid.
    ///               repayAssets The amount of `borrowableCToken` asset that
    ///                           will be repaid to lenders.
    ///               swapActions Swap actions instructions converting
    ///                           collateral asset into debt asset to
    ///                           facilitate deleveraging.
    ///               auxData Optional auxiliary data for execution of a
    ///                       deleverage action.
    function _processPositionManagerRedemption(
        uint256 assets,
        uint256 shares,
        address owner,
        uint256 balancePrior,
        IPositionManager.DeleverageAction memory action
    ) internal virtual {
        // Callback to Position Manager to execute remaining deleverage logic.
        IPositionManager(msg.sender).onRedeem(
            address(this),
            assets,
            owner,
            action
        );

        // Fails if redemption not allowed.
        uint256 collateralRedeemed = marketManager.canRedeemWithCollateralRemoval(
            address(this),
            shares,
            owner,
            balancePrior,
            collateralPosted[owner],
            false
        );

        if (collateralRedeemed > 0) {
            _removeCollateral(collateralRedeemed, owner);
        }
    }

    /// @notice Helper function to efficiently transfers cToken balances
    ///         without checking approvals.
    /// @dev This is only used in liquidations where maximal gas
    ///      optimization improves protocol MEV competitiveness,
    ///      improving protocol safety.
    ///      Emits a {Transfer} event.
    /// @param from The address of the account transferring `amount`
    ///             shares from.
    /// @param to The address of the destination account to receive `amount`
    ///           shares.
    /// @param amount The number of tokens to transfer from `from` to `to`.
    function _transferFromWithoutAllowance(
        address from,
        address to,
        uint256 amount
    ) internal {
        /// @solidity memory-safe-assembly
        assembly {
            let from_ := shl(96, from)
            // Compute the balance slot and load its value.
            mstore(0x0c, or(from_, _BALANCE_SLOT_SEED))
            let fromBalanceSlot := keccak256(0x0c, 0x20)
            let fromBalance := sload(fromBalanceSlot)
            // Revert if insufficient balance.
            if gt(amount, fromBalance) {
                mstore(0x00, 0xf4d678b8) // `InsufficientBalance()`.
                revert(0x1c, 0x04)
            }
            // Subtract and store the updated balance.
            sstore(fromBalanceSlot, sub(fromBalance, amount))
            // Compute the balance slot of `to`.
            mstore(0x00, to)
            let toBalanceSlot := keccak256(0x0c, 0x20)
            // Add and store the updated balance of `to`.
            // Will not overflow because the sum of all user balances
            // cannot exceed the maximum uint256 value.
            sstore(toBalanceSlot, add(sload(toBalanceSlot), amount))
            // Emit the {Transfer} event.
            mstore(0x20, amount)
            log3(
                0x20,
                0x20,
                _TRANSFER_EVENT_SIGNATURE,
                shr(96, from_),
                shr(96, mload(0x0c))
            )
        }
    }

    /// @notice Starts a cToken market, executed via marketManager.
    /// @dev This initial mint is a failsafe against rounding exploits,
    ///      although, we protect against them in many ways,
    ///      better safe than sorry.
    /// @dev Emits a {Deposit} event.
    /// @param by The account initializing deposits.
    function _initializeDeposits(address by) internal virtual {
        if (msg.sender != address(marketManager)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        address cTokenAddress = address(this);
        uint256 assets = _BASE_UNDERLYING_RESERVE;
        
        SafeTransferLib.safeTransferFrom(asset(), by, cTokenAddress, assets);

        // Because nobody can deposit into the market before initializeDeposits()
        // is called, this will always be the initial call.
        uint256 shares = _initialConvertToShares(assets);

        _mint(cTokenAddress, shares);
        _totalAssets = assets;

        emit Deposit(cTokenAddress, cTokenAddress, assets, shares);
        _afterDepositAction(shares, cTokenAddress);
    }

    /// @notice Updates the allowance for the caller.
    /// @param owner The owner of the allowance.
    /// @param amount The spent amount of the allowance.
    function _updateAllowance(address owner, uint256 amount) internal {
        if (msg.sender != owner) {
            uint256 allowed = allowance(owner, msg.sender);

            if (allowed != type(uint256).max) {
                _spendAllowance(owner, msg.sender, amount);
            }
        }
    }

    /// @dev Returns the decimals of the underlying asset.
    function _underlyingDecimals() internal view override returns (uint8) {
        return _decimals;
    }

    /// @notice Returns the total amount of the underlying asset in the vault,
    ///         including pending rewards that are vested.
    /// @return result The total number of underlying assets.
    function _getTotalAssets() internal view virtual returns (uint256 result) {
        result = _totalAssets;
    }

    /// @notice Returns the amount of shares that would be exchanged by the
    ///         vault for `assets` provided.
    /// @param assets The number of assets to theoretically use
    ///               for conversion to shares.
    /// @param ta The total number of assets to theoretically use
    ///           for conversion to shares.
    /// @return shares The number of shares a user would receive for
    ///                converting `assets`.
    function _convertToShares(
        uint256 assets,
        uint256 ta
    ) internal view returns (uint256 shares) {
        uint256 totalShares = totalSupply();

        shares = totalShares == 0
            ? assets
            : FixedPointMathLib.fullMulDiv(assets, totalShares, ta);
    }

    /// @notice Returns the amount of assets that would be exchanged by the
    ///         vault for `shares` provided.
    /// @param shares The number of shares to theoretically use
    ///               for conversion to assets.
    /// @param ta The total number of assets to theoretically use
    ///           for conversion to assets.
    /// @return assets The number of assets a user would receive for
    ///                converting `shares`.
    function _convertToAssets(
        uint256 shares,
        uint256 ta
    ) internal view returns (uint256 assets) {
        uint256 totalShares = totalSupply();

        assets = totalShares == 0
            ? shares
            : FixedPointMathLib.fullMulDiv(shares, ta, totalShares);
    }

    /// @notice Simulates the effects of a user mint at the current
    ///         block.
    /// @param shares The number of shares to preview a mint call.
    /// @param ta The total number of assets to simulate a mint at the
    ///           current block.
    /// @return assets The assets received for minting `shares`.
    function _previewMint(
        uint256 shares,
        uint256 ta
    ) internal view returns (uint256 assets) {
        uint256 totalShares = totalSupply();

        assets = totalShares == 0
            ? shares
            : FixedPointMathLib.fullMulDivUp(shares, ta, totalShares);
    }

    /// @notice Simulates the effects of a user withdrawal at the current
    ///         block.
    /// @param assets The number of assets to preview a withdrawal call.
    /// @param ta The total number of assets to simulate a withdrawal at the
    ///           current block.
    /// @return shares The shares received for withdrawing `assets`.
    function _previewWithdraw(
        uint256 assets,
        uint256 ta
    ) internal view returns (uint256 shares) {
        uint256 totalShares = totalSupply();

        shares = totalShares == 0
            ? assets
            : FixedPointMathLib.fullMulDivUp(assets, totalShares, ta);
    }

    /// @notice Updates asset values for a pending deposit.
    /// @param assets The amount of `asset()` to deposit.
    function _updateAssetsForDeposit(uint256 assets) internal virtual {
        // Document addition of `assets` to `ta` due to deposit.
        _totalAssets = _totalAssets + assets;
    }

    /// @notice Updates asset values for a pending withdrawal.
    /// @param assets The amount of `asset()` to withdraw.
    function _updateAssetsForWithdrawal(uint256 assets) internal virtual {
        // Document removal of `assets` from `ta` due to withdrawal.
        _totalAssets = _totalAssets - assets;
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

    /// @notice Helper function to check validity of a proposed posting
    ///         of collateral.
    /// @param shares The number of shares to post as collateral from `owner`.
    /// @param owner The address of the account posting `shares`
    ///              as collateral.
    function _checkPostCollateral(
        uint256 shares,
        address owner
    ) internal view {
        _checkZeroAmount(shares);

        if (collateralPosted[owner] + shares > balanceOf(owner)) {
            _revert(_INSUFFICIENT_LIQUIDITY_SELECTOR);
        }
    }

    /// @notice Helper function to check validity of a proposed removal
    ///         of collateral.
    /// @param shares The number of shares to remove as collateral
    ///               from `owner`.
    /// @param owner The address of the account removing `shares`
    ///              as collateral.
    function _checkRemoveCollateral(
        uint256 shares,
        address owner
    ) internal {
        _checkZeroAmount(shares);

        uint256 collateralOf = collateralPosted[owner];
        if (collateralOf < shares) {
            _revert(_INSUFFICIENT_LIQUIDITY_SELECTOR);
        }

        marketManager.canRedeemWithCollateralRemoval(
            address(this),
            shares,
            owner,
            balanceOf(owner),
            collateralOf,
            true
        );
    }

    /// @notice Helper function to prepare for a transfer.
    /// @param shares The number of shares to transfer from `owner` to
    ///               `receiver`.
    /// @param receiver The address of the destination account to receive
    ///                 `shares` shares.y
    /// @param owner The address of the account transferring `shares`
    ///              shares from.
    function _checkTransfer(
        uint256 shares,
        address receiver,
        address owner
    ) internal {
        _checkZeroAmount(shares);
        if (owner == receiver) {
            revert BaseCToken__TransferError();
        }
        
        uint256 collateralOf = collateralPosted[owner];
        
        // Fails if transfer not allowed.
        uint256 collateralRedeemed = marketManager.canTransfer(
            address(this),
            shares,
            msg.sender,
            balanceOf(owner),
            collateralOf,
            collateralOf > 0 ? true : false
        );

        if (collateralRedeemed > 0) {
            _removeCollateral(collateralRedeemed, owner);
        }
        
        _beforeTransferAction(shares, receiver, owner);
    }

    /// @notice An optional set of instructions to check before processing
    ///         a deposit of assets.
    function _checkDeposit(address /* owner */) internal view virtual {}

    /// @notice Returns the total assets invariant, any pending rewards for
    ///         depositors and other values to process a withdrawal.
    /// @param assets The amount of the underlying asset to withdraw.
    /// @param owner The account that will burn their shares to withdraw
    ///              assets.
    /// @param ta The current total amount of assets inside this vault.
    /// @return balance The balance of shares `owner`.
    function _checkRedemption(
        uint256 assets,
        address owner,
        uint256 ta
    ) internal view returns (uint256 balance) {
        _checkZeroAmount(assets);

        // Check whether `assets` is above their allowed redemption limit.
        if (assets > _convertToAssets(balance = balanceOf(owner), ta)) {
            _revert(_INSUFFICIENT_LIQUIDITY_SELECTOR);
        }

        _checkAssetsHeld(assets);
    }

    /// @notice Checks to make sure an action is not an empty action.
    function _checkZeroAmount(uint256 assets) internal pure {
        /// @solidity memory-safe-assembly
        assembly {
            if iszero(assets) {
                mstore(0x00, 0xc0883a55) // Revert BaseCToken__ZeroAmount().
                // Return bytes 29-32 for the selector.
                revert(0x1c, 0x04)
            }
        }
    }

    /// @notice An optional set of instructions to check before processing
    ///         a redemption of assets.
    function _checkAssetsHeld(uint256 /* assets */) internal view virtual {}

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

    /// @dev Returns `floor(x * y / d)`.
    /// Reverts if `x * y` overflows, or `d` is zero.
    function _mulDiv(
        uint256 x,
        uint256 y,
        uint256 d
    ) internal pure returns (uint256 z) {
        z = FixedPointMathLib.mulDiv(x, y, d);
    }

    /// INTERNAL HOOK FUNCTIONS WHICH MAY BE OVERRIDDEN ///

    /// @notice An optional set of instructions to execute before processing
    ///         a deposit of `receiver`'s shares.
    function _afterDepositAction(uint256, address) internal virtual {}

    /// @notice An optional set of instructions to execute before processing
    ///         a withdrawal of `owners`'s shares.
    function _beforeWithdrawAction(uint256, address) internal virtual {}

    /// @notice An optional set of instructions to execute before processing
    ///         a transfer of `owner`'s shares to `receiver`.
    function _beforeTransferAction(uint256, address, address) internal virtual {}

    /// @notice An optional set of instructions to execute before processing
    ///         liquidation of `account`'s collateral.
    function _beforeLiqAction(uint256, address, address) internal virtual {}
}
