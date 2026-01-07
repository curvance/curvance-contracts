// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { WAD, BPS } from "contracts/libraries/ConstantsLib.sol";

contract TestLendingOptimizerMint is TestBaseLendingOptimizer {

    LendingOptimizer uninitializedOptimizer;

    event Deposit(address indexed by, address indexed owner, uint256 assets, uint256 shares);

    function setUp() public override {
        super.setUp();

        address[] memory approvedCTokens = new address[](3);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WETH_MARKET;
        approvedCTokens[2] = cUSDC_WBTC_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](3);
        allocationCapsBps[0] = 5_000;
        allocationCapsBps[1] = 4_000;
        allocationCapsBps[2] = 1_000;

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000,
            1 days
        );

        // Create an uninitialized optimizer for testing revert cases
        uninitializedOptimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000,
            1 days
        );

        deal(USDC_MONAD, address(this), 77777, true);

        IERC20(USDC_MONAD).approve(address(optimizer), 77777);

        optimizer.initializeDeposits(0);
    }

    // ============ mint(shares, receiver, targetMarket) Tests ============

    function test_lendingOptimizer_mint_success_targetMarket() public {
        vm.startPrank(user1);

        uint256 sharesToMint = 1000e6;
        uint256 expectedAssets = optimizer.previewMint(sharesToMint);
        
        // Give user enough assets to cover the mint
        deal(USDC_MONAD, user1, expectedAssets * 2, true);
        IERC20(USDC_MONAD).approve(address(optimizer), expectedAssets * 2);

        uint256 totalAssetsBefore = optimizer.totalAssets();
        uint256 user1SharesBefore = optimizer.balanceOf(user1);

        uint256 assets = optimizer.mint(sharesToMint, user1, cUSDC_WMON_MARKET);

        assertEq(assets, expectedAssets, "Assets deposited should match preview");
        assertEq(optimizer.balanceOf(user1), user1SharesBefore + sharesToMint, "User balance should increase by exact shares");
        assertEq(optimizer.totalAssets(), totalAssetsBefore + assets, "Total assets should increase");

        vm.stopPrank();
    }

    function test_lendingOptimizer_mint_success_targetMarketDifferentReceiver() public {
        vm.startPrank(user1);

        uint256 sharesToMint = 1000e6;
        uint256 expectedAssets = optimizer.previewMint(sharesToMint);
        
        deal(USDC_MONAD, user1, expectedAssets * 2, true);
        IERC20(USDC_MONAD).approve(address(optimizer), expectedAssets * 2);

        // Mint for user2 as receiver
        uint256 assets = optimizer.mint(sharesToMint, user2, cUSDC_WMON_MARKET);

        assertEq(assets, expectedAssets, "Assets deposited should match preview");
        assertEq(optimizer.balanceOf(user2), sharesToMint, "Receiver should get exact shares");
        assertEq(optimizer.balanceOf(user1), 0, "Minter should have no shares");

        vm.stopPrank();
    }

    function test_lendingOptimizer_mint_success_targetMarketAllMarkets() public {
        uint256 sharesToMint = 1000e6;

        // Test mint to each approved market
        address[3] memory markets = [cUSDC_WMON_MARKET, cUSDC_WETH_MARKET, cUSDC_WBTC_MARKET];

        for (uint256 i = 0; i < markets.length; i++) {
            uint256 expectedAssets = optimizer.previewMint(sharesToMint);
            deal(USDC_MONAD, user1, expectedAssets * 2, true);

            vm.startPrank(user1);
            IERC20(USDC_MONAD).approve(address(optimizer), expectedAssets * 2);

            uint256 sharesBefore = optimizer.balanceOf(user1);
            uint256 assets = optimizer.mint(sharesToMint, user1, markets[i]);

            assertGt(assets, 0, "Should deposit assets");
            assertEq(optimizer.balanceOf(user1), sharesBefore + sharesToMint, "Exact shares should be credited");
            vm.stopPrank();
        }
    }

    function test_lendingOptimizer_mint_success_targetMarketEmitsEvent() public {
        vm.startPrank(user1);

        uint256 sharesToMint = 1000e6;
        uint256 expectedAssets = optimizer.previewMint(sharesToMint);
        
        deal(USDC_MONAD, user1, expectedAssets * 2, true);
        IERC20(USDC_MONAD).approve(address(optimizer), expectedAssets * 2);

        vm.expectEmit(true, true, false, true);
        emit Deposit(user1, user1, expectedAssets, sharesToMint);

        optimizer.mint(sharesToMint, user1, cUSDC_WMON_MARKET);

        vm.stopPrank();
    }

    function test_lendingOptimizer_mint_revert_targetMarketNotApproved() public {
        vm.startPrank(user1);

        uint256 sharesToMint = 1000e6;
        uint256 expectedAssets = optimizer.previewMint(sharesToMint);
        
        deal(USDC_MONAD, user1, expectedAssets * 2, true);
        IERC20(USDC_MONAD).approve(address(optimizer), expectedAssets * 2);

        // Use a random address that's not an approved market
        address fakeMarket = makeAddr("fakeMarket");

        vm.expectRevert(LendingOptimizer.LendingOptimizer__MarketNotApproved.selector);
        optimizer.mint(sharesToMint, user1, fakeMarket);

        vm.stopPrank();
    }

    function test_lendingOptimizer_mint_revert_targetMarketNotInitialized() public {
        vm.startPrank(user1);

        uint256 sharesToMint = 1000e6;
        
        deal(USDC_MONAD, user1, 10000e6, true);
        IERC20(USDC_MONAD).approve(address(uninitializedOptimizer), 10000e6);

        vm.expectRevert(LendingOptimizer.LendingOptimizer__NotInitialized.selector);
        uninitializedOptimizer.mint(sharesToMint, user1, cUSDC_WMON_MARKET);

        vm.stopPrank();
    }

    function test_lendingOptimizer_mint_success_targetMarketMultipleMints() public {
        vm.startPrank(user1);

        uint256 sharesToMint = 1000e6;
        uint256 numMints = 5;
        uint256 totalShares;

        for (uint256 i = 0; i < numMints; i++) {
            uint256 expectedAssets = optimizer.previewMint(sharesToMint);
            deal(USDC_MONAD, user1, expectedAssets * 2, true);
            IERC20(USDC_MONAD).approve(address(optimizer), expectedAssets * 2);

            optimizer.mint(sharesToMint, user1, cUSDC_WMON_MARKET);
            totalShares += sharesToMint;
        }

        // User should have exact shares from all mints
        assertEq(optimizer.balanceOf(user1), totalShares, "User should have exact total shares");

        vm.stopPrank();
    }

    // ============ mint(shares, receiver) - ERC4626 Standard Tests ============

    function test_lendingOptimizer_mint_success_optimalMarket() public {
        vm.startPrank(user1);

        uint256 sharesToMint = 1000e6;
        uint256 expectedAssets = optimizer.previewMint(sharesToMint);
        
        deal(USDC_MONAD, user1, expectedAssets * 2, true);
        IERC20(USDC_MONAD).approve(address(optimizer), expectedAssets * 2);

        uint256 totalAssetsBefore = optimizer.totalAssets();

        uint256 assets = optimizer.mint(sharesToMint, user1);

        assertEq(assets, expectedAssets, "Assets deposited should match preview");
        assertEq(optimizer.balanceOf(user1), sharesToMint, "User balance should equal exact shares");
        assertEq(optimizer.totalAssets(), totalAssetsBefore + assets, "Total assets should increase");

        vm.stopPrank();
    }

    function test_lendingOptimizer_mint_success_optimalMarketDifferentReceiver() public {
        vm.startPrank(user1);

        uint256 sharesToMint = 1000e6;
        uint256 expectedAssets = optimizer.previewMint(sharesToMint);
        
        deal(USDC_MONAD, user1, expectedAssets * 2, true);
        IERC20(USDC_MONAD).approve(address(optimizer), expectedAssets * 2);

        uint256 assets = optimizer.mint(sharesToMint, user2);

        assertEq(optimizer.balanceOf(user2), sharesToMint, "Receiver should get exact shares");
        assertEq(optimizer.balanceOf(user1), 0, "Minter should have no shares");

        vm.stopPrank();
    }

    function test_lendingOptimizer_mint_success_optimalMarketEmitsEvent() public {
        vm.startPrank(user1);

        uint256 sharesToMint = 1000e6;
        uint256 expectedAssets = optimizer.previewMint(sharesToMint);
        
        deal(USDC_MONAD, user1, expectedAssets * 2, true);
        IERC20(USDC_MONAD).approve(address(optimizer), expectedAssets * 2);

        vm.expectEmit(true, true, false, true);
        emit Deposit(user1, user1, expectedAssets, sharesToMint);

        optimizer.mint(sharesToMint, user1);

        vm.stopPrank();
    }

    function test_lendingOptimizer_mint_success_optimalMarketSelectsCorrectly() public {
        vm.startPrank(user1);

        uint256 sharesToMint = 1000e6;
        uint256 expectedAssets = optimizer.previewMint(sharesToMint);
        
        deal(USDC_MONAD, user1, expectedAssets * 2, true);
        IERC20(USDC_MONAD).approve(address(optimizer), expectedAssets * 2);

        // Get the expected optimal target before mint
        uint256 expectedTarget = optimizer.optimalDepositTarget(expectedAssets);
        address expectedMarket = optimizer.approvedCTokensList(expectedTarget);

        // Get market balance before
        uint256 marketBalanceBefore = IBorrowableCToken(expectedMarket).balanceOf(address(optimizer));

        optimizer.mint(sharesToMint, user1);

        // Verify deposit went to the expected market
        uint256 marketBalanceAfter = IBorrowableCToken(expectedMarket).balanceOf(address(optimizer));
        assertGt(marketBalanceAfter, marketBalanceBefore, "Expected market should receive deposit");

        vm.stopPrank();
    }

    function test_lendingOptimizer_mint_success_optimalMarketMultipleMints() public {
        uint256 sharesToMint = 50_000e6;
        uint256 numMints = 5;

        for (uint256 i = 0; i < numMints; i++) {
            uint256 expectedAssets = optimizer.previewMint(sharesToMint);
            deal(USDC_MONAD, user1, expectedAssets * 2, true);

            vm.startPrank(user1);
            IERC20(USDC_MONAD).approve(address(optimizer), expectedAssets * 2);

            uint256 sharesBefore = optimizer.balanceOf(user1);
            uint256 assets = optimizer.mint(sharesToMint, user1);

            assertGt(assets, 0, "Should deposit assets");
            assertEq(optimizer.balanceOf(user1), sharesBefore + sharesToMint, "Exact shares should accumulate");
            vm.stopPrank();
        }
    }

    function test_lendingOptimizer_mint_success_smallAmount() public {
        vm.startPrank(user1);

        // Mint 1 share (smallest meaningful amount)
        uint256 sharesToMint = 1e6;
        uint256 expectedAssets = optimizer.previewMint(sharesToMint);
        
        deal(USDC_MONAD, user1, expectedAssets * 2, true);
        IERC20(USDC_MONAD).approve(address(optimizer), expectedAssets * 2);

        uint256 assets = optimizer.mint(sharesToMint, user1);

        assertGt(assets, 0, "Should deposit assets even for small mint");
        assertEq(optimizer.balanceOf(user1), sharesToMint, "Should receive exact shares");

        vm.stopPrank();
    }

    function test_lendingOptimizer_mint_success_largeAmount() public {
        vm.startPrank(user1);

        // Mint 1M shares
        uint256 sharesToMint = 1_000_000e6;
        uint256 expectedAssets = optimizer.previewMint(sharesToMint);
        
        deal(USDC_MONAD, user1, expectedAssets * 2, true);
        IERC20(USDC_MONAD).approve(address(optimizer), expectedAssets * 2);

        uint256 assets = optimizer.mint(sharesToMint, user1);

        assertEq(assets, expectedAssets, "Large mint should deposit correct assets");
        assertEq(optimizer.balanceOf(user1), sharesToMint, "Should receive exact shares");

        vm.stopPrank();
    }

    function test_lendingOptimizer_mint_success_multipleUsersMint() public {
        uint256 sharesToMint = 1000e6;

        // User1 mints
        uint256 expectedAssets1 = optimizer.previewMint(sharesToMint);
        deal(USDC_MONAD, user1, expectedAssets1 * 2, true);
        vm.startPrank(user1);
        IERC20(USDC_MONAD).approve(address(optimizer), expectedAssets1 * 2);
        optimizer.mint(sharesToMint, user1);
        vm.stopPrank();

        // User2 mints
        uint256 expectedAssets2 = optimizer.previewMint(sharesToMint);
        deal(USDC_MONAD, user2, expectedAssets2 * 2, true);
        vm.startPrank(user2);
        IERC20(USDC_MONAD).approve(address(optimizer), expectedAssets2 * 2);
        optimizer.mint(sharesToMint, user2);
        vm.stopPrank();

        assertEq(optimizer.balanceOf(user1), sharesToMint, "User1 should have exact shares");
        assertEq(optimizer.balanceOf(user2), sharesToMint, "User2 should have exact shares");
    }

    function test_lendingOptimizer_mint_success_afterTimePasses() public {
        vm.startPrank(user1);

        uint256 sharesToMint = 1000e6;
        
        // First mint
        uint256 expectedAssets1 = optimizer.previewMint(sharesToMint);
        deal(USDC_MONAD, user1, expectedAssets1 * 2, true);
        IERC20(USDC_MONAD).approve(address(optimizer), expectedAssets1 * 2);
        uint256 assets1 = optimizer.mint(sharesToMint, user1);

        // Skip time (interest accrues)
        skip(7 days);
        
        // Trigger yield detection and start vesting
        optimizer.accrueIfNeeded();
        
        // Skip vesting period to let yield vest
        skip(1 days);

        // Second mint - now exchange rate should have changed
        uint256 expectedAssets2 = optimizer.previewMint(sharesToMint);
        deal(USDC_MONAD, user1, expectedAssets2 * 2, true);
        IERC20(USDC_MONAD).approve(address(optimizer), expectedAssets2 * 2);
        uint256 assets2 = optimizer.mint(sharesToMint, user1);

        // Both mints should mint exact shares requested
        assertEq(optimizer.balanceOf(user1), sharesToMint * 2, "Should have exact shares from both mints");
        
        // Second mint should require MORE assets (exchange rate increased)
        assertGt(assets2, assets1, "Should require same or more assets after yield vests");

        vm.stopPrank();
    }

    function test_lendingOptimizer_mint_success_previewMatchesActual() public {
        vm.startPrank(user1);

        uint256 sharesToMint = 1000e6;
        uint256 previewedAssets = optimizer.previewMint(sharesToMint);
        
        deal(USDC_MONAD, user1, previewedAssets * 2, true);
        IERC20(USDC_MONAD).approve(address(optimizer), previewedAssets * 2);

        uint256 actualAssets = optimizer.mint(sharesToMint, user1);

        assertEq(actualAssets, previewedAssets, "Actual assets should match previewed assets");

        vm.stopPrank();
    }

    function test_lendingOptimizer_mint_success_exchangeRateConsistency() public {
        vm.startPrank(user1);

        uint256 sharesToMint = 1000e6;
        uint256 expectedAssets = optimizer.previewMint(sharesToMint);
        
        deal(USDC_MONAD, user1, expectedAssets * 2, true);
        IERC20(USDC_MONAD).approve(address(optimizer), expectedAssets * 2);

        uint256 totalAssetsBefore = optimizer.totalAssets();
        uint256 totalSupplyBefore = optimizer.totalSupply();

        uint256 assets = optimizer.mint(sharesToMint, user1);

        uint256 totalAssetsAfter = optimizer.totalAssets();
        uint256 totalSupplyAfter = optimizer.totalSupply();

        // Verify assets increased by deposited amount
        assertEq(totalAssetsAfter, totalAssetsBefore + assets, "Assets should increase by deposited amount");

        // Verify supply increased by exact shares minted
        assertEq(totalSupplyAfter, totalSupplyBefore + sharesToMint, "Supply should increase by exact shares");

        vm.stopPrank();
    }

    // ============ Mint vs Deposit Equivalence Tests ============

    function test_lendingOptimizer_mint_depositEquivalence() public {
        // Mint and deposit should be inverse operations
        uint256 sharesToMint = 1000e6;
        
        // Get expected assets for minting shares
        uint256 assetsForMint = optimizer.previewMint(sharesToMint);
        
        // Get expected shares for depositing those assets
        uint256 sharesForDeposit = optimizer.previewDeposit(assetsForMint);
        
        // They should be equivalent (within rounding)
        uint256 diff = sharesToMint > sharesForDeposit 
            ? sharesToMint - sharesForDeposit 
            : sharesForDeposit - sharesToMint;
        
        assertLe(diff, 1, "Mint and deposit should be inverse operations");
    }

    // ============ Invariant Tests ============

    function test_lendingOptimizer_mint_invariant_exactSharesMinted() public {
        vm.startPrank(user1);

        uint256 sharesToMint = 1000e6;
        uint256 expectedAssets = optimizer.previewMint(sharesToMint);
        
        deal(USDC_MONAD, user1, expectedAssets * 2, true);
        IERC20(USDC_MONAD).approve(address(optimizer), expectedAssets * 2);

        uint256 sharesBefore = optimizer.balanceOf(user1);
        optimizer.mint(sharesToMint, user1);
        uint256 sharesAfter = optimizer.balanceOf(user1);

        // Mint should always give exact shares requested
        assertEq(sharesAfter - sharesBefore, sharesToMint, "Must mint exact shares requested");

        vm.stopPrank();
    }

    function test_lendingOptimizer_mint_invariant_assetsMatchFormula() public {
        vm.startPrank(user1);

        uint256 sharesToMint = 1000e6;
        
        // Accrue first to get post-accrual state
        optimizer.accrueIfNeeded();
        uint256 totalAssetsBefore = optimizer.totalAssets();
        uint256 totalSupplyBefore = optimizer.totalSupply();

        uint256 expectedAssets = optimizer.previewMint(sharesToMint);
        deal(USDC_MONAD, user1, expectedAssets * 2, true);
        IERC20(USDC_MONAD).approve(address(optimizer), expectedAssets * 2);

        uint256 actualAssets = optimizer.mint(sharesToMint, user1);

        // Verify the ERC4626 formula: assets = shares * totalAssets / totalSupply (round up)
        // For mint, we round UP on assets to protect the vault
        uint256 calculatedAssets = (sharesToMint * totalAssetsBefore + totalSupplyBefore - 1) / totalSupplyBefore;
        
        // Allow for small rounding difference
        uint256 diff = actualAssets > calculatedAssets 
            ? actualAssets - calculatedAssets 
            : calculatedAssets - actualAssets;
        
        assertLe(diff, 1, "Assets should match formula calculation");

        vm.stopPrank();
    }

    function test_lendingOptimizer_mint_invariant_exchangeRateNeverDecreases() public {
        uint256 sharesToMint = 1000e6;

        // Track exchange rate across multiple mints
        uint256 previousExchangeRate = optimizer.exchangeRate();

        for (uint256 i = 0; i < 5; i++) {
            address minter = i % 2 == 0 ? user1 : user2;
            
            uint256 expectedAssets = optimizer.previewMint(sharesToMint);
            deal(USDC_MONAD, minter, expectedAssets * 2, true);
            vm.startPrank(minter);
            IERC20(USDC_MONAD).approve(address(optimizer), expectedAssets * 2);
            optimizer.mint(sharesToMint, minter);
            vm.stopPrank();

            // Skip time and accrue to simulate yield
            skip(1 days);
            optimizer.accrueIfNeeded();
            skip(1 days); // Let yield vest

            uint256 currentExchangeRate = optimizer.exchangeRate();
            
            // Exchange rate should never decrease (assuming no losses)
            assertGe(currentExchangeRate, previousExchangeRate, "Exchange rate should never decrease");
            
            previousExchangeRate = currentExchangeRate;
        }
    }

    // ============ Fuzz Tests ============

    function testFuzz_lendingOptimizer_mint_targetMarket(uint256 sharesToMint) public {
        // Bound to reasonable amounts (1 share to 10M shares)
        sharesToMint = bound(sharesToMint, 1e6, 10_000_000e6);

        vm.startPrank(user1);

        uint256 expectedAssets = optimizer.previewMint(sharesToMint);
        deal(USDC_MONAD, user1, expectedAssets * 2, true);
        IERC20(USDC_MONAD).approve(address(optimizer), expectedAssets * 2);

        uint256 assets = optimizer.mint(sharesToMint, user1, cUSDC_WMON_MARKET);

        assertEq(assets, expectedAssets, "Assets should match preview");
        assertEq(optimizer.balanceOf(user1), sharesToMint, "Balance should equal exact shares");

        vm.stopPrank();
    }

    function testFuzz_lendingOptimizer_mint_optimalMarket(uint256 sharesToMint) public {
        // Bound to reasonable amounts (1 share to 10M shares)
        sharesToMint = bound(sharesToMint, 1e6, 10_000_000e6);

        vm.startPrank(user1);

        uint256 expectedAssets = optimizer.previewMint(sharesToMint);
        deal(USDC_MONAD, user1, expectedAssets * 2, true);
        IERC20(USDC_MONAD).approve(address(optimizer), expectedAssets * 2);

        uint256 assets = optimizer.mint(sharesToMint, user1);

        assertEq(assets, expectedAssets, "Assets should match preview");
        assertEq(optimizer.balanceOf(user1), sharesToMint, "Balance should equal exact shares");

        vm.stopPrank();
    }

    function testFuzz_lendingOptimizer_mint_invariant_exactShares(uint256 sharesToMint) public {
        // Bound to reasonable amounts
        sharesToMint = bound(sharesToMint, 1e6, 10_000_000e6);

        vm.startPrank(user1);

        uint256 expectedAssets = optimizer.previewMint(sharesToMint);
        deal(USDC_MONAD, user1, expectedAssets * 2, true);
        IERC20(USDC_MONAD).approve(address(optimizer), expectedAssets * 2);

        uint256 sharesBefore = optimizer.balanceOf(user1);
        optimizer.mint(sharesToMint, user1);
        uint256 sharesAfter = optimizer.balanceOf(user1);

        // Core invariant: mint always gives exact shares requested
        assertEq(sharesAfter - sharesBefore, sharesToMint, "Must always mint exact shares");

        vm.stopPrank();
    }
}
