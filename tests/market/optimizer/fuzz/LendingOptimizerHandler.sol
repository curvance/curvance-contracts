// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LendingOptimizerHarness} from "../LendingOptimizerHarness.sol";
import {LendingOptimizer} from "contracts/market/optimizer/LendingOptimizer.sol";
import {IBorrowableCToken} from "contracts/interfaces/IBorrowableCToken.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {WAD} from "contracts/libraries/ConstantsLib.sol";

/// @title LendingOptimizerHandler
/// @notice Handler contract for Foundry stateful invariant testing of LendingOptimizer.
/// @dev Wraps optimizer actions with input bounding, ghost variable tracking,
///      and try/catch for expected reverts to keep the fuzzer running.
contract LendingOptimizerHandler is Test {
    LendingOptimizerHarness public optimizer;
    IERC20 public usdc;
    ICentralRegistry public centralRegistry;

    address[] public actors;
    address[] public markets;

    // Ghost variables for invariant checking.
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;
    mapping(address => uint256) public ghost_userDeposited;
    mapping(address => uint256) public ghost_userWithdrawn;
    uint256 public ghost_depositCount;
    uint256 public ghost_withdrawCount;
    uint256 public ghost_delegatedWithdrawCount;
    uint256 public ghost_rebalanceCount;
    uint256 public ghost_lastExchangeRate;
    uint256 public ghost_underlyingDonated;

    // Track total shares minted / burned for supply consistency checks.
    uint256 public ghost_totalSharesMinted;
    uint256 public ghost_totalSharesBurned;

    // Track share transfers for balance consistency checks.
    uint256 public ghost_transferCount;

    constructor(
        LendingOptimizerHarness _optimizer,
        IERC20 _usdc,
        ICentralRegistry _centralRegistry,
        address[] memory _actors
    ) {
        optimizer = _optimizer;
        usdc = _usdc;
        centralRegistry = _centralRegistry;
        actors = _actors;

        // Cache approved markets.
        uint256 numMarkets = _optimizer.numApprovedMarkets();
        for (uint256 i; i < numMarkets; ++i) {
            markets.push(_optimizer.approvedCTokensList(i));
        }

        // Record initial exchange rate.
        ghost_lastExchangeRate = WAD;
    }

    // ========================================================================
    // ACTIONS
    // ========================================================================

    /// @notice Deposit assets into the optimizer for a random actor.
    function deposit(uint256 actorSeed, uint256 assets, uint256) external {
        address actor = _selectActor(actorSeed);
        assets = bound(assets, 1e6, 10_000_000e6);

        deal(address(usdc), actor, assets);

        vm.startPrank(actor);
        usdc.approve(address(optimizer), assets);

        try optimizer.deposit(assets, actor) returns (uint256 shares) {
            ghost_totalDeposited += assets;
            ghost_userDeposited[actor] += assets;
            ghost_totalSharesMinted += shares;
            ghost_depositCount++;
        } catch {
            // Expected revert (e.g., cap exceeded, cToken rejection).
        }

        vm.stopPrank();
        _updateExchangeRate();
    }

    /// @notice Deposit assets into a selected optimizer market.
    function depositToMarket(uint256 actorSeed, uint256 assets, uint256 marketSeed) external {
        address actor = _selectActor(actorSeed);
        assets = bound(assets, 1e6, 10_000_000e6);
        address market = markets[marketSeed % markets.length];

        deal(address(usdc), actor, assets);

        vm.startPrank(actor);
        usdc.approve(address(optimizer), assets);

        try optimizer.depositToMarket(assets, actor, market) returns (uint256 shares) {
            ghost_totalDeposited += assets;
            ghost_userDeposited[actor] += assets;
            ghost_totalSharesMinted += shares;
            ghost_depositCount++;
        } catch {
            // Expected revert (e.g., deposits paused or market unavailable).
        }

        vm.stopPrank();
        _updateExchangeRate();
    }

    /// @notice Withdraw assets for a random actor who has shares.
    function withdraw(uint256 actorSeed, uint256 assets, uint256) external {
        address actor = _selectActor(actorSeed);
        uint256 maxW = optimizer.maxWithdraw(actor);
        if (maxW == 0) return;

        assets = bound(assets, 1, maxW);

        vm.startPrank(actor);

        try optimizer.withdraw(assets, actor, actor) returns (uint256 shares) {
            ghost_totalWithdrawn += assets;
            ghost_userWithdrawn[actor] += assets;
            ghost_totalSharesBurned += shares;
            ghost_withdrawCount++;
        } catch {
            // Expected revert (e.g., insufficient liquidity in target market).
        }

        vm.stopPrank();
        _updateExchangeRate();
    }

    /// @notice Redeem shares for a random actor who has shares.
    function redeem(uint256 actorSeed, uint256 shares, uint256) external {
        address actor = _selectActor(actorSeed);
        uint256 maxR = optimizer.maxRedeem(actor);
        if (maxR == 0) return;

        shares = bound(shares, 1, maxR);

        vm.startPrank(actor);

        try optimizer.redeem(shares, actor, actor) returns (uint256 assets) {
            ghost_totalWithdrawn += assets;
            ghost_userWithdrawn[actor] += assets;
            ghost_totalSharesBurned += shares;
            ghost_withdrawCount++;
        } catch {
            // Expected revert (e.g., insufficient liquidity in target market).
        }

        vm.stopPrank();
        _updateExchangeRate();
    }

    /// @notice Withdraw assets through the allowance path.
    /// @dev The owner approves a distinct actor, and the delegate receives
    ///      assets. Ghost accounting attributes the burned shares to owner.
    function delegatedWithdraw(uint256 ownerSeed, uint256 delegateSeed, uint256 assets) external {
        (address owner, address delegate) = _selectDistinctActors(ownerSeed, delegateSeed);

        uint256 maxW = optimizer.maxWithdraw(owner);
        if (maxW == 0) return;

        assets = bound(assets, 1, maxW);
        uint256 ownerShares = optimizer.balanceOf(owner);

        vm.prank(owner);
        optimizer.approve(delegate, ownerShares);

        vm.startPrank(delegate);

        try optimizer.withdraw(assets, delegate, owner) returns (uint256 shares) {
            ghost_totalWithdrawn += assets;
            ghost_userWithdrawn[owner] += assets;
            ghost_totalSharesBurned += shares;
            ghost_withdrawCount++;
            ghost_delegatedWithdrawCount++;
        } catch {
            // Expected revert (e.g., insufficient liquidity or allowance drift).
        }

        vm.stopPrank();
        _updateExchangeRate();
    }

    /// @notice Redeem shares through the allowance path.
    /// @dev The delegate receives assets while owner shares are burned.
    function delegatedRedeem(uint256 ownerSeed, uint256 delegateSeed, uint256 shares) external {
        (address owner, address delegate) = _selectDistinctActors(ownerSeed, delegateSeed);

        uint256 maxR = optimizer.maxRedeem(owner);
        if (maxR == 0) return;

        shares = bound(shares, 1, maxR);

        vm.prank(owner);
        optimizer.approve(delegate, shares);

        vm.startPrank(delegate);

        try optimizer.redeem(shares, delegate, owner) returns (uint256 assets) {
            ghost_totalWithdrawn += assets;
            ghost_userWithdrawn[owner] += assets;
            ghost_totalSharesBurned += shares;
            ghost_withdrawCount++;
            ghost_delegatedWithdrawCount++;
        } catch {
            // Expected revert (e.g., insufficient liquidity).
        }

        vm.stopPrank();
        _updateExchangeRate();
    }

    /// @notice Mint shares for a random actor.
    function mint(uint256 actorSeed, uint256 shares) external {
        address actor = _selectActor(actorSeed);
        shares = bound(shares, 1e6, 10_000_000e6);

        uint256 assetsNeeded = optimizer.previewMint(shares);
        if (assetsNeeded == 0) return;

        deal(address(usdc), actor, assetsNeeded);

        vm.startPrank(actor);
        usdc.approve(address(optimizer), assetsNeeded);

        try optimizer.mint(shares, actor) returns (uint256 assets) {
            ghost_totalDeposited += assets;
            ghost_userDeposited[actor] += assets;
            ghost_totalSharesMinted += shares;
            ghost_depositCount++;
        } catch {
            // Expected revert.
        }

        vm.stopPrank();
        _updateExchangeRate();
    }

    /// @notice Transfer shares between two different actors.
    function transferShares(uint256 seed, uint256 amount) external {
        address sender = _selectActor(seed);
        address receiver = actors[(seed + 1) % actors.length];

        // Ensure sender and receiver are different.
        if (sender == receiver) return;

        uint256 balance = optimizer.balanceOf(sender);
        if (balance == 0) return;

        amount = bound(amount, 1, balance);

        vm.prank(sender);

        try optimizer.transfer(receiver, amount) returns (bool) {
            // Track the asset value of transferred shares so that
            // the round-trip invariant accounts for shares received
            // via transfer (not just direct deposits).
            // Round up (+1) so the ghost accounting never under-counts
            // the receiver's "deposit", which would cause false positives
            // on the round-trip invariant with dust amounts.
            uint256 assetValue = optimizer.convertToAssets(amount) + 1;
            ghost_userDeposited[receiver] += assetValue;
            ghost_transferCount++;
        } catch {
            // Unexpected revert.
        }

        _updateExchangeRate();
    }

    /// @notice Transfer shares through the allowance path.
    function delegatedTransferShares(uint256 ownerSeed, uint256 delegateSeed, uint256 recipientSeed, uint256 amount)
        external
    {
        (address owner, address delegate) = _selectDistinctActors(ownerSeed, delegateSeed);
        address recipient = _selectDifferentActor(owner, recipientSeed);

        uint256 balance = optimizer.balanceOf(owner);
        if (balance == 0) return;

        amount = bound(amount, 1, balance);

        vm.prank(owner);
        optimizer.approve(delegate, amount);

        vm.prank(delegate);

        try optimizer.transferFrom(owner, recipient, amount) returns (bool) {
            uint256 assetValue = optimizer.convertToAssets(amount) + 1;
            ghost_userDeposited[recipient] += assetValue;
            ghost_transferCount++;
        } catch {
            // Expected revert for standard ERC20 allowance/balance checks.
        }

        _updateExchangeRate();
    }

    /// @notice Donate idle underlying directly to the optimizer.
    /// @dev Direct donations are not part of optimizer accounting and should
    ///      remain recoverable idle balance rather than changing share price.
    function donateUnderlying(uint256 actorSeed, uint256 assets) external {
        address actor = _selectActor(actorSeed);
        assets = bound(assets, 1, 1_000_000e6);

        deal(address(usdc), actor, assets);

        vm.prank(actor);
        try usdc.transfer(address(optimizer), assets) returns (bool success) {
            if (success) ghost_underlyingDonated += assets;
        } catch {
            // Unexpected token transfer failure.
        }

        _updateExchangeRate();
    }

    /// @notice Rebalance assets between two markets.
    function rebalance(uint256 withdrawMarketIndex, uint256 depositMarketIndex, uint256 amount) external {
        uint256 numMarkets = markets.length;
        if (numMarkets < 2) return;

        withdrawMarketIndex = bound(withdrawMarketIndex, 0, numMarkets - 1);
        depositMarketIndex = bound(depositMarketIndex, 0, numMarkets - 1);

        // Ensure different markets.
        if (withdrawMarketIndex == depositMarketIndex) {
            depositMarketIndex = (depositMarketIndex + 1) % numMarkets;
        }

        // Bound amount to available assets in the withdrawal market.
        address withdrawMarket = markets[withdrawMarketIndex];
        uint256 marketAssets = IBorrowableCToken(withdrawMarket)
            .convertToAssets(IBorrowableCToken(withdrawMarket).balanceOf(address(optimizer)));
        uint256 availableLiquidity = IBorrowableCToken(withdrawMarket).assetsHeld();
        uint256 maxAmount = marketAssets < availableLiquidity ? marketAssets : availableLiquidity;
        if (maxAmount == 0) return;

        amount = bound(amount, 1, maxAmount);

        // Build ReallocationAction array matching approvedCTokensList order.
        LendingOptimizer.ReallocationAction[] memory actions = new LendingOptimizer.ReallocationAction[](numMarkets);

        for (uint256 i; i < numMarkets; ++i) {
            actions[i].cToken = IBorrowableCToken(markets[i]);
            if (i == withdrawMarketIndex) {
                actions[i].assetsOrBps = -int256(amount);
            } else if (i == depositMarketIndex) {
                actions[i].assetsOrBps = int256(amount);
            }
            // else: assets defaults to 0 (no-op)
        }

        _mockHarvestPermissions(address(this));

        try optimizer.rebalance(actions, _unconstrainedBounds()) {
            ghost_rebalanceCount++;
        } catch {
            // Expected revert (e.g., allocation cap exceeded).
        }

        _updateExchangeRate();
    }

    /// @notice Warp time forward.
    function warpTime(uint256 duration) external {
        duration = bound(duration, 1, 7 days);
        vm.warp(block.timestamp + duration);
        // Accrue interest so _totalAssets reflects the new cToken values.
        // exchangeRate() is now a simple view; use exchangeRateUpdated()
        // which triggers _accrueIfNeeded().
        try optimizer.exchangeRateUpdated() {} catch {}
        _updateExchangeRate();
    }

    /// @notice Trigger accrual and yield vesting.
    function accrueYield() external {
        try optimizer.exchangeRateUpdated() {}
            catch {
            // May revert if reentrancy guard triggered from test context.
        }
        _updateExchangeRate();
    }

    /// @notice Set a new performance fee.
    function setFee(uint256 newFeeBps) external {
        newFeeBps = bound(newFeeBps, 0, 5000);
        _mockMarketPermissions(address(this));

        try optimizer.setFee(newFeeBps) {}
            catch {
            // Unexpected revert.
        }

        _updateExchangeRate();
    }

    /// @notice Pause deposits. Deposits/mints will revert while paused.
    function pauseMint() external {
        _mockMarketPermissions(address(this));

        uint8 currentState = optimizer.mintPaused();
        if (currentState != 1) return; // Only pause if currently active.

        try optimizer.setMintPaused(true) {}
            catch {
            // Unexpected revert.
        }
    }

    /// @notice Unpause deposits.
    function unpauseMint() external {
        _mockMarketPermissions(address(this));

        uint8 currentState = optimizer.mintPaused();
        if (currentState != 2) return; // Only unpause if currently paused.

        try optimizer.setMintPaused(false) {}
            catch {
            // Unexpected revert.
        }
    }

    /// @notice Update allocation cap for a market.
    function updateCap(uint256 marketIndex, uint256 newCapBps) external {
        marketIndex = bound(marketIndex, 0, markets.length - 1);
        newCapBps = bound(newCapBps, 1000, 10000);

        _mockMarketPermissions(address(this));

        try optimizer.updateCap(markets[marketIndex], newCapBps) {}
            catch {
            // Expected revert (e.g., total caps < 100%).
        }
    }

    // ========================================================================
    // INTENTIONALLY EXCLUDED ACTIONS
    // ========================================================================

    // Market add/remove (addApprovedAsset / removeApprovedAsset) is excluded
    // from the handler because:
    // 1. Both require admin-level market permissions (not user actions).
    // 2. removeApprovedAsset requires constructing valid ReallocationAction arrays
    //    with exact reallocation amounts matching redeemed totals, which is
    //    difficult to fuzz meaningfully without hitting constant reverts.
    // 3. addApprovedAsset requires deploying or referencing a valid cToken
    //    with correct underlying, registered market manager, etc.
    // 4. Changing the market set mid-sequence invalidates the cached `markets`
    //    array used by all other handler functions.
    // These operations are tested in dedicated unit/integration tests instead.

    // ========================================================================
    // VIEW HELPERS
    // ========================================================================

    function getActorCount() external view returns (uint256) {
        return actors.length;
    }

    function getActor(uint256 i) external view returns (address) {
        return actors[i];
    }

    function getMarketCount() external view returns (uint256) {
        return markets.length;
    }

    // ========================================================================
    // HELPERS
    // ========================================================================

    function _selectActor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _selectDistinctActors(uint256 firstSeed, uint256 secondSeed)
        internal
        view
        returns (address first, address second)
    {
        first = _selectActor(firstSeed);
        second = _selectActor(secondSeed);
        if (first == second) {
            second = actors[(secondSeed + 1) % actors.length];
        }
    }

    function _selectDifferentActor(address excluded, uint256 seed) internal view returns (address actor) {
        actor = _selectActor(seed);
        if (actor == excluded) {
            actor = actors[(seed + 1) % actors.length];
        }
    }

    /// @dev Returns unconstrained allocation bounds for the optimizer.
    function _unconstrainedBounds() internal view returns (LendingOptimizer.AllocationBound[] memory bounds) {
        uint256 l = optimizer.numApprovedMarkets();
        bounds = new LendingOptimizer.AllocationBound[](l);
        for (uint256 i; i < l; ++i) {
            bounds[i] =
                LendingOptimizer.AllocationBound({cToken: optimizer.approvedCTokensList(i), minBps: 0, maxBps: 10000});
        }
    }

    function _updateExchangeRate() internal {
        uint256 supply = optimizer.totalSupply();
        if (supply > 0) {
            uint256 rate = (WAD * optimizer.totalAssets()) / supply;
            ghost_lastExchangeRate = rate;
        }
    }

    function _mockHarvestPermissions(address caller) internal {
        vm.mockCall(
            address(centralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasHarvestPermissions.selector, caller),
            abi.encode(true)
        );
    }

    function _mockMarketPermissions(address caller) internal {
        vm.mockCall(
            address(centralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, caller),
            abi.encode(true)
        );
    }
}
