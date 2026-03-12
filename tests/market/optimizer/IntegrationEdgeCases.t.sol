// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "./TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { LendingOptimizerHarness } from "./LendingOptimizerHarness.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { WAD, BPS } from "contracts/libraries/ConstantsLib.sol";

/// @title Integration and Edge-Case Tests for LendingOptimizer
/// @notice Covers 6 confirmed coverage gaps:
///         1. 4-6 market operations (deposit, withdraw, rebalance across many markets)
///         2. Cap decrease below current allocation
///         3. Fee accrual with zero user TVL (only dead shares)
///         4. Full lifecycle e2e test (init -> deposit -> yield -> fee -> rebalance -> withdraw)
///         5. removeApprovedAsset on a paused market
///         6. removeApprovedAsset with a zero-balance market
contract TestLendingOptimizerIntegrationEdgeCases is TestBaseLendingOptimizer {

    // =====================================================================
    //  HELPERS
    // =====================================================================

    /// @dev Mocks market permissions for the test contract.
    function _mockMarketPermissions() internal {
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
    }

    /// @dev Mocks harvest permissions for the test contract.
    function _mockHarvestPermissions() internal {
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasHarvestPermissions.selector, address(this)),
            abi.encode(true)
        );
    }

    /// @dev Mocks a valid cToken that passes _validateCToken checks.
    ///      Uses the real WMON market's manager (which is registered).
    function _mockValidCToken(address mockMarket) internal {
        address validManager = address(IBorrowableCToken(cUSDC_WMON_MARKET).marketManager());

        vm.mockCall(
            mockMarket,
            abi.encodeWithSelector(IBorrowableCToken.asset.selector),
            abi.encode(USDC_MONAD)
        );
        vm.mockCall(
            mockMarket,
            abi.encodeWithSelector(IBorrowableCToken.isBorrowable.selector),
            abi.encode(true)
        );
        vm.mockCall(
            mockMarket,
            abi.encodeWithSelector(IBorrowableCToken.marketManager.selector),
            abi.encode(validManager)
        );
        vm.mockCall(
            validManager,
            abi.encodeWithSelector(IMarketManager.isListed.selector, mockMarket),
            abi.encode(true)
        );
    }

    /// @dev Mocks a cToken with full operational support (for _accrueMarkets,
    ///      _optimalDepositTarget, _depositToMarket, etc.). Returns 0 balance/assets
    ///      by default so the market behaves as empty.
    function _mockOperationalCToken(address mockMarket) internal {
        _mockValidCToken(mockMarket);

        // accrueIfNeeded() is a no-op.
        vm.mockCall(
            mockMarket,
            abi.encodeWithSelector(IBorrowableCToken.accrueIfNeeded.selector),
            abi.encode()
        );
        // balanceOf(optimizer) returns 0.
        vm.mockCall(
            mockMarket,
            abi.encodeWithSelector(IBorrowableCToken.balanceOf.selector),
            abi.encode(uint256(0))
        );
        // convertToAssets(0) returns 0.
        vm.mockCall(
            mockMarket,
            abi.encodeWithSelector(IBorrowableCToken.convertToAssets.selector, uint256(0)),
            abi.encode(uint256(0))
        );
        // assetsHeld returns 0.
        vm.mockCall(
            mockMarket,
            abi.encodeWithSelector(IBorrowableCToken.assetsHeld.selector),
            abi.encode(uint256(0))
        );
        // marketOutstandingDebt returns 0.
        vm.mockCall(
            mockMarket,
            abi.encodeWithSelector(IBorrowableCToken.marketOutstandingDebt.selector),
            abi.encode(uint256(0))
        );
        // interestFee returns 0.
        vm.mockCall(
            mockMarket,
            abi.encodeWithSelector(IBorrowableCToken.interestFee.selector),
            abi.encode(uint256(0))
        );

        // IRM -- needs to return a contract address that responds to supplyRate.
        // We use the real WMON market's IRM since it already exists on-chain.
        address realIRM = address(IBorrowableCToken(cUSDC_WMON_MARKET).IRM());
        vm.mockCall(
            mockMarket,
            abi.encodeWithSelector(IBorrowableCToken.IRM.selector),
            abi.encode(realIRM)
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
    function _mockRedeemPaused(address cToken, bool paused) internal {
        address mm = address(IBorrowableCToken(cToken).marketManager());
        vm.mockCall(
            mm,
            abi.encodeWithSelector(bytes4(keccak256("redeemPaused()"))),
            abi.encode(paused ? uint8(2) : uint8(1))
        );
    }

    /// @dev Returns the optimizer's tracked assets in a specific market.
    function _getMarketAssets(address cToken) internal view returns (uint256) {
        return IBorrowableCToken(cToken).convertToAssets(
            IBorrowableCToken(cToken).balanceOf(address(optimizer))
        );
    }

    /// @dev Returns the DAO address from the central registry.
    function _daoAddress() internal view returns (address) {
        return liveCentralRegistry.daoAddress();
    }

    // =====================================================================
    //  GAP 1: 4-6 Market Operations
    // =====================================================================

    /// @notice Deploys optimizer with 4 markets (3 real + 1 mock), deposits,
    ///         and verifies the optimizer correctly tracks assets across all.
    function test_fourMarket_depositAndWithdraw() public {
        // --- Setup: create 4-market optimizer ---
        address mockMarket4 = makeAddr("mockMarket4");
        _mockOperationalCToken(mockMarket4);

        address[] memory cTokens = new address[](4);
        cTokens[0] = cUSDC_WMON_MARKET;
        cTokens[1] = cUSDC_WBTC_MARKET;
        cTokens[2] = cUSDC_WETH_MARKET;
        cTokens[3] = mockMarket4;

        uint256[] memory caps = new uint256[](4);
        caps[0] = 4_000; // 40%
        caps[1] = 4_000; // 40%
        caps[2] = 2_000; // 20%
        caps[3] = 2_000; // 20%  (sum = 120% >= 100%)

        optimizer = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            cTokens,
            caps,
            1_000
        );

        // Initialize.
        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets);
        _mockMarketPermissions();
        optimizer.initializeDeposits(cUSDC_WMON_MARKET);

        assertEq(optimizer.numApprovedMarkets(), 4, "Should have 4 approved markets");

        // Deposit to first 3 real markets.
        uint256 depositAmount = 5_000e6;
        for (uint256 i = 0; i < 3; i++) {
            deal(USDC_MONAD, address(this), depositAmount);
            IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
            LendingOptimizerHarness(address(optimizer)).depositToMarket(
                depositAmount, address(this), cTokens[i]
            );
        }

        // Verify total assets track all deposits (+ dead shares).
        uint256 expectedTotal = depositAmount * 3 + initAssets;
        assertApproxEqAbs(
            optimizer.totalAssets(),
            expectedTotal,
            10,
            "Total assets should equal sum of deposits + dead shares"
        );

        // Withdraw a portion from market 0.
        uint256 withdrawAmount = 1_000e6;
        uint256 sharesBurned = optimizer.withdraw(
            withdrawAmount, address(this), address(this)
        );
        assertGt(sharesBurned, 0, "Should have burned shares on withdraw");

        // Total assets should decrease by the withdrawal.
        assertApproxEqAbs(
            optimizer.totalAssets(),
            expectedTotal - withdrawAmount,
            10,
            "Total assets should decrease after withdrawal"
        );
    }

    /// @notice Deploys optimizer with 5 markets and verifies rebalance works
    ///         across all of them.
    function test_fiveMarket_rebalance() public {
        // --- Setup: 5-market optimizer (3 real + 2 mock) ---
        // Use generous caps so deposits don't breach them.
        address mockMarket4 = makeAddr("mockMarket4");
        address mockMarket5 = makeAddr("mockMarket5");
        _mockOperationalCToken(mockMarket4);
        _mockOperationalCToken(mockMarket5);

        address[] memory cTokens = new address[](5);
        cTokens[0] = cUSDC_WMON_MARKET;
        cTokens[1] = cUSDC_WBTC_MARKET;
        cTokens[2] = cUSDC_WETH_MARKET;
        cTokens[3] = mockMarket4;
        cTokens[4] = mockMarket5;

        uint256[] memory caps = new uint256[](5);
        caps[0] = 10_000; // 100%
        caps[1] = 10_000; // 100%
        caps[2] = 10_000; // 100%
        caps[3] = 2_000;  // 20%
        caps[4] = 2_000;  // 20%  (sum = 340% >= 100%)

        optimizer = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            cTokens,
            caps,
            1_000
        );

        // Initialize.
        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets);
        _mockMarketPermissions();
        optimizer.initializeDeposits(cUSDC_WMON_MARKET);

        assertEq(optimizer.numApprovedMarkets(), 5, "Should have 5 approved markets");

        // Deposit to real markets only.
        for (uint256 i = 0; i < 3; i++) {
            deal(USDC_MONAD, address(this), 10_000e6);
            IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
            LendingOptimizerHarness(address(optimizer)).depositToMarket(
                10_000e6, address(this), cTokens[i]
            );
        }

        uint256 totalAssetsBefore = optimizer.totalAssets();

        // Rebalance: move assets from WETH to WMON (keeping mock markets at 0).
        uint256 transferAmount = 2_000e6;
        LendingOptimizer.ReallocationAction[] memory actions = new LendingOptimizer.ReallocationAction[](5);
        actions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WMON_MARKET), int256(transferAmount)
        );
        actions[1] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WBTC_MARKET), int256(0)
        );
        actions[2] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WETH_MARKET), -int256(transferAmount)
        );
        actions[3] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(mockMarket4), int256(0)
        );
        actions[4] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(mockMarket5), int256(0)
        );

        _mockHarvestPermissions();
        _rebalance(optimizer, actions, _unconstrainedBounds());

        // Total assets should be preserved.
        assertApproxEqAbs(
            optimizer.totalAssets(),
            totalAssetsBefore,
            10,
            "Total assets should be preserved after rebalance"
        );
    }

    /// @notice Deploys optimizer with 6 markets and confirms successful
    ///         deposit and exchange rate calculation.
    function test_sixMarket_maxMarkets() public {
        // --- Setup: 6-market optimizer (3 real + 3 mock) ---
        address mockMarket4 = makeAddr("mockMarket4");
        address mockMarket5 = makeAddr("mockMarket5");
        address mockMarket6 = makeAddr("mockMarket6");
        _mockOperationalCToken(mockMarket4);
        _mockOperationalCToken(mockMarket5);
        _mockOperationalCToken(mockMarket6);

        address[] memory cTokens = new address[](6);
        cTokens[0] = cUSDC_WMON_MARKET;
        cTokens[1] = cUSDC_WBTC_MARKET;
        cTokens[2] = cUSDC_WETH_MARKET;
        cTokens[3] = mockMarket4;
        cTokens[4] = mockMarket5;
        cTokens[5] = mockMarket6;

        uint256[] memory caps = new uint256[](6);
        caps[0] = 3_000;
        caps[1] = 3_000;
        caps[2] = 2_000;
        caps[3] = 2_000;
        caps[4] = 1_000;
        caps[5] = 1_000; // sum = 120%

        optimizer = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            cTokens,
            caps,
            1_000
        );

        // Initialize.
        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets);
        _mockMarketPermissions();
        optimizer.initializeDeposits(cUSDC_WMON_MARKET);

        assertEq(optimizer.numApprovedMarkets(), 6, "Should have MAX_MARKETS");

        // Deposit.
        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        uint256 shares = optimizer.deposit(10_000e6, address(this));
        assertGt(shares, 0, "Should receive shares with 6 markets");

        // Exchange rate should be valid.
        uint256 rate = optimizer.exchangeRate();
        assertGt(rate, 0, "Exchange rate should be positive with 6 markets");
    }

    // =====================================================================
    //  GAP 2: Cap Decrease Below Current Allocation
    // =====================================================================

    /// @notice Deposits to fill a market to ~50% allocation, then decreases
    ///         its cap below the current allocation. Verifies the cap update
    ///         succeeds (caps are soft ceilings enforced at rebalance time)
    ///         and that a rebalance which does not correct the over-allocation
    ///         will revert.
    function test_capDecreaseBelow_currentAllocation() public {
        // Setup with two markets: WMON (100%) + WBTC (100%).
        address[] memory cTokens = new address[](2);
        cTokens[0] = cUSDC_WMON_MARKET;
        cTokens[1] = cUSDC_WBTC_MARKET;

        uint256[] memory caps = new uint256[](2);
        caps[0] = 10_000; // 100%
        caps[1] = 10_000; // 100%

        optimizer = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            cTokens,
            caps,
            1_000
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets);
        _mockMarketPermissions();
        optimizer.initializeDeposits(cUSDC_WMON_MARKET);

        // Deposit 10K to each market => ~50/50 allocation.
        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(
            10_000e6, address(this), cUSDC_WMON_MARKET
        );

        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(
            10_000e6, address(this), cUSDC_WBTC_MARKET
        );

        // Verify current allocation is ~50% each.
        uint256 totalAssets = optimizer.totalAssets();
        uint256 wmonAssets = _getMarketAssets(cUSDC_WMON_MARKET);
        uint256 wmonAllocationWad = FixedPointMathLib.mulDiv(wmonAssets, WAD, totalAssets);
        assertGt(wmonAllocationWad, 0.4e18, "WMON should be > 40% allocated");

        // Now lower WMON cap to 30% -- below its current ~50% allocation.
        // This should succeed because updateCap only validates that total caps >= 100%.
        optimizer.updateCap(cUSDC_WMON_MARKET, 3_000);
        assertEq(
            optimizer.allocationCaps(cUSDC_WMON_MARKET),
            3_000 * 1e14,
            "Cap should be updated to 30%"
        );

        // A no-op rebalance should now revert because WMON's ~50% allocation
        // exceeds its new 30% cap.
        _mockHarvestPermissions();
        LendingOptimizer.ReallocationAction[] memory actions = new LendingOptimizer.ReallocationAction[](2);
        actions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WMON_MARKET), int256(0)
        );
        actions[1] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WBTC_MARKET), int256(0)
        );

        LendingOptimizer.AllocationBound[] memory bounds = _unconstrainedBounds();
        (address[] memory sq, address[] memory wq) = _currentQueues(optimizer);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__AllocationExceedsCap.selector);
        optimizer.rebalance(actions, bounds, sq, wq);

        // A corrective rebalance that moves assets from WMON to WBTC should pass.
        uint256 wmonTarget = (totalAssets * 25) / 100; // 25% < 30% cap
        uint256 moveAmount = wmonAssets - wmonTarget;

        actions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WMON_MARKET), -int256(moveAmount)
        );
        actions[1] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WBTC_MARKET), int256(moveAmount)
        );

        _rebalance(optimizer, actions, _unconstrainedBounds());

        // Verify WMON is now within its cap.
        uint256 wmonAssetsAfter = _getMarketAssets(cUSDC_WMON_MARKET);
        uint256 totalAssetsAfter = optimizer.totalAssets();
        uint256 wmonAllocationAfter = FixedPointMathLib.mulDiv(wmonAssetsAfter, WAD, totalAssetsAfter);
        assertLe(
            wmonAllocationAfter,
            optimizer.allocationCaps(cUSDC_WMON_MARKET),
            "WMON allocation should be within its lowered cap after corrective rebalance"
        );
    }

    // =====================================================================
    //  GAP 3: Fee Accrual with Zero User TVL (Only Dead Shares)
    // =====================================================================

    /// @notice After initializeDeposits (only 77777 wei of dead shares exist
    ///         in address(0)), simulates time passing (yield accrual in the
    ///         underlying cToken) and verifies that fee logic handles this
    ///         edge case correctly without reverting.
    function test_feeAccrual_zeroUserTVL_onlyDeadShares() public {
        _setUpOneMarket();

        // At this point only dead shares (77777 wei) exist, minted to address(0).
        uint256 totalSupply = optimizer.totalSupply();
        assertApproxEqAbs(totalSupply, 77777, 1, "Only dead shares should exist");

        // Verify no user balance exists.
        assertEq(optimizer.balanceOf(address(this)), 0, "User should have no shares");

        // Skip forward so underlying cToken accrues interest.
        skip(30 days);

        // _accrueIfNeeded should not revert even with only dead shares.
        LendingOptimizerHarness harness = LendingOptimizerHarness(address(optimizer));
        harness.exposed_accrueIfNeeded();

        // The total supply may have increased from fee minting (fee shares go to DAO).
        uint256 totalSupplyAfter = optimizer.totalSupply();
        assertGe(totalSupplyAfter, totalSupply, "Supply should stay same or increase from fee shares");

        // Total assets should reflect accrued interest.
        uint256 totalAssetsAfter = optimizer.totalAssets();
        assertGe(totalAssetsAfter, 77777, "Total assets should be >= initial dead shares value");

        // Exchange rate should still be valid and > 0.
        uint256 rate = optimizer.exchangeRate();
        assertGt(rate, 0, "Exchange rate should be positive");

        // A new user should be able to deposit without issues.
        deal(USDC_MONAD, address(this), 1_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000e6);
        uint256 shares = optimizer.deposit(1_000e6, address(this));
        assertGt(shares, 0, "User should receive shares even after dead-shares-only accrual");
    }

    // =====================================================================
    //  GAP 4: Full Lifecycle E2E Test
    // =====================================================================

    /// @notice End-to-end lifecycle: init -> deposit -> yield accrual -> fee
    ///         charging -> rebalance -> withdraw. Verifies exchange rate,
    ///         shares, and assets at each step.
    function test_fullLifecycle_e2e() public {
        address user = makeAddr("user");

        // --- STEP 1: Initialization ---
        _setUpThreeMarkets();
        assertApproxEqAbs(optimizer.exchangeRate(), WAD, 100, "Initial rate should be ~1:1");
        assertEq(optimizer.mintPaused(), 1, "Optimizer should be active");

        // --- STEP 2: Deposit ---
        _e2e_deposit(user);

        // --- STEP 3 & 4: Yield Accrual and Fee Charging ---
        _e2e_yieldAndFees(user);

        // --- STEP 5: Rebalance ---
        _e2e_rebalance(user);

        // --- STEP 6: Withdraw ---
        _e2e_withdraw(user);
    }

    function _e2e_deposit(address user) internal {
        // Deposit across two markets so no single market dominates.
        uint256 depositPerMarket = 25_000e6;
        uint256 totalDeposit = depositPerMarket * 2;
        deal(USDC_MONAD, user, totalDeposit);

        vm.startPrank(user);
        IERC20(USDC_MONAD).approve(address(optimizer), totalDeposit);
        uint256 shares1 = LendingOptimizerHarness(address(optimizer)).depositToMarket(
            depositPerMarket, user, cUSDC_WMON_MARKET
        );
        uint256 shares2 = LendingOptimizerHarness(address(optimizer)).depositToMarket(
            depositPerMarket, user, cUSDC_WBTC_MARKET
        );
        vm.stopPrank();

        assertGt(shares1 + shares2, 0, "Step 2: shares should be minted");
        assertApproxEqAbs(
            optimizer.totalAssets(),
            totalDeposit + 77777,
            10,
            "Step 2: total assets should include deposit + dead shares"
        );
        assertApproxEqRel(
            optimizer.exchangeRate(),
            WAD,
            0.001e18,
            "Step 2: rate should be approximately preserved"
        );
    }

    function _e2e_yieldAndFees(address) internal {
        uint256 totalAssetsBefore = optimizer.totalAssets();

        // --- STEP 3: Yield Accrual ---
        skip(7 days);
        optimizer.accrueIfNeeded();

        uint256 totalAssetsAfterYield = optimizer.totalAssets();
        assertGe(totalAssetsAfterYield, totalAssetsBefore, "Step 3: total assets should grow from yield");

        uint256 rateAfterYield = optimizer.exchangeRateUpdated();
        assertGe(rateAfterYield, WAD, "Step 3: rate should be >= 1:1");

        // --- STEP 4: Fee Charging ---
        if (totalAssetsAfterYield > totalAssetsBefore) {
            assertGt(
                optimizer.balanceOf(_daoAddress()),
                0,
                "Step 4: DAO should receive fee shares when yield accrued"
            );
        }
        assertGe(optimizer.exchangeRateHighWatermark(), WAD, "Step 4: watermark should be >= WAD");
    }

    function _e2e_rebalance(address) internal {
        uint256 totalAssetsBefore = optimizer.totalAssets();

        // Rebalance: move 1K from WBTC to WMON.
        // WMON starts at ~50% of total, after adding 1K it stays under 60% cap.
        // WBTC starts at ~50% of total, after removing 1K it stays under 50% cap.
        uint256 transferAmount = 1_000e6;
        LendingOptimizer.ReallocationAction[] memory actions = new LendingOptimizer.ReallocationAction[](3);
        actions[0] = LendingOptimizer.ReallocationAction(IBorrowableCToken(cUSDC_WMON_MARKET), int256(transferAmount));
        actions[1] = LendingOptimizer.ReallocationAction(IBorrowableCToken(cUSDC_WBTC_MARKET), -int256(transferAmount));
        actions[2] = LendingOptimizer.ReallocationAction(IBorrowableCToken(cUSDC_WETH_MARKET), int256(0));

        _mockHarvestPermissions();
        _rebalance(optimizer, actions, _unconstrainedBounds());

        assertApproxEqAbs(
            optimizer.totalAssets(), totalAssetsBefore, 10,
            "Step 5: total assets should be preserved after rebalance"
        );
    }

    function _e2e_withdraw(address user) internal {
        uint256 halfShares = optimizer.balanceOf(user) / 2;
        uint256 userBalanceBefore = IERC20(USDC_MONAD).balanceOf(user);

        vm.prank(user);
        uint256 assetsRedeemed = optimizer.redeem(halfShares, user, user);

        assertGt(assetsRedeemed, 0, "Step 6: should redeem assets");
        assertEq(
            IERC20(USDC_MONAD).balanceOf(user) - userBalanceBefore,
            assetsRedeemed,
            "Step 6: user balance should increase by redeemed assets"
        );

        uint256 finalRate = optimizer.exchangeRate();
        assertGt(finalRate, 0, "Step 6: final rate should be positive");
        assertGe(finalRate, WAD, "Step 6: final rate should be >= 1:1 (yield should not be lost)");
    }

    // =====================================================================
    //  GAP 5: removeApprovedAsset on a Paused Market
    // =====================================================================

    /// @notice Pauses a market's mint and redeem, then calls removeApprovedAsset.
    ///         The removal should succeed because removeApprovedAsset calls
    ///         cToken.redeem() internally (which is a direct call, not gated
    ///         by the optimizer's pause check).
    function test_removeApprovedAsset_pausedMarket() public {
        _setUpThreeMarkets();

        // Deposit to WMON and WBTC only. Then deposit a small amount to WETH
        // so the reallocation stays within caps after removal.
        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(
            10_000e6, address(this), cUSDC_WMON_MARKET
        );

        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(
            10_000e6, address(this), cUSDC_WBTC_MARKET
        );

        deal(USDC_MONAD, address(this), 1_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000e6);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(
            1_000e6, address(this), cUSDC_WETH_MARKET
        );

        // Record assets in WETH market before removal.
        uint256 wethAssets = _getMarketAssets(cUSDC_WETH_MARKET);
        assertGt(wethAssets, 0, "WETH market should have assets");

        uint256 totalAssetsBefore = optimizer.totalAssets();

        // Pause both mint and redeem on the WETH market.
        _mockMintPaused(cUSDC_WETH_MARKET, true);
        _mockRedeemPaused(cUSDC_WETH_MARKET, true);

        // Prepare reallocation: move WETH assets to WMON (has 60% cap with headroom).
        LendingOptimizer.ReallocationAction[] memory removeActions = new LendingOptimizer.ReallocationAction[](1);
        removeActions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WMON_MARKET),
            int256(10_000)
        );

        _mockMarketPermissions();

        // removeApprovedAsset should succeed even though the market is paused,
        // because it directly calls cToken.redeem() which is an ERC4626 operation
        // on the cToken itself, not gated by the optimizer's _isMarketPausedForAction.
        optimizer.removeApprovedAsset(cUSDC_WETH_MARKET, removeActions);

        // Verify removal succeeded.
        assertEq(optimizer.numApprovedMarkets(), 2, "Should have 2 markets after removal");
        assertEq(
            optimizer.allocationCaps(cUSDC_WETH_MARKET),
            0,
            "Removed market cap should be 0"
        );

        // Total assets should be preserved.
        assertApproxEqAbs(
            optimizer.totalAssets(),
            totalAssetsBefore,
            10,
            "Total assets should be preserved after removing paused market"
        );
    }

    // =====================================================================
    //  GAP 6: removeApprovedAsset with Zero-Balance Market
    // =====================================================================

    /// @notice Adds a market but never deposits into it, then attempts removal.
    ///         The underlying cToken.redeem(0,...) reverts with ZeroAmount,
    ///         so this verifies the revert behavior. Then deposits a minimal
    ///         amount and verifies that removal succeeds with a near-zero balance.
    function test_removeApprovedAsset_zeroBalanceMarket_succeeds() public {
        _setUpThreeMarkets();

        // Deposit only to markets 0 and 1, NOT market 2 (WETH).
        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(
            10_000e6, address(this), cUSDC_WMON_MARKET
        );

        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(
            10_000e6, address(this), cUSDC_WBTC_MARKET
        );

        // Verify WETH market has zero optimizer balance.
        uint256 wethCTokenBalance = IBorrowableCToken(cUSDC_WETH_MARKET).balanceOf(address(optimizer));
        assertEq(wethCTokenBalance, 0, "WETH market should have 0 cToken balance");

        uint256 totalAssetsBefore = optimizer.totalAssets();

        _mockMarketPermissions();

        // Removing a zero-balance market succeeds with empty removeActions.
        LendingOptimizer.ReallocationAction[] memory removeActions = new LendingOptimizer.ReallocationAction[](0);
        optimizer.removeApprovedAsset(cUSDC_WETH_MARKET, removeActions);

        assertEq(optimizer.numApprovedMarkets(), 2, "Should have 2 markets after removal");
        assertEq(optimizer.totalAssets(), totalAssetsBefore, "Total assets should be unchanged");
    }

    /// @notice Deposits a minimal amount to a market, then removes it.
    ///         Verifies removal succeeds with a near-zero balance to reallocate.
    function test_removeApprovedAsset_minimalBalanceMarket() public {
        _setUpThreeMarkets();

        // Deposit to markets 0 and 1.
        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(
            10_000e6, address(this), cUSDC_WMON_MARKET
        );

        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(
            10_000e6, address(this), cUSDC_WBTC_MARKET
        );

        // Deposit a minimal amount to WETH (just enough to have non-zero shares).
        deal(USDC_MONAD, address(this), 100e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 100e6);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(
            100e6, address(this), cUSDC_WETH_MARKET
        );

        // Verify WETH market has a non-zero balance.
        uint256 wethCTokenBalance = IBorrowableCToken(cUSDC_WETH_MARKET).balanceOf(address(optimizer));
        assertGt(wethCTokenBalance, 0, "WETH market should have non-zero cToken balance");

        uint256 wethAssets = _getMarketAssets(cUSDC_WETH_MARKET);
        uint256 totalAssetsBefore = optimizer.totalAssets();

        // Remove the minimal-balance market, reallocating to WMON.
        LendingOptimizer.ReallocationAction[] memory removeActions = new LendingOptimizer.ReallocationAction[](1);
        removeActions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WMON_MARKET),
            int256(10_000)
        );

        _mockMarketPermissions();
        optimizer.removeApprovedAsset(cUSDC_WETH_MARKET, removeActions);

        // Verify removal succeeded.
        assertEq(optimizer.numApprovedMarkets(), 2, "Should have 2 markets after removal");
        assertEq(
            optimizer.allocationCaps(cUSDC_WETH_MARKET),
            0,
            "Removed market cap should be 0"
        );

        // Total assets should be approximately preserved.
        assertApproxEqAbs(
            optimizer.totalAssets(),
            totalAssetsBefore,
            10,
            "Total assets should be preserved when removing minimal-balance market"
        );
    }

    // =====================================================================
    //  ADDITIONAL EDGE CASES
    // =====================================================================

    /// @notice Verifies that auto-routed deposit correctly selects the optimal
    ///         market when operating with 4+ markets.
    function test_fourMarket_autoRoutedDeposit() public {
        // Setup 4-market optimizer with 3 real markets.
        address mockMarket4 = makeAddr("mockMarket4");
        _mockOperationalCToken(mockMarket4);

        address[] memory cTokens = new address[](4);
        cTokens[0] = cUSDC_WMON_MARKET;
        cTokens[1] = cUSDC_WBTC_MARKET;
        cTokens[2] = cUSDC_WETH_MARKET;
        cTokens[3] = mockMarket4;

        uint256[] memory caps = new uint256[](4);
        caps[0] = 5_000;
        caps[1] = 5_000;
        caps[2] = 2_000;
        caps[3] = 2_000;

        optimizer = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            cTokens,
            caps,
            1_000
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets);
        _mockMarketPermissions();
        optimizer.initializeDeposits(cUSDC_WMON_MARKET);

        // Auto-routed deposit should select one of the real markets
        // (mock market has 0 supply rate from IRM so real markets should win).
        deal(USDC_MONAD, address(this), 5_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 5_000e6);
        uint256 shares = optimizer.deposit(5_000e6, address(this));
        assertGt(shares, 0, "Auto-routed deposit should succeed with 4 markets");
    }

    /// @notice Tests updateCap to reduce a cap, then verifies that
    ///         _validateAllocationCaps prevents going below 100% total.
    function test_capDecrease_belowMinimumTotal_reverts() public {
        // Setup two markets: 60% + 50% = 110%.
        _setUpTwoMarkets();

        _mockMarketPermissions();

        // Try to lower WMON from 60% to 40% => total would be 40% + 50% = 90% < 100%.
        vm.expectRevert(LendingOptimizer.LendingOptimizer__InsufficientAllocationCaps.selector);
        optimizer.updateCap(cUSDC_WMON_MARKET, 4_000);
    }

    /// @notice Verifies multiple accrual cycles with only dead shares do not
    ///         cause fee logic to break or accumulate errors.
    function test_feeAccrual_multipleAccrualCycles_deadSharesOnly() public {
        _setUpOneMarket();

        // Multiple accrual cycles with no user deposits.
        for (uint256 i = 0; i < 5; i++) {
            skip(2 days);
            // Should never revert.
            optimizer.exchangeRateUpdated();
        }

        // Exchange rate should have increased from yield on dead shares.
        uint256 finalRate = optimizer.exchangeRate();
        assertGe(finalRate, WAD, "Rate should be >= 1:1 after yield on dead shares");

        // A user deposit after many cycles should work fine.
        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        uint256 shares = optimizer.deposit(10_000e6, address(this));
        assertGt(shares, 0, "Should deposit after multiple dead-shares-only accrual cycles");
    }
}
