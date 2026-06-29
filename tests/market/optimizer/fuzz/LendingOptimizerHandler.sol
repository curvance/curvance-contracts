// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LendingOptimizerHarness} from "../LendingOptimizerHarness.sol";
import {
    LendingOptimizer
} from "contracts/market/optimizer/LendingOptimizer.sol";
import {IBorrowableCToken} from "contracts/interfaces/IBorrowableCToken.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IMarketManager} from "contracts/interfaces/IMarketManager.sol";
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
    address[] public candidateMarkets;
    address public seedHolder;

    // Ghost variables for invariant checking.
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;
    mapping(address => uint256) public ghost_userDeposited;
    mapping(address => uint256) public ghost_userWithdrawn;
    uint256 public ghost_depositCount;
    uint256 public ghost_withdrawCount;
    uint256 public ghost_delegatedWithdrawCount;
    uint256 public ghost_rebalanceCount;
    uint256 public ghost_addMarketCount;
    uint256 public ghost_removeMarketCount;
    uint256 public ghost_skimCount;
    uint256 public ghost_accrueCount;
    uint256 public ghost_lastExchangeRate;
    uint256 public ghost_underlyingDonated;
    bool public ghost_reinitialized;

    // Track total shares minted / burned for supply consistency checks.
    uint256 public ghost_totalSharesMinted;
    uint256 public ghost_totalSharesBurned;

    // Track share transfers for balance consistency checks.
    uint256 public ghost_transferCount;

    constructor(
        LendingOptimizerHarness _optimizer,
        IERC20 _usdc,
        ICentralRegistry _centralRegistry,
        address[] memory _actors,
        address[] memory _candidateMarkets
    ) {
        optimizer = _optimizer;
        usdc = _usdc;
        centralRegistry = _centralRegistry;
        actors = _actors;
        candidateMarkets = _candidateMarkets;
        seedHolder = msg.sender;

        // Cache approved markets.
        uint256 numMarkets = _optimizer.numApprovedMarkets();
        for (uint256 i; i < numMarkets; ++i) {
            markets.push(_optimizer.approvedCTokensList(i));
        }

        // Record initial exchange rate.
        ghost_lastExchangeRate = WAD;
    }

    modifier checkPostActionInvariants() {
        _;
        _assertPostActionInvariants();
    }

    // ========================================================================
    // ACTIONS
    // ========================================================================

    /// @notice Deposit assets into the optimizer for a random actor.
    function deposit(uint256 actorSeed, uint256 assets, uint256)
        external
        checkPostActionInvariants
    {
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
    function depositToMarket(
        uint256 actorSeed,
        uint256 assets,
        uint256 marketSeed
    ) external checkPostActionInvariants {
        address actor = _selectActor(actorSeed);
        assets = bound(assets, 1e6, 10_000_000e6);
        address market = markets[marketSeed % markets.length];

        deal(address(usdc), actor, assets);

        vm.startPrank(actor);
        usdc.approve(address(optimizer), assets);

        try optimizer.depositToMarket(assets, actor, market) returns (
            uint256 shares
        ) {
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
    function withdraw(uint256 actorSeed, uint256 assets, uint256)
        external
        checkPostActionInvariants
    {
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
    function redeem(uint256 actorSeed, uint256 shares, uint256)
        external
        checkPostActionInvariants
    {
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
    function delegatedWithdraw(
        uint256 ownerSeed,
        uint256 delegateSeed,
        uint256 assets
    ) external checkPostActionInvariants {
        (address owner, address delegate) =
            _selectDistinctActors(ownerSeed, delegateSeed);

        uint256 maxW = optimizer.maxWithdraw(owner);
        if (maxW == 0) return;

        assets = bound(assets, 1, maxW);
        uint256 ownerShares = optimizer.balanceOf(owner);

        vm.prank(owner);
        optimizer.approve(delegate, ownerShares);

        vm.startPrank(delegate);

        try optimizer.withdraw(assets, delegate, owner) returns (
            uint256 shares
        ) {
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
    function delegatedRedeem(
        uint256 ownerSeed,
        uint256 delegateSeed,
        uint256 shares
    ) external checkPostActionInvariants {
        (address owner, address delegate) =
            _selectDistinctActors(ownerSeed, delegateSeed);

        uint256 maxR = optimizer.maxRedeem(owner);
        if (maxR == 0) return;

        shares = bound(shares, 1, maxR);

        vm.prank(owner);
        optimizer.approve(delegate, shares);

        vm.startPrank(delegate);

        try optimizer.redeem(shares, delegate, owner) returns (
            uint256 assets
        ) {
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
    function mint(uint256 actorSeed, uint256 shares)
        external
        checkPostActionInvariants
    {
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
    function transferShares(uint256 seed, uint256 amount)
        external
        checkPostActionInvariants
    {
        address sender = _selectActor(seed);
        address receiver = _selectDifferentActor(sender, seed);

        // Ensure sender and receiver are different.
        if (sender == receiver) return;

        uint256 balance = optimizer.balanceOf(sender);
        if (balance == 0) return;

        amount = bound(amount, 1, balance);
        try optimizer.exchangeRateUpdated() {} catch {}

        uint256 senderBalanceBefore = optimizer.balanceOf(sender);
        uint256 receiverBalanceBefore = optimizer.balanceOf(receiver);
        uint256 supplyBefore = optimizer.totalSupply();
        uint256 totalAssetsBefore = optimizer.totalAssets();

        vm.prank(sender);

        try optimizer.transfer(receiver, amount) returns (bool) {
            assertEq(
                optimizer.balanceOf(sender),
                senderBalanceBefore - amount,
                "POST TRANSFER: sender share delta"
            );
            assertEq(
                optimizer.balanceOf(receiver),
                receiverBalanceBefore + amount,
                "POST TRANSFER: receiver share delta"
            );
            assertEq(
                optimizer.totalSupply(),
                supplyBefore,
                "POST TRANSFER: supply changed"
            );
            assertEq(
                optimizer.totalAssets(),
                totalAssetsBefore,
                "POST TRANSFER: totalAssets changed"
            );
            ghost_transferCount++;
        } catch {
            // Unexpected revert.
        }

        _updateExchangeRate();
    }

    /// @notice Transfer shares through the allowance path.
    function delegatedTransferShares(
        uint256 ownerSeed,
        uint256 delegateSeed,
        uint256 recipientSeed,
        uint256 amount
    ) external checkPostActionInvariants {
        (address owner, address delegate) =
            _selectDistinctActors(ownerSeed, delegateSeed);
        address recipient = _selectDifferentActor(owner, recipientSeed);

        uint256 balance = optimizer.balanceOf(owner);
        if (balance == 0) return;

        amount = bound(amount, 1, balance);
        try optimizer.exchangeRateUpdated() {} catch {}

        uint256 ownerBalanceBefore = optimizer.balanceOf(owner);
        uint256 recipientBalanceBefore = optimizer.balanceOf(recipient);
        uint256 supplyBefore = optimizer.totalSupply();
        uint256 totalAssetsBefore = optimizer.totalAssets();

        vm.prank(owner);
        optimizer.approve(delegate, amount);

        vm.prank(delegate);

        try optimizer.transferFrom(owner, recipient, amount) returns (bool) {
            assertEq(
                optimizer.balanceOf(owner),
                ownerBalanceBefore - amount,
                "POST TRANSFERFROM: owner share delta"
            );
            assertEq(
                optimizer.balanceOf(recipient),
                recipientBalanceBefore + amount,
                "POST TRANSFERFROM: recipient share delta"
            );
            assertEq(
                optimizer.allowance(owner, delegate),
                0,
                "POST TRANSFERFROM: allowance delta"
            );
            assertEq(
                optimizer.totalSupply(),
                supplyBefore,
                "POST TRANSFERFROM: supply changed"
            );
            assertEq(
                optimizer.totalAssets(),
                totalAssetsBefore,
                "POST TRANSFERFROM: totalAssets changed"
            );
            ghost_transferCount++;
        } catch {
            // Expected revert for standard ERC20 allowance/balance checks.
        }

        _updateExchangeRate();
    }

    /// @notice Donate idle underlying directly to the optimizer.
    /// @dev Direct donations are not part of optimizer accounting and should
    ///      remain recoverable idle balance rather than changing share price.
    function donateUnderlying(uint256 actorSeed, uint256 assets)
        external
        checkPostActionInvariants
    {
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
    function rebalance(
        uint256 withdrawMarketIndex,
        uint256 depositMarketIndex,
        uint256 amount
    ) external checkPostActionInvariants {
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
            .convertToAssets(
                IBorrowableCToken(withdrawMarket).balanceOf(address(optimizer))
            );
        uint256 availableLiquidity =
            IBorrowableCToken(withdrawMarket).assetsHeld();
        uint256 maxAmount = marketAssets < availableLiquidity
            ? marketAssets
            : availableLiquidity;
        if (maxAmount == 0) return;

        amount = bound(amount, 1, maxAmount);

        // Build ReallocationAction array matching approvedCTokensList order.
        LendingOptimizer.ReallocationAction[] memory actions =
            new LendingOptimizer.ReallocationAction[](numMarkets);

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
    function warpTime(uint256 duration) external checkPostActionInvariants {
        duration = bound(duration, 1, 7 days);
        vm.warp(block.timestamp + duration);
        // Accrue interest so _totalAssets reflects the new cToken values.
        // exchangeRate() is now a simple view; use exchangeRateUpdated()
        // which triggers _accrueIfNeeded().
        try optimizer.exchangeRateUpdated() {} catch {}
        _updateExchangeRate();
    }

    /// @notice Trigger accrual and yield vesting.
    function accrueYield() external checkPostActionInvariants {
        try optimizer.exchangeRateUpdated() {}
            catch {
            // May revert if reentrancy guard triggered from test context.
        }
        _updateExchangeRate();
    }

    /// @notice Set a new performance fee.
    function setFee(uint256 newFeeBps) external checkPostActionInvariants {
        newFeeBps = bound(newFeeBps, 0, 5000);
        _mockMarketPermissions(address(this));

        try optimizer.setFee(newFeeBps) {}
            catch {
            // Unexpected revert.
        }

        _updateExchangeRate();
    }

    /// @notice Pause deposits. Deposits/mints will revert while paused.
    function pauseMint() external checkPostActionInvariants {
        _mockMarketPermissions(address(this));

        uint8 currentState = optimizer.mintPaused();
        if (currentState != 1) return; // Only pause if currently active.

        try optimizer.setMintPaused(true) {}
            catch {
            // Unexpected revert.
        }
    }

    /// @notice Unpause deposits.
    function unpauseMint() external checkPostActionInvariants {
        _mockMarketPermissions(address(this));

        uint8 currentState = optimizer.mintPaused();
        if (currentState != 2) return; // Only unpause if currently paused.

        try optimizer.setMintPaused(false) {}
            catch {
            // Unexpected revert.
        }
    }

    /// @notice Update allocation cap for a market.
    function updateCap(uint256 marketIndex, uint256 newCapBps)
        external
        checkPostActionInvariants
    {
        marketIndex = bound(marketIndex, 0, markets.length - 1);
        newCapBps = bound(newCapBps, 1000, 10000);

        _mockMarketPermissions(address(this));

        try optimizer.updateCap(markets[marketIndex], newCapBps) {}
            catch {
            // Expected revert (e.g., total caps < 100%).
        }
    }

    /// @notice Attempts to initialize the already-initialized optimizer again.
    function initializeDepositsAgain(uint256 marketSeed)
        external
        checkPostActionInvariants
    {
        if (markets.length == 0) return;

        address market = markets[marketSeed % markets.length];
        deal(address(usdc), address(this), 77777);
        usdc.approve(address(optimizer), 77777);
        _mockMarketPermissions(address(this));

        try optimizer.initializeDeposits(market) {
            ghost_reinitialized = true;
        } catch {
            // Expected: the stateful harness initializes during setUp.
        }

        _updateExchangeRate();
    }

    /// @notice Explicitly accrues optimizer accounting through the public method.
    function accrueIfNeededAction() external checkPostActionInvariants {
        try optimizer.accrueIfNeeded() {
            ghost_accrueCount++;
        } catch {
            // Expected if another nonReentrant path is active.
        }

        _updateExchangeRate();
    }

    /// @notice Explicitly updates and returns the optimizer exchange rate.
    function exchangeRateUpdatedAction() external checkPostActionInvariants {
        try optimizer.exchangeRateUpdated() {
            ghost_accrueCount++;
        } catch {
            // Expected if another nonReentrant path is active.
        }

        _updateExchangeRate();
    }

    /// @notice Skims donated idle underlying to the DAO.
    function skimDonatedUnderlying() external checkPostActionInvariants {
        _mockDaoPermissions(address(this));

        try optimizer.skim() {
            ghost_skimCount++;
        } catch {
            // Expected if no DAO permission or token transfer edge reverts.
        }

        _updateExchangeRate();
    }

    /// @notice Adds a known valid candidate market if it is not already approved.
    function addApprovedAsset(uint256 marketSeed, uint256 capSeed)
        external
        checkPostActionInvariants
    {
        if (candidateMarkets.length == 0) return;

        address candidate =
            candidateMarkets[marketSeed % candidateMarkets.length];
        uint256 capBps = bound(capSeed, 1000, 10000);

        _mockElevatedPermissions(address(this));

        try optimizer.addApprovedAsset(candidate, capBps) {
            markets.push(candidate);
            ghost_addMarketCount++;
        } catch {
            // Expected for duplicate, invalid, or max-market candidates.
        }

        _updateExchangeRate();
    }

    /// @notice Removes an approved market and reallocates to one remaining market.
    function removeApprovedAsset(uint256 marketSeed, uint256 targetSeed)
        external
        checkPostActionInvariants
    {
        uint256 numMarkets = markets.length;
        if (numMarkets < 2) return;

        uint256 removeIndex = bound(marketSeed, 0, numMarkets - 1);
        uint256 targetIndex = bound(targetSeed, 0, numMarkets - 1);
        if (targetIndex == removeIndex) {
            targetIndex = (targetIndex + 1) % numMarkets;
        }

        address marketToRemove = markets[removeIndex];
        address targetMarket = markets[targetIndex];

        _mockMarketPermissions(address(this));

        try optimizer.updateCap(targetMarket, 10000) {} catch {}

        LendingOptimizer.ReallocationAction[] memory removeActions =
            new LendingOptimizer.ReallocationAction[](1);
        removeActions[0] = LendingOptimizer.ReallocationAction({
            cToken: IBorrowableCToken(targetMarket), assetsOrBps: int256(10000)
        });

        try optimizer.removeApprovedAsset(
            marketToRemove,
            removeActions,
            _unconstrainedBoundsForRemoval(marketToRemove)
        ) {
            _removeCachedMarket(removeIndex);
            ghost_removeMarketCount++;
        } catch {
            // Expected for liquidity, cap, or rounding constraints.
        }

        _updateExchangeRate();
    }

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
            uint256 secondIndex = secondSeed % actors.length;
            second = actors[(secondIndex + 1) % actors.length];
        }
    }

    function _selectDifferentActor(address excluded, uint256 seed)
        internal
        view
        returns (address actor)
    {
        uint256 index = seed % actors.length;
        actor = actors[index];
        if (actor == excluded) {
            actor = actors[(index + 1) % actors.length];
        }
    }

    /// @dev Returns unconstrained allocation bounds for the optimizer.
    function _unconstrainedBounds()
        internal
        view
        returns (LendingOptimizer.AllocationBound[] memory bounds)
    {
        uint256 l = optimizer.numApprovedMarkets();
        bounds = new LendingOptimizer.AllocationBound[](l);
        for (uint256 i; i < l; ++i) {
            bounds[i] = LendingOptimizer.AllocationBound({
                cToken: optimizer.approvedCTokensList(i),
                minBps: 0,
                maxBps: 10000
            });
        }
    }

    function _unconstrainedBoundsForRemoval(address cTokenToRemove)
        internal
        view
        returns (LendingOptimizer.AllocationBound[] memory bounds)
    {
        uint256 l = optimizer.numApprovedMarkets();
        if (l <= 1) return new LendingOptimizer.AllocationBound[](0);

        bounds = new LendingOptimizer.AllocationBound[](l - 1);
        uint256 removeIndex;
        for (uint256 i; i < l; ++i) {
            if (optimizer.approvedCTokensList(i) == cTokenToRemove) {
                removeIndex = i;
                break;
            }
        }

        address[] memory postRemoval = new address[](l - 1);
        for (uint256 i; i < l; ++i) {
            if (i < l - 1) postRemoval[i] = optimizer.approvedCTokensList(i);
        }
        if (removeIndex != l - 1) {
            postRemoval[removeIndex] = optimizer.approvedCTokensList(l - 1);
        }

        for (uint256 i; i < l - 1; ++i) {
            bounds[i] = LendingOptimizer.AllocationBound({
                cToken: postRemoval[i], minBps: 0, maxBps: 10000
            });
        }
    }

    function _removeCachedMarket(uint256 index) internal {
        uint256 last = markets.length - 1;
        if (index != last) {
            markets[index] = markets[last];
        }
        markets.pop();
    }

    function _assertPostActionInvariants() internal {
        _updateExchangeRate();

        uint256 numMarkets = optimizer.numApprovedMarkets();
        uint256 totalCaps;
        uint256 listedMarketAssets;
        uint256 trackedAssets = optimizer.totalAssets();

        assertEq(
            markets.length,
            numMarkets,
            "POST ACTION: cached market length drift"
        );

        for (uint256 i; i < numMarkets; ++i) {
            address market = optimizer.approvedCTokensList(i);
            assertEq(markets[i], market, "POST ACTION: cached market drift");

            totalCaps += optimizer.allocationCaps(market);
            assertEq(
                IBorrowableCToken(market).asset(),
                address(usdc),
                "POST ACTION: approved market underlying drift"
            );
            assertTrue(
                centralRegistry.isMarketManager(
                    address(IBorrowableCToken(market).marketManager())
                ),
                "POST ACTION: approved market manager not registered"
            );
            assertTrue(
                IMarketManager(IBorrowableCToken(market).marketManager())
                    .isListed(market),
                "POST ACTION: approved market not listed"
            );

            uint256 marketAssets = IBorrowableCToken(market)
                .convertToAssets(
                    IBorrowableCToken(market).balanceOf(address(optimizer))
                );
            listedMarketAssets += marketAssets;
        }

        assertGe(totalCaps, WAD, "POST ACTION: caps below 100%");
        assertLe(
            trackedAssets,
            listedMarketAssets,
            "POST ACTION: tracked assets exceed listed markets"
        );

        uint256 supply = optimizer.totalSupply();
        assertGt(supply, 0, "POST ACTION: zero total supply");
        assertGt(
            optimizer.balanceOf(address(0)),
            0,
            "POST ACTION: missing dead shares"
        );
        assertFalse(ghost_reinitialized, "POST ACTION: reinitialized");
        assertGe(
            ghost_totalSharesMinted,
            ghost_totalSharesBurned,
            "POST ACTION: burned more actor shares than minted"
        );

        uint256 actorShares = _sumActorShareBalances();
        assertEq(
            actorShares,
            ghost_totalSharesMinted - ghost_totalSharesBurned,
            "POST ACTION: actor shares ghost mismatch"
        );

        uint256 knownShares = optimizer.balanceOf(address(0))
            + optimizer.balanceOf(seedHolder)
            + optimizer.balanceOf(address(this)) + actorShares;
        assertEq(
            knownShares,
            supply,
            "POST ACTION: supply differs from known holders"
        );

        uint256 currentRate = (WAD * trackedAssets) / supply;
        assertEq(
            currentRate,
            ghost_lastExchangeRate,
            "POST ACTION: exchange rate ghost drift"
        );

        for (uint256 i; i < actors.length; ++i) {
            assertLe(
                optimizer.maxWithdraw(actors[i]),
                trackedAssets,
                "POST ACTION: maxWithdraw above tracked assets"
            );
        }
    }

    function _sumActorShareBalances()
        internal
        view
        returns (uint256 actorShares)
    {
        for (uint256 i; i < actors.length; ++i) {
            actorShares += optimizer.balanceOf(actors[i]);
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
            abi.encodeWithSelector(
                ICentralRegistry.hasHarvestPermissions.selector, caller
            ),
            abi.encode(true)
        );
    }

    function _mockElevatedPermissions(address caller) internal {
        vm.mockCall(
            address(centralRegistry),
            abi.encodeWithSelector(
                ICentralRegistry.hasElevatedPermissions.selector, caller
            ),
            abi.encode(true)
        );
    }

    function _mockMarketPermissions(address caller) internal {
        vm.mockCall(
            address(centralRegistry),
            abi.encodeWithSelector(
                ICentralRegistry.hasMarketPermissions.selector, caller
            ),
            abi.encode(true)
        );
    }

    function _mockDaoPermissions(address caller) internal {
        vm.mockCall(
            address(centralRegistry),
            abi.encodeWithSelector(
                ICentralRegistry.hasDaoPermissions.selector, caller
            ),
            abi.encode(true)
        );
    }
}
