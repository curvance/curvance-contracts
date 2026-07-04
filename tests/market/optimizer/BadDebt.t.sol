// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { LendingOptimizerShareCToken } from "contracts/market/token/LendingOptimizerShareCToken.sol";
import { LendingOptimizerHarness } from "./LendingOptimizerHarness.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { SimpleCToken } from "contracts/market/token/SimpleCToken.sol";
import { DynamicIRM } from "contracts/market/DynamicIRM.sol";
import { VaultAggregator } from "contracts/oracles/adaptors/wrappedAggregators/VaultAggregator.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { BAD_SOURCE, WAD, BPS } from "contracts/libraries/ConstantsLib.sol";
import { console2 } from "forge-std/console2.sol";

/// @title Bad Debt Stress Tests for LendingOptimizer
/// @notice Tests LendingOptimizer behavior when underlying markets experience bad debt
/// @dev Creates scenarios with multiple market managers, borrowers, and price crashes
contract TestLendingOptimizerBadDebt is TestBaseMarketIsolated {

    LendingOptimizerHarness optimizer;

    // Second market manager for multi-market testing
    MarketManagerIsolated marketManager2;
    BorrowableCToken borrowableCUSDC2;
    SimpleCToken collateralDAI2;

    // Third market manager
    MarketManagerIsolated marketManager3;
    BorrowableCToken borrowableCUSDC3;
    SimpleCToken collateralWETH;


    // Test actors
    address depositor1 = makeAddr("depositor1");
    address depositor2 = makeAddr("depositor2");
    address borrower1 = makeAddr("borrower1");
    address borrower2 = makeAddr("borrower2");
    address borrower3 = makeAddr("borrower3");
    address liquidityProvider = makeAddr("liquidityProvider");

    uint256 constant BASE_RESERVE = 77777;

    event BadDebtRecognized(uint256 badDebt, address indexed liquidator);

    function setUp() public override {
        super.setUp();
        _setupMultipleMarketManagers();
        _setupOptimizer();
    }

    /// @dev Creates multiple market managers with their own borrowable markets
    function _setupMultipleMarketManagers() internal {
        // === Market Manager 2: USDC lending with DAI collateral ===
        marketManager2 = new MarketManagerIsolated(
            ICentralRegistry(address(centralRegistry)),
            10e18,
            false
        );
        centralRegistry.addMarketManager(address(marketManager2));

        // Deploy borrowable USDC for market manager 2
        DynamicIRM irm2 = new DynamicIRM(
            ICentralRegistry(address(centralRegistry)),
            1000, 1000, 5000, 1000, 100, 100000
        );
        borrowableCUSDC2 = new BorrowableCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(_USDC_ADDRESS),
            address(marketManager2),
            address(irm2)
        );
        irm2.setLinkedToken(address(borrowableCUSDC2));

        // Deploy DAI collateral for market manager 2
        collateralDAI2 = new SimpleCToken(
            ICentralRegistry(address(centralRegistry)),
            dai,
            address(marketManager2)
        );

        // Add oracle support BEFORE setting token config
        oracleManager.addCTokenSupport(address(borrowableCUSDC2));
        oracleManager.addCTokenSupport(address(collateralDAI2));

        // Seed funds for market manager 2
        _prepareDAI(address(this), BASE_RESERVE);
        _prepareUSDC(address(this), BASE_RESERVE);
        dai.approve(address(collateralDAI2), BASE_RESERVE);
        usdc.approve(address(borrowableCUSDC2), BASE_RESERVE);

        // List tokens in market manager 2
        marketManager2.listTokens(address(collateralDAI2), address(borrowableCUSDC2));
        _setCTokenConfigForManager(marketManager2, address(collateralDAI2), 100_000e18, 0);
        _setCTokenConfigForManager(marketManager2, address(borrowableCUSDC2), 0, 1_000_000e6);

        // === Market Manager 3: USDC lending with WETH collateral ===
        marketManager3 = new MarketManagerIsolated(
            ICentralRegistry(address(centralRegistry)),
            10e18,
            false
        );
        centralRegistry.addMarketManager(address(marketManager3));

        DynamicIRM irm3 = new DynamicIRM(
            ICentralRegistry(address(centralRegistry)),
            1000, 1000, 5000, 1000, 100, 100000
        );
        borrowableCUSDC3 = new BorrowableCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(_USDC_ADDRESS),
            address(marketManager3),
            address(irm3)
        );
        irm3.setLinkedToken(address(borrowableCUSDC3));

        collateralWETH = new SimpleCToken(
            ICentralRegistry(address(centralRegistry)),
            weth,
            address(marketManager3)
        );

        // Initialize all oracle prices for testing
        mockUsdcFeed.setMockAnswer(1e8);    // $1 per USDC
        mockDaiFeed.setMockAnswer(1e8);     // $1 per DAI
        mockWethFeed.setMockAnswer(2000e8); // $2000 per ETH

        // Add oracle support BEFORE setting token config
        oracleManager.addCTokenSupport(address(borrowableCUSDC3));
        oracleManager.addCTokenSupport(address(collateralWETH));

        // Seed funds for market manager 3
        _prepareWETH(address(this), BASE_RESERVE);
        _prepareUSDC(address(this), BASE_RESERVE);
        weth.approve(address(collateralWETH), BASE_RESERVE);
        usdc.approve(address(borrowableCUSDC3), BASE_RESERVE);

        marketManager3.listTokens(address(collateralWETH), address(borrowableCUSDC3));
        _setCTokenConfigForManager(marketManager3, address(collateralWETH), 100_000e18, 0);
        _setCTokenConfigForManager(marketManager3, address(borrowableCUSDC3), 0, 1_000_000e6);
    }

    /// @dev Helper to set token config for any market manager
    function _setCTokenConfigForManager(
        MarketManagerIsolated mm,
        address cToken,
        uint256 collateralCap,
        uint256 debtCap
    ) internal {
        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = cToken;
        tokenConfig.collRatio = 7000; // 70% LTV
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 10;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.closeFactorBase = 5000; // 50% close factor for easier liquidation
        tokenConfig.closeFactorMin = 5000;
        tokenConfig.closeFactorMax = 10000; // 100% for bad debt scenarios
        tokenConfig.collateralCap = collateralCap;
        tokenConfig.debtCap = debtCap;
        mm.updateTokenConfig(tokenConfig);
    }

    /// @dev Sets up the LendingOptimizer with multiple markets
    function _setupOptimizer() internal {
        // First, list tokens in base marketManagerIsolated (from TestBaseMarketIsolated)
        // This is required before borrowableCUSDC can accept deposits
        _prepareDAI(address(this), BASE_RESERVE);
        _prepareUSDC(address(this), BASE_RESERVE);
        dai.approve(address(borrowableCDAI), BASE_RESERVE);
        usdc.approve(address(borrowableCUSDC), BASE_RESERVE);
        marketManagerIsolated.listTokens(address(borrowableCDAI), address(borrowableCUSDC));

        address[] memory approvedCTokens = new address[](3);
        approvedCTokens[0] = address(borrowableCUSDC);  // Market 1
        approvedCTokens[1] = address(borrowableCUSDC2); // Market 2
        approvedCTokens[2] = address(borrowableCUSDC3); // Market 3

        uint256[] memory allocationCapsBps = new uint256[](3);
        allocationCapsBps[0] = 4000; // 40%
        allocationCapsBps[1] = 4000; // 40%
        allocationCapsBps[2] = 4000; // 40% (sum > 100% to allow flexibility)

        optimizer = new LendingOptimizerHarness(
            IERC20(_USDC_ADDRESS),
            ICentralRegistry(address(centralRegistry)),
            approvedCTokens,
            allocationCapsBps,
            1000 // 10% performance fee
        );

        // Initialize optimizer
        _prepareUSDC(address(this), BASE_RESERVE);
        usdc.approve(address(optimizer), BASE_RESERVE);

        optimizer.initializeDeposits(address(borrowableCUSDC));
    }

    function _deployOptimizerShareCTokenForBadDebtPricing()
        internal
        returns (LendingOptimizerShareCToken shareCToken, MockV3Aggregator optimizerFeed)
    {
        DynamicIRM irm = new DynamicIRM(
            ICentralRegistry(address(centralRegistry)),
            1000,
            1000,
            5000,
            1000,
            100,
            100000
        );
        shareCToken = new LendingOptimizerShareCToken(
            ICentralRegistry(address(centralRegistry)),
            optimizer,
            address(marketManagerIsolated),
            address(irm)
        );
        irm.setLinkedToken(address(shareCToken));

        optimizerFeed = new MockV3Aggregator(8, 1e8);
        VaultAggregator optimizerVaultFeed = new VaultAggregator(
            address(optimizer),
            _USDC_ADDRESS,
            address(optimizerFeed),
            "optimizer/USD"
        );
        chainlinkAdaptor.addAsset(address(optimizer), true, address(optimizerVaultFeed), 0);
        oracleManager.addAssetPricingAdaptor(
            address(optimizer),
            address(chainlinkAdaptor),
            0,
            0,
            0,
            0
        );
        oracleManager.addCTokenSupport(address(shareCToken));

        _prepareUSDC(address(this), BASE_RESERVE);
        usdc.approve(address(optimizer), BASE_RESERVE);
        optimizer.deposit(BASE_RESERVE, address(this));

        IERC20(address(optimizer)).approve(address(shareCToken), BASE_RESERVE);
        vm.prank(address(marketManagerIsolated));
        shareCToken.initializeDeposits(address(this));
    }

    function _deployOptimizerShareLaunchMarketForBadDebt()
        internal
        returns (
            MarketManagerIsolated optimizerShareMarket,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken,
            MockV3Aggregator optimizerFeed
        )
    {
        optimizerShareMarket = new MarketManagerIsolated(
            ICentralRegistry(address(centralRegistry)),
            10e18,
            false
        );
        centralRegistry.addMarketManager(address(optimizerShareMarket));

        DynamicIRM debtIrm = new DynamicIRM(
            ICentralRegistry(address(centralRegistry)),
            1000,
            1000,
            5000,
            1000,
            100,
            100000
        );
        debtCToken = new BorrowableCToken(
            ICentralRegistry(address(centralRegistry)),
            usdc,
            address(optimizerShareMarket),
            address(debtIrm)
        );
        debtIrm.setLinkedToken(address(debtCToken));

        DynamicIRM shareIrm = new DynamicIRM(
            ICentralRegistry(address(centralRegistry)),
            1000,
            1000,
            5000,
            1000,
            100,
            100000
        );
        shareCToken = new LendingOptimizerShareCToken(
            ICentralRegistry(address(centralRegistry)),
            optimizer,
            address(optimizerShareMarket),
            address(shareIrm)
        );
        shareIrm.setLinkedToken(address(shareCToken));

        optimizerFeed = new MockV3Aggregator(8, 1e8);
        VaultAggregator optimizerVaultFeed = new VaultAggregator(
            address(optimizer),
            _USDC_ADDRESS,
            address(optimizerFeed),
            "optimizer/USD"
        );
        chainlinkAdaptor.addAsset(address(optimizer), true, address(optimizerVaultFeed), 0);
        chainlinkAdaptor.setGuardedPriceConfig(address(optimizer), true, 0, 0, WAD, 0);
        oracleManager.addAssetPricingAdaptor(
            address(optimizer),
            address(chainlinkAdaptor),
            0,
            0,
            0,
            0
        );
        oracleManager.addCTokenSupport(address(shareCToken));
        oracleManager.addCTokenSupport(address(debtCToken));

        _prepareUSDC(address(this), BASE_RESERVE * 2);
        usdc.approve(address(optimizer), BASE_RESERVE);
        optimizer.deposit(BASE_RESERVE, address(this));
        IERC20(address(optimizer)).approve(address(shareCToken), BASE_RESERVE);
        usdc.approve(address(debtCToken), BASE_RESERVE);
        optimizerShareMarket.listTokens(address(shareCToken), address(debtCToken));
        _setCTokenConfigForManager(optimizerShareMarket, address(shareCToken), 1_000_000e6, 0);
        _setCTokenConfigForManager(optimizerShareMarket, address(debtCToken), 0, 1_000_000e6);
    }

    function _optimizerShareCollateralMaxDebtValue(
        LendingOptimizerShareCToken shareCToken,
        address account,
        uint256 optimizerPrice
    ) internal view returns (uint256) {
        uint256 sharePrice = FixedPointMathLib.mulDiv(
            optimizerPrice,
            shareCToken.exchangeRate(),
            WAD
        );
        uint256 collateralValue = FixedPointMathLib.mulDiv(
            shareCToken.collateralPosted(account),
            sharePrice,
            10 ** shareCToken.decimals()
        );

        return FixedPointMathLib.mulDiv(collateralValue, 7000, BPS);
    }

    function _usdcDebtValue(uint256 assets) internal pure returns (uint256) {
        return FixedPointMathLib.mulDiv(assets, WAD, 1e6);
    }

    function _prepareOptimizerShareAccountAfterBadDebt()
        internal
        returns (
            MarketManagerIsolated optimizerShareMarket,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken,
            uint256 totalAssetsBeforeBadDebt
        )
    {
        LendingOptimizerShareCToken deployedShareCToken;
        MockV3Aggregator optimizerFeed;
        (
            optimizerShareMarket,
            debtCToken,
            deployedShareCToken,
            optimizerFeed
        ) = _deployOptimizerShareLaunchMarketForBadDebt();
        shareCToken = deployedShareCToken;

        uint256 depositAmount = 100_000e6;
        _prepareUSDC(depositor1, depositAmount);
        vm.startPrank(depositor1);
        usdc.approve(address(optimizer), depositAmount);
        optimizer.depositToMarket(depositAmount, depositor1, address(borrowableCUSDC));
        uint256 optimizerShares = optimizer.balanceOf(depositor1);
        IERC20(address(optimizer)).approve(address(shareCToken), optimizerShares);
        shareCToken.depositAsCollateral(optimizerShares, depositor1);
        vm.stopPrank();

        _prepareUSDC(liquidityProvider, 100_000e6);
        vm.startPrank(liquidityProvider);
        usdc.approve(address(debtCToken), 100_000e6);
        debtCToken.deposit(100_000e6, liquidityProvider);
        vm.stopPrank();

        (, uint256 maxDebtBeforeBadDebt,) = optimizerShareMarket.statusOf(depositor1);
        uint256 initialBorrowAmount = FixedPointMathLib.mulDiv(
            maxDebtBeforeBadDebt,
            9970 * 1e6,
            BPS * WAD
        );

        vm.prank(depositor1);
        debtCToken.borrow(initialBorrowAmount, depositor1);

        vm.warp(optimizerShareMarket.accountAssets(depositor1) + optimizerShareMarket.MIN_HOLD_PERIOD());
        _refreshMockFeeds();
        optimizerFeed.updateAnswer(1e8);

        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);
        _createBorrower(
            borrower1,
            marketManagerIsolated,
            ICToken(address(borrowableCDAI)),
            IBorrowableCToken(address(borrowableCUSDC)),
            10_000e18,
            7000e6
        );

        totalAssetsBeforeBadDebt = optimizer.totalAssets();

        mockDaiFeed.setMockAnswer(0.1e8);
        _refreshMockFeeds();
        optimizerFeed.updateAnswer(1e8);

        address[] memory accounts = new address[](1);
        accounts[0] = borrower1;

        _prepareUSDC(user2, 10_000e6);
        vm.startPrank(user2);
        usdc.approve(address(borrowableCUSDC), 10_000e6);
        borrowableCUSDC.liquidate(accounts, address(borrowableCDAI));
        vm.stopPrank();

        assertEq(borrowableCUSDC.debtBalance(borrower1), 0, "borrower debt should be cleared");
        assertEq(
            optimizer.totalAssets(),
            totalAssetsBeforeBadDebt,
            "optimizer NAV must still be cached before market price path"
        );
    }

    /// @dev Provides liquidity to all markets for borrowing
    function _provideLiquidityToAllMarkets(uint256 amountPerMarket) internal {
        _prepareUSDC(liquidityProvider, amountPerMarket * 3);

        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), amountPerMarket);
        borrowableCUSDC.deposit(amountPerMarket, liquidityProvider);

        usdc.approve(address(borrowableCUSDC2), amountPerMarket);
        borrowableCUSDC2.deposit(amountPerMarket, liquidityProvider);

        usdc.approve(address(borrowableCUSDC3), amountPerMarket);
        borrowableCUSDC3.deposit(amountPerMarket, liquidityProvider);
        vm.stopPrank();
    }

    /// @dev Creates a borrower with collateral and debt
    function _createBorrower(
        address borrower,
        MarketManagerIsolated mm,
        ICToken collateralToken,
        IBorrowableCToken debtToken,
        uint256 collateralAmount,
        uint256 borrowAmount
    ) internal {
        address collateralAsset = collateralToken.asset();

        // Provide collateral
        deal(collateralAsset, borrower, collateralAmount);
        vm.startPrank(borrower);
        IERC20(collateralAsset).approve(address(collateralToken), collateralAmount);
        collateralToken.depositAsCollateral(collateralAmount, borrower);

        // Borrow
        debtToken.borrow(borrowAmount, borrower);
        vm.stopPrank();
    }

    function _optimizerAssetsFromApprovedMarkets()
        internal
        view
        returns (uint256 assets)
    {
        assets += borrowableCUSDC.convertToAssets(
            borrowableCUSDC.balanceOf(address(optimizer))
        );
        assets += borrowableCUSDC2.convertToAssets(
            borrowableCUSDC2.balanceOf(address(optimizer))
        );
        assets += borrowableCUSDC3.convertToAssets(
            borrowableCUSDC3.balanceOf(address(optimizer))
        );
    }

    function _realizeSingleMarketBadDebtWithoutOptimizerAccrual() internal {
        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);

        _createBorrower(
            borrower1,
            marketManagerIsolated,
            ICToken(address(borrowableCDAI)),
            IBorrowableCToken(address(borrowableCUSDC)),
            10_000e18,
            7000e6
        );

        mockDaiFeed.setMockAnswer(0.1e8);
        _refreshMockFeeds();
        skip(30 days);
        _refreshMockFeeds();

        address[] memory accounts = new address[](1);
        accounts[0] = borrower1;

        _prepareUSDC(user2, 10_000e6);
        vm.startPrank(user2);
        usdc.approve(address(borrowableCUSDC), 10_000e6);
        borrowableCUSDC.liquidate(accounts, address(borrowableCDAI));
        vm.stopPrank();

        assertEq(borrowableCUSDC.debtBalance(borrower1), 0, "borrower debt should be cleared");
    }

    // ==================== SINGLE MARKET BAD DEBT ====================

    function test_lendingOptimizer_badDebt_singleMarketBadDebt() public {
        // Deposit into optimizer (target market 1 where the borrower will be)
        uint256 depositAmount = 100_000e6;
        _prepareUSDC(depositor1, depositAmount);
        vm.startPrank(depositor1);
        usdc.approve(address(optimizer), depositAmount);
        optimizer.depositToMarket(depositAmount, depositor1, address(borrowableCUSDC));
        vm.stopPrank();

        // Setup market 1 borrower config (tokens already listed in setUp)
        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);

        // Create borrower in market 1
        _createBorrower(
            borrower1,
            marketManagerIsolated,
            ICToken(address(borrowableCDAI)),
            IBorrowableCToken(address(borrowableCUSDC)),
            10_000e18, // 10k DAI collateral
            7000e6     // 7k USDC borrowed (70% LTV)
        );

        // Record state before bad debt
        uint256 rateBeforeBadDebt = optimizer.exchangeRateUpdated();
        uint256 totalAssetsBeforeBadDebt = optimizer.totalAssets();
        uint256 totalSupplyBefore = optimizer.totalSupply();
        uint256 depositor1SharesBefore = optimizer.balanceOf(depositor1);

        console2.log("Rate before bad debt:", rateBeforeBadDebt);
        console2.log("Total assets before:", totalAssetsBeforeBadDebt);
        console2.log("Total supply:", totalSupplyBefore);

        // Crash DAI price to create bad debt scenario
        mockDaiFeed.setMockAnswer(0.1e8); // DAI crashes to $0.10
        _refreshMockFeeds();

        // Skip time to accrue interest and make position more underwater
        skip(30 days);
        _refreshMockFeeds();

        // Liquidate the borrower
        {
            address[] memory accounts = new address[](1);
            accounts[0] = borrower1;

            _prepareUSDC(user2, 10_000e6);
            vm.startPrank(user2);
            usdc.approve(address(borrowableCUSDC), 10_000e6);
            borrowableCUSDC.liquidate(accounts, address(borrowableCDAI));
            vm.stopPrank();
        }

        // Verify borrower position is cleared
        assertEq(borrowableCUSDC.debtBalance(borrower1), 0, "Borrower debt should be cleared");

        // Trigger optimizer accrual to recognize bad debt impact
        uint256 rateAfterBadDebt = optimizer.exchangeRateUpdated();
        uint256 totalAssetsAfterBadDebt = optimizer.totalAssets();
        uint256 totalSupplyAfter = optimizer.totalSupply();

        console2.log("Rate after bad debt:", rateAfterBadDebt);
        console2.log("Total assets after:", totalAssetsAfterBadDebt);

        // Exchange rate should decrease due to bad debt
        assertLt(rateAfterBadDebt, rateBeforeBadDebt, "Exchange rate should decrease after bad debt");
        assertLt(totalAssetsAfterBadDebt, totalAssetsBeforeBadDebt, "Total assets should decrease");

        // Supply should not change (no shares minted/burned during bad debt)
        assertEq(totalSupplyAfter, totalSupplyBefore, "Supply should remain unchanged");

        // === PRECISE PROPORTIONALITY VERIFICATION ===
        // The exchange rate formula is: rate = WAD * totalAssets / totalSupply
        // After bad debt: newRate = WAD * newTotalAssets / totalSupply
        // Therefore: newRate / oldRate = newTotalAssets / oldTotalAssets
        {
            uint256 expectedRate = FixedPointMathLib.mulDiv(
                WAD,
                totalAssetsAfterBadDebt,
                totalSupplyAfter
            );

            console2.log("Expected rate:", expectedRate);
            console2.log("Actual rate:", rateAfterBadDebt);

            // Rate should exactly match the formula (within 1 wei for rounding)
            assertApproxEqAbs(
                rateAfterBadDebt,
                expectedRate,
                1,
                "Rate should equal WAD * totalAssets / totalSupply"
            );
        }

        // Verify rate decreased proportionally to asset loss
        // rateDelta / rateOld = assetDelta / assetsOld
        uint256 assetLoss = totalAssetsBeforeBadDebt - totalAssetsAfterBadDebt;
        {
            uint256 rateLoss = rateBeforeBadDebt - rateAfterBadDebt;

            // Cross-multiply to avoid division: rateLoss * assetsOld = assetLoss * rateOld
            uint256 lhs = rateLoss * totalAssetsBeforeBadDebt;
            uint256 rhs = assetLoss * rateBeforeBadDebt;

            console2.log("Asset loss:", assetLoss);
            console2.log("Rate loss:", rateLoss);

            // Allow 0.01% tolerance for rounding
            assertApproxEqRel(lhs, rhs, 0.0001e18, "Rate decrease should be proportional to asset loss");
        }

        // Depositor's share value should have decreased proportionally
        {
            uint256 depositor1ValueAfter = optimizer.convertToAssets(depositor1SharesBefore);
            uint256 depositor1ValueBefore = FixedPointMathLib.mulDiv(
                depositor1SharesBefore,
                rateBeforeBadDebt,
                WAD
            );
            assertLt(depositor1ValueAfter, depositor1ValueBefore, "Depositor value should decrease");

            // Verify depositor loss is proportional to bad debt
            uint256 depositorLoss = depositor1ValueBefore - depositor1ValueAfter;
            uint256 depositorLossPercent = FixedPointMathLib.mulDiv(depositorLoss, WAD, depositor1ValueBefore);
            uint256 assetLossPercent = FixedPointMathLib.mulDiv(assetLoss, WAD, totalAssetsBeforeBadDebt);

            console2.log("Depositor loss %:", depositorLossPercent);
            console2.log("Asset loss %:", assetLossPercent);

            assertApproxEqRel(
                depositorLossPercent,
                assetLossPercent,
                0.001e18, // 0.1% tolerance
                "Depositor loss should be proportional to total asset loss"
            );
        }
    }

    function test_lendingOptimizerShareCToken_badDebtRepricesIsolatedPairThroughVaultAggregator() public {
        (LendingOptimizerShareCToken shareCToken, MockV3Aggregator optimizerFeed) =
            _deployOptimizerShareCTokenForBadDebtPricing();

        uint256 depositAmount = 100_000e6;
        _prepareUSDC(depositor1, depositAmount);
        vm.startPrank(depositor1);
        usdc.approve(address(optimizer), depositAmount);
        optimizer.depositToMarket(depositAmount, depositor1, address(borrowableCUSDC));
        vm.stopPrank();

        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);

        _createBorrower(
            borrower1,
            marketManagerIsolated,
            ICToken(address(borrowableCDAI)),
            IBorrowableCToken(address(borrowableCUSDC)),
            10_000e18,
            7000e6
        );

        (uint256 sharesPriceBefore,) = oracleManager.getPriceIsolatedPair(
            address(shareCToken),
            address(borrowableCUSDC),
            BAD_SOURCE
        );
        uint256 totalAssetsBeforeBadDebt = optimizer.totalAssets();

        mockDaiFeed.setMockAnswer(0.1e8);
        _refreshMockFeeds();
        skip(30 days);
        _refreshMockFeeds();
        optimizerFeed.updateAnswer(1e8);

        address[] memory accounts = new address[](1);
        accounts[0] = borrower1;

        _prepareUSDC(user2, 10_000e6);
        vm.startPrank(user2);
        usdc.approve(address(borrowableCUSDC), 10_000e6);
        borrowableCUSDC.liquidate(accounts, address(borrowableCDAI));
        vm.stopPrank();

        assertEq(borrowableCUSDC.debtBalance(borrower1), 0, "borrower debt should be cleared");
        assertEq(
            optimizer.totalAssets(),
            totalAssetsBeforeBadDebt,
            "optimizer NAV must still be cached before market price path"
        );

        (uint256 staleOptimizerPrice, uint256 staleErrorCode) =
            oracleManager.getPrice(address(optimizer), true, true);
        assertEq(staleErrorCode, 0);

        (uint256 sharesPriceAfter,) = oracleManager.getPriceIsolatedPair(
            address(shareCToken),
            address(borrowableCUSDC),
            BAD_SOURCE
        );

        assertLt(
            optimizer.totalAssets(),
            totalAssetsBeforeBadDebt,
            "isolated pair price path must sync bad-debt NAV loss"
        );
        assertLt(sharesPriceAfter, sharesPriceBefore, "wrapper collateral price should fall after bad debt");

        (uint256 freshOptimizerPrice, uint256 freshErrorCode) =
            oracleManager.getPrice(address(optimizer), true, true);
        assertEq(freshErrorCode, 0);
        assertLt(freshOptimizerPrice, staleOptimizerPrice, "direct cached optimizer price was stale high");

        uint256 expectedSharesPrice = FixedPointMathLib.mulDiv(
            freshOptimizerPrice,
            shareCToken.exchangeRate(),
            WAD
        );
        assertEq(sharesPriceAfter, expectedSharesPrice);
    }

    function test_lendingOptimizerShareCToken_directShareCTokenPriceIsStaleAfterBadDebtUntilAccrual() public {
        (LendingOptimizerShareCToken shareCToken, MockV3Aggregator optimizerFeed) =
            _deployOptimizerShareCTokenForBadDebtPricing();

        uint256 depositAmount = 100_000e6;
        _prepareUSDC(depositor1, depositAmount);
        vm.startPrank(depositor1);
        usdc.approve(address(optimizer), depositAmount);
        optimizer.depositToMarket(depositAmount, depositor1, address(borrowableCUSDC));
        vm.stopPrank();

        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);

        _createBorrower(
            borrower1,
            marketManagerIsolated,
            ICToken(address(borrowableCDAI)),
            IBorrowableCToken(address(borrowableCUSDC)),
            10_000e18,
            7000e6
        );

        (uint256 priceBeforeBadDebt, uint256 priceBeforeErrorCode) =
            oracleManager.getPrice(address(shareCToken), true, true);
        assertEq(priceBeforeErrorCode, 0);
        uint256 totalAssetsBeforeBadDebt = optimizer.totalAssets();

        mockDaiFeed.setMockAnswer(0.1e8);
        _refreshMockFeeds();
        skip(30 days);
        _refreshMockFeeds();
        optimizerFeed.updateAnswer(1e8);

        address[] memory accounts = new address[](1);
        accounts[0] = borrower1;

        _prepareUSDC(user2, 10_000e6);
        vm.startPrank(user2);
        usdc.approve(address(borrowableCUSDC), 10_000e6);
        borrowableCUSDC.liquidate(accounts, address(borrowableCDAI));
        vm.stopPrank();

        assertEq(borrowableCUSDC.debtBalance(borrower1), 0, "borrower debt should be cleared");
        assertEq(
            optimizer.totalAssets(),
            totalAssetsBeforeBadDebt,
            "optimizer NAV must still be cached before direct cToken price read"
        );

        (uint256 staleShareCTokenPrice, uint256 staleErrorCode) =
            oracleManager.getPrice(address(shareCToken), true, true);
        assertEq(staleErrorCode, 0);
        assertEq(
            optimizer.totalAssets(),
            totalAssetsBeforeBadDebt,
            "direct share-cToken price read must not accrue optimizer"
        );
        assertEq(staleShareCTokenPrice, priceBeforeBadDebt, "direct share-cToken price stayed stale high");

        shareCToken.exchangeRateUpdated();

        assertLt(
            optimizer.totalAssets(),
            totalAssetsBeforeBadDebt,
            "wrapper accrual must sync optimizer bad-debt NAV loss"
        );

        (uint256 freshShareCTokenPrice, uint256 freshErrorCode) =
            oracleManager.getPrice(address(shareCToken), true, true);
        assertEq(freshErrorCode, 0);
        assertLt(freshShareCTokenPrice, staleShareCTokenPrice, "fresh share-cToken price should include NAV loss");

        (uint256 freshOptimizerPrice, uint256 optimizerErrorCode) =
            oracleManager.getPrice(address(optimizer), true, true);
        assertEq(optimizerErrorCode, 0);
        uint256 expectedShareCTokenPrice = FixedPointMathLib.mulDiv(
            freshOptimizerPrice,
            shareCToken.exchangeRate(),
            WAD
        );
        assertEq(freshShareCTokenPrice, expectedShareCTokenPrice);
    }

    function test_lendingOptimizerShareCToken_badDebtBlocksBorrowThroughFreshMarketPricing() public {
        (
            MarketManagerIsolated optimizerShareMarket,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken,
            MockV3Aggregator optimizerFeed
        ) = _deployOptimizerShareLaunchMarketForBadDebt();

        uint256 depositAmount = 100_000e6;
        _prepareUSDC(depositor1, depositAmount);
        vm.startPrank(depositor1);
        usdc.approve(address(optimizer), depositAmount);
        optimizer.depositToMarket(depositAmount, depositor1, address(borrowableCUSDC));
        uint256 optimizerShares = optimizer.balanceOf(depositor1);
        IERC20(address(optimizer)).approve(address(shareCToken), optimizerShares);
        shareCToken.depositAsCollateral(optimizerShares, depositor1);
        vm.stopPrank();

        _prepareUSDC(liquidityProvider, 100_000e6);
        vm.startPrank(liquidityProvider);
        usdc.approve(address(debtCToken), 100_000e6);
        debtCToken.deposit(100_000e6, liquidityProvider);
        vm.stopPrank();

        (, uint256 maxDebtBeforeBadDebt,) = optimizerShareMarket.statusOf(depositor1);
        uint256 initialBorrowAmount = FixedPointMathLib.mulDiv(
            maxDebtBeforeBadDebt,
            9970 * 1e6,
            BPS * WAD
        );
        uint256 additionalBorrowAmount = 100e6;
        assertGt(
            maxDebtBeforeBadDebt,
            _usdcDebtValue(initialBorrowAmount + additionalBorrowAmount),
            "pre-loss account should still have borrow room"
        );

        vm.prank(depositor1);
        debtCToken.borrow(initialBorrowAmount, depositor1);

        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);
        _createBorrower(
            borrower1,
            marketManagerIsolated,
            ICToken(address(borrowableCDAI)),
            IBorrowableCToken(address(borrowableCUSDC)),
            10_000e18,
            7000e6
        );

        uint256 totalAssetsBeforeBadDebt = optimizer.totalAssets();

        mockDaiFeed.setMockAnswer(0.1e8);
        _refreshMockFeeds();
        optimizerFeed.updateAnswer(1e8);

        address[] memory accounts = new address[](1);
        accounts[0] = borrower1;

        _prepareUSDC(user2, 10_000e6);
        vm.startPrank(user2);
        usdc.approve(address(borrowableCUSDC), 10_000e6);
        borrowableCUSDC.liquidate(accounts, address(borrowableCDAI));
        vm.stopPrank();

        assertEq(borrowableCUSDC.debtBalance(borrower1), 0, "borrower debt should be cleared");
        assertEq(
            optimizer.totalAssets(),
            totalAssetsBeforeBadDebt,
            "optimizer NAV must still be cached before market price path"
        );

        (uint256 staleOptimizerPrice, uint256 staleErrorCode) =
            oracleManager.getPrice(address(optimizer), true, true);
        assertEq(staleErrorCode, 0);

        uint256 staleMaxDebt =
            _optimizerShareCollateralMaxDebtValue(shareCToken, depositor1, staleOptimizerPrice);
        assertGt(
            staleMaxDebt,
            _usdcDebtValue(initialBorrowAmount + additionalBorrowAmount),
            "stale NAV would leave room for the extra borrow"
        );

        vm.expectRevert(MarketManagerIsolated.MarketManager__InsufficientCollateral.selector);
        vm.prank(depositor1);
        debtCToken.borrow(additionalBorrowAmount, depositor1);

        (, uint256 freshMaxDebt, uint256 freshDebt) = optimizerShareMarket.statusOf(depositor1);
        assertLt(
            freshMaxDebt,
            freshDebt + _usdcDebtValue(additionalBorrowAmount),
            "fresh market price should block the extra borrow"
        );
    }

    function test_lendingOptimizerShareCToken_badDebtBlocksCollateralMovementThroughFreshMarketPricing() public {
        (,, LendingOptimizerShareCToken shareCToken, uint256 totalAssetsBeforeBadDebt) =
            _prepareOptimizerShareAccountAfterBadDebt();
        uint256 shares = 1;
        address receiver = makeAddr("badDebtCollateralMovementReceiver");
        address spender = makeAddr("badDebtCollateralMovementSpender");

        assertGt(shareCToken.collateralPosted(depositor1), shares, "precondition: collateral was posted");

        vm.expectRevert(MarketManagerIsolated.MarketManager__InsufficientCollateral.selector);
        vm.prank(depositor1);
        shareCToken.removeCollateral(shares);

        vm.prank(depositor1);
        shareCToken.setDelegateApproval(spender, true);
        assertTrue(shareCToken.isDelegate(depositor1, spender), "delegate should be approved");
        vm.expectRevert(MarketManagerIsolated.MarketManager__InsufficientCollateral.selector);
        vm.prank(spender);
        shareCToken.removeCollateralFor(shares, depositor1);

        vm.expectRevert(MarketManagerIsolated.MarketManager__InsufficientCollateral.selector);
        vm.prank(depositor1);
        shareCToken.transfer(receiver, shares);

        vm.prank(depositor1);
        shareCToken.approve(spender, shares);
        vm.expectRevert(MarketManagerIsolated.MarketManager__InsufficientCollateral.selector);
        vm.prank(spender);
        shareCToken.transferFrom(depositor1, receiver, shares);

        vm.expectRevert(MarketManagerIsolated.MarketManager__InsufficientCollateral.selector);
        vm.prank(depositor1);
        shareCToken.redeem(shares, depositor1, depositor1);

        vm.expectRevert(MarketManagerIsolated.MarketManager__InsufficientCollateral.selector);
        vm.prank(depositor1);
        shareCToken.redeemCollateral(shares, depositor1, depositor1);

        vm.expectRevert(MarketManagerIsolated.MarketManager__InsufficientCollateral.selector);
        vm.prank(depositor1);
        shareCToken.withdraw(shares, depositor1, depositor1);

        vm.expectRevert(MarketManagerIsolated.MarketManager__InsufficientCollateral.selector);
        vm.prank(depositor1);
        shareCToken.withdrawCollateral(shares, depositor1, depositor1);

        assertEq(
            optimizer.totalAssets(),
            totalAssetsBeforeBadDebt,
            "failed collateral movement must not commit optimizer accrual"
        );
    }

    function test_lendingOptimizerShareCToken_badDebtStatusOfSyncsOptimizerShareCollateralPrice() public {
        (
            MarketManagerIsolated optimizerShareMarket,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken,
            uint256 totalAssetsBeforeBadDebt
        ) = _prepareOptimizerShareAccountAfterBadDebt();

        uint256 debtBeforeStatus = debtCToken.debtBalance(depositor1);
        assertGt(debtBeforeStatus, 0, "precondition: account should carry debt");

        (uint256 staleOptimizerPrice, uint256 staleErrorCode) =
            oracleManager.getPrice(address(optimizer), true, true);
        assertEq(staleErrorCode, 0);
        uint256 staleMaxDebt =
            _optimizerShareCollateralMaxDebtValue(shareCToken, depositor1, staleOptimizerPrice);
        assertGt(staleMaxDebt, _usdcDebtValue(debtBeforeStatus), "stale NAV would leave account healthy");
        assertEq(
            optimizer.totalAssets(),
            totalAssetsBeforeBadDebt,
            "precondition: optimizer NAV must still be cached before statusOf"
        );

        (, uint256 freshMaxDebt, uint256 freshDebt) = optimizerShareMarket.statusOf(depositor1);

        assertLt(
            optimizer.totalAssets(),
            totalAssetsBeforeBadDebt,
            "statusOf must sync optimizer-share collateral NAV loss"
        );
        assertLt(freshMaxDebt, staleMaxDebt, "fresh status should reduce collateral capacity");
        assertGt(freshDebt, freshMaxDebt, "fresh status should report the account underwater");
    }

    function test_lendingOptimizerShareCToken_badDebtLiquidatesThroughFreshMarketPricing() public {
        (
            ,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken,
            uint256 totalAssetsBeforeBadDebt
        ) = _prepareOptimizerShareAccountAfterBadDebt();

        uint256 debtBefore = debtCToken.debtBalance(depositor1);
        uint256 collateralBefore = shareCToken.collateralPosted(depositor1);

        (uint256 staleOptimizerPrice, uint256 staleErrorCode) =
            oracleManager.getPrice(address(optimizer), true, true);
        assertEq(staleErrorCode, 0);
        uint256 staleMaxDebt =
            _optimizerShareCollateralMaxDebtValue(shareCToken, depositor1, staleOptimizerPrice);
        assertGt(staleMaxDebt, _usdcDebtValue(debtBefore), "stale NAV would not liquidate");

        address[] memory accounts = new address[](1);
        accounts[0] = depositor1;

        _prepareUSDC(user2, debtBefore);
        vm.startPrank(user2);
        usdc.approve(address(debtCToken), debtBefore);
        debtCToken.liquidate(accounts, address(shareCToken));
        vm.stopPrank();

        assertLt(
            optimizer.totalAssets(),
            totalAssetsBeforeBadDebt,
            "liquidation price path must sync optimizer NAV loss"
        );
        assertLt(debtCToken.debtBalance(depositor1), debtBefore, "liquidation should reduce debt");
        assertLt(
            shareCToken.collateralPosted(depositor1),
            collateralBefore,
            "liquidation should seize posted collateral"
        );
        assertGt(shareCToken.balanceOf(user2), 0, "liquidator should receive seized shares");
    }

    function test_lendingOptimizerShareCToken_badDebtBatchLiquidatesMultipleAccountsThroughFreshMarketPricing() public {
        (
            MarketManagerIsolated optimizerShareMarket,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken,
            MockV3Aggregator optimizerFeed
        ) = _deployOptimizerShareLaunchMarketForBadDebt();

        address[] memory accounts = new address[](2);
        accounts[0] = depositor1;
        accounts[1] = depositor2;

        uint256[] memory depositAmounts = new uint256[](2);
        depositAmounts[0] = 100_000e6;
        depositAmounts[1] = 80_000e6;

        for (uint256 i; i < accounts.length; ++i) {
            _prepareUSDC(accounts[i], depositAmounts[i]);
            vm.startPrank(accounts[i]);
            usdc.approve(address(optimizer), depositAmounts[i]);
            optimizer.depositToMarket(depositAmounts[i], accounts[i], address(borrowableCUSDC));
            uint256 optimizerShares = optimizer.balanceOf(accounts[i]);
            IERC20(address(optimizer)).approve(address(shareCToken), optimizerShares);
            shareCToken.depositAsCollateral(optimizerShares, accounts[i]);
            vm.stopPrank();
        }

        _prepareUSDC(liquidityProvider, 200_000e6);
        vm.startPrank(liquidityProvider);
        usdc.approve(address(debtCToken), 200_000e6);
        debtCToken.deposit(200_000e6, liquidityProvider);
        vm.stopPrank();

        for (uint256 i; i < accounts.length; ++i) {
            (, uint256 maxDebtBeforeBadDebt,) = optimizerShareMarket.statusOf(accounts[i]);
            uint256 initialBorrowAmount = FixedPointMathLib.mulDiv(
                maxDebtBeforeBadDebt,
                9970 * 1e6,
                BPS * WAD
            );
            vm.prank(accounts[i]);
            debtCToken.borrow(initialBorrowAmount, accounts[i]);
        }

        vm.warp(optimizerShareMarket.accountAssets(depositor1) + optimizerShareMarket.MIN_HOLD_PERIOD());
        _refreshMockFeeds();
        optimizerFeed.updateAnswer(1e8);

        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);
        _createBorrower(
            borrower1,
            marketManagerIsolated,
            ICToken(address(borrowableCDAI)),
            IBorrowableCToken(address(borrowableCUSDC)),
            10_000e18,
            7000e6
        );

        uint256 totalAssetsBeforeBadDebt = optimizer.totalAssets();

        mockDaiFeed.setMockAnswer(0.1e8);
        _refreshMockFeeds();
        optimizerFeed.updateAnswer(1e8);

        address[] memory badDebtAccounts = new address[](1);
        badDebtAccounts[0] = borrower1;

        _prepareUSDC(user2, 10_000e6);
        vm.startPrank(user2);
        usdc.approve(address(borrowableCUSDC), 10_000e6);
        borrowableCUSDC.liquidate(badDebtAccounts, address(borrowableCDAI));
        vm.stopPrank();

        assertEq(
            optimizer.totalAssets(),
            totalAssetsBeforeBadDebt,
            "optimizer NAV must still be cached before batch liquidation"
        );

        uint256[] memory debtBefore = new uint256[](2);
        uint256[] memory collateralBefore = new uint256[](2);
        uint256 totalDebtBefore;
        for (uint256 i; i < accounts.length; ++i) {
            debtBefore[i] = debtCToken.debtBalance(accounts[i]);
            collateralBefore[i] = shareCToken.collateralPosted(accounts[i]);
            totalDebtBefore += debtBefore[i];
        }
        uint256 liquidatorSharesBefore = shareCToken.balanceOf(user2);

        _prepareUSDC(user2, totalDebtBefore);
        vm.startPrank(user2);
        usdc.approve(address(debtCToken), totalDebtBefore);
        debtCToken.liquidate(accounts, address(shareCToken));
        vm.stopPrank();

        assertLt(
            optimizer.totalAssets(),
            totalAssetsBeforeBadDebt,
            "batch liquidation price path must sync optimizer NAV loss once"
        );
        for (uint256 i; i < accounts.length; ++i) {
            assertLt(debtCToken.debtBalance(accounts[i]), debtBefore[i], "batch liquidation should reduce debt");
            assertLt(
                shareCToken.collateralPosted(accounts[i]),
                collateralBefore[i],
                "batch liquidation should seize posted collateral"
            );
        }
        assertGt(
            shareCToken.balanceOf(user2),
            liquidatorSharesBefore,
            "liquidator should receive seized shares from batch"
        );
    }

    function test_lendingOptimizerShareCToken_badDebtLiquidateExactUsesFreshMarketPricing() public {
        (
            ,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken,
            uint256 totalAssetsBeforeBadDebt
        ) = _prepareOptimizerShareAccountAfterBadDebt();

        uint256 debtBefore = debtCToken.debtBalance(depositor1);
        uint256 collateralBefore = shareCToken.collateralPosted(depositor1);
        uint256 liquidatorSharesBefore = shareCToken.balanceOf(user2);
        uint256 debtToRepay = debtBefore / 4;

        assertGt(debtToRepay, 0, "precondition: exact liquidation has debt to repay");

        address[] memory accounts = new address[](1);
        accounts[0] = depositor1;
        uint256[] memory debtAmounts = new uint256[](1);
        debtAmounts[0] = debtToRepay;

        _prepareUSDC(user2, debtToRepay);
        uint256 liquidatorUsdcBefore = usdc.balanceOf(user2);
        vm.startPrank(user2);
        usdc.approve(address(debtCToken), debtToRepay);
        debtCToken.liquidateExact(debtAmounts, accounts, address(shareCToken));
        vm.stopPrank();

        assertLt(
            optimizer.totalAssets(),
            totalAssetsBeforeBadDebt,
            "exact liquidation price path must sync optimizer NAV loss"
        );
        assertEq(liquidatorUsdcBefore - usdc.balanceOf(user2), debtToRepay, "exact liquidation should collect requested debt");
        assertLt(debtCToken.debtBalance(depositor1), debtBefore, "exact liquidation should reduce borrower debt");
        assertLt(
            shareCToken.collateralPosted(depositor1),
            collateralBefore,
            "exact liquidation should seize posted collateral"
        );
        assertGt(
            shareCToken.balanceOf(user2),
            liquidatorSharesBefore,
            "exact liquidation should transfer seized shares to liquidator"
        );
    }

    // ==================== MULTI-MARKET BAD DEBT ====================

    function test_lendingOptimizer_badDebt_multipleMarketsBadDebt() public {
        // Deposit into optimizer across all markets
        uint256 depositPerMarket = 50_000e6;
        _prepareUSDC(depositor1, depositPerMarket * 3);
        vm.startPrank(depositor1);
        usdc.approve(address(optimizer), depositPerMarket * 3);
        optimizer.depositToMarket(depositPerMarket, depositor1, address(borrowableCUSDC));
        optimizer.depositToMarket(depositPerMarket, depositor1, address(borrowableCUSDC2));
        optimizer.depositToMarket(depositPerMarket, depositor1, address(borrowableCUSDC3));
        vm.stopPrank();

        // Setup market 1 config (tokens already listed in setUp)
        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);

        // Create borrowers in each market
        _createBorrower(
            borrower1,
            marketManagerIsolated,
            ICToken(address(borrowableCDAI)),
            IBorrowableCToken(address(borrowableCUSDC)),
            10_000e18,
            7000e6
        );

        _createBorrower(
            borrower2,
            marketManager2,
            ICToken(address(collateralDAI2)),
            IBorrowableCToken(address(borrowableCUSDC2)),
            10_000e18,
            7000e6
        );

        _createBorrower(
            borrower3,
            marketManager3,
            ICToken(address(collateralWETH)),
            IBorrowableCToken(address(borrowableCUSDC3)),
            5e18,      // 5 ETH @ $2000 = $10k
            7000e6     // 7k USDC borrowed
        );

        uint256 rateBeforeCrash = optimizer.exchangeRateUpdated();
        uint256 totalAssetsBefore = optimizer.totalAssets();

        console2.log("Initial rate:", rateBeforeCrash);
        console2.log("Initial total assetsOrBps:", totalAssetsBefore);

        // Crash all collateral prices simultaneously
        mockDaiFeed.setMockAnswer(0.1e8);  // DAI to $0.10
        mockWethFeed.setMockAnswer(200e8); // ETH to $200 (90% drop)
        _refreshMockFeeds();

        skip(7 days);
        _refreshMockFeeds();

        // Liquidate all borrowers
        address[] memory accounts1 = new address[](1);
        accounts1[0] = borrower1;

        address[] memory accounts2 = new address[](1);
        accounts2[0] = borrower2;

        address[] memory accounts3 = new address[](1);
        accounts3[0] = borrower3;

        _prepareUSDC(user2, 30_000e6);
        vm.startPrank(user2);
        usdc.approve(address(borrowableCUSDC), 10_000e6);
        usdc.approve(address(borrowableCUSDC2), 10_000e6);
        usdc.approve(address(borrowableCUSDC3), 10_000e6);

        borrowableCUSDC.liquidate(accounts1, address(borrowableCDAI));
        borrowableCUSDC2.liquidate(accounts2, address(collateralDAI2));
        borrowableCUSDC3.liquidate(accounts3, address(collateralWETH));
        vm.stopPrank();

        // Check optimizer state after bad debt
        uint256 rateAfterCrash = optimizer.exchangeRateUpdated();
        uint256 totalAssetsAfter = optimizer.totalAssets();

        console2.log("Rate after crash:", rateAfterCrash);
        console2.log("Total assets after:", totalAssetsAfter);

        // All markets had bad debt, so rate should decrease significantly
        assertLt(rateAfterCrash, rateBeforeCrash, "Rate should decrease after multi-market bad debt");
        assertLt(totalAssetsAfter, totalAssetsBefore, "Total assets should decrease");
    }

    // ==================== ISOLATED MARKET BAD DEBT ====================

    function test_lendingOptimizer_badDebt_isolatedToOneMarket() public {
        // Deposit into optimizer across markets
        uint256 depositPerMarket = 50_000e6;
        _prepareUSDC(depositor1, depositPerMarket * 3);
        vm.startPrank(depositor1);
        usdc.approve(address(optimizer), depositPerMarket * 3);
        optimizer.depositToMarket(depositPerMarket, depositor1, address(borrowableCUSDC));
        optimizer.depositToMarket(depositPerMarket, depositor1, address(borrowableCUSDC2));
        optimizer.depositToMarket(depositPerMarket, depositor1, address(borrowableCUSDC3));
        vm.stopPrank();

        // Only create borrower in market 3 (WETH collateral)
        _createBorrower(
            borrower3,
            marketManager3,
            ICToken(address(collateralWETH)),
            IBorrowableCToken(address(borrowableCUSDC3)),
            5e18,
            7000e6
        );

        uint256 rateBefore = optimizer.exchangeRateUpdated();

        // Get individual market values before crash
        uint256 market1AssetsBefore = borrowableCUSDC.convertToAssets(
            borrowableCUSDC.balanceOf(address(optimizer))
        );
        uint256 market2AssetsBefore = borrowableCUSDC2.convertToAssets(
            borrowableCUSDC2.balanceOf(address(optimizer))
        );
        uint256 market3AssetsBefore = borrowableCUSDC3.convertToAssets(
            borrowableCUSDC3.balanceOf(address(optimizer))
        );

        console2.log("Market 1 assets before:", market1AssetsBefore);
        console2.log("Market 2 assets before:", market2AssetsBefore);
        console2.log("Market 3 assets before:", market3AssetsBefore);

        // Only crash WETH (affects market 3 only)
        mockWethFeed.setMockAnswer(100e8); // ETH crashes to $100
        _refreshMockFeeds();
        skip(7 days);
        _refreshMockFeeds();

        // Liquidate borrower3
        address[] memory accounts = new address[](1);
        accounts[0] = borrower3;

        _prepareUSDC(user2, 10_000e6);
        vm.startPrank(user2);
        usdc.approve(address(borrowableCUSDC3), 10_000e6);
        borrowableCUSDC3.liquidate(accounts, address(collateralWETH));
        vm.stopPrank();

        // Get individual market values after crash
        uint256 market1AssetsAfter = borrowableCUSDC.convertToAssets(
            borrowableCUSDC.balanceOf(address(optimizer))
        );
        uint256 market2AssetsAfter = borrowableCUSDC2.convertToAssets(
            borrowableCUSDC2.balanceOf(address(optimizer))
        );
        uint256 market3AssetsAfter = borrowableCUSDC3.convertToAssets(
            borrowableCUSDC3.balanceOf(address(optimizer))
        );

        console2.log("Market 1 assets after:", market1AssetsAfter);
        console2.log("Market 2 assets after:", market2AssetsAfter);
        console2.log("Market 3 assets after:", market3AssetsAfter);

        // Markets 1 and 2 should be unaffected (may have slight interest accrual)
        assertApproxEqRel(market1AssetsAfter, market1AssetsBefore, 0.01e18, "Market 1 should be unaffected");
        assertApproxEqRel(market2AssetsAfter, market2AssetsBefore, 0.01e18, "Market 2 should be unaffected");

        // Market 3 should have decreased due to bad debt
        assertLt(market3AssetsAfter, market3AssetsBefore, "Market 3 should decrease due to bad debt");

        // Overall rate should decrease, but not as much as if all markets had bad debt
        uint256 rateAfter = optimizer.exchangeRateUpdated();
        assertLt(rateAfter, rateBefore, "Overall rate should decrease");
    }

    // ==================== WITHDRAWAL AFTER BAD DEBT ====================

    function test_lendingOptimizer_badDebt_withdrawAfterBadDebt() public {
        // Two depositors
        uint256 deposit1 = 100_000e6;
        uint256 deposit2 = 50_000e6;

        _prepareUSDC(depositor1, deposit1);
        _prepareUSDC(depositor2, deposit2);

        vm.startPrank(depositor1);
        usdc.approve(address(optimizer), deposit1);
        optimizer.depositToMarket(deposit1, depositor1, address(borrowableCUSDC));
        vm.stopPrank();

        vm.startPrank(depositor2);
        usdc.approve(address(optimizer), deposit2);
        optimizer.depositToMarket(deposit2, depositor2, address(borrowableCUSDC));
        vm.stopPrank();

        uint256 depositor1Shares = optimizer.balanceOf(depositor1);
        uint256 depositor2Shares = optimizer.balanceOf(depositor2);

        // Setup config (tokens already listed in setUp)
        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);

        _createBorrower(
            borrower1,
            marketManagerIsolated,
            ICToken(address(borrowableCDAI)),
            IBorrowableCToken(address(borrowableCUSDC)),
            20_000e18,
            14000e6
        );

        // Crash and liquidate
        mockDaiFeed.setMockAnswer(0.05e8);
        _refreshMockFeeds();
        skip(30 days);
        _refreshMockFeeds();

        {
            address[] memory accounts = new address[](1);
            accounts[0] = borrower1;

            _prepareUSDC(user2, 20_000e6);
            vm.startPrank(user2);
            usdc.approve(address(borrowableCUSDC), 20_000e6);
            borrowableCUSDC.liquidate(accounts, address(borrowableCDAI));
            vm.stopPrank();
        }

        // Trigger accrual to recognize bad debt
        optimizer.accrueIfNeeded();

        // Since optimizer is sole liquidity provider in borrowableCUSDC,
        // we can derive expected values precisely from cToken state
        uint256 optimizerCTokenShares = borrowableCUSDC.balanceOf(address(optimizer));
        uint256 optimizerAssetsInCToken = borrowableCUSDC.convertToAssets(optimizerCTokenShares);
        uint256 optimizerTotalSupply = optimizer.totalSupply();

        // Verify optimizer's totalAssets matches cToken-derived value
        assertEq(
            optimizer.totalAssets(),
            optimizerAssetsInCToken,
            "Optimizer totalAssets should match cToken assets"
        );

        // Compute expected withdrawals using cToken-derived totalAssets
        uint256 expectedWithdrawn1 = FixedPointMathLib.mulDiv(
            depositor1Shares,
            optimizerAssetsInCToken,
            optimizerTotalSupply
        );
        uint256 expectedWithdrawn2 = FixedPointMathLib.mulDiv(
            depositor2Shares,
            optimizerAssetsInCToken,
            optimizerTotalSupply
        );

        console2.log("cToken shares held by optimizer:", optimizerCTokenShares);
        console2.log("Assets derived from cToken:", optimizerAssetsInCToken);
        console2.log("Expected withdrawn1:", expectedWithdrawn1);
        console2.log("Expected withdrawn2:", expectedWithdrawn2);

        // Both depositors withdraw
        vm.prank(depositor1);
        uint256 withdrawn1 = optimizer.redeem(depositor1Shares, depositor1, depositor1);

        vm.prank(depositor2);
        uint256 withdrawn2 = optimizer.redeem(depositor2Shares, depositor2, depositor2);

        console2.log("Actual withdrawn1:", withdrawn1);
        console2.log("Actual withdrawn2:", withdrawn2);

        // Verify actual matches expected. The conversion roundtrip in
        // redeem() (previewRedeem(previewDeposit())) may reduce payout by
        // a few wei per market vs the raw convertToAssets calculation.
        assertApproxEqAbs(withdrawn1, expectedWithdrawn1, 3, "Withdrawn1 should match cToken-derived expectation");
        assertApproxEqAbs(withdrawn2, expectedWithdrawn2, 3, "Withdrawn2 should match cToken-derived expectation");

        // Both should receive less than deposited due to bad debt
        assertLt(withdrawn1, deposit1, "Depositor1 should receive less due to bad debt");
        assertLt(withdrawn2, deposit2, "Depositor2 should receive less due to bad debt");

        // Verify proportionality via share ratio (depositor1 has 2x shares of depositor2)
        // withdrawn1 / depositor1Shares should equal withdrawn2 / depositor2Shares
        // Cross-multiply: withdrawn1 * depositor2Shares = withdrawn2 * depositor1Shares
        // Max error from rounding per withdrawal amplified by share count,
        // plus conversion roundtrip rounding per market.
        assertApproxEqAbs(
            withdrawn1 * depositor2Shares,
            withdrawn2 * depositor1Shares,
            depositor1Shares * 2,
            "Withdrawal amounts should be proportional to shares"
        );
    }

    // ==================== DEPOSIT AFTER BAD DEBT ====================

    function test_lendingOptimizer_badDebt_depositAfterBadDebt() public {
        // Initial deposit
        uint256 initialDeposit = 100_000e6;
        _prepareUSDC(depositor1, initialDeposit);
        vm.startPrank(depositor1);
        usdc.approve(address(optimizer), initialDeposit);
        optimizer.depositToMarket(initialDeposit, depositor1, address(borrowableCUSDC));
        vm.stopPrank();

        uint256 depositor1SharesBefore = optimizer.balanceOf(depositor1);

        // Setup config (tokens already listed in setUp)
        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);

        _createBorrower(
            borrower1,
            marketManagerIsolated,
            ICToken(address(borrowableCDAI)),
            IBorrowableCToken(address(borrowableCUSDC)),
            10_000e18,
            7000e6
        );

        mockDaiFeed.setMockAnswer(0.1e8);
        _refreshMockFeeds();
        skip(30 days);
        _refreshMockFeeds();

        address[] memory accounts = new address[](1);
        accounts[0] = borrower1;

        _prepareUSDC(user2, 10_000e6);
        vm.startPrank(user2);
        usdc.approve(address(borrowableCUSDC), 10_000e6);
        borrowableCUSDC.liquidate(accounts, address(borrowableCDAI));
        vm.stopPrank();

        // Record rate after bad debt
        uint256 rateAfterBadDebt = optimizer.exchangeRateUpdated();

        // New depositor comes in after bad debt
        uint256 newDeposit = 50_000e6;
        _prepareUSDC(depositor2, newDeposit);
        vm.startPrank(depositor2);
        usdc.approve(address(optimizer), newDeposit);
        uint256 depositor2Shares = optimizer.deposit(newDeposit, depositor2);
        vm.stopPrank();

        console2.log("Rate after bad debt:", rateAfterBadDebt);
        console2.log("Depositor2 shares received:", depositor2Shares);

        // Depositor2 should get more shares per asset since rate is lower
        uint256 expectedShares = FixedPointMathLib.mulDiv(newDeposit, WAD, rateAfterBadDebt);
        assertApproxEqRel(depositor2Shares, expectedShares, 0.01e18, "New depositor gets fair shares");

        // Rate should be preserved after new deposit
        uint256 rateAfterNewDeposit = optimizer.exchangeRateUpdated();
        assertApproxEqRel(rateAfterNewDeposit, rateAfterBadDebt, 0.001e18, "Rate preserved after deposit");
    }

    function test_lendingOptimizer_badDebt_depositAutoAccruesWithoutManualPreAccrual() public {
        uint256 initialDeposit = 100_000e6;
        _prepareUSDC(depositor1, initialDeposit);
        vm.startPrank(depositor1);
        usdc.approve(address(optimizer), initialDeposit);
        optimizer.depositToMarket(initialDeposit, depositor1, address(borrowableCUSDC));
        vm.stopPrank();

        uint256 staleTotalAssets = optimizer.totalAssets();
        _realizeSingleMarketBadDebtWithoutOptimizerAccrual();

        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV must still be stale before deposit"
        );

        uint256 freshAssetsBeforeDeposit = _optimizerAssetsFromApprovedMarkets();
        uint256 supplyBeforeDeposit = optimizer.totalSupply();
        assertLt(freshAssetsBeforeDeposit, staleTotalAssets, "bad debt must reduce cToken-derived assets");

        uint256 newDeposit = 50_000e6;
        _prepareUSDC(depositor2, newDeposit);
        vm.startPrank(depositor2);
        usdc.approve(address(optimizer), newDeposit);
        uint256 depositor2Shares = optimizer.deposit(newDeposit, depositor2);
        vm.stopPrank();

        uint256 trackedAssets = optimizer.totalAssets() - freshAssetsBeforeDeposit;
        uint256 expectedShares = FixedPointMathLib.fullMulDiv(
            trackedAssets,
            supplyBeforeDeposit,
            freshAssetsBeforeDeposit
        );
        uint256 staleShares = FixedPointMathLib.fullMulDiv(
            trackedAssets,
            supplyBeforeDeposit,
            staleTotalAssets
        );

        assertApproxEqAbs(
            optimizer.totalAssets(),
            _optimizerAssetsFromApprovedMarkets(),
            1,
            "deposit should sync NAV to cTokens"
        );
        assertEq(depositor2Shares, expectedShares, "deposit must mint against fresh bad-debt NAV");
        assertGt(depositor2Shares, staleShares, "stale NAV would have under-minted the new depositor");
    }

    function test_lendingOptimizer_badDebt_withdrawAutoAccruesWithoutManualPreAccrual() public {
        uint256 depositAmount = 100_000e6;
        _prepareUSDC(depositor1, depositAmount);
        vm.startPrank(depositor1);
        usdc.approve(address(optimizer), depositAmount);
        optimizer.depositToMarket(depositAmount, depositor1, address(borrowableCUSDC));
        vm.stopPrank();

        uint256 staleTotalAssets = optimizer.totalAssets();
        _realizeSingleMarketBadDebtWithoutOptimizerAccrual();

        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV must still be stale before withdraw"
        );

        uint256 freshAssetsBeforeWithdraw = _optimizerAssetsFromApprovedMarkets();
        uint256 supplyBeforeWithdraw = optimizer.totalSupply();
        assertLt(freshAssetsBeforeWithdraw, staleTotalAssets, "bad debt must reduce cToken-derived assets");

        uint256 withdrawAmount = 10_000e6;
        uint256 balanceBefore = usdc.balanceOf(depositor1);
        vm.prank(depositor1);
        uint256 sharesBurned = optimizer.withdraw(withdrawAmount, depositor1, depositor1);

        uint256 actualCost = freshAssetsBeforeWithdraw - optimizer.totalAssets();
        uint256 expectedShares = FixedPointMathLib.fullMulDivUp(
            actualCost,
            supplyBeforeWithdraw,
            freshAssetsBeforeWithdraw
        );
        uint256 staleShares = FixedPointMathLib.fullMulDivUp(
            actualCost,
            supplyBeforeWithdraw,
            staleTotalAssets
        );

        assertEq(usdc.balanceOf(depositor1) - balanceBefore, withdrawAmount, "withdraw should pay requested assets");
        assertEq(optimizer.totalAssets(), _optimizerAssetsFromApprovedMarkets(), "withdraw should sync NAV to cTokens");
        assertEq(sharesBurned, expectedShares, "withdraw must burn against fresh bad-debt NAV");
        assertGt(sharesBurned, staleShares, "stale NAV would have under-burned the withdrawing depositor");
    }

    function test_lendingOptimizer_badDebt_redeemAutoAccruesWithoutManualPreAccrual() public {
        uint256 depositAmount = 100_000e6;
        _prepareUSDC(depositor1, depositAmount);
        vm.startPrank(depositor1);
        usdc.approve(address(optimizer), depositAmount);
        optimizer.depositToMarket(depositAmount, depositor1, address(borrowableCUSDC));
        vm.stopPrank();

        uint256 staleTotalAssets = optimizer.totalAssets();
        _realizeSingleMarketBadDebtWithoutOptimizerAccrual();

        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV must still be stale before redeem"
        );

        uint256 freshAssetsBeforeRedeem = _optimizerAssetsFromApprovedMarkets();
        uint256 supplyBeforeRedeem = optimizer.totalSupply();
        uint256 sharesToRedeem = optimizer.balanceOf(depositor1) / 3;
        assertLt(freshAssetsBeforeRedeem, staleTotalAssets, "bad debt must reduce cToken-derived assets");

        uint256 expectedFreshAssets = FixedPointMathLib.fullMulDiv(
            sharesToRedeem,
            freshAssetsBeforeRedeem,
            supplyBeforeRedeem
        );
        uint256 staleAssets = FixedPointMathLib.fullMulDiv(
            sharesToRedeem,
            staleTotalAssets,
            supplyBeforeRedeem
        );

        uint256 balanceBefore = usdc.balanceOf(depositor1);
        vm.prank(depositor1);
        uint256 assetsRedeemed = optimizer.redeem(sharesToRedeem, depositor1, depositor1);

        assertEq(usdc.balanceOf(depositor1) - balanceBefore, assetsRedeemed, "redeem should transfer returned assets");
        assertEq(optimizer.totalAssets(), _optimizerAssetsFromApprovedMarkets(), "redeem should sync NAV to cTokens");
        assertApproxEqAbs(assetsRedeemed, expectedFreshAssets, 3, "redeem must pay against fresh bad-debt NAV");
        assertLt(assetsRedeemed, staleAssets, "stale NAV would have overpaid the redeeming depositor");
    }

    function test_lendingOptimizer_badDebt_unrealizedUnderwaterWithdrawMatchesDirectCTokenAccounting() public {
        uint256 depositAmount = 100_000e6;
        _prepareUSDC(depositor1, depositAmount);
        vm.startPrank(depositor1);
        usdc.approve(address(optimizer), depositAmount);
        optimizer.depositToMarket(depositAmount, depositor1, address(borrowableCUSDC));
        vm.stopPrank();

        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);
        _createBorrower(
            borrower1,
            marketManagerIsolated,
            ICToken(address(borrowableCDAI)),
            IBorrowableCToken(address(borrowableCUSDC)),
            10_000e18,
            7000e6
        );

        mockDaiFeed.setMockAnswer(0.1e8);
        _refreshMockFeeds();

        (, uint256 maxDebt, uint256 debt) = marketManagerIsolated.statusOf(borrower1);
        assertGt(debt, maxDebt, "precondition: borrower must be underwater before liquidation");

        uint256 withdrawAmount = 10_000e6;
        uint256 marketDebtBefore = borrowableCUSDC.marketOutstandingDebt();
        uint256 cTokenTotalAssetsBefore = borrowableCUSDC.totalAssets();

        assertGt(marketDebtBefore, 0, "precondition: market must carry borrower debt");
        assertLe(withdrawAmount, borrowableCUSDC.assetsHeld(), "precondition: cToken liquidity must cover withdraw");

        {
            uint256 optimizerTotalAssets = optimizer.totalAssets();
            uint256 optimizerCTokenShares = borrowableCUSDC.balanceOf(address(optimizer));
            assertApproxEqAbs(
                optimizerTotalAssets,
                borrowableCUSDC.convertToAssets(optimizerCTokenShares),
                1,
                "precondition: optimizer NAV should match cToken accounting"
            );
        }

        uint256 directCTokenSharesBurned;
        uint256 directReceived;
        {
            uint256 snapshotId = vm.snapshotState();
            address directReceiver = makeAddr("directReceiver");
            uint256 directReceiverBefore = usdc.balanceOf(directReceiver);
            vm.prank(address(optimizer));
            directCTokenSharesBurned = borrowableCUSDC.withdraw(
                withdrawAmount,
                directReceiver,
                address(optimizer)
            );
            directReceived = usdc.balanceOf(directReceiver) - directReceiverBefore;
            assertTrue(vm.revertToState(snapshotId), "failed to restore pre-realization bad debt state");
        }

        uint256 optimizerReceived;
        uint256 optimizerCTokenSharesBurned;
        uint256 optimizerSharesBurned;
        uint256 expectedOptimizerShares;
        {
            uint256 depositorBalanceBefore = usdc.balanceOf(depositor1);
            uint256 optimizerSupplyBefore = optimizer.totalSupply();
            uint256 optimizerCTokenSharesBefore = borrowableCUSDC.balanceOf(address(optimizer));
            uint256 optimizerTotalAssetsBefore = optimizer.totalAssets();

            vm.prank(depositor1);
            optimizerSharesBurned = optimizer.withdraw(withdrawAmount, depositor1, depositor1);

            optimizerReceived = usdc.balanceOf(depositor1) - depositorBalanceBefore;
            optimizerCTokenSharesBurned =
                optimizerCTokenSharesBefore - borrowableCUSDC.balanceOf(address(optimizer));
            uint256 actualOptimizerCost = optimizerTotalAssetsBefore - optimizer.totalAssets();
            expectedOptimizerShares = FixedPointMathLib.fullMulDivUp(
                actualOptimizerCost,
                optimizerSupplyBefore,
                optimizerTotalAssetsBefore
            );
        }

        assertEq(optimizerReceived, directReceived, "optimizer withdraw should match direct cToken payout");
        assertEq(optimizerReceived, withdrawAmount, "optimizer withdraw should pay requested assets");
        assertEq(
            optimizerCTokenSharesBurned,
            directCTokenSharesBurned,
            "optimizer should burn the same cToken shares as direct withdrawal"
        );
        assertEq(optimizerSharesBurned, expectedOptimizerShares, "optimizer should price burned shares from cToken cost");
        assertEq(borrowableCUSDC.marketOutstandingDebt(), marketDebtBefore, "withdraw should not realize borrower debt");
        assertEq(
            borrowableCUSDC.totalAssets(),
            cTokenTotalAssetsBefore - withdrawAmount,
            "pre-realization withdraw should use ordinary cToken accounting"
        );
        assertEq(
            optimizer.totalAssets(),
            borrowableCUSDC.convertToAssets(borrowableCUSDC.balanceOf(address(optimizer))),
            "optimizer NAV should remain synced to direct cToken accounting"
        );
    }

    // ==================== VESTING DURING BAD DEBT ====================

    function test_lendingOptimizer_badDebt_duringActiveYield() public {
        // Deposit
        uint256 depositAmount = 100_000e6;
        _prepareUSDC(depositor1, depositAmount);
        vm.startPrank(depositor1);
        usdc.approve(address(optimizer), depositAmount);
        optimizer.depositToMarket(depositAmount, depositor1, address(borrowableCUSDC));
        vm.stopPrank();

        // Let some yield accrue
        skip(2 days);
        optimizer.exchangeRateUpdated();

        // Skip some time
        skip(6 hours);

        uint256 rateBeforeBadDebt = optimizer.exchangeRateUpdated();

        console2.log("Rate before bad debt:", rateBeforeBadDebt);

        // Refresh feeds to avoid stale price errors
        _refreshMockFeeds();

        // Setup config (tokens already listed in setUp)
        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);

        _createBorrower(
            borrower1,
            marketManagerIsolated,
            ICToken(address(borrowableCDAI)),
            IBorrowableCToken(address(borrowableCUSDC)),
            10_000e18,
            7000e6
        );

        mockDaiFeed.setMockAnswer(0.1e8);
        _refreshMockFeeds();

        address[] memory accounts = new address[](1);
        accounts[0] = borrower1;

        _prepareUSDC(user2, 10_000e6);
        vm.startPrank(user2);
        usdc.approve(address(borrowableCUSDC), 10_000e6);
        borrowableCUSDC.liquidate(accounts, address(borrowableCDAI));
        vm.stopPrank();

        // Complete vesting period and check final state
        skip(2 days);
        _refreshMockFeeds();

        uint256 rateAfterBadDebt = optimizer.exchangeRateUpdated();

        console2.log("Rate after bad debt (post-vesting):", rateAfterBadDebt);

        // Rate should be lower due to bad debt
        assertLt(rateAfterBadDebt, rateBeforeBadDebt, "Rate should decrease due to bad debt");
    }

    // ==================== EXTREME BAD DEBT ====================

    function test_lendingOptimizer_badDebt_extremeLoss() public {
        // Deposit
        uint256 depositAmount = 100_000e6;
        _prepareUSDC(depositor1, depositAmount);
        vm.startPrank(depositor1);
        usdc.approve(address(optimizer), depositAmount);
        optimizer.depositToMarket(depositAmount, depositor1, address(borrowableCUSDC));
        vm.stopPrank();

        // Setup config with higher caps (tokens already listed in setUp)
        _setCTokenConfigBasic(address(borrowableCDAI), 1_000_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);

        // Create max leverage borrower
        _createBorrower(
            borrower1,
            marketManagerIsolated,
            ICToken(address(borrowableCDAI)),
            IBorrowableCToken(address(borrowableCUSDC)),
            100_000e18, // 100k DAI collateral
            70_000e6    // 70k USDC borrowed
        );

        uint256 rateBefore = optimizer.exchangeRateUpdated();
        uint256 totalAssetsBefore = optimizer.totalAssets();

        console2.log("Rate before extreme crash:", rateBefore);
        console2.log("Total assets before:", totalAssetsBefore);

        // Extreme crash - DAI becomes nearly worthless
        mockDaiFeed.setMockAnswer(0.01e8); // DAI to $0.01
        _refreshMockFeeds();
        skip(30 days);
        _refreshMockFeeds();

        // Liquidate
        address[] memory accounts = new address[](1);
        accounts[0] = borrower1;

        _prepareUSDC(user2, 100_000e6);
        vm.startPrank(user2);
        usdc.approve(address(borrowableCUSDC), 100_000e6);
        borrowableCUSDC.liquidate(accounts, address(borrowableCDAI));
        vm.stopPrank();

        uint256 rateAfter = optimizer.exchangeRateUpdated();
        uint256 totalAssetsAfter = optimizer.totalAssets();

        console2.log("Rate after extreme crash:", rateAfter);
        console2.log("Total assets after:", totalAssetsAfter);

        // Massive loss should be reflected
        assertLt(rateAfter, rateBefore, "Rate should decrease significantly");

        // Optimizer should still be functional
        uint256 depositorValue = optimizer.convertToAssets(optimizer.balanceOf(depositor1));
        assertGt(depositorValue, 0, "Depositor should still have some value");

        // New deposits should still work
        _prepareUSDC(depositor2, 10_000e6);
        vm.startPrank(depositor2);
        usdc.approve(address(optimizer), 10_000e6);
        uint256 newShares = optimizer.deposit(10_000e6, depositor2);
        vm.stopPrank();

        assertGt(newShares, 0, "New deposits should still work");
    }

    // ==================== REBALANCE AFTER BAD DEBT ====================

    function test_lendingOptimizer_badDebt_rebalanceAfter() public {
        // Deposit to multiple markets
        uint256 depositPerMarket = 50_000e6;
        _prepareUSDC(depositor1, depositPerMarket * 3);
        vm.startPrank(depositor1);
        usdc.approve(address(optimizer), depositPerMarket * 3);
        optimizer.depositToMarket(depositPerMarket, depositor1, address(borrowableCUSDC));
        optimizer.depositToMarket(depositPerMarket, depositor1, address(borrowableCUSDC2));
        optimizer.depositToMarket(depositPerMarket, depositor1, address(borrowableCUSDC3));
        vm.stopPrank();

        // Create bad debt in market 3
        _createBorrower(
            borrower3,
            marketManager3,
            ICToken(address(collateralWETH)),
            IBorrowableCToken(address(borrowableCUSDC3)),
            5e18,
            7000e6
        );

        mockWethFeed.setMockAnswer(100e8);
        _refreshMockFeeds();
        skip(7 days);
        _refreshMockFeeds();

        address[] memory accounts = new address[](1);
        accounts[0] = borrower3;

        _prepareUSDC(user2, 10_000e6);
        vm.startPrank(user2);
        usdc.approve(address(borrowableCUSDC3), 10_000e6);
        borrowableCUSDC3.liquidate(accounts, address(collateralWETH));
        vm.stopPrank();

        // Attempt rebalance after bad debt
        centralRegistry.addHarvestPermissions(address(this));

        uint256 market3Assets = borrowableCUSDC3.convertToAssets(
            borrowableCUSDC3.balanceOf(address(optimizer))
        );

        // Update cap for market 1 to allow receiving funds from damaged market
        optimizer.updateCap(address(borrowableCUSDC), 8000); // 80% cap

        // Rebalance: move assets from market 3 (damaged) to market 1 (healthy)
        LendingOptimizer.ReallocationAction[] memory actions = new LendingOptimizer.ReallocationAction[](3);
        actions[0] = LendingOptimizer.ReallocationAction({
            cToken: IBorrowableCToken(address(borrowableCUSDC)),
            assetsOrBps: int256(market3Assets)
        });
        actions[1] = LendingOptimizer.ReallocationAction({
            cToken: IBorrowableCToken(address(borrowableCUSDC2)),
            assetsOrBps: int256(0)
        });
        actions[2] = LendingOptimizer.ReallocationAction({
            cToken: IBorrowableCToken(address(borrowableCUSDC3)),
            assetsOrBps: -int256(market3Assets)
        });

        // Rebalance should succeed
        LendingOptimizer.AllocationBound[] memory bounds = new LendingOptimizer.AllocationBound[](3);
        bounds[0] = LendingOptimizer.AllocationBound({ cToken: address(borrowableCUSDC), minBps: 0, maxBps: 10000 });
        bounds[1] = LendingOptimizer.AllocationBound({ cToken: address(borrowableCUSDC2), minBps: 0, maxBps: 10000 });
        bounds[2] = LendingOptimizer.AllocationBound({ cToken: address(borrowableCUSDC3), minBps: 0, maxBps: 10000 });
        optimizer.rebalance(actions, bounds);

        // Verify funds moved
        uint256 market3AssetsAfter = borrowableCUSDC3.convertToAssets(
            borrowableCUSDC3.balanceOf(address(optimizer))
        );
        assertLt(market3AssetsAfter, market3Assets, "Market 3 assets should decrease");
    }

    // ==================== FUZZ TESTS ====================

    function testFuzz_lendingOptimizer_badDebt_varyingCollateralCrash(
        uint256 depositAmount,
        int256 crashedPrice
    ) public {
        depositAmount = bound(depositAmount, 10_000e6, 500_000e6);
        crashedPrice = int256(bound(uint256(crashedPrice), 1, 0.5e8)); // $0.00000001 to $0.50

        // Deposit
        _prepareUSDC(depositor1, depositAmount);
        vm.startPrank(depositor1);
        usdc.approve(address(optimizer), depositAmount);
        optimizer.depositToMarket(depositAmount, depositor1, address(borrowableCUSDC));
        vm.stopPrank();

        // Calculate safe borrow amount (50% of deposit to stay under 70% LTV)
        uint256 borrowAmount = (depositAmount * 50) / 100;
        // Collateral needs to cover borrow at 70% LTV: collateral = borrow / 0.7
        // Scale from 6 decimals (USDC) to 18 decimals (DAI) and add safety margin
        uint256 collateralAmount = (borrowAmount * 1e12 * 150) / 100; // 150% of borrow in DAI

        // Setup config with high enough caps for fuzz values
        _setCTokenConfigBasic(address(borrowableCDAI), collateralAmount + 1e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, depositAmount + 1e6);

        _createBorrower(
            borrower1,
            marketManagerIsolated,
            ICToken(address(borrowableCDAI)),
            IBorrowableCToken(address(borrowableCUSDC)),
            collateralAmount,
            borrowAmount
        );

        uint256 rateBefore = optimizer.exchangeRateUpdated();

        // Crash price
        mockDaiFeed.setMockAnswer(crashedPrice);
        _refreshMockFeeds();
        skip(7 days);
        _refreshMockFeeds();

        // Liquidate
        address[] memory accounts = new address[](1);
        accounts[0] = borrower1;

        _prepareUSDC(user2, depositAmount);
        vm.startPrank(user2);
        usdc.approve(address(borrowableCUSDC), depositAmount);
        borrowableCUSDC.liquidate(accounts, address(borrowableCDAI));
        vm.stopPrank();

        uint256 rateAfter = optimizer.exchangeRateUpdated();

        // Rate should decrease (or stay same if no bad debt occurred)
        assertLe(rateAfter, rateBefore, "Rate should not increase after crash");

        // Optimizer should remain functional
        uint256 totalAssets = optimizer.totalAssets();
        uint256 totalSupply = optimizer.totalSupply();
        assertGt(totalAssets, 0, "Total assets should be positive");
        assertGt(totalSupply, 0, "Total supply should be positive");
    }
}
