// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { LendingOptimizerHarness } from "../LendingOptimizerHarness.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { WAD, BPS } from "contracts/libraries/ConstantsLib.sol";

contract TestLendingOptimizerExchangeRateUpdated is TestBaseLendingOptimizer {

    event PerformanceFeeAccrued(uint256 feeShares, address indexed recipient);

    LendingOptimizerHarness harness;

    uint256 constant BASE_RESERVE = 77777;

    function setUp() public override {
        super.setUp();
    }

    function _daoAddress() internal view returns (address) {
        return liveCentralRegistry.daoAddress();
    }

    /// @dev Sets up a harness with one market for internal function testing.
    function _setUpHarness() internal {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        harness = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000, // 10% fee
            1 days // vesting period
        );

        uint256 initAssets = BASE_RESERVE;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(harness), initAssets);
        harness.initializeDeposits(0);
    }

    /// @dev Calculates expected exchange rate: WAD * totalAssets / totalSupply
    function _expectedRate(uint256 totalAssets, uint256 totalSupply) internal pure returns (uint256) {
        return FixedPointMathLib.mulDiv(WAD, totalAssets, totalSupply);
    }

    /// @dev Calculates expected fee shares minted to DAO.
    ///      profit = currentAssets - (highWatermark * supply / WAD)
    ///      feeAssets = profit * feeWad / WAD (rounds up)
    ///      feeShares = feeAssets * supply / (currentAssets - feeAssets) (rounds up)
    function _expectedFeeShares(
        uint256 currentAssets,
        uint256 supply,
        uint256 highWatermark,
        uint256 feeWad
    ) internal pure returns (uint256) {
        uint256 highAssets = FixedPointMathLib.mulDiv(highWatermark, supply, WAD);
        if (currentAssets <= highAssets) return 0;

        uint256 profit = currentAssets - highAssets;
        uint256 feeAssets = FixedPointMathLib.mulDivUp(profit, feeWad, WAD);
        if (feeAssets == 0) return 0;

        return FixedPointMathLib.fullMulDivUp(feeAssets, supply, currentAssets - feeAssets);
    }

    // ==================== EXCHANGE RATE CALCULATION ====================

    function test_lendingOptimizer_exchangeRateUpdated_preciseRateAfterInit() public {
        _setUpOneMarket();

        // After initializeDeposits: 77777 assets, 77777 shares (1:1 ratio)
        uint256 totalAssets = optimizer.totalAssets();
        uint256 totalSupply = optimizer.totalSupply();

        assertEq(totalSupply, BASE_RESERVE, "Initial supply should be BASE_RESERVE");

        uint256 rate = optimizer.exchangeRateUpdated();
        uint256 expectedRate = _expectedRate(totalAssets, totalSupply);

        assertEq(rate, expectedRate, "Rate should exactly match formula");
    }

    function test_lendingOptimizer_exchangeRateUpdated_preciseRateAfterDeposit() public {
        _setUpOneMarket();

        uint256 depositAmount = 100_000e6;
        deal(USDC_MONAD, address(this), depositAmount);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);

        // Capture state before deposit
        uint256 totalAssetsBefore = optimizer.totalAssets();
        uint256 totalSupplyBefore = optimizer.totalSupply();
        uint256 rateBefore = _expectedRate(totalAssetsBefore, totalSupplyBefore);

        // Calculate expected shares: shares = assets * totalSupply / totalAssets
        uint256 expectedShares = FixedPointMathLib.mulDiv(
            depositAmount,
            totalSupplyBefore,
            totalAssetsBefore
        );

        uint256 actualShares = optimizer.deposit(depositAmount, address(this));
        assertEq(actualShares, expectedShares, "Shares minted should match formula");

        // After deposit: assets increased by depositAmount, shares increased by expectedShares
        uint256 totalAssetsAfter = totalAssetsBefore + depositAmount;
        uint256 totalSupplyAfter = totalSupplyBefore + expectedShares;

        uint256 rate = optimizer.exchangeRateUpdated();
        uint256 expectedRateAfter = _expectedRate(totalAssetsAfter, totalSupplyAfter);

        // Rate should be preserved (within 1 wei due to rounding)
        assertApproxEqAbs(rate, expectedRateAfter, 1, "Rate should match formula after deposit");
        assertApproxEqAbs(rate, rateBefore, 1, "Rate should be preserved after proportional deposit");
    }

    function test_lendingOptimizer_exchangeRateUpdated_preciseRateMultipleDeposits() public {
        _setUpOneMarket();

        uint256[] memory deposits = new uint256[](3);
        deposits[0] = 50_000e6;
        deposits[1] = 123_456e6;
        deposits[2] = 789_012e6;

        for (uint256 i = 0; i < deposits.length; i++) {
            deal(USDC_MONAD, address(this), deposits[i]);
            IERC20(USDC_MONAD).approve(address(optimizer), deposits[i]);

            uint256 totalAssetsBefore = optimizer.totalAssets();
            uint256 totalSupplyBefore = optimizer.totalSupply();

            uint256 expectedShares = FixedPointMathLib.mulDiv(
                deposits[i],
                totalSupplyBefore,
                totalAssetsBefore
            );

            uint256 actualShares = optimizer.deposit(deposits[i], address(this));
            assertEq(actualShares, expectedShares, "Shares should match for each deposit");

            uint256 rate = optimizer.exchangeRateUpdated();
            uint256 expectedRate = _expectedRate(
                totalAssetsBefore + deposits[i],
                totalSupplyBefore + expectedShares
            );
            assertApproxEqAbs(rate, expectedRate, 1, "Rate should match after each deposit");
        }
    }

    // ==================== VESTING MECHANISM ====================

    function test_lendingOptimizer_exchangeRateUpdated_preciseVestingCalculation() public {
        _setUpOneMarket();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 100_000e6);
        optimizer.deposit(100_000e6, address(this));

        // Skip forward past vesting period to detect yield from underlying market
        skip(2 days);

        // Trigger accrual - this detects new yield and starts vesting
        optimizer.exchangeRateUpdated();

        // Get raw assets from market (what the underlying actually holds)
        uint256 rawAssets = IBorrowableCToken(cUSDC_WMON_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer))
        );

        // Get indexed total assets (what optimizer tracks internally)
        uint256 indexedAssets = optimizer.totalAssets();

        // totalAssets should include pending vest
        // The vesting just started so most yield is still pending
        assertGe(rawAssets, indexedAssets, "Raw assets >= indexed (unvested yield exists)");
    }

    function test_lendingOptimizer_exchangeRateUpdated_vestingProgressionExact() public {
        _setUpOneMarket();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 100_000e6);
        optimizer.deposit(100_000e6, address(this));

        uint256 vestingPeriod = optimizer.vestingPeriod();
        assertEq(vestingPeriod, 1 days, "Vesting period should be 1 day");

        // Skip forward to end of initial period and trigger yield detection
        skip(2 days);
        optimizer.exchangeRateUpdated();

        // Record state at vesting start
        uint256 assetsAtStart = optimizer.totalAssets();
        uint256 supplyAtStart = optimizer.totalSupply();
        uint256 rateAtStart = optimizer.exchangeRateUpdated();

        // Skip forward to 50% through vesting
        skip(vestingPeriod / 2);
        uint256 rateAt50Pct = optimizer.exchangeRateUpdated();
        uint256 assetsAt50Pct = optimizer.totalAssets();

        // Skip forward to 100% through vesting
        skip(vestingPeriod / 2);
        uint256 rateAt100Pct = optimizer.exchangeRateUpdated();
        uint256 assetsAt100Pct = optimizer.totalAssets();

        // Verify progression
        assertGe(assetsAt50Pct, assetsAtStart, "Assets should increase at 50%");
        assertGe(assetsAt100Pct, assetsAt50Pct, "Assets should increase at 100%");
        assertGe(rateAt50Pct, rateAtStart, "Rate should increase at 50%");
        assertGe(rateAt100Pct, rateAt50Pct, "Rate should increase at 100%");

        // Rate calculation should be exact
        uint256 expectedRate100 = _expectedRate(assetsAt100Pct, supplyAtStart);
        assertEq(rateAt100Pct, expectedRate100, "Rate at 100% should match formula exactly");
    }

    // ==================== PERFORMANCE FEE CALCULATION ====================

    function test_lendingOptimizer_exchangeRateUpdated_preciseFeeCalculation() public {
        _setUpOneMarket();

        uint256 feeWad = optimizer.fee();
        assertEq(feeWad, 1_000 * 1e14, "Fee should be 10% (1000 BPS)");

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 100_000e6);
        optimizer.deposit(100_000e6, address(this));

        uint256 daoSharesBefore = optimizer.balanceOf(_daoAddress());
        uint256 watermarkBefore = optimizer.exchangeRateHighWatermark();

        // Skip forward to accrue yield and complete vesting
        skip(2 days);
        optimizer.exchangeRateUpdated();

        // Complete another vesting cycle to ensure fees are charged
        skip(2 days);

        // Capture state before fee accrual
        uint256 supplyBeforeFee = optimizer.totalSupply();
        uint256 assetsBeforeFee = optimizer.totalAssets();

        // This should trigger fee accrual
        optimizer.exchangeRateUpdated();

        uint256 daoSharesAfter = optimizer.balanceOf(_daoAddress());
        uint256 watermarkAfter = optimizer.exchangeRateHighWatermark();
        uint256 feeSharesMinted = daoSharesAfter - daoSharesBefore;

        // Verify watermark increased
        assertGe(watermarkAfter, watermarkBefore, "Watermark should increase");

        // If fees were minted, verify the calculation
        if (feeSharesMinted > 0) {
            // Calculate expected fee shares
            uint256 expectedFeeShares = _expectedFeeShares(
                assetsBeforeFee,
                supplyBeforeFee,
                watermarkBefore,
                feeWad
            );

            // Allow 1 share tolerance for rounding
            assertApproxEqAbs(
                feeSharesMinted,
                expectedFeeShares,
                1,
                "Fee shares should match formula"
            );
        }
    }

    function test_lendingOptimizer_exchangeRateUpdated_noFeeWhenBelowWatermark() public {
        _setUpOneMarket();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 100_000e6);
        optimizer.deposit(100_000e6, address(this));

        // Trigger first accrual to set watermark
        skip(2 days);
        optimizer.exchangeRateUpdated();
        skip(2 days);
        optimizer.exchangeRateUpdated();

        uint256 watermark = optimizer.exchangeRateHighWatermark();
        uint256 daoSharesBefore = optimizer.balanceOf(_daoAddress());

        // Call again in same block - no new yield, rate == watermark
        uint256 rate = optimizer.exchangeRateUpdated();

        uint256 daoSharesAfter = optimizer.balanceOf(_daoAddress());

        // If rate <= watermark, no fees should be minted
        if (rate <= watermark) {
            assertEq(daoSharesAfter, daoSharesBefore, "No fees when rate <= watermark");
        }
    }

    function test_lendingOptimizer_exchangeRateUpdated_noFeeWhenFeeIsZero() public {
        _setUpOneMarket();

        // Set fee to 0
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
        optimizer.setFee(0);
        assertEq(optimizer.fee(), 0, "Fee should be 0");

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 100_000e6);
        optimizer.deposit(100_000e6, address(this));

        uint256 daoSharesBefore = optimizer.balanceOf(_daoAddress());

        // Accrue yield
        skip(30 days);
        optimizer.exchangeRateUpdated();

        uint256 daoSharesAfter = optimizer.balanceOf(_daoAddress());
        assertEq(daoSharesAfter, daoSharesBefore, "DAO should receive exactly 0 shares when fee is 0");
    }

    function test_lendingOptimizer_exchangeRateUpdated_feeEventEmittedWithCorrectValues() public {
        _setUpOneMarket();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 100_000e6);
        optimizer.deposit(100_000e6, address(this));

        // Build up yield over multiple vesting cycles
        skip(2 days);
        optimizer.exchangeRateUpdated();
        skip(2 days);
        optimizer.exchangeRateUpdated();
        skip(2 days);

        // Capture state before accrual
        uint256 supplyBefore = optimizer.totalSupply();
        uint256 assetsBefore = optimizer.totalAssets();
        uint256 watermarkBefore = optimizer.exchangeRateHighWatermark();
        uint256 feeWad = optimizer.fee();
        uint256 daoSharesBefore = optimizer.balanceOf(_daoAddress());

        // Trigger accrual
        optimizer.exchangeRateUpdated();

        uint256 daoSharesAfter = optimizer.balanceOf(_daoAddress());
        uint256 actualFeeShares = daoSharesAfter - daoSharesBefore;

        if (actualFeeShares > 0) {
            // Verify against expected calculation
            uint256 expectedFeeShares = _expectedFeeShares(
                assetsBefore,
                supplyBefore,
                watermarkBefore,
                feeWad
            );
            assertApproxEqAbs(actualFeeShares, expectedFeeShares, 1, "Fee shares should match calculation");
        }
    }

    // ==================== WATERMARK BEHAVIOR ====================

    function test_lendingOptimizer_exchangeRateUpdated_watermarkUpdatesCorrectly() public {
        _setUpOneMarket();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 100_000e6);
        optimizer.deposit(100_000e6, address(this));

        uint256 initialWatermark = optimizer.exchangeRateHighWatermark();
        assertEq(initialWatermark, WAD, "Initial watermark should be WAD");

        // Accrue yield
        skip(2 days);
        optimizer.exchangeRateUpdated();
        skip(2 days);
        optimizer.exchangeRateUpdated();

        uint256 newWatermark = optimizer.exchangeRateHighWatermark();

        // Watermark should be updated to post-fee rate
        uint256 currentRate = optimizer.exchangeRate();

        // Watermark should equal current rate (post-fee)
        assertEq(newWatermark, currentRate, "Watermark should equal current rate after fee accrual");
    }

    function test_lendingOptimizer_exchangeRateUpdated_watermarkNeverDecreases() public {
        _setUpOneMarket();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 100_000e6);
        optimizer.deposit(100_000e6, address(this));

        uint256 previousWatermark = optimizer.exchangeRateHighWatermark();

        for (uint256 i = 0; i < 5; i++) {
            skip(3 days);
            optimizer.exchangeRateUpdated();

            uint256 currentWatermark = optimizer.exchangeRateHighWatermark();
            assertGe(currentWatermark, previousWatermark, "Watermark should never decrease");
            previousWatermark = currentWatermark;
        }
    }

    // ==================== RATE STABILITY ====================

    function test_lendingOptimizer_exchangeRateUpdated_rateMatchesViewFunction() public {
        _setUpOneMarket();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 100_000e6);
        optimizer.deposit(100_000e6, address(this));

        // After calling exchangeRateUpdated, the view should match
        uint256 rateUpdated = optimizer.exchangeRateUpdated();
        uint256 rateView = optimizer.exchangeRate();

        assertEq(rateUpdated, rateView, "exchangeRateUpdated and exchangeRate should match after accrual");
    }

    // ==================== MULTI-MARKET TESTS ====================

    function test_lendingOptimizer_exchangeRateUpdated_multiMarketPrecision() public {
        _setUpThreeMarkets();

        // Deposit to each market
        address[3] memory markets = [cUSDC_WMON_MARKET, cUSDC_WBTC_MARKET, cUSDC_WETH_MARKET];
        uint256 depositPerMarket = 50_000e6;

        for (uint256 i = 0; i < markets.length; i++) {
            deal(USDC_MONAD, address(this), depositPerMarket);
            IERC20(USDC_MONAD).approve(address(optimizer), depositPerMarket);
            optimizer.deposit(depositPerMarket, address(this), markets[i]);
        }

        uint256 totalDeposited = depositPerMarket * 3 + BASE_RESERVE;

        // Verify rate calculation with multiple markets
        uint256 rate = optimizer.exchangeRateUpdated();
        uint256 totalAssets = optimizer.totalAssets();
        uint256 totalSupply = optimizer.totalSupply();

        uint256 expectedRate = _expectedRate(totalAssets, totalSupply);
        assertEq(rate, expectedRate, "Rate should match formula with multiple markets");

        // Verify total assets approximately equals deposits (before yield)
        assertApproxEqRel(totalAssets, totalDeposited, 0.001e18, "Total assets should match deposits");
    }

    // ==================== FUZZ TESTS ====================

    function testFuzz_lendingOptimizer_exchangeRateUpdated_rateFormula(
        uint256 depositAmount
    ) public {
        _setUpOneMarket();

        depositAmount = bound(depositAmount, 1e6, 10_000_000e6);

        deal(USDC_MONAD, address(this), depositAmount);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
        optimizer.deposit(depositAmount, address(this));

        uint256 rate = optimizer.exchangeRateUpdated();
        uint256 totalAssets = optimizer.totalAssets();
        uint256 totalSupply = optimizer.totalSupply();

        uint256 expectedRate = _expectedRate(totalAssets, totalSupply);
        assertEq(rate, expectedRate, "Rate should always match formula exactly");
    }

    function testFuzz_lendingOptimizer_exchangeRateUpdated_rateNeverDecreases(
        uint256 timeWarp
    ) public {
        _setUpOneMarket();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 100_000e6);
        optimizer.deposit(100_000e6, address(this));

        uint256 rateBefore = optimizer.exchangeRateUpdated();

        timeWarp = bound(timeWarp, 1 hours, 365 days);
        skip(timeWarp);

        uint256 rateAfter = optimizer.exchangeRateUpdated();
        assertGe(rateAfter, rateBefore, "Rate should never decrease over time");
    }

    function testFuzz_lendingOptimizer_exchangeRateUpdated_depositPreservesRate(
        uint256 deposit1,
        uint256 deposit2
    ) public {
        _setUpOneMarket();

        deposit1 = bound(deposit1, 1e6, 1_000_000e6);
        deposit2 = bound(deposit2, 1e6, 1_000_000e6);

        // First deposit
        deal(USDC_MONAD, address(this), deposit1);
        IERC20(USDC_MONAD).approve(address(optimizer), deposit1);
        optimizer.deposit(deposit1, address(this));

        uint256 rateAfterFirst = optimizer.exchangeRateUpdated();

        // Second deposit
        deal(USDC_MONAD, address(this), deposit2);
        IERC20(USDC_MONAD).approve(address(optimizer), deposit2);
        optimizer.deposit(deposit2, address(this));

        uint256 rateAfterSecond = optimizer.exchangeRateUpdated();

        // Rate should be preserved (within rounding)
        assertEq(rateAfterSecond, rateAfterFirst, "Rate should be preserved across deposits");
    }

    // ==================== HARNESS TESTS: INTERNAL FUNCTION COVERAGE ====================

    function test_lendingOptimizer_exchangeRateUpdated_harness_vestingRateCalculation() public {
        _setUpHarness();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 100_000e6);
        harness.deposit(100_000e6, address(this));

        // Record indexed assets before yield detection
        uint256 indexedBefore = harness.exposed_totalAssetsIndexed();

        // Skip past vesting period to trigger yield detection
        skip(2 days);

        // Get raw assets from underlying market (includes accrued yield)
        uint256 rawAssets = harness.exposed_accrueMarkets();

        // Trigger accrual to detect yield and start vesting
        harness.exposed_accrueIfNeeded();

        // Get vesting data
        (uint256 vestingRate, uint256 vestingEnd, uint256 lastVestingClaim) = harness.exposed_getVestingData();

        // If new yield was detected, verify vesting rate calculation
        if (rawAssets > indexedBefore) {
            uint256 newYield = rawAssets - indexedBefore;
            uint256 vestingPeriod = harness.vestingPeriod();

            // Expected rate: newYield * WAD / vestingPeriod
            uint256 expectedRate = FixedPointMathLib.mulDiv(newYield, WAD, vestingPeriod);

            assertEq(vestingRate, expectedRate, "Vesting rate should match: yield * WAD / period");
            assertEq(vestingEnd, block.timestamp + vestingPeriod, "Vesting end should be now + period");
            assertEq(lastVestingClaim, block.timestamp, "Last claim should be now");
        }
    }

    function test_lendingOptimizer_exchangeRateUpdated_harness_assetsToVestCalculation() public {
        _setUpHarness();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 100_000e6);
        harness.deposit(100_000e6, address(this));

        // Trigger yield detection
        skip(2 days);
        harness.exchangeRateUpdated();

        // Get vesting data
        (uint256 vestingRate, uint256 vestingEnd, uint256 lastVestingClaim) = harness.exposed_getVestingData();

        if (vestingRate > 0) {
            // Skip partway through vesting
            uint256 elapsed = 6 hours;
            skip(elapsed);

            // Calculate expected vested assets
            // assets = vestingRate * elapsed / WAD
            uint256 expectedVested = (vestingRate * elapsed) / WAD;

            // Get actual from harness
            uint256 actualVested = harness.exposed_assetsToVest();

            assertEq(actualVested, expectedVested, "Vested assets should match: rate * elapsed / WAD");
        }
    }

    function test_lendingOptimizer_exchangeRateUpdated_harness_assetsToVestWithParams() public {
        _setUpHarness();

        // Test _assetsToVest with specific parameters
        uint256 vestingRate = 1000e18; // 1000 assets per second in WAD
        uint256 vestingEnd = block.timestamp + 1 days;
        uint256 lastVestingClaim = block.timestamp;

        // At t=0, no time elapsed
        uint256 vested0 = harness.exposed_assetsToVest(vestingRate, vestingEnd, lastVestingClaim);
        assertEq(vested0, 0, "No vesting at t=0");

        // Skip 100 seconds
        skip(100);
        uint256 vested100 = harness.exposed_assetsToVest(vestingRate, vestingEnd, lastVestingClaim);
        uint256 expected100 = (vestingRate * 100) / WAD;
        assertEq(vested100, expected100, "Vested after 100s should be rate * 100 / WAD");

        // Skip to exactly vesting end
        skip(1 days - 100);
        uint256 vestedEnd = harness.exposed_assetsToVest(vestingRate, vestingEnd, lastVestingClaim);
        uint256 expectedEnd = (vestingRate * 1 days) / WAD;
        assertEq(vestedEnd, expectedEnd, "Vested at end should be rate * period / WAD");

        // Skip past vesting end - should cap at vestingEnd
        skip(1 days);
        uint256 vestedPast = harness.exposed_assetsToVest(vestingRate, vestingEnd, lastVestingClaim);
        assertEq(vestedPast, expectedEnd, "Vested past end should cap at total");
    }

    function test_lendingOptimizer_exchangeRateUpdated_harness_indexedVsTotalAssets() public {
        _setUpHarness();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 100_000e6);
        harness.deposit(100_000e6, address(this));

        // Initially, indexed should equal total (no pending vest)
        uint256 indexed1 = harness.exposed_totalAssetsIndexed();
        uint256 total1 = harness.totalAssets();
        assertEq(indexed1, total1, "Initially indexed == total");

        // Trigger yield detection to start vesting
        skip(2 days);
        harness.exchangeRateUpdated();

        // Now during active vesting, total > indexed (pending vest exists)
        skip(12 hours);

        uint256 indexed2 = harness.exposed_totalAssetsIndexed();
        uint256 total2 = harness.totalAssets();
        uint256 pendingVest = harness.exposed_assetsToVest();

        assertEq(total2, indexed2 + pendingVest, "total = indexed + pendingVest");
    }

    function test_lendingOptimizer_exchangeRateUpdated_harness_vestingActiveCheck() public {
        _setUpHarness();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 100_000e6);
        harness.deposit(100_000e6, address(this));

        // Initially no active vesting
        assertFalse(harness.exposed_isVestingActive(), "No vesting initially");

        // Trigger yield detection
        skip(2 days);
        harness.exchangeRateUpdated();

        // Now vesting should be active
        assertTrue(harness.exposed_isVestingActive(), "Vesting active after yield detection");

        // Skip to end of vesting
        skip(1 days);
        harness.exchangeRateUpdated();

        // Vesting ended, may start new one depending on yield
        // Check that it properly transitioned
        (uint256 rate, uint256 vestEnd,) = harness.exposed_getVestingData();
        if (rate > 0) {
            assertGe(vestEnd, block.timestamp, "New vesting should have future end");
        }
    }

    function test_lendingOptimizer_exchangeRateUpdated_harness_noYieldDetectionDuringActiveVest() public {
        _setUpHarness();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 100_000e6);
        harness.deposit(100_000e6, address(this));

        // Start first vesting
        skip(2 days);
        harness.exchangeRateUpdated();

        // Get vesting data after first detection
        (uint256 rate1, uint256 vestEnd1,) = harness.exposed_getVestingData();

        // Skip partway through vesting (not past end)
        skip(12 hours);
        assertTrue(harness.exposed_isVestingActive(), "Should still be in active vesting");

        // Call accrueIfNeeded - should NOT detect new yield
        harness.exposed_accrueIfNeeded();

        // Vesting data should be unchanged (no new yield detection during active vest)
        (uint256 rate2, uint256 vestEnd2,) = harness.exposed_getVestingData();
        assertEq(rate1, rate2, "Vesting rate unchanged during active vest");
        assertEq(vestEnd1, vestEnd2, "Vesting end unchanged during active vest");
    }

    function test_lendingOptimizer_exchangeRateUpdated_harness_indexedUpdatesOnVest() public {
        _setUpHarness();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 100_000e6);
        harness.deposit(100_000e6, address(this));

        // Trigger yield detection
        skip(2 days);
        harness.exchangeRateUpdated();

        uint256 indexedAtStart = harness.exposed_totalAssetsIndexed();

        // Skip partway through vesting
        skip(12 hours);
        uint256 pendingVest = harness.exposed_assetsToVest();

        // Trigger accrual to vest pending assets
        harness.exposed_accrueIfNeeded();

        uint256 indexedAfterVest = harness.exposed_totalAssetsIndexed();

        // Indexed should have increased by vested amount
        assertEq(indexedAfterVest, indexedAtStart + pendingVest, "Indexed increases by vested amount");
    }

    function test_lendingOptimizer_exchangeRateUpdated_harness_rateMatchesInternalState() public {
        _setUpHarness();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 100_000e6);
        harness.deposit(100_000e6, address(this));

        // Trigger some yield cycles
        skip(2 days);
        harness.exchangeRateUpdated();
        skip(12 hours);

        // Get rate from public function
        uint256 rate = harness.exchangeRateUpdated();

        // Calculate rate from internal state
        uint256 indexedAssets = harness.exposed_totalAssetsIndexed();
        uint256 pending = harness.exposed_assetsToVest();
        uint256 totalAssets = indexedAssets + pending;
        uint256 totalSupply = harness.totalSupply();

        uint256 expectedRate = FixedPointMathLib.mulDiv(WAD, totalAssets, totalSupply);

        assertEq(rate, expectedRate, "Rate matches: WAD * (indexed + pending) / supply");
        assertEq(harness.totalAssets(), totalAssets, "totalAssets() = indexed + pending");
    }

    function testFuzz_lendingOptimizer_exchangeRateUpdated_harness_vestingMath(
        uint256 vestingRate,
        uint256 elapsed
    ) public {
        _setUpHarness();

        // Bound inputs to reasonable ranges
        vestingRate = bound(vestingRate, 1e12, 1e24); // Reasonable rate range
        elapsed = bound(elapsed, 1, 3 days); // Up to max vesting period

        uint256 vestingEnd = block.timestamp + 3 days;
        uint256 lastVestingClaim = block.timestamp;

        skip(elapsed);

        uint256 vested = harness.exposed_assetsToVest(vestingRate, vestingEnd, lastVestingClaim);

        // Expected: rate * min(elapsed, vestingEnd - lastClaim) / WAD
        uint256 effectiveElapsed = elapsed < 3 days ? elapsed : 3 days;
        uint256 expected = (vestingRate * effectiveElapsed) / WAD;

        assertEq(vested, expected, "Vested should match formula exactly");
    }
}
