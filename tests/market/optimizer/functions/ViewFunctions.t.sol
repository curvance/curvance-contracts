// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { LendingOptimizerHarness } from "../LendingOptimizerHarness.sol";
import { OptimizerReader } from "contracts/views/OptimizerReader.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IDynamicIRM } from "contracts/interfaces/IDynamicIRM.sol";
import { ILendingOptimizer } from "contracts/interfaces/ILendingOptimizer.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { BPS, WAD } from "contracts/libraries/ConstantsLib.sol";

/// @title View Function Tests & optimalRebalance Edge Cases
/// @notice Tests for getOptimizerAPY, getOptimizerMarketData,
///         getOptimizerUserData, and optimalRebalance edge cases
///         (zero markets, oracle error skips USD threshold).
contract TestViewFunctions is TestBaseLendingOptimizer {

    OptimizerReader reader;

    function setUp() public override {
        super.setUp();
        reader = new OptimizerReader(
            ICentralRegistry(address(liveCentralRegistry)),
            0
        );
    }

    // ==================== getOptimizerAPY ====================

    /// @notice APY is non-zero when the optimizer has deposits and markets
    ///         have outstanding debt (generating interest).
    function test_getOptimizerAPY_nonZeroWithDeposits() public {
        _setUpThreeMarketsUnconstrained();
        _depositToAllMarketsUnconstrained(50_000e6);

        uint256 apy = reader.getOptimizerAPY(address(optimizer));

        assertGt(apy, 0, "APY should be non-zero with deposits and debt");
        // Sanity: APY should be < 100% (1e18 WAD).
        assertLt(apy, 1e18, "APY should be reasonable (< 100%)");
    }

    /// @notice APY matches an independent manual calculation using per-market
    ///         supply rates.
    function test_getOptimizerAPY_matchesManualCalculation() public {
        _setUpThreeMarketsUnconstrained();
        _depositToAllMarketsUnconstrained(50_000e6);

        uint256 ta = optimizer.totalAssets();
        address[] memory markets = optimizer.getApprovedMarkets();

        uint256 expectedWeightedRate;
        for (uint256 i; i < markets.length; ++i) {
            IBorrowableCToken ct = IBorrowableCToken(markets[i]);
            uint256 allocated = ct.convertToAssets(
                ct.balanceOf(address(optimizer))
            );
            uint256 rate = ct.IRM().supplyRate(
                ct.assetsHeld(),
                ct.marketOutstandingDebt(),
                ct.interestFee()
            );
            expectedWeightedRate += FixedPointMathLib.mulDiv(
                allocated, rate, ta
            );
        }
        uint256 expectedApy = expectedWeightedRate * 31_536_000;

        uint256 actualApy = reader.getOptimizerAPY(address(optimizer));

        assertEq(actualApy, expectedApy, "APY should match manual calculation");
    }

    /// @notice APY decreases when a whale floods a market with liquidity
    ///         (depressing supply rates).
    function test_getOptimizerAPY_decreasesAfterLiquidityFlood() public {
        _setUpThreeMarketsUnconstrained();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 100_000e6);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(
            100_000e6, address(this), cUSDC_WMON_MARKET
        );

        uint256 apyBefore = reader.getOptimizerAPY(address(optimizer));

        // Whale floods the market with 10M.
        address whale = address(0xBEEF);
        deal(USDC_MONAD, whale, 10_000_000e6);
        vm.startPrank(whale);
        IERC20(USDC_MONAD).approve(cUSDC_WMON_MARKET, 10_000_000e6);
        IBorrowableCToken(cUSDC_WMON_MARKET).deposit(10_000_000e6, whale);
        vm.stopPrank();

        uint256 apyAfter = reader.getOptimizerAPY(address(optimizer));

        assertLt(
            apyAfter,
            apyBefore,
            "APY should decrease after liquidity flood"
        );
    }

    /// @notice APY is zero when totalAssets is zero.
    function test_getOptimizerAPY_zeroWhenNoAssets() public {
        // Mock an optimizer that returns totalAssets = 0.
        address mockOptimizer = address(0xFACE);
        vm.mockCall(
            mockOptimizer,
            abi.encodeWithSelector(ILendingOptimizer.totalAssets.selector),
            abi.encode(uint256(0))
        );

        uint256 apy = reader.getOptimizerAPY(mockOptimizer);
        assertEq(apy, 0, "APY should be 0 when totalAssets is 0");
    }

    /// @notice APY accrues stale optimizer NAV before calculating weighted rate.
    function test_getOptimizerAPY_accruesStaleOptimizerBeforeRateCalculation()
        public
    {
        _setUpThreeMarketsUnconstrained();
        _depositToAllMarketsUnconstrained(50_000e6);

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(365 days);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: cached optimizer NAV is stale"
        );

        uint256 apy = reader.getOptimizerAPY(address(optimizer));

        assertGt(apy, 0, "APY should remain non-zero after accrual");
        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "reader must refresh optimizer NAV before APY"
        );
    }

    // ==================== getOptimizerMarketData ====================

    /// @notice Market data returns correct structure for a single optimizer.
    function test_getOptimizerMarketData_correctStructure() public {
        _setUpThreeMarketsUnconstrained();
        _depositToAllMarketsUnconstrained(50_000e6);

        address[] memory optimizers = new address[](1);
        optimizers[0] = address(optimizer);

        OptimizerReader.OptimizerMarketData[] memory data =
            reader.getOptimizerMarketData(optimizers);

        assertEq(data.length, 1, "Should return data for 1 optimizer");
        assertEq(data[0]._address, address(optimizer), "Address mismatch");
        assertEq(data[0].asset, USDC_MONAD, "Asset mismatch");
        assertEq(data[0].markets.length, 3, "Should have 3 markets");
        assertEq(
            data[0].numApprovedMarkets,
            optimizer.numApprovedMarkets(),
            "numApprovedMarkets should match optimizer"
        );
        assertEq(
            data[0].exchangeRateHighWatermark,
            optimizer.exchangeRateHighWatermark(),
            "high watermark should match optimizer"
        );
        // apy matches the standalone getOptimizerAPY path (merged in-loop).
        assertEq(
            data[0].apy,
            reader.getOptimizerAPY(address(optimizer)),
            "apy field should match getOptimizerAPY"
        );
    }

    /// @notice totalAssets in market data matches optimizer.totalAssets().
    function test_getOptimizerMarketData_totalAssetsMatch() public {
        _setUpThreeMarketsUnconstrained();
        _depositToAllMarketsUnconstrained(50_000e6);

        // Accrue first so both reads observe the same post-accrual state.
        optimizer.accrueIfNeeded();

        address[] memory optimizers = new address[](1);
        optimizers[0] = address(optimizer);

        OptimizerReader.OptimizerMarketData[] memory data =
            reader.getOptimizerMarketData(optimizers);

        // Reader is now view and does not accrue, so both reads are taken
        // from identical state. Tolerance retained for defensive margin.
        assertApproxEqAbs(
            data[0].totalAssets,
            optimizer.totalAssets(),
            3,
            "totalAssets should match optimizer"
        );
    }

    /// @notice Market data accrues stale optimizer NAV before reporting.
    function test_getOptimizerMarketData_accruesStaleOptimizerBeforeReporting()
        public
    {
        _setUpThreeMarketsUnconstrained();
        _depositToAllMarketsUnconstrained(50_000e6);

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(365 days);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: cached optimizer NAV is stale"
        );

        address[] memory optimizers = new address[](1);
        optimizers[0] = address(optimizer);

        OptimizerReader.OptimizerMarketData[] memory data =
            reader.getOptimizerMarketData(optimizers);

        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "reader must refresh optimizer NAV"
        );
        assertEq(
            data[0].totalAssets,
            optimizer.totalAssets(),
            "reported totalAssets should be refreshed"
        );
        assertEq(
            data[0].sharePrice,
            optimizer.exchangeRate(),
            "reported sharePrice should be refreshed"
        );
    }

    /// @notice Allocated assets across markets sum to approximately totalAssets.
    function test_getOptimizerMarketData_allocatedAssetsSum() public {
        _setUpThreeMarketsUnconstrained();
        _depositToAllMarketsUnconstrained(50_000e6);

        address[] memory optimizers = new address[](1);
        optimizers[0] = address(optimizer);

        OptimizerReader.OptimizerMarketData[] memory data =
            reader.getOptimizerMarketData(optimizers);

        uint256 sumAllocated;
        for (uint256 i; i < data[0].markets.length; ++i) {
            sumAllocated += data[0].markets[i].allocatedAssets;
        }

        assertApproxEqAbs(
            sumAllocated,
            data[0].totalAssets,
            data[0].markets.length, // 1 wei rounding per market
            "Sum of allocated assets should match totalAssets"
        );
    }

    /// @notice Per-market allocation cap fields match optimizer state.
    function test_getOptimizerMarketData_allocationCapFieldsMatch() public {
        _setUpThreeMarkets();

        address[] memory optimizers = new address[](1);
        optimizers[0] = address(optimizer);

        OptimizerReader.OptimizerMarketData[] memory data =
            reader.getOptimizerMarketData(optimizers);

        for (uint256 i; i < data[0].markets.length; ++i) {
            uint256 maxAllocation = FixedPointMathLib.mulDiv(
                data[0].totalAssets,
                data[0].markets[i].allocationCap,
                WAD
            );
            uint256 expectedUtilizationBps = maxAllocation == 0
                ? 0
                : FixedPointMathLib.mulDiv(
                    data[0].markets[i].allocatedAssets,
                    BPS,
                    maxAllocation
                );

            assertEq(
                data[0].markets[i].allocationCap,
                optimizer.allocationCaps(data[0].markets[i]._address),
                "Allocation cap should match optimizer"
            );
            assertEq(
                data[0].markets[i].allocationCapUtilizationBps,
                expectedUtilizationBps,
                "Allocation cap utilization should match"
            );
        }
    }

    /// @notice totalLiquidity is the sum of per-market liquidity.
    function test_getOptimizerMarketData_totalLiquidityIsSum() public {
        _setUpThreeMarketsUnconstrained();
        _depositToAllMarketsUnconstrained(50_000e6);

        address[] memory optimizers = new address[](1);
        optimizers[0] = address(optimizer);

        OptimizerReader.OptimizerMarketData[] memory data =
            reader.getOptimizerMarketData(optimizers);

        uint256 sumLiquidity;
        for (uint256 i; i < data[0].markets.length; ++i) {
            sumLiquidity += data[0].markets[i].liquidity;
        }

        assertEq(
            data[0].totalLiquidity,
            sumLiquidity,
            "totalLiquidity should be sum of per-market liquidity"
        );
    }

    /// @notice sharePrice is non-zero for an initialized optimizer.
    function test_getOptimizerMarketData_sharePriceNonZero() public {
        _setUpThreeMarketsUnconstrained();
        _depositToAllMarketsUnconstrained(50_000e6);

        address[] memory optimizers = new address[](1);
        optimizers[0] = address(optimizer);

        OptimizerReader.OptimizerMarketData[] memory data =
            reader.getOptimizerMarketData(optimizers);

        assertGt(data[0].sharePrice, 0, "Share price should be non-zero");
    }

    /// @notice performanceFee matches the optimizer's fee setting.
    function test_getOptimizerMarketData_performanceFee() public {
        _setUpThreeMarkets(); // Uses 1000 BPS (10%) fee.

        address[] memory optimizers = new address[](1);
        optimizers[0] = address(optimizer);

        OptimizerReader.OptimizerMarketData[] memory data =
            reader.getOptimizerMarketData(optimizers);

        assertEq(
            data[0].performanceFee,
            optimizer.fee(),
            "Performance fee should match"
        );
    }

    /// @notice Multiple optimizers return independent data.
    function test_getOptimizerMarketData_multipleOptimizers() public {
        _setUpThreeMarketsUnconstrained();

        // Create a second optimizer.
        address[] memory approvedCTokens2 = new address[](1);
        approvedCTokens2[0] = cUSDC_WMON_MARKET;
        uint256[] memory caps2 = new uint256[](1);
        caps2[0] = 10_000;

        LendingOptimizerHarness opt2 = new LendingOptimizerHarness(
            IERC20(USDC_MONAD), liveCentralRegistry, approvedCTokens2, caps2, 0
        );
        deal(USDC_MONAD, address(this), 77777);
        IERC20(USDC_MONAD).approve(address(opt2), 77777);
        opt2.initializeDeposits(cUSDC_WMON_MARKET);

        address[] memory optimizers = new address[](2);
        optimizers[0] = address(optimizer);
        optimizers[1] = address(opt2);

        OptimizerReader.OptimizerMarketData[] memory data =
            reader.getOptimizerMarketData(optimizers);

        assertEq(data.length, 2, "Should return data for 2 optimizers");
        assertEq(data[0].markets.length, 3, "Optimizer 0: 3 markets");
        assertEq(data[1].markets.length, 1, "Optimizer 1: 1 market");
    }

    // ==================== getOptimizerUserData ====================

    /// @notice Returns correct share balance and redeemable for a depositor.
    function test_getOptimizerUserData_correctForDepositor() public {
        _setUpThreeMarketsUnconstrained();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 100_000e6);
        optimizer.deposit(100_000e6, address(this));

        address[] memory optimizers = new address[](1);
        optimizers[0] = address(optimizer);

        OptimizerReader.OptimizerUserData[] memory data =
            reader.getOptimizerUserData(optimizers, address(this));

        assertEq(data.length, 1);
        assertEq(data[0]._address, address(optimizer));
        assertEq(
            data[0].shareBalance,
            optimizer.balanceOf(address(this)),
            "Share balance mismatch"
        );
        assertEq(
            data[0].redeemable,
            optimizer.convertToAssets(data[0].shareBalance),
            "Redeemable mismatch"
        );
    }

    /// @notice Returns zero for an account with no shares.
    function test_getOptimizerUserData_zeroForNonHolder() public {
        _setUpThreeMarketsUnconstrained();

        address nobody = address(0xDEAD);

        address[] memory optimizers = new address[](1);
        optimizers[0] = address(optimizer);

        OptimizerReader.OptimizerUserData[] memory data =
            reader.getOptimizerUserData(optimizers, nobody);

        assertEq(data[0].shareBalance, 0, "Non-holder should have 0 shares");
        assertEq(data[0].redeemable, 0, "Non-holder should have 0 redeemable");
    }

    /// @notice Redeemable amount matches expected value after yield accrual.
    function test_getOptimizerUserData_redeemableGrowsWithYield() public {
        _setUpThreeMarketsUnconstrained();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 100_000e6);
        optimizer.deposit(100_000e6, address(this));

        address[] memory optimizers = new address[](1);
        optimizers[0] = address(optimizer);

        OptimizerReader.OptimizerUserData[] memory dataBefore =
            reader.getOptimizerUserData(optimizers, address(this));

        // Skip time so yield accrues.
        skip(365 days);
        optimizer.accrueIfNeeded();

        OptimizerReader.OptimizerUserData[] memory dataAfter =
            reader.getOptimizerUserData(optimizers, address(this));

        // Shares unchanged, redeemable increased.
        assertEq(
            dataAfter[0].shareBalance,
            dataBefore[0].shareBalance,
            "Shares should not change"
        );
        assertGt(
            dataAfter[0].redeemable,
            dataBefore[0].redeemable,
            "Redeemable should grow with yield"
        );
    }

    /// @notice User data accrues stale optimizer NAV before reporting redeemable assets.
    function test_getOptimizerUserData_accruesStaleOptimizerBeforeRedeemable()
        public
    {
        _setUpThreeMarketsUnconstrained();

        deal(USDC_MONAD, address(this), 100_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 100_000e6);
        optimizer.deposit(100_000e6, address(this));

        uint256 shares = optimizer.balanceOf(address(this));
        uint256 staleRedeemable = optimizer.convertToAssets(shares);
        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(365 days);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: cached optimizer NAV is stale"
        );

        address[] memory optimizers = new address[](1);
        optimizers[0] = address(optimizer);

        OptimizerReader.OptimizerUserData[] memory data =
            reader.getOptimizerUserData(optimizers, address(this));

        assertEq(data[0].shareBalance, shares, "share balance should be stable");
        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "reader must refresh optimizer NAV"
        );
        assertGt(
            data[0].redeemable,
            staleRedeemable,
            "redeemable should include accrued optimizer NAV"
        );
        assertEq(
            data[0].redeemable,
            optimizer.convertToAssets(shares),
            "reported redeemable should be refreshed"
        );
    }

    // ==================== optimalRebalance: Zero Markets ====================

    /// @notice An optimizer with no approved markets returns empty arrays.
    function test_optimalRebalance_zeroMarkets_returnsEmpty() public {
        address mockOptimizer = address(0xFACE);

        // Mock getApprovedMarkets to return empty array.
        vm.mockCall(
            mockOptimizer,
            abi.encodeWithSelector(
                ILendingOptimizer.getApprovedMarkets.selector
            ),
            abi.encode(new address[](0))
        );

        (LendingOptimizer.ReallocationAction[] memory actions,
         LendingOptimizer.AllocationBound[] memory bounds) =
            reader.optimalRebalance(mockOptimizer, 500, 200);

        assertEq(actions.length, 0, "Zero markets: empty actions");
        assertEq(bounds.length, 0, "Zero markets: empty bounds");
    }

    // ==================== optimalRebalance: Oracle Error Skips Threshold ====================

    /// @notice When the oracle returns an error for the underlying asset,
    ///         the USD threshold check is skipped and small rebalances proceed.
    function test_optimalRebalance_oracleError_skipsThreshold() public {
        _setUpThreeMarkets(); // Constrained: 60%/50%/20% caps.

        // Deposit a small amount into market 0 only. The total rebalance
        // value must be under $100 (USD_THRESHOLD) for the threshold to
        // filter it. With $50 deposited, max redistribution ≈ $35 → $35 < $100.
        deal(USDC_MONAD, address(this), 50e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 50e6);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(
            50e6, address(this), cUSDC_WMON_MARKET
        );

        // With working oracle, small rebalance should be below threshold → empty.
        (LendingOptimizer.ReallocationAction[] memory actionsNormal, ) =
            reader.optimalRebalance(address(optimizer), 500, 200);
        assertEq(
            actionsNormal.length,
            0,
            "Normal oracle: small rebalance filtered by threshold"
        );

        // Mock USDC oracle to return an error (errorCode = 1).
        // This causes the threshold check block to be skipped entirely.
        vm.mockCall(
            address(_oracleManager),
            abi.encodeWithSelector(
                IOracleManager.getPrice.selector,
                USDC_MONAD,
                true,
                true
            ),
            abi.encode(uint256(0), uint256(1))
        );

        // With oracle error, threshold check is skipped → actions returned.
        (LendingOptimizer.ReallocationAction[] memory actionsError, ) =
            reader.optimalRebalance(address(optimizer), 500, 200);
        assertGt(
            actionsError.length,
            0,
            "Oracle error: threshold skipped, actions returned"
        );
    }

    /// @notice optimalRebalance accrues stale optimizer NAV before planning.
    function test_optimalRebalance_accruesStaleOptimizerBeforePlanning()
        public
    {
        _setUpThreeMarketsUnconstrained();
        _depositToAllMarketsUnconstrained(50_000e6);

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(365 days);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: cached optimizer NAV is stale"
        );

        (LendingOptimizer.ReallocationAction[] memory actions,
         LendingOptimizer.AllocationBound[] memory bounds) =
            reader.optimalRebalance(address(optimizer), 500, 200);

        assertEq(actions.length, bounds.length, "rebalance arrays should align");
        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "reader must refresh optimizer NAV before planning"
        );
    }

    // ==================== Internal Helpers ====================

    function _setUpThreeMarketsUnconstrained() internal {
        address[] memory approvedCTokens = new address[](3);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;
        approvedCTokens[2] = cUSDC_WETH_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](3);
        allocationCapsBps[0] = 10_000;
        allocationCapsBps[1] = 10_000;
        allocationCapsBps[2] = 10_000;

        optimizer = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            0
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets);
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(
                ICentralRegistry.hasMarketPermissions.selector,
                address(this)
            ),
            abi.encode(true)
        );
        optimizer.initializeDeposits(cUSDC_WMON_MARKET);

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(
                ICentralRegistry.hasHarvestPermissions.selector,
                address(this)
            ),
            abi.encode(true)
        );
    }

    function _depositToAllMarketsUnconstrained(
        uint256 amountPerMarket
    ) internal {
        address[3] memory markets = [
            cUSDC_WMON_MARKET, cUSDC_WBTC_MARKET, cUSDC_WETH_MARKET
        ];
        for (uint256 i = 0; i < 3; i++) {
            deal(USDC_MONAD, address(this), amountPerMarket);
            IERC20(USDC_MONAD).approve(address(optimizer), amountPerMarket);
            LendingOptimizerHarness(address(optimizer)).depositToMarket(
                amountPerMarket, address(this), markets[i]
            );
        }
    }
}
