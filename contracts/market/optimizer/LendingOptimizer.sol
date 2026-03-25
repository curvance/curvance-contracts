// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { ReentrancyGuard } from "contracts/libraries/external/ReentrancyGuard.sol";
import { WAD, BPS } from "contracts/libraries/ConstantsLib.sol";
import { ERC20 } from "contracts/libraries/external/ERC20.sol";
import { ERC4626 } from "contracts/libraries/external/ERC4626.sol";
import { ERC165 } from "contracts/libraries/external/ERC165.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { ILendingOptimizer } from "contracts/interfaces/ILendingOptimizer.sol";


/// @title Curvance Lending Optimizer.
/// @notice Optimizes yield across multiple Curvance lending markets
///         for a single underlying asset.
/// @dev This contract is ERC4626-like with multi-market allocation
///      support, enabling users to deposit a single asset and have it
///      distributed across multiple Curvance lending markets (cTokens)
///      based on configurable allocation caps.
///
///      Deposits and withdrawals are routed pro-rata across approved
///      markets to maintain current allocation percentages. Only
///      `rebalance()` can shift allocation percentages.
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
contract LendingOptimizer is ILendingOptimizer, ERC4626, ReentrancyGuard, ERC165 {

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

    /// @notice Bounds for post-rebalance allocation validation per market.
    /// @dev Used to protect against race conditions where market state
    ///      changes between off-chain computation and on-chain execution.
    struct AllocationBound {
        /// @notice The cToken market address. Must match approvedCTokensList
        ///         ordering to commit the caller to a specific market layout.
        address cToken;
        /// @notice Minimum allocation in BPS for this market.
        uint256 minBps;
        /// @notice Maximum allocation in BPS for this market.
        uint256 maxBps;
    }

    /// CONSTANTS ///

    /// @dev Maximum fee in BPS (50% = 5000 BPS).
    uint256 public constant MAX_FEE_BPS = 5000;
    /// @dev Maximum number of supported markets.
    uint256 public constant MAX_MARKETS = 8;
    /// @dev Minimum allowed value for ReallocationAction.assetsOrBps (withdrawals).
    ///      type(int256).min is the only int256 value whose negation overflows,
    ///      so we set the floor to type(int256).min + 1.
    int256 public constant MIN_REALLOCATION_AMOUNT = type(int256).min + 1;
    /// @dev The base underlying asset requirement held in order to minimize
    ///      rounding exploits, and more generally, invariant manipulation.
    uint256 internal constant _BASE_UNDERLYING_RESERVE = 77777;

    /// @dev Minimum acceptable trackedAssets from the initial deposit.
    ///      Ensures cToken rounding never silently reduces the dead share
    ///      count below a safe threshold. Set to _BASE_UNDERLYING_RESERVE - 7
    ///      to tolerate minor rounding while catching pathological cases.
    uint256 internal constant _BASE_UNDERLYING_RESERVE_FLOOR = 77770;

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
    event ExcessRecovered(uint256 amount, address indexed recipient);

    /// ERRORS ///

    error LendingOptimizer__Unauthorized();
    error LendingOptimizer__ZeroAmount();
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
    error LendingOptimizer__AllocationOutOfBounds();

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
    /// @param targetMarket The address of the market to deposit initial assets into.
    function initializeDeposits(
        address targetMarket
    ) external nonReentrant {
        // Revert if the caller does not have market permissions.
        _hasMarketPermissions();

        // Revert if the market has already been initialized.
        if (mintPaused != 0) revert LendingOptimizer__AlreadyInitialized();
        // Revert if the target market is not approved.
        if (!_isApprovedMarket(targetMarket)) revert LendingOptimizer__MarketNotApproved();

        // Transfer _BASE_UNDERLYING_RESERVE assets.
        uint256 assets = _BASE_UNDERLYING_RESERVE;
        SafeTransferLib.safeTransferFrom(address(_asset), msg.sender, address(this), assets);

        // Deposit into target market.
        uint256 trackedAssets = _depositToMarket(targetMarket, assets);
        // Sanity check: revert if cToken rounding reduced the dead share
        // count below the safety floor. This should never happen at
        // initialization (1:1 exchange rate) but guards against edge cases.
        if (trackedAssets < _BASE_UNDERLYING_RESERVE_FLOOR) revert LendingOptimizer__InvalidParameter();

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

    /// @notice ERC4626-like deposit - deposits pro-rata across active
    ///         markets to maintain current allocation percentages.
    /// @param assets The amount of underlying assets to deposit.
    /// @param receiver The address to receive the minted shares.
    /// @return shares The amount of shares minted.
    function deposit(
        uint256 assets,
        address receiver
    ) public override(ERC4626, ILendingOptimizer) nonReentrant returns (uint256 shares) {
        if (assets == 0) revert LendingOptimizer__InvalidParameter();
        _checkMintPaused();
        _accrueIfNeeded();

        // Pull assets from the caller into the optimizer.
        SafeTransferLib.safeTransferFrom(address(_asset), msg.sender, address(this), assets);

        // Route the deposit pro-rata across all approved markets,
        // maintaining current allocation percentages.
        // trackedAssets = sum of recoverable values after cToken rounding.
        uint256[] memory perMarket = _calculateDepositProRata(assets, false);
        uint256 trackedAssets;
        for (uint256 i; i < approvedCTokensList.length; ++i) {
            // Skip deposits that would round to zero cToken shares.
            if (perMarket[i] == 0 || IBorrowableCToken(approvedCTokensList[i]).convertToShares(perMarket[i]) == 0) continue;
            trackedAssets += _depositToMarket(approvedCTokensList[i], perMarket[i]);
        }

        // Derive shares from trackedAssets (not input assets) BEFORE updating
        // _totalAssets, so convertToShares uses the pre-deposit denominator.
        shares = convertToShares(trackedAssets);
        // Revert if the deposit is too small to mint any shares.
        if (shares == 0) revert LendingOptimizer__ZeroAmount();
        _totalAssets += trackedAssets;
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice ERC4626-like mint - mints exact shares by depositing
    ///         pro-rata across active markets.
    /// @param shares The exact amount of shares to mint.
    /// @param receiver The address to receive the minted shares.
    /// @return assets The amount of assets deposited.
    function mint(
        uint256 shares,
        address receiver
    ) public override nonReentrant returns (uint256 assets) {
        _checkMintPaused();
        _accrueIfNeeded();

        if (shares == 0) revert LendingOptimizer__InvalidParameter();

        // Compute asset cost for the requested shares, rounding up
        // so the vault never under-charges. totalSupply() is always > 0
        // because initializeDeposits() must be called before any deposits.
        assets = FixedPointMathLib.fullMulDivUp(shares, _totalAssets, totalSupply());

        // Compute pro-rata amounts with conversion roundtrip so that
        // each per-market deposit covers the full withdrawal cost of the
        // shares being minted. This prevents mint() from rounding in
        // favor of the user at the expense of existing depositors.
        uint256[] memory perMarket = _calculateDepositProRata(assets, true);
        assets = 0;
        for (uint256 i; i < approvedCTokensList.length; ++i) {
            assets += perMarket[i];
        }

        // Pull the (potentially inflated) assets and deposit to markets.
        SafeTransferLib.safeTransferFrom(address(_asset), msg.sender, address(this), assets);
        uint256 trackedAssets;
        for (uint256 i; i < approvedCTokensList.length; ++i) {
            // Skip deposits that would round to zero cToken shares.
            if (perMarket[i] == 0 || IBorrowableCToken(approvedCTokensList[i]).convertToShares(perMarket[i]) == 0) continue;
            trackedAssets += _depositToMarket(approvedCTokensList[i], perMarket[i]);
        }

        // Track recoverable value so exchange rate accurately reflects
        // what can be withdrawn. Any excess corrects at next _accrueIfNeeded().
        _totalAssets += trackedAssets;
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice ERC4626-like withdraw - withdraws pro-rata across
    ///         all approved markets while respecting liquidity constraints.
    /// @dev Executes withdrawals first (violating CEI), then measures the
    ///      actual cToken rounding loss by re-reading positions. Shares
    ///      burned reflect the true cost including rounding loss, so
    ///      remaining depositors are not diluted. CEI violation is safe
    ///      because cToken markets are trusted and nonReentrant is enforced.
    /// @param assets The amount of underlying assets to withdraw.
    /// @param receiver The address to receive the withdrawn assets.
    /// @param owner The address that owns the shares being burned.
    /// @return shares The amount of shares burned.
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override nonReentrant returns (uint256 shares) {
        if (assets == 0) revert LendingOptimizer__InvalidParameter();
        _checkRedeemPaused();
        _accrueIfNeeded();

        uint256 taBefore = _totalAssets;
        uint256 supplyBefore = totalSupply();

        // Execute pro-rata withdrawals and re-sync _totalAssets from
        // actual cToken positions. The difference taBefore - _totalAssets
        // captures both the withdrawn assets and any cToken rounding loss.
        (_totalAssets,) = _executeWithdraw(assets, false);

        // Burn shares based on actual cost (assets + rounding loss).
        uint256 actualCost = taBefore - _totalAssets;
        shares = FixedPointMathLib.fullMulDivUp(
            actualCost, supplyBefore, taBefore
        );

        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);
        _burn(owner, shares);

        SafeTransferLib.safeTransfer(address(_asset), receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /// @notice ERC4626-like redeem - redeems pro-rata across
    ///         all approved markets while respecting liquidity constraints.
    /// @dev Executes withdrawals with a conversion roundtrip to ensure
    ///      the optimizer's position drops by exactly the fair amount.
    /// @param shares The amount of shares to redeem.
    /// @param receiver The address to receive the underlying assets.
    /// @param owner The address that owns the shares being burned.
    /// @return assets The amount of assets withdrawn.
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override nonReentrant returns (uint256 assets) {
        _checkRedeemPaused();
        _accrueIfNeeded();

        // Compute gross assets from shares before any state changes.
        uint256 taBefore = _totalAssets;
        assets = convertToAssets(shares);
        if (assets == 0) revert LendingOptimizer__InvalidParameter();

        // Execute pro-rata withdrawals with conversion roundtrip to
        // ensure the optimizer's position drops by exactly what is fair
        // for the redeemed shares. Without this, cToken rounding loss
        // leaves dust stuck in the optimizer and drops the exchange rate.
        (_totalAssets, assets) = _executeWithdraw(assets, true);

        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);
        _burn(owner, shares);

        SafeTransferLib.safeTransfer(address(_asset), receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
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
    ///      After rebalancing, each market's allocation must not exceed its cap
    ///      and must fall within the caller-specified allocation bounds.
    ///      NOTE: cToken deposit/withdraw rounding incurs a small asset loss
    ///      (~1-2 wei per action). This is absorbed on the next accrual.
    /// @param actions Array of reallocation actions, one per approved market.
    /// @param bounds Array of allocation bounds, one per approved market.
    ///               Each market's post-rebalance allocation (in BPS) must be
    ///               within [minBps, maxBps]. Use [0, 10000] for unconstrained.
    function rebalance(
        ReallocationAction[] calldata actions,
        AllocationBound[] calldata bounds
    ) external nonReentrant {
        // Revert if the caller does not have harvester or market permissions.
        _hasRebalancePermissions();

        // Accrue yield and charge protocol's performance fee.
        _accrueIfNeeded();

        // Cache approved markets length.
        uint256 l = approvedCTokensList.length;
        // Revert if the actions or bounds array length does not match approved markets.
        if (actions.length != l) revert LendingOptimizer__ArrayLengthMismatch();
        if (bounds.length != l) revert LendingOptimizer__ArrayLengthMismatch();

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

        // Verify allocation caps, bounds, and emit post-rebalance state.
        _verifyAllocations(bounds);
    }

    /// @notice Removes an approved market and reallocates its assets.
    /// @dev After removal, remaining market caps must sum to >= 100%. If not,
    ///      call `updateCap()` to increase a remaining market's cap before removal.
    ///      The caller specifies BPS-based percentages for redistribution
    ///      via the `assetsOrBps` field of each ReallocationAction. BPS values
    ///      must be positive and sum to exactly 10000 (100%).
    ///      The last target receives the remainder to avoid dust.
    /// @param cTokenToRemove Address of the market to remove.
    /// @param removeActions Reallocation targets. `assetsOrBps` field is BPS (1-10000).
    /// @param bounds Post-removal allocation bounds, one per remaining market.
    ///               Must match the post-removal approvedCTokensList order (swap-and-pop).
    function removeApprovedAsset(
        address cTokenToRemove,
        ReallocationAction[] calldata removeActions,
        AllocationBound[] calldata bounds
    ) external nonReentrant {
        // Revert if the caller does not have market permissions.
        _hasMarketPermissions();

        // Revert if there is only one market.
        if (approvedCTokensList.length == 1) revert LendingOptimizer__InvalidParameter();
        // Bounds must match the post-removal market count.
        if (bounds.length != approvedCTokensList.length - 1) revert LendingOptimizer__ArrayLengthMismatch();

        // Revert if the market to remove is not approved.
        if (!_isApprovedMarket(cTokenToRemove)) revert LendingOptimizer__MarketNotApproved();

        // Revert if the market to remove is paused for redemptions.
        if (_isMarketPausedForAction(cTokenToRemove, false)) {
            revert LendingOptimizer__MarketPaused();
        }

        // Validate remaining allocation caps sum to >= 100%.
        _validateAllocationCaps(cTokenToRemove, 0);

        // Accrue yield and charge protocol's performance fee.
        _accrueIfNeeded();

        // Delete the allocation cap for the removed market.
        delete allocationCaps[cTokenToRemove];

        // Check if there are actual assets to redeem.
        // Both zero shares and non-zero shares that round down to
        // zero assets are handled.
        {
            IBorrowableCToken cToken = IBorrowableCToken(cTokenToRemove);
            uint256 sharesToRedeem = cToken.balanceOf(address(this));
            uint256 previewedAssets = sharesToRedeem > 0
                ? cToken.convertToAssets(sharesToRedeem)
                : 0;

            // Only redeem and reallocate if there are previewed assets.
            // Else we can skip straight to removing the market from the approved list.
            if (previewedAssets > 0) {
                // Revert if no reallocation targets are provided.
                if (removeActions.length == 0) revert LendingOptimizer__InvalidParameter();

                // Redeem all shares from the market being removed.
                uint256 assetsRedeemed = cToken.redeem(
                    sharesToRedeem,
                    address(this),
                    address(this)
                );

                // Distribute redeemed assets proportionally via BPS.
                uint256 totalBps;
                uint256 totalDeposited;
                uint256 lastAction = removeActions.length - 1;

                for (uint256 i; i <= lastAction; ++i) {
                    address cTokenAddress = address(removeActions[i].cToken);

                    // Validate the reallocation target.
                    {
                        int256 bps = removeActions[i].assetsOrBps;
                        // Revert if BPS is not positive.
                        if (bps <= 0) revert LendingOptimizer__InvalidParameter();
                        // Revert if target is the market being removed.
                        if (cTokenAddress == cTokenToRemove) revert LendingOptimizer__InvalidParameter();
                        // Revert if the reallocation target is not an approved market.
                        if (!_isApprovedMarket(cTokenAddress)) revert LendingOptimizer__MarketNotApproved();
                        // Revert if duplicate reallocation target.
                        for (uint256 j; j < i; ++j) {
                            if (address(removeActions[j].cToken) == cTokenAddress) revert LendingOptimizer__InvalidParameter();
                        }
                        // Revert if the reallocation target is paused for minting.
                        if (_isMarketPausedForAction(cTokenAddress, true)) {
                            revert LendingOptimizer__MarketPaused();
                        }
                        totalBps += uint256(bps);
                    }

                    // Last target receives the remainder to avoid dust.
                    // Else deposit normally.
                    uint256 depositAmount;
                    if (i == lastAction) {
                        depositAmount = assetsRedeemed - totalDeposited;
                    } else {
                        depositAmount = FixedPointMathLib.fullMulDiv(assetsRedeemed, uint256(removeActions[i].assetsOrBps), BPS);
                        totalDeposited += depositAmount;
                    }

                    // Skip deposit if dust amount rounds to zero cToken shares.
                    if (IBorrowableCToken(cTokenAddress).convertToShares(depositAmount) > 0) {
                        _depositToMarket(cTokenAddress, depositAmount);
                    }
                }

                // Revert if BPS values do not sum to exactly 100%.
                if (totalBps != BPS) revert LendingOptimizer__InvalidParameter();
            }
        }

        // Find the index of the cToken to remove.
        {
            uint256 l = approvedCTokensList.length;
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
        }

        // Verify allocation caps and caller-specified bounds after reallocation.
        _verifyAllocations(bounds);

        emit MarketRemoved(cTokenToRemove);
    }

    /// @notice Adds a new approved market for allocation.
    /// @dev Requires market permissions. The cToken must have matching
    ///      underlying asset and a registered market manager. Max 8 markets.
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

        emit MarketAdded(newAsset, capBps);
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

        emit AllocationCapUpdated(cToken, newCapBps);
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

    /// @notice Returns the cached exchange rate. Accurate post-accrual,
    ///         slightly stale between accruals as market interest accrues
    ///         continuously. For real-time accuracy, call `accrueIfNeeded()`
    ///         first or use `exchangeRateUpdated()`.
    /// @return Current exchange rate in WAD (1e18 = 1:1). Returns WAD if no supply.
    function exchangeRate() public view returns (uint256) {
        return _exchangeRate();
    }

    /// @notice Accrues interest, absorbs yield, charges fees, and returns exchange rate.
    /// @dev Triggers full state update: accrues underlying markets, absorbs
    ///      yield, and charges performance fees if rate exceeds watermark.
    /// @return Current exchange rate in WAD (1e18 = 1:1). Returns WAD if no supply.
    function exchangeRateUpdated() public nonReentrant returns (uint256) {
        _accrueIfNeeded();
        return _exchangeRate();
    }

    /// @notice Accrues yield from underlying markets and absorbs it.
    function accrueIfNeeded() external nonReentrant {
        _accrueIfNeeded();
    }

    /// @notice Recovers underlying assets incorrectly sent to the optimizer.
    /// @dev All assets should be deployed in cToken markets, so any idle
    ///      underlying balance is excess. Does not modify `_totalAssets`.
    ///      Requires DAO permissions.
    function skim() external nonReentrant {
        _hasDaoPermissions();
        uint256 excess = skimAvailable();

        address daoAddress = centralRegistry.daoAddress();
        SafeTransferLib.safeTransfer(address(_asset), daoAddress, excess);

        emit ExcessRecovered(excess, daoAddress);
    }

    /// @notice Returns the amount of excess underlying that can be recovered.
    /// @dev The optimizer should hold no idle underlying — any balance is excess.
    /// @return excess The recoverable excess underlying amount.
    function skimAvailable() public view returns (uint256 excess) {
        excess = _asset.balanceOf(address(this));
        if (excess == 0) revert LendingOptimizer__ZeroAmount();
    }

    /// VIEW FUNCTIONS ///

    /// @notice Returns the cached total assets held across all approved markets.
    /// @dev Returns the internally tracked `_totalAssets`, which is updated
    ///      on every state-changing operation (deposit, withdraw, rebalance).
    ///      This value may be slightly stale between accruals as market
    ///      interest accrues continuously.
    ///
    ///      NOTE: `totalAssets()` intentionally returns the cached value
    ///      because `deposit()` calls `convertToShares()` — which reads
    ///      `totalAssets()` — AFTER depositing into cTokens. An accrued read
    ///      would include the just-deposited amount, inflating the denominator
    ///      and minting fewer shares than intended.
    /// @return The cached total assets held by the optimizer.
    function totalAssets() public view override(ERC4626, ILendingOptimizer) returns (uint256) {
        return _totalAssets;
    }

    /// @notice Returns the maximum amount of assets that can be deposited.
    /// @dev Returns 0 when deposits are paused, uninitialized,
    ///      or any approved market has minting paused.
    /// @return Maximum depositable assets, or 0 if deposits are blocked.
    function maxDeposit(address) public view override returns (uint256) {
        return mintPaused == 1 && !_anyMarketPaused(true)
            ? type(uint256).max
            : 0;
    }

    /// @notice Returns the maximum amount of shares that can be minted.
    /// @dev Returns 0 when deposits are paused, uninitialized,
    ///      or any approved market has minting paused.
    /// @return Maximum mintable shares, or 0 if deposits are blocked.
    function maxMint(address) public view override returns (uint256) {
        return mintPaused == 1 && !_anyMarketPaused(true)
            ? type(uint256).max
            : 0;
    }

    /// @notice Returns the maximum amount of assets that `owner` can withdraw.
    /// @dev Returns 0 when any approved market has redemptions paused.
    ///      Uses cached `_totalAssets` — accurate post-accrual.
    /// @param owner The address that owns the shares.
    /// @return Maximum withdrawable assets, or 0 if withdrawals are blocked.
    function maxWithdraw(address owner) public view override returns (uint256) {
        if (_anyMarketPaused(false)) return 0;
        return convertToAssets(balanceOf(owner));
    }

    /// @notice Returns the maximum amount of shares that `owner` can redeem.
    /// @dev Returns 0 when any approved market has redemptions paused.
    /// @param owner The address that owns the shares.
    /// @return Maximum redeemable shares, or 0 if withdrawals are blocked.
    function maxRedeem(address owner) public view override returns (uint256) {
        if (_anyMarketPaused(false)) return 0;
        return balanceOf(owner);
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
    function asset() public view override(ERC4626, ILendingOptimizer) returns (address) {
        return address(_asset);
    }

    /// @inheritdoc ERC4626
    function convertToAssets(uint256 shares) public view override(ERC4626, ILendingOptimizer) returns (uint256 assets) {
        return super.convertToAssets(shares);
    }

    /// @inheritdoc ERC20
    function balanceOf(address owner) public view override(ERC20, ILendingOptimizer) returns (uint256 result) {
        return super.balanceOf(owner);
    }

    /// @notice Returns true if this contract implements the interface.
    /// @param interfaceId The interface identifier to check.
    /// @return result True if the interface is supported.
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool result) {
        result = interfaceId == type(IERC20).interfaceId ||
            interfaceId == type(ERC4626).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// INTERNAL FUNCTIONS ///

    /// @dev Returns true if any approved market is paused for the given action.
    ///      Used to propagate cToken pause state to the optimizer level:
    ///      any single market paused → entire optimizer paused for that action.
    /// @param isDeposit True to check mint-paused, false to check redeem-paused.
    /// @return True if at least one approved market is paused for the action.
    function _anyMarketPaused(bool isDeposit) internal view returns (bool) {
        uint256 l = approvedCTokensList.length;
        for (uint256 i; i < l; ++i) {
            if (_isMarketPausedForAction(approvedCTokensList[i], isDeposit)) return true;
        }
        return false;
    }

    /// @dev Returns true if the market is paused for the given action.
    ///      Deposits check per-cToken `mintPaused` via the market manager;
    ///      withdrawals check market-wide `redeemPaused`.
    /// @param cToken The cToken market address to check.
    /// @param isDeposit True to check mint-paused, false to check redeem-paused.
    /// @return True if the market is paused for the specified action.
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

    /// @dev Executes pro-rata withdrawals across all approved markets and
    ///      returns the total remaining position (for `_totalAssets` re-sync).
    ///      Entry point reverts if any market is paused for redemptions.
    /// @param assets Total underlying assets to withdraw.
    /// @param conversionRoundtrip If true, adjusts each per-market amount
    ///        via previewRedeem(previewDeposit(amount)) so the optimizer's
    ///        position drops by exactly the fair amount for the redeemed
    ///        shares. Used by redeem() to prevent dust accumulation.
    /// @return newTotalAssets Sum of optimizer positions after withdrawals.
    /// @return totalWithdrawn Sum of adjusted per-market withdrawal amounts.
    function _executeWithdraw(uint256 assets, bool conversionRoundtrip) internal returns (uint256 newTotalAssets, uint256 totalWithdrawn) {
        uint256 l = approvedCTokensList.length;
        uint256[] memory marketAssets = new uint256[](l);
        uint256[] memory liquidityLimit = new uint256[](l);
        uint256 totalMarketAssets;

        // Read each market's optimizer position and available liquidity.
        // marketAssets[i]    = optimizer's full position (pro-rata weight).
        // liquidityLimit[i]  = min(position, idle cash) — max withdrawable.
        for (uint256 i; i < l; ++i) {
            IBorrowableCToken cToken = IBorrowableCToken(approvedCTokensList[i]);
            uint256 optimizerAssets = cToken.convertToAssets(
                cToken.balanceOf(address(this))
            );
            uint256 marketLiquidity = cToken.assetsHeld();

            marketAssets[i] = optimizerAssets;
            liquidityLimit[i] = optimizerAssets < marketLiquidity
                ? optimizerAssets
                : marketLiquidity;
            totalMarketAssets += optimizerAssets;
        }

        // Split withdrawal pro-rata by position size, capped by each
        // market's available liquidity. Shortfalls from liquidity-limited
        // markets are redistributed sequentially to others.
        uint256[] memory amounts = _calcProRata(
            assets, marketAssets, liquidityLimit, totalMarketAssets
        );

        // Verify the full amount was allocated. If total available
        // liquidity across all markets is insufficient, revert.
        uint256 totalAllocated;
        for (uint256 i; i < l; ++i) {
            totalAllocated += amounts[i];
            // For redeem(): adjust each amount via previewRedeem(previewDeposit(amount))
            // so the withdrawn amount rounds down to exactly what the cToken would
            // give back, preventing dust from accumulating in the optimizer.
            if (conversionRoundtrip) {
                amounts[i] = IBorrowableCToken(approvedCTokensList[i]).previewRedeem(
                    IBorrowableCToken(approvedCTokensList[i]).previewDeposit(amounts[i])
                );
            }
            totalWithdrawn += amounts[i];
        }

        // Revert if roundtrip adjustment reduced all withdrawals to zero.
        if (conversionRoundtrip && totalWithdrawn == 0) revert LendingOptimizer__ZeroAmount();
        if (totalAllocated < assets) revert LendingOptimizer__InsufficientLiquidity();

        // Execute cToken withdrawals and re-read positions in a single
        // pass. The returned newTotalAssets reflects ground truth after
        // withdrawals, capturing any cToken rounding loss (from ceil
        // share burns) that the caller uses for accounting.
        for (uint256 i; i < l; ++i) {
            if (amounts[i] > 0) {
                IBorrowableCToken(approvedCTokensList[i]).withdraw(
                    amounts[i], address(this), address(this)
                );
            }
            newTotalAssets += _getMarketAssets(approvedCTokensList[i]);
        }
    }

    /// @dev Computes pro-rata deposit amounts across all approved markets,
    ///      maintaining current allocation percentages. Only callable
    ///      post-initializeDeposits (totalMarketAssets > 0).
    ///      Entry point reverts if any market is paused for minting.
    /// @param assets Total assets to deposit.
    /// @param conversionRoundtrip If true, inflates each per-market amount
    ///        via previewMint(previewWithdraw(amount)) so that the deposited
    ///        cToken position can cover a full withdrawal of `amount`. Used by
    ///        mint() to prevent rounding in the user's favor.
    function _calculateDepositProRata(uint256 assets, bool conversionRoundtrip) internal view returns (uint256[] memory amounts) {
        uint256 l = approvedCTokensList.length;
        amounts = new uint256[](l);
        uint256[] memory marketAssets = new uint256[](l);
        uint256 totalMarketAssets;
        uint256 lastNonZero;

        // Gather each market's current asset allocation.
        // Entry point reverts if any market is paused for minting.
        // totalMarketAssets is always > 0 post-initializeDeposits.
        for (uint256 i; i < l; ++i) {
            marketAssets[i] = _getMarketAssets(approvedCTokensList[i]);
            totalMarketAssets += marketAssets[i];
            if (marketAssets[i] > 0) lastNonZero = i;
        }

        // Split the deposit proportionally by current allocation.
        // No liquidity cap needed for deposits — last non-zero market
        // receives the remainder to handle mulDiv rounding dust.
        uint256 deposited;
        for (uint256 i; i < l; ++i) {
            uint256 amount;
            if (i == lastNonZero) {
                // Last market gets the remainder to avoid dust.
                amount = assets - deposited;
            } else {
                amount = FixedPointMathLib.fullMulDiv(
                    assets, marketAssets[i], totalMarketAssets
                );
                deposited += amount;
            }

            // For mint(): inflate amount so the deposited cToken position
            // covers a full withdrawal of the pro-rata share.
            if (conversionRoundtrip) {
                amount = IBorrowableCToken(approvedCTokensList[i]).previewMint(
                    IBorrowableCToken(approvedCTokensList[i]).previewWithdraw(amount)
                );
            }
            amounts[i] = amount;
        }
    }

    /// @dev Computes pro-rata allocation of `total` across markets based on
    ///      `weights`, bounded by `liquidityLimit` per market. Any shortfall
    ///      from rounding or liquidity-limited markets is redistributed
    ///      sequentially.
    /// @param total Total amount to allocate.
    /// @param marketAssets Per-market optimizer position (used as pro-rata weights).
    /// @param liquidityLimit Per-market maximum allocation (available liquidity).
    /// @param totalMarketAssets Sum of all market assets.
    /// @return amounts Per-market allocated amounts.
    function _calcProRata(
        uint256 total,
        uint256[] memory marketAssets,
        uint256[] memory liquidityLimit,
        uint256 totalMarketAssets
    ) internal pure returns (uint256[] memory amounts) {
        // Always approvedCTokensList length, saves a storage read.
        uint256 l = marketAssets.length;
        amounts = new uint256[](l);

        // First pass: assign each market its proportional share,
        // capped by that market's liquidity limit.
        uint256 allocated;
        for (uint256 i; i < l; ++i) {
            // Proportional amount = total * (market assets / total market assets).
            uint256 proportional = FixedPointMathLib.fullMulDiv(
                total, marketAssets[i], totalMarketAssets
            );

            // Cap by available liquidity.
            amounts[i] = proportional < liquidityLimit[i] ? proportional : liquidityLimit[i];
            allocated += amounts[i];
        }

        // Second pass: redistribute any unallocated remainder.
        // Remainder comes from two sources:
        //   1. mulDiv rounding (typically 0-2 wei across all markets)
        //   2. Liquidity-capped markets that couldn't take their full share
        // Redistributed sequentially to the first markets with spare capacity.
        if (allocated < total) {
            uint256 remaining = total - allocated;
            for (uint256 i; i < l && remaining > 0; ++i) {
                uint256 spare = liquidityLimit[i] - amounts[i];
                if (spare == 0) continue;
                uint256 extra = remaining < spare ? remaining : spare;
                amounts[i] += extra;
                remaining -= extra;
            }
        }
    }

    /// @dev Validates that total allocation caps sum to at least 100% (WAD).
    ///      Used when decreasing a cap or removing a market to ensure
    ///      full allocation remains possible.
    /// @param marketToModify The market whose cap is being changed.
    /// @param newCap The proposed new cap in WAD (pass 0 for removal).
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
    /// @param bps Value in basis points (1 BPS = 0.01%).
    /// @return WAD-scaled value (1e14 per BPS).
    function _bpsToWad(uint256 bps) internal pure returns (uint256) {
        return bps * 1e14;
    }

    /// @dev Returns the optimizer's asset value in a specific market.
    /// @param cToken The cToken market address.
    /// @return The optimizer's position in underlying asset terms.
    function _getMarketAssets(address cToken) internal view returns (uint256) {
        IBorrowableCToken ct = IBorrowableCToken(cToken);
        return ct.convertToAssets(ct.balanceOf(address(this)));
    }

    /// @dev Validates cToken has correct underlying, is borrowable,
    ///      has a registered market manager, and is listed in that manager.
    /// @param cToken The cToken market address to validate.
    function _validateCToken(address cToken) internal view {
        if (IBorrowableCToken(cToken).asset() != address(_asset)) revert LendingOptimizer__InvalidUnderlying();
        if (!IBorrowableCToken(cToken).isBorrowable()) revert LendingOptimizer__InvalidParameter();

        address marketManager = address(IBorrowableCToken(cToken).marketManager());
        if (!centralRegistry.isMarketManager(marketManager)) revert LendingOptimizer__InvalidMarketManager();
        if (!IMarketManager(marketManager).isListed(cToken)) revert LendingOptimizer__InvalidMarketManager();
    }

    /// @dev Returns whether a market is approved for allocation.
    /// @param market The market address to check.
    /// @return True if the market has a non-zero allocation cap.
    function _isApprovedMarket(address market) internal view returns (bool) {
        return allocationCaps[market] != 0;
    }

    /// @dev Returns the current exchange rate in WAD. Returns WAD if no supply.
    ///      Uses cached `_totalAssets` — accurate post-accrual.
    /// @return Exchange rate scaled by WAD (1e18 = 1:1 ratio).
    function _exchangeRate() internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return WAD;
        return FixedPointMathLib.fullMulDiv(WAD, totalAssets(), supply);
    }

    /// @dev Verifies allocation caps and bounds, syncs _totalAssets,
    ///      and emits the post-rebalance state. Reads each market's balance
    ///      once, avoiding redundant external calls.
    ///
    ///      Both caps and bounds are always checked. Bounds protect against
    ///      race conditions where state changes between off-chain computation
    ///      and on-chain execution (e.g., a deposit shifts allocations before
    ///      the harvester's rebalance tx lands).
    /// @param bounds Array of allocation bounds, one per approved market.
    ///               Must match approvedCTokensList length.
    function _verifyAllocations(AllocationBound[] memory bounds) internal {
        uint256 l = approvedCTokensList.length;
        uint256[] memory allocations = new uint256[](l);
        uint256 ta;
        bool checkBounds = bounds.length > 0;

        // Compute fresh total from actual post-rebalance market balances
        // instead of using the cached _totalAssets, which may be stale
        // due to rounding losses from cToken withdraw/deposit round-trips.
        for (uint256 i; i < l; ++i) {
            allocations[i] = _getMarketAssets(approvedCTokensList[i]);
            ta += allocations[i];
            // Validate bounds ordering and sanity when provided.
            if (checkBounds) {
                if (bounds[i].cToken != approvedCTokensList[i]) revert LendingOptimizer__InvalidParameter();
                if (bounds[i].minBps > bounds[i].maxBps) revert LendingOptimizer__InvalidParameter();
            }
        }

        // Sync cached total assets to the post-rebalance state.
        _totalAssets = ta;

        if (ta > 0) {
            for (uint256 i; i < l; ++i) {
                // Check allocation cap (WAD-based).
                uint256 allocationWad = FixedPointMathLib.fullMulDiv(allocations[i], WAD, ta);
                if (allocationWad > allocationCaps[approvedCTokensList[i]]) {
                    revert LendingOptimizer__AllocationExceedsCap();
                }

                // Check caller-specified bounds (BPS-based) if provided.
                if (checkBounds) {
                    uint256 allocationBps = FixedPointMathLib.fullMulDiv(allocations[i], BPS, ta);
                    if (allocationBps < bounds[i].minBps || allocationBps > bounds[i].maxBps) {
                        revert LendingOptimizer__AllocationOutOfBounds();
                    }
                }
            }
        } else {
            // If totalAssets is zero, all bounds must allow zero allocation.
            if (checkBounds) {
                for (uint256 i; i < l; ++i) {
                    if (bounds[i].minBps > 0) {
                        revert LendingOptimizer__AllocationOutOfBounds();
                    }
                }
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
                    uint256 profit = rawTa - FixedPointMathLib.fullMulDivUp(highRate, supply, WAD);
                    // Round up to prevent fee undercharge on dust profits.
                    uint256 feeAssets = FixedPointMathLib.fullMulDiv(profit, _bpsToWad(fee), WAD);

                    if (feeAssets > 0) {
                        uint256 feeShares = FixedPointMathLib.fullMulDiv(
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

    /// @dev Reverts if deposits are paused. Deposits are paused when:
    ///      1. The optimizer itself is paused (mintPaused > 1) or uninitialized (0).
    ///      2. Any approved market has minting paused — prevents new depositors
    ///         from entering a degraded pool where some markets are unreachable.
    function _checkMintPaused() internal view {
        uint256 mintPaused_ = mintPaused;
        if (mintPaused_ == 0) revert LendingOptimizer__NotInitialized();
        if (mintPaused_ > 1) revert LendingOptimizer__MintPaused();
        if (_anyMarketPaused(true)) revert LendingOptimizer__MarketPaused();
    }

    /// @dev Reverts if any approved market has redemptions paused.
    ///      Prevents bank-run scenario where early withdrawers drain
    ///      liquidity from active markets, leaving later withdrawers
    ///      with funds locked in the paused market.
    function _checkRedeemPaused() internal view {
        if (_anyMarketPaused(false)) revert LendingOptimizer__MarketPaused();
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

    /// @dev Checks if caller has harvester or market permissions.
    ///      Used by rebalance() to allow both the harvester bot and
    ///      the DAO/market admin to reallocate assets.
    function _hasRebalancePermissions() internal view {
        if (!centralRegistry.hasHarvestPermissions(msg.sender) &&
            !centralRegistry.hasMarketPermissions(msg.sender)) revert LendingOptimizer__Unauthorized();
    }

    /// @dev Checks if caller has market permissions.
    function _hasMarketPermissions() internal view {
        if (!centralRegistry.hasMarketPermissions(msg.sender)) revert LendingOptimizer__Unauthorized();
    }

    /// @dev Checks if caller has DAO permissions.
    function _hasDaoPermissions() internal view {
        if (!centralRegistry.hasDaoPermissions(msg.sender)) revert LendingOptimizer__Unauthorized();
    }
}
