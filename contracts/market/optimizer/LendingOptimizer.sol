// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { ReentrancyGuard } from "contracts/libraries/external/ReentrancyGuard.sol";
import { WAD, BPS } from "contracts/libraries/ConstantsLib.sol";
import { ERC4626 } from "contracts/libraries/external/ERC4626.sol";
import { ERC165 } from "contracts/libraries/external/ERC165.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";


/// @title Curvance Lending Optimizer.
/// @notice Optimizes yield across multiple Curvance lending markets
///         for a single underlying asset.
/// @dev This contract extends ERC4626 with multi-market allocation
///      support, enabling users to deposit a single asset and have it
///      distributed across multiple Curvance lending markets (cTokens)
///      based on configurable allocation caps.
///
///      Deposits can target specific markets or be automatically routed
///      to the optimal market based on projected yield.
///      Withdrawals similarly select the lowest-yielding market to
///      preserve capital in higher-performing markets.
///
///      Yield from underlying cToken markets is absorbed immediately
///      into `_totalAssets` on every accrual (cToken-style). Since
///      `_accrueIfNeeded()` runs before every user action, frontrunning
///      is blocked: depositors earn from block 1 with no temporary loss.
///
///      Performance fees are charged on yield above a high watermark,
///      ensuring fees are only taken on new all-time-high profits. This
///      prevents double-charging after drawdowns recover.
///
///      Shares represent proportional ownership of total assets across
///      all markets. The exchange rate is calculated as:
///      `(totalAssets * WAD) / totalSupply`.
///
///      Allocation caps (stored internally in WAD, configured in BPS)
///      define the maximum percentage each market can hold. The sum of
///      all caps must be >= 100% to ensure
///      full allocation is possible. Authorized harvesters can rebalance
///      assets across markets while respecting these caps.
///
///      Dead shares minted to address(0) on initialization prevent
///      inflation attacks. All state-changing functions have reentrancy
///      protection.
contract LendingOptimizer is ERC4626, ReentrancyGuard, ERC165 {

    /// TYPES ///

    /// @notice Represents a single reallocation operation for moving assets between markets.
    /// @dev Used in rebalance() and removeApprovedAsset(). In rebalance(),
    ///      positive values indicate deposits and negative values indicate
    ///      withdrawals. In removeApprovedAsset(), values represent BPS
    ///      percentages (1-10000) that must sum to exactly 10000.
    struct ReallocationAction {
        /// @notice The cToken market to interact with.
        IBorrowableCToken cToken;
        /// @notice In rebalance(): the amount of underlying assets to deposit
        ///         (positive) or withdraw (negative).
        ///         In removeApprovedAsset(): the BPS percentage of redeemed assets.
        int256 assetsOrBps;
    }

    /// CONSTANTS ///

    /// @dev Maximum fee in BPS (50% = 5000 BPS).
    uint256 public constant MAX_FEE_BPS = 5000;
    /// @dev Maximum number of supported markets.
    uint256 public constant MAX_MARKETS = 8;
    /// @dev Minimum allowed value for ReallocationAction.assetsOrBps (withdrawals).
    ///      Caps at negative int128 range to prevent negation overflow on int256.
    int256 public constant MIN_REALLOCATION_AMOUNT = -type(int128).max;
    /// @dev The base underlying asset requirement held in order to minimize
    ///      rounding exploits, and more generally, invariant manipulation.
    uint256 internal constant _BASE_UNDERLYING_RESERVE = 77777;

    /// STORAGE ///

    /// @notice The underlying asset address.
    IERC20 public immutable _asset;
    /// @notice Token name for the optimizer shares.
    string internal _name;
    /// @notice Token symbol for the optimizer shares.
    string internal _symbol;
    /// @notice Underlying token decimals.
    uint8 internal immutable _decimals;
    /// @notice List of approved cTokens for allocation.
    address[] public approvedCTokensList;
    /// @notice Allocation cap per cToken in WAD (1e18 = 100%).
    mapping(address => uint256) public allocationCaps;
    /// @notice Performance fee in BPS.
    uint256 public fee;
    /// @notice Highest exchange rate ever achieved (for fee calculation).
    uint256 public exchangeRateHighWatermark;
    /// @notice Last recognized total assets.
    uint256 internal _totalAssets;
    /// @notice Whether deposits are enabled.
    /// @dev 0 = uninitialized; 1 = active; 2 = paused.
    uint8 public mintPaused;
    /// @notice Central registry for permissions and market manager lookups.
    ICentralRegistry public immutable centralRegistry;
    
    /// EVENTS ///

    event MarketAdded(address indexed cToken, uint256 allocationCap);
    event MarketRemoved(address indexed cToken);
    event AllocationCapUpdated(address indexed cToken, uint256 newCap);
    event FeeUpdated(uint256 newFee);
    event Rebalanced(uint256 totalAssets, address[] markets, uint256[] allocations);
    event PerformanceFeeAccrued(uint256 feeShares, address indexed recipient);
    event ActionPaused(string action, bool state);

    /// ERRORS ///

    error LendingOptimizer__Unauthorized();
    error LendingOptimizer__InvalidParameter();
    error LendingOptimizer__TooManyMarkets();
    error LendingOptimizer__ArrayLengthMismatch();
    error LendingOptimizer__InvalidUnderlying();
    error LendingOptimizer__InvalidMarketManager();
    error LendingOptimizer__InsufficientAllocationCaps();
    error LendingOptimizer__MarketNotApproved();
    error LendingOptimizer__MarketAlreadyApproved();
    error LendingOptimizer__AllocationExceedsCap();
    error LendingOptimizer__AssetMismatch();
    error LendingOptimizer__FeeTooHigh();
    error LendingOptimizer__InsufficientLiquidity();
    error LendingOptimizer__NotInitialized();
    error LendingOptimizer__AlreadyInitialized();
    error LendingOptimizer__MintPaused();
    error LendingOptimizer__MarketPaused();

    /// CONSTRUCTOR ///

    /// @notice Deploys a new LendingOptimizer for a single underlying asset.
    /// @dev Performs four categories of setup:
    ///      1. Validation -- enforces array bounds, length parity, fee ceiling,
    ///         per-market cap range (0 < cap <= 100%), no duplicates, correct
    ///         underlying asset, and registered market manager for each cToken.
    ///      2. ERC20 metadata -- derives the share token name/symbol/decimals
    ///         from the underlying asset.
    ///      3. Market registration -- converts each allocation cap from BPS to
    ///         WAD and stores the approved cToken list. Reverts if total caps
    ///         sum to less than 100%.
    ///      4. Fee initialization -- stores the performance fee in BPS and sets
    ///         the high watermark to WAD (1:1 exchange rate).
    ///
    ///      After construction the optimizer is NOT yet active; `initializeDeposits()`
    ///      must be called to mint dead shares and enable deposits.
    /// @param asset_ The underlying ERC20 asset (e.g. USDC).
    /// @param _centralRegistry Protocol registry for permissions and market manager lookups.
    /// @param _approvedCTokens Initial set of Curvance cToken markets (max 8).
    /// @param _allocationCapsBps Per-market allocation caps in BPS (1-10000). Must sum >= 10000.
    /// @param _feeBps Performance fee in BPS charged on yield above the high watermark (max 5000).
    constructor(
        IERC20 asset_,
        ICentralRegistry _centralRegistry,
        address[] memory _approvedCTokens,
        uint256[] memory _allocationCapsBps,
        uint256 _feeBps
    ) {
        // Revert if trying to add more than `MAX_MARKETS`.
        if (_approvedCTokens.length > MAX_MARKETS) revert LendingOptimizer__TooManyMarkets();
        if (_approvedCTokens.length == 0) revert LendingOptimizer__InvalidParameter();
        // Revert if constructor's arrays mismatch in length.
        if (_approvedCTokens.length != _allocationCapsBps.length) revert LendingOptimizer__ArrayLengthMismatch();
        // Revert if the performance fee is more than the allowed max.
        if (_feeBps > MAX_FEE_BPS) revert LendingOptimizer__FeeTooHigh();

        // Set essential storage slots.
        centralRegistry = _centralRegistry;
        _asset = asset_;
        _name = string.concat("Curvance ", asset_.name(), " Optimizer");
        _symbol = string.concat("c", asset_.symbol(), "+");
        _decimals = asset_.decimals();
        // Store fee as BPS.
        fee = _feeBps;

        // Counter to find the sum of all allocation amounts.
        uint256 totalAllocation;

        // Loop through all cTokens and validate.
        for (uint256 i; i < _approvedCTokens.length; ++i) {
            // Revert if allocation cap is 0 which would cause a dead market,
            // and also prevent allocating cap > 100% to cause dirty allocation math.
            if (_allocationCapsBps[i] == 0 || _allocationCapsBps[i] > BPS)
                    revert LendingOptimizer__InvalidParameter();

            address cToken = _approvedCTokens[i];

            // Revert if the cToken has already been added (duplicate check).
            if (allocationCaps[cToken] != 0) revert LendingOptimizer__MarketAlreadyApproved();

            // Validate the cToken's underlying and market manager.
            _validateCToken(cToken);

            // Convert cap from BPS to WAD.
            uint256 alloCapWAD = _bpsToWad(_allocationCapsBps[i]);
            // Store cap into allocation cap mapping.
            allocationCaps[cToken] = alloCapWAD;
            // Add alloCapWAD to the totalAllocation counter.
            totalAllocation += alloCapWAD;
        }

        // Revert if the totalAllocation is less than 100% (WAD).
        if (totalAllocation < WAD) revert LendingOptimizer__InsufficientAllocationCaps();

        // Store the provided cToken list.
        approvedCTokensList = _approvedCTokens;
        // Store the high watermark exchange rate as 100% (WAD).
        exchangeRateHighWatermark = WAD;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Initializes the optimizer with dead shares to prevent inflation attacks.
    /// @dev This initial mint is a failsafe against rounding exploits.
    ///      Must be called before any deposits can be made.
    /// @param targetMarket The index of the market to deposit initial assets into.
    function initializeDeposits(
        uint256 targetMarket
    ) external nonReentrant {
        // Revert if the caller does not have market permissions.
        _hasMarketPermissions();

        // Revert if the market has already been initialized.
        if (mintPaused != 0) revert LendingOptimizer__AlreadyInitialized();
        // Array length sanity check.
        if (targetMarket >= approvedCTokensList.length) revert LendingOptimizer__MarketNotApproved();

        // Transfer _BASE_UNDERLYING_RESERVE assets.
        uint256 assets = _BASE_UNDERLYING_RESERVE;
        SafeTransferLib.safeTransferFrom(address(_asset), msg.sender, address(this), assets);

        // Deposit into target market.
        uint256 trackedAssets = _depositToMarket(approvedCTokensList[targetMarket], assets);

        // Update _totalAssets with the actual recoverable value.
        _totalAssets += trackedAssets;

        // Mint dead shares equal to actual tracked assets.
        // We use trackedAssets (returned by _depositToMarket) rather than input assets
        // because cToken share rounding may cause the recoverable value to differ
        // slightly from the input. This ensures the initial exchange rate is exactly 1:1.
        _mint(address(0), trackedAssets);

        // Set mintPaused to 1 to indicate deposits are active.
        mintPaused = 1;

        emit Deposit(msg.sender, address(0), assets, trackedAssets);
    }

    /// @notice Standard ERC4626 deposit - deposits into optimal market.
    /// @dev Shares are derived from the actual recoverable value (trackedAssets)
    ///      via convertToShares, which rounds down -- favoring the vault.
    /// @param assets The amount of underlying assets to deposit.
    /// @param receiver The address to receive the minted shares.
    /// @return shares The amount of shares minted.
    function deposit(
        uint256 assets,
        address receiver
    ) public override nonReentrant returns (uint256 shares) {
        _checkMintPaused();
        _accrueIfNeeded();
        // _optimalTarget(assets, true) true == deposit.
        shares = _deposit(assets, receiver, approvedCTokensList[_optimalTarget(assets, true)]);
    }

    /// @notice Deposits assets into a specific market and mints shares to receiver.
    /// @dev Shares are derived from the actual recoverable value (trackedAssets)
    ///      via convertToShares, which rounds down -- favoring the vault.
    /// @param assets The amount of underlying assets to deposit.
    /// @param receiver The address to receive the minted shares.
    /// @param targetMarket The address of the target cToken market to deposit into.
    /// @return shares The amount of shares minted.
    function deposit(
        uint256 assets,
        address receiver,
        address targetMarket
    ) external nonReentrant returns (uint256 shares) {
        _checkMintPaused();
        _validateTargetMarket(targetMarket, true);
        _accrueIfNeeded();
        shares = _deposit(assets, receiver, targetMarket);
    }

    /// @notice Standard ERC4626 mint - mints exact shares by depositing
    ///         into the optimal market.
    /// @param shares The exact amount of shares to mint.
    /// @param receiver The address to receive the minted shares.
    /// @return assets The amount of assets deposited.
    function mint(
        uint256 shares,
        address receiver
    ) public override nonReentrant returns (uint256 assets) {
        _checkMintPaused();
        _accrueIfNeeded();
        // _optimalTarget(previewMint(shares), true) true == deposit.
        assets = _mintShares(shares, receiver, approvedCTokensList[_optimalTarget(previewMint(shares), true)]);
    }

    /// @notice Mints exact shares by depositing into a specific market.
    /// @dev Uses previewMint (rounds up) to compute the asset cost, ensuring
    ///      the vault never under-charges. Mints exactly `shares` shares
    ///      regardless of cToken rounding; any rounding dust is absorbed
    ///      by the vault as a tiny surplus.
    /// @param shares The exact amount of shares to mint.
    /// @param receiver The address to receive the minted shares.
    /// @param targetMarket The address of the target cToken market to deposit into.
    /// @return assets The amount of assets deposited.
    function mint(
        uint256 shares,
        address receiver,
        address targetMarket
    ) external nonReentrant returns (uint256 assets) {
        _checkMintPaused();
        _validateTargetMarket(targetMarket, true);
        _accrueIfNeeded();
        assets = _mintShares(shares, receiver, targetMarket);
    }

    /// @notice Standard ERC4626 withdraw - withdraws from optimal market.
    /// @param assets The amount of underlying assets to withdraw.
    /// @param receiver The address to receive the withdrawn assets.
    /// @param owner The address that owns the shares being burned.
    /// @return shares The amount of shares burned.
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override nonReentrant returns (uint256 shares) {
        _accrueIfNeeded();

        shares = previewWithdraw(assets);
        _withdraw(
            assets,
            shares,
            receiver,
            owner,
            approvedCTokensList[_optimalTarget(assets, false)]
        );
    }

    /// @notice Withdraws assets from a specific market.
    /// @param assets The amount of underlying assets to withdraw.
    /// @param receiver The address to receive the withdrawn assets.
    /// @param owner The address that owns the shares being burned.
    /// @param targetMarket The address of the target cToken market to withdraw from.
    /// @return shares The amount of shares burned.
    function withdraw(
        uint256 assets,
        address receiver,
        address owner,
        address targetMarket
    ) external nonReentrant returns (uint256 shares) {
        _validateTargetMarket(targetMarket, false);
        _accrueIfNeeded();

        shares = previewWithdraw(assets);
        _withdraw(assets, shares, receiver, owner, targetMarket);
    }

    /// @notice Standard ERC4626 redeem - redeems from optimal market.
    /// @param shares The amount of shares to redeem.
    /// @param receiver The address to receive the underlying assets.
    /// @param owner The address that owns the shares being burned.
    /// @return assets The amount of assets withdrawn.
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override nonReentrant returns (uint256 assets) {
        _accrueIfNeeded();

        assets = previewRedeem(shares);
        _withdraw(
            assets,
            shares,
            receiver,
            owner,
            approvedCTokensList[_optimalTarget(assets, false)]
        );
    }

    /// @notice Redeems shares from a specific market.
    /// @param shares The amount of shares to redeem.
    /// @param receiver The address to receive the underlying assets.
    /// @param owner The address that owns the shares being burned.
    /// @param targetMarket The address of the target cToken market to withdraw from.
    /// @return assets The amount of assets withdrawn.
    function redeem(
        uint256 shares,
        address receiver,
        address owner,
        address targetMarket
    ) external nonReentrant returns (uint256 assets) {
        _validateTargetMarket(targetMarket, false);
        _accrueIfNeeded();

        assets = previewRedeem(shares);
        _withdraw(assets, shares, receiver, owner, targetMarket);
    }

    /// @notice Rebalances assets across approved markets.
    /// @dev Requires harvester permissions. Actions are processed in two passes:
    ///      withdrawals first, then deposits. This ensures sufficient liquidity
    ///      for deposits without requiring external capital.
    ///
    ///      The actions array must:
    ///      1. Have exactly `approvedCTokensList.length` elements.
    ///      2. Match the order of `approvedCTokensList` (actions[i].cToken must
    ///         equal approvedCTokensList[i]).
    ///      3. Include an entry for every market, even if no action is needed
    ///         (use assets=0 for no-op).
    ///      4. Have total withdrawal amounts equal to total deposit amounts.
    ///
    ///      Positive `assets` values indicate deposits, negative values indicate
    ///      withdrawals.
    ///
    ///      After rebalancing, each market's allocation must not exceed its cap.
    ///      NOTE: cToken deposit/withdraw rounding incurs a small asset loss
    ///      (~1-2 wei per action). This is absorbed on the next accrual.
    /// @param actions Array of reallocation actions, one per approved market.
    function rebalance(ReallocationAction[] calldata actions) external nonReentrant {
        // Revert if the caller does not have harvester permissions.
        _hasHarvesterPermissions();

        // Accrue yield and charge protocol's performance fee.
        _accrueIfNeeded();

        // Cache approved markets length.
        uint256 l = approvedCTokensList.length;
        // Revert if the actions array length does not match approved markets.
        if (actions.length != l) revert LendingOptimizer__ArrayLengthMismatch();

        uint256 sumDeclaredWithdrawals;
        // First pass: process withdrawals (negative assets).
        for (uint256 i; i < l; ++i) {
            // Revert if action cToken does not match expected market at index.
            if (address(actions[i].cToken) != approvedCTokensList[i]) revert LendingOptimizer__InvalidParameter();

            // Process withdrawal if assets is negative.
            if (actions[i].assetsOrBps < 0) {
                if (actions[i].assetsOrBps < MIN_REALLOCATION_AMOUNT) revert LendingOptimizer__InvalidParameter();
                if (_isMarketPausedForAction(address(actions[i].cToken), false)) {
                    revert LendingOptimizer__MarketPaused();
                }
                uint256 withdrawAmount = uint256(-actions[i].assetsOrBps);
                sumDeclaredWithdrawals += withdrawAmount;
                actions[i].cToken.withdraw(
                    withdrawAmount,
                    address(this),
                    address(this)
                );
            }
        }

        // Track the intended deposited assets.
        uint256 sumDeclaredReallocated;
        // Second pass: process deposits (positive assets).
        for (uint256 i; i < l; ++i) {
            // Process deposit if assets is positive.
            if (actions[i].assetsOrBps > 0) {
                if (_isMarketPausedForAction(address(actions[i].cToken), true)) {
                    revert LendingOptimizer__MarketPaused();
                }
                uint256 depositAmount = uint256(actions[i].assetsOrBps);
                _depositToMarket(address(actions[i].cToken), depositAmount);
                sumDeclaredReallocated += depositAmount;
            }
        }

        // Check that the manager intended to withdraw and deposit the same amount of assets.
        if (sumDeclaredWithdrawals != sumDeclaredReallocated) revert LendingOptimizer__AssetMismatch();

        // Verify allocation caps and emit post-rebalance state.
        _verifyAllocationCaps();
    }

    /// @notice Removes an approved market and reallocates its assets.
    /// @dev After removal, remaining market caps must sum to >= 100%. If not,
    ///      call `updateCap()` to increase a remaining market's cap before removal.
    ///      The caller specifies BPS-based percentages for redistribution
    ///      via the `assets` field of each ReallocationAction. BPS values
    ///      must be positive and sum to exactly 10000 (100%).
    ///      The last target receives the remainder to avoid dust.
    /// @param cTokenToRemove Address of the market to remove.
    /// @param removeActions Reallocation targets. `assets` field is BPS (1-10000).
    function removeApprovedAsset(
        address cTokenToRemove,
        ReallocationAction[] calldata removeActions
    ) external nonReentrant {
        // Revert if the caller does not have market permissions.
        _hasMarketPermissions();

        // Revert if no reallocation targets are provided.
        if (removeActions.length == 0) revert LendingOptimizer__InvalidParameter();

        // Revert if there is only one market.
        uint256 l = approvedCTokensList.length;
        if (l == 1) revert LendingOptimizer__InvalidParameter();

        // Revert if the market to remove is not approved.
        if (!_isApprovedMarket(cTokenToRemove)) revert LendingOptimizer__MarketNotApproved();

        // Validate remaining allocation caps sum to >= 100%.
        _validateAllocationCaps(cTokenToRemove, 0);

        // Accrue yield and charge protocol's performance fee.
        _accrueIfNeeded();

        IBorrowableCToken cToken = IBorrowableCToken(cTokenToRemove);

        // Redeem all shares from the market being removed.
        uint256 assetsRedeemed = cToken.redeem(
            cToken.balanceOf(address(this)),
            address(this),
            address(this)
        );

        // Delete the allocation cap for the removed market.
        delete allocationCaps[cTokenToRemove];

        // Distribute redeemed assets proportionally via BPS.
        uint256 totalBps;
        uint256 totalDeposited;
        uint256 lastAction = removeActions.length - 1;

        for (uint256 i; i <= lastAction; ++i) {
            address cTokenAddress = address(removeActions[i].cToken);
            int256 bps = removeActions[i].assetsOrBps;

            // Revert if BPS is not positive.
            if (bps <= 0) revert LendingOptimizer__InvalidParameter();
            // Revert if target is the market being removed.
            if (cTokenAddress == cTokenToRemove) revert LendingOptimizer__InvalidParameter();
            // Revert if the reallocation target is not an approved market.
            if (!_isApprovedMarket(cTokenAddress)) revert LendingOptimizer__MarketNotApproved();

            totalBps += uint256(bps);

            // Last target receives the remainder to avoid dust.
            // Else deposit normally.
            uint256 depositAmount;
            if (i == lastAction) {
                depositAmount = assetsRedeemed - totalDeposited;
            } else {
                depositAmount = FixedPointMathLib.mulDiv(assetsRedeemed, uint256(bps), BPS);
                totalDeposited += depositAmount;
            }

            _depositToMarket(cTokenAddress, depositAmount);
        }

        // Revert if BPS values do not sum to exactly 100%.
        if (totalBps != BPS) revert LendingOptimizer__InvalidParameter();

        // Find the index of the cToken to remove.
        uint256 removeIndex;
        for (uint256 i; i < l; ++i) {
            if (approvedCTokensList[i] == cTokenToRemove) {
                removeIndex = i;
                break;
            }
        }

        // Update approved markets list using swap and pop.
        uint256 swapIndex = l - 1;
        if (removeIndex != swapIndex) {
            approvedCTokensList[removeIndex] = approvedCTokensList[swapIndex];
        }
        approvedCTokensList.pop();

        // Verify allocation caps are respected after reallocation.
        _verifyAllocationCaps();

        emit MarketRemoved(cTokenToRemove);
    }

    /// @notice Adds a new approved market for allocation.
    /// @dev Requires market permissions. The cToken must have matching
    ///      underlying asset and a registered market manager. Max 6 markets.
    /// @param newAsset Address of the cToken market to add.
    /// @param capBps Allocation cap in BPS. Stored as WAD internally.
    function addApprovedAsset(address newAsset, uint256 capBps) external nonReentrant {
        // Revert if the caller does not have market permissions.
        _hasMarketPermissions();

        // Revert if the new asset address is zero.
        if (newAsset == address(0)) revert LendingOptimizer__InvalidParameter();
        // Revert if the cap is zero or exceeds 100%.
        if (capBps == 0 || capBps > BPS) revert LendingOptimizer__InvalidParameter();
        // Revert if the market is already approved.
        if (_isApprovedMarket(newAsset)) revert LendingOptimizer__MarketAlreadyApproved();
        // Revert if adding would exceed maximum markets.
        if (approvedCTokensList.length >= MAX_MARKETS) revert LendingOptimizer__TooManyMarkets();

        // Validate the cToken's underlying and market manager.
        _validateCToken(newAsset);

        // Add market to approved list and set allocation cap.
        uint256 capWad = _bpsToWad(capBps);
        approvedCTokensList.push(newAsset);
        allocationCaps[newAsset] = capWad;

        emit MarketAdded(newAsset, capWad);
    }

    /// @notice Updates the allocation cap for an approved market.
    /// @dev Requires market permissions. If decreasing, validates total
    ///      caps remain >= 100% to ensure full allocation is possible.
    /// @param cToken Address of the cToken market (must be approved).
    /// @param newCapBps New allocation cap in BPS (1-10000).
    function updateCap(address cToken, uint256 newCapBps) external nonReentrant {
        // Revert if the caller does not have market permissions.
        _hasMarketPermissions();

        // Revert if the market is not approved.
        if (!_isApprovedMarket(cToken)) revert LendingOptimizer__MarketNotApproved();
        // Revert if the new cap is zero or exceeds 100%.
        if (newCapBps > BPS || newCapBps == 0) revert LendingOptimizer__InvalidParameter();

        uint256 newCapWad = _bpsToWad(newCapBps);

        // If decreasing cap, validate total caps still >= 100%.
        if (newCapWad < allocationCaps[cToken]) {
            _validateAllocationCaps(cToken, newCapWad);
        }

        // Update the allocation cap.
        allocationCaps[cToken] = newCapWad;

        emit AllocationCapUpdated(cToken, newCapWad);
    }

    /// @notice Updates the performance fee charged on yield above watermark.
    /// @dev Requires market permissions. Accrues existing fees before updating.
    ///      If enabling from 0, watermark resets to current rate so fees only
    ///      apply to future yield. Max 50%.
    /// @param newFeeBps New fee in BPS.
    function setFee(uint256 newFeeBps) external nonReentrant {
        // Revert if the caller does not have market permissions.
        _hasMarketPermissions();

        // Revert if the new fee exceeds the maximum allowed (50%).
        if (newFeeBps > MAX_FEE_BPS) revert LendingOptimizer__FeeTooHigh();

        // Accrue fees on existing profits before changing fee.
        _accrueIfNeeded();

        // If enabling fees from 0, update watermark to current rate
        // so fees only apply to future yield.
        if (fee == 0 && newFeeBps > 0) {
            if (totalSupply() > 0) {
                uint256 exchangeRateCurrent = _exchangeRate();
                // Never lower the watermark.
                if (exchangeRateCurrent > exchangeRateHighWatermark) {
                    exchangeRateHighWatermark = exchangeRateCurrent;
                }
            }
        }

        fee = newFeeBps;
        emit FeeUpdated(newFeeBps);
    }

    /// @notice Pauses or unpauses deposits. Emits an {ActionPaused} event.
    /// @dev Requires market permissions.
    /// @param state True to pause, false to unpause.
    function setMintPaused(bool state) external nonReentrant {
        _hasMarketPermissions();

        // Cannot pause or unpause if not initialized.
        if (mintPaused == 0) revert LendingOptimizer__NotInitialized();

        mintPaused = state ? 2 : 1; // 2 = paused; 1 = active.

        emit ActionPaused("Mint Paused", state);
    }

    /// @notice Accrues interest, absorbs yield, charges fees, and returns exchange rate.
    /// @dev Triggers full state update: accrues underlying markets, absorbs
    ///      yield, and charges performance fees if rate exceeds watermark.
    /// @return Current exchange rate in WAD (1e18 = 1:1). Returns WAD if no supply.
    function exchangeRateUpdated() public nonReentrant returns (uint256) {
        if (totalSupply() == 0) return WAD;

        // Accrue yield from underlying markets and vest new yield.
        // Note: _accrueIfNeeded() may mint fee shares, so we must use
        // totalSupply() after accrual, not a cached value.
        _accrueIfNeeded();

        return _exchangeRate();
    }

    /// @notice Accrues yield from underlying markets and absorbs it.
    function accrueIfNeeded() external nonReentrant {
        _accrueIfNeeded();
    }

    /// VIEW FUNCTIONS ///

    /// @notice Returns total assets held across all approved markets.
    /// @dev Unlike totalAssetsUpdated(), this does not trigger interest accrual.
    ///      The returned value may be slightly stale if markets haven't been
    ///      accrued recently.
    /// @return The total assets held by the optimizer across all markets.
    function totalAssets() public view override returns (uint256) {
        return _totalAssets;
    }

    /// @notice Returns a conservative share estimate for a given deposit.
    /// @dev Rounds down by 1 share to account for the cToken deposit
    ///      round-trip (assets → cTokenShares → trackedAssets) losing
    ///      up to 1 wei of recoverable value. This ensures
    ///      `deposit() >= previewDeposit()` per ERC4626 when the caller
    ///      accrues state beforehand. Integrators should call
    ///      `accrueIfNeeded()` before `previewDeposit()` in the same
    ///      transaction for maximum accuracy.
    function previewDeposit(uint256 assets) public view override returns (uint256 shares) {
        shares = convertToShares(assets);
        shares = shares == 0 ? 0 : shares - 1;
    }

    /// @notice Returns 0 when deposits are paused or uninitialized.
    function maxDeposit(address) public view override returns (uint256) {
        return mintPaused == 1 ? type(uint256).max : 0;
    }

    /// @notice Returns 0 when deposits are paused or uninitialized.
    function maxMint(address) public view override returns (uint256) {
        return mintPaused == 1 ? type(uint256).max : 0;
    }

    /// @notice Returns the maximum amount of assets that can be withdrawn from `owner`.
    function maxWithdraw(address owner) public view override returns (uint256) {
        return convertToAssets(balanceOf(owner));
    }

    /// @notice Returns the maximum amount of shares that can be redeemed from `owner`.
    function maxRedeem(address owner) public view override returns (uint256) {
        return balanceOf(owner);
    }

    /// @notice Returns current exchange rate (view function).
    /// @dev Unlike exchangeRateUpdated(), this does not trigger interest accrual.
    ///      The returned rate may be slightly stale if markets haven't been
    ///      accrued recently.
    /// @return The current exchange rate in WAD (1e18 = 1:1 ratio).
    function exchangeRate() public view nonReadReentrant returns (uint256) {
        return _exchangeRate();
    }

    /// @notice Returns the number of approved markets.
    function numApprovedMarkets() external view returns (uint256) {
        return approvedCTokensList.length;
    }

    /// @notice Returns all approved market addresses.
    function getApprovedMarkets() external view returns (address[] memory) {
        return approvedCTokensList;
    }

    /// @notice Returns the name of the token.
    function name() public view override returns (string memory) {
        return _name;
    }

    /// @notice Returns the symbol of the token.
    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /// @notice Returns the underlying asset address.
    function asset() public view override returns (address) {
        return address(_asset);
    }

    /// @notice Returns true if this contract implements the interface.
    /// @param interfaceId The interface identifier to check.
    /// @return result True if the interface is supported.
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool result) {
        result = interfaceId == type(ERC4626).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// INTERNAL FUNCTIONS ///

    /// @dev Selects the best market index for a deposit or withdrawal
    ///      by projecting each market's supply rate after the action.
    ///
    ///      DEPOSITS  – Every market is a candidate. The market whose IRM
    ///                   projects the **highest** supply rate after the
    ///                   deposit wins (routes capital where yield is best).
    ///
    ///      WITHDRAWALS – A market is viable when (a) this optimizer holds
    ///                    enough cToken shares AND (b) the market has enough
    ///                    idle liquidity. Among viable markets the one that
    ///                    projects the **lowest** supply rate wins, draining
    ///                    the weakest performer first.
    ///                    Reverts if no market qualifies.
    ///
    /// @param assets  Amount of underlying assets to deposit or withdraw.
    /// @param isDeposit  `true` for a deposit, `false` for a withdrawal.
    /// @return targetIndex  Index into `approvedCTokensList` of the chosen market.
    function _optimalTarget(uint256 assets, bool isDeposit) internal view returns (uint256 targetIndex) {
        uint256 l = approvedCTokensList.length;

        if (l == 0) revert LendingOptimizer__MarketNotApproved();

        uint256 optimalRate = isDeposit ? 0 : type(uint256).max;
        bool foundViable;

        for (uint256 i; i < l; ++i) {
            address cTokenAddr = approvedCTokensList[i];

            // Skip markets paused for this action type.
            if (_isMarketPausedForAction(cTokenAddr, isDeposit)) continue;

            IBorrowableCToken cToken = IBorrowableCToken(cTokenAddr);
            uint256 assetsHeld = cToken.assetsHeld();

            // Withdrawals require sufficient balance and idle liquidity.
            if (!isDeposit) {
                if (_getMarketAssets(cTokenAddr) < assets || assetsHeld < assets) continue;
            }

            uint256 projectedRate = cToken.IRM().supplyRate(
                isDeposit ? assetsHeld + assets : assetsHeld - assets,
                cToken.marketOutstandingDebt(),
                cToken.interestFee()
            );

            if (isDeposit ? (!foundViable || projectedRate > optimalRate) : projectedRate < optimalRate) {
                foundViable = true;
                optimalRate = projectedRate;
                targetIndex = i;
            }
        }

        if (!foundViable) {
            if (isDeposit) revert LendingOptimizer__MarketPaused();
            revert LendingOptimizer__InsufficientLiquidity();
        }
    }

    /// @dev Validates that `market` is approved and not paused for the given action.
    ///      Reverts if market is not approved or is paused.
    function _validateTargetMarket(address market, bool isDeposit) internal view {
        if (!_isApprovedMarket(market)) revert LendingOptimizer__MarketNotApproved();
        if (_isMarketPausedForAction(market, isDeposit)) revert LendingOptimizer__MarketPaused();
    }

    /// @dev Returns true if the market is paused for the given action.
    ///      Deposits check per-cToken `mintPaused` via the market manager;
    ///      withdrawals check market-wide `redeemPaused`.
    function _isMarketPausedForAction(
        address cToken,
        bool isDeposit
    ) internal view returns (bool) {
        MarketManagerIsolated mm =
            MarketManagerIsolated(address(IBorrowableCToken(cToken).marketManager()));
        if (isDeposit) {
            (bool mintPaused_,,) = mm.actionsPaused(cToken);
            return mintPaused_;
        } else {
            return mm.redeemPaused() == 2;
        }
    }

    /// @dev Accrues interest on all markets and returns total assets.
    function _accrueMarkets() internal returns (uint256 ta) {
        uint256 l = approvedCTokensList.length;
        for (uint256 i; i < l; ++i) {
            address cToken = approvedCTokensList[i];
            IBorrowableCToken(cToken).accrueIfNeeded();
            ta += _getMarketAssets(cToken);
        }
    }

    /// @dev Deposits assets into a specific cToken market.
    /// @param cToken The cToken market to deposit into.
    /// @param assets The amount of assets to deposit.
    /// @return trackedAssets The actual recoverable value (for _totalAssets tracking).
    function _depositToMarket(
        address cToken,
        uint256 assets
    ) internal returns (uint256 trackedAssets) {
        SwapperLib._approveIfNeeded(address(_asset), cToken, assets);

        IBorrowableCToken cToken_ = IBorrowableCToken(cToken);

        // Track the actual recoverable value of shares received, not the input amount.
        // cToken share math involves two rounding operations (assets→shares, shares→assets)
        // which can cause a 1 wei difference between input and recoverable value.
        // Using convertToAssets ensures _totalAssets stays in sync with what
        // _accrueMarkets() reports.
        trackedAssets = cToken_.convertToAssets(cToken_.deposit(assets, address(this)));

        // Remove any residual approval for USDT-like token compatibility.
        SwapperLib._removeApprovalIfNeeded(address(_asset), cToken);
    }

    /// @dev Transfers assets from the caller and deposits them into a cToken market.
    ///
    ///      IMPORTANT: Does NOT update `_totalAssets`. The deposit() and mint()
    ///      functions that call this helper must increment
    ///      `_totalAssets += trackedAssets` themselves. This separation exists
    ///      because deposit() must call convertToShares() with the pre-deposit
    ///      totalAssets (before the increment), while mint() skips that
    ///      calculation entirely and mints exact shares.
    ///
    /// @param assets The amount of underlying assets to transfer and deposit.
    /// @param targetMarket The target cToken market to deposit into.
    /// @return trackedAssets The actual recoverable value after cToken rounding.
    ///         May be up to 1 wei less than `assets` due to cToken share math.
    function _pullAndDeposit(
        uint256 assets,
        address targetMarket
    ) internal returns (uint256 trackedAssets) {
        SafeTransferLib.safeTransferFrom(address(_asset), msg.sender, address(this), assets);
        trackedAssets = _depositToMarket(targetMarket, assets);
    }

    /// @dev Core deposit logic shared by deposit() variants.
    ///      Shares are derived from the actual recoverable value (trackedAssets)
    ///      via convertToShares, which rounds down -- favoring the vault.
    function _deposit(
        uint256 assets,
        address receiver,
        address targetMarket
    ) internal returns (uint256 shares) {
        uint256 trackedAssets = _pullAndDeposit(assets, targetMarket);
        // Calculate shares from trackedAssets BEFORE updating _totalAssets,
        // so convertToShares uses the pre-deposit totalAssets denominator.
        shares = convertToShares(trackedAssets);
        if (shares == 0) revert LendingOptimizer__InvalidParameter();

        _totalAssets += trackedAssets;
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @dev Core mint logic shared by mint() variants.
    ///      Uses previewMint (rounds up) to compute the asset cost, ensuring
    ///      the vault never under-charges. Mints exactly `shares` shares
    ///      regardless of cToken rounding; any rounding dust is absorbed
    ///      by the vault as a tiny surplus.
    function _mintShares(
        uint256 shares,
        address receiver,
        address targetMarket
    ) internal returns (uint256 assets) {
        // Round up: user pays ceiling amount of assets for the requested shares.
        assets = previewMint(shares);
        _totalAssets += _pullAndDeposit(assets, targetMarket);
        // Mint exact requested shares (not derived from trackedAssets).
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @dev Core withdraw logic shared by withdraw() and redeem() variants.
    /// @param assets The amount of assets to withdraw.
    /// @param shares The amount of shares to burn.
    /// @param receiver The address to receive the withdrawn assets.
    /// @param owner The address that owns the shares being burned.
    /// @param targetMarket The target cToken market to withdraw from.
    function _withdraw(
        uint256 assets,
        uint256 shares,
        address receiver,
        address owner,
        address targetMarket
    ) internal {
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);
        _burn(owner, shares);
        _totalAssets -= assets;
        IBorrowableCToken(targetMarket).withdraw(assets, address(this), address(this));
        SafeTransferLib.safeTransfer(address(_asset), receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /// @dev Validates that total allocation caps sum to at least 100%.
    function _validateAllocationCaps(address marketToModify, uint256 newCap) internal view {
        uint256 totalCaps;
        uint256 l = approvedCTokensList.length;

        for (uint256 i; i < l; ++i) {
            address market = approvedCTokensList[i];
            if (market == marketToModify) {
                totalCaps += newCap;
            } else {
                totalCaps += allocationCaps[market];
            }
        }
        if (totalCaps < WAD) revert LendingOptimizer__InsufficientAllocationCaps();
    }

    /// @dev Converts BPS to WAD (e.g., 1000 BPS = 0.1 WAD = 10%).
    function _bpsToWad(uint256 bps) internal pure returns (uint256) {
        return bps * 1e14;
    }

    /// @dev Returns optimizer's assets held in a specific market.
    function _getMarketAssets(address cToken) internal view returns (uint256) {
        IBorrowableCToken ct = IBorrowableCToken(cToken);
        return ct.convertToAssets(ct.balanceOf(address(this)));
    }

    /// @dev Validates cToken has correct underlying and registered market manager.
    function _validateCToken(address cToken) internal view {
        if (IBorrowableCToken(cToken).asset() != address(_asset)) revert LendingOptimizer__InvalidUnderlying();
        if (!centralRegistry.isMarketManager(address(IBorrowableCToken(cToken).marketManager()))) {
            revert LendingOptimizer__InvalidMarketManager();
        }
    }

    /// @dev Returns whether a market is approved for allocation.
    function _isApprovedMarket(address market) internal view returns (bool) {
        return allocationCaps[market] != 0;
    }

    /// @dev Returns the current exchange rate in WAD. Returns WAD if no supply.
    function _exchangeRate() internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return WAD;
        return FixedPointMathLib.fullMulDiv(WAD, totalAssets(), supply);
    }

    /// @dev Verifies that every market's current allocation does not exceed its cap
    ///      and emits the post-rebalance state with per-market allocations.
    function _verifyAllocationCaps() internal {
        uint256 ta = totalAssets();
        uint256 l = approvedCTokensList.length;
        uint256[] memory allocations = new uint256[](l);

        if (ta > 0) {
            for (uint256 i; i < l; ++i) {
                address cToken = approvedCTokensList[i];
                allocations[i] = _getMarketAssets(cToken);
                uint256 currentAllocation = FixedPointMathLib.mulDiv(allocations[i], WAD, ta);
                if (currentAllocation > allocationCaps[cToken]) revert LendingOptimizer__AllocationExceedsCap();
            }
        }

        emit Rebalanced(ta, approvedCTokensList, allocations);
    }

    /// @dev Synchronizes optimizer state: absorbs yield from underlying
    ///      markets immediately and accrues performance fees.
    ///
    ///      Yield is absorbed immediately into `_totalAssets` (cToken-style).
    ///      Since this runs before every user action, frontrunning is blocked:
    ///      an attacker depositing at an accrual boundary gets no excess yield
    ///      because yield is already priced in.
    ///
    ///      Performance Fees
    ///      Fees are charged on yield above a high watermark, ensuring fees
    ///      are only taken on new all-time-high profits. This prevents
    ///      double-charging after drawdowns recover.
    function _accrueIfNeeded() internal {
        // Sync with underlying cToken markets and absorb yield
        uint256 rawTa = _accrueMarkets();
        _totalAssets = rawTa;

        // Charge performance fee on absorbed yield
        if (fee > 0) {
            uint256 supply = totalSupply();
            if (supply > 0) {
                uint256 currentRate = FixedPointMathLib.fullMulDiv(WAD, rawTa, supply);
                uint256 highRate = exchangeRateHighWatermark;

                if (currentRate > highRate) {
                    uint256 profit = rawTa - FixedPointMathLib.fullMulDiv(highRate, supply, WAD);
                    uint256 feeAssets = FixedPointMathLib.fullMulDivUp(profit, _bpsToWad(fee), WAD);

                    if (feeAssets > 0) {
                        uint256 feeShares = FixedPointMathLib.fullMulDivUp(
                            feeAssets, supply, rawTa - feeAssets
                        );
                        address dao = centralRegistry.daoAddress();
                        _mint(dao, feeShares);
                        exchangeRateHighWatermark = FixedPointMathLib.fullMulDiv(
                            WAD, rawTa, supply + feeShares
                        );
                        emit PerformanceFeeAccrued(feeShares, dao);
                    } else {
                        exchangeRateHighWatermark = currentRate;
                    }
                }
            }
        }
    }

    /// @dev Checks if deposits are paused.
    function _checkMintPaused() internal view {
        // Cache the mint paused state.
        uint256 mintPaused_ = mintPaused;
        // Revert if the optimizer is not initialized.
        if (mintPaused_ == 0) revert LendingOptimizer__NotInitialized();
        // Revert if the optimizer is paused.
        if (mintPaused_ > 1) revert LendingOptimizer__MintPaused();
    }

    /// @dev Returns the underlying token decimals.
    function _underlyingDecimals() internal view override returns (uint8) {
        return _decimals;
    }

    /// @dev Returns the decimals offset for virtual shares.
    /// @dev No offset used - inflation protection via initializeDeposits dead shares.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 0;
    }

    /// @dev Returns false - no virtual shares, use dead shares instead.
    function _useVirtualShares() internal pure override returns (bool) {
        return false;
    }

    /// @dev Checks if caller has harvester permissions.
    function _hasHarvesterPermissions() internal view {
        if (!centralRegistry.hasHarvestPermissions(msg.sender)) revert LendingOptimizer__Unauthorized();
    }

    /// @dev Checks if caller has market permissions.
    function _hasMarketPermissions() internal view {
        if (!centralRegistry.hasMarketPermissions(msg.sender)) revert LendingOptimizer__Unauthorized();
    }
}
