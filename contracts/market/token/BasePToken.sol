// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Multicall } from "contracts/libraries/Multicall.sol";
import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";
import { WAD } from "contracts/libraries/Constants.sol";
import { ERC4626 } from "contracts/libraries/external/ERC4626.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { ReentrancyGuard } from "contracts/libraries/external/ReentrancyGuard.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IMToken, AccountSnapshot } from "contracts/interfaces/IMToken.sol";
import { IPositionManagement } from "contracts/interfaces/IPositionManagement.sol";

/// @notice Vault Positions must have all assets ready for withdraw,
///         IE assets can NOT be locked.
///         This way assets can be easily liquidated when loans default.
/// @dev Curvance's pTokens are ERC4626 compliant. However, they follow their
///      own design flow modifying underlying mechanisms such as totalAssets
///      following a vesting mechanism in compounding vaults but a direct
///      conversion in basic or "primitive" vaults.
///
///      The "pToken" employs two different methods of engaging with the
///      Curvance protocol. Users can deposit an unlimited amount of assets,
///      which may or may not benefit from some form of auto compounded yield.
///
///      Users can at any time, choose to "post" their pTokens as collateral
///      inside the Curvance Protocol, unlocking their ability to borrow
///      against these assets. Posting collateral carries restrictions,
///      not all assets inside Curvance can be collateralized, and if they
///      can, they have a "Collateral Cap" which restricts the total amount of
///      exogeneous risk introduced by each asset into the system.
///      Rehypothecation of collateral assets has also been removed from the
///      system, reducing the likelihood of introducing systematic risk to the
///      broad DeFi landscape.
///
///      These caps can be updated as needed by the DAO and should be
///      configured based on "sticky" onchain liquidity in the corresponding
///      asset.
///
///      The vaults can have their compounding, minting, or redemption
///      functionality paused. Modifying the maximum mint, deposit,
///      withdrawal, or redemptions possible.
///
///      "Safe" versions of functions have been added that introduce
///      additional reentry and update protection logic to minimize risks
///      when integrating Curvance into external protocols.
///
abstract contract BasePToken is
    ERC4626,
    PluginDelegable,
    ReentrancyGuard,
    Multicall
{
    /// CONSTANTS ///

    /// @dev `bytes4(keccak256(bytes("BasePToken__Unauthorized()")))`
    uint256 internal constant _UNAUTHORIZED_SELECTOR = 0xc123b8f2;
    /// @dev `bytes4(keccak256(bytes("BasePToken__InsufficientShares()")))`
    uint256 internal constant _INSUFFICIENT_SHARES_SELECTOR = 0x3bb64346;
    /// @dev `keccak256(bytes("Deposit(address,address,uint256,uint256)"))`.
    uint256 internal constant _DEPOSIT_EVENT_SIGNATURE =
        0xdcbc1c05240f31ff3ad067ef1ee35ce4997762752e3a095284754544f4c709d7;
    /// @dev `keccak256(bytes("Withdraw(address,address,address,uint256,uint256)"))`.
    uint256 internal constant _WITHDRAW_EVENT_SIGNATURE =
        0xfbde797d201c681b91056529119e0b02407c7bb96a4a2c75c01fc9667232c8db;
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
    uint256 internal constant _BASE_UNDERLYING_RESERVE = 42069;

    /// @notice Address of the Market Manager linked to this contract.
    IMarketManager public immutable marketManager;

    /// @notice Underlying asset for the pToken.
    /// @dev CANNOT be a fee-on-transfer token.
    IERC20 internal immutable _asset;
    /// @notice pToken decimal precision.
    uint8 internal immutable _decimals;

    /// STORAGE ///

    /// @notice Amount of pToken that has been posted as collateral,
    ///         in shares.
    uint256 marketCollateralPosted;

    /// @notice Token name metadata.
    string internal _name;
    /// @notice Token symbol metadata.
    string internal _symbol;
    /// @notice Total PToken underlying token assets, minus pending vesting.
    uint256 internal _totalAssets;

    /// @notice Collateral information associated with an account.
    /// @dev Account address => Collateral data.
    mapping(address => uint256) public collateralPosted;
    
    /// EVENTS ///

    event CollateralUpdated(
        address account,
        uint256 amount,
        bool increased
    );

    event Liquidated(
        address liquidator,
        address account,
        uint256 liquidatedAmount,
        address debtToken
    );

    /// ERRORS ///

    error BasePToken__EmptyAction();
    error BasePToken__ZeroShares();
    error BasePToken__InsufficientShares();
    error BasePToken__InsufficientAssets();
    error BasePToken__InsufficientCollateral();
    error BasePToken__Unauthorized();
    error BasePToken__InvalidMarketManager();
    error BasePToken__UnsupportedChain();
    error BasePToken__UnderlyingAssetTotalSupplyExceedsMaximum();

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        IERC20 asset_,
        address MarketManager_
    ) PluginDelegable(centralRegistry_) {
        _asset = asset_;
        _name = string.concat("Curvance ", asset_.name());
        _symbol = string.concat("c", asset_.symbol());
        _decimals = asset_.decimals();

        // Ensure that marketManager parameter is a marketManager.
        if (!centralRegistry.isMarketManager(MarketManager_)) {
            revert BasePToken__InvalidMarketManager();
        }

        // Set `marketManager`.
        marketManager = IMarketManager(MarketManager_);

        // Sanity check underlying so that we know users will not need to
        // mint anywhere close to exchange rate, in `WAD`.
        if (asset_.totalSupply() >= type(uint232).max) {
            revert BasePToken__UnderlyingAssetTotalSupplyExceedsMaximum();
        }
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Starts a pToken market, executed via marketManager.
    /// @dev This initial mint is a failsafe against rounding exploits,
    ///      although, we protect against them in many ways,
    ///      better safe than sorry.
    ///      NOTE: ONLY CALLED ONCE DURING TOKEN LISTING BY DAO AUTHORIZED
    ///            ADDRESS FROM THE MARKET MANAGER.
    /// @param by The account initializing the pToken market.
    /// @return Returns with true when successful.
    function startMarket(
        address by
    ) external virtual nonReentrant returns (bool) {
        _startMarket(by);
        return true;
    }

    /// @notice Helper function for Position Management contract to
    ///         redeem assets.
    /// @param owner The owner address of assets to redeem.
    /// @param assets The amount of the underlying assets to redeem.
    /// @param deleverageData Struct containing information on the desired
    ///                       deleverage action to execute. Containing values:
    ///                       1. Address of pToken that will be routed into
    ///                          eToken underlying to repay outstanding debt.
    ///                       2. The amount of pTokens that will be
    ///                          deleveraged.
    ///                       3. Address of eToken that will have its
    ///                          underlying token debt repaid.
    ///                       4. Optional struct containing instructions on
    ///                          how to handle swapping into eToken underlying
    ///                          to facilitate deleveraging.
    ///                       5. The amount of underlying tokens that will be
    ///                          repaid to the eToken lenders.
    ///                       6. Optional auxiliary data for execution of a
    ///                          deleverage action.
    function withdrawByPositionManagement(
        address owner,
        uint256 assets,
        IPositionManagement.DeleverageStruct memory deleverageData
    ) external nonReentrant {
        // Validate that the position folding contract is calling.
        if (!marketManager.positionManagers(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        (
            uint256 ta,
            uint256 pending,
            uint256 balancePrior,
            uint256 shares
        ) = _getValuesForWithdrawal(assets, owner);

        _processWithdraw(
            msg.sender,
            msg.sender,
            owner,
            assets,
            shares,
            ta,
            pending
        );

        // Process the Position Management redemption leg.
        _processPositionManagementRedemption(
            owner,
            assets,
            shares,
            balancePrior,
            deleverageData
        );
    }

    /// @notice Caller deposits assets into the market, `receiver` receives
    ///         shares, and turns on collateralization of the assets.
    /// @dev The caller must be depositing for themselves, or be managing
    ///      their position through the position folding contract.
    /// @param assets The amount of the underlying assets to deposit.
    /// @param receiver The account that should receive the pToken shares.
    /// @return shares The amount of pToken shares received by `receiver`.
    function depositAsCollateral(
        uint256 assets,
        address receiver
    ) external nonReentrant returns (uint256 shares) {
        if (
            msg.sender != receiver &&
            !marketManager.positionManagers(msg.sender)
        ) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        shares = _deposit(assets, receiver);

        // Can skip _checkPostCollateral since we know that `shares` is not
        // 0 and `receiver` has shares to post as collateral due to prior
        // _deposit action.
        _postCollateral(receiver, shares);
    }

    /// @notice Caller deposits assets into the market, `receivier` receives
    ///         shares, and turns on collateralization of the assets.
    /// @dev Requires that `receiver` approves the caller prior to
    ///      collateralize on their behalf.
    ///      NOTE: Be careful who you approve here!
    ///      They can delay redemption of assets through repeated
    ///      collateralization preventing withdrawal.
    ///      If the caller is not approved to collateralize the function will
    ///      simply deposit assets on behalf of `receiver`.
    /// @param assets The amount of the underlying assets to deposit.
    /// @param receiver The account that should receive the pToken shares.
    /// @return shares The amount of pToken shares received by `receiver`.
    function depositAsCollateralFor(
        uint256 assets,
        address receiver
    ) external nonReentrant returns (uint256 shares) {
        _checkDelegate(receiver, msg.sender);

        shares = _deposit(assets, receiver);

        // Can skip _checkPostCollateral since we know that `shares` is not
        // 0 and `receiver` has shares to post as collateral due to prior
        // _deposit action.
        _postCollateral(receiver, shares);
    }

    /// @notice Caller withdraws assets from the market and burns their shares.
    /// @dev Forces collateral to be withdrawn from `owner` collateralPosted.
    /// @param assets The amount of the underlying assets to withdraw.
    /// @param receiver The account that should receive the assets.
    /// @param owner The account that will burn their shares to withdraw assets.
    /// @return shares the amount of pToken shares redeemed by `owner`.
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

    /// @notice Caller withdraws assets from the market and burns their shares,
    ///         on behalf of `owner`.
    /// @dev Forces collateral to be withdrawn from `owner` collateralPosted.
    /// @param shares The amount of shares to redeemed.
    /// @param receiver The account that should receive the assets.
    /// @param owner The account that will burn their shares to withdraw assets.
    /// @return assets the amount of assets redeemed by `owner`.
    function redeemCollateralFor(
        uint256 shares,
        address receiver,
        address owner
    ) external nonReentrant returns (uint256 assets) {
        assets = _redeem(shares, receiver, owner, true, true);
    }

    /// @notice Posts `shares` as collateral inside this market.
    /// @dev The position token must have collateralization
    ///      enabled (collRatio > 0).
    /// @param shares The amount of shares to post as collateral.
    function postCollateral(uint256 shares) external nonReentrant {
        _checkPostCollateral(msg.sender, shares);

        _postCollateral(msg.sender, shares);
    }

    /// @notice Posts `shares` as collateral inside this market
    ///         for `account`.
    /// @dev The position token must have collateralization
    ///      enabled (collRatio > 0).
    /// @param shares The amount of shares to post as collateral.
    function postCollateralFor(
        address account,
        uint256 shares
    ) external nonReentrant {
        _checkDelegate(account, msg.sender);
        _checkPostCollateral(account, shares);

        _postCollateral(msg.sender, shares);
    }

    /// @notice Removes `shares` of collateral posted inside this market.
    /// @param shares The number of shares that are posted of collateral
    ///               that will be removed.
    function removeCollateral(uint256 shares) external nonReentrant {
        _checkRemoveCollateral(msg.sender, shares);

        _removeCollateral(msg.sender, shares);
    }

    /// @notice Removes `shares` of collateral posted inside this market
    ///         for `account`.
    /// @param shares The number of shares that are posted of collateral
    ///               that will be removed.
    function removeCollateralFor(
        address account,
        uint256 shares
    ) external nonReentrant {
        _checkDelegate(account, msg.sender);
        _checkRemoveCollateral(msg.sender, shares);

        _removeCollateral(msg.sender, shares);
    }

    /// @notice Returns share -> asset exchange rate, in `WAD`, safely.
    /// @dev Has added re-entry lock for protocols building ontop of Curvance
    ///      Protocol to have confidence in data quality.
    ///      Oracle Manager calculates pToken value from this exchange rate.
    /// @return The share -> asset exchange rate, in `WAD`.
    function exchangeRateSafe() external view returns (uint256) {
        return convertToAssetsSafe(WAD);
    }

    /// @notice Returns share -> asset exchange rate, in `WAD`.
    /// @dev Oracle Manager calculates pToken value from this exchange rate.
    /// @return The share -> asset exchange rate, in `WAD`.
    function exchangeRateCached() external view returns (uint256) {
        return convertToAssets(WAD);
    }

    /// @notice Returns a snapshot of the pToken and `account` data.
    /// @dev Used by MarketManager to efficiently perform liquidity checks.
    /// NOTE: debtBalance always return 0 to runtime gas in MarketManager
    ///       since it is unused.
    /// @return The snapshot of the pToken and `account` data.
    function getSnapshot(
        address account
    ) external view virtual returns (AccountSnapshot memory) {
        return (
            AccountSnapshot({
                asset: address(this),
                isPToken: true,
                decimals: decimals(),
                collateralPosted: collateralPosted[account],
                debtBalance: 0, // This is a pToken so always 0.
                exchangeRate: convertToAssets(WAD)
            })
        );
    }

    /// @notice Transfers position tokens (this pToken) from `account`
    ///         to `liquidator`.
    /// @dev Will fail unless called by a eToken during the process
    ///      of liquidation.
    /// @param liquidator The account receiving seized collateral.
    /// @param accounts An array containing the accounts having
    ///                 collateral seized.
    /// @param shares An array containing the number of pTokens
    ///               shares to seize.
    /// @param debtToken The market in which debt was repaid for
    ///                  the accounts.
    function seize(
        address liquidator,
        address[] calldata accounts,
        uint256[] calldata shares,
        address debtToken
    ) external nonReentrant {
        // Fails if seizure not allowed.
        marketManager.canSeize(address(this), msg.sender);

        // We know that accounts and shares arrays are the same length since
        // its validated inside the eToken getting debt repaid within.

        uint256 cachedAmount;
        address cachedAccount;
        uint256 numAccounts = accounts.length;
        for (uint256 i; i < numAccounts; ++i) {
            cachedAmount = shares[i];
            // If theres no debt to repay for this user can
            // skip them.
            if (cachedAmount == 0) {
                continue;
            }

            cachedAccount = accounts[i];

            // Execute any prior liquidation actions.
            _beforeLiquidationAction(cachedAccount, liquidator, cachedAmount);

            // Remove liquidated account's collateral.
            _removeCollateral(cachedAccount, cachedAmount);
            // Efficiently transfer liquidated token balance from `cachedAccount`
            // to `liquidator`.
            _transferFromWithoutAllowance(cachedAccount, liquidator, cachedAmount);
            emit Liquidated(
                liquidator,
                cachedAccount,
                cachedAmount,
                debtToken
            );
        }
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
    /// @dev We have both asset() and underlying() for composability.
    /// @return The address of the underlying asset.
    function asset() public view override returns (address) {
        return address(_asset);
    }

    /// @notice Returns the address of the underlying asset.
    /// @dev We have both asset() and underlying() for composability.
    /// @return The address of the underlying asset.
    function underlying() external view returns (address) {
        return address(_asset);
    }

    /// @notice Returns the maximum assets that can be deposited at a time.
    /// @dev If depositing is disabled maxAssets should be equal to 0,
    ///      according to ERC4626 spec.
    /// @param to The address who would receive minted shares.
    /// @return maxAssets The maximum assets that can be deposited at a time.
    function maxDeposit(
        address to
    ) public view override returns (uint256 maxAssets) {
        if (
            !marketManager.isListed(address(this)) ||
            marketManager.mintPaused(address(this)) == 2
        ) {
            // We do not need to set maxAssets here since its initialized
            // as 0 so we can just return.
            return maxAssets;
        }
        maxAssets = super.maxDeposit(to);
    }

    /// @notice Returns the maximum shares that can be minted at a time.
    /// @dev If depositing is disabled minMint should be equal to 0,
    ///      according to ERC4626 spec.
    /// @param to The address who would receive minted shares.
    /// @return maxShares The maximum shares that can be minted at a time.
    function maxMint(
        address to
    ) public view override returns (uint256 maxShares) {
        if (
            !marketManager.isListed(address(this)) ||
            marketManager.mintPaused(address(this)) == 2
        ) {
            // We do not need to set maxShares here since its initialized
            // as 0 so we can just return.
            return maxShares;
        }
        maxShares = super.maxMint(to);
    }

    /// @notice Caller deposits assets into the market and receives shares.
    /// @param assets The amount of the underlying assets to deposit.
    /// @param receiver The account that should receive the pToken shares.
    /// @return shares The amount of pToken shares received by `receiver`.
    function deposit(
        uint256 assets,
        address receiver
    ) public override nonReentrant returns (uint256 shares) {
        shares = _deposit(assets, receiver);
    }

    /// @notice Caller deposits assets into the market and receives shares.
    /// @param shares The amount of the underlying assets quoted in shares
    ///               to deposit.
    /// @param receiver The account that should receive the pToken shares.
    /// @return assets The amount of pToken shares quoted in assets received
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
    /// @return shares The amount of pToken shares redeemed by `owner`.
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
    ///         and burns `owner` shares, on behalf of `owner`.
    /// @dev Does not force collateral to be withdrawn.
    /// @param shares The amount of shares to be redeemed.
    /// @param receiver The account that should receive the assets.
    /// @param owner The account that will burn their shares to withdraw
    ///              assets.
    /// @return assets The amount of assets redeemed by `owner`.
    function redeemFor(
        uint256 shares,
        address receiver,
        address owner
    ) public nonReentrant returns (uint256 assets) {
        assets = _redeem(shares, receiver, owner, true, false);
    }

    /// @notice Transfers `amount` tokens from caller to `to`.
    /// @param to The address of the destination account to receive `amount`
    ///           shares.
    /// @param amount The number of tokens to transfer from caller to `to`.
    /// @return Whether or not the transfer succeeded or not.
    function transfer(
        address to,
        uint256 amount
    ) public override nonReentrant returns (bool) {
        _checkTransfer(msg.sender, to, amount);

        // Execute transfer.
        super.transfer(to, amount);
        return true;
    }

    /// @notice Transfers `amount` tokens from `from` to `to`.
    /// @param from The address of the account transferring `amount`
    ///             shares from.
    /// @param to The address of the destination account to receive `amount`
    ///           shares.
    /// @param amount The number of tokens to transfer from `from` to `to`.
    /// @return Whether or not the transfer succeeded or not.
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override nonReentrant returns (bool) {
        _checkTransfer(from, to, amount);

        // Execute transfer.
        super.transferFrom(from, to, amount);
        return true;
    }

    /// @notice Returns the type of Curvance token.
    /// @dev true = Position token; false = Debt token.
    /// @return Whether this token is a pToken or not.
    function isPToken() public pure returns (bool) {
        return true;
    }

    /// @notice Returns whether the underlying token can be collateralized.
    /// @dev true = Collateralizable; false = Not Collateralizable.
    /// @return Whether this token is collateralizable or not.
    function isCollateralizable() public pure virtual returns (bool) {
        return true;
    }

    /// @notice Returns whether the underlying token can be borrowed.
    /// @dev true = Borrowable; false = Not Borrowable.
    /// @return Whether this token is borrowable or not.
    function isBorrowable() public pure virtual returns (bool) {
        return false;
    }

    /// @dev Returns true that this contract implements both ERC4626
    ///      and IMToken interfaces.
    /// @param interfaceId The interface ID to check.
    /// @return Whether the contract implements the interface.
    function supportsInterface(
        bytes4 interfaceId
    ) public pure virtual returns (bool) {
        return
            interfaceId == type(IMToken).interfaceId ||
            interfaceId == type(ERC4626).interfaceId;
    }

    /// @notice Returns the total number of assets backing shares, safely.
    /// @dev Has added re-entry lock for protocols building ontop of Curvance
    ///      Protocol to have confidence in data quality.
    /// @return The total number of assets backing shares.
    function totalAssetsSafe()
        public
        view
        virtual
        nonReadReentrant
        returns (uint256)
    {
        return _totalAssets;
    }

    /// @notice Returns the total number of assets backing shares.
    /// @return The total number of assets backing shares.
    function totalAssets() public view virtual override returns (uint256) {
        return _totalAssets;
    }

    /// @notice Returns the amount of shares that would be exchanged
    ///         by the vault for `assets` provided, safely.
    /// @dev Has added re-entry lock for protocols building ontop of Curvance
    ///      Protocol to have confidence in data quality.
    /// @param assets The number of assets to theoretically use
    ///               for conversion to shares.
    /// @return The number of shares a user would receive for converting
    ///         `assets`.
    function convertToSharesSafe(
        uint256 assets
    ) public view nonReadReentrant returns (uint256) {
        return _convertToShares(assets, totalAssets());
    }

    /// @notice Returns the amount of shares that would be exchanged
    ///         by the vault for `assets` provided.
    /// @param assets The number of assets to theoretically use
    ///               for conversion to shares.
    /// @return The number of shares a user would receive for converting
    ///         `assets`.
    function convertToShares(
        uint256 assets
    ) public view override returns (uint256) {
        return _convertToShares(assets, totalAssets());
    }

    /// @notice Returns the amount of assets that would be exchanged
    ///         by the vault for `shares` provided, safely.
    /// @dev Has added re-entry lock for protocols building ontop of Curvance
    ///      Protocol to have confidence in data quality.
    /// @param shares The number of shares to theoretically use
    ///               for conversion to assets.
    /// @return The number of assets a user would receive for converting
    ///         `assets`.
    function convertToAssetsSafe(
        uint256 shares
    ) public view nonReadReentrant returns (uint256) {
        return _convertToAssets(shares, totalAssets());
    }

    /// @notice Returns the amount of assets that would be exchanged
    ///         by the vault for `shares` provided.
    /// @param shares The number of shares to theoretically use
    ///               for conversion to assets.
    /// @return The number of assets a user would receive for converting
    ///         `shares`.
    function convertToAssets(
        uint256 shares
    ) public view override returns (uint256) {
        return _convertToAssets(shares, totalAssets());
    }

    /// @notice Allows users to simulate the effects of their deposit at
    ///         the current block.
    /// @param assets The number of assets to preview a deposit call.
    /// @return The shares received for depositing `assets`.
    function previewDeposit(
        uint256 assets
    ) public view override returns (uint256) {
        return _previewDeposit(assets, totalAssets());
    }

    /// @notice Allows users to simulate the effects of their mint at
    ///         the current block.
    /// @param shares The number of assets, quoted as shares to preview
    ///               a mint call.
    /// @return The shares received quoted as assets for depositing `shares`.
    function previewMint(
        uint256 shares
    ) public view override returns (uint256) {
        return _previewMint(shares, totalAssets());
    }

    /// @notice Allows users to simulate the effects of their withdraw
    ///         at the current block.
    /// @param assets The number of assets to preview a withdraw call.
    /// @return The assets received quoted as shares for withdrawing `assets`.
    function previewWithdraw(
        uint256 assets
    ) public view virtual override returns (uint256) {
        return _previewWithdraw(assets, totalAssets());
    }

    /// @notice Allows users to simulate the effects of their redeem at
    ///         the current block.
    /// @param shares The number of assets, quoted as shares to preview
    ///               a redeem call.
    /// @return The assets received for withdrawing `shares`.
    function previewRedeem(
        uint256 shares
    ) public view virtual override returns (uint256) {
        return _previewRedeem(shares, totalAssets());
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Deposits `assets` and mints shares to `receiver`.
    /// @param assets The amount of the underlying asset to supply.
    /// @param receiver The account that should receive the pToken shares.
    /// @return shares The amount of pToken shares received by `receiver`.
    function _deposit(
        uint256 assets,
        address receiver
    ) internal returns (uint256 shares) {
        _checkZeroAmount(assets);

        // Fails if deposit not allowed, this stands in for a maxDeposit
        // check reviewing isListed and mintPaused != 2.
        marketManager.canMint(address(this));

        // Calculate any pending rewards and new total assets invariant.
        (uint256 ta, uint256 pending) = _calculateTotalAssetsWithRewards();

        // Check for rounding error, since we round down in previewDeposit.
        if ((shares = _previewDeposit(assets, ta)) == 0) {
            revert BasePToken__ZeroShares();
        }

        // Execute deposit.
        _processDeposit(msg.sender, receiver, assets, shares, ta, pending);
        _afterDepositAction(receiver, shares);
    }

    /// @notice Deposits assets and mints `shares` to `receiver`.
    /// @param shares The amount of the underlying assets quoted in shares
    ///               to supply.
    /// @param receiver The account that should receive the pToken shares.
    /// @return assets The amount of pToken shares quoted in assets received
    ///                by `receiver`.
    function _mint(
        uint256 shares,
        address receiver
    ) internal returns (uint256 assets) {
        _checkZeroAmount(shares);

        // Fail if mint not allowed, this stands in for a maxMint
        // check reviewing isListed and mintPaused != 2.
        marketManager.canMint(address(this));

        // Calculate any pending rewards and new total assets invariant.
        (uint256 ta, uint256 pending) = _calculateTotalAssetsWithRewards();

        // No need to check for rounding error, previewMint rounds up.
        assets = _previewMint(shares, ta);

        // Execute deposit.
        _processDeposit(msg.sender, receiver, assets, shares, ta, pending);
        _afterDepositAction(receiver, shares);
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
    ) internal returns (uint256) {
        (
            uint256 ta,
            uint256 pending,
            uint256 balancePrior,
            uint256 shares
        ) = _getValuesForWithdrawal(assets, owner);

        // Validate caller is allowed to withdraw `shares` on behalf of
        // `owner`.
        _updateAllowance(owner, shares);

        // Validate that `owner` can redeem `shares`.
        uint256 collateralToRemove = marketManager.canRedeemWithCollateralRemoval(
            address(this),
            owner,
            balancePrior,
            collateralPosted[owner],
            shares,
            forceRedeemCollateral
        );

        if (collateralToRemove > 0) {
            _removeCollateral(owner, collateralToRemove);
        }

        // Execute withdrawal.
        _processWithdraw(
            msg.sender,
            receiver,
            owner,
            assets,
            shares,
            ta,
            pending
        );

        return shares;
    }

    /// @notice Returns the total assets invariant, any pending rewards for
    ///         depositors and other values to process a withdrawal.
    /// @param assets The amount of the underlying asset to withdraw.
    /// @param owner The account that will burn their shares to withdraw
    ///              assets.
    /// @return ta The total assets invariant.
    /// @return pending The pending rewards for depositors.
    /// @return balancePrior The balance of shares `owner`.
    /// @return shares The amount of shares to burn to withdraw `assets`.
    function _getValuesForWithdrawal(
        uint256 assets,
        address owner
    )
        internal
        view
        returns (
            uint256 ta,
            uint256 pending,
            uint256 balancePrior,
            uint256 shares
        )
    {
        _checkZeroAmount(assets);

        // Calculate any pending rewards and new total assets invariant.
        (ta, pending) = _calculateTotalAssetsWithRewards();
        // Cache balanceOf of `owner`.
        balancePrior = balanceOf(owner);

        // We use a modified version of maxWithdraw with newly vested assets.
        if (assets > _convertToAssets(balancePrior, ta)) {
            revert BasePToken__InsufficientAssets();
        }

        // No need to check for rounding error, previewWithdraw rounds up.
        shares = _previewWithdraw(assets, ta);
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
    ) internal returns (uint256 assets) {
        _checkZeroAmount(shares);

        // Validate caller is allowed to withdraw `shares` on behalf of
        // `owner`. Or whether the caller has delegated approval or not.
        if (delegatedAction) {
            _checkDelegate(owner, msg.sender);
        } else {
            _updateAllowance(owner, shares);
        }

        // Check whether `shares` is above max allowed redemption.
        if (shares > maxRedeem(owner)) {
            _revert(_INSUFFICIENT_SHARES_SELECTOR);
        }

        // Validate that `owner` can redeem `shares`.
        uint256 collateralToRemove = marketManager.canRedeemWithCollateralRemoval(
            address(this),
            owner,
            balanceOf(owner),
            collateralPosted[owner],
            shares,
            forceRedeemCollateral
        );

        if (collateralToRemove > 0) {
            _removeCollateral(owner, collateralToRemove);
        }

        // Calculate any pending rewards and new total assets invariant.
        (uint256 ta, uint256 pending) = _calculateTotalAssetsWithRewards();

        // Check for rounding error, since we round down in previewRedeem.
        if ((assets = _previewRedeem(shares, ta)) == 0) {
            revert BasePToken__InsufficientAssets();
        }

        // Execute withdrawal.
        _processWithdraw(
            msg.sender,
            receiver,
            owner,
            assets,
            shares,
            ta,
            pending
        );
    }

    /// @notice Helper function for posting `shares` as collateral
    ///         for `account` inside this market.
    /// @dev Emits {CollateralUpdated} event.
    ///      May emit {PositionUpdated} event inside Market Manager.
    /// @param account The account posting collateral.
    /// @param shares The amount of shares to post as collateral.
    function _postCollateral(address account, uint256 shares) internal {
        uint256 newNetCollateral = marketCollateralPosted + shares;
        marketManager.canCollateralize(
            address(this),
            account,
            newNetCollateral
        );
        // Update user and market collateral posted invariants.
        collateralPosted[account] = collateralPosted[account] + shares;
        marketCollateralPosted = newNetCollateral;
        emit CollateralUpdated(account, shares, true);
    }

    /// @notice Helper function for removing `shares` collateral posted for
    ///         `account` inside this market.
    /// @dev Emits a {CollateralUpdated} event.
    ///      May emit {PositionUpdated} event inside Market Manager.
    /// @param account The address of the account to reduce `mToken`
    ///                collateral posted for.
    /// @param shares The number of shares that are posted of collateral
    ///               that should be removed.
    function _removeCollateral(address account, uint256 shares) internal {
        // Update user and market collateral posted invariants.
        collateralPosted[account] = collateralPosted[account] - shares;
        marketCollateralPosted = marketCollateralPosted - shares;
        emit CollateralUpdated(account, shares, false);
    }

    /// @notice Processes a deposit of `assets` from the market and mints
    ///         shares to `owner`, then increases `ta` by `assets`,
    ///         and vests rewards if `pending` > 0.
    /// @dev Emits a {Deposit} event.
    /// @param by The account that is executing the deposit.
    /// @param to The account that should receive `shares`.
    /// @param assets The amount of the underlying asset to deposit.
    /// @param shares The amount of shares minted to `to`.
    /// @param ta The current total number of assets for assets to shares
    ///           conversion.
    /// @param pending The current rewards that are pending and will be vested
    ///                during this deposit.
    function _processDeposit(
        address by,
        address to,
        uint256 assets,
        uint256 shares,
        uint256 ta,
        uint256 pending
    ) internal {
        // Need to transfer before minting or ERC777s could reenter.
        SafeTransferLib.safeTransferFrom(asset(), by, address(this), assets);

        // Vests any rewards,if there are any, then update `_totalAssets`
        // invariant and prepare assets for withdrawal.
        _updateAssetsForDeposit(assets, ta, pending);

        // Mint `shares` to `to`.
        // NOTE: This is the erc20 mint function, meaning this is effectively
        //       super._mint().
        _mint(to, shares);

        _afterDepositAction(to, shares);

        /// @solidity memory-safe-assembly
        assembly {
            // Emit the {Deposit} event.
            mstore(0x00, assets)
            mstore(0x20, shares)
            let m := shr(96, not(0))
            log3(0x00, 0x40, _DEPOSIT_EVENT_SIGNATURE, and(m, by), and(m, to))
        }
    }

    /// @notice Processes a withdrawal of `shares` from the market by burning
    ///         `owner` shares and transferring `assets` to `to`, then
    ///         decreases `ta` by `assets`, and vests rewards if
    ///         `pending` > 0.
    /// @dev Emits a {Withdraw} event.
    /// @param by The account that is executing the withdrawal.
    /// @param to The account that should receive `assets`.
    /// @param owner The account that will have `shares` burned to withdraw
    ///              `assets`.
    /// @param assets The amount of the underlying asset to withdraw.
    /// @param shares The amount of shares redeemed from `owner`.
    /// @param ta The current total number of assets for assets to shares
    ///           conversion.
    /// @param pending The current rewards that are pending and will be vested
    ///                during this withdrawal.
    function _processWithdraw(
        address by,
        address to,
        address owner,
        uint256 assets,
        uint256 shares,
        uint256 ta,
        uint256 pending
    ) internal virtual {
        _beforeWithdrawAction(owner, shares);

        // Burn `owner` `shares`.
        _burn(owner, shares);

        // Vests any rewards, if there are any, then update `_totalAssets`.
        // invariant and prepare assets for withdrawal.
        _updateAssetsForWithdrawal(assets, ta, pending);

        // Transfer the underlying assets to `to`.
        SafeTransferLib.safeTransfer(asset(), to, assets);

        /// @solidity memory-safe-assembly
        assembly {
            // Emit the {Withdraw} event.
            mstore(0x00, assets)
            mstore(0x20, shares)
            let m := shr(96, not(0))
            log4(
                0x00,
                0x40,
                _WITHDRAW_EVENT_SIGNATURE,
                and(m, by),
                and(m, to),
                and(m, owner)
            )
        }
    }

    /// @notice Helper function for Position Management contract to
    ///         redeem assets.
    /// @param owner The owner address of assets to redeem.
    /// @param assets The amount of the underlying assets to redeem.
    /// @param shares The amount of the shares to redeem.
    /// @param balancePrior The balance of shares `owner` has before this
    ///                     redemption.
    /// @param deleverageData Struct containing information on the desired
    ///                       deleverage action to execute. Containing values:
    ///                       1. Address of pToken that will be routed into
    ///                          eToken underlying to repay outstanding debt.
    ///                       2. The amount of pTokens that will be
    ///                          deleveraged.
    ///                       3. Address of eToken that will have its underlying
    ///                          token debt repaid.
    ///                       4. Optional struct containing instructions on how
    ///                          to handle swapping into eToken underlying to
    ///                          facilitate deleveraging.
    ///                       5. The amount of underlying tokens that will be
    ///                          repaid to the eToken lenders.
    ///                       6. Optional auxiliary data for execution of a
    ///                          deleverage action.
    function _processPositionManagementRedemption(
        address owner,
        uint256 assets,
        uint256 shares,
        uint256 balancePrior,
        IPositionManagement.DeleverageStruct memory deleverageData
    ) internal virtual {
        // Callback to PositionManagement that executes pToken specific logic.
        IPositionManagement(msg.sender).onRedeem(
            address(this),
            owner,
            assets,
            deleverageData
        );

        // Fails if redemption not allowed.
        uint256 collateralToRemove = marketManager.canRedeemWithCollateralRemoval(
            address(this),
            owner,
            balancePrior,
            collateralPosted[owner],
            shares,
            false
        );

        if (collateralToRemove > 0) {
            _removeCollateral(owner, collateralToRemove);
        }
    }

    /// @notice Helper function to check validity of a proposed posting
    ///         of collateral.
    /// @param owner The address of the account posting `shares`
    ///              as collateral.
    /// @param shares The number of shares to post as collateral from `owner`.
    function _checkPostCollateral(
        address owner,
        uint256 shares
    ) internal view {
        _checkZeroAmount(shares);

        if (collateralPosted[owner] + shares > balanceOf(owner)) {
            _revert(_INSUFFICIENT_SHARES_SELECTOR);
        }
    }

    /// @notice Helper function to check validity of a proposed removal
    ///         of collateral.
    /// @param owner The address of the account removing `shares`
    ///              as collateral.
    /// @param shares The number of shares to remove as collateral
    ///               from `owner`.
    function _checkRemoveCollateral(
        address owner,
        uint256 shares
    ) internal {
        _checkZeroAmount(shares);

        uint256 balanceOfCached = balanceOf(owner);
        uint256 collateralPostedCached = collateralPosted[owner];

        if (collateralPostedCached < shares) {
            revert BasePToken__InsufficientCollateral();
        }

        marketManager.canRedeemWithCollateralRemoval(
            address(this),
            owner,
            balanceOfCached,
            collateralPostedCached,
            shares,
            true
        );
    }

    /// @notice Helper function to prepare for a transfer.
    /// @param from The address of the account transferring `shares`
    ///             shares from.
    /// @param to The address of the destination account to receive `shares`
    ///           shares.
    /// @param shares The number of tokens to transfer from `from` to `to`.
    function _checkTransfer(
        address from,
        address to,
        uint256 shares
    ) internal {
        _checkZeroAmount(shares);
        // Fails if transfer not allowed.
        uint256 collateralToRemove = marketManager.canTransferPToken(
            address(this),
            msg.sender,
            balanceOf(from),
            collateralPosted[from],
            shares
        );

        if (collateralToRemove > 0) {
            _removeCollateral(from, collateralToRemove);
        }
        
        _beforeTransferAction(from, to, shares);
    }

    /// @notice Helper function to efficiently transfers pToken balances
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

    /// @notice Starts a pToken market, executed via marketManager.
    /// @dev This initial mint is a failsafe against rounding exploits,
    ///      although, we protect against them in many ways,
    ///      better safe than sorry.
    /// @dev Emits a {Deposit} event.
    /// @param by The account initializing the pToken market.
    function _startMarket(address by) internal virtual {
        if (msg.sender != address(marketManager)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        uint256 assets = _BASE_UNDERLYING_RESERVE;
        address market = address(this);

        SafeTransferLib.safeTransferFrom(asset(), by, market, assets);

        // Because nobody can deposit into the market before startMarket()
        // is called, this will always be the initial call.
        uint256 shares = _initialConvertToShares(assets);

        _mint(market, shares);
        _totalAssets = assets;

        assembly {
            // Emit the {Deposit} event.
            mstore(0x00, assets)
            mstore(0x20, shares)
            let m := shr(96, not(0))
            log3(
                0x00,
                0x40,
                _DEPOSIT_EVENT_SIGNATURE,
                and(m, market),
                and(m, market)
            )
        }

        _afterDepositAction(market, shares);
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
            : FixedPointMathLib.mulDiv(assets, totalShares, ta);
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
            : FixedPointMathLib.mulDiv(shares, ta, totalShares);
    }

    /// @notice Simulates the effects of a user deposit at the current
    ///         block.
    /// @param assets The number of assets to preview a deposit call.
    /// @param ta The total number of assets to simulate a deposit at the
    ///           current block.
    /// @return The shares received for depositing `assets`.
    function _previewDeposit(
        uint256 assets,
        uint256 ta
    ) internal view returns (uint256) {
        return _convertToShares(assets, ta);
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
            : FixedPointMathLib.mulDivUp(shares, ta, totalShares);
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
            : FixedPointMathLib.mulDivUp(assets, totalShares, ta);
    }

    /// @notice Simulates the effects of a user redemption at the current
    ///         block.
    /// @param shares The number of shares to preview a redemption call.
    /// @param ta The total number of assets to simulate a redemption at the
    ///           current block.
    /// @return The assets received for redeeming `shares`.
    function _previewRedeem(
        uint256 shares,
        uint256 ta
    ) internal view returns (uint256) {
        return _convertToAssets(shares, ta);
    }

    /// @notice Updates asset values for a pending deposit request.
    /// @param assets The amount of the underlying asset to deposit.
    /// @param ta The current total number of assets for assets to shares
    ///           conversion.
    function _updateAssetsForDeposit(
        uint256 assets,
        uint256 ta,
        uint256 /* pending */
    ) internal virtual {
        // Document addition of `assets` to `ta` due to deposit.
        unchecked {
            _totalAssets = ta + assets;
        }
    }

    /// @notice Updates asset values for a pending withdrawal request.
    /// @param assets The amount of the underlying asset to withdraw.
    /// @param ta The current total number of assets for assets to shares
    ///           conversion.
    function _updateAssetsForWithdrawal(
        uint256 assets,
        uint256 ta,
        uint256 /* pending */
    ) internal virtual {
        // Document removal of `assets` from `ta` due to withdrawal.
        _totalAssets = ta - assets;
    }

    /// @notice Returns total assets invariant and any pending rewards for
    ///         depositors.
    /// @return The total assets and pending rewards.
    function _calculateTotalAssetsWithRewards()
        internal
        view
        virtual
        returns (uint256, uint256)
    {
        return (_totalAssets, 0);
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

    /// @notice Checks to make sure an action is not an empty action.
    function _checkZeroAmount(uint256 amount) internal pure {
        if (amount == 0) {
            revert BasePToken__EmptyAction();
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

    /// INTERNAL CONVERSION FUNCTIONS WHICH MAY BE OVERRIDDEN ///

    /// @notice An optional set of instructions to execute before processing
    ///         a deposit of `owners`'s assets.
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
    function _beforeTransferAction(
        address /* from */,
        address /* to */,
        uint256 /* shares */
    ) internal virtual {}

    /// @notice An optional set of instructions to execute before processing
    ///         liquidation of `account`'s collateral.
    function _beforeLiquidationAction(
        address /* account */,
        address /* liquidator */,
        uint256 /* shares */
    ) internal virtual {}
}
