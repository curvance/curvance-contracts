// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { ReentrancyGuard } from "contracts/libraries/external/ReentrancyGuard.sol";
import { WAD, BPS } from "contracts/libraries/ConstantsLib.sol";
import { ERC4626 } from "contracts/libraries/external/ERC4626.sol";
import { ERC165 } from "contracts/libraries/external/ERC165.sol";
import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

import { ICToken } from "contracts/interfaces/ICToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPluginDelegable } from "contracts/interfaces/IPluginDelegable.sol";

import { console2 } from "forge-std/console2.sol";

/// @title Curvance Lending Optimizer.
/// @notice Optimizes yield across multiple Curvance lending markets
///         for a single underlying asset.
/// @dev This contract extends ERC4626 with multi-market allocation
///      support, enabling users to deposit a single asset and have it
///      distributed across multiple Curvance lending markets (cTokens)
///      based on configurable allocation caps.
///
///      Deposits can target specific markets or be automatically routed
///      to the optimal market based on projected yield and cap headroom.
///      Withdrawals similarly select the lowest-yielding market to
///      preserve capital in higher-performing markets.
///
///      Yield is smoothed over a configurable vesting period to prevent
///      frontrunning attacks where users deposit before yield accrues
///      and withdraw immediately after. New yield is only detected after
///      the previous vesting period ends, preventing overlapping vests.
///
///      Performance fees are charged on yield above a high watermark,
///      ensuring fees are only taken on new all-time-high profits. This
///      prevents double-charging after drawdowns recover.
///
///      Shares represent proportional ownership of total assets across
///      all markets. The exchange rate is calculated as:
///      `(totalAssets * WAD) / totalSupply`, where totalAssets includes
///      vested yield but excludes unvested yield still vesting.
///
///      Allocation caps (in WAD) define the maximum percentage each
///      market can hold. The sum of all caps must be >= 100% to ensure
///      full allocation is possible. Authorized harvesters can rebalance
///      assets across markets while respecting these caps.
///
///      Dead shares minted to address(0) on initialization prevent
///      inflation attacks. All state-changing functions have reentrancy
///      protection.
contract LendingOptimizer is ERC4626, PluginDelegable, ReentrancyGuard, ERC165 {

    /// TYPES ///

    /// @notice Represents a single rebalance operation for moving assets between markets.
    /// @dev Used in the rebalance() function to specify deposit/withdrawal actions.
    ///      Actions are processed in two passes: withdrawals first, then deposits.
    struct RebalanceAction {
        /// @notice The cToken market to interact with.
        IBorrowableCToken cToken;
        /// @notice The amount of underlying assets to deposit or withdraw.
        uint256 assets;
        /// @notice True for deposit, false for withdrawal.
        bool isDeposit;
    }

    /// @notice Represents a reallocation target when removing a market.
    /// @dev Used in removeApprovedAsset() to specify where to move assets
    ///      from the removed market. The sum of all reallocationAmounts must
    ///      equal the total assets redeemed from the removed market.
    struct RemoveAction {
        /// @notice The target cToken market to receive reallocated assets.
        IBorrowableCToken cToken;
        /// @notice The amount of assets to deposit into this market.
        uint256 reallocationAmount;
    }

    /// CONSTANTS ///

    /// @dev Maximum fee in BPS (50% = 5000 BPS).
    uint256 public constant MAX_FEE_BPS = 5000;
    /// @dev Maximum number of supported markets.
    uint256 public constant MAX_MARKETS = 6;
    /// @dev The base underlying asset requirement held in order to minimize
    ///      rounding exploits, and more generally, invariant manipulation.
    uint256 internal constant _BASE_UNDERLYING_RESERVE = 77777;

    /// @dev Mask of `VESTING_RATE` entry in `_vestingData`.
    uint256 internal constant _BITMASK_VESTING_RATE = (1 << 176) - 1;
    /// @dev Mask of all bits except `LAST_VEST` entry in `_vestingData`.
    uint256 internal constant _BITMASK_LAST_VEST_COMPLEMENT = (1 << 216) - 1;
    /// @dev The bit position of `VEST_END` in `_vestingData`.
    uint256 internal constant _BITPOS_VEST_END = 176;
    /// @dev The bit position of `LAST_VEST` in `_vestingData`.
    uint256 internal constant _BITPOS_LAST_VEST = 216;
    /// @dev Maximum vesting period (3 days).
    uint256 internal constant _MAXIMUM_VESTING_PERIOD = 3 days;

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
    /// @notice Performance fee in WAD.
    uint256 public fee;
    /// @notice Highest exchange rate ever achieved (for fee calculation).
    uint256 public exchangeRateHighWatermark;
    /// @dev Internal packed vesting data:
    ///      Bits Layout:
    ///      - [0..175]   `VESTING_RATE`.
    ///      - [176..215] `VEST_END`.
    ///      - [216..255] `LAST_VEST`.
    uint256 internal _vestingData;
    /// @notice The period of time harvested rewards are vested over,
    ///         in seconds.
    uint256 public vestingPeriod;
    /// @notice Last recognized total assets (after vesting).
    uint256 internal _totalAssets;
    /// @notice Whether deposits are enabled.
    /// @dev 0 = uninitialized; 1 = active; 2 = paused.
    uint8 public mintPaused;


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


    /// EVENTS ///

    event MarketAdded(address indexed cToken, uint256 allocationCap);
    event MarketRemoved(address indexed cToken);
    event AllocationCapUpdated(address indexed cToken, uint256 newCap);
    event FeeUpdated(uint256 newFee);
    event Rebalanced(uint256 totalAssets);
    event PerformanceFeeAccrued(uint256 feeShares, address indexed recipient);
    event ActionPaused(string action, bool state);

    /// CONSTRUCTOR ///

    constructor(
        IERC20 asset_,
        ICentralRegistry _centralRegistry,
        address[] memory _approvedCTokens,
        uint256[] memory _allocationCapsBps,
        uint256 _feeBps,
        uint256 _vestingPeriod
    ) PluginDelegable(_centralRegistry) {
        // Revert if trying to add more than `MAX_MARKETS`.
        if (_approvedCTokens.length > MAX_MARKETS) {
            revert LendingOptimizer__TooManyMarkets();
        }
        if (_approvedCTokens.length == 0) {
            revert LendingOptimizer__InvalidParameter();
        }
        // Revert if constructor's arrays mismatch in length.
        if (_approvedCTokens.length != _allocationCapsBps.length) {
            revert LendingOptimizer__ArrayLengthMismatch();
        }
        // Revert if the performance fee is more than the allowed max.
        if (_feeBps > MAX_FEE_BPS) {
            revert LendingOptimizer__FeeTooHigh();
        }

        // Set essential storage slots.
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
            address cToken = _approvedCTokens[i];

            // Revert if the cToken has already been added (duplicate check).
            if (allocationCaps[cToken] != 0) {
                revert LendingOptimizer__MarketAlreadyApproved();
            }

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
        if (totalAllocation < WAD) {
            revert LendingOptimizer__InsufficientAllocationCaps();
        }

        // Validate vesting period
        if (_vestingPeriod == 0 || _vestingPeriod > _MAXIMUM_VESTING_PERIOD) {
            revert LendingOptimizer__InvalidParameter();
        }
        vestingPeriod = _vestingPeriod;

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
        if (mintPaused != 0) {
            revert LendingOptimizer__AlreadyInitialized();
        }
        // Array length sanity check.
        if (targetMarket >= approvedCTokensList.length) {
            revert LendingOptimizer__MarketNotApproved();
        }

        // Transfer _BASE_UNDERLYING_RESERVE assets.
        uint256 assets = _BASE_UNDERLYING_RESERVE;
        SafeTransferLib.safeTransferFrom(address(_asset), msg.sender, address(this), assets);

        // Deposit into target market.
        address cToken = approvedCTokensList[targetMarket];
        _depositToMarket(cToken, assets, false);

        // Mint dead shares equal to actual assets tracked.
        // We use _totalAssets (set by _depositToMarket) rather than input assets
        // because cToken share rounding may cause the recoverable value to differ
        // slightly from the input. This ensures the initial exchange rate is exactly 1:1.
        uint256 shares = _totalAssets;
        _mint(address(0), shares);

        // Set mintPaused to 1 to indicate deposits are active.
        mintPaused = 1;

        // Initialize vesting state.
        _setLastVestingClaim(uint40(block.timestamp));

        emit Deposit(msg.sender, address(0), assets, shares);
    }

    /// @notice Standard ERC4626 deposit - deposits into optimal market.
    /// @param assets The amount of underlying assets to deposit.
    /// @param receiver The address to receive the minted shares.
    /// @return shares The amount of shares minted.
    function deposit(
        uint256 assets,
        address receiver
    ) public override nonReentrant returns (uint256 shares) {
        _checkMintPaused();
        _accrueIfNeeded();

        shares = previewDeposit(assets);
        _processDeposit(assets, shares, receiver, _getOptimalDepositMarket(assets));
    }

    /// @notice Deposits assets into a specific market and mints shares to receiver.
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
        if (!_isApprovedMarket(targetMarket)) {
            revert LendingOptimizer__MarketNotApproved();
        }
        _accrueIfNeeded();

        shares = previewDeposit(assets);
        _processDeposit(assets, shares, receiver, targetMarket);
    }

    /// @notice Standard ERC4626 mint - mints exact shares by depositing into optimal market.
    /// @param shares The amount of shares to mint.
    /// @param receiver The address to receive the minted shares.
    /// @return assets The amount of assets deposited.
    function mint(
        uint256 shares,
        address receiver
    ) public override nonReentrant returns (uint256 assets) {
        _accrueIfNeeded();
        _checkMintPaused();

        assets = previewMint(shares);
        _processDeposit(assets, shares, receiver, _getOptimalDepositMarket(assets));
    }

    /// @notice Mints exact shares by depositing into a specific market.
    /// @param shares The amount of shares to mint.
    /// @param receiver The address to receive the minted shares.
    /// @param targetMarket The address of the target cToken market to deposit into.
    /// @return assets The amount of assets deposited.
    function mint(
        uint256 shares,
        address receiver,
        address targetMarket
    ) external nonReentrant returns (uint256 assets) {
        _checkMintPaused();
        if (!_isApprovedMarket(targetMarket)) {
            revert LendingOptimizer__MarketNotApproved();
        }
        _accrueIfNeeded();

        assets = previewMint(shares);
        _processDeposit(assets, shares, receiver, targetMarket);
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
        _processWithdraw(assets, shares, receiver, owner, _getOptimalWithdrawalMarket(assets));
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
        if (!_isApprovedMarket(targetMarket)) {
            revert LendingOptimizer__MarketNotApproved();
        }
        _accrueIfNeeded();

        shares = previewWithdraw(assets);
        _processWithdraw(assets, shares, receiver, owner, targetMarket);
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
        _processWithdraw(assets, shares, receiver, owner, _getOptimalWithdrawalMarket(assets));
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
        if (!_isApprovedMarket(targetMarket)) {
            revert LendingOptimizer__MarketNotApproved();
        }
        _accrueIfNeeded();

        assets = previewRedeem(shares);
        _processWithdraw(assets, shares, receiver, owner, targetMarket);
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
    ///      After rebalancing, each market's allocation must not exceed its cap.
    /// @param actions Array of rebalance actions, one per approved market.
    function rebalance(RebalanceAction[] calldata actions) external nonReentrant {
        // Revert if the caller does not have harvester permissions.
        _hasHarvesterPermissions();

        // Update vesting data and accrue protocol's performance fee.
        _accrueIfNeeded();

        // Cache approved markets length.
        uint256 l = approvedCTokensList.length;
        // Revert if the actions array length does not match approved markets.
        if (actions.length != l) {
            revert LendingOptimizer__ArrayLengthMismatch();
        }

        // First pass: accrue all markets and process withdrawals.
        uint256 totalWithdrawals;
        for (uint256 i; i < l; ++i) {
            address expectedCToken = approvedCTokensList[i];

            // Revert if action cToken does not match expected market at index.
            if (address(actions[i].cToken) != expectedCToken) {
                revert LendingOptimizer__InvalidParameter();
            }

            // Process withdrawal if this action is a withdrawal with assets > 0.
            if (actions[i].assets > 0 && !actions[i].isDeposit) {
                totalWithdrawals += actions[i].assets;
                actions[i].cToken.withdraw(
                    actions[i].assets,
                    address(this),
                    address(this)
                );
            }
        }

        // Second pass: process deposits.
        // Use raw deposits since rebalance is a net-zero asset movement.
        uint256 totalDeposits;
        for (uint256 i; i < l; ++i) {
            // Process deposit if this action is a deposit with assets > 0.
            if (actions[i].assets > 0 && actions[i].isDeposit) {
                totalDeposits += actions[i].assets;
                _depositToMarket(address(actions[i].cToken), actions[i].assets, true);
            }
        }

        // Revert if withdrawals and deposits don't match.
        if (totalWithdrawals != totalDeposits) {
            revert LendingOptimizer__InvalidParameter();
        }

        // Calculate total assets for cap verification.
        // Interest is accrued in the for loop above.
        uint256 ta = totalAssets();

        // Verify allocation caps are respected after rebalance.
        if (ta > 0) {
            for (uint256 i; i < l; ++i) {
                address cToken = approvedCTokensList[i];

                // Calculate current allocation percentage for this market.
                uint256 marketAssets = _getMarketAssets(cToken);
                uint256 currentAllocation = FixedPointMathLib.mulDivUp(marketAssets, WAD, ta);

                // Revert if the market allocation exceeds its cap.
                if (currentAllocation > allocationCaps[cToken]) {
                    revert LendingOptimizer__AllocationExceedsCap();
                }
            }
        }

        emit Rebalanced(ta);
    }

    /// @notice Removes an approved market and reallocates its assets.
    /// @dev After removal, remaining market caps must sum to >= 100%. If not,
    ///      call `updateCap()` to increase a remaining market's cap before removal.
    /// @param indexRemove Index of the market to remove.
    /// @param removeActions Actions specifying how to reallocate assets.
    function removeApprovedAsset(
        uint256 indexRemove,
        RemoveAction[] calldata removeActions
    ) external nonReentrant {
        // Revert if the caller does not have market permissions.
        _hasMarketPermissions();

        uint256 l = approvedCTokensList.length;
        // Revert if there is only one market.
        if (l == 1) {
            revert LendingOptimizer__InvalidParameter();
        }
        // Revert if the index is out of bounds.
        if (indexRemove >= l) {
            revert LendingOptimizer__InvalidParameter();
        }

        // Cache the cToken to remove.
        IBorrowableCToken cTokenToRemove = IBorrowableCToken(approvedCTokensList[indexRemove]);

        // Validate remaining allocation caps sum to >= 100%.
        _validateAllocationCaps(address(cTokenToRemove), 0);

        // Update vesting data and accrue protocol's performance fee.
        _accrueIfNeeded();

        // Redeem all shares from the market being removed.
        uint256 assetsRedeemed = cTokenToRemove.redeem(
            cTokenToRemove.balanceOf(address(this)),
            address(this),
            address(this)
        );

        // Delete the allocation cap for the removed market.
        delete allocationCaps[address(cTokenToRemove)];

        // Reallocate redeemed assets to other approved markets.
        // Use `true` for `isRebalance` to signal not to update `_indexedTotalAssets`.
        uint256 assetsReallocated;
        for (uint256 i; i < removeActions.length; ++i) {
            address cTokenAddress = address(removeActions[i].cToken);

            // Revert if the reallocation target is not an approved market.
            if (!_isApprovedMarket(cTokenAddress)) {
                revert LendingOptimizer__MarketNotApproved();
            }

            // Deposit reallocation amount to the target market.
            uint256 reallocationAmount = removeActions[i].reallocationAmount;
            _depositToMarket(cTokenAddress, reallocationAmount, true);
            assetsReallocated += reallocationAmount;
        }

        // Revert if reallocated assets do not match redeemed assets.
        if (assetsReallocated != assetsRedeemed) {
            revert LendingOptimizer__AssetMismatch();
        }

        // Update approved markets list using swap and pop.
        uint256 lastIndex = approvedCTokensList.length - 1;
        if (indexRemove != lastIndex) {
            approvedCTokensList[indexRemove] = approvedCTokensList[lastIndex];
        }
        approvedCTokensList.pop();


        emit MarketRemoved(address(cTokenToRemove));
    }

    /// @notice Adds a new approved market for allocation.
    /// @dev Requires market permissions. The cToken must have matching
    ///      underlying asset and a registered market manager. Max 6 markets.
    /// @param newAsset Address of the cToken market to add.
    /// @param capBps Allocation cap in BPS. Stored as WAD internally.
    function addApprovedAsset(address newAsset, uint256 capBps) external {
        // Revert if the caller does not have market permissions.
        _hasMarketPermissions();

        // Revert if the new asset address is zero.
        if (newAsset == address(0)) {
            revert LendingOptimizer__InvalidParameter();
        }

        // Revert if the cap is zero or exceeds 100%.
        if (capBps == 0 || capBps > BPS) {
            revert LendingOptimizer__InvalidParameter();
        }

        // Revert if the market is already approved.
        if (_isApprovedMarket(newAsset)) {
            revert LendingOptimizer__MarketAlreadyApproved();
        }

        // Revert if adding would exceed maximum markets.
        if (approvedCTokensList.length >= MAX_MARKETS) {
            revert LendingOptimizer__TooManyMarkets();
        }

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
    function updateCap(address cToken, uint256 newCapBps) external {
        // Revert if the caller does not have market permissions.
        _hasMarketPermissions();

        // Revert if the market is not approved.
        if (!_isApprovedMarket(cToken)) {
            revert LendingOptimizer__MarketNotApproved();
        }

        // Revert if the new cap is zero or exceeds 100%.
        if (newCapBps > BPS || newCapBps == 0) {
            revert LendingOptimizer__InvalidParameter();
        }

        // Convert BPS to WAD and cache old cap.
        uint256 newCapWad = _bpsToWad(newCapBps);
        uint256 oldCap = allocationCaps[cToken];

        // If decreasing cap, validate total caps still >= 100%.
        if (newCapWad < oldCap) {
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
    function setFee(uint256 newFeeBps) external {
        // Revert if the caller does not have market permissions.
        _hasMarketPermissions();

        // Accrue fees on existing profits.
        _accrueIfNeeded();

        // If enabling fees from 0, update watermark to current rate
        // so fees only apply to future yield.
        if (fee == 0 && newFeeBps > 0) {
            uint256 supply = totalSupply();
            if (supply > 0) {
                exchangeRateHighWatermark = FixedPointMathLib.mulDiv(
                    WAD,
                    totalAssets(),
                    supply
                );
            }
        }

        // Revert if the new fee exceeds the maximum allowed (50%).
        if (newFeeBps > MAX_FEE_BPS) {
            revert LendingOptimizer__FeeTooHigh();
        }

        // Update the fee.
        fee = newFeeBps;

        emit FeeUpdated(newFeeBps);
    }

    /// @notice Pauses or unpauses deposits. Emits an {ActionPaused} event.
    /// @dev Requires market permissions.
    /// @param state True to pause, false to unpause.
    function setMintPaused(bool state) external {
        _hasMarketPermissions();

        // Cannot pause or unpause if not initialized.
        if (mintPaused == 0) {
            revert LendingOptimizer__NotInitialized();
        }

        mintPaused = state ? 2 : 1; // 2 = paused; 1 = active.

        emit ActionPaused("Mint Paused", state);
    }


    /// @notice Accrues interest, vests yield, charges fees, and returns exchange rate.
    /// @dev Triggers full state update: accrues underlying markets, vests pending
    ///      yield, and charges performance fees if rate exceeds watermark.
    /// @return Current exchange rate in WAD (1e18 = 1:1). Returns WAD if no supply.
    function exchangeRateUpdated() public nonReentrant returns (uint256) {
        uint256 supply = totalSupply();

        if (supply == 0) return WAD;

        // Accrue yield from underlying markets and vest new yield.
        _accrueIfNeeded();

        return FixedPointMathLib.mulDiv(WAD, totalAssets(), supply);
    }

    /// @notice Accrues yield from underlying markets and vests new yield.
    function accrueIfNeeded() external nonReentrant {
        _accrueIfNeeded();
    }

    /// VIEW FUNCTIONS ///

    /// @notice Finds the optimal market for depositing assets.
    /// @dev Uses previewAssetImpact() to find market with highest projected rate after deposit.
    ///      The algorithm prioritizes markets that:
    ///      1. Have remaining allocation cap headroom.
    ///      2. Would yield the highest supply rate after the deposit.
    /// @param assets Amount of assets to deposit.
    /// @return targetIndex Index of the optimal target market.
    function optimalDepositTarget(uint256 assets) public view returns (uint256 targetIndex) {
        // Cache the number of approved markets.
        uint256 l = approvedCTokensList.length;

        // Revert if there are no approved markets.
        if (l == 0) revert LendingOptimizer__MarketNotApproved();

        // Revert if deposits are paused.
        _checkMintPaused();

        // Get total assets currently held across all markets.
        uint256 ta = totalAssets();

        // If only one market exists, return index 0 immediately.
        if (l == 1) return 0;

        // Calculate the new total assets after the deposit.
        // This is used to compute allocation percentages against caps.
        uint256 newTotal = ta + assets;

        // Track the highest projected supply rate found across viable markets.
        uint256 maxProjectedRate;

        // Flag to track if any market has cap headroom for the deposit.
        bool foundViable;

        // Iterate through all approved markets to find the optimal target.
        for (uint256 i; i < l; ++i) {
            // Cache the cToken address for this market.
            address cTokenAddr = approvedCTokensList[i];

            // Calculate the current assets held by this optimizer in the market.
            uint256 marketAssets = _getMarketAssets(cTokenAddr);

            // Get the allocation cap for this market (in WAD, 1e18 = 100%).
            uint256 cap = allocationCaps[cTokenAddr];

            // Calculate the maximum assets this market can hold based on its cap.
            // maxAllocation = (cap * newTotal) / WAD
            uint256 maxAllocation = FixedPointMathLib.mulDiv(cap, newTotal, WAD);

            // Only consider markets that have remaining allocation headroom.
            // If maxAllocation <= marketAssets, the market is at or over its cap.
            if (maxAllocation > marketAssets) {
                // Mark that we found at least one viable market.
                foundViable = true;

                // Calculate the projected supply rate after depositing `assets`
                // into this market using the market's interest rate model.
                uint256 projectedRate = previewAssetImpact(
                    IBorrowableCToken(cTokenAddr),
                    assets,
                    true
                );

                // Update the target if this market offers a higher projected rate.
                if (projectedRate > maxProjectedRate) {
                    maxProjectedRate = projectedRate;
                    targetIndex = i;
                }
            }
        }

        // If no market has cap headroom, fall back to the first market.
        // This allows deposits to proceed even when all markets are at capacity,
        // though the allocation cap check will occur during rebalancing.
        if (!foundViable) {
            targetIndex = 0;
        }
    }

    /// @notice Finds the optimal market for withdrawing assets.
    /// @dev Uses previewAssetImpact() to find market with lowest projected rate after withdrawal.
    ///      The algorithm prioritizes markets that:
    ///      1. Have sufficient liquidity to fulfill the withdrawal.
    ///      2. Would have the lowest supply rate after the withdrawal (weakest performer).
    ///      This strategy preserves capital in higher-yielding markets.
    /// @param assets Amount of assets to withdraw.
    /// @return targetIndex Index of the optimal target market.
    function optimalWithdrawalTarget(uint256 assets) public view returns (uint256 targetIndex) {
        // Cache the number of approved markets.
        uint256 l = approvedCTokensList.length;

        // Revert if there are no approved markets.
        if (l == 0) revert LendingOptimizer__MarketNotApproved();

        // Revert if deposits are paused.
        _checkMintPaused();

        // If only one market exists, return index 0 immediately.
        if (l == 1) return 0;

        // Track the lowest projected supply rate found across viable markets.
        // Initialize to max uint256 so any valid rate will be lower.
        uint256 minProjectedRate = type(uint256).max;

        // Flag to track if any market has sufficient liquidity for the withdrawal.
        bool foundViable;

        // Iterate through all approved markets to find the optimal target.
        for (uint256 i; i < l; ++i) {
            // Cache the cToken interface for this market.
            IBorrowableCToken cToken = IBorrowableCToken(approvedCTokensList[i]);

            // Calculate the current assets held by this optimizer in the market.
            uint256 marketAssets = cToken.convertToAssets(cToken.balanceOf(address(this)));

            // Only consider markets that meet both conditions:
            // 1. The optimizer has enough cTokens to cover the withdrawal.
            // 2. The market has enough idle liquidity (assets not lent out).
            if (marketAssets >= assets && cToken.assetsHeld() >= assets) {
                // Mark that we found at least one viable market.
                foundViable = true;

                // Calculate the projected supply rate after withdrawing `assets`
                // from this market using the market's interest rate model.
                uint256 projectedRate = previewAssetImpact(cToken, assets, false);

                // Update the target if this market has a lower projected rate.
                // Withdrawing from the weakest performer preserves yield in
                // higher-performing markets, optimizing overall returns.
                if (projectedRate < minProjectedRate) {
                    minProjectedRate = projectedRate;
                    targetIndex = i;
                }
            }
        }

        // Revert if no market has sufficient liquidity for the withdrawal.
        // This prevents partial withdrawals that would require multiple markets.
        if (!foundViable) {
            revert LendingOptimizer__InsufficientLiquidity();
        }
    }

    /// @notice Returns total assets held across all approved markets.
    /// @dev Unlike totalAssetsUpdated(), this does not trigger interest accrual.
    ///      The returned value may be slightly stale if markets haven't been
    ///      accrued recently.
    /// @return ta The total assets held by the optimizer across all markets.
    function totalAssets() public view override returns (uint256) {
        return _totalAssets + _assetsToVest();
    }

    /// @notice Returns current exchange rate (view function).
    /// @dev Unlike exchangeRateUpdated(), this does not trigger interest accrual.
    ///      The returned rate may be slightly stale if markets haven't been
    ///      accrued recently.
    /// @return The current exchange rate in WAD (1e18 = 1:1 ratio).
    function exchangeRate() public view nonReadReentrant returns (uint256) {
        // Cache the total supply of optimizer shares.
        uint256 supply = totalSupply();

        // If no shares exist, return 1:1 exchange rate (WAD).
        if (supply == 0) return WAD;

        // Calculate and return the exchange rate.
        // exchangeRate = (WAD * totalAssets) / totalSupply
        return FixedPointMathLib.mulDiv(WAD, totalAssets(), supply);
    }

    /// @notice Calculates the projected supply rate for a market after a deposit or withdrawal.
    /// @dev Modified version of previewAssetImpact for optimizer use.
    ///      Returns type(uint256).max if the market has insufficient liquidity for a withdrawal,
    ///      which signals that the market should not be selected for withdrawals.
    /// @param cToken The market to calculate impact for.
    /// @param assets The amount of assets being deposited or withdrawn.
    /// @param isDeposit True for deposit, false for withdrawal.
    /// @return projectedRate The projected supply rate after the action, in WAD per second.
    function previewAssetImpact(
        IBorrowableCToken cToken,
        uint256 assets,
        bool isDeposit
    ) public view returns (uint256 projectedRate) {
        // Get current idle assets held in the market (not lent out).
        uint256 currentAssetsHeld = cToken.assetsHeld();
        uint256 projectedAssetsHeld;

        // Calculate projected assets after the action.
        if (isDeposit) {
            projectedAssetsHeld = currentAssetsHeld + assets;
        } else {
            // If market doesn't have enough liquidity, return max uint256 to signal
            // this market is not viable for withdrawals of this size.
            // This ensures it won't be selected in optimalWithdrawalTarget
            // (which picks the lowest rate).
            if (assets > currentAssetsHeld) {
                return type(uint256).max;
            }
            projectedAssetsHeld = currentAssetsHeld - assets;
        }
        
        // Get current outstanding debt in the market.
        uint256 debt = cToken.marketOutstandingDebt();

        // Calculate projected supply rate using the market's IRM.
        projectedRate = cToken.IRM().supplyRate(
            projectedAssetsHeld,
            debt,
            cToken.interestFee()
        );
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
        result = interfaceId == type(IPluginDelegable).interfaceId ||
            interfaceId == type(ERC4626).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// INTERNAL FUNCTIONS ///

    /// @dev Accrues interest on all markets and returns total assets.
    function _accrueMarkets() internal returns (uint256 ta) {
        uint256 l = approvedCTokensList.length;
        for (uint256 i; i < l; ++i) {
            address cToken = approvedCTokensList[i];
            IBorrowableCToken(cToken).accrueIfNeeded();
            ta += _getMarketAssets(cToken);
        }
    }

    /// @dev Deposits assets into a specific market with proper approval handling.
    /// @param cToken The market to deposit into.
    /// @param assets The amount of assets to deposit.
    /// @param isRebalance If true, skips updating _indexedTotalAssets (for net-zero
    ///                    asset movements like rebalancing and reallocation).
    function _depositToMarket(
        address cToken,
        uint256 assets,
        bool isRebalance
    ) internal {
        SwapperLib._approveIfNeeded(address(_asset), cToken, assets);

        IBorrowableCToken cToken_ = IBorrowableCToken(cToken);

        uint256 sharesReceived = cToken_.deposit(assets, address(this));

        if (!isRebalance) {
            // Track the actual recoverable value of shares received, not the input amount.
            // cToken share math involves two rounding operations (assets→shares, shares→assets)
            // which can cause a 1 wei difference between input and recoverable value.
            // Using convertToAssets ensures _totalAssets stays in sync with what
            // _accrueMarkets() reports, preventing false bad debt detection.
            _totalAssets += cToken_.convertToAssets(sharesReceived);
        }
    }

    /// @dev Withdraws assets from a specific market.
    ///      Updates _totalAssets for user withdrawals.
    function _withdrawFromMarket(address cToken, uint256 assets) internal {
        IBorrowableCToken(cToken).withdraw(assets, address(this), address(this));
        _totalAssets -= assets;
    }

    /// @dev Core deposit logic shared by deposit() and mint() variants.
    /// @param assets The amount of assets to deposit.
    /// @param shares The amount of shares to mint.
    /// @param receiver The address to receive the minted shares.
    /// @param targetMarket The target cToken market to deposit into.
    function _processDeposit(
        uint256 assets,
        uint256 shares,
        address receiver,
        address targetMarket
    ) internal {
        SafeTransferLib.safeTransferFrom(address(_asset), msg.sender, address(this), assets);
        _depositToMarket(targetMarket, assets, false);
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @dev Core withdraw logic shared by withdraw() and redeem() variants.
    /// @param assets The amount of assets to withdraw.
    /// @param shares The amount of shares to burn.
    /// @param receiver The address to receive the withdrawn assets.
    /// @param owner The address that owns the shares being burned.
    /// @param targetMarket The target cToken market to withdraw from.
    function _processWithdraw(
        uint256 assets,
        uint256 shares,
        address receiver,
        address owner,
        address targetMarket
    ) internal {
        _updateAllowance(owner, shares);
        _burn(owner, shares);
        _withdrawFromMarket(targetMarket, assets);
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
        if (totalCaps < WAD) {
            revert LendingOptimizer__InsufficientAllocationCaps();
        }

    }

    /// @dev Converts BPS to WAD (e.g., 1000 BPS = 0.1 WAD = 10%).
    function _bpsToWad(uint256 bps) internal pure returns (uint256) {
        return bps * 1e14;
    }

    /// @dev Returns optimizer's assets held in a specific market.
    function _getMarketAssets(address cToken) internal view returns (uint256) {
        return IBorrowableCToken(cToken).convertToAssets(
            IBorrowableCToken(cToken).balanceOf(address(this))
        );
    }

    /// @dev Validates cToken has correct underlying and registered market manager.
    function _validateCToken(address cToken) internal view {
        if (IBorrowableCToken(cToken).asset() != address(_asset)) {
            revert LendingOptimizer__InvalidUnderlying();
        }
        if (!centralRegistry.isMarketManager(
            address(IBorrowableCToken(cToken).marketManager())
        )) {
            revert LendingOptimizer__InvalidMarketManager();
        }
    }

    function _isApprovedMarket(address market) internal view returns (bool) {
        if(allocationCaps[market] == 0) {
            return false;
        }
        return true;
    }

    /// @notice Updates the allowance for the caller.
    /// @param owner The owner of the allowance.
    /// @param amount The spent amount of the allowance.
    function _updateAllowance(address owner, uint256 amount) internal {
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, amount);
        }
    }

    /// @dev Synchronizes optimizer state: vests pending yield, detects new yield
    ///      from underlying markets, and accrues performance fees.
    ///
    ///      Vesting Mechanism
    ///      Yield is smoothed over `vestingPeriod` to prevent frontrunning attacks
    ///      where users deposit before yield accrues and withdraw immediately after.
    ///      Pending vested assets are checkpointed on each call.
    ///
    ///      New yield from underlying markets is only detected when the current
    ///      vesting period ends. This prevents overlapping vesting periods.
    ///
    ///      Performance Fees
    ///      Fees are charged on vested yield only (not unvested).
    ///      The high watermark ensures fees are only charged on new all-time-high
    ///      profits, preventing double-charging after drawdowns.
    function _accrueIfNeeded() internal {
        // Get actual assets from underlying markets (triggers underlying interest accrual).
        uint256 rawTa = _accrueMarkets();

        // If rawTa < totalAssets + pending vested assets, bad debt detected.
        if (rawTa < totalAssets()) {
            // Bad debt detected, update _totalAssets immediately.
            _totalAssets = rawTa;
            _vestingData = 0;
            return;
        }

        // Only gate new yield detection behind vesting period.
        if (!_checkVestingFinished(_vestingData)) {
            return;
        }

        // Calculate pending vested assets.
        uint256 assetsToVest = _assetsToVest();

        // Vest pending assets, if there is any.
        if (assetsToVest > 0) {
            // Update the lastVestingClaim timestamp.
            _setLastVestingClaim(uint40(block.timestamp));

            // Update _totalAssets invariant with vested assets added.
            _totalAssets += assetsToVest;
        }

        // Check for new yield from underlying markets.
        // If rawTa > _totalAssets, the difference is new yield to vest.
        if (rawTa > _totalAssets) {
            uint256 newYield = rawTa - _totalAssets;
            _setVestingData(newYield);
        }

        // Fees are charged on vested yield only, based on exchange rate vs watermark.
        // If no fee is configured, exit immediately.
        if (fee == 0) return;

        // Cache the total supply of optimizer shares.
        uint256 supply = totalSupply();

        // Skip if no shares exist (nothing to charge fees on).
        if (supply == 0) return;

        // Get total assets (indexed + pending vest from new vesting period).
        uint256 currentAssets = totalAssets();

        // Calculate the current exchange rate.
        // currentRate = (WAD * currentAssets) / supply
        uint256 currentRate = FixedPointMathLib.mulDiv(WAD, currentAssets, supply);

        // Cache the high watermark exchange rate.
        uint256 highRate = exchangeRateHighWatermark;

        // Only charge fees if we've exceeded the previous all-time-high rate.
        // This prevents double-charging after losses recover.
        if (currentRate <= highRate) return;

        // Calculate profit above the watermark in asset terms.
        uint256 highAssets = FixedPointMathLib.mulDiv(highRate, supply, WAD);

        // Calculate the profit above the high watermark.
        uint256 profit = currentAssets - highAssets;

        // Calculate the fee amount in assets (rounds up to favor protocol).
        // feeAssets = (profit * fee) / WAD
        uint256 feeAssets = FixedPointMathLib.mulDivUp(profit, _bpsToWad(fee), WAD);

        // If fee rounds to zero, just update the watermark and return.
        if (feeAssets == 0) {
            exchangeRateHighWatermark = currentRate;
            return;
        }

        // Calculate shares to mint to the DAO for the fee.
        // Uses the formula: feeShares = (feeAssets * supply) / (currentAssets - feeAssets)
        // This ensures the DAO receives shares worth exactly feeAssets.
        uint256 feeShares = FixedPointMathLib.fullMulDivUp(
            feeAssets,
            supply,
            currentAssets - feeAssets
        );

        // Get the DAO address from the central registry.
        address dao = centralRegistry.daoAddress();

        // Mint fee shares to the DAO.
        _mint(dao, feeShares);

        // Calculate and store the new high watermark exchange rate.
        // This accounts for the dilution from minting fee shares.
        uint256 sAfter = supply + feeShares;
        uint256 rAfter = FixedPointMathLib.mulDiv(WAD, currentAssets, sAfter);

        // Update the high watermark to the new exchange rate.
        exchangeRateHighWatermark = rAfter;

        emit PerformanceFeeAccrued(feeShares, dao);
    }

    /// @dev Calculates pending assets to vest based on elapsed time
    function _assetsToVest(
        uint256 vestingRate,
        uint256 vestingEnd,
        uint256 lastVestingClaim
    ) internal view returns (uint256 assets) {
        // Check whether there are pending yield vesting.
        if (vestingRate > 0 && lastVestingClaim < vestingEnd) {
            // When calculating pending assets to vest, if the vesting period
            // has not ended:
            // assets = vestingRate * (block.timestamp - lastVestingClaim).
            // If the vesting period has ended:
            // assets = vestingRate * (vestingEnd - lastVestingClaim).
            // Then in either case:
            // Divide the pending yield by `WAD` (1e18) for precision.
            assets =
                (
                    block.timestamp < vestingEnd
                        ? vestingRate * (block.timestamp - lastVestingClaim)
                        : vestingRate * (vestingEnd - lastVestingClaim)
                ) / WAD;
        }
    }

    /// @notice Calculates pending assets that have been vested.
    /// @dev If there are no pending assets or the vesting period has ended,
    ///      it returns 0.
    /// @return assets The calculated pending assets to vest.
    function _assetsToVest() internal view returns (uint256 assets) {
        // Cache `_vestingData`, the packed vesting data storage value.
        uint256 vestingData = _vestingData;
        assets =  _assetsToVest(
            uint176(vestingData),
            uint40(vestingData >> _BITPOS_VEST_END),
            uint40(vestingData >> _BITPOS_LAST_VEST)
        );
    }

    /// @dev Returns true if deposits are paused.
    function _checkMintPaused() internal view {
        if (mintPaused != 1) {
            revert LendingOptimizer__MintPaused();
        }
    }

    function _getOptimalDepositMarket(uint256 assets) internal view returns (address) {
        return approvedCTokensList[optimalDepositTarget(assets)];
    }

    function _getOptimalWithdrawalMarket(uint256 assets) internal view returns (address) {
        return approvedCTokensList[optimalWithdrawalTarget(assets)];
    }

    /// @dev Sets vesting schedule for new yield.
    function _setVestingData(uint256 assetsToVest) internal {
        // Cache `vestingPeriod`, the vesting period of harvested assets.
        uint256 period = vestingPeriod;

        // Set `VESTING_RATE` equal to `assetsToVest` prorated over
        // `vestingPeriod`, in `WAD` (1e18).
        uint256 rate =
            FixedPointMathLib.mulDiv(assetsToVest, WAD, period);
        uint256 newVestingEnd = block.timestamp + period;
        
        // Reuse `period` as a temporary variable to store the newly packed
        // `_vestingData` storage value.
        assembly {
            // Mask `rate` to the lower 176 bits, in case the upper bits
            // somehow are not clean.
            rate := and(rate, _BITMASK_VESTING_RATE)
            // Equals `rate | (newVestingEnd << _BITPOS_VEST_END) |
            //         block.timestamp`.
            period := or(
                rate,
                or(
                    shl(_BITPOS_VEST_END, newVestingEnd),
                    shl(_BITPOS_LAST_VEST, timestamp())
                )
            )
            // Update packed `_vestingData` based on new vesting config.
            sstore(_vestingData.slot, period)
        }
    }

    /// @dev Updates lastVestingClaim timestamp.
    function _setLastVestingClaim(uint40 newVestClaim) internal {
        // Cache `_vestingData`, the packed vesting data storage value.
        uint256 vestingData = _vestingData;

        assembly {
            // Mask `vestingData` to the lower 216 bits, to wipe out previous
            // `LAST_VEST` timestamp so we can simply shift newVestClaim left.
            vestingData := or(
                and(vestingData, _BITMASK_LAST_VEST_COMPLEMENT),
                shl(_BITPOS_LAST_VEST, newVestClaim)
            )
            // Update packed `_vestingData` with new last vesting timestamp.
            sstore(_vestingData.slot, vestingData)
        }
    }

    /// @notice Returns whether the current vesting period has ended,
    ///         based on the last vest timestamp.
    /// @param vestingData Current packed vault data value.
    /// @return result Boolean value indicating whether the current
    ///                vesting period has ended or not.
    function _checkVestingFinished(
        uint256 vestingData
    ) internal pure returns (bool result) {
        result =  uint40(vestingData >> _BITPOS_LAST_VEST) >=
            uint40(vestingData >> _BITPOS_VEST_END);
    }

    /// @notice Returns the underlying token decimals.
    function _underlyingDecimals() internal view override returns (uint8) {
        return _decimals;
    }

    /// @notice Returns the decimals offset for virtual shares.
    /// @dev No offset used - inflation protection via initializeDeposits dead shares.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 0;
    }

    /// @notice Returns false - no virtual shares, use dead shares instead.
    function _useVirtualShares() internal pure override returns (bool) {
        return false;
    }

    /// @dev Checks if caller has harvester permissions.
    function _hasHarvesterPermissions() internal view {
        if (!centralRegistry.hasHarvestPermissions(msg.sender)) {
            revert LendingOptimizer__Unauthorized();
        }
    }

    /// @dev Checks if caller has market permissions.
    function _hasMarketPermissions() internal view {
        if (!centralRegistry.hasMarketPermissions(msg.sender)) {
            revert LendingOptimizer__Unauthorized();
        }
    }
}
