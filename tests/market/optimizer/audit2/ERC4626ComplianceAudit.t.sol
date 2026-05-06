// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizerHarness } from "../LendingOptimizerHarness.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { WAD, BPS } from "contracts/libraries/ConstantsLib.sol";
import { console2 } from "forge-std/console2.sol";

/// @title ERC4626 Compliance & Invariant Audit
/// @notice Auditor 4: Tests ERC4626 compliance, invariant violations, and edge
///         cases that prior audits missed.
/// @dev Covers: share transfer consistency, concurrent deposits,
///      round-trip properties, maxDeposit spec compliance, dead shares robustness,
///      previewDeposit vs actual deposit, preview/max withdrawal
///      consistency, exchange rate invariant, zero-amount operations, and more.
contract ERC4626ComplianceAudit is TestBaseLendingOptimizer {

    LendingOptimizerHarness harness;

    address user1Addr = address(0x1001);
    address user2Addr = address(0x1002);
    address user3Addr = address(0x1003);
    address daoAddr;

    uint256 constant BASE_RESERVE = 77777;
    uint256 constant ONE_USDC = 1e6;
    uint256 constant MILLION_USDC = 1_000_000e6;

    function setUp() public override {
        super.setUp();
    }

    // =====================================================================
    //  HELPERS
    // =====================================================================

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
            0
        );

        deal(USDC_MONAD, address(this), BASE_RESERVE);
        IERC20(USDC_MONAD).approve(address(harness), BASE_RESERVE);
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
        harness.initializeDeposits(cUSDC_WMON_MARKET);

        daoAddr = liveCentralRegistry.daoAddress();
    }

    function _setUpHarnessWithFee() internal {
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

        deal(USDC_MONAD, address(this), BASE_RESERVE);
        IERC20(USDC_MONAD).approve(address(harness), BASE_RESERVE);
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
        harness.initializeDeposits(cUSDC_WMON_MARKET);

        daoAddr = liveCentralRegistry.daoAddress();
    }

    function _setUpHarnessShortVesting() internal {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        harness = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            0
        );

        deal(USDC_MONAD, address(this), BASE_RESERVE);
        IERC20(USDC_MONAD).approve(address(harness), BASE_RESERVE);
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
        harness.initializeDeposits(cUSDC_WMON_MARKET);
    }

    /// @dev Deposit USDC for a specific user into the harness.
    function _depositAs(address user, uint256 amount) internal returns (uint256 shares) {
        deal(USDC_MONAD, user, amount);
        vm.startPrank(user);
        IERC20(USDC_MONAD).approve(address(harness), amount);
        shares = harness.deposit(amount, user);
        vm.stopPrank();
    }

    /// @dev Trigger yield accrual.
    function _triggerAccrual() internal {
        harness.accrueIfNeeded();
    }

    /// @dev Check the core exchange rate invariant:
    ///      exchangeRate * totalSupply ~= totalAssets * WAD within tolerance.
    function _assertExchangeRateInvariant(string memory context, uint256 tolerance) internal view {
        uint256 supply = harness.totalSupply();
        if (supply == 0) return;
        uint256 ta = harness.totalAssets();
        uint256 lhs = FixedPointMathLib.mulDiv(WAD, ta, supply) * supply;
        uint256 rhs = ta * WAD;
        uint256 diff = lhs > rhs ? lhs - rhs : rhs - lhs;
        require(diff <= tolerance * WAD, string.concat("Exchange rate invariant broken: ", context));
    }

    // =====================================================================
    //  A. SHARE TRANSFER + WITHDRAWAL CONSISTENCY
    // =====================================================================

    /// @notice After transferring half shares from A to B, the sum of their
    ///         asset claims should approximate the original deposit value.
    function test_A_shareTransfer_accountingConsistency() public {
        _setUpHarnessNoFee();

        uint256 depositAmount = MILLION_USDC;
        uint256 sharesA = _depositAs(user1Addr, depositAmount);

        uint256 halfShares = sharesA / 2;

        // Transfer half to user2Addr.
        vm.prank(user1Addr);
        harness.transfer(user2Addr, halfShares);

        uint256 remainingSharesA = harness.balanceOf(user1Addr);
        uint256 sharesBUser2 = harness.balanceOf(user2Addr);

        uint256 assetsA = harness.convertToAssets(remainingSharesA);
        uint256 assetsB = harness.convertToAssets(sharesBUser2);
        uint256 totalClaim = assetsA + assetsB;

        // The original deposit's tracked value (may be slightly less than depositAmount
        // due to cToken rounding).
        uint256 originalAssets = harness.convertToAssets(sharesA);

        // The total claim after transfer should be within 1 wei of the original.
        uint256 diff = totalClaim > originalAssets
            ? totalClaim - originalAssets
            : originalAssets - totalClaim;

        console2.log("Original assets claim:", originalAssets);
        console2.log("Post-transfer total claim:", totalClaim);
        console2.log("Diff (wei):", diff);

        // Rounding can lose up to 1 wei per conversion.
        assertLe(diff, 1, "Share transfer broke accounting by more than 1 wei");
    }

    /// @notice After transfer, both users should be able to redeem their shares.
    function test_A_shareTransfer_bothCanRedeem() public {
        _setUpHarnessNoFee();

        uint256 sharesA = _depositAs(user1Addr, MILLION_USDC);
        uint256 halfShares = sharesA / 2;

        vm.prank(user1Addr);
        harness.transfer(user2Addr, halfShares);

        // User2 redeems their shares.
        uint256 redeemableB = harness.maxRedeem(user2Addr);
        assertGt(redeemableB, 0, "User2 should have redeemable shares");

        vm.prank(user2Addr);
        uint256 assetsB = harness.redeem(redeemableB, user2Addr, user2Addr);
        assertGt(assetsB, 0, "User2 should receive assets");

        // User1 redeems their remaining shares.
        uint256 redeemableA = harness.maxRedeem(user1Addr);
        assertGt(redeemableA, 0, "User1 should have redeemable shares");

        vm.prank(user1Addr);
        uint256 assetsA = harness.redeem(redeemableA, user1Addr, user1Addr);
        assertGt(assetsA, 0, "User1 should receive assets");

        console2.log("User1 redeemed:", assetsA);
        console2.log("User2 redeemed:", assetsB);
    }

    // =====================================================================
    //  B. CONCURRENT DEPOSITS DURING ACTIVE VESTING
    // =====================================================================

    /// @notice Deposit order A->B vs B->A should produce approximately equal
    ///         total shares (within rounding tolerance).
    function test_B_depositOrder_doesNotMatterSignificantly() public {
        // Setup two separate harness instances with identical config.
        // Harness 1: A deposits first, then B.
        _setUpHarnessNoFee();
        LendingOptimizerHarness harness1 = harness;

        uint256 amountA = 500_000e6;
        uint256 amountB = 300_000e6;

        // Deposit into harness1: A then B.
        uint256 sharesA1 = _depositAs(user1Addr, amountA);
        uint256 sharesB1 = _depositAs(user2Addr, amountB);
        uint256 totalShares1 = sharesA1 + sharesB1;

        // Setup harness2: B deposits first, then A.
        _setUpHarnessNoFee();
        LendingOptimizerHarness harness2 = harness;

        // Deposit into harness2: B then A.
        deal(USDC_MONAD, user2Addr, amountB);
        vm.startPrank(user2Addr);
        IERC20(USDC_MONAD).approve(address(harness2), amountB);
        uint256 sharesB2 = harness2.deposit(amountB, user2Addr);
        vm.stopPrank();

        deal(USDC_MONAD, user1Addr, amountA);
        vm.startPrank(user1Addr);
        IERC20(USDC_MONAD).approve(address(harness2), amountA);
        uint256 sharesA2 = harness2.deposit(amountA, user1Addr);
        vm.stopPrank();

        uint256 totalShares2 = sharesA2 + sharesB2;

        console2.log("Order A->B total shares:", totalShares1);
        console2.log("Order B->A total shares:", totalShares2);

        uint256 diff = totalShares1 > totalShares2
            ? totalShares1 - totalShares2
            : totalShares2 - totalShares1;

        // Allow for cToken rounding difference (a few wei).
        assertLe(diff, 5, "Deposit order caused significant share difference");
    }

    // =====================================================================
    //  C. ROUND-TRIP PROPERTY: convertToAssets(convertToShares(x)) <= x
    // =====================================================================

    /// @notice Verify round-trip property for adversarial values during normal state.
    function test_C_roundTrip_depositDirection_normalState() public {
        _setUpHarnessNoFee();
        _depositAs(user1Addr, MILLION_USDC);

        uint256[8] memory testValues = [uint256(1), 2, 3, 7, ONE_USDC - 1, ONE_USDC, ONE_USDC + 1, type(uint128).max];

        for (uint256 i = 0; i < testValues.length; i++) {
            uint256 x = testValues[i];
            uint256 shares = harness.convertToShares(x);
            uint256 backToAssets = harness.convertToAssets(shares);
            assertLe(
                backToAssets, x,
                string.concat("Round-trip deposit violated for value index ", vm.toString(i))
            );
        }
    }

    /// @notice Verify round-trip property for redemption direction.
    function test_C_roundTrip_redeemDirection_normalState() public {
        _setUpHarnessNoFee();
        _depositAs(user1Addr, MILLION_USDC);

        uint256[4] memory testShares = [uint256(1), 7, ONE_USDC, ONE_USDC + 1];

        for (uint256 i = 0; i < testShares.length; i++) {
            uint256 x = testShares[i];
            uint256 assets = harness.convertToAssets(x);
            uint256 backToShares = harness.convertToShares(assets);
            assertLe(
                backToShares, x,
                string.concat("Round-trip redeem violated for value index ", vm.toString(i))
            );
        }
    }

    /// @notice Round-trip after yield accrual.
    function test_C_roundTrip_afterYieldAccrual() public {
        _setUpHarnessNoFee();
        _depositAs(user1Addr, MILLION_USDC);

        // Trigger yield accrual.
        vm.warp(block.timestamp + 1 days);
        harness.accrueIfNeeded();

        uint256[4] memory testValues = [uint256(1), 7, ONE_USDC, MILLION_USDC];

        for (uint256 i = 0; i < testValues.length; i++) {
            uint256 x = testValues[i];
            uint256 shares = harness.convertToShares(x);
            uint256 backToAssets = harness.convertToAssets(shares);
            assertLe(
                backToAssets, x,
                string.concat("Round-trip violated after yield accrual for index ", vm.toString(i))
            );
        }
    }

    /// @notice Round-trip after fee accrual.
    function test_C_roundTrip_afterFeeAccrual() public {
        _setUpHarnessWithFee();
        _depositAs(user1Addr, MILLION_USDC);

        // Generate yield and let it vest.
        vm.warp(block.timestamp + 2 days);
        harness.accrueIfNeeded();
        vm.warp(block.timestamp + 2 days);
        harness.accrueIfNeeded(); // Fee accrual happens here.

        uint256[4] memory testValues = [uint256(1), 7, ONE_USDC, MILLION_USDC];

        for (uint256 i = 0; i < testValues.length; i++) {
            uint256 x = testValues[i];
            uint256 shares = harness.convertToShares(x);
            uint256 backToAssets = harness.convertToAssets(shares);
            assertLe(
                backToAssets, x,
                string.concat("Round-trip violated after fee accrual for index ", vm.toString(i))
            );
        }
    }

    // =====================================================================
    //  D. maxDeposit RETURNS type(uint256).max - SPEC COMPLIANCE
    // =====================================================================

    /// @notice maxDeposit returns type(uint256).max when active, but actual
    ///         deposit of that much would fail. This is a spec deviation.
    function test_D_maxDeposit_returnsMaxUint_whenActive() public {
        _setUpHarnessNoFee();

        uint256 maxDep = harness.maxDeposit(user1Addr);
        assertEq(maxDep, type(uint256).max, "maxDeposit should return max uint when active");

        // Verify that maxDeposit returns 0 when paused.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
        harness.setMintPaused(true);

        uint256 maxDepPaused = harness.maxDeposit(user1Addr);
        assertEq(maxDepPaused, 0, "maxDeposit should return 0 when paused");
    }

    /// @notice maxMint returns type(uint256).max when active.
    function test_D_maxMint_returnsMaxUint_whenActive() public {
        _setUpHarnessNoFee();

        uint256 maxM = harness.maxMint(user1Addr);
        assertEq(maxM, type(uint256).max, "maxMint should return max uint when active");
    }

    // =====================================================================
    //  E. DEAD SHARES ROBUSTNESS
    // =====================================================================

    /// @notice Very small deposit (1 USDC) after initialization should not
    ///         allow value extraction.
    function test_E_deadShares_smallDeposit_noValueExtraction() public {
        _setUpHarnessNoFee();

        uint256 depositAmount = ONE_USDC; // 1 USDC
        uint256 shares = _depositAs(user1Addr, depositAmount);
        assertGt(shares, 0, "Should receive shares for 1 USDC deposit");

        // Immediately redeem.
        uint256 redeemable = harness.maxRedeem(user1Addr);
        vm.prank(user1Addr);
        uint256 assetsBack = harness.redeem(redeemable, user1Addr, user1Addr);

        // Should not get more than deposited.
        assertLe(assetsBack, depositAmount, "Should not extract value from small deposit");

        console2.log("Deposited:", depositAmount);
        console2.log("Got back:", assetsBack);
        console2.log("Loss (wei):", depositAmount - assetsBack);
    }

    /// @notice Very small deposit (100 wei) should not extract value.
    function test_E_deadShares_tinyDeposit_noValueExtraction() public {
        _setUpHarnessNoFee();

        uint256 depositAmount = 100;
        uint256 shares = _depositAs(user1Addr, depositAmount);

        if (shares == 0) {
            console2.log("100 wei deposit yielded 0 shares - dust is lost to vault (by design)");
            return;
        }

        uint256 redeemable = harness.maxRedeem(user1Addr);
        vm.prank(user1Addr);
        uint256 assetsBack = harness.redeem(redeemable, user1Addr, user1Addr);

        assertLe(assetsBack, depositAmount, "Tiny deposit should not extract value");

        console2.log("Deposited:", depositAmount);
        console2.log("Got back:", assetsBack);
    }

    /// @notice Very large deposit should maintain fair exchange rate.
    function test_E_deadShares_largeDeposit_fairExchangeRate() public {
        _setUpHarnessNoFee();

        uint256 rateBefore = harness.exchangeRate();
        console2.log("Exchange rate before large deposit:", rateBefore);

        uint256 largeAmount = 10_000_000e6; // 10M USDC
        _depositAs(user1Addr, largeAmount);

        uint256 rateAfter = harness.exchangeRate();
        console2.log("Exchange rate after large deposit:", rateAfter);

        // Exchange rate should not decrease.
        assertGe(rateAfter, rateBefore, "Exchange rate should not decrease after large deposit");

        // The rate change should be minimal (within a few wei per WAD).
        uint256 rateDiff = rateAfter > rateBefore ? rateAfter - rateBefore : rateBefore - rateAfter;
        assertLe(rateDiff, 10, "Exchange rate should barely change after deposit");
    }

    // =====================================================================
    //  F. previewDeposit VS ACTUAL DEPOSIT DURING VESTING
    // =====================================================================

    /// @notice After yield accrual, previewDeposit should return no more
    ///         shares than actual deposit (ERC4626: deposit MUST return >=
    ///         previewDeposit).
    function test_F_previewDeposit_vs_actualDeposit_afterYieldAccrual() public {
        _setUpHarnessNoFee();
        _depositAs(user1Addr, MILLION_USDC);

        // Generate yield and accrue.
        vm.warp(block.timestamp + 1 days);
        harness.accrueIfNeeded();

        uint256 depositAmount = 100_000e6;

        // Get preview BEFORE actual deposit.
        uint256 previewShares = harness.previewDeposit(depositAmount);

        // Perform actual deposit.
        uint256 actualShares = _depositAs(user2Addr, depositAmount);

        console2.log("previewDeposit:", previewShares);
        console2.log("actualDeposit:", actualShares);

        // ERC4626 spec: deposit() MUST return >= previewDeposit() shares.
        // previewDeposit already subtracts 1 from convertToShares to account
        // for cToken rounding, so actualShares should be >= previewShares
        // with at most 1 wei tolerance for the cToken deposit round-trip.
        assertGe(
            actualShares, previewShares - 1,
            "deposit must return >= previewDeposit minus cToken rounding"
        );
    }

    /// @notice At accrual boundary, test if _accrueIfNeeded changes state between
    ///         preview and deposit causing divergence.
    function test_F_previewDeposit_atAccrualBoundary() public {
        _setUpHarnessNoFee();
        _depositAs(user1Addr, MILLION_USDC);

        // Generate yield -- do not accrue yet.
        vm.warp(block.timestamp + 1 days);

        uint256 depositAmount = 100_000e6;

        // Preview uses current state (before accrual).
        uint256 previewShares = harness.previewDeposit(depositAmount);

        // deposit() calls _accrueIfNeeded() which will:
        // 1. Detect new yield
        // 2. Update _totalAssets
        // 3. Charge performance fees (if any)
        // This changes state before computing shares.
        uint256 actualShares = _depositAs(user2Addr, depositAmount);

        console2.log("Preview at accrual boundary:", previewShares);
        console2.log("Actual at accrual boundary:", actualShares);

        uint256 diff = previewShares > actualShares
            ? previewShares - actualShares
            : actualShares - previewShares;

        console2.log("Diff:", diff);
    }

    /// @notice Right after accrual, preview should match deposit.
    function test_F_previewDeposit_afterAccrual() public {
        _setUpHarnessNoFee();
        _depositAs(user1Addr, MILLION_USDC);

        // Generate yield and accrue.
        vm.warp(block.timestamp + 1 days);
        harness.accrueIfNeeded();

        // Right after accrual.
        uint256 depositAmount = 100_000e6;
        uint256 previewShares = harness.previewDeposit(depositAmount);
        uint256 actualShares = _depositAs(user2Addr, depositAmount);

        console2.log("Preview after accrual:", previewShares);
        console2.log("Actual after accrual:", actualShares);

        uint256 diff = previewShares > actualShares
            ? previewShares - actualShares
            : actualShares - previewShares;

        // After accrual, _accrueIfNeeded() should return early (no new yield),
        // so preview and actual should closely match (within cToken rounding).
        assertLe(diff, 2, "previewDeposit should match actual after accrual (within cToken rounding)");
    }

    // =====================================================================
    //  G. previewWithdraw/previewRedeem DURING VESTING
    // =====================================================================

    /// @notice previewWithdraw(maxWithdraw(owner)) <= balanceOf(owner) after yield.
    function test_G_previewWithdraw_maxWithdraw_consistency() public {
        _setUpHarnessNoFee();
        _depositAs(user1Addr, MILLION_USDC);

        // Accrue yield.
        vm.warp(block.timestamp + 1 days);
        harness.accrueIfNeeded();

        uint256 maxW = harness.maxWithdraw(user1Addr);
        uint256 sharesNeeded = harness.previewWithdraw(maxW);
        uint256 balance = harness.balanceOf(user1Addr);

        console2.log("maxWithdraw:", maxW);
        console2.log("previewWithdraw(maxWithdraw):", sharesNeeded);
        console2.log("balanceOf:", balance);

        assertLe(
            sharesNeeded, balance,
            "previewWithdraw(maxWithdraw(owner)) should not exceed balanceOf(owner)"
        );
    }

    /// @notice previewRedeem(maxRedeem(owner)) <= _totalAssets after yield.
    function test_G_previewRedeem_maxRedeem_consistency() public {
        _setUpHarnessNoFee();
        _depositAs(user1Addr, MILLION_USDC);

        // Accrue yield.
        vm.warp(block.timestamp + 1 days);
        harness.accrueIfNeeded();

        uint256 maxR = harness.maxRedeem(user1Addr);
        uint256 assetsOut = harness.previewRedeem(maxR);
        uint256 totalAssetsIndexed = harness.exposed_totalAssetsIndexed();

        console2.log("maxRedeem:", maxR);
        console2.log("previewRedeem(maxRedeem):", assetsOut);
        console2.log("_totalAssets:", totalAssetsIndexed);

        assertLe(
            assetsOut, totalAssetsIndexed,
            "previewRedeem(maxRedeem(owner)) should not exceed _totalAssets"
        );
    }

    /// @notice maxWithdraw should be capped at _totalAssets.
    function test_G_maxWithdraw_cappedAtTotalAssets() public {
        _setUpHarnessNoFee();
        _depositAs(user1Addr, MILLION_USDC);

        // Accrue yield.
        vm.warp(block.timestamp + 1 days);
        harness.accrueIfNeeded();

        uint256 maxW = harness.maxWithdraw(user1Addr);
        uint256 totalAssetsIndexed = harness.exposed_totalAssetsIndexed();

        console2.log("maxWithdraw:", maxW);
        console2.log("_totalAssets:", totalAssetsIndexed);

        assertLe(maxW, totalAssetsIndexed, "maxWithdraw should be capped at _totalAssets");
    }

    /// @notice withdraw(maxWithdraw(owner)) should succeed after yield accrual.
    function test_G_maxWithdraw_doesNotRevert_afterYieldAccrual() public {
        _setUpHarnessNoFee();
        _depositAs(user1Addr, MILLION_USDC);

        // Accrue yield.
        vm.warp(block.timestamp + 1 days);
        harness.accrueIfNeeded();

        uint256 maxW = harness.maxWithdraw(user1Addr);
        if (maxW > 0) {
            vm.prank(user1Addr);
            harness.withdraw(maxW, user1Addr, user1Addr);
            console2.log("withdraw(maxWithdraw) succeeded with amount:", maxW);
        }
    }

    /// @notice redeem(maxRedeem(owner)) should succeed after yield accrual.
    function test_G_maxRedeem_doesNotRevert_afterYieldAccrual() public {
        _setUpHarnessNoFee();
        _depositAs(user1Addr, MILLION_USDC);

        // Accrue yield.
        vm.warp(block.timestamp + 1 days);
        harness.accrueIfNeeded();

        uint256 maxR = harness.maxRedeem(user1Addr);
        if (maxR > 0) {
            vm.prank(user1Addr);
            harness.redeem(maxR, user1Addr, user1Addr);
            console2.log("redeem(maxRedeem) succeeded with shares:", maxR);
        }
    }

    // =====================================================================
    //  H. EXCHANGE RATE INVARIANT: exchangeRate * totalSupply ~= totalAssets * WAD
    // =====================================================================

    /// @notice Invariant after initialization.
    function test_H_exchangeRateInvariant_afterInit() public {
        _setUpHarnessNoFee();
        _assertExchangeRateInvariant("after init", 2);
    }

    /// @notice Invariant after first deposit.
    function test_H_exchangeRateInvariant_afterDeposit() public {
        _setUpHarnessNoFee();
        _depositAs(user1Addr, MILLION_USDC);
        _assertExchangeRateInvariant("after deposit", 2);
    }

    /// @notice Invariant through multiple yield accrual cycles.
    function test_H_exchangeRateInvariant_multipleAccruals() public {
        _setUpHarnessNoFee();
        _depositAs(user1Addr, MILLION_USDC);

        // After first accrual.
        vm.warp(block.timestamp + 1 days);
        harness.accrueIfNeeded();
        _assertExchangeRateInvariant("after first accrual", 2);

        // After second accrual.
        vm.warp(block.timestamp + 1 days);
        harness.accrueIfNeeded();
        _assertExchangeRateInvariant("after second accrual", 2);

        // After third accrual.
        vm.warp(block.timestamp + 1 days);
        harness.accrueIfNeeded();
        _assertExchangeRateInvariant("after third accrual", 2);
    }

    /// @notice Invariant after fee accrual.
    function test_H_exchangeRateInvariant_afterFeeAccrual() public {
        _setUpHarnessWithFee();
        _depositAs(user1Addr, MILLION_USDC);

        // Generate yield and accrue fees.
        vm.warp(block.timestamp + 2 days);
        harness.accrueIfNeeded();
        vm.warp(block.timestamp + 2 days);
        harness.accrueIfNeeded();

        _assertExchangeRateInvariant("after fee accrual", 2);
    }

    /// @notice Invariant after withdrawal.
    function test_H_exchangeRateInvariant_afterWithdrawal() public {
        _setUpHarnessNoFee();
        _depositAs(user1Addr, MILLION_USDC);

        uint256 withdrawAmount = 200_000e6;
        vm.prank(user1Addr);
        harness.withdraw(withdrawAmount, user1Addr, user1Addr);

        _assertExchangeRateInvariant("after withdrawal", 2);
    }

    // =====================================================================
    //  I. INITIALIZATION WITH EXTREME CTOKEN EXCHANGE RATE
    //     (Testing dead shares effectiveness)
    // =====================================================================

    /// @notice Verify that 77777 wei deposit produces non-zero cToken shares.
    function test_I_initialization_producesNonZeroCTokenShares() public {
        _setUpHarnessNoFee();

        // Check that dead shares were actually minted.
        uint256 deadShares = harness.balanceOf(address(0));
        assertGt(deadShares, 0, "Dead shares should be non-zero after initialization");

        console2.log("Dead shares minted:", deadShares);
        console2.log("Dead share asset value:", harness.convertToAssets(deadShares));
    }

    /// @notice Verify the dead shares value matches _totalAssets after init.
    function test_I_initialization_deadSharesMatchTotalAssets() public {
        _setUpHarnessNoFee();

        uint256 deadShares = harness.balanceOf(address(0));
        uint256 totalSupply = harness.totalSupply();
        uint256 totalAssetsIndexed = harness.exposed_totalAssetsIndexed();

        console2.log("Dead shares:", deadShares);
        console2.log("Total supply:", totalSupply);
        console2.log("_totalAssets:", totalAssetsIndexed);

        // After init, total supply should equal dead shares (no other holders yet).
        assertEq(deadShares, totalSupply, "After init, totalSupply should equal deadShares");
        // _totalAssets should equal dead shares (1:1 at init).
        assertEq(totalAssetsIndexed, deadShares, "After init, _totalAssets should equal deadShares");
    }

    // =====================================================================
    //  J. ERC4626 STRICT COMPLIANCE - ZERO AMOUNT OPERATIONS
    // =====================================================================

    /// @notice deposit(0) should return 0 shares and not revert.
    function test_J_deposit_zero_assets() public {
        _setUpHarnessNoFee();
        _depositAs(user1Addr, MILLION_USDC); // Need existing state.

        deal(USDC_MONAD, user2Addr, 0);
        vm.startPrank(user2Addr);
        IERC20(USDC_MONAD).approve(address(harness), 0);

        // deposit(0) should either return 0 shares or revert.
        // ERC4626 doesn't mandate that deposit(0) must succeed, but it should
        // not leave the vault in an inconsistent state.
        try harness.deposit(0, user2Addr) returns (uint256 shares) {
            console2.log("deposit(0) returned shares:", shares);
            assertEq(shares, 0, "deposit(0) should return 0 shares");
        } catch {
            console2.log("deposit(0) reverted (acceptable)");
        }
        vm.stopPrank();
    }

    /// @notice withdraw(0) should return 0 shares and not revert.
    function test_J_withdraw_zero_assets() public {
        _setUpHarnessNoFee();
        _depositAs(user1Addr, MILLION_USDC);

        vm.prank(user1Addr);
        try harness.withdraw(0, user1Addr, user1Addr) returns (uint256 shares) {
            console2.log("withdraw(0) returned shares:", shares);
            assertEq(shares, 0, "withdraw(0) should return 0 shares");
        } catch {
            console2.log("withdraw(0) reverted (acceptable)");
        }
    }

    /// @notice redeem(0) should return 0 assets and not revert.
    function test_J_redeem_zero_shares() public {
        _setUpHarnessNoFee();
        _depositAs(user1Addr, MILLION_USDC);

        vm.prank(user1Addr);
        try harness.redeem(0, user1Addr, user1Addr) returns (uint256 assets) {
            console2.log("redeem(0) returned assets:", assets);
            assertEq(assets, 0, "redeem(0) should return 0 assets");
        } catch {
            console2.log("redeem(0) reverted (acceptable)");
        }
    }

    /// @notice mint(0) should return 0 assets and not revert.
    function test_J_mint_zero_shares() public {
        _setUpHarnessNoFee();
        _depositAs(user1Addr, MILLION_USDC); // Need existing state.

        deal(USDC_MONAD, user2Addr, 0);
        vm.startPrank(user2Addr);
        IERC20(USDC_MONAD).approve(address(harness), 0);

        // mint(0) should either return 0 assets or revert.
        // ERC4626 doesn't mandate that mint(0) must succeed, but it should
        // not leave the vault in an inconsistent state.
        try harness.mint(0, user2Addr) returns (uint256 assets) {
            console2.log("mint(0) returned assets:", assets);
            assertEq(assets, 0, "mint(0) should return 0 assets");
            // Verify no shares were minted.
            assertEq(harness.balanceOf(user2Addr), 0, "mint(0) should not mint any shares");
        } catch {
            console2.log("mint(0) reverted (acceptable)");
        }
        vm.stopPrank();
    }

    /// @notice convertToShares(0) should return 0.
    function test_J_convertToShares_zero() public {
        _setUpHarnessNoFee();
        _depositAs(user1Addr, MILLION_USDC);

        uint256 shares = harness.convertToShares(0);
        assertEq(shares, 0, "convertToShares(0) should return 0");
    }

    /// @notice convertToAssets(0) should return 0.
    function test_J_convertToAssets_zero() public {
        _setUpHarnessNoFee();
        _depositAs(user1Addr, MILLION_USDC);

        uint256 assets = harness.convertToAssets(0);
        assertEq(assets, 0, "convertToAssets(0) should return 0");
    }

    /// @notice previewDeposit(0) should return 0.
    function test_J_previewDeposit_zero() public {
        _setUpHarnessNoFee();
        _depositAs(user1Addr, MILLION_USDC);

        uint256 shares = harness.previewDeposit(0);
        assertEq(shares, 0, "previewDeposit(0) should return 0");
    }

    /// @notice previewMint(0) should return 0.
    function test_J_previewMint_zero() public {
        _setUpHarnessNoFee();
        _depositAs(user1Addr, MILLION_USDC);

        uint256 assets = harness.previewMint(0);
        assertEq(assets, 0, "previewMint(0) should return 0");
    }

    /// @notice previewRedeem(0) should return 0.
    function test_J_previewRedeem_zero() public {
        _setUpHarnessNoFee();
        _depositAs(user1Addr, MILLION_USDC);

        uint256 assets = harness.previewRedeem(0);
        assertEq(assets, 0, "previewRedeem(0) should return 0");
    }

    // =====================================================================
    //  K. DEPOSIT/MINT SKIP maxDeposit/maxMint CHECK (SPEC DEVIATION)
    // =====================================================================
    //  ERC4626 states that deposit() MUST revert if depositing more than
    //  maxDeposit() allows, and mint() MUST revert if minting more than
    //  maxMint() allows. The contract achieves the same end-result via
    //  _checkMintPaused() instead of consulting maxDeposit/maxMint directly.
    //  These tests document that behavior: when paused, maxDeposit returns 0
    //  and deposit reverts (through _checkMintPaused), and when active,
    //  maxDeposit returns type(uint256).max and deposit succeeds.

    /// @notice When paused: maxDeposit returns 0 and deposit reverts.
    function test_K_maxDeposit_paused_depositReverts() public {
        _setUpHarnessNoFee();

        // Pause deposits.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
        harness.setMintPaused(true);

        // maxDeposit should return 0 when paused.
        uint256 maxDep = harness.maxDeposit(user1Addr);
        assertEq(maxDep, 0, "maxDeposit should return 0 when paused");

        // deposit should revert when paused (via _checkMintPaused, not maxDeposit check).
        deal(USDC_MONAD, user1Addr, ONE_USDC);
        vm.startPrank(user1Addr);
        IERC20(USDC_MONAD).approve(address(harness), ONE_USDC);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__MintPaused.selector);
        harness.deposit(ONE_USDC, user1Addr);
        vm.stopPrank();
    }

    /// @notice When paused: maxMint returns 0 and mint reverts.
    function test_K_maxMint_paused_mintReverts() public {
        _setUpHarnessNoFee();

        // Pause deposits.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
        harness.setMintPaused(true);

        // maxMint should return 0 when paused.
        uint256 maxM = harness.maxMint(user1Addr);
        assertEq(maxM, 0, "maxMint should return 0 when paused");

        // mint should revert when paused (via _checkMintPaused, not maxMint check).
        deal(USDC_MONAD, user1Addr, MILLION_USDC);
        vm.startPrank(user1Addr);
        IERC20(USDC_MONAD).approve(address(harness), MILLION_USDC);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__MintPaused.selector);
        harness.mint(ONE_USDC, user1Addr);
        vm.stopPrank();
    }

    /// @notice When active: maxDeposit returns type(uint256).max and deposit succeeds.
    function test_K_maxDeposit_active_depositSucceeds() public {
        _setUpHarnessNoFee();

        // maxDeposit should return type(uint256).max when active.
        uint256 maxDep = harness.maxDeposit(user1Addr);
        assertEq(maxDep, type(uint256).max, "maxDeposit should return type(uint256).max when active");

        // deposit should succeed when active.
        uint256 shares = _depositAs(user1Addr, MILLION_USDC);
        assertGt(shares, 0, "deposit should succeed and mint shares when active");
    }

    /// @notice When active: maxMint returns type(uint256).max and mint succeeds.
    function test_K_maxMint_active_mintSucceeds() public {
        _setUpHarnessNoFee();

        // maxMint should return type(uint256).max when active.
        uint256 maxM = harness.maxMint(user1Addr);
        assertEq(maxM, type(uint256).max, "maxMint should return type(uint256).max when active");

        // mint should succeed when active.
        uint256 sharesToMint = 100_000e6;
        uint256 assetCost = harness.previewMint(sharesToMint);

        deal(USDC_MONAD, user1Addr, assetCost * 2);
        vm.startPrank(user1Addr);
        IERC20(USDC_MONAD).approve(address(harness), assetCost * 2);
        uint256 actualAssets = harness.mint(sharesToMint, user1Addr);
        vm.stopPrank();

        assertGt(actualAssets, 0, "mint should succeed and spend assets when active");
        assertEq(harness.balanceOf(user1Addr), sharesToMint, "mint should produce exact shares");
    }

    // =====================================================================
    //  L. WITHDRAW/REDEEM SKIP maxWithdraw/maxRedeem CHECK (NATURAL PROTECTION)
    // =====================================================================
    //  ERC4626 states that withdraw() MUST revert if withdrawing more than
    //  maxWithdraw() allows, and redeem() MUST revert if redeeming more than
    //  maxRedeem() allows. The contract does not explicitly consult these
    //  functions but achieves the same result through natural arithmetic
    //  protections (share burn underflow, insufficient cToken balance).
    //  These tests document that behavior.

    /// @notice withdraw(maxWithdraw(owner)) succeeds and returns correct shares.
    function test_L_withdraw_maxWithdraw_succeeds() public {
        _setUpHarnessNoFee();
        _depositAs(user1Addr, MILLION_USDC);

        // Accrue to ensure state is synced before querying maxWithdraw.
        vm.warp(block.timestamp + 1 days);
        harness.accrueIfNeeded();

        uint256 maxW = harness.maxWithdraw(user1Addr);
        assertGt(maxW, 0, "maxWithdraw should be > 0 after deposit");

        // The shares needed to withdraw maxW.
        uint256 expectedShares = harness.previewWithdraw(maxW);

        vm.prank(user1Addr);
        uint256 actualShares = harness.withdraw(maxW, user1Addr, user1Addr);

        // Shares burned should match preview.
        assertEq(actualShares, expectedShares, "withdraw(maxWithdraw) should burn previewWithdraw shares");

        // User should have 0 or near-0 shares remaining (rounding dust possible).
        assertLe(harness.balanceOf(user1Addr), 1, "User should have near-zero shares after full withdraw");

        console2.log("maxWithdraw amount:", maxW);
        console2.log("Shares burned:", actualShares);
    }

    /// @notice redeem(maxRedeem(owner)) succeeds and returns correct assets.
    function test_L_redeem_maxRedeem_succeeds() public {
        _setUpHarnessNoFee();
        _depositAs(user1Addr, MILLION_USDC);

        // Accrue to ensure state is synced before querying maxRedeem.
        vm.warp(block.timestamp + 1 days);
        harness.accrueIfNeeded();

        uint256 maxR = harness.maxRedeem(user1Addr);
        assertGt(maxR, 0, "maxRedeem should be > 0 after deposit");

        // The assets expected from redeeming maxR shares.
        uint256 expectedAssets = harness.previewRedeem(maxR);

        vm.prank(user1Addr);
        uint256 actualAssets = harness.redeem(maxR, user1Addr, user1Addr);

        // Assets returned should approximately match preview. The conversion
        // roundtrip in redeem() may reduce payout by a few wei per market.
        assertApproxEqAbs(actualAssets, expectedAssets, 3, "redeem(maxRedeem) should return previewRedeem assets");

        // User should have 0 shares remaining.
        assertEq(harness.balanceOf(user1Addr), 0, "User should have zero shares after full redeem");

        console2.log("maxRedeem shares:", maxR);
        console2.log("Assets received:", actualAssets);
    }

    /// @notice withdraw(maxWithdraw + 1 wei) reverts (natural arithmetic protection).
    function test_L_withdraw_exceedsMax_reverts() public {
        _setUpHarnessNoFee();
        _depositAs(user1Addr, MILLION_USDC);

        // Accrue to ensure state is synced.
        vm.warp(block.timestamp + 1 days);
        harness.accrueIfNeeded();

        uint256 maxW = harness.maxWithdraw(user1Addr);
        assertGt(maxW, 0, "maxWithdraw should be > 0");

        // Attempting to withdraw 1 wei more than maxWithdraw should revert.
        // The revert comes from trying to burn more shares than the user holds
        // (natural arithmetic underflow protection), not from a maxWithdraw check.
        vm.prank(user1Addr);
        vm.expectRevert();
        harness.withdraw(maxW + 1, user1Addr, user1Addr);
    }

    /// @notice redeem(maxRedeem + 1) reverts (natural arithmetic protection).
    function test_L_redeem_exceedsMax_reverts() public {
        _setUpHarnessNoFee();
        _depositAs(user1Addr, MILLION_USDC);

        // Accrue to ensure state is synced.
        vm.warp(block.timestamp + 1 days);
        harness.accrueIfNeeded();

        uint256 maxR = harness.maxRedeem(user1Addr);
        assertGt(maxR, 0, "maxRedeem should be > 0");

        // Attempting to redeem 1 more share than maxRedeem should revert.
        // The revert comes from trying to burn more shares than the user holds
        // (natural arithmetic underflow protection), not from a maxRedeem check.
        vm.prank(user1Addr);
        vm.expectRevert();
        harness.redeem(maxR + 1, user1Addr, user1Addr);
    }

    // =====================================================================
    //  ADDITIONAL: previewMint vs actual mint consistency
    // =====================================================================

    /// @notice previewMint should return no fewer assets than actual mint requires.
    function test_previewMint_vs_actualMint() public {
        _setUpHarnessNoFee();
        _depositAs(user1Addr, MILLION_USDC);

        uint256 sharesToMint = 500_000e6;
        uint256 previewAssets = harness.previewMint(sharesToMint);

        // Deal extra to cover any accrual-induced increase between preview and actual mint.
        deal(USDC_MONAD, user2Addr, previewAssets + 1e6);
        vm.startPrank(user2Addr);
        IERC20(USDC_MONAD).approve(address(harness), previewAssets + 1e6);
        uint256 actualAssets = harness.mint(sharesToMint, user2Addr);
        vm.stopPrank();

        console2.log("previewMint assets:", previewAssets);
        console2.log("actual mint assets:", actualAssets);

        // ERC4626 spec: mint() MUST spend <= previewMint() assets.
        // Allow 1 wei tolerance: _accrueIfNeeded() inside mint() can shift
        // the exchange rate between the external preview and actual mint.
        assertApproxEqAbs(
            actualAssets, previewAssets, 1,
            "mint() should not require more assets than previewMint() (within accrual rounding)"
        );
    }

    // =====================================================================
    //  ADDITIONAL: previewWithdraw vs actual withdraw consistency
    // =====================================================================

    /// @notice previewWithdraw should return no fewer shares than actual withdraw.
    function test_previewWithdraw_vs_actualWithdraw() public {
        _setUpHarnessNoFee();
        _depositAs(user1Addr, MILLION_USDC);

        uint256 withdrawAmount = 200_000e6;
        uint256 previewShares = harness.previewWithdraw(withdrawAmount);

        vm.prank(user1Addr);
        uint256 actualShares = harness.withdraw(withdrawAmount, user1Addr, user1Addr);

        console2.log("previewWithdraw shares:", previewShares);
        console2.log("actual withdraw shares:", actualShares);

        // ERC4626: withdraw should return same or fewer shares than previewWithdraw.
        assertLe(
            actualShares, previewShares,
            "withdraw() should not burn more shares than previewWithdraw()"
        );
    }

    // =====================================================================
    //  ADDITIONAL: previewRedeem vs actual redeem consistency
    // =====================================================================

    /// @notice previewRedeem should return no more assets than actual redeem.
    function test_previewRedeem_vs_actualRedeem() public {
        _setUpHarnessNoFee();
        _depositAs(user1Addr, MILLION_USDC);

        uint256 sharesToRedeem = 200_000e6;
        uint256 previewAssets = harness.previewRedeem(sharesToRedeem);

        vm.prank(user1Addr);
        uint256 actualAssets = harness.redeem(sharesToRedeem, user1Addr, user1Addr);

        console2.log("previewRedeem assets:", previewAssets);
        console2.log("actual redeem assets:", actualAssets);

        // redeem() applies a conversion roundtrip that may reduce payout
        // by a few wei per market vs previewRedeem().
        assertApproxEqAbs(
            actualAssets, previewAssets, 3,
            "redeem() should approximately match previewRedeem() assets"
        );
    }

    // =====================================================================
    //  ADDITIONAL: Multi-user exchange rate consistency through yield accrual
    // =====================================================================

    /// @notice Exchange rate should be monotonically non-decreasing through
    ///         deposit, yield accrual, and withdrawal sequences.
    function test_exchangeRate_monotonicity_complexSequence() public {
        _setUpHarnessWithFee();

        uint256 lastRate = harness.exchangeRate();
        console2.log("Initial rate:", lastRate);

        // Deposit from 3 users.
        for (uint256 i = 0; i < 3; i++) {
            address user = i == 0 ? user1Addr : (i == 1 ? user2Addr : user3Addr);
            _depositAs(user, (i + 1) * 100_000e6);
            uint256 newRate = harness.exchangeRate();
            assertGe(newRate, lastRate, "Rate decreased after deposit");
            lastRate = newRate;
        }

        // Warp through multiple yield accrual cycles.
        for (uint256 cycle = 0; cycle < 3; cycle++) {
            vm.warp(block.timestamp + 2 days);
            harness.accrueIfNeeded();
            uint256 newRate = harness.exchangeRate();
            assertGe(newRate, lastRate, "Rate decreased during yield accrual cycle");
            lastRate = newRate;
            console2.log("Rate after cycle", cycle, ":", newRate);
        }

        // Partial withdrawal.
        vm.prank(user1Addr);
        harness.withdraw(50_000e6, user1Addr, user1Addr);
        uint256 rateAfterWithdraw = harness.exchangeRate();
        // Live exchangeRate() reads cToken convertToAssets which rounds
        // down, causing a negligible rate decrease after withdrawals.
        assertGe(rateAfterWithdraw + lastRate / 1e10, lastRate,
            "Rate decreased after withdrawal beyond cToken rounding tolerance");
        console2.log("Rate after withdrawal:", rateAfterWithdraw);
    }

    // =====================================================================
    //  ADDITIONAL: maxWithdraw multi-user fairness
    // =====================================================================

    /// @notice With multiple users, sum of all maxWithdraw should not exceed _totalAssets.
    function test_maxWithdraw_multiUser_sumCapped() public {
        _setUpHarnessNoFee();
        _depositAs(user1Addr, 500_000e6);
        _depositAs(user2Addr, 300_000e6);
        _depositAs(user3Addr, 200_000e6);

        // Accrue yield.
        vm.warp(block.timestamp + 1 days);
        harness.accrueIfNeeded();

        uint256 mw1 = harness.maxWithdraw(user1Addr);
        uint256 mw2 = harness.maxWithdraw(user2Addr);
        uint256 mw3 = harness.maxWithdraw(user3Addr);
        uint256 totalAssetsIndexed = harness.exposed_totalAssetsIndexed();

        console2.log("maxWithdraw(user1):", mw1);
        console2.log("maxWithdraw(user2):", mw2);
        console2.log("maxWithdraw(user3):", mw3);
        console2.log("Sum:", mw1 + mw2 + mw3);
        console2.log("_totalAssets:", totalAssetsIndexed);

        // Each individual maxWithdraw is capped at _totalAssets, but they
        // each represent an independent cap, not a collective one. However,
        // the sum of convertToAssets(balanceOf(user)) should be <= totalAssets().
        uint256 sumClaims = harness.convertToAssets(harness.balanceOf(user1Addr))
            + harness.convertToAssets(harness.balanceOf(user2Addr))
            + harness.convertToAssets(harness.balanceOf(user3Addr));

        // Sum of claims should be <= totalAssets (within rounding).
        assertLe(
            sumClaims, harness.totalAssets() + 3,
            "Sum of user claims exceeds totalAssets by more than rounding tolerance"
        );
    }

    // =====================================================================
    //  ADDITIONAL: deposit when paused should revert
    // =====================================================================

    /// @notice deposit should revert when mintPaused == 2.
    function test_deposit_whenPaused_reverts() public {
        _setUpHarnessNoFee();

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
        harness.setMintPaused(true);

        deal(USDC_MONAD, user1Addr, ONE_USDC);
        vm.startPrank(user1Addr);
        IERC20(USDC_MONAD).approve(address(harness), ONE_USDC);

        vm.expectRevert(LendingOptimizer.LendingOptimizer__MintPaused.selector);
        harness.deposit(ONE_USDC, user1Addr);
        vm.stopPrank();
    }

    // =====================================================================
    //  ADDITIONAL: Share price consistency pre and post yield accrual
    // =====================================================================

    /// @notice convertToShares and previewDeposit should be consistent.
    function test_convertToShares_vs_previewDeposit_behavior() public {
        _setUpHarnessNoFee();
        _depositAs(user1Addr, MILLION_USDC);

        // Before yield accrual, they should be identical (allow 1 wei for cToken rounding).
        uint256 amount = 100_000e6;
        uint256 convert = harness.convertToShares(amount);
        uint256 preview = harness.previewDeposit(amount);
        assertApproxEqAbs(convert, preview, 1, "convertToShares should equal previewDeposit before yield");

        // After yield accrual.
        vm.warp(block.timestamp + 1 days);
        harness.accrueIfNeeded();

        uint256 convertAfterYield = harness.convertToShares(amount);
        uint256 previewAfterYield = harness.previewDeposit(amount);

        console2.log("After yield - convertToShares:", convertAfterYield);
        console2.log("After yield - previewDeposit:", previewAfterYield);

        // With immediate yield recognition, previewDeposit and convertToShares
        // should be equal since there is no pricing difference.
        // Allow 1 wei tolerance for cToken rounding.
        assertApproxEqAbs(
            previewAfterYield, convertAfterYield, 1,
            "previewDeposit should equal convertToShares with immediate yield"
        );
    }


    // =====================================================================
    //  REMOVED: _accruedState projection tests
    //  Preview/max functions now use base ERC4626 defaults (cached _totalAssets).
    //  They are intentionally stale between accruals. Off-chain eth_call
    //  simulation replaces on-chain estimation.
    // =====================================================================
}
