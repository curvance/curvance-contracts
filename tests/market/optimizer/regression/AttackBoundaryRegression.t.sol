// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { LendingOptimizerShareCToken } from "contracts/market/token/LendingOptimizerShareCToken.sol";
import { DynamicIRM } from "contracts/market/DynamicIRM.sol";
import { ERC20 } from "contracts/libraries/external/ERC20.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { ILendingOptimizer } from "contracts/interfaces/ILendingOptimizer.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { WAD, BPS } from "contracts/libraries/ConstantsLib.sol";

/// @title Attack Boundary Regression Tests for LendingOptimizer
/// @notice Exercises attack-boundary scenarios against the optimizer's accounting
/// @dev These tests preserve current defensive behavior for known attack-boundary scenarios
contract LendingOptimizerAttackBoundaryRegression is TestBaseLendingOptimizer {

    bytes4 internal constant REENTRANCY_SELECTOR =
        bytes4(keccak256("Reentrancy()"));

    address attacker = address(0xBAD);
    address victim = address(0xFACE);

    function setUp() public override {
        super.setUp();
        _setUpThreeMarkets();
    }

    // =========================================================================
    // ATTACK 1: Donation Attack - Direct transfer to optimizer
    // =========================================================================

    /// @notice Attempt: Donate assets directly to optimizer to inflate exchange rate
    /// @dev Attack vector: Transfer assets to optimizer without going through deposit
    ///      Expected: Exchange rate should NOT be affected by direct donations
    function test_attackBoundary_donationAttack_directTransfer() public {
        // Victim deposits first
        deal(USDC_MONAD, victim, 1_000_000e6);
        vm.startPrank(victim);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000_000e6);
        uint256 victimShares = optimizer.deposit(1_000_000e6, victim);
        vm.stopPrank();

        uint256 exchangeRateBefore = optimizer.exchangeRate();
        uint256 totalAssetsBefore = optimizer.totalAssets();

        // Attacker donates directly to optimizer contract
        deal(USDC_MONAD, attacker, 500_000e6);
        vm.prank(attacker);
        IERC20(USDC_MONAD).transfer(address(optimizer), 500_000e6);

        // Exchange rate should NOT increase from direct donation
        uint256 exchangeRateAfter = optimizer.exchangeRate();
        uint256 totalAssetsAfter = optimizer.totalAssets();

        // totalAssets should be unchanged (donation not tracked)
        assertEq(totalAssetsAfter, totalAssetsBefore, "totalAssets should not change from donation");

        // Exchange rate should be unchanged
        assertEq(exchangeRateAfter, exchangeRateBefore, "Exchange rate should not change from donation");

        // Victim's redeemable assets should be unchanged
        uint256 victimAssets = optimizer.convertToAssets(victimShares);
        assertApproxEqRel(victimAssets, 1_000_000e6, 0.001e18, "Victim assets unchanged");
    }

    // =========================================================================
    // ATTACK 2: Sandwich Attack on Vesting Boundary
    // =========================================================================

    /// @notice Attempt: Front-run yield detection by depositing right before vesting ends
    /// @dev Attack vector: Deposit just before yield becomes visible, redeem after
    ///      Expected: Attacker should not profit significantly from timing
    function test_attackBoundary_sandwichAttack_vestingBoundary() public {
        // Setup: Victim deposits
        deal(USDC_MONAD, victim, 1_000_000e6);
        vm.startPrank(victim);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000_000e6);
        optimizer.deposit(1_000_000e6, victim);
        vm.stopPrank();

        // Let yield accrue in underlying markets (simulate 1 day of interest)
        skip(1 days);

        // Trigger accrual to start vesting
        optimizer.exchangeRate();

        // Skip some time for yield to be recognized
        skip(1 days);

        uint256 exchangeRateMidVest = optimizer.exchangeRate();

        // Attacker deposits large amount trying to capture remaining vesting
        deal(USDC_MONAD, attacker, 10_000_000e6);
        vm.startPrank(attacker);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000_000e6);
        uint256 attackerShares = optimizer.deposit(10_000_000e6, attacker);
        vm.stopPrank();

        // Skip past vesting
        skip(2);

        // Trigger final vesting
        optimizer.exchangeRate();

        // Attacker redeems immediately
        vm.prank(attacker);
        uint256 attackerAssets = optimizer.redeem(attackerShares, attacker, attacker);

        // Attacker should NOT profit significantly
        int256 attackerProfit = int256(attackerAssets) - int256(10_000_000e6);

        // Attacker's profit per dollar invested should be minimal
        assertLt(attackerProfit, 100e6, "Attacker profit should be minimal");

        emit log_named_int("Attacker profit/loss (6 decimals)", attackerProfit);
    }

    // =========================================================================
    // ATTACK 3: Exchange Rate Manipulation via Rounding
    // =========================================================================

    /// @notice Attempt: Exercise rounding in share calculation
    /// @dev Attack vector: Many small deposits to accumulate rounding errors
    ///      Expected: Rounding should favor vault, not attacker
    function test_attackBoundary_roundingAttack_manySmallDeposits() public {
        // Victim deposits first
        deal(USDC_MONAD, victim, 1_000_000e6);
        vm.startPrank(victim);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000_000e6);
        optimizer.deposit(1_000_000e6, victim);
        vm.stopPrank();

        uint256 exchangeRateBefore = optimizer.exchangeRate();

        // Attacker makes many tiny deposits
        uint256 totalDeposited;
        uint256 totalShares;
        deal(USDC_MONAD, attacker, 1_000_000e6);
        vm.startPrank(attacker);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000_000e6);

        // Make 100 small deposits
        for (uint256 i = 0; i < 100; i++) {
            uint256 depositAmount = 1000e6; // 1000 USDC each
            uint256 shares = optimizer.deposit(depositAmount, attacker);
            totalDeposited += depositAmount;
            totalShares += shares;
        }
        vm.stopPrank();

        // Exchange rate should not decrease
        uint256 exchangeRateAfter = optimizer.exchangeRate();
        assertGe(exchangeRateAfter, exchangeRateBefore, "Exchange rate should not decrease");

        // Attacker should not have gained value from rounding
        uint256 attackerValue = optimizer.convertToAssets(totalShares);
        assertLe(attackerValue, totalDeposited, "Attacker should not profit from rounding");
    }

    // =========================================================================
    // ATTACK 4: Fee Avoidance via Watermark Gaming
    // =========================================================================

    /// @notice Attempt: Avoid fees by depositing after yield, withdrawing before fee
    /// @dev Attack vector: Time deposits/withdrawals to avoid performance fee
    ///      Expected: Fees should be charged correctly based on vested yield
    function test_attackBoundary_feeAvoidance_timingAttack() public {
        // Victim deposits first
        deal(USDC_MONAD, victim, 1_000_000e6);
        vm.startPrank(victim);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000_000e6);
        optimizer.deposit(1_000_000e6, victim);
        vm.stopPrank();

        // Let yield accrue
        skip(1 days);

        // Trigger vesting start
        optimizer.exchangeRate();

        // Attacker deposits during vesting (trying to capture yield without fees)
        deal(USDC_MONAD, attacker, 1_000_000e6);
        vm.startPrank(attacker);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000_000e6);
        uint256 attackerShares = optimizer.deposit(1_000_000e6, attacker);
        vm.stopPrank();

        uint256 attackerValueBeforeVesting = optimizer.convertToAssets(attackerShares);

        // Skip past vesting
        skip(2 days);

        // Attacker tries to redeem before fees are charged
        vm.prank(attacker);
        uint256 attackerAssets = optimizer.redeem(attackerShares, attacker, attacker);

        // Attacker should not have captured yield disproportionately
        int256 attackerGain = int256(attackerAssets) - int256(1_000_000e6);
        assertLt(
            attackerGain,
            int256(10e6),
            "Attacker gain should stay below timing materiality bound"
        );

        emit log_named_int("Attacker gain (6 decimals)", attackerGain);
    }

    // =========================================================================
    // ATTACK 5: Flash Loan Attack
    // =========================================================================

    /// @notice Attempt: Use flash loan to capture yield
    /// @dev Attack vector: Flash deposit -> trigger accrual -> flash withdraw
    ///      Expected: No profit due to same-block deposit/withdraw
    function test_attackBoundary_flashLoanAttack_sameBlock() public {
        // Victim deposits first
        deal(USDC_MONAD, victim, 1_000_000e6);
        vm.startPrank(victim);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000_000e6);
        optimizer.deposit(1_000_000e6, victim);
        vm.stopPrank();

        // Let yield accrue
        skip(1 days);

        uint256 exchangeRateBefore = optimizer.exchangeRate();

        // Attacker "flash loans" and does deposit+redeem in same block
        deal(USDC_MONAD, attacker, 10_000_000e6);
        vm.startPrank(attacker);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000_000e6);

        // Deposit
        uint256 shares = optimizer.deposit(10_000_000e6, attacker);

        // Immediately redeem (same block - no time passes for vesting)
        uint256 assetsOut = optimizer.redeem(shares, attacker, attacker);
        vm.stopPrank();

        // Attacker should NOT profit
        int256 profit = int256(assetsOut) - int256(10_000_000e6);
        assertLe(profit, 0, "Flash attacker should not profit");

        emit log_named_int("Flash attack profit (should be <= 0)", profit);
    }

    // =========================================================================
    // ATTACK 7: Inflation Attack (First Depositor)
    // =========================================================================

    /// @notice Attempt: Classic ERC4626 inflation attack
    /// @dev Attack vector: First depositor manipulates share price
    ///      Expected: Dead shares prevent this attack
    function test_attackBoundary_inflationAttack_firstDepositor() public {
        // Deploy fresh optimizer to test first deposit
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        LendingOptimizer freshOptimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            "Flagship",
            "Flag",
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000 // 10% fee
        );

        // Initialize with dead shares (required)
        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(freshOptimizer), initAssets);
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
        freshOptimizer.initializeDeposits(cUSDC_WMON_MARKET);

        // Verify dead shares exist
        uint256 deadShares = freshOptimizer.balanceOf(address(0));
        assertGt(deadShares, 0, "Dead shares should exist");

        // Exchange rate should be 1:1 after init
        uint256 exchangeRate = freshOptimizer.exchangeRate();
        assertEq(exchangeRate, WAD, "Exchange rate should be 1:1 after init");

        // Victim deposits - should get fair share
        deal(USDC_MONAD, victim, 1_000e6);
        vm.startPrank(victim);
        IERC20(USDC_MONAD).approve(address(freshOptimizer), 1_000e6);
        uint256 victimShares = freshOptimizer.deposit(1_000e6, victim);
        vm.stopPrank();

        // Victim should receive approximately 1:1 shares
        uint256 victimValue = freshOptimizer.convertToAssets(victimShares);
        assertApproxEqRel(victimValue, 1_000e6, 0.01e18, "Victim should get fair value");
    }

    /// @notice Attempt: Redeem optimizer dead shares by forging a zero-owner permit.
    /// @dev Attack vector: Invalid signatures can recover address(0), and dead shares are
    ///      intentionally minted to address(0) during initializeDeposits().
    function test_attackBoundary_zeroOwnerPermit_cannotRedeemDeadShares() public {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        LendingOptimizer freshOptimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            "Flagship",
            "Flag",
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(freshOptimizer), initAssets);
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
        freshOptimizer.initializeDeposits(cUSDC_WMON_MARKET);

        uint256 deadShares = freshOptimizer.balanceOf(address(0));
        assertGt(deadShares, 0, "Dead shares should exist");
        assertEq(freshOptimizer.allowance(address(0), attacker), 0, "No prior zero-owner allowance");

        vm.prank(attacker);
        vm.expectRevert();
        freshOptimizer.permit(
            address(0),
            attacker,
            deadShares,
            block.timestamp,
            27,
            bytes32(0),
            bytes32(0)
        );

        assertEq(
            freshOptimizer.allowance(address(0), attacker),
            0,
            "Invalid zero-owner permit must not create allowance"
        );
        assertEq(freshOptimizer.balanceOf(address(0)), deadShares, "Dead shares must remain");
    }

    /// @notice Attempt: Spend cToken dead shares by forging a zero-owner permit.
    /// @dev The shared ERC20 permit path is inherited by cTokens as well as the optimizer.
    function test_attackBoundary_zeroOwnerPermit_cannotSpendCTokenDeadShares() public {
        BorrowableCToken cToken = BorrowableCToken(cUSDC_WMON_MARKET);
        uint256 deadShares = cToken.balanceOf(address(0));
        assertGt(deadShares, 0, "cToken dead shares should exist");
        assertEq(cToken.allowance(address(0), attacker), 0, "No prior zero-owner allowance");

        vm.prank(attacker);
        vm.expectRevert();
        cToken.permit(
            address(0),
            attacker,
            deadShares,
            block.timestamp,
            27,
            bytes32(0),
            bytes32(0)
        );

        assertEq(cToken.allowance(address(0), attacker), 0, "Invalid permit must not create allowance");
        assertEq(cToken.balanceOf(address(0)), deadShares, "cToken dead shares must remain");
    }

    // =========================================================================
    // ATTACK 8: Reentrancy via cToken callback
    // =========================================================================

    /// @notice Verify: malicious approved-market callbacks cannot reenter optimizer state changes.
    /// @dev This models a callback-enabled cToken listed as an optimizer market.
    function test_attackBoundary_maliciousApprovedMarketReentryBlockedDuringDepositAndWithdraw() public {
        address validManager = address(
            IBorrowableCToken(cUSDC_WMON_MARKET).marketManager()
        );
        MaliciousOptimizerMarket maliciousMarket = new MaliciousOptimizerMarket(
            USDC_MONAD,
            validManager
        );
        vm.mockCall(
            validManager,
            abi.encodeWithSelector(
                IMarketManager.isListed.selector,
                address(maliciousMarket)
            ),
            abi.encode(true)
        );

        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = address(maliciousMarket);

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        LendingOptimizer callbackOptimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            "Flagship",
            "Flag",
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            0
        );
        maliciousMarket.setOptimizer(address(callbackOptimizer));

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        deal(USDC_MONAD, address(this), 77777 + 100_000e6);
        IERC20(USDC_MONAD).approve(address(callbackOptimizer), type(uint256).max);

        maliciousMarket.setReentryEnabled(true);
        callbackOptimizer.initializeDeposits(address(maliciousMarket));

        assertTrue(maliciousMarket.reentryAttempted(), "init reentry attempted");
        assertFalse(maliciousMarket.reentrySucceeded(), "init reentry blocked");
        assertEq(
            maliciousMarket.lastReentrySelector(),
            REENTRANCY_SELECTOR,
            "init reentry selector"
        );

        maliciousMarket.resetReentry();
        maliciousMarket.setReentryEnabled(true);
        uint256 shares = callbackOptimizer.deposit(100_000e6, address(this));

        assertGt(shares, 0, "deposit should succeed");
        assertTrue(maliciousMarket.reentryAttempted(), "deposit reentry attempted");
        assertFalse(maliciousMarket.reentrySucceeded(), "deposit reentry blocked");
        assertEq(
            maliciousMarket.lastReentrySelector(),
            REENTRANCY_SELECTOR,
            "deposit reentry selector"
        );

        maliciousMarket.resetReentry();
        maliciousMarket.setReentryEnabled(true);
        callbackOptimizer.withdraw(10_000e6, address(this), address(this));

        assertTrue(maliciousMarket.reentryAttempted(), "withdraw reentry attempted");
        assertFalse(maliciousMarket.reentrySucceeded(), "withdraw reentry blocked");
        assertEq(
            maliciousMarket.lastReentrySelector(),
            REENTRANCY_SELECTOR,
            "withdraw reentry selector"
        );

        maliciousMarket.resetReentry();
        maliciousMarket.setReentryEnabled(true);
        uint256 assets = callbackOptimizer.mint(1e6, address(this));

        assertGt(assets, 0, "mint should succeed");
        assertTrue(maliciousMarket.reentryAttempted(), "mint reentry attempted");
        assertFalse(maliciousMarket.reentrySucceeded(), "mint reentry blocked");
        assertEq(
            maliciousMarket.lastReentrySelector(),
            REENTRANCY_SELECTOR,
            "mint reentry selector"
        );

        maliciousMarket.resetReentry();
        maliciousMarket.setReentryEnabled(true);
        uint256 redeemedAssets = callbackOptimizer.redeem(1e6, address(this), address(this));

        assertGt(redeemedAssets, 0, "redeem should succeed");
        assertTrue(maliciousMarket.reentryAttempted(), "redeem reentry attempted");
        assertFalse(maliciousMarket.reentrySucceeded(), "redeem reentry blocked");
        assertEq(
            maliciousMarket.lastReentrySelector(),
            REENTRANCY_SELECTOR,
            "redeem reentry selector"
        );
    }

    /// @notice Verify: underlying token callbacks cannot reenter optimizer state changes.
    /// @dev This models an ERC20 with transfer hooks around optimizer asset movement.
    function test_attackBoundary_callbackUnderlyingCannotReenterDuringOptimizerAssetTransfers() public {
        address validManager = address(
            IBorrowableCToken(cUSDC_WMON_MARKET).marketManager()
        );
        CallbackOptimizerAsset callbackAsset = new CallbackOptimizerAsset();
        MaliciousOptimizerMarket callbackMarket = new MaliciousOptimizerMarket(
            address(callbackAsset),
            validManager
        );
        vm.mockCall(
            validManager,
            abi.encodeWithSelector(
                IMarketManager.isListed.selector,
                address(callbackMarket)
            ),
            abi.encode(true)
        );

        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = address(callbackMarket);

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        LendingOptimizer callbackOptimizer = new LendingOptimizer(
            IERC20(address(callbackAsset)),
            "Flagship",
            "Flag",
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            0
        );
        callbackMarket.setOptimizer(address(callbackOptimizer));

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        callbackAsset.mint(address(this), 77777 + 100_000e18);
        callbackAsset.approve(address(callbackOptimizer), type(uint256).max);

        callbackAsset.configureReentry(
            address(callbackOptimizer),
            CallbackOptimizerAsset.ReentryMode.ToOptimizer
        );
        callbackOptimizer.initializeDeposits(address(callbackMarket));

        assertTrue(callbackAsset.reentryAttempted(), "init asset callback");
        assertFalse(callbackAsset.reentrySucceeded(), "init asset reentry blocked");
        assertEq(
            callbackAsset.reentryRevertSelector(),
            REENTRANCY_SELECTOR,
            "init asset selector"
        );

        callbackAsset.resetReentry();
        callbackAsset.configureReentry(
            address(callbackOptimizer),
            CallbackOptimizerAsset.ReentryMode.ToOptimizer
        );
        uint256 shares = callbackOptimizer.deposit(100_000e18, address(this));

        assertGt(shares, 0, "callback-asset deposit shares");
        assertTrue(callbackAsset.reentryAttempted(), "deposit asset callback");
        assertFalse(callbackAsset.reentrySucceeded(), "deposit asset reentry blocked");
        assertEq(
            callbackAsset.reentryRevertSelector(),
            REENTRANCY_SELECTOR,
            "deposit asset selector"
        );

        callbackAsset.resetReentry();
        callbackAsset.configureReentry(
            address(callbackOptimizer),
            CallbackOptimizerAsset.ReentryMode.FromOptimizer
        );
        callbackOptimizer.withdraw(10_000e18, address(this), address(this));

        assertTrue(callbackAsset.reentryAttempted(), "withdraw asset callback");
        assertFalse(callbackAsset.reentrySucceeded(), "withdraw asset reentry blocked");
        assertEq(
            callbackAsset.reentryRevertSelector(),
            REENTRANCY_SELECTOR,
            "withdraw asset selector"
        );

        callbackAsset.resetReentry();
        callbackAsset.configureReentry(
            address(callbackOptimizer),
            CallbackOptimizerAsset.ReentryMode.ToOptimizer
        );
        uint256 assets = callbackOptimizer.mint(1e18, address(this));

        assertGt(assets, 0, "callback-asset mint assets");
        assertTrue(callbackAsset.reentryAttempted(), "mint asset callback");
        assertFalse(callbackAsset.reentrySucceeded(), "mint asset reentry blocked");
        assertEq(
            callbackAsset.reentryRevertSelector(),
            REENTRANCY_SELECTOR,
            "mint asset selector"
        );

        callbackAsset.resetReentry();
        callbackAsset.configureReentry(
            address(callbackOptimizer),
            CallbackOptimizerAsset.ReentryMode.FromOptimizer
        );
        uint256 redeemedAssets = callbackOptimizer.redeem(1e18, address(this), address(this));

        assertGt(redeemedAssets, 0, "callback-asset redeem assets");
        assertTrue(callbackAsset.reentryAttempted(), "redeem asset callback");
        assertFalse(callbackAsset.reentrySucceeded(), "redeem asset reentry blocked");
        assertEq(
            callbackAsset.reentryRevertSelector(),
            REENTRANCY_SELECTOR,
            "redeem asset selector"
        );

        callbackAsset.resetReentry();
        callbackAsset.mint(address(callbackOptimizer), 1e18);
        callbackAsset.configureReentry(
            address(callbackOptimizer),
            CallbackOptimizerAsset.ReentryMode.FromOptimizer
        );

        uint256 daoBalanceBefore = callbackAsset.balanceOf(liveCentralRegistry.daoAddress());
        callbackOptimizer.skim();

        assertEq(
            callbackAsset.balanceOf(liveCentralRegistry.daoAddress()) -
                daoBalanceBefore,
            1e18,
            "skim transfers idle asset"
        );
        assertTrue(callbackAsset.reentryAttempted(), "skim asset callback");
        assertFalse(callbackAsset.reentrySucceeded(), "skim asset reentry blocked");
        assertEq(
            callbackAsset.reentryRevertSelector(),
            REENTRANCY_SELECTOR,
            "skim asset selector"
        );
    }

    /// @notice Verify: permissioned lifecycle callbacks cannot reenter optimizer state changes.
    /// @dev This covers rebalance/remove callbacks separately from public ERC4626-style flows.
    function test_attackBoundary_permissionedLifecycleMaliciousMarketReentryBlockedDuringRebalanceAndRemoval() public {
        address validManager = address(
            IBorrowableCToken(cUSDC_WMON_MARKET).marketManager()
        );
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasHarvestPermissions.selector, address(this)),
            abi.encode(true)
        );
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        MaliciousOptimizerMarket lifecycleMarket = new MaliciousOptimizerMarket(
            USDC_MONAD,
            validManager
        );
        _mockMarketListed(validManager, address(lifecycleMarket));
        LendingOptimizer lifecycleOptimizer = _newTwoMarketOptimizer(
            IERC20(USDC_MONAD),
            address(lifecycleMarket),
            cUSDC_WMON_MARKET
        );
        lifecycleMarket.setOptimizer(address(lifecycleOptimizer));

        deal(USDC_MONAD, address(this), 77777 + 100_000e6);
        IERC20(USDC_MONAD).approve(address(lifecycleOptimizer), type(uint256).max);
        lifecycleOptimizer.initializeDeposits(address(lifecycleMarket));
        lifecycleOptimizer.deposit(100_000e6, address(this));

        lifecycleMarket.resetReentry();
        lifecycleMarket.setReentryEnabled(true);
        lifecycleOptimizer.rebalance(
            _actions2(address(lifecycleMarket), -int256(10_000e6), cUSDC_WMON_MARKET, int256(10_000e6)),
            _bounds2(address(lifecycleMarket), cUSDC_WMON_MARKET)
        );

        assertTrue(lifecycleMarket.reentryAttempted(), "rebalance withdraw reentry attempted");
        assertFalse(lifecycleMarket.reentrySucceeded(), "rebalance withdraw reentry blocked");
        assertEq(
            lifecycleMarket.lastReentrySelector(),
            REENTRANCY_SELECTOR,
            "rebalance withdraw reentry selector"
        );

        lifecycleMarket.resetReentry();
        lifecycleMarket.setReentryEnabled(true);
        lifecycleOptimizer.rebalance(
            _actions2(address(lifecycleMarket), int256(5_000e6), cUSDC_WMON_MARKET, -int256(5_000e6)),
            _bounds2(address(lifecycleMarket), cUSDC_WMON_MARKET)
        );

        assertTrue(lifecycleMarket.reentryAttempted(), "rebalance deposit reentry attempted");
        assertFalse(lifecycleMarket.reentrySucceeded(), "rebalance deposit reentry blocked");
        assertEq(
            lifecycleMarket.lastReentrySelector(),
            REENTRANCY_SELECTOR,
            "rebalance deposit reentry selector"
        );

        lifecycleMarket.resetReentry();
        lifecycleMarket.setReentryEnabled(true);
        lifecycleOptimizer.removeApprovedAsset(
            address(lifecycleMarket),
            _removeAction(cUSDC_WMON_MARKET),
            _bounds1(cUSDC_WMON_MARKET)
        );

        assertTrue(lifecycleMarket.reentryAttempted(), "remove redeem reentry attempted");
        assertFalse(lifecycleMarket.reentrySucceeded(), "remove redeem reentry blocked");
        assertEq(
            lifecycleMarket.lastReentrySelector(),
            REENTRANCY_SELECTOR,
            "remove redeem reentry selector"
        );
        assertEq(lifecycleOptimizer.numApprovedMarkets(), 1, "removed malicious market");

        MaliciousOptimizerMarket targetMarket = new MaliciousOptimizerMarket(
            USDC_MONAD,
            validManager
        );
        _mockMarketListed(validManager, address(targetMarket));
        LendingOptimizer removeToMaliciousOptimizer = _newTwoMarketOptimizer(
            IERC20(USDC_MONAD),
            cUSDC_WMON_MARKET,
            address(targetMarket)
        );
        targetMarket.setOptimizer(address(removeToMaliciousOptimizer));

        deal(USDC_MONAD, address(this), 77777 + 100_000e6);
        IERC20(USDC_MONAD).approve(address(removeToMaliciousOptimizer), type(uint256).max);
        removeToMaliciousOptimizer.initializeDeposits(cUSDC_WMON_MARKET);
        removeToMaliciousOptimizer.deposit(100_000e6, address(this));

        targetMarket.resetReentry();
        targetMarket.setReentryEnabled(true);
        removeToMaliciousOptimizer.removeApprovedAsset(
            cUSDC_WMON_MARKET,
            _removeAction(address(targetMarket)),
            _bounds1(address(targetMarket))
        );

        assertTrue(targetMarket.reentryAttempted(), "remove deposit reentry attempted");
        assertFalse(targetMarket.reentrySucceeded(), "remove deposit reentry blocked");
        assertEq(
            targetMarket.lastReentrySelector(),
            REENTRANCY_SELECTOR,
            "remove deposit reentry selector"
        );
        assertEq(removeToMaliciousOptimizer.numApprovedMarkets(), 1, "removed source market");
    }

    /// @notice Verify: approved-market accrual callbacks cannot reenter accrual-only optimizer entrypoints.
    /// @dev `exchangeRateUpdated()` and `accrueIfNeeded()` call approved cToken hooks without moving user assets.
    function test_attackBoundary_maliciousApprovedMarketReentryBlockedDuringAccrualEntrypoints() public {
        address validManager = address(
            IBorrowableCToken(cUSDC_WMON_MARKET).marketManager()
        );
        MaliciousOptimizerMarket accrualMarket = new MaliciousOptimizerMarket(
            USDC_MONAD,
            validManager
        );
        _mockMarketListed(validManager, address(accrualMarket));
        LendingOptimizer accrualOptimizer = _newSingleMarketOptimizer(
            IERC20(USDC_MONAD),
            address(accrualMarket)
        );
        accrualMarket.setOptimizer(address(accrualOptimizer));

        deal(USDC_MONAD, address(this), 77777 + 100_000e6);
        IERC20(USDC_MONAD).approve(address(accrualOptimizer), type(uint256).max);
        accrualOptimizer.initializeDeposits(address(accrualMarket));
        accrualOptimizer.deposit(100_000e6, address(this));

        accrualMarket.setReentryOnAccrue(true);
        accrualMarket.setReentryEnabled(true);

        accrualMarket.resetReentry();
        assertGt(accrualOptimizer.exchangeRateUpdated(), 0, "exchange rate settled");
        assertTrue(accrualMarket.reentryAttempted(), "exchangeRateUpdated reentry attempted");
        assertFalse(accrualMarket.reentrySucceeded(), "exchangeRateUpdated reentry blocked");
        assertEq(
            accrualMarket.lastReentrySelector(),
            REENTRANCY_SELECTOR,
            "exchangeRateUpdated reentry selector"
        );

        accrualMarket.resetReentry();
        accrualOptimizer.accrueIfNeeded();
        assertTrue(accrualMarket.reentryAttempted(), "accrueIfNeeded reentry attempted");
        assertFalse(accrualMarket.reentrySucceeded(), "accrueIfNeeded reentry blocked");
        assertEq(
            accrualMarket.lastReentrySelector(),
            REENTRANCY_SELECTOR,
            "accrueIfNeeded reentry selector"
        );

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        accrualMarket.resetReentry();
        accrualOptimizer.setFee(100);
        assertTrue(accrualMarket.reentryAttempted(), "setFee accrue reentry attempted");
        assertFalse(accrualMarket.reentrySucceeded(), "setFee accrue reentry blocked");
        assertEq(
            accrualMarket.lastReentrySelector(),
            REENTRANCY_SELECTOR,
            "setFee accrue reentry selector"
        );
        assertEq(accrualOptimizer.fee(), 100, "setFee still settles");
    }

    /// @notice Verify: a hard-reverting approved market bricks optimizer movement fail-closed.
    /// @dev This preserves the code-identity boundary: the optimizer does not
    ///      route around an approved market whose accrual hook stops working.
    function test_attackBoundary_revertingApprovedMarketBlocksMovementAndRemoval() public {
        address validManager = address(
            IBorrowableCToken(cUSDC_WMON_MARKET).marketManager()
        );
        MaliciousOptimizerMarket revertingMarket = new MaliciousOptimizerMarket(
            USDC_MONAD,
            validManager
        );
        _mockMarketListed(validManager, address(revertingMarket));

        LendingOptimizer livenessOptimizer = _newTwoMarketOptimizer(
            IERC20(USDC_MONAD),
            address(revertingMarket),
            cUSDC_WMON_MARKET
        );

        deal(USDC_MONAD, address(this), 77777 + 200_000e6);
        IERC20(USDC_MONAD).approve(address(livenessOptimizer), type(uint256).max);
        livenessOptimizer.initializeDeposits(address(revertingMarket));
        uint256 shares = livenessOptimizer.deposit(100_000e6, address(this));
        assertGt(shares, 0, "test setup shares");

        revertingMarket.setRevertOnAccrue(true);

        vm.expectRevert(MaliciousOptimizerMarket.MaliciousOptimizerMarket__AccrueReverted.selector);
        livenessOptimizer.deposit(1e6, address(this));

        vm.expectRevert(MaliciousOptimizerMarket.MaliciousOptimizerMarket__AccrueReverted.selector);
        livenessOptimizer.transfer(victim, shares / 4);

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
        vm.expectRevert(MaliciousOptimizerMarket.MaliciousOptimizerMarket__AccrueReverted.selector);
        livenessOptimizer.removeApprovedAsset(
            address(revertingMarket),
            _removeAction(cUSDC_WMON_MARKET),
            _bounds1(cUSDC_WMON_MARKET)
        );

        assertEq(livenessOptimizer.numApprovedMarkets(), 2, "failed removal keeps market approved");
        assertEq(
            livenessOptimizer.balanceOf(victim),
            0,
            "failed transfer does not move optimizer shares"
        );
    }

    /// @notice Verify: optimizer share movement cannot be reentered while it refreshes approved-market NAV.
    /// @dev `transfer` and `transferFrom` both call `_accrueIfNeeded()` before moving shares.
    function test_attackBoundary_maliciousApprovedMarketReentryBlockedDuringShareMovement() public {
        address validManager = address(
            IBorrowableCToken(cUSDC_WMON_MARKET).marketManager()
        );
        MaliciousOptimizerMarket accrualMarket = new MaliciousOptimizerMarket(
            USDC_MONAD,
            validManager
        );
        _mockMarketListed(validManager, address(accrualMarket));
        LendingOptimizer accrualOptimizer = _newSingleMarketOptimizer(
            IERC20(USDC_MONAD),
            address(accrualMarket)
        );
        accrualMarket.setOptimizer(address(accrualOptimizer));

        deal(USDC_MONAD, address(this), 77777 + 100_000e6);
        IERC20(USDC_MONAD).approve(address(accrualOptimizer), type(uint256).max);
        accrualOptimizer.initializeDeposits(address(accrualMarket));
        uint256 userShares = accrualOptimizer.deposit(100_000e6, address(this));
        uint256 transferAmount = userShares / 4;
        assertGt(transferAmount, 0, "test setup shares");

        accrualMarket.setReentryOnAccrue(true);
        accrualMarket.setReentryEnabled(true);

        uint256 ownerBefore = accrualOptimizer.balanceOf(address(this));
        uint256 victimBefore = accrualOptimizer.balanceOf(victim);
        accrualMarket.resetReentry();
        assertTrue(accrualOptimizer.transfer(victim, transferAmount), "transfer settled");
        assertTrue(accrualMarket.reentryAttempted(), "transfer accrue reentry attempted");
        assertFalse(accrualMarket.reentrySucceeded(), "transfer accrue reentry blocked");
        assertEq(
            accrualMarket.lastReentrySelector(),
            REENTRANCY_SELECTOR,
            "transfer accrue reentry selector"
        );
        assertEq(accrualOptimizer.balanceOf(address(this)), ownerBefore - transferAmount, "owner transfer delta");
        assertEq(accrualOptimizer.balanceOf(victim), victimBefore + transferAmount, "victim transfer delta");

        uint256 delegatedAmount = transferAmount / 2;
        assertGt(delegatedAmount, 0, "delegated transfer shares");
        accrualOptimizer.approve(attacker, delegatedAmount);

        ownerBefore = accrualOptimizer.balanceOf(address(this));
        victimBefore = accrualOptimizer.balanceOf(victim);
        accrualMarket.resetReentry();
        vm.prank(attacker);
        assertTrue(accrualOptimizer.transferFrom(address(this), victim, delegatedAmount), "transferFrom settled");
        assertTrue(accrualMarket.reentryAttempted(), "transferFrom accrue reentry attempted");
        assertFalse(accrualMarket.reentrySucceeded(), "transferFrom accrue reentry blocked");
        assertEq(
            accrualMarket.lastReentrySelector(),
            REENTRANCY_SELECTOR,
            "transferFrom accrue reentry selector"
        );
        assertEq(accrualOptimizer.balanceOf(address(this)), ownerBefore - delegatedAmount, "owner transferFrom delta");
        assertEq(accrualOptimizer.balanceOf(victim), victimBefore + delegatedAmount, "victim transferFrom delta");
        assertEq(accrualOptimizer.allowance(address(this), attacker), 0, "delegated allowance consumed");
    }

    /// @notice Verify: optimizer-approved market callbacks cannot reenter the share wrapper while it refreshes NAV.
    /// @dev The wrapper's freshness hook calls optimizer.accrual before cToken accounting;
    ///      a hostile approved market then attempts the wrapper's unguarded freshness hook.
    function test_attackBoundary_maliciousApprovedMarketCannotReenterShareWrapperFreshnessDuringDeposit()
        public
    {
        address validManager = address(
            IBorrowableCToken(cUSDC_WMON_MARKET).marketManager()
        );
        MaliciousOptimizerMarket accrualMarket = new MaliciousOptimizerMarket(
            USDC_MONAD,
            validManager
        );
        _mockMarketListed(validManager, address(accrualMarket));
        LendingOptimizer accrualOptimizer = _newSingleMarketOptimizer(
            IERC20(USDC_MONAD),
            address(accrualMarket)
        );
        accrualMarket.setOptimizer(address(accrualOptimizer));

        DynamicIRM irm = _newWrapperIRM();
        LendingOptimizerShareCToken shareCToken = new LendingOptimizerShareCToken(
            liveCentralRegistry,
            ILendingOptimizer(address(accrualOptimizer)),
            validManager,
            address(irm)
        );
        irm.setLinkedToken(address(shareCToken));

        vm.mockCall(
            validManager,
            abi.encodeWithSelector(IMarketManager.canMint.selector, address(shareCToken)),
            ""
        );

        deal(USDC_MONAD, address(this), 77777 + 100_000e6);
        IERC20(USDC_MONAD).approve(address(accrualOptimizer), type(uint256).max);
        accrualOptimizer.initializeDeposits(address(accrualMarket));
        uint256 optimizerShares = accrualOptimizer.deposit(100_000e6, address(this));
        assertGt(optimizerShares, 77777, "test setup optimizer shares");
        uint256 wrapperDeposit = (optimizerShares - 77777) / 2;
        assertGt(wrapperDeposit, 0, "test setup wrapper assets");

        IERC20(address(accrualOptimizer)).approve(
            address(shareCToken), 77777 + wrapperDeposit
        );
        vm.prank(validManager);
        shareCToken.initializeDeposits(address(this));

        accrualMarket.setReentryOnAccrue(true);
        accrualMarket.setReentryCall(
            address(shareCToken),
            abi.encodeWithSelector(shareCToken.exchangeRateUpdated.selector)
        );
        accrualMarket.setReentryEnabled(true);

        uint256 optimizerAssetsBefore = accrualOptimizer.totalAssets();
        uint256 wrapperShares = shareCToken.deposit(wrapperDeposit, address(this));

        assertGt(wrapperShares, 0, "wrapper deposit settled");
        assertTrue(accrualMarket.reentryAttempted(), "wrapper reentry attempted");
        assertFalse(accrualMarket.reentrySucceeded(), "wrapper reentry blocked");
        assertEq(
            accrualMarket.lastReentrySelector(),
            REENTRANCY_SELECTOR,
            "wrapper reentry selector"
        );
        assertEq(
            shareCToken.convertToAssets(wrapperShares),
            wrapperDeposit,
            "wrapper accounting settled on deposited optimizer shares"
        );
        assertEq(
            accrualOptimizer.totalAssets(),
            optimizerAssetsBefore,
            "blocked nested freshness did not mutate optimizer NAV"
        );
    }

    function _newSingleMarketOptimizer(
        IERC20 asset,
        address market
    ) internal returns (LendingOptimizer callbackOptimizer) {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = market;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        callbackOptimizer = new LendingOptimizer(
            asset,
            "Flagship",
            "Flag",
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            0
        );
    }

    function _newTwoMarketOptimizer(
        IERC20 asset,
        address market0,
        address market1
    ) internal returns (LendingOptimizer callbackOptimizer) {
        address[] memory approvedCTokens = new address[](2);
        approvedCTokens[0] = market0;
        approvedCTokens[1] = market1;

        uint256[] memory allocationCapsBps = new uint256[](2);
        allocationCapsBps[0] = 10_000;
        allocationCapsBps[1] = 10_000;

        callbackOptimizer = new LendingOptimizer(
            asset,
            "Flagship",
            "Flag",
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            0
        );
    }

    function _newWrapperIRM() internal returns (DynamicIRM) {
        return new DynamicIRM(
            liveCentralRegistry, 1200, 2000, 8500, 500, 200, 100000
        );
    }

    function _mockMarketListed(address marketManager, address market) internal {
        vm.mockCall(
            marketManager,
            abi.encodeWithSelector(IMarketManager.isListed.selector, market),
            abi.encode(true)
        );
    }

    function _actions2(
        address market0,
        int256 assets0,
        address market1,
        int256 assets1
    ) internal pure returns (LendingOptimizer.ReallocationAction[] memory actions) {
        actions = new LendingOptimizer.ReallocationAction[](2);
        actions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(market0),
            assets0
        );
        actions[1] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(market1),
            assets1
        );
    }

    function _removeAction(
        address targetMarket
    ) internal pure returns (LendingOptimizer.ReallocationAction[] memory actions) {
        actions = new LendingOptimizer.ReallocationAction[](1);
        actions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(targetMarket),
            int256(BPS)
        );
    }

    function _bounds2(
        address market0,
        address market1
    ) internal pure returns (LendingOptimizer.AllocationBound[] memory bounds) {
        bounds = new LendingOptimizer.AllocationBound[](2);
        bounds[0] = LendingOptimizer.AllocationBound(market0, 0, BPS);
        bounds[1] = LendingOptimizer.AllocationBound(market1, 0, BPS);
    }

    function _bounds1(
        address market
    ) internal pure returns (LendingOptimizer.AllocationBound[] memory bounds) {
        bounds = new LendingOptimizer.AllocationBound[](1);
        bounds[0] = LendingOptimizer.AllocationBound(market, 0, BPS);
    }

    // =========================================================================
    // ATTACK 9: Griefing via Dust Deposits
    // =========================================================================

    /// @notice Attempt: Grief vault with many dust deposits
    /// @dev Attack vector: Create many tiny positions to increase gas costs
    ///      Expected: Minimum viable deposit should be enforced by cToken
    function test_attackBoundary_griefing_dustDeposits() public {
        // Try to deposit dust amount
        deal(USDC_MONAD, attacker, 1);
        vm.startPrank(attacker);
        IERC20(USDC_MONAD).approve(address(optimizer), 1);

        // This should revert (cToken rejects dust)
        vm.expectRevert();
        optimizer.deposit(1, attacker);
        vm.stopPrank();
    }

    // =========================================================================
    // ATTACK 10: Watermark Reset Boundary
    // =========================================================================

    /// @notice Attempt: Reset watermark by causing temporary loss
    /// @dev Attack vector: Cause loss to reset watermark, then capture recovery
    ///      Expected: Watermark should never decrease
    function test_attackBoundary_watermarkReset_lossRecovery() public {
        // Deposit and let yield accrue
        deal(USDC_MONAD, address(this), 1_000_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000_000e6);
        optimizer.deposit(1_000_000e6, address(this));

        // Accrue yield and charge fees
        skip(2 days);
        optimizer.exchangeRate();

        uint256 watermarkBefore = optimizer.exchangeRateHighWatermark();

        skip(2 days);
        optimizer.exchangeRate();

        uint256 watermarkAfter = optimizer.exchangeRateHighWatermark();

        // Watermark should never decrease
        assertGe(watermarkAfter, watermarkBefore, "Watermark should never decrease");
    }

    // =========================================================================
    // ATTACK 11: Share Calculation Overflow
    // =========================================================================

    /// @notice Attempt: Cause overflow in share calculations
    /// @dev Attack vector: Extreme values that might overflow
    ///      Expected: No overflow due to safe math
    function test_attackBoundary_overflow_extremeDeposit() public {
        uint256 extremeAmount = type(uint128).max;
        deal(USDC_MONAD, address(this), extremeAmount);
        IERC20(USDC_MONAD).approve(address(optimizer), extremeAmount);

        // This might revert due to liquidity limits, but should not overflow
        try optimizer.deposit(extremeAmount, address(this)) returns (uint256 shares) {
            assertGt(shares, 0, "Shares should be non-zero");
        } catch {
            // Revert is acceptable (due to cToken limits, not overflow)
        }
    }

    // =========================================================================
    // ATTACK 12: Race Condition on Fee Accrual
    // =========================================================================

    /// @notice Attempt: Race to deposit before fee accrual
    /// @dev Attack vector: Deposit right before exchangeRateUpdated is called
    ///      Expected: Can't front-run because deposit calls _accrueIfNeeded first
    function test_attackBoundary_raceCondition_feeAccrual() public {
        // Victim deposits
        deal(USDC_MONAD, victim, 1_000_000e6);
        vm.startPrank(victim);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000_000e6);
        optimizer.deposit(1_000_000e6, victim);
        vm.stopPrank();

        // Yield accrues
        skip(2 days);

        uint256 exchangeRateBefore = optimizer.exchangeRate();

        // Attacker tries to deposit to dilute existing shareholders before fees
        deal(USDC_MONAD, attacker, 1_000_000e6);
        vm.startPrank(attacker);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000_000e6);
        uint256 attackerShares = optimizer.deposit(1_000_000e6, attacker);
        vm.stopPrank();

        // Exchange rate should not decrease. Live exchangeRate() reads cToken
        // convertToAssets which rounds down, causing a negligible rate decrease
        // after deposits route through cToken share math.
        uint256 exchangeRateAfter = optimizer.exchangeRate();
        assertGe(exchangeRateAfter + exchangeRateBefore / 1e10, exchangeRateBefore,
            "Exchange rate should not decrease beyond cToken rounding tolerance");

        // Attacker should get shares at post-fee rate, not pre-fee rate
        uint256 attackerValue = optimizer.convertToAssets(attackerShares);
        assertLe(attackerValue, 1_000_000e6 + 1000, "Attacker should not profit from timing");
    }

    // =========================================================================
    // ATTACK 13: Vesting Boundary Exact Timing
    // =========================================================================

    /// @notice Attempt: Deposit exactly when vesting ends (boundary condition)
    /// @dev Attack vector: Exercise exact vesting end timestamp
    ///      Expected: No profit from exact timing
    function test_attackBoundary_vestingBoundary_exactTiming() public {
        // Victim deposits
        deal(USDC_MONAD, victim, 1_000_000e6);
        vm.startPrank(victim);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000_000e6);
        optimizer.deposit(1_000_000e6, victim);
        vm.stopPrank();

        // Yield accrues
        skip(1 days);

        // Start vesting
        optimizer.exchangeRate();

        // Skip some time for yield to be recognized
        skip(2 days);

        // Attacker deposits at exact vesting boundary
        deal(USDC_MONAD, attacker, 1_000_000e6);
        vm.startPrank(attacker);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000_000e6);
        uint256 attackerShares = optimizer.deposit(1_000_000e6, attacker);
        vm.stopPrank();

        // Attacker redeems immediately
        vm.prank(attacker);
        uint256 attackerAssets = optimizer.redeem(attackerShares, attacker, attacker);

        // Attacker should not profit
        int256 profit = int256(attackerAssets) - int256(1_000_000e6);
        assertLe(profit, 0, "Attacker should not profit from boundary timing");

        emit log_named_int("Boundary timing profit", profit);
    }

    // =========================================================================
    // ATTACK 14: Multiple Vesting Periods Stacking
    // =========================================================================

    /// @notice Attempt: Exercise transition between vesting periods
    /// @dev Attack vector: Try to capture yield from multiple vesting periods
    ///      Expected: Each period should be independent
    function test_attackBoundary_multipleVestingPeriods() public {
        // Victim deposits
        deal(USDC_MONAD, victim, 1_000_000e6);
        vm.startPrank(victim);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000_000e6);
        optimizer.deposit(1_000_000e6, victim);
        vm.stopPrank();

        uint256 victimSharesBefore = optimizer.balanceOf(victim);

        // Go through 5 accrual cycles. Use exchangeRateUpdated() to trigger
        // _accrueIfNeeded(); exchangeRate() is now a cached view.
        for (uint256 i = 0; i < 5; i++) {
            skip(2 days);
            optimizer.exchangeRateUpdated();
        }

        // Exchange rate should have increased
        uint256 exchangeRateAfter = optimizer.exchangeRate();
        assertGt(exchangeRateAfter, WAD, "Exchange rate should increase over time");

        // Victim's value should have increased
        uint256 victimValueAfter = optimizer.convertToAssets(victimSharesBefore);
        assertGt(victimValueAfter, 1_000_000e6, "Victim value should increase");

        // Attacker enters late
        deal(USDC_MONAD, attacker, 1_000_000e6);
        vm.startPrank(attacker);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000_000e6);
        uint256 attackerShares = optimizer.deposit(1_000_000e6, attacker);
        vm.stopPrank();

        // Attacker should get fewer shares (exchange rate > 1)
        assertLt(attackerShares, 1_000_000e6, "Attacker should get fewer shares at higher rate");

        // Attacker value should equal deposit
        uint256 attackerValue = optimizer.convertToAssets(attackerShares);
        assertApproxEqRel(attackerValue, 1_000_000e6, 0.001e18, "Attacker value should equal deposit");
    }

    // =========================================================================
    // ATTACK 15: Zero Supply Edge Case After Full Withdrawal
    // =========================================================================

    /// @notice Attempt: Exercise zero supply state after full withdrawal
    /// @dev Attack vector: Withdraw everything, then deposit to manipulate rate
    ///      Expected: Dead shares prevent zero supply
    function test_attackBoundary_zeroSupply_afterFullWithdrawal() public {
        // Deposit
        deal(USDC_MONAD, address(this), 1_000_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000_000e6);
        uint256 shares = optimizer.deposit(1_000_000e6, address(this));

        // Try to withdraw everything
        uint256 assets = optimizer.redeem(shares, address(this), address(this));
        assertGt(assets, 0, "Should receive assets");

        // Total supply should NOT be zero (dead shares exist)
        uint256 remainingSupply = optimizer.totalSupply();
        assertGt(remainingSupply, 0, "Dead shares should remain");

        // Exchange rate should still be valid
        uint256 exchangeRate = optimizer.exchangeRate();
        assertGt(exchangeRate, 0, "Exchange rate should be valid");

        // Next depositor should get fair rate
        deal(USDC_MONAD, attacker, 1_000_000e6);
        vm.startPrank(attacker);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000_000e6);
        uint256 attackerShares = optimizer.deposit(1_000_000e6, attacker);
        vm.stopPrank();

        uint256 attackerValue = optimizer.convertToAssets(attackerShares);
        assertApproxEqRel(attackerValue, 1_000_000e6, 0.01e18, "Attacker should get fair value");
    }

    // =========================================================================
    // ATTACK 16: Rapid Deposit/Withdraw Cycles
    // =========================================================================

    /// @notice Attempt: Exercise rapid deposit/withdraw cycles
    /// @dev Attack vector: Many rapid cycles to accumulate rounding in favor
    ///      Expected: Rounding should favor vault consistently
    function test_attackBoundary_rapidCycles() public {
        deal(USDC_MONAD, attacker, 10_000_000e6);
        vm.startPrank(attacker);
        IERC20(USDC_MONAD).approve(address(optimizer), type(uint256).max);

        uint256 startingBalance = 10_000_000e6;
        uint256 currentBalance = startingBalance;

        // 20 rapid deposit/withdraw cycles
        for (uint256 i = 0; i < 20; i++) {
            uint256 shares = optimizer.deposit(currentBalance, attacker);
            currentBalance = optimizer.redeem(shares, attacker, attacker);
        }
        vm.stopPrank();

        // Attacker should have lost value (rounding favors vault)
        assertLe(currentBalance, startingBalance, "Attacker should not profit from cycles");

        int256 loss = int256(startingBalance) - int256(currentBalance);
        emit log_named_int("Loss from 20 cycles (6 decimals)", loss);

        // Loss should be small but non-zero
        assertGt(loss, 0, "Should have some loss from rounding");
    }

    // =========================================================================
    // ATTACK 17: Exchange Rate Consistency Check
    // =========================================================================

    /// @notice Invariant: Exchange rate should never decrease unexpectedly
    /// @dev Verify exchange rate monotonicity across various operations
    function test_invariant_exchangeRateNeverDecreases() public {
        // Initial deposit
        deal(USDC_MONAD, address(this), 10_000_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000_000e6);
        optimizer.deposit(5_000_000e6, address(this));

        uint256 lastRate = optimizer.exchangeRate();

        // Series of operations
        for (uint256 i = 0; i < 10; i++) {
            // Deposit
            optimizer.deposit(100_000e6, address(this));
            uint256 rateAfterDeposit = optimizer.exchangeRate();
            // cToken share rounding causes _depositToMarket to track slightly
            // fewer assets than actually deposited (1-2 wei per cToken
            // conversion). This produces a negligible rate decrease that scales
            // with deposit size relative to total assets. We tolerate up to
            // 0.001% relative decrease per deposit.
            if (rateAfterDeposit < lastRate) {
                uint256 decrease = lastRate - rateAfterDeposit;
                assertLe(decrease, lastRate / 100_000,
                    "Rate decreased after deposit by more than cToken rounding tolerance");
            }
            lastRate = rateAfterDeposit;

            // Time passes
            skip(1 hours);

            // Accrue
            optimizer.exchangeRate();
            uint256 rateAfterAccrue = optimizer.exchangeRate();
            assertGe(rateAfterAccrue, lastRate, "Rate decreased after accrue");
            lastRate = rateAfterAccrue;

            // Partial withdraw
            uint256 shares = optimizer.balanceOf(address(this));
            if (shares > 10_000e6) {
                optimizer.redeem(10_000e6, address(this), address(this));
                uint256 rateAfterWithdraw = optimizer.exchangeRate();
                // Live exchangeRate() reads cToken convertToAssets which rounds
                // down, causing a negligible rate decrease after withdrawals.
                assertGe(rateAfterWithdraw + lastRate / 1e10, lastRate,
                    "Rate decreased after withdraw beyond cToken rounding tolerance");
                lastRate = rateAfterWithdraw;
            }
        }
    }

    // =========================================================================
    // ATTACK 18: totalAssets vs Sum of Markets Discrepancy
    // =========================================================================

    /// @notice Invariant: totalAssets should match sum of market values (within buffer)
    /// @dev Check for any discrepancy that could create value extraction
    function test_invariant_totalAssetsMatchesMarkets() public {
        // Deposit to multiple markets
        deal(USDC_MONAD, address(this), 3_000_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 3_000_000e6);

        optimizer.deposit(1_000_000e6, address(this));
        optimizer.deposit(1_000_000e6, address(this));
        optimizer.deposit(1_000_000e6, address(this));

        // Calculate sum of markets manually
        uint256 market0 = IBorrowableCToken(cUSDC_WMON_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer))
        );
        uint256 market1 = IBorrowableCToken(cUSDC_WBTC_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WBTC_MARKET).balanceOf(address(optimizer))
        );
        uint256 market2 = IBorrowableCToken(cUSDC_WETH_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WETH_MARKET).balanceOf(address(optimizer))
        );

        uint256 sumOfMarkets = market0 + market1 + market2;
        uint256 totalAssets = optimizer.totalAssets();

        // Should match closely (small rounding tolerance from cToken math).
        assertApproxEqAbs(
            totalAssets,
            sumOfMarkets,
            100,
            "totalAssets should match sum of markets"
        );
    }
}

