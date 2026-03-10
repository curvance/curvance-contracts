// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { WAD, BPS } from "contracts/libraries/ConstantsLib.sol";

/// @title AccessControlFuzz
/// @notice Fuzz tests verifying access control and edge cases for LendingOptimizer.
contract AccessControlFuzz is TestBaseLendingOptimizer {

    function setUp() public override {
        super.setUp();
        _setUpThreeMarkets();
    }

    // ========================================================================
    // UNAUTHORIZED CALLER TESTS
    // ========================================================================

    /// @notice Random callers without harvest permissions cannot rebalance.
    function testFuzz_unauthorized_rebalance(address caller) public {
        vm.assume(caller != address(0));

        // Explicitly deny harvest permissions for this caller.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasHarvestPermissions.selector, caller),
            abi.encode(false)
        );

        LendingOptimizer.ReallocationAction[] memory actions =
            new LendingOptimizer.ReallocationAction[](3);
        actions[0] = LendingOptimizer.ReallocationAction(IBorrowableCToken(cUSDC_WMON_MARKET), int256(0));
        actions[1] = LendingOptimizer.ReallocationAction(IBorrowableCToken(cUSDC_WBTC_MARKET), int256(0));
        actions[2] = LendingOptimizer.ReallocationAction(IBorrowableCToken(cUSDC_WETH_MARKET), int256(0));

        vm.prank(caller);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__Unauthorized.selector);
        optimizer.rebalance(actions);
    }

    /// @notice Random callers without market permissions cannot setFee.
    function testFuzz_unauthorized_setFee(address caller) public {
        vm.assume(caller != address(0));

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, caller),
            abi.encode(false)
        );

        vm.prank(caller);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__Unauthorized.selector);
        optimizer.setFee(500);
    }

    /// @notice Random callers without market permissions cannot addApprovedAsset.
    function testFuzz_unauthorized_addApprovedAsset(address caller) public {
        vm.assume(caller != address(0));

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, caller),
            abi.encode(false)
        );

        vm.prank(caller);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__Unauthorized.selector);
        optimizer.addApprovedAsset(address(0x1234), 5000);
    }

    /// @notice Random callers without market permissions cannot removeApprovedAsset.
    function testFuzz_unauthorized_removeApprovedAsset(address caller) public {
        vm.assume(caller != address(0));

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, caller),
            abi.encode(false)
        );

        LendingOptimizer.ReallocationAction[] memory actions = new LendingOptimizer.ReallocationAction[](0);

        vm.prank(caller);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__Unauthorized.selector);
        optimizer.removeApprovedAsset(cUSDC_WMON_MARKET, actions);
    }

    /// @notice Random callers without market permissions cannot updateCap.
    function testFuzz_unauthorized_updateCap(address caller) public {
        vm.assume(caller != address(0));

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, caller),
            abi.encode(false)
        );

        vm.prank(caller);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__Unauthorized.selector);
        optimizer.updateCap(cUSDC_WMON_MARKET, 5000);
    }

    /// @notice Random callers without market permissions cannot setMintPaused.
    function testFuzz_unauthorized_setMintPaused(address caller) public {
        vm.assume(caller != address(0));

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, caller),
            abi.encode(false)
        );

        vm.prank(caller);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__Unauthorized.selector);
        optimizer.setMintPaused(true);
    }

    /// @notice Random callers without market permissions cannot initializeDeposits.
    function testFuzz_unauthorized_initializeDeposits(address caller) public {
        vm.assume(caller != address(0));

        // Deploy a fresh uninitialized optimizer to test initializeDeposits.
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        uint256[] memory caps = new uint256[](1);
        caps[0] = 10_000;

        LendingOptimizer freshOptimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            caps,
            1_000
        );

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, caller),
            abi.encode(false)
        );

        vm.prank(caller);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__Unauthorized.selector);
        freshOptimizer.initializeDeposits(cUSDC_WMON_MARKET);
    }

    // ========================================================================
    // DELEGATE WITHDRAWAL / ALLOWANCE TESTS
    // ========================================================================

    /// @notice Test delegate approval + withdrawal with fuzzed amounts.
    function testFuzz_delegateWithdrawal_allowance(
        uint256 allowance,
        uint256 withdrawAmount
    ) public {
        // First, deposit so user1 has shares.
        uint256 depositAmount = 10_000e6;
        deal(USDC_MONAD, user1, depositAmount);
        vm.startPrank(user1);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
        uint256 shares = optimizer.deposit(depositAmount, user1);
        vm.stopPrank();

        uint256 maxW = optimizer.maxWithdraw(user1);
        if (maxW == 0) return;

        withdrawAmount = bound(withdrawAmount, 1, maxW);

        // Calculate shares needed for this withdrawal.
        uint256 sharesNeeded = optimizer.previewWithdraw(withdrawAmount);
        if (sharesNeeded == 0) return;

        allowance = bound(allowance, 0, type(uint128).max);

        // user1 approves user2 to spend shares.
        vm.prank(user1);
        optimizer.approve(user2, allowance);

        // user2 tries to withdraw on behalf of user1.
        vm.startPrank(user2);
        if (allowance < sharesNeeded) {
            // Insufficient allowance should revert.
            vm.expectRevert();
            optimizer.withdraw(withdrawAmount, user2, user1);
        } else {
            // Sufficient allowance should succeed.
            uint256 user2BalBefore = IERC20(USDC_MONAD).balanceOf(user2);
            optimizer.withdraw(withdrawAmount, user2, user1);
            uint256 user2BalAfter = IERC20(USDC_MONAD).balanceOf(user2);

            assertEq(
                user2BalAfter - user2BalBefore,
                withdrawAmount,
                "Delegate should receive withdrawn assets"
            );
        }
        vm.stopPrank();
    }

    // ========================================================================
    // EDGE CASE TESTS
    // ========================================================================

    /// @notice Calling initializeDeposits twice should revert.
    function test_initializeDeposits_alreadyInitialized() public {
        // optimizer was already initialized in setUp via _setUpThreeMarkets.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        deal(USDC_MONAD, address(this), 77777);
        IERC20(USDC_MONAD).approve(address(optimizer), 77777);

        vm.expectRevert(LendingOptimizer.LendingOptimizer__AlreadyInitialized.selector);
        optimizer.initializeDeposits(cUSDC_WMON_MARKET);
    }

    /// @notice Zero amount deposit should revert (cToken rejects zero deposits).
    function testFuzz_zeroAmountDeposit() public {
        vm.startPrank(user1);
        deal(USDC_MONAD, user1, 1e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 1e6);

        vm.expectRevert();
        optimizer.deposit(0, user1);
        vm.stopPrank();
    }

    /// @notice Zero amount withdraw should revert (zero shares to burn).
    function testFuzz_zeroAmountWithdraw() public {
        // First deposit so user1 has shares.
        deal(USDC_MONAD, user1, 1_000e6);
        vm.startPrank(user1);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000e6);
        optimizer.deposit(1_000e6, user1);
        vm.stopPrank();

        vm.startPrank(user1);
        vm.expectRevert();
        optimizer.withdraw(0, user1, user1);
        vm.stopPrank();
    }

    /// @notice Depositing type(uint256).max should revert (transfer would fail).
    function testFuzz_maxUintDeposit() public {
        vm.startPrank(user1);
        IERC20(USDC_MONAD).approve(address(optimizer), type(uint256).max);

        vm.expectRevert();
        optimizer.deposit(type(uint256).max, user1);
        vm.stopPrank();
    }

    /// @notice A rebalance where all actions have zero amounts is a no-op.
    function test_rebalance_allZeroActions() public {
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

        // Deposit into all three markets so allocations are within caps.
        // Without this, all assets sit in market 0 (100% allocation > 60% cap)
        // and _verifyAllocationCaps() would revert on rebalance.
        deal(USDC_MONAD, address(this), 300_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 300_000e6);
        optimizer.deposit(150_000e6, address(this), cUSDC_WMON_MARKET);
        optimizer.deposit(100_000e6, address(this), cUSDC_WBTC_MARKET);
        optimizer.deposit(50_000e6, address(this), cUSDC_WETH_MARKET);

        uint256 totalAssetsBefore = optimizer.totalAssets();
        uint256 exchangeRateBefore = optimizer.exchangeRate();

        LendingOptimizer.ReallocationAction[] memory actions =
            new LendingOptimizer.ReallocationAction[](3);
        actions[0] = LendingOptimizer.ReallocationAction(IBorrowableCToken(cUSDC_WMON_MARKET), int256(0));
        actions[1] = LendingOptimizer.ReallocationAction(IBorrowableCToken(cUSDC_WBTC_MARKET), int256(0));
        actions[2] = LendingOptimizer.ReallocationAction(IBorrowableCToken(cUSDC_WETH_MARKET), int256(0));

        optimizer.rebalance(actions);

        uint256 totalAssetsAfter = optimizer.totalAssets();
        uint256 exchangeRateAfter = optimizer.exchangeRate();

        assertApproxEqAbs(
            totalAssetsAfter,
            totalAssetsBefore,
            2,
            "Total assets should not change on no-op rebalance"
        );
        assertGe(
            exchangeRateAfter,
            exchangeRateBefore,
            "Exchange rate should not decrease on no-op rebalance"
        );
    }
}
