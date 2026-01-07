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

/// @title LendingOptimizer
/// @notice Optimizes yield across multiple Curvance lending markets for a single underlying asset.
/// @dev Similar to ERC4626 but with multi-market allocation support.
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

    /// EVENTS ///

    event MarketAdded(address indexed cToken, uint256 allocationCap);
    event MarketRemoved(address indexed cToken);
    event AllocationCapUpdated(address indexed cToken, uint256 newCap);
    event FeeUpdated(uint256 newFee);
    event Rebalanced(uint256 totalAssets);
    event PerformanceFeeAccrued(uint256 feeShares, address indexed recipient);

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
        _symbol = string.concat("c", asset_.symbol(), " OPTI");
        _decimals = asset_.decimals();
        // Store fee as WAD.
        fee = _feeBps * 1e14;

        // Counter to find the sum of all allocation amounts.
        uint256 totalAllocation;

        // Loop through all cTokens and validate.
        for (uint256 i; i < _approvedCTokens.length; ++i) {
            address cToken = _approvedCTokens[i];

            // Revert if the cToken has already been added (duplicate check).
            if (allocationCaps[cToken] != 0) {
                revert LendingOptimizer__MarketAlreadyApproved();
            }

            // Revert if the provided cToken's underlying asset does not
            //      match the optimizer's underlying asset.
            if (IBorrowableCToken(cToken).asset() != address(asset_)) {
                revert LendingOptimizer__InvalidUnderlying();
            }
            // Revert if the provided cToken's MarketManager is not registered.
            if (!centralRegistry.isMarketManager(
                address(IBorrowableCToken(cToken).marketManager())
            )) {
                revert LendingOptimizer__InvalidMarketManager();
            }

            // Convert cap from BPS to WAD (multiply by 1e14)
            uint256 alloCapWAD = _allocationCapsBps[i] * 1e14;
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
        // Revert if the market has already been initialized.
        if (totalSupply() != 0) {
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

        // Mint dead shares to address(0).
        uint256 shares = assets;
        _mint(address(0), shares);

        // Initialize vesting state.
        _setLastVestingClaim(uint40(block.timestamp));

        emit Deposit(msg.sender, address(0), assets, shares);
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
        // Revert if deposits have not been initialized.
        if (totalSupply() == 0) {
            revert LendingOptimizer__NotInitialized();
        }
        // Revert if the target market is not approved.
        if (allocationCaps[targetMarket] == 0) {
            revert LendingOptimizer__MarketNotApproved();
        }

        // Update vesting data and accrue protocol's performance fee.
        _accrueIfNeeded();

        // Get shares to be minted by using `previewDeposit()`.
        shares = previewDeposit(assets);

        // Transfer assets to the optimizer.
        SafeTransferLib.safeTransferFrom(address(_asset), msg.sender, address(this), assets);

        // Deposit assets to the specified target market.
        _depositToMarket(targetMarket, assets, false);

        // Mint user shares.
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Standard ERC4626 deposit - deposits into optimal market.
    /// @param assets The amount of underlying assets to deposit.
    /// @param receiver The address to receive the minted shares.
    /// @return shares The amount of shares minted.
    function deposit(
        uint256 assets,
        address receiver
    ) public override nonReentrant returns (uint256 shares) {
        // Update vesting data and accrue protocol's performance fee.
        _accrueIfNeeded();

        // Get shares to be minted by using `previewDeposit()`.
        shares = previewDeposit(assets);

        // Transfer assets to the optimizer.
        SafeTransferLib.safeTransferFrom(address(_asset), msg.sender, address(this), assets);

        // Get the optimal deposit target market with the highest yield and cap headroom.
        uint256 targetMarket = optimalDepositTarget(assets);

        // Deposit assets to the optimal target market.
        address cToken = approvedCTokensList[targetMarket];
        _depositToMarket(cToken, assets, false);

        // Mint user shares.
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Standard ERC4626 mint - mints exact shares by depositing into optimal market.
    /// @param shares The amount of shares to mint.
    /// @param receiver The address to receive the minted shares.
    /// @return assets The amount of assets deposited.
    function mint(
        uint256 shares,
        address receiver
    ) public override nonReentrant returns (uint256 assets) {
        // Update vesting data and accrue protocol's performance fee.
        _accrueIfNeeded();
        
        // Get assets to be deposited by using `previewMint()`.
        assets = previewMint(shares);

        // Transfer assets to the optimizer.
        SafeTransferLib.safeTransferFrom(address(_asset), msg.sender, address(this), assets);

        // Get the optimal deposit target market with the highest yield and cap headroom.
        uint256 targetMarket = optimalDepositTarget(assets);

        // Deposit assets to the optimal target market.
        address cToken = approvedCTokensList[targetMarket];
        _depositToMarket(cToken, assets, false);

        // Mint user shares.
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
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
        // Revert if deposits have not been initialized.
        if (totalSupply() == 0) {
            revert LendingOptimizer__NotInitialized();
        }
        // Revert if the target market is not approved.
        if (allocationCaps[targetMarket] == 0) {
            revert LendingOptimizer__MarketNotApproved();
        }

        // Update vesting data and accrue protocol's performance fee.
        _accrueIfNeeded();

        // Get assets to be deposited by using `previewMint()`.
        assets = previewMint(shares);

        // Transfer assets to the optimizer.
        SafeTransferLib.safeTransferFrom(address(_asset), msg.sender, address(this), assets);

        // Deposit assets to the specified target market.
        _depositToMarket(targetMarket, assets, false);

        // Mint user shares.
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
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
        // Update vesting data and accrue protocol's performance fee.
        _accrueIfNeeded();

        // Get shares to be withdrawn by using `previewWithdraw()`.
        shares = previewWithdraw(assets);

        // Revert if there is insufficient allowance.
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        // Burn owner shares when withdrawing.
        _burn(owner, shares);

        // Get the optimal withdrawal target market with the lowest yield. 
        uint256 targetMarket = optimalWithdrawalTarget(assets);
        address cToken = approvedCTokensList[targetMarket];
        _withdrawFromMarket(cToken, assets);

        // Transfer assets to the `receiver`.
        SafeTransferLib.safeTransfer(address(_asset), receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
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
        // Revert if the target market is not approved.
        if (allocationCaps[targetMarket] == 0) {
            revert LendingOptimizer__MarketNotApproved();
        }

        // Update vesting data and accrue protocol's performance fee.
        _accrueIfNeeded();

        // Get shares to be redeemed by using `previewWithdraw()`.
        shares = previewWithdraw(assets);

        // Revert if the caller does not have sufficient allowance.
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        // Burn owner shares when withdrawing.
        _burn(owner, shares);

        // Withdraw assets from the specified target market.
        _withdrawFromMarket(targetMarket, assets);

        // Transfer assets to the `receiver`.
        SafeTransferLib.safeTransfer(address(_asset), receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
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
        // Update vesting data and accrue protocol's performance fee.
        _accrueIfNeeded();

        // Get assets to be withdrawn by using `previewRedeem()`.
        assets = previewRedeem(shares);

        // Revert if the caller has insufficient allowance.
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        // Burn owner shares when redeeming.
        _burn(owner, shares);

        // Get the optimal withdrawal target market with the lowest yield. 
        uint256 targetMarket = optimalWithdrawalTarget(assets);
        address cToken = approvedCTokensList[targetMarket];
        _withdrawFromMarket(cToken, assets);

        // Transfer assets to the `receiver`.
        SafeTransferLib.safeTransfer(address(_asset), receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
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
        // Revert if the target market is not approved.
        if (allocationCaps[targetMarket] == 0) {
            revert LendingOptimizer__MarketNotApproved();
        }

        // Update vesting data and accrue protocol's performance fee.
        _accrueIfNeeded();

        // Get assets to be withdrawn by using `previewRedeem()`.
        assets = previewRedeem(shares);

        // Revert if the caller has insufficient allowance.
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        // Burn owner shares when redeeming.
        _burn(owner, shares);

        // Withdraw assets from specified market.
        _withdrawFromMarket(targetMarket, assets);

        // Transfer assets to the `receiver`.
        SafeTransferLib.safeTransfer(address(_asset), receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /// @notice Rebalances assets across markets.
    /// @dev Withdrawals are processed first, then deposits.
    /// @param actions Array of rebalance actions (must match approved markets length).
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
        for (uint256 i; i < l; ++i) {
            address expectedCToken = approvedCTokensList[i];

            // Revert if action cToken does not match expected market at index.
            if (address(actions[i].cToken) != expectedCToken) {
                revert LendingOptimizer__InvalidParameter();
            }

            // Revert if the market is not approved (cap == 0).
            if (allocationCaps[expectedCToken] == 0) {
                revert LendingOptimizer__MarketNotApproved();
            }

            // Process withdrawal if this action is a withdrawal with assets > 0.
            if (actions[i].assets > 0 && !actions[i].isDeposit) {
                actions[i].cToken.withdraw(
                    actions[i].assets,
                    address(this),
                    address(this)
                );
            }
        }

        // Second pass: process deposits and track last deposit market for dust.
        // Use raw deposits since rebalance is a net-zero asset movement.
        address lastDepositMarket;
        for (uint256 i; i < l; ++i) {
            // Process deposit if this action is a deposit with assets > 0.
            if (actions[i].assets > 0 && actions[i].isDeposit) {
                lastDepositMarket = address(actions[i].cToken);
                _depositToMarket(lastDepositMarket, actions[i].assets, true);
            }
        }

        // Deposit any remaining dust to a market.
        uint256 remainingDust = _asset.balanceOf(address(this));
        if (remainingDust > 0) {
            // If there was a deposit action, use that market for dust.
            // Otherwise, fall back to the first approved market.
            address dustTarget = lastDepositMarket != address(0)
                ? lastDepositMarket
                : approvedCTokensList[0];
            _depositToMarket(dustTarget, remainingDust, true);
        }

        // Calculate total assets for cap verification.
        // Interest is accrued in the for loop above.
        uint256 ta = totalAssets();

        // Verify allocation caps are respected after rebalance.
        if (ta > 0) {
            for (uint256 i; i < l; ++i) {
                address cToken = approvedCTokensList[i];

                // Calculate current allocation percentage for this market.
                uint256 marketAssets = IBorrowableCToken(cToken).convertToAssets(
                    IBorrowableCToken(cToken).balanceOf(address(this))
                );
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
        // Update vesting data and accrue protocol's performance fee.
        _accrueIfNeeded();

        // Cache the cToken to remove.
        IBorrowableCToken cTokenToRemove = IBorrowableCToken(approvedCTokensList[indexRemove]);

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
            if (allocationCaps[cTokenAddress] == 0) {
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

        // Validate remaining allocation caps sum to >= 100%.
        _validateAllocationCaps();

        emit MarketRemoved(address(cTokenToRemove));
    }

    /// @notice Adds a new approved market.
    /// @param newAsset Address of the new cToken market.
    /// @param capBps Allocation cap in BPS.
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
        if (allocationCaps[newAsset] > 0) {
            revert LendingOptimizer__MarketAlreadyApproved();
        }

        // Revert if adding would exceed maximum markets.
        if (approvedCTokensList.length >= MAX_MARKETS) {
            revert LendingOptimizer__TooManyMarkets();
        }

        // Cache the cToken for validation.
        IBorrowableCToken cToken = IBorrowableCToken(newAsset);

        // Revert if the cToken's underlying does not match optimizer's asset.
        if (cToken.asset() != address(_asset)) {
            revert LendingOptimizer__InvalidUnderlying();
        }

        // Revert if the cToken's market manager is not registered.
        if (!centralRegistry.isMarketManager(address(cToken.marketManager()))) {
            revert LendingOptimizer__InvalidMarketManager();
        }

        // Add market to approved list and set allocation cap.
        approvedCTokensList.push(newAsset);
        allocationCaps[newAsset] = capBps * 1e14;

        emit MarketAdded(newAsset, capBps * 1e14);
    }

    /// @notice Updates the allocation cap for a market.
    /// @param cToken Address of the cToken market.
    /// @param newCapBps New allocation cap in BPS.
    function updateCap(address cToken, uint256 newCapBps) external {
        // Revert if the caller does not have market permissions.
        _hasMarketPermissions();

        // Revert if the market is not approved.
        if (allocationCaps[cToken] == 0) {
            revert LendingOptimizer__MarketNotApproved();
        }

        // Revert if the new cap is zero or exceeds 100%.
        if (newCapBps > BPS || newCapBps == 0) {
            revert LendingOptimizer__InvalidParameter();
        }

        // Convert BPS to WAD and cache old cap.
        uint256 newCapWad = newCapBps * 1e14;
        uint256 oldCap = allocationCaps[cToken];

        // Update the allocation cap.
        allocationCaps[cToken] = newCapWad;

        // If decreasing cap, validate total caps still >= 100%.
        if (newCapWad < oldCap) {
            _validateAllocationCaps();
        }

        emit AllocationCapUpdated(cToken, newCapWad);
    }

    /// @notice Updates the performance fee.
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

        // Update the fee (convert BPS to WAD).
        fee = newFeeBps * 1e14;

        emit FeeUpdated(newFeeBps);
    }

    function exchangeRateUpdated() public nonReentrant returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return WAD;
        
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

        // Revert if deposits have not been initialized.
        if (totalSupply() == 0) {
            revert LendingOptimizer__NotInitialized();
        }

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
            // Cache the cToken interface for this market.
            IBorrowableCToken cToken = IBorrowableCToken(approvedCTokensList[i]);

            // Calculate the current assets held by this optimizer in the market.
            uint256 marketAssets = cToken.convertToAssets(cToken.balanceOf(address(this)));

            // Get the allocation cap for this market (in WAD, 1e18 = 100%).
            uint256 cap = allocationCaps[address(cToken)];

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
                uint256 projectedRate = previewAssetImpact(cToken, assets, true);

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

        // Revert if deposits have not been initialized.
        if (totalSupply() == 0) {
            revert LendingOptimizer__NotInitialized();
        }

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

        // Get total assets across all markets (without accruing).
        uint256 ta = totalAssets();

        // Calculate and return the exchange rate.
        // exchangeRate = (WAD * totalAssets) / totalSupply
        return FixedPointMathLib.mulDiv(WAD, ta, supply);
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
            ta += IBorrowableCToken(cToken).convertToAssets(
                IBorrowableCToken(cToken).balanceOf(address(this))
            );
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
        IBorrowableCToken(cToken).deposit(assets, address(this));
        if (!isRebalance) {
            _totalAssets += assets;
        }
    }

    /// @dev Withdraws assets from a specific market.
    ///      Updates _indexedTotalAssets for user withdrawals.
    function _withdrawFromMarket(address cToken, uint256 assets) internal {
        IBorrowableCToken(cToken).withdraw(assets, address(this), address(this));
        _totalAssets -= assets;
    }

    /// @dev Validates that total allocation caps sum to at least 100%.
    function _validateAllocationCaps() internal view {
        uint256 totalCaps;
        uint256 l = approvedCTokensList.length;

        for (uint256 i; i < l; ++i) {
            totalCaps += allocationCaps[approvedCTokensList[i]];
        }

        if (totalCaps < WAD) {
            revert LendingOptimizer__InsufficientAllocationCaps();
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
        // Calculate pending vested assets.
        uint256 assetsToVest = _assetsToVest();

        // Vest pending assets, if there is any.
        if (assetsToVest > 0) {
            // Update the lastVestingClaim timestamp.
            _setLastVestingClaim(uint40(block.timestamp));
            
            // Update _totalAssets invariant with vested assets added.
            _totalAssets += assetsToVest;
        }

        // Cache vesting data to check if vesting period has ended.
        uint256 vestingData = _vestingData;
        uint256 rate = uint176(vestingData);
        uint256 vestingEnd = uint40(vestingData >> _BITPOS_VEST_END);

        // Can only accrue once previous vesting period is done.
        if (rate > 0 && block.timestamp < vestingEnd) {
            return;
        }

        // Get actual assets from underlying markets (triggers interest accrual).
        uint256 rawTa = _accrueMarkets();

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
        uint256 feeAssets = FixedPointMathLib.mulDivUp(profit, fee, WAD);

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
