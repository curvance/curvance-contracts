// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { LendingOptimizerHarness } from "../LendingOptimizerHarness.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { WAD } from "contracts/libraries/ConstantsLib.sol";

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
    uint256 public ghost_rebalanceCount;
    uint256 public ghost_lastExchangeRate;

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
    // HELPERS
    // ========================================================================

    function _selectActor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _selectMarket(uint256 seed) internal view returns (address) {
        return markets[seed % markets.length];
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

    // ========================================================================
    // ACTIONS
    // ========================================================================

    /// @notice Deposit assets into the optimizer for a random actor.
    function deposit(uint256 actorSeed, uint256 assets, uint256 marketIndex) external {
        address actor = _selectActor(actorSeed);
        assets = bound(assets, 1e6, 10_000_000e6);
        address market = _selectMarket(marketIndex);

        deal(address(usdc), actor, assets);

        vm.startPrank(actor);
        usdc.approve(address(optimizer), assets);

        try optimizer.deposit(assets, actor, market) returns (uint256 shares) {
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

    /// @notice Withdraw assets for a random actor who has shares.
    function withdraw(uint256 actorSeed, uint256 assets, uint256 marketIndex) external {
        address actor = _selectActor(actorSeed);
        uint256 maxW = optimizer.maxWithdraw(actor);
        if (maxW == 0) return;

        assets = bound(assets, 1, maxW);
        address market = _selectMarket(marketIndex);

        vm.startPrank(actor);

        try optimizer.withdraw(assets, actor, actor, market) returns (uint256 shares) {
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
    function redeem(uint256 actorSeed, uint256 shares, uint256 marketIndex) external {
        address actor = _selectActor(actorSeed);
        uint256 maxR = optimizer.maxRedeem(actor);
        if (maxR == 0) return;

        shares = bound(shares, 1, maxR);
        address market = _selectMarket(marketIndex);

        vm.startPrank(actor);

        try optimizer.redeem(shares, actor, actor, market) returns (uint256 assets) {
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
            // Actual shares minted may differ slightly from requested due to cToken rounding.
            uint256 actualShares = optimizer.balanceOf(actor);
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
            ghost_transferCount++;
        } catch {
            // Unexpected revert.
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
        uint256 marketAssets = IBorrowableCToken(withdrawMarket).convertToAssets(
            IBorrowableCToken(withdrawMarket).balanceOf(address(optimizer))
        );
        uint256 availableLiquidity = IBorrowableCToken(withdrawMarket).assetsHeld();
        uint256 maxAmount = marketAssets < availableLiquidity ? marketAssets : availableLiquidity;
        if (maxAmount == 0) return;

        amount = bound(amount, 1, maxAmount);

        // Build RebalanceAction array matching approvedCTokensList order.
        LendingOptimizer.RebalanceAction[] memory actions =
            new LendingOptimizer.RebalanceAction[](numMarkets);

        for (uint256 i; i < numMarkets; ++i) {
            actions[i].cToken = IBorrowableCToken(markets[i]);
            if (i == withdrawMarketIndex) {
                actions[i].assets = amount;
                actions[i].isDeposit = false;
            } else if (i == depositMarketIndex) {
                actions[i].assets = amount;
                actions[i].isDeposit = true;
            } else {
                actions[i].assets = 0;
                actions[i].isDeposit = false;
            }
        }

        _mockHarvestPermissions(address(this));

        try optimizer.rebalance(actions) {
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
        _updateExchangeRate();
    }

    /// @notice Trigger accrual and yield vesting.
    function accrueYield() external {
        try optimizer.exchangeRateUpdated() {
            // Success.
        } catch {
            // May revert if reentrancy guard triggered from test context.
        }
        _updateExchangeRate();
    }

    /// @notice Set a new performance fee.
    function setFee(uint256 newFeeBps) external {
        newFeeBps = bound(newFeeBps, 0, 5000);
        _mockMarketPermissions(address(this));

        try optimizer.setFee(newFeeBps) {
            // Success.
        } catch {
            // Unexpected revert.
        }

        _updateExchangeRate();
    }

    /// @notice Pause deposits. Deposits/mints will revert while paused.
    function pauseMint() external {
        _mockMarketPermissions(address(this));

        uint8 currentState = optimizer.mintPaused();
        if (currentState != 1) return; // Only pause if currently active.

        try optimizer.setMintPaused(true) {
            // Success.
        } catch {
            // Unexpected revert.
        }
    }

    /// @notice Unpause deposits.
    function unpauseMint() external {
        _mockMarketPermissions(address(this));

        uint8 currentState = optimizer.mintPaused();
        if (currentState != 2) return; // Only unpause if currently paused.

        try optimizer.setMintPaused(false) {
            // Success.
        } catch {
            // Unexpected revert.
        }
    }

    /// @notice Update allocation cap for a market.
    function updateCap(uint256 marketIndex, uint256 newCapBps) external {
        marketIndex = bound(marketIndex, 0, markets.length - 1);
        newCapBps = bound(newCapBps, 1000, 10000);

        _mockMarketPermissions(address(this));

        try optimizer.updateCap(markets[marketIndex], newCapBps) {
            // Success.
        } catch {
            // Expected revert (e.g., total caps < 100%).
        }
    }

    // ========================================================================
    // INTENTIONALLY EXCLUDED ACTIONS
    // ========================================================================

    // Market add/remove (addApprovedAsset / removeApprovedAsset) is excluded
    // from the handler because:
    // 1. Both require admin-level market permissions (not user actions).
    // 2. removeApprovedAsset requires constructing valid RemoveAction arrays
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
}