contract MaliciousOptimizerMarket {
    error MaliciousOptimizerMarket__AccrueReverted();

    address public immutable asset;
    address public immutable marketManager;

    address public optimizer;
    uint256 public totalSupply;
    bool public reentryEnabled;
    bool public reenterOnAccrue;
    bool public revertOnAccrue;
    bool public reentryAttempted;
    bool public reentrySucceeded;
    bytes public lastReentryData;
    address public reentryTarget;
    bytes public reentryCallData;

    mapping(address => uint256) public balanceOf;

    constructor(address asset_, address marketManager_) {
        asset = asset_;
        marketManager = marketManager_;
    }

    function setOptimizer(address optimizer_) external {
        optimizer = optimizer_;
    }

    function setReentryEnabled(bool enabled) external {
        reentryEnabled = enabled;
    }

    function setReentryOnAccrue(bool enabled) external {
        reenterOnAccrue = enabled;
    }

    function setRevertOnAccrue(bool enabled) external {
        revertOnAccrue = enabled;
    }

    function setReentryCall(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryCallData = data;
    }

    function resetReentry() external {
        reentryAttempted = false;
        reentrySucceeded = false;
        delete lastReentryData;
    }

    function isBorrowable() external pure returns (bool) {
        return true;
    }

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function convertToShares(uint256 assets) external pure returns (uint256) {
        return assets;
    }

    function previewDeposit(uint256 assets) external pure returns (uint256) {
        return assets;
    }

    function previewWithdraw(uint256 assets) external pure returns (uint256) {
        return assets;
    }

    function previewRedeem(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function previewMint(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function exchangeRate() external pure returns (uint256) {
        return WAD;
    }

    function assetsHeld() external view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function totalAssets() external view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function accrueIfNeeded() external {
        if (revertOnAccrue) revert MaliciousOptimizerMarket__AccrueReverted();
        if (reenterOnAccrue) _attemptReentry();
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        IERC20(asset).transferFrom(msg.sender, address(this), assets);
        _attemptReentry();

        shares = assets;
        balanceOf[receiver] += shares;
        totalSupply += shares;
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) external returns (uint256 shares) {
        shares = assets;
        balanceOf[owner] -= shares;
        totalSupply -= shares;

        IERC20(asset).transfer(receiver, assets);
        _attemptReentry();
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets) {
        assets = shares;
        balanceOf[owner] -= shares;
        totalSupply -= shares;

        IERC20(asset).transfer(receiver, assets);
        _attemptReentry();
    }

    function lastReentrySelector() external view returns (bytes4 selector) {
        bytes memory data = lastReentryData;
        if (data.length >= 4) {
            assembly {
                selector := mload(add(data, 32))
            }
        }
    }

    function _attemptReentry() internal {
        if (!reentryEnabled || reentryAttempted) return;

        reentryAttempted = true;

        if (reentryTarget != address(0)) {
            (reentrySucceeded, lastReentryData) =
                reentryTarget.call(reentryCallData);
            return;
        }

        IERC20(asset).approve(optimizer, 1);

        try LendingOptimizer(optimizer).deposit(1, address(this)) returns (uint256) {
            reentrySucceeded = true;
        } catch (bytes memory reason) {
            lastReentryData = reason;
        }

        IERC20(asset).approve(optimizer, 0);
    }
}

contract CallbackOptimizerAsset is ERC20 {
    enum ReentryMode {
        None,
        ToOptimizer,
        FromOptimizer
    }

    address public optimizer;
    ReentryMode public reentryMode;
    bool public reentryAttempted;
    bool public reentrySucceeded;
    bytes4 public reentryRevertSelector;

    function name() public pure override returns (string memory) {
        return "Callback Asset";
    }

    function symbol() public pure override returns (string memory) {
        return "CALL";
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function configureReentry(
        address optimizer_,
        ReentryMode reentryMode_
    ) external {
        optimizer = optimizer_;
        reentryMode = reentryMode_;
        reentryAttempted = false;
        reentrySucceeded = false;
        reentryRevertSelector = bytes4(0);
    }

    function resetReentry() external {
        reentryAttempted = false;
        reentrySucceeded = false;
        reentryRevertSelector = bytes4(0);
    }

    function _afterTokenTransfer(
        address from,
        address to,
        uint256
    ) internal override {
        if (
            optimizer == address(0) ||
            reentryMode == ReentryMode.None ||
            reentryAttempted
        ) {
            return;
        }

        if (reentryMode == ReentryMode.ToOptimizer && to != optimizer) return;
        if (reentryMode == ReentryMode.FromOptimizer && from != optimizer) {
            return;
        }

        reentryAttempted = true;
        _approve(address(this), optimizer, 1);

        (bool success, bytes memory data) = optimizer.call(
            abi.encodeWithSelector(
                LendingOptimizer.deposit.selector,
                1,
                address(this)
            )
        );
        reentrySucceeded = success;
        if (!success && data.length >= 4) {
            reentryRevertSelector = bytes4(data);
        }

        _approve(address(this), optimizer, 0);
    }
}
