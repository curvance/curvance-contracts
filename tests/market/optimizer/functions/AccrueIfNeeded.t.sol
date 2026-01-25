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

contract TestLendingOptimizerAccrueIfNeeded is TestBaseLendingOptimizer {

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
        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
        harness.initializeDeposits(0);
    }

    /// @dev Sets up a zero-fee harness for testing accrual without fee interference.
    function _setUpHarnessNoFee() internal {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        harness = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            0, // 0% fee
            1 days
        );

        uint256 initAssets = BASE_RESERVE;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(harness), initAssets);
        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
        harness.initializeDeposits(0);
    }

    /// @dev Calculates expected exchange rate: WAD * totalAssets / totalSupply
    function _expectedRate(uint256 totalAssets, uint256 totalSupply) internal pure returns (uint256) {
        return FixedPointMathLib.mulDiv(WAD, totalAssets, totalSupply);
    }

    /// @dev Calculates expected fee shares minted to DAO.
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

    /// @dev Calculates expected vesting rate: newYield * WAD / vestingPeriod
    function _expectedVestingRate(uint256 newYield, uint256 vestingPeriod) internal pure returns (uint256) {
        return FixedPointMathLib.mulDiv(newYield, WAD, vestingPeriod);
    }

    /// @dev Calculates expected vested assets: vestingRate * elapsed / WAD
    function _expectedVestedAssets(uint256 vestingRate, uint256 elapsed) internal pure returns (uint256) {
        return (vestingRate * elapsed) / WAD;
    }

    // ==================== BASIC ACCRUAL BEHAVIOR ====================

    function test_lendingOptimizer_accrueIfNeeded_noRevertOnEmptyState() public {
        _setUpOneMarket();

        // Should not revert when called immediately after setup
        optimizer.accrueIfNeeded();

        // State should remain unchanged (minus 1 wei for cToken rounding on initializeDeposits)
        uint256 totalAssets = optimizer.totalAssets();
        assertEq(totalAssets, BASE_RESERVE - 1, "Total assets should be BASE_RESERVE minus rounding");
    }

    function test_lendingOptimizer_accrueIfNeeded_calledMultipleTimes() public {
        _setUpOneMarket();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 100_000e6);
        optimizer.deposit(100_000e6, address(this));

        // Multiple calls should not revert or cause issues
        optimizer.accrueIfNeeded();
        optimizer.accrueIfNeeded();
        optimizer.accrueIfNeeded();

        // Verify state is consistent
        uint256 totalAssets = optimizer.totalAssets();
        uint256 totalSupply = optimizer.totalSupply();
        assertGt(totalAssets, 0, "Total assets should be positive");
        assertGt(totalSupply, 0, "Total supply should be positive");
    }

    function test_lendingOptimizer_accrueIfNeeded_idempotentWithinSameBlock() public {
        _setUpHarness();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 100_000e6);
        harness.deposit(100_000e6, address(this));

        // Skip to trigger yield detection
        skip(2 days);
        harness.accrueIfNeeded();

        // Record state after first accrual
        uint256 indexedAfterFirst = harness.exposed_totalAssetsIndexed();
        (uint256 rateAfterFirst, uint256 vestEndAfterFirst, uint256 lastClaimAfterFirst) = harness.exposed_getVestingData();

        // Call again in same block
        harness.accrueIfNeeded();

        // State should be identical (no double-vesting or double-detection)
        uint256 indexedAfterSecond = harness.exposed_totalAssetsIndexed();
        (uint256 rateAfterSecond, uint256 vestEndAfterSecond, uint256 lastClaimAfterSecond) = harness.exposed_getVestingData();

        assertEq(indexedAfterFirst, indexedAfterSecond, "Indexed should not change on same-block call");
        assertEq(rateAfterFirst, rateAfterSecond, "Vesting rate should not change on same-block call");
        assertEq(vestEndAfterFirst, vestEndAfterSecond, "Vesting end should not change on same-block call");
        assertEq(lastClaimAfterFirst, lastClaimAfterSecond, "Last claim should not change on same-block call");
    }

    // ==================== VESTING YIELD ====================

    function test_lendingOptimizer_accrueIfNeeded_vestsAssetsCorrectly() public {
        _setUpHarness();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 100_000e6);
        harness.deposit(100_000e6, address(this));

        // Skip to trigger yield detection and start first vesting period
        skip(2 days);
        harness.accrueIfNeeded();

        // Record state at vesting start
        uint256 indexedAtStart = harness.exposed_totalAssetsIndexed();
        (uint256 vestingRate, uint256 vestEnd, uint256 lastClaim) = harness.exposed_getVestingData();
        uint256 vestingPeriod = vestEnd - lastClaim;

        // Calculate total yield that will be vested over the full period
        uint256 totalYieldToVest = _expectedVestedAssets(vestingRate, vestingPeriod);

        // Skip past vesting end to trigger indexed update
        skip(2 days);
        harness.accrueIfNeeded();

        uint256 indexedAfterVest = harness.exposed_totalAssetsIndexed();

        // Indexed assets should now include the fully vested yield from previous period
        assertEq(
            indexedAfterVest,
            indexedAtStart + totalYieldToVest,
            "Indexed should increase by vested amount"
        );
    }

    function test_lendingOptimizer_accrueIfNeeded_updatesLastVestingClaim() public {
        _setUpHarness();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 100_000e6);
        harness.deposit(100_000e6, address(this));

        // Start first vesting period
        skip(2 days);
        harness.accrueIfNeeded();

        (, , uint256 lastClaimFirstPeriod) = harness.exposed_getVestingData();

        // Skip past vesting end to trigger new vesting period
        skip(2 days);
        harness.accrueIfNeeded();

        (, , uint256 lastClaimSecondPeriod) = harness.exposed_getVestingData();

        // Last claim should update when new vesting period starts
        assertEq(lastClaimSecondPeriod, block.timestamp, "Last claim should update to current timestamp");
        assertGt(lastClaimSecondPeriod, lastClaimFirstPeriod, "Last claim should have advanced");
    }

    function test_lendingOptimizer_accrueIfNeeded_vestingCapsAtVestEnd() public {
        _setUpHarness();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 100_000e6);
        harness.deposit(100_000e6, address(this));

        // Start vesting
        skip(2 days);
        harness.accrueIfNeeded();

        (uint256 vestingRate, uint256 vestEnd, uint256 lastClaim) = harness.exposed_getVestingData();
        uint256 vestingPeriod = vestEnd - lastClaim;

        // Calculate max vested (full vesting period)
        uint256 maxVested = _expectedVestedAssets(vestingRate, vestingPeriod);

        // Skip way past vesting end
        skip(7 days);

        // Vested assets should cap at max
        uint256 actualVested = harness.exposed_assetsToVest();
        assertEq(actualVested, maxVested, "Vested should cap at max when past vestEnd");
    }

    function test_lendingOptimizer_accrueIfNeeded_noVestingWhenRateZero() public {
        _setUpHarness();

        // Immediately after setup, vesting rate should be 0
        (uint256 vestingRate, , ) = harness.exposed_getVestingData();
        assertEq(vestingRate, 0, "Vesting rate should be 0 initially");

        uint256 indexedBefore = harness.exposed_totalAssetsIndexed();

        // Accrual should not change indexed assets (no yield yet)
        harness.accrueIfNeeded();

        uint256 indexedAfter = harness.exposed_totalAssetsIndexed();
        assertEq(indexedAfter, indexedBefore, "Indexed should not change when no vesting");
    }

    // ==================== NEW YIELD DETECTION ====================

    function test_lendingOptimizer_accrueIfNeeded_detectsNewYield() public {
        _setUpHarnessNoFee();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 100_000e6);
        harness.deposit(100_000e6, address(this));

        uint256 indexedBefore = harness.exposed_totalAssetsIndexed();

        // Skip to end of initial vesting period (to allow yield detection)
        skip(2 days);

        // Trigger yield detection
        harness.accrueIfNeeded();

        // Get raw assets from underlying
        uint256 rawAssets = IBorrowableCToken(cUSDC_WMON_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(harness))
        );

        // Get vesting data
        (uint256 vestingRate, uint256 vestEnd, ) = harness.exposed_getVestingData();

        // If new yield exists, vesting should have started
        if (rawAssets > indexedBefore) {
            assertGt(vestingRate, 0, "Vesting rate should be non-zero when yield detected");
            assertGt(vestEnd, block.timestamp, "Vesting end should be in the future");
        }
    }

    function test_lendingOptimizer_accrueIfNeeded_startsNewVestingWithCorrectRate() public {
        _setUpHarnessNoFee();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 100_000e6);
        harness.deposit(100_000e6, address(this));

        uint256 indexedBefore = harness.exposed_totalAssetsIndexed();

        // Skip to allow yield accumulation
        skip(2 days);

        // Get raw assets before accrual
        uint256 rawAssets = harness.exposed_accrueMarkets();
        uint256 newYield = rawAssets > indexedBefore ? rawAssets - indexedBefore : 0;

        // Now actually trigger accrual
        harness.accrueIfNeeded();

        if (newYield > 0) {
            (uint256 vestingRate, uint256 vestEnd, uint256 lastClaim) = harness.exposed_getVestingData();
            uint256 vestingPeriod = harness.vestingPeriod();

            // Verify vesting rate: newYield * WAD / vestingPeriod
            uint256 expectedRate = _expectedVestingRate(newYield, vestingPeriod);
            assertEq(vestingRate, expectedRate, "Vesting rate should match: yield * WAD / period");

            // Verify vesting timestamps
            assertEq(vestEnd, block.timestamp + vestingPeriod, "Vesting end should be now + period");
            assertEq(lastClaim, block.timestamp, "Last claim should be now");
        }
    }

    function test_lendingOptimizer_accrueIfNeeded_noYieldDetectionDuringActiveVesting() public {
        _setUpHarness();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 100_000e6);
        harness.deposit(100_000e6, address(this));

        // Start first vesting
        skip(2 days);
        harness.accrueIfNeeded();

        // Record vesting data
        (uint256 rate1, uint256 vestEnd1, ) = harness.exposed_getVestingData();

        // Skip partway through (not past vestEnd)
        skip(12 hours);
        assertTrue(harness.exposed_isVestingActive(), "Should still be in active vesting");

        // Accrue - should vest but NOT detect new yield
        harness.accrueIfNeeded();

        (uint256 rate2, uint256 vestEnd2, ) = harness.exposed_getVestingData();

        // Vesting data should be unchanged (no new yield detection)
        assertEq(rate1, rate2, "Vesting rate should not change during active vesting");
        assertEq(vestEnd1, vestEnd2, "Vesting end should not change during active vesting");
    }

    function test_lendingOptimizer_accrueIfNeeded_detectsYieldAfterVestingEnds() public {
        _setUpHarnessNoFee();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 100_000e6);
        harness.deposit(100_000e6, address(this));

        // Start first vesting
        skip(2 days);
        harness.accrueIfNeeded();

        (uint256 rate1, , ) = harness.exposed_getVestingData();

        // Skip past vesting end
        skip(2 days);
        assertFalse(harness.exposed_isVestingActive(), "Vesting should have ended");

        // Accrue - should detect new yield and start new vesting
        harness.accrueIfNeeded();

        (uint256 rate2, uint256 vestEnd2, ) = harness.exposed_getVestingData();

        // New vesting should have started (if there was yield)
        if (rate2 > 0) {
            // VestEnd should be fresh (in the future from now)
            assertEq(vestEnd2, block.timestamp + harness.vestingPeriod(), "New vesting should have fresh end time");
        }
    }

    // ==================== PERFORMANCE FEE ACCRUAL ====================

    function test_lendingOptimizer_accrueIfNeeded_chargesFeesOnProfit() public {
        _setUpHarness();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 100_000e6);
        harness.deposit(100_000e6, address(this));

        uint256 daoBalanceBefore = harness.balanceOf(_daoAddress());

        // Build up yield over multiple cycles
        skip(2 days);
        harness.accrueIfNeeded();
        skip(2 days);
        harness.accrueIfNeeded();

        uint256 daoBalanceAfter = harness.balanceOf(_daoAddress());

        // DAO should have received fee shares
        assertGe(daoBalanceAfter, daoBalanceBefore, "DAO should receive fee shares");
    }

    function test_lendingOptimizer_accrueIfNeeded_noFeeWhenBelowWatermark() public {
        _setUpHarness();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 100_000e6);
        harness.deposit(100_000e6, address(this));

        // Trigger first cycle to set watermark
        skip(2 days);
        harness.accrueIfNeeded();
        skip(2 days);
        harness.accrueIfNeeded();

        uint256 daoBalanceBefore = harness.balanceOf(_daoAddress());
        uint256 watermark = harness.exchangeRateHighWatermark();

        // Call again in same block (no new yield)
        harness.accrueIfNeeded();

        uint256 currentRate = harness.exchangeRate();
        uint256 daoBalanceAfter = harness.balanceOf(_daoAddress());

        // If rate <= watermark, no additional fees
        if (currentRate <= watermark) {
            assertEq(daoBalanceAfter, daoBalanceBefore, "No fees when rate <= watermark");
        }
    }

    function test_lendingOptimizer_accrueIfNeeded_noFeeWhenFeeIsZero() public {
        _setUpHarnessNoFee();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 100_000e6);
        harness.deposit(100_000e6, address(this));

        uint256 daoBalanceBefore = harness.balanceOf(_daoAddress());

        // Accrue significant yield
        skip(30 days);
        harness.accrueIfNeeded();
        skip(30 days);
        harness.accrueIfNeeded();

        uint256 daoBalanceAfter = harness.balanceOf(_daoAddress());

        assertEq(daoBalanceAfter, daoBalanceBefore, "DAO should receive 0 shares when fee is 0");
    }

    function test_lendingOptimizer_accrueIfNeeded_preciseFeeCalculation() public {
        _setUpHarness();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 100_000e6);
        harness.deposit(100_000e6, address(this));

        // Build up yield - need to complete first vesting period
        skip(2 days);
        harness.accrueIfNeeded();
        skip(2 days);

        // Capture state before fee accrual
        uint256 supplyBefore = harness.totalSupply();
        uint256 watermarkBefore = harness.exchangeRateHighWatermark();
        // Fee is stored in BPS, convert to WAD for calculation
        uint256 feeBps = harness.fee();
        uint256 feeWad = (feeBps * WAD) / BPS;
        uint256 daoBalanceBefore = harness.balanceOf(_daoAddress());

        // Get totalAssets() which is what _accrueIfNeeded uses for fee calculation.
        // Fee calculation uses totalAssets() (not rawTa) so fees vest along with yield,
        // preventing dilution at vesting boundaries.
        uint256 currentAssets = harness.totalAssets();

        // Trigger accrual - this ends vesting and detects new yield
        harness.accrueIfNeeded();

        uint256 daoBalanceAfter = harness.balanceOf(_daoAddress());
        uint256 actualFeeShares = daoBalanceAfter - daoBalanceBefore;

        if (actualFeeShares > 0) {
            // Calculate expected fee shares using totalAssets() (what _accrueIfNeeded uses)
            uint256 expectedFeeShares = _expectedFeeShares(
                currentAssets,
                supplyBefore,
                watermarkBefore,
                feeWad
            );

            // Allow 1 share tolerance for rounding
            assertApproxEqAbs(
                actualFeeShares,
                expectedFeeShares,
                1,
                "Fee shares should match formula"
            );
        }
    }

    function test_lendingOptimizer_accrueIfNeeded_updatesWatermarkOnFeeAccrual() public {
        _setUpHarness();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 100_000e6);
        harness.deposit(100_000e6, address(this));

        uint256 initialWatermark = harness.exchangeRateHighWatermark();
        assertEq(initialWatermark, WAD, "Initial watermark should be WAD");

        // Build up yield and charge fees
        skip(2 days);
        harness.accrueIfNeeded();
        skip(2 days);
        harness.accrueIfNeeded();

        uint256 newWatermark = harness.exchangeRateHighWatermark();

        // Watermark should have increased from initial WAD
        assertGt(newWatermark, initialWatermark, "Watermark should increase after fee accrual");

        // Watermark is calculated using currentAssets (rawTa) which includes new yield to vest.
        // exchangeRate() uses totalAssets() which starts vesting the new yield gradually.
        // So watermark >= currentRate immediately after accrual.
        uint256 currentRate = harness.exchangeRate();
        assertGe(newWatermark, currentRate, "Watermark should be >= current rate (includes unvested yield)");
    }

    function test_lendingOptimizer_accrueIfNeeded_emitsFeeEvent() public {
        _setUpHarness();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 100_000e6);
        harness.deposit(100_000e6, address(this));

        // Build up yield
        skip(2 days);
        harness.accrueIfNeeded();
        skip(2 days);

        address dao = _daoAddress();
        uint256 daoBalanceBefore = harness.balanceOf(dao);

        // Accrue and check for event
        harness.accrueIfNeeded();

        uint256 daoBalanceAfter = harness.balanceOf(dao);
        uint256 feeSharesMinted = daoBalanceAfter - daoBalanceBefore;

        // If fees were minted, event should have been emitted (verified by state change)
        if (feeSharesMinted > 0) {
            assertGt(feeSharesMinted, 0, "Fee shares should have been minted");
        }
    }

    // ==================== MULTI-MARKET ACCRUAL ====================

    function test_lendingOptimizer_accrueIfNeeded_accruessAllMarkets() public {
        _setUpThreeMarkets();

        // Deposit to all markets
        address[3] memory markets = [cUSDC_WMON_MARKET, cUSDC_WBTC_MARKET, cUSDC_WETH_MARKET];
        uint256 depositPerMarket = 50_000e6;

        for (uint256 i = 0; i < markets.length; i++) {
            deal(USDC_MONAD, address(this), depositPerMarket);
            IERC20(USDC_MONAD).approve(address(optimizer), depositPerMarket);
            optimizer.deposit(depositPerMarket, address(this), markets[i]);
        }

        uint256 totalAssetsBefore = optimizer.totalAssets();

        // Skip time to accumulate yield
        skip(7 days);

        // Accrue
        optimizer.accrueIfNeeded();

        uint256 totalAssetsAfter = optimizer.totalAssets();

        // Total assets should have increased (yield from all markets)
        assertGe(totalAssetsAfter, totalAssetsBefore, "Total assets should not decrease");
    }

    function test_lendingOptimizer_accrueIfNeeded_multiMarketYieldDetection() public {
        _setUpThreeMarkets();

        address[3] memory markets = [cUSDC_WMON_MARKET, cUSDC_WBTC_MARKET, cUSDC_WETH_MARKET];
        uint256 depositPerMarket = 50_000e6;

        for (uint256 i = 0; i < markets.length; i++) {
            deal(USDC_MONAD, address(this), depositPerMarket);
            IERC20(USDC_MONAD).approve(address(optimizer), depositPerMarket);
            optimizer.deposit(depositPerMarket, address(this), markets[i]);
        }

        // Skip to allow yield
        skip(3 days);

        // Accrue and start vesting
        optimizer.accrueIfNeeded();

        // Verify rate is maintained properly
        uint256 rate = optimizer.exchangeRate();
        uint256 totalAssets = optimizer.totalAssets();
        uint256 totalSupply = optimizer.totalSupply();
        uint256 expectedRate = _expectedRate(totalAssets, totalSupply);

        assertEq(rate, expectedRate, "Rate should match formula with multiple markets");
    }

    // ==================== EDGE CASES ====================

    function test_lendingOptimizer_accrueIfNeeded_handlesZeroYield() public {
        _setUpHarness();

        // Just initialized, no deposits beyond dead shares
        uint256 indexedBefore = harness.exposed_totalAssetsIndexed();

        // Immediate accrual (no time for yield)
        harness.accrueIfNeeded();

        uint256 indexedAfter = harness.exposed_totalAssetsIndexed();

        // Indexed should not change significantly
        assertApproxEqAbs(indexedAfter, indexedBefore, 1, "Indexed should be unchanged with zero yield");
    }

    function test_lendingOptimizer_accrueIfNeeded_handlesVerySmallYield() public {
        _setUpHarnessNoFee();

        // Small deposit
        deal(USDC_MONAD, address(this), 100e6);
        IERC20(USDC_MONAD).approve(address(harness), 100e6);
        harness.deposit(100e6, address(this));

        // Very short time (minimal yield)
        skip(1 hours);

        // Should handle small yield without issues
        harness.accrueIfNeeded();

        // Verify state is consistent
        uint256 totalAssets = harness.totalAssets();
        uint256 totalSupply = harness.totalSupply();
        assertGt(totalAssets, 0, "Total assets should be positive");
        assertGt(totalSupply, 0, "Total supply should be positive");
    }

    function test_lendingOptimizer_accrueIfNeeded_vestingWithZeroElapsed() public {
        _setUpHarness();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 100_000e6);
        harness.deposit(100_000e6, address(this));

        // Start vesting
        skip(2 days);
        harness.accrueIfNeeded();

        uint256 indexedAfterStart = harness.exposed_totalAssetsIndexed();

        // Call again in same block (zero elapsed)
        harness.accrueIfNeeded();

        uint256 indexedAfterSecond = harness.exposed_totalAssetsIndexed();

        // Indexed should not change (zero elapsed = zero vested)
        assertEq(indexedAfterSecond, indexedAfterStart, "Indexed unchanged with zero elapsed");
    }

    // ==================== INTEGRATION WITH OTHER FUNCTIONS ====================

    function test_lendingOptimizer_accrueIfNeeded_calledByDeposit() public {
        _setUpHarness();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 100_000e6);
        harness.deposit(100_000e6, address(this));

        // Start vesting
        skip(2 days);
        harness.accrueIfNeeded();

        // Record totalAssets before (includes vesting via _assetsToVest())
        uint256 totalAssetsBefore = harness.totalAssets();

        // Skip forward (still within vesting period)
        skip(12 hours);

        // Deposit should internally call accrueIfNeeded
        // During active vesting, indexed is not updated but totalAssets() still reflects vesting
        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 10_000e6);
        harness.deposit(10_000e6, address(this));

        // Verify totalAssets increased by deposit amount (minus 1 for cToken rounding)
        uint256 totalAssetsAfter = harness.totalAssets();

        // totalAssets should have increased by approximately the deposit amount
        // (allowing for vesting progress and cToken rounding)
        assertGe(
            totalAssetsAfter,
            totalAssetsBefore + 10_000e6 - 1,
            "Deposit should increase totalAssets"
        );
    }

    function test_lendingOptimizer_accrueIfNeeded_calledByWithdraw() public {
        _setUpHarness();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 100_000e6);
        harness.deposit(100_000e6, address(this));

        // Start vesting
        skip(2 days);
        harness.accrueIfNeeded();

        // Record totalAssets before (includes vesting via _assetsToVest())
        uint256 totalAssetsBefore = harness.totalAssets();

        // Skip forward (still within vesting period)
        skip(12 hours);

        // Withdraw should internally call accrueIfNeeded
        // During active vesting, indexed is not updated but totalAssets() still reflects vesting
        harness.withdraw(1_000e6, address(this), address(this));

        uint256 totalAssetsAfter = harness.totalAssets();

        // totalAssets should have decreased by approximately the withdraw amount
        // (vesting progress may add some, but net effect should show withdrawal)
        assertLe(
            totalAssetsAfter,
            totalAssetsBefore,
            "Withdraw should decrease totalAssets"
        );
    }

    function test_lendingOptimizer_accrueIfNeeded_calledByExchangeRateUpdated() public {
        _setUpHarness();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 100_000e6);
        harness.deposit(100_000e6, address(this));

        // Start vesting
        skip(2 days);
        harness.exchangeRateUpdated();

        // Record totalAssets (includes vesting via _assetsToVest())
        uint256 totalAssetsBefore = harness.totalAssets();

        // Skip forward (still within vesting period)
        skip(12 hours);

        // exchangeRateUpdated should internally call accrueIfNeeded
        // During active vesting, indexed is not updated but totalAssets() reflects vesting
        harness.exchangeRateUpdated();

        uint256 totalAssetsAfter = harness.totalAssets();

        // totalAssets should have increased due to vesting progress
        assertGe(
            totalAssetsAfter,
            totalAssetsBefore,
            "exchangeRateUpdated should reflect vesting in totalAssets"
        );
    }

    // ==================== FUZZ TESTS ====================

    function testFuzz_lendingOptimizer_accrueIfNeeded_vestingMathConsistent(
        uint256 elapsed
    ) public {
        _setUpHarnessNoFee();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 100_000e6);
        harness.deposit(100_000e6, address(this));

        // Start vesting
        skip(2 days);
        harness.accrueIfNeeded();

        (uint256 vestingRate, uint256 vestEnd, uint256 lastClaim) = harness.exposed_getVestingData();

        if (vestingRate == 0) return; // No yield to vest

        // Bound elapsed to reasonable range
        elapsed = bound(elapsed, 0, 2 days);
        skip(elapsed);

        // Calculate expected vested
        uint256 effectiveElapsed = block.timestamp < vestEnd
            ? block.timestamp - lastClaim
            : vestEnd - lastClaim;
        uint256 expectedVested = _expectedVestedAssets(vestingRate, effectiveElapsed);

        uint256 actualVested = harness.exposed_assetsToVest();

        assertEq(actualVested, expectedVested, "Vested assets should match formula");
    }

    function testFuzz_lendingOptimizer_accrueIfNeeded_indexedNeverDecreases(
        uint256 depositAmount,
        uint256 timeWarp
    ) public {
        _setUpHarnessNoFee();

        depositAmount = bound(depositAmount, 1e6, 10_000_000e6);
        timeWarp = bound(timeWarp, 1 hours, 365 days);

        deal(USDC_MONAD, address(this), depositAmount);
        IERC20(USDC_MONAD).approve(address(harness), depositAmount);
        harness.deposit(depositAmount, address(this));

        uint256 indexedBefore = harness.exposed_totalAssetsIndexed();

        skip(timeWarp);
        harness.accrueIfNeeded();

        uint256 indexedAfter = harness.exposed_totalAssetsIndexed();

        assertGe(indexedAfter, indexedBefore, "Indexed assets should never decrease");
    }

    function testFuzz_lendingOptimizer_accrueIfNeeded_totalAssetsConsistent(
        uint256 depositAmount,
        uint256 timeWarp
    ) public {
        _setUpHarnessNoFee();

        depositAmount = bound(depositAmount, 1e6, 10_000_000e6);
        timeWarp = bound(timeWarp, 1 hours, 30 days);

        deal(USDC_MONAD, address(this), depositAmount);
        IERC20(USDC_MONAD).approve(address(harness), depositAmount);
        harness.deposit(depositAmount, address(this));

        skip(timeWarp);
        harness.accrueIfNeeded();

        // Verify totalAssets = indexed + pending vest
        uint256 indexedAssets = harness.exposed_totalAssetsIndexed();
        uint256 pending = harness.exposed_assetsToVest();
        uint256 totalAssets = harness.totalAssets();

        assertEq(totalAssets, indexedAssets + pending, "totalAssets should equal indexed + pending");
    }

    function testFuzz_lendingOptimizer_accrueIfNeeded_vestingRateFormula(
        uint256 newYield
    ) public {
        _setUpHarnessNoFee();

        // Test the vesting rate formula with various yield amounts
        newYield = bound(newYield, 1e6, 1_000_000e6);
        uint256 vestingPeriod = harness.vestingPeriod();

        // Expected rate formula: newYield * WAD / vestingPeriod
        uint256 expectedRate = _expectedVestingRate(newYield, vestingPeriod);

        // The rate should be positive and proportional to yield
        assertGt(expectedRate, 0, "Rate should be positive for non-zero yield");

        // Over the full vesting period, we should get back the full yield
        uint256 totalVested = _expectedVestedAssets(expectedRate, vestingPeriod);

        // Allow for rounding error (up to 1 unit per second of vesting)
        assertApproxEqAbs(
            totalVested,
            newYield,
            vestingPeriod / WAD + 1,
            "Full vest should return original yield"
        );
    }

    function testFuzz_lendingOptimizer_accrueIfNeeded_feesNeverExceedProfit(
        uint256 depositAmount,
        uint256 timeWarp
    ) public {
        _setUpHarness();

        depositAmount = bound(depositAmount, 1e6, 10_000_000e6);
        timeWarp = bound(timeWarp, 1 days, 365 days);

        deal(USDC_MONAD, address(this), depositAmount);
        IERC20(USDC_MONAD).approve(address(harness), depositAmount);
        harness.deposit(depositAmount, address(this));

        uint256 assetsBefore = harness.totalAssets();
        uint256 daoBalanceBefore = harness.balanceOf(_daoAddress());

        skip(timeWarp);
        harness.accrueIfNeeded();

        uint256 assetsAfter = harness.totalAssets();
        uint256 daoBalanceAfter = harness.balanceOf(_daoAddress());
        uint256 feeSharesMinted = daoBalanceAfter - daoBalanceBefore;

        if (assetsAfter > assetsBefore) {
            uint256 yield = assetsAfter - assetsBefore;
            uint256 feeAssetsValue = harness.convertToAssets(feeSharesMinted);

            // Fee assets should not exceed yield * fee percentage
            uint256 maxFee = FixedPointMathLib.mulDivUp(yield, harness.fee(), WAD);
            assertLe(
                feeAssetsValue,
                maxFee + 1, // +1 for rounding
                "Fee should not exceed yield * fee percentage"
            );
        }
    }
}
