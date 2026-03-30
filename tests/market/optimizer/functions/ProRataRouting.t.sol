// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { LendingOptimizerHarness } from "../LendingOptimizerHarness.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { WAD, BPS } from "contracts/libraries/ConstantsLib.sol";

contract TestProRataRouting is TestBaseLendingOptimizer {

    address marketManagerWMON;
    address marketManagerWBTC;
    address marketManagerWETH;

    function setUp() public override {
        super.setUp();
    }

    // ============ Helpers ============

    /// @dev Returns the optimizer's position in a given market (underlying terms).
    function _marketPosition(address cToken) internal view returns (uint256) {
        return IBorrowableCToken(cToken).convertToAssets(
            IBorrowableCToken(cToken).balanceOf(address(optimizer))
        );
    }

    /// @dev Mocks mintPaused for a specific cToken market.
    function _mockMintPaused(address cToken, bool paused) internal {
        address mm = address(IBorrowableCToken(cToken).marketManager());
        vm.mockCall(
            mm,
            abi.encodeWithSelector(IMarketManager.actionsPaused.selector, cToken),
            abi.encode(paused, false, false)
        );
    }

    /// @dev Mocks redeemPaused on a market manager (market-wide).
    function _mockRedeemPaused(address mm, bool paused) internal {
        vm.mockCall(
            mm,
            abi.encodeWithSelector(bytes4(keccak256("redeemPaused()"))),
            abi.encode(paused ? uint8(2) : uint8(1))
        );
    }

    /// @dev Mocks harvest permissions for the caller.
    function _mockHarvestPermissions() internal {
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasHarvestPermissions.selector, address(this)),
            abi.encode(true)
        );
    }

    /// @dev Caches market manager addresses. Call after setting up the optimizer.
    function _cacheMarketManagers() internal {
        marketManagerWMON = address(IBorrowableCToken(cUSDC_WMON_MARKET).marketManager());
        marketManagerWBTC = address(IBorrowableCToken(cUSDC_WBTC_MARKET).marketManager());
        marketManagerWETH = address(IBorrowableCToken(cUSDC_WETH_MARKET).marketManager());
    }

    // ============ 1. Pro-Rata Deposit Routing ============

    /// @notice Deposits are split proportionally to current market allocations.
    function test_proRataDeposit_twoMarkets_60_40_split() public {
        _setUpTwoMarkets();
        LendingOptimizerHarness harness = LendingOptimizerHarness(address(optimizer));

        // Seed market A with 600e6 and market B with 400e6.
        // Market A also has dead-share assets (~77777 from initializeDeposits).
        deal(USDC_MONAD, address(this), 1_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000e6);
        harness.depositToMarket(600e6, address(this), cUSDC_WMON_MARKET);
        harness.depositToMarket(400e6, address(this), cUSDC_WBTC_MARKET);

        uint256 posABefore = _marketPosition(cUSDC_WMON_MARKET);
        uint256 posBBefore = _marketPosition(cUSDC_WBTC_MARKET);
        uint256 totalBefore = posABefore + posBBefore;

        // Now do a pro-rata deposit of 1000e6.
        uint256 depositAmount = 1_000e6;
        deal(USDC_MONAD, user1, depositAmount);
        vm.startPrank(user1);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
        optimizer.deposit(depositAmount, user1);
        vm.stopPrank();

        uint256 posAAfter = _marketPosition(cUSDC_WMON_MARKET);
        uint256 posBAfter = _marketPosition(cUSDC_WBTC_MARKET);

        uint256 deltaA = posAAfter - posABefore;
        uint256 deltaB = posBAfter - posBBefore;

        // Pro-rata routing splits based on actual market positions.
        // Market A has posABefore, B has posBBefore. Compute expected split.
        uint256 expectedA = (depositAmount * posABefore) / totalBefore;
        uint256 expectedB = (depositAmount * posBBefore) / totalBefore;

        assertApproxEqAbs(deltaA, expectedA, 3, "Market A should receive proportional share");
        assertApproxEqAbs(deltaB, expectedB, 3, "Market B should receive proportional share");

        // Verify the total deposited approximately matches (within cToken rounding).
        assertApproxEqAbs(deltaA + deltaB, depositAmount, 3, "Total routed should match deposit");
    }

    /// @notice Three-market proportional split is routed correctly.
    function test_proRataDeposit_threeMarkets_proportional() public {
        _setUpThreeMarkets();
        LendingOptimizerHarness harness = LendingOptimizerHarness(address(optimizer));

        // Seed: 500e6 / 300e6 / 200e6 into the three markets.
        // Market 0 also has dead-share assets from initializeDeposits.
        deal(USDC_MONAD, address(this), 1_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000e6);
        harness.depositToMarket(500e6, address(this), cUSDC_WMON_MARKET);
        harness.depositToMarket(300e6, address(this), cUSDC_WBTC_MARKET);
        harness.depositToMarket(200e6, address(this), cUSDC_WETH_MARKET);

        uint256 pos0Before = _marketPosition(cUSDC_WMON_MARKET);
        uint256 pos1Before = _marketPosition(cUSDC_WBTC_MARKET);
        uint256 pos2Before = _marketPosition(cUSDC_WETH_MARKET);
        uint256 totalBefore = pos0Before + pos1Before + pos2Before;

        // Pro-rata deposit of 10_000e6.
        uint256 depositAmount = 10_000e6;
        deal(USDC_MONAD, user1, depositAmount);
        vm.startPrank(user1);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
        optimizer.deposit(depositAmount, user1);
        vm.stopPrank();

        uint256 delta0 = _marketPosition(cUSDC_WMON_MARKET) - pos0Before;
        uint256 delta1 = _marketPosition(cUSDC_WBTC_MARKET) - pos1Before;
        uint256 delta2 = _marketPosition(cUSDC_WETH_MARKET) - pos2Before;

        // Compute expected split based on actual positions (includes dead shares).
        uint256 expected0 = (depositAmount * pos0Before) / totalBefore;
        uint256 expected1 = (depositAmount * pos1Before) / totalBefore;
        uint256 expected2 = (depositAmount * pos2Before) / totalBefore;

        assertApproxEqAbs(delta0, expected0, 3, "Market 0 should receive proportional share");
        assertApproxEqAbs(delta1, expected1, 3, "Market 1 should receive proportional share");
        assertApproxEqAbs(delta2, expected2, 3, "Market 2 should receive proportional share");

        // Total routed should match deposit amount.
        assertApproxEqAbs(delta0 + delta1 + delta2, depositAmount, 5, "Total routed should match deposit");
    }

    /// @notice Total tracked assets matches deposit amount after pro-rata routing.
    function test_proRataDeposit_totalAssetsConsistent() public {
        _setUpTwoMarkets();
        LendingOptimizerHarness harness = LendingOptimizerHarness(address(optimizer));

        deal(USDC_MONAD, address(this), 800e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 800e6);
        harness.depositToMarket(500e6, address(this), cUSDC_WMON_MARKET);
        harness.depositToMarket(300e6, address(this), cUSDC_WBTC_MARKET);

        uint256 totalBefore = optimizer.totalAssets();

        uint256 depositAmount = 5_000e6;
        deal(USDC_MONAD, user1, depositAmount);
        vm.startPrank(user1);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
        optimizer.deposit(depositAmount, user1);
        vm.stopPrank();

        // Total assets should increase by ~depositAmount (minus cToken rounding).
        assertApproxEqAbs(
            optimizer.totalAssets(),
            totalBefore + depositAmount,
            3,
            "Total assets should increase by deposit amount"
        );
    }

    // ============ 2. Pro-Rata Withdrawal Routing ============

    /// @notice Withdrawals decrease each market proportionally.
    function test_proRataWithdraw_twoMarkets_proportional() public {
        _setUpTwoMarkets();
        LendingOptimizerHarness harness = LendingOptimizerHarness(address(optimizer));

        // Seed: 6000e6 in A, 4000e6 in B.
        // Market A also has dead-share assets from initializeDeposits.
        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        harness.depositToMarket(6_000e6, address(this), cUSDC_WMON_MARKET);
        harness.depositToMarket(4_000e6, address(this), cUSDC_WBTC_MARKET);

        uint256 posABefore = _marketPosition(cUSDC_WMON_MARKET);
        uint256 posBBefore = _marketPosition(cUSDC_WBTC_MARKET);
        uint256 totalBefore = posABefore + posBBefore;
        uint256 balanceBefore = IERC20(USDC_MONAD).balanceOf(address(this));

        // Withdraw 1000e6.
        uint256 withdrawAmount = 1_000e6;
        optimizer.withdraw(withdrawAmount, address(this), address(this));

        uint256 deltaA = posABefore - _marketPosition(cUSDC_WMON_MARKET);
        uint256 deltaB = posBBefore - _marketPosition(cUSDC_WBTC_MARKET);
        uint256 received = IERC20(USDC_MONAD).balanceOf(address(this)) - balanceBefore;

        // Compute expected proportional withdrawal based on actual positions.
        uint256 expectedA = (withdrawAmount * posABefore) / totalBefore;
        uint256 expectedB = (withdrawAmount * posBBefore) / totalBefore;

        assertApproxEqAbs(deltaA, expectedA, 3, "Market A should decrease proportionally");
        assertApproxEqAbs(deltaB, expectedB, 3, "Market B should decrease proportionally");
        // User should receive the full withdrawal amount.
        assertEq(received, withdrawAmount, "User should receive the full withdrawal");
    }

    /// @notice Redeem also routes proportionally.
    function test_proRataRedeem_threeMarkets_proportional() public {
        _setUpThreeMarkets();
        LendingOptimizerHarness harness = LendingOptimizerHarness(address(optimizer));

        // Seed: 500e6 / 300e6 / 200e6.
        deal(USDC_MONAD, address(this), 1_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000e6);
        harness.depositToMarket(500e6, address(this), cUSDC_WMON_MARKET);
        harness.depositToMarket(300e6, address(this), cUSDC_WBTC_MARKET);
        harness.depositToMarket(200e6, address(this), cUSDC_WETH_MARKET);

        uint256 pos0Before = _marketPosition(cUSDC_WMON_MARKET);
        uint256 pos1Before = _marketPosition(cUSDC_WBTC_MARKET);
        uint256 pos2Before = _marketPosition(cUSDC_WETH_MARKET);

        // Redeem half of our shares.
        uint256 sharesToRedeem = optimizer.balanceOf(address(this)) / 2;
        uint256 assets = optimizer.redeem(sharesToRedeem, address(this), address(this));

        uint256 delta0 = pos0Before - _marketPosition(cUSDC_WMON_MARKET);
        uint256 delta1 = pos1Before - _marketPosition(cUSDC_WBTC_MARKET);
        uint256 delta2 = pos2Before - _marketPosition(cUSDC_WETH_MARKET);

        // All three markets should decrease. Check proportions.
        uint256 totalDecreased = delta0 + delta1 + delta2;
        assertGt(totalDecreased, 0, "Should withdraw from markets");
        assertGt(assets, 0, "Should receive assets");

        // Approximate proportions: 50/30/20 of total withdrawn.
        assertApproxEqAbs(
            delta0 * 100 / totalDecreased, 50, 2,
            "Market 0 should decrease ~50% of total"
        );
        assertApproxEqAbs(
            delta1 * 100 / totalDecreased, 30, 2,
            "Market 1 should decrease ~30% of total"
        );
        assertApproxEqAbs(
            delta2 * 100 / totalDecreased, 20, 2,
            "Market 2 should decrease ~20% of total"
        );
    }

    // ============ 3. Liquidity-Limited Withdrawal Redistribution ============

    /// @notice When one market has limited liquidity, the shortfall is covered
    ///         by other markets. Uses mock to simulate constrained liquidity.
    function test_proRataWithdraw_liquidityLimited_redistributes() public {
        _setUpTwoMarkets();
        LendingOptimizerHarness harness = LendingOptimizerHarness(address(optimizer));

        // Deposit equally: 50/50 split.
        deal(USDC_MONAD, address(this), 20_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 20_000e6);
        harness.depositToMarket(10_000e6, address(this), cUSDC_WMON_MARKET);
        harness.depositToMarket(10_000e6, address(this), cUSDC_WBTC_MARKET);

        // Mock market B's assetsHeld to return very limited liquidity.
        // This simulates heavy borrowing draining the idle cash.
        vm.mockCall(
            cUSDC_WBTC_MARKET,
            abi.encodeWithSelector(IBorrowableCToken.assetsHeld.selector),
            abi.encode(uint256(1_000e6))
        );

        uint256 posABefore = _marketPosition(cUSDC_WMON_MARKET);
        uint256 posBBefore = _marketPosition(cUSDC_WBTC_MARKET);
        uint256 balanceBefore = IERC20(USDC_MONAD).balanceOf(address(this));

        // Withdraw 5000e6. Pro-rata wants ~50% from each (~2500 each).
        // But B's liquidity is capped at 1000, so A must cover the extra ~1500.
        uint256 withdrawAmount = 5_000e6;
        optimizer.withdraw(withdrawAmount, address(this), address(this));

        // Clear mock so subsequent calls work normally.
        vm.clearMockedCalls();

        uint256 received = IERC20(USDC_MONAD).balanceOf(address(this)) - balanceBefore;
        assertEq(received, withdrawAmount, "User should receive full withdrawal amount");

        uint256 deltaA = posABefore - _marketPosition(cUSDC_WMON_MARKET);
        uint256 deltaB = posBBefore - _marketPosition(cUSDC_WBTC_MARKET);

        // Market B should have been limited to ~1000e6 (its mock liquidity).
        assertApproxEqAbs(deltaB, 1_000e6, 3, "Market B should withdraw up to its liquidity");
        // Market A should cover the rest (~4000e6).
        assertApproxEqAbs(deltaA, 4_000e6, 3, "Market A should cover the shortfall");
    }

    // ============ 4. Pause Propagation — Deposits ============

    /// @notice Pausing ONE market's minting causes deposit() to revert.
    function test_pausePropagation_deposit_reverts_onePaused() public {
        _setUpThreeMarkets();
        _cacheMarketManagers();
        _depositToAllMarkets(10_000e6);

        // Pause mint on just market B.
        _mockMintPaused(cUSDC_WBTC_MARKET, true);

        deal(USDC_MONAD, user1, 1_000e6);
        vm.startPrank(user1);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000e6);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__MarketPaused.selector);
        optimizer.deposit(1_000e6, user1);
        vm.stopPrank();
    }

    /// @notice Pausing ONE market's minting causes mint() to revert.
    function test_pausePropagation_mint_reverts_onePaused() public {
        _setUpThreeMarkets();
        _cacheMarketManagers();
        _depositToAllMarkets(10_000e6);

        _mockMintPaused(cUSDC_WETH_MARKET, true);

        deal(USDC_MONAD, user1, 10_000e6);
        vm.startPrank(user1);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);

        uint256 sharesToMint = optimizer.previewDeposit(1_000e6);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__MarketPaused.selector);
        optimizer.mint(sharesToMint, user1);
        vm.stopPrank();
    }

    /// @notice maxDeposit returns 0 when any market is paused.
    function test_pausePropagation_maxDeposit_returns0() public {
        _setUpThreeMarkets();
        _cacheMarketManagers();
        _depositToAllMarkets(10_000e6);

        // Before pausing, maxDeposit should be max uint.
        assertEq(
            optimizer.maxDeposit(user1),
            type(uint256).max,
            "maxDeposit should be max before pause"
        );

        // Pause one market.
        _mockMintPaused(cUSDC_WMON_MARKET, true);

        assertEq(
            optimizer.maxDeposit(user1),
            0,
            "maxDeposit should be 0 when any market is paused"
        );
    }

    /// @notice maxMint returns 0 when any market is paused.
    function test_pausePropagation_maxMint_returns0() public {
        _setUpThreeMarkets();
        _cacheMarketManagers();
        _depositToAllMarkets(10_000e6);

        assertEq(
            optimizer.maxMint(user1),
            type(uint256).max,
            "maxMint should be max before pause"
        );

        _mockMintPaused(cUSDC_WBTC_MARKET, true);

        assertEq(
            optimizer.maxMint(user1),
            0,
            "maxMint should be 0 when any market is paused"
        );
    }

    // ============ 5. Pause Propagation — Withdrawals ============

    /// @notice Pausing ONE market's redemptions causes withdraw() to revert.
    function test_pausePropagation_withdraw_reverts_oneRedeemPaused() public {
        _setUpThreeMarkets();
        _cacheMarketManagers();
        _depositToAllMarkets(10_000e6);

        _mockRedeemPaused(marketManagerWBTC, true);

        vm.expectRevert(LendingOptimizer.LendingOptimizer__MarketPaused.selector);
        optimizer.withdraw(100e6, address(this), address(this));
    }

    /// @notice Pausing ONE market's redemptions causes redeem() to revert.
    function test_pausePropagation_redeem_reverts_oneRedeemPaused() public {
        _setUpThreeMarkets();
        _cacheMarketManagers();
        _depositToAllMarkets(10_000e6);

        _mockRedeemPaused(marketManagerWETH, true);

        uint256 shares = optimizer.balanceOf(address(this)) / 10;
        vm.expectRevert(LendingOptimizer.LendingOptimizer__MarketPaused.selector);
        optimizer.redeem(shares, address(this), address(this));
    }

    // ============ 6. Market Permissions Can Rebalance ============

    /// @notice rebalance() succeeds when called by market permissions holder
    ///         (not just harvester).
    function test_rebalance_withMarketPermissions() public {
        _setUpThreeMarkets();
        LendingOptimizerHarness harness = LendingOptimizerHarness(address(optimizer));

        // Deposit respecting caps: 50% / 40% / 10%.
        deal(USDC_MONAD, address(this), 50_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 50_000e6);
        harness.depositToMarket(25_000e6, address(this), cUSDC_WMON_MARKET);
        harness.depositToMarket(20_000e6, address(this), cUSDC_WBTC_MARKET);
        harness.depositToMarket(5_000e6, address(this), cUSDC_WETH_MARKET);

        address marketAdmin = makeAddr("marketAdmin");

        // Grant market permissions but NOT harvester.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasHarvestPermissions.selector, marketAdmin),
            abi.encode(false)
        );
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, marketAdmin),
            abi.encode(true)
        );

        // No-op rebalance should succeed.
        LendingOptimizer.ReallocationAction[] memory actions = new LendingOptimizer.ReallocationAction[](3);
        actions[0] = LendingOptimizer.ReallocationAction(IBorrowableCToken(cUSDC_WMON_MARKET), int256(0));
        actions[1] = LendingOptimizer.ReallocationAction(IBorrowableCToken(cUSDC_WBTC_MARKET), int256(0));
        actions[2] = LendingOptimizer.ReallocationAction(IBorrowableCToken(cUSDC_WETH_MARKET), int256(0));

        vm.prank(marketAdmin);
        optimizer.rebalance(actions, _unconstrainedBounds());
    }

    // ============ 7. First Deposit Edge Case ============

    /// @notice After initializeDeposits, all markets have 0 user assets
    ///         (only dead shares in one market). First deposit should go
    ///         entirely to approvedCTokensList[0].
    function test_firstDeposit_goesToFirstMarket() public {
        _setUpTwoMarkets();

        // After _setUpTwoMarkets, initializeDeposits has been called on
        // cUSDC_WMON_MARKET, placing 77777 of dead-share assets there.
        // Market B has 0 assets. A pro-rata deposit should recognize
        // that essentially all weight is in market A and route accordingly.
        // But let's check the edge case: if we consider the dead shares
        // as existing allocation, the split should be ~100% to market A.
        uint256 pos0Before = _marketPosition(cUSDC_WMON_MARKET);
        uint256 pos1Before = _marketPosition(cUSDC_WBTC_MARKET);

        assertEq(pos1Before, 0, "Market B should have 0 assets initially");
        assertGt(pos0Before, 0, "Market A should have dead-share assets");

        uint256 depositAmount = 1_000e6;
        deal(USDC_MONAD, user1, depositAmount);
        vm.startPrank(user1);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
        optimizer.deposit(depositAmount, user1);
        vm.stopPrank();

        uint256 pos0After = _marketPosition(cUSDC_WMON_MARKET);
        uint256 pos1After = _marketPosition(cUSDC_WBTC_MARKET);

        // Because only market A has assets (dead shares), all new deposits
        // should be routed to market A (pro-rata: 100% weight in A, 0% in B).
        assertApproxEqAbs(
            pos0After - pos0Before,
            depositAmount,
            2,
            "First deposit should go entirely to market A"
        );
        assertEq(pos1After, 0, "Market B should still have 0 assets");
    }

    /// @notice When using three markets and only one has dead-share assets,
    ///         first deposit goes entirely to the first market (the one with assets).
    function test_firstDeposit_threeMarkets_allToFirst() public {
        _setUpThreeMarkets();

        uint256 pos0Before = _marketPosition(cUSDC_WMON_MARKET);
        uint256 pos1Before = _marketPosition(cUSDC_WBTC_MARKET);
        uint256 pos2Before = _marketPosition(cUSDC_WETH_MARKET);

        assertEq(pos1Before, 0, "Market 1 should be empty");
        assertEq(pos2Before, 0, "Market 2 should be empty");

        uint256 depositAmount = 5_000e6;
        deal(USDC_MONAD, user1, depositAmount);
        vm.startPrank(user1);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
        optimizer.deposit(depositAmount, user1);
        vm.stopPrank();

        assertApproxEqAbs(
            _marketPosition(cUSDC_WMON_MARKET) - pos0Before,
            depositAmount,
            2,
            "First deposit should go entirely to market 0"
        );
        assertEq(_marketPosition(cUSDC_WBTC_MARKET), 0, "Market 1 should remain empty");
        assertEq(_marketPosition(cUSDC_WETH_MARKET), 0, "Market 2 should remain empty");
    }

    // ============ 8. exchangeRate() View Accuracy ============

    /// @notice After deposit + accrue, exchangeRate() matches exchangeRateUpdated().
    function test_exchangeRate_matchesUpdated_afterAccrue() public {
        _setUpTwoMarkets();
        LendingOptimizerHarness harness = LendingOptimizerHarness(address(optimizer));

        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        harness.depositToMarket(5_000e6, address(this), cUSDC_WMON_MARKET);
        harness.depositToMarket(5_000e6, address(this), cUSDC_WBTC_MARKET);

        // Accrue to sync state.
        optimizer.accrueIfNeeded();

        // Right after accrual, the cached exchangeRate should equal
        // exchangeRateUpdated (which also accrues, but state is fresh).
        uint256 cachedRate = optimizer.exchangeRate();
        uint256 updatedRate = optimizer.exchangeRateUpdated();

        assertEq(cachedRate, updatedRate, "Rates should match right after accrual");
    }

    /// @notice After time passes without accruing, exchangeRate() is stale
    ///         (less than exchangeRateUpdated).
    function test_exchangeRate_staleAfterTimeSkip() public {
        _setUpTwoMarkets();
        LendingOptimizerHarness harness = LendingOptimizerHarness(address(optimizer));

        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        harness.depositToMarket(5_000e6, address(this), cUSDC_WMON_MARKET);
        harness.depositToMarket(5_000e6, address(this), cUSDC_WBTC_MARKET);

        // Accrue to sync state.
        optimizer.accrueIfNeeded();

        // Skip time so interest accrues in underlying markets.
        skip(7 days);

        // Cached exchangeRate uses stale _totalAssets.
        uint256 cachedRate = optimizer.exchangeRate();
        // exchangeRateUpdated accrues markets first.
        uint256 updatedRate = optimizer.exchangeRateUpdated();

        // After time passes with real borrowers, interest accrues in
        // underlying markets. The updated rate should reflect this.
        assertLt(
            cachedRate,
            updatedRate,
            "Cached rate should be stale (less than updated rate)"
        );
    }

    // ============ 9. maxDeposit/maxMint with Pause Propagation ============

    /// @notice Full lifecycle: no pause -> returns max, pause -> returns 0,
    ///         unpause -> returns max again.
    function test_maxDeposit_pauseUnpause_lifecycle() public {
        _setUpThreeMarkets();
        _cacheMarketManagers();
        _depositToAllMarkets(10_000e6);

        // 1. No markets paused -> max.
        assertEq(optimizer.maxDeposit(user1), type(uint256).max, "Should be max when no pause");
        assertEq(optimizer.maxMint(user1), type(uint256).max, "Should be max when no pause");

        // 2. Pause one market -> 0.
        _mockMintPaused(cUSDC_WETH_MARKET, true);
        assertEq(optimizer.maxDeposit(user1), 0, "Should be 0 when one market paused");
        assertEq(optimizer.maxMint(user1), 0, "Should be 0 when one market paused");

        // 3. Unpause -> max again.
        _mockMintPaused(cUSDC_WETH_MARKET, false);
        assertEq(optimizer.maxDeposit(user1), type(uint256).max, "Should be max after unpause");
        assertEq(optimizer.maxMint(user1), type(uint256).max, "Should be max after unpause");
    }

    /// @notice maxDeposit returns 0 when optimizer itself is paused (mintPaused=2).
    function test_maxDeposit_optimizerPaused_returns0() public {
        _setUpOneMarket();

        // Optimizer is initialized (mintPaused=1), maxDeposit should be max.
        assertEq(optimizer.maxDeposit(user1), type(uint256).max, "Should be max when active");

        // Pause the optimizer itself.
        optimizer.setMintPaused(true);

        assertEq(optimizer.maxDeposit(user1), 0, "Should be 0 when optimizer paused");
        assertEq(optimizer.maxMint(user1), 0, "Should be 0 when optimizer paused");
    }

    // ============ maxWithdraw / maxRedeem pause propagation ============

    function test_maxWithdraw_returns0_whenRedeemPaused() public {
        _setUpTwoMarkets();

        // Deposit so user has shares.
        uint256 depositAmount = 10_000e6;
        deal(USDC_MONAD, user1, depositAmount);
        vm.startPrank(user1);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
        optimizer.deposit(depositAmount, user1);
        vm.stopPrank();

        // Sanity: maxWithdraw > 0 before pause.
        assertGt(optimizer.maxWithdraw(user1), 0, "Should be > 0 before pause");
        assertGt(optimizer.maxRedeem(user1), 0, "Should be > 0 before pause");

        // Pause redemptions on one market.
        address mm = address(IBorrowableCToken(cUSDC_WMON_MARKET).marketManager());
        _mockRedeemPaused(mm, true);

        assertEq(optimizer.maxWithdraw(user1), 0, "maxWithdraw should be 0 when redeem paused");
        assertEq(optimizer.maxRedeem(user1), 0, "maxRedeem should be 0 when redeem paused");
    }

}
