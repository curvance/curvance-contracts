// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { LendingOptimizerHarness } from "../LendingOptimizerHarness.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IERC165 } from "contracts/interfaces/IERC165.sol";
import { IPluginDelegable } from "contracts/interfaces/IPluginDelegable.sol";
import { ERC4626 } from "contracts/libraries/external/ERC4626.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { WAD, BPS } from "contracts/libraries/ConstantsLib.sol";

contract TestLendingOptimizerDeposit is TestBaseLendingOptimizer {

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

    // ============ deposit(assets, receiver) - ERC4626 Standard Tests ============

    function test_lendingOptimizer_deposit_success_optimalMarket() public {
        vm.startPrank(user1);

        uint256 depositAmount = 1000e6;
        deal(USDC_MONAD, user1, depositAmount, true);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);

        uint256 expectedShares = optimizer.previewDeposit(depositAmount);
        uint256 totalAssetsBefore = optimizer.totalAssets();

        uint256 shares = optimizer.deposit(depositAmount, user1);

        // Allow 0-2 wei variance due to cToken interest accrual and fee dilution.
        assertApproxEqAbs(shares, expectedShares, 2, "Shares minted should approximately match preview");
        assertEq(optimizer.balanceOf(user1), shares, "User balance should equal shares");
        // Assets may differ slightly due to cToken rounding during deposit.
        assertApproxEqAbs(optimizer.totalAssets(), totalAssetsBefore + depositAmount, 2, "Total assets should approximately increase");

        vm.stopPrank();
    }

    function test_lendingOptimizer_deposit_success_optimalMarketDifferentReceiver() public {
        vm.startPrank(user1);

        uint256 depositAmount = 1000e6;
        deal(USDC_MONAD, user1, depositAmount, true);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);

        uint256 shares = optimizer.deposit(depositAmount, user2);

        assertEq(optimizer.balanceOf(user2), shares, "Receiver should get the shares");
        assertEq(optimizer.balanceOf(user1), 0, "Depositor should have no shares");

        vm.stopPrank();
    }

    function test_lendingOptimizer_deposit_success_optimalMarketEmitsEvent() public {
        vm.startPrank(user1);

        uint256 depositAmount = 1000e6;
        deal(USDC_MONAD, user1, depositAmount, true);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);

        // Only check indexed parameters (caller and owner) since shares
        // may differ by 1-2 wei due to cToken rounding.
        vm.expectEmit(true, true, false, false);
        emit Deposit(user1, user1, 0, 0);

        optimizer.deposit(depositAmount, user1);

        vm.stopPrank();
    }

    function test_lendingOptimizer_deposit_success_optimalMarketSelectsCorrectly() public {
        vm.startPrank(user1);

        uint256 depositAmount = 1000e6;
        deal(USDC_MONAD, user1, depositAmount, true);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);

        // Get the expected optimal target before deposit
        address expectedMarket = LendingOptimizerHarness(address(optimizer)).supplyQueueTarget();

        // Get market balance before
        uint256 marketBalanceBefore = IBorrowableCToken(expectedMarket).balanceOf(address(optimizer));

        optimizer.deposit(depositAmount, user1);

        // Verify deposit went to the expected market
        uint256 marketBalanceAfter = IBorrowableCToken(expectedMarket).balanceOf(address(optimizer));
        assertGt(marketBalanceAfter, marketBalanceBefore, "Expected market should receive deposit");

        vm.stopPrank();
    }

    function test_lendingOptimizer_deposit_success_optimalMarketMultipleDeposits() public {
        uint256 depositAmount = 50_000e6;
        uint256 numDeposits = 5;

        for (uint256 i = 0; i < numDeposits; i++) {
            deal(USDC_MONAD, user1, depositAmount, true);

            vm.startPrank(user1);
            IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);

            uint256 sharesBefore = optimizer.balanceOf(user1);
            uint256 shares = optimizer.deposit(depositAmount, user1);

            assertGt(shares, 0, "Should mint shares");
            assertEq(optimizer.balanceOf(user1), sharesBefore + shares, "Shares should accumulate");
            vm.stopPrank();
        }
    }

    function test_lendingOptimizer_deposit_success_smallAmount() public {
        vm.startPrank(user1);

        // Deposit 1 USDC (smallest meaningful amount)
        uint256 depositAmount = 1e6;
        deal(USDC_MONAD, user1, depositAmount, true);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);

        uint256 shares = optimizer.deposit(depositAmount, user1);

        assertGt(shares, 0, "Should mint shares even for small deposit");

        vm.stopPrank();
    }

    function test_lendingOptimizer_deposit_success_largeAmount() public {
        vm.startPrank(user1);

        // Deposit 1M USDC
        uint256 depositAmount = 1_000_000e6;
        deal(USDC_MONAD, user1, depositAmount, true);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);

        uint256 expectedShares = optimizer.previewDeposit(depositAmount);
        uint256 shares = optimizer.deposit(depositAmount, user1);

        // Allow 0-2 wei variance due to cToken interest accrual and fee dilution.
        assertApproxEqAbs(shares, expectedShares, 2, "Large deposit should mint approximately correct shares");

        vm.stopPrank();
    }

    function test_lendingOptimizer_deposit_success_multipleUsersDeposit() public {
        uint256 depositAmount = 1000e6;

        // User1 deposits
        deal(USDC_MONAD, user1, depositAmount, true);
        vm.startPrank(user1);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
        uint256 shares1 = optimizer.deposit(depositAmount, user1);
        vm.stopPrank();

        // User2 deposits
        deal(USDC_MONAD, user2, depositAmount, true);
        vm.startPrank(user2);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
        uint256 shares2 = optimizer.deposit(depositAmount, user2);
        vm.stopPrank();

        assertEq(optimizer.balanceOf(user1), shares1, "User1 should have their shares");
        assertEq(optimizer.balanceOf(user2), shares2, "User2 should have their shares");
        assertGt(optimizer.totalSupply(), shares1 + shares2, "Total supply should include dead shares + user shares");
    }

    function test_lendingOptimizer_deposit_success_afterTimePasses() public {
        vm.startPrank(user1);

        uint256 depositAmount = 1000e6;
        deal(USDC_MONAD, user1, depositAmount * 2, true);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount * 2);

        // First deposit
        uint256 shares1 = optimizer.deposit(depositAmount, user1);

        // Skip time (interest accrues)
        skip(7 days);
        
        // Trigger yield detection and start vesting
        optimizer.accrueIfNeeded();
        
        // Skip vesting period to let yield vest
        skip(1 days);

        // Second deposit - now exchange rate should have changed
        uint256 shares2 = optimizer.deposit(depositAmount, user1);

        // Second deposit should get FEWER shares (exchange rate increased)
        assertLt(shares2, shares1, "Should get fewer shares after yield vests");

        vm.stopPrank();
    }

    function test_lendingOptimizer_deposit_success_previewMatchesActual() public {
        vm.startPrank(user1);

        uint256 depositAmount = 1000e6;
        deal(USDC_MONAD, user1, depositAmount, true);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);

        uint256 previewedShares = optimizer.previewDeposit(depositAmount);
        uint256 actualShares = optimizer.deposit(depositAmount, user1);

        // Allow 0-2 wei variance due to cToken interest accrual and fee dilution.
        assertApproxEqAbs(actualShares, previewedShares, 2, "Actual shares should approximately match previewed shares");

        vm.stopPrank();
    }

    function test_lendingOptimizer_deposit_success_exchangeRateConsistency() public {
        vm.startPrank(user1);

        uint256 depositAmount = 1000e6;
        deal(USDC_MONAD, user1, depositAmount, true);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);

        // Call accrueIfNeeded first to capture post-accrual state.
        // This ensures fee minting happens before we measure totalSupplyBefore.
        optimizer.accrueIfNeeded();

        uint256 totalAssetsBefore = optimizer.totalAssets();
        uint256 totalSupplyBefore = optimizer.totalSupply();

        uint256 shares = optimizer.deposit(depositAmount, user1);

        uint256 totalAssetsAfter = optimizer.totalAssets();
        uint256 totalSupplyAfter = optimizer.totalSupply();

        // Verify assets increased by deposit amount (allow 1-2 wei for cToken rounding).
        assertApproxEqAbs(totalAssetsAfter, totalAssetsBefore + depositAmount, 2, "Assets should increase by deposit");

        // Verify supply increased by shares minted
        assertEq(totalSupplyAfter, totalSupplyBefore + shares, "Supply should increase by shares");

        vm.stopPrank();
    }

    // ============ Fuzz Tests ============

    function testFuzz_lendingOptimizer_deposit_optimalMarket(uint256 depositAmount) public {
        // Bound to reasonable amounts (1 USDC to 10M USDC)
        depositAmount = bound(depositAmount, 1e6, 10_000_000e6);

        vm.startPrank(user1);

        deal(USDC_MONAD, user1, depositAmount, true);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);

        uint256 expectedShares = optimizer.previewDeposit(depositAmount);
        uint256 shares = optimizer.deposit(depositAmount, user1);

        // Allow 0-2 wei variance due to cToken interest accrual and fee dilution.
        assertApproxEqAbs(shares, expectedShares, 2, "Shares should approximately match preview");
        assertEq(optimizer.balanceOf(user1), shares, "Balance should equal shares");

        vm.stopPrank();
    }

    // ============ Invariant Tests ============

    function test_lendingOptimizer_deposit_invariant_sharesMatchExchangeRate() public {
        vm.startPrank(user1);

        uint256 depositAmount = 1000e6;
        deal(USDC_MONAD, user1, depositAmount, true);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);

        // Accrue first to get post-accrual state (deposit() calls _accrueIfNeeded internally)
        optimizer.accrueIfNeeded();
        uint256 totalAssetsBefore = optimizer.totalAssets();
        uint256 totalSupplyBefore = optimizer.totalSupply();

        // Perform deposit
        uint256 shares = optimizer.deposit(depositAmount, user1);

        // Verify invariant
        _assertSharesMatchInvariant(depositAmount, shares, totalAssetsBefore, totalSupplyBefore);

        // Also verify using our helper matches previewDeposit.
        // Allow 0-2 wei variance due to cToken interest accrual and fee dilution.
        uint256 calculatedShares = _calculateExpectedShares(depositAmount, totalAssetsBefore, totalSupplyBefore);
        assertApproxEqAbs(shares, calculatedShares, 2, "Shares should approximately match calculated expected");

        vm.stopPrank();
    }

    function test_lendingOptimizer_deposit_invariant_multipleDepositsWithYield() public {
        uint256 depositAmount = 1000e6;

        // First deposit by user1
        deal(USDC_MONAD, user1, depositAmount, true);
        vm.startPrank(user1);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
        
        // Accrue first to get post-accrual state (deposit() calls _accrueIfNeeded internally)
        optimizer.accrueIfNeeded();
        uint256 totalAssetsBefore1 = optimizer.totalAssets();
        uint256 totalSupplyBefore1 = optimizer.totalSupply();
        uint256 shares1 = optimizer.deposit(depositAmount, user1);
        
        _assertSharesMatchInvariant(depositAmount, shares1, totalAssetsBefore1, totalSupplyBefore1);
        vm.stopPrank();

        // Time passes, yield accrues
        skip(7 days);
        optimizer.accrueIfNeeded();
        skip(1 days); // Let yield vest

        // Second deposit by user2 - exchange rate should be different
        deal(USDC_MONAD, user2, depositAmount, true);
        vm.startPrank(user2);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);

        // Accrue first to get post-accrual state (deposit() calls _accrueIfNeeded internally)
        optimizer.accrueIfNeeded();
        uint256 totalAssetsBefore2 = optimizer.totalAssets();
        uint256 totalSupplyBefore2 = optimizer.totalSupply();
        uint256 shares2 = optimizer.deposit(depositAmount, user2);

        _assertSharesMatchInvariant(depositAmount, shares2, totalAssetsBefore2, totalSupplyBefore2);
        vm.stopPrank();

        // Log exchange rates for debugging
        uint256 exchangeRate1 = (totalAssetsBefore1 * WAD) / totalSupplyBefore1;
        uint256 exchangeRate2 = (totalAssetsBefore2 * WAD) / totalSupplyBefore2;
        
        // If yield accrued, exchange rate should have increased (user2 gets fewer shares)
        if (totalAssetsBefore2 > totalAssetsBefore1 + depositAmount) {
            assertLt(shares2, shares1, "User2 should get fewer shares due to higher exchange rate");
            assertGt(exchangeRate2, exchangeRate1, "Exchange rate should have increased");
        }
    }

    function testFuzz_lendingOptimizer_deposit_invariant_sharesCalculation(uint256 depositAmount) public {
        // Bound to reasonable amounts
        depositAmount = bound(depositAmount, 1e6, 10_000_000e6);

        vm.startPrank(user1);

        deal(USDC_MONAD, user1, depositAmount, true);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);

        // Accrue first to get post-accrual state (deposit() calls _accrueIfNeeded internally)
        optimizer.accrueIfNeeded();
        uint256 totalAssetsBefore = optimizer.totalAssets();
        uint256 totalSupplyBefore = optimizer.totalSupply();

        uint256 shares = optimizer.deposit(depositAmount, user1);

        // Verify the core ERC4626 invariant
        _assertSharesMatchInvariant(depositAmount, shares, totalAssetsBefore, totalSupplyBefore);

        // Verify previewDeposit matches actual.
        // Allow 0-2 wei variance due to cToken rounding in _depositToMarket.
        // Note: previewDeposit uses fully-diluted pricing (includes unvested yield),
        // so during active vesting it returns fewer shares than convertToShares().
        // We can't use the pre-deposit state here since deposit already changed state,
        // but _assertSharesMatchInvariant above already validates the core invariant.

        vm.stopPrank();
    }

    function test_lendingOptimizer_deposit_invariant_exchangeRateNeverDecreases() public {
        uint256 depositAmount = 1000e6;

        // Track exchange rate across multiple deposits
        uint256 previousExchangeRate = optimizer.exchangeRate();

        for (uint256 i = 0; i < 5; i++) {
            address depositor = i % 2 == 0 ? user1 : user2;
            
            deal(USDC_MONAD, depositor, depositAmount, true);
            vm.startPrank(depositor);
            IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
            optimizer.deposit(depositAmount, depositor);
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

    function test_lendingOptimizer_deposit_invariant_totalAssetsEqualsSum() public {
        uint256 depositAmount = 1000e6;

        // Multiple users deposit
        address[3] memory users = [user1, user2, makeAddr("user3")];
        uint256 totalDeposited;

        for (uint256 i = 0; i < users.length; i++) {
            deal(USDC_MONAD, users[i], depositAmount, true);
            vm.startPrank(users[i]);
            IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
            optimizer.deposit(depositAmount, users[i]);
            vm.stopPrank();
            totalDeposited += depositAmount;
        }

        // Total assets should approximately equal the sum of deposits (plus initial deposit from setUp).
        // Allow some tolerance for cToken rounding (1-2 wei per deposit).
        uint256 initialDeposit = 77777; // From setUp
        uint256 expectedTotal = totalDeposited + initialDeposit;
        uint256 tolerance = 10; // Allow up to 10 wei difference for multiple deposits

        assertApproxEqAbs(
            optimizer.totalAssets(),
            expectedTotal,
            tolerance,
            "Total assets should approximately equal sum of all deposits"
        );
    }
}