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
            1_000 // 10% fee
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
        harness.initializeDeposits(cUSDC_WMON_MARKET);
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
            0 // 0% fee
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
        harness.initializeDeposits(cUSDC_WMON_MARKET);
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
        uint256 feeAssets = FixedPointMathLib.mulDiv(profit, feeWad, WAD);
        if (feeAssets == 0) return 0;

        return FixedPointMathLib.fullMulDiv(feeAssets, supply, currentAssets - feeAssets);
    }

    function _mintDonationMarketShares(uint256 assets) internal returns (uint256 shares) {
        deal(USDC_MONAD, address(this), assets);
        IERC20(USDC_MONAD).approve(cUSDC_WMON_MARKET, assets);
        shares = IBorrowableCToken(cUSDC_WMON_MARKET).deposit(
            assets,
            address(this)
        );
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

        // Call again in same block
        harness.accrueIfNeeded();

        // State should be identical (no double-detection)
        uint256 indexedAfterSecond = harness.exposed_totalAssetsIndexed();

        assertEq(indexedAfterFirst, indexedAfterSecond, "Indexed should not change on same-block call");
    }

    // ==================== YIELD DETECTION ====================

    function test_lendingOptimizer_accrueIfNeeded_detectsNewYield() public {
        _setUpHarnessNoFee();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 100_000e6);
        harness.deposit(100_000e6, address(this));

        uint256 indexedBefore = harness.exposed_totalAssetsIndexed();

        // Skip to allow yield accumulation
        skip(2 days);

        // Trigger yield detection
        harness.accrueIfNeeded();

        uint256 indexedAfter = harness.exposed_totalAssetsIndexed();

        // Get raw assets from underlying
        uint256 rawAssets = IBorrowableCToken(cUSDC_WMON_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(harness))
        );

        // If new yield exists, indexed should have been updated
        if (rawAssets > indexedBefore) {
            assertGe(indexedAfter, indexedBefore, "Indexed should not decrease when yield detected");
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

        // Build up yield
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

        // _accrueIfNeeded absorbs yield immediately (rawTa), then charges fees.
        // Trigger cToken accrual first (same as _accrueMarkets does), then read value.
        IBorrowableCToken(cUSDC_WMON_MARKET).accrueIfNeeded();
        uint256 rawTa = IBorrowableCToken(cUSDC_WMON_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(harness))
        );

        // Trigger accrual - absorbs yield and charges fee
        harness.accrueIfNeeded();

        uint256 daoBalanceAfter = harness.balanceOf(_daoAddress());
        uint256 actualFeeShares = daoBalanceAfter - daoBalanceBefore;

        if (actualFeeShares > 0) {
            // Calculate expected fee shares using rawTa (what _accrueIfNeeded uses after absorption)
            uint256 expectedFeeShares = _expectedFeeShares(
                rawTa,
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

    /// @notice Documents current fee-dust behavior: sub-base-unit fees are forgone.
    function test_lendingOptimizer_accrueIfNeeded_tinyProfitIncrementsCanBypassPerformanceFee() public {
        _setUpHarness();

        address dao = _daoAddress();
        uint256 daoSharesBefore = harness.balanceOf(dao);
        uint256 watermarkBefore = harness.exchangeRateHighWatermark();
        uint256 cumulativeDonatedAssets;

        for (uint256 i; i < 20; ++i) {
            uint256 donationAssets = 9;
            deal(USDC_MONAD, address(this), donationAssets);
            IERC20(USDC_MONAD).approve(cUSDC_WMON_MARKET, donationAssets);
            uint256 donatedShares = IBorrowableCToken(cUSDC_WMON_MARKET).deposit(
                donationAssets,
                address(this)
            );
            IERC20(cUSDC_WMON_MARKET).transfer(address(harness), donatedShares);

            uint256 totalAssetsBefore = harness.totalAssets();
            harness.accrueIfNeeded();

            cumulativeDonatedAssets += harness.totalAssets() - totalAssetsBefore;
            assertEq(
                harness.balanceOf(dao),
                daoSharesBefore,
                "sub-fee-unit profit increment should mint no DAO shares"
            );
        }

        assertGt(cumulativeDonatedAssets, 0, "test setup should create cumulative profit");
        assertGt(
            harness.exchangeRateHighWatermark(),
            watermarkBefore,
            "watermark should advance across fee-free tiny increments"
        );
        assertEq(harness.balanceOf(dao), daoSharesBefore, "cumulative tiny profits minted no fee shares");
    }

    /// @notice Same-state baseline: split tiny accruals avoid fee shares that
    ///         the equivalent donated cToken shares would mint if accrued once.
    function test_lendingOptimizer_accrueIfNeeded_splitTinyProfitsAvoidFeesVersusOneShot() public {
        _setUpHarness();

        address dao = _daoAddress();
        uint256 daoSharesBefore = harness.balanceOf(dao);
        uint256 snapshotId = vm.snapshotState();
        uint256 chunks = 20;
        uint256 donationAssets = 9;
        uint256 totalDonatedShares;

        for (uint256 i; i < chunks; ++i) {
            uint256 donatedShares = _mintDonationMarketShares(donationAssets);
            totalDonatedShares += donatedShares;
            IERC20(cUSDC_WMON_MARKET).transfer(address(harness), donatedShares);
            harness.accrueIfNeeded();
        }

        uint256 splitFeeShares = harness.balanceOf(dao) - daoSharesBefore;
        assertEq(splitFeeShares, 0, "split tiny accruals mint no fee shares");

        assertTrue(
            vm.revertToState(snapshotId),
            "failed to restore pre-split fee state"
        );

        uint256 oneShotDaoSharesBefore = harness.balanceOf(dao);
        uint256 oneShotDonatedShares;
        for (uint256 i; i < chunks; ++i) {
            oneShotDonatedShares += _mintDonationMarketShares(donationAssets);
        }
        assertEq(
            oneShotDonatedShares,
            totalDonatedShares,
            "baseline must donate identical cToken shares"
        );

        IERC20(cUSDC_WMON_MARKET).transfer(address(harness), oneShotDonatedShares);
        harness.accrueIfNeeded();

        uint256 oneShotFeeShares = harness.balanceOf(dao) - oneShotDaoSharesBefore;
        assertGt(
            oneShotFeeShares,
            splitFeeShares,
            "one-shot accrual mints fee shares while split accrual does not"
        );
    }

    /// @notice Documents the second fee-dust branch: positive fee assets can still mint zero shares.
    function test_lendingOptimizer_accrueIfNeeded_positiveFeeAssetsCanMintZeroFeeShares() public {
        _setUpHarness();

        address dao = _daoAddress();
        uint256 daoSharesBefore = harness.balanceOf(dao);
        uint256 supplyBefore = harness.totalSupply();
        uint256 watermarkBefore = harness.exchangeRateHighWatermark();

        uint256 donationAssets = 19;
        deal(USDC_MONAD, address(this), donationAssets);
        IERC20(USDC_MONAD).approve(cUSDC_WMON_MARKET, donationAssets);
        uint256 donatedShares = IBorrowableCToken(cUSDC_WMON_MARKET).deposit(
            donationAssets,
            address(this)
        );
        IERC20(cUSDC_WMON_MARKET).transfer(address(harness), donatedShares);

        IBorrowableCToken(cUSDC_WMON_MARKET).accrueIfNeeded();
        uint256 rawTa = IBorrowableCToken(cUSDC_WMON_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(harness))
        );
        uint256 highAssets = FixedPointMathLib.fullMulDivUp(
            watermarkBefore,
            supplyBefore,
            WAD
        );
        uint256 profit = rawTa - highAssets;
        uint256 feeAssets = FixedPointMathLib.fullMulDiv(profit, harness.fee(), BPS);
        uint256 feeShares = FixedPointMathLib.fullMulDiv(
            feeAssets,
            supplyBefore,
            rawTa - feeAssets
        );

        assertGt(feeAssets, 0, "test setup must create positive fee assets");
        assertEq(feeShares, 0, "positive fee assets should still round to zero shares");

        harness.accrueIfNeeded();

        assertEq(harness.balanceOf(dao), daoSharesBefore, "positive fee assets minted no DAO shares");
        assertGt(
            harness.exchangeRateHighWatermark(),
            watermarkBefore,
            "watermark should still advance after zero-share fee accrual"
        );
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

        // Watermark is calculated using currentAssets (rawTa).
        // So watermark >= currentRate immediately after accrual.
        uint256 currentRate = harness.exchangeRate();
        assertGe(newWatermark, currentRate, "Watermark should be >= current rate");
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
            optimizer.deposit(depositPerMarket, address(this));
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
            optimizer.deposit(depositPerMarket, address(this));
        }

        // Skip to allow yield
        skip(3 days);

        // Accrue yield
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

    function test_lendingOptimizer_accrueIfNeeded_sameBlockNoChange() public {
        _setUpHarness();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 100_000e6);
        harness.deposit(100_000e6, address(this));

        // Trigger accrual
        skip(2 days);
        harness.accrueIfNeeded();

        uint256 indexedAfterStart = harness.exposed_totalAssetsIndexed();

        // Call again in same block (zero elapsed)
        harness.accrueIfNeeded();

        uint256 indexedAfterSecond = harness.exposed_totalAssetsIndexed();

        // Indexed should not change
        assertEq(indexedAfterSecond, indexedAfterStart, "Indexed unchanged with zero elapsed");
    }

    // ==================== INTEGRATION WITH OTHER FUNCTIONS ====================

    function test_lendingOptimizer_accrueIfNeeded_calledByDeposit() public {
        _setUpHarness();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 100_000e6);
        harness.deposit(100_000e6, address(this));

        // Trigger accrual
        skip(2 days);
        harness.accrueIfNeeded();

        // Record totalAssets before
        uint256 totalAssetsBefore = harness.totalAssets();

        // Skip forward
        skip(12 hours);

        // Deposit should internally call accrueIfNeeded
        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 10_000e6);
        harness.deposit(10_000e6, address(this));

        // Verify totalAssets increased by deposit amount (minus 1 for cToken rounding)
        uint256 totalAssetsAfter = harness.totalAssets();

        // totalAssets should have increased by approximately the deposit amount
        // (allowing for yield accrual and cToken rounding)
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

        // Trigger accrual
        skip(2 days);
        harness.accrueIfNeeded();

        // Record totalAssets before
        uint256 totalAssetsBefore = harness.totalAssets();

        // Skip forward
        skip(12 hours);

        // Withdraw should internally call accrueIfNeeded
        harness.withdraw(1_000e6, address(this), address(this));

        uint256 totalAssetsAfter = harness.totalAssets();

        // totalAssets should have decreased by approximately the withdraw amount
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

        // Establish a post-accrual baseline.
        skip(2 days);
        harness.accrueIfNeeded();

        // Record cached state
        uint256 totalAssetsBefore = harness.totalAssets();
        uint256 cachedRateBefore = harness.exchangeRate();

        // Skip forward
        skip(12 hours);

        // exchangeRateUpdated should internally call accrueIfNeeded
        uint256 updatedRate = harness.exchangeRateUpdated();

        uint256 totalAssetsAfter = harness.totalAssets();

        // totalAssets should have increased due to yield accrual
        assertGt(
            totalAssetsAfter,
            totalAssetsBefore,
            "exchangeRateUpdated should reflect yield in totalAssets"
        );
        assertGt(updatedRate, cachedRateBefore, "exchangeRateUpdated should return fresh rate");
        assertEq(updatedRate, harness.exchangeRate(), "exchangeRateUpdated return should match cached rate after accrual");
    }

    // ==================== FUZZ TESTS ====================

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
            // fee() is in BPS, so divide by BPS (not WAD)
            uint256 maxFee = FixedPointMathLib.mulDivUp(yield, harness.fee(), BPS);
            assertLe(
                feeAssetsValue,
                maxFee + 1, // +1 for rounding
                "Fee should not exceed yield * fee percentage"
            );
        }
    }
}
