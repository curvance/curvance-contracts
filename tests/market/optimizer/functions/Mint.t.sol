// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { LendingOptimizerHarness } from "../LendingOptimizerHarness.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { WAD, BPS } from "contracts/libraries/ConstantsLib.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

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

        optimizer = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000
        );

        // Create an uninitialized optimizer for testing revert cases
        uninitializedOptimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            "Flagship",
            "Flag",
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000
        );

        deal(USDC_MONAD, address(this), 77777, true);

        IERC20(USDC_MONAD).approve(address(optimizer), 77777);

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
        optimizer.initializeDeposits(cUSDC_WMON_MARKET);
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

        assertApproxEqAbs(assets, expectedAssets, 3, "Assets deposited should match preview");
        assertEq(optimizer.balanceOf(user1), sharesToMint, "User balance should equal requested shares");
        assertApproxEqAbs(optimizer.totalAssets(), totalAssetsBefore + assets, 2, "Total assets should approximately increase");

        vm.stopPrank();
    }

    function test_lendingOptimizer_mint_success_optimalMarketDifferentReceiver() public {
        vm.startPrank(user1);

        uint256 sharesToMint = 1000e6;
        uint256 expectedAssets = optimizer.previewMint(sharesToMint);

        deal(USDC_MONAD, user1, expectedAssets * 2, true);
        IERC20(USDC_MONAD).approve(address(optimizer), expectedAssets * 2);

        uint256 assets = optimizer.mint(sharesToMint, user2);

        assertEq(optimizer.balanceOf(user2), sharesToMint, "Receiver should get requested shares");
        assertEq(optimizer.balanceOf(user1), 0, "Minter should have no shares");

        vm.stopPrank();
    }

    function test_lendingOptimizer_mint_success_differentReceiverAfterAccrual() public {
        uint256 seedShares = 1000e6;
        uint256 seedAssets = optimizer.previewMint(seedShares);
        deal(USDC_MONAD, user2, seedAssets * 2, true);
        vm.startPrank(user2);
        IERC20(USDC_MONAD).approve(address(optimizer), seedAssets * 2);
        optimizer.mint(seedShares, user2);
        vm.stopPrank();

        skip(7 days);
        optimizer.accrueIfNeeded();

        uint256 sharesToMint = 1000e6;
        uint256 expectedAssets = optimizer.previewMint(sharesToMint);
        deal(USDC_MONAD, user1, expectedAssets * 2, true);
        vm.startPrank(user1);
        IERC20(USDC_MONAD).approve(address(optimizer), expectedAssets * 2);

        uint256 callerSharesBefore = optimizer.balanceOf(user1);
        uint256 receiverSharesBefore = optimizer.balanceOf(user2);
        uint256 totalSupplyBefore = optimizer.totalSupply();
        uint256 totalAssetsBefore = optimizer.totalAssets();

        uint256 assets = optimizer.mint(sharesToMint, user2);

        assertEq(optimizer.balanceOf(user1), callerSharesBefore, "Caller should not receive shares");
        assertEq(optimizer.balanceOf(user2), receiverSharesBefore + sharesToMint, "Receiver should receive requested shares");
        assertEq(optimizer.totalSupply(), totalSupplyBefore + sharesToMint, "Supply should increase by requested shares");
        assertApproxEqAbs(
            optimizer.totalAssets(),
            totalAssetsBefore + assets,
            2,
            "Assets should approximately increase by deposited amount"
        );

        vm.stopPrank();
    }

    function test_lendingOptimizer_mint_revertsAtomicallyWhenMarketDepositFails() public {
        uint256 sharesToMint = 1000e6;
        uint256 expectedAssets = optimizer.previewMint(sharesToMint);

        deal(USDC_MONAD, user1, expectedAssets * 2, true);
        vm.startPrank(user1);
        IERC20(USDC_MONAD).approve(address(optimizer), expectedAssets * 2);

        uint256 userAssetsBefore = IERC20(USDC_MONAD).balanceOf(user1);
        uint256 optimizerIdleAssetsBefore = IERC20(USDC_MONAD).balanceOf(address(optimizer));
        uint256 allowanceBefore = IERC20(USDC_MONAD).allowance(user1, address(optimizer));
        uint256 totalAssetsBefore = optimizer.totalAssets();
        uint256 totalSupplyBefore = optimizer.totalSupply();
        uint256 userSharesBefore = optimizer.balanceOf(user1);
        uint256 optimizerCTokensBefore = IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer));

        vm.mockCallRevert(
            cUSDC_WMON_MARKET,
            abi.encodeWithSelector(IBorrowableCToken.deposit.selector),
            "cToken deposit failed"
        );

        vm.expectRevert();
        optimizer.mint(sharesToMint, user1);

        assertEq(IERC20(USDC_MONAD).balanceOf(user1), userAssetsBefore, "user assets should roll back");
        assertEq(IERC20(USDC_MONAD).balanceOf(address(optimizer)), optimizerIdleAssetsBefore, "optimizer idle assets should roll back");
        assertEq(IERC20(USDC_MONAD).allowance(user1, address(optimizer)), allowanceBefore, "allowance should roll back");
        assertEq(optimizer.totalAssets(), totalAssetsBefore, "total assets should roll back");
        assertEq(optimizer.totalSupply(), totalSupplyBefore, "total supply should roll back");
        assertEq(optimizer.balanceOf(user1), userSharesBefore, "user shares should roll back");
        assertEq(
            IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer)),
            optimizerCTokensBefore,
            "optimizer cToken balance should roll back"
        );

        vm.stopPrank();
    }

    function test_lendingOptimizer_mint_reverts_zeroReceiver() public {
        vm.startPrank(user1);

        uint256 sharesToMint = 1000e6;
        uint256 expectedAssets = optimizer.previewMint(sharesToMint);

        deal(USDC_MONAD, user1, expectedAssets * 2, true);
        IERC20(USDC_MONAD).approve(address(optimizer), expectedAssets * 2);

        vm.expectRevert(LendingOptimizer.LendingOptimizer__InvalidParameter.selector);
        optimizer.mint(sharesToMint, address(0));

        vm.stopPrank();
    }

    function test_lendingOptimizer_mint_success_optimalMarketEmitsEvent() public {
        vm.startPrank(user1);

        uint256 sharesToMint = 1000e6;
        uint256 expectedAssets = optimizer.previewMint(sharesToMint);

        deal(USDC_MONAD, user1, expectedAssets * 2, true);
        IERC20(USDC_MONAD).approve(address(optimizer), expectedAssets * 2);

        // Assets can differ from preview by cToken roundtrip rounding.
        vm.expectEmit(true, true, false, false);
        emit Deposit(user1, user1, 0, 0);

        optimizer.mint(sharesToMint, user1);

        vm.stopPrank();
    }

    function test_lendingOptimizer_mint_success_optimalMarketSelectsCorrectly() public {
        vm.startPrank(user1);

        uint256 sharesToMint = 1000e6;
        uint256 expectedAssets = optimizer.previewMint(sharesToMint);

        deal(USDC_MONAD, user1, expectedAssets * 2, true);
        IERC20(USDC_MONAD).approve(address(optimizer), expectedAssets * 2);

        // Get the total cToken balance across all approved markets before mint.
        uint256 totalCTokensBefore;
        for (uint256 i = 0; i < optimizer.numApprovedMarkets(); i++) {
            totalCTokensBefore += IBorrowableCToken(optimizer.approvedCTokensList(i)).balanceOf(address(optimizer));
        }

        optimizer.mint(sharesToMint, user1);

        // Verify deposit went to some market (total cToken balance increased).
        uint256 totalCTokensAfter;
        for (uint256 i = 0; i < optimizer.numApprovedMarkets(); i++) {
            totalCTokensAfter += IBorrowableCToken(optimizer.approvedCTokensList(i)).balanceOf(address(optimizer));
        }
        assertGt(totalCTokensAfter, totalCTokensBefore, "Some market should receive deposit");

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
            assertEq(optimizer.balanceOf(user1), sharesBefore + sharesToMint, "Shares should accumulate exactly");
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
        assertEq(optimizer.balanceOf(user1), sharesToMint, "Should receive requested shares");

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

        assertApproxEqAbs(assets, expectedAssets, 3, "Large mint should deposit correct assets");
        assertEq(optimizer.balanceOf(user1), sharesToMint, "Should receive requested shares");

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

        assertEq(optimizer.balanceOf(user1), sharesToMint, "User1 should have requested shares");
        assertEq(optimizer.balanceOf(user2), sharesToMint, "User2 should have requested shares");
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

        assertEq(optimizer.balanceOf(user1), sharesToMint * 2, "Should have requested shares from both mints");

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

        assertApproxEqAbs(actualAssets, previewedAssets, 3, "Actual assets should match previewed assets");

        vm.stopPrank();
    }

    function test_lendingOptimizer_mint_success_exchangeRateConsistency() public {
        vm.startPrank(user1);

        uint256 sharesToMint = 1000e6;
        uint256 expectedAssets = optimizer.previewMint(sharesToMint);

        deal(USDC_MONAD, user1, expectedAssets * 2, true);
        IERC20(USDC_MONAD).approve(address(optimizer), expectedAssets * 2);

        // Call accrueIfNeeded first to capture post-accrual state.
        optimizer.accrueIfNeeded();

        uint256 totalAssetsBefore = optimizer.totalAssets();
        uint256 totalSupplyBefore = optimizer.totalSupply();

        uint256 assets = optimizer.mint(sharesToMint, user1);

        uint256 totalAssetsAfter = optimizer.totalAssets();
        uint256 totalSupplyAfter = optimizer.totalSupply();

        // Verify assets increased by deposited amount (allow 1-2 wei for cToken rounding).
        assertApproxEqAbs(totalAssetsAfter, totalAssetsBefore + assets, 2, "Assets should approximately increase by deposited amount");

        assertEq(totalSupplyAfter, totalSupplyBefore + sharesToMint, "Supply should increase by requested shares");

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

        // Mint should give exactly the requested shares.
        assertEq(sharesAfter - sharesBefore, sharesToMint, "Must mint exact shares requested");

        vm.stopPrank();
    }

    function test_lendingOptimizer_mint_invariant_recoverableAssetsCoverShares() public {
        vm.startPrank(user1);

        uint256 sharesToMint = 1000e6;

        optimizer.accrueIfNeeded();
        uint256 totalAssetsBefore = optimizer.totalAssets();
        uint256 totalSupplyBefore = optimizer.totalSupply();

        uint256 expectedAssets = optimizer.previewMint(sharesToMint);
        deal(USDC_MONAD, user1, expectedAssets * 2, true);
        IERC20(USDC_MONAD).approve(address(optimizer), expectedAssets * 2);

        optimizer.mint(sharesToMint, user1);

        uint256 trackedAssets = optimizer.totalAssets() - totalAssetsBefore;
        uint256 backedShares =
            (trackedAssets * totalSupplyBefore) / totalAssetsBefore;

        assertGe(
            backedShares,
            sharesToMint,
            "Recoverable assets should cover minted shares"
        );

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

    function testFuzz_lendingOptimizer_mint_optimalMarket(uint256 sharesToMint) public {
        // Bound to reasonable amounts (1 share to 10M shares)
        sharesToMint = bound(sharesToMint, 1e6, 10_000_000e6);

        vm.startPrank(user1);

        uint256 expectedAssets = optimizer.previewMint(sharesToMint);
        deal(USDC_MONAD, user1, expectedAssets * 2, true);
        IERC20(USDC_MONAD).approve(address(optimizer), expectedAssets * 2);

        uint256 assets = optimizer.mint(sharesToMint, user1);

        assertApproxEqAbs(assets, expectedAssets, 3, "Assets should match preview");
        assertEq(optimizer.balanceOf(user1), sharesToMint, "Balance should equal requested shares");

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

        assertEq(sharesAfter - sharesBefore, sharesToMint, "Should mint requested shares");

        vm.stopPrank();
    }

    function testFuzz_lendingOptimizer_mint_neverOvercreditsTrackedAssets(uint256 sharesToMint) public {
        sharesToMint = bound(sharesToMint, 1e6, 10_000_000e6);

        uint256 expectedAssets = optimizer.previewMint(sharesToMint);
        deal(USDC_MONAD, user1, expectedAssets * 2, true);
        vm.startPrank(user1);
        IERC20(USDC_MONAD).approve(address(optimizer), expectedAssets * 2);

        uint256 totalAssetsBefore = optimizer.totalAssets();
        uint256 assets = optimizer.mint(sharesToMint, user1);
        uint256 trackedIncrease = optimizer.totalAssets() - totalAssetsBefore;

        assertLe(trackedIncrease, assets, "mint must not overcredit tracked assets");

        vm.stopPrank();
    }
}
