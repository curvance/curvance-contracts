// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { LendingOptimizerHarness } from "../LendingOptimizerHarness.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract TestLendingOptimizerMarketPaused is TestBaseLendingOptimizer {

    address marketManagerWMON;
    address marketManagerWBTC;
    address marketManagerWETH;

    function setUp() public override {
        super.setUp();
        _setUpThreeMarkets();

        // Cache market manager addresses for mocking.
        marketManagerWMON = address(IBorrowableCToken(cUSDC_WMON_MARKET).marketManager());
        marketManagerWBTC = address(IBorrowableCToken(cUSDC_WBTC_MARKET).marketManager());
        marketManagerWETH = address(IBorrowableCToken(cUSDC_WETH_MARKET).marketManager());

        // Deposit to all markets so we have assets to work with.
        _depositToAllMarkets(10_000e6);
    }

    // ============ Helpers ============

    /// @dev Mocks mintPaused for a specific cToken market.
    function _mockMintPaused(address cToken, bool paused) internal {
        address mm = address(IBorrowableCToken(cToken).marketManager());
        vm.mockCall(
            mm,
            abi.encodeWithSelector(IMarketManager.actionsPaused.selector, cToken),
            abi.encode(paused, false, false)
        );
    }

    /// @dev Mocks redeemPaused on a market manager (market-wide).
    function _mockRedeemPaused(address mm, bool paused) internal {
        vm.mockCall(
            mm,
            abi.encodeWithSelector(bytes4(keccak256("redeemPaused()"))),
            abi.encode(paused ? uint8(2) : uint8(1))
        );
    }

    /// @dev Mocks harvest permissions for the caller.
    function _mockHarvestPermissions() internal {
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasHarvestPermissions.selector, address(this)),
            abi.encode(true)
        );
    }

    // ============ Auto-Routed Deposit Skips Paused Markets ============

    function test_lendingOptimizer_deposit_autoRoute_skipsPausedMarket() public {
        // Pause mint on the first market. Auto-route should skip it.
        _mockMintPaused(cUSDC_WMON_MARKET, true);

        uint256 wmonBalanceBefore = IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer));

        deal(USDC_MONAD, address(this), 1_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000e6);

        uint256 shares = optimizer.deposit(1_000e6, address(this));
        assertGt(shares, 0, "Auto-routed deposit should succeed");

        // The paused market should NOT have received the deposit.
        uint256 wmonBalanceAfter = IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer));
        assertEq(wmonBalanceAfter, wmonBalanceBefore, "Paused market should not receive deposit");
    }

    function test_lendingOptimizer_mint_autoRoute_skipsPausedMarket() public {
        // Pause mint on first market.
        _mockMintPaused(cUSDC_WMON_MARKET, true);

        uint256 wmonBalanceBefore = IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer));

        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);

        uint256 sharesToMint = optimizer.previewDeposit(1_000e6);
        uint256 assets = optimizer.mint(sharesToMint, address(this));
        assertGt(assets, 0, "Auto-routed mint should succeed");

        uint256 wmonBalanceAfter = IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer));
        assertEq(wmonBalanceAfter, wmonBalanceBefore, "Paused market should not receive mint");
    }

    function test_lendingOptimizer_deposit_autoRoute_allMintPaused_reverts() public {
        // Pause mint on ALL markets.
        _mockMintPaused(cUSDC_WMON_MARKET, true);
        _mockMintPaused(cUSDC_WBTC_MARKET, true);
        _mockMintPaused(cUSDC_WETH_MARKET, true);

        deal(USDC_MONAD, address(this), 1_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000e6);

        vm.expectRevert(LendingOptimizer.LendingOptimizer__MarketPaused.selector);
        optimizer.deposit(1_000e6, address(this));
    }

    // ============ Auto-Routed Withdraw Skips Paused Markets ============

    function test_lendingOptimizer_withdraw_autoRoute_skipsRedeemPaused() public {
        // Pause redeem on the WMON market manager.
        _mockRedeemPaused(marketManagerWMON, true);

        // Auto-routed withdraw should skip markets under the paused manager.
        uint256 assets = optimizer.withdraw(100e6, address(this), address(this));
        assertGt(assets, 0, "Auto-routed withdraw should succeed by skipping paused market");
    }

    function test_lendingOptimizer_redeem_autoRoute_skipsRedeemPaused() public {
        _mockRedeemPaused(marketManagerWMON, true);

        uint256 sharesToRedeem = optimizer.balanceOf(address(this)) / 10;
        uint256 assets = optimizer.redeem(sharesToRedeem, address(this), address(this));
        assertGt(assets, 0, "Auto-routed redeem should succeed by skipping paused market");
    }

    function test_lendingOptimizer_withdraw_autoRoute_allRedeemPaused_reverts() public {
        // Pause redeem on ALL market managers.
        _mockRedeemPaused(marketManagerWMON, true);
        _mockRedeemPaused(marketManagerWBTC, true);
        _mockRedeemPaused(marketManagerWETH, true);

        vm.expectRevert(LendingOptimizer.LendingOptimizer__InsufficientLiquidity.selector);
        optimizer.withdraw(100e6, address(this), address(this));
    }

    // ============ Rebalance Paused Tests ============

    function test_lendingOptimizer_rebalance_revert_withdrawFromPausedMarket() public {
        _mockHarvestPermissions();
        _mockRedeemPaused(marketManagerWETH, true);

        LendingOptimizer.ReallocationAction[] memory actions = new LendingOptimizer.ReallocationAction[](3);
        actions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WMON_MARKET),
            int256(1_000e6) // deposit
        );
        actions[1] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WBTC_MARKET),
            int256(0)
        );
        actions[2] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WETH_MARKET),
            -int256(1_000e6) // withdraw from paused market
        );

        LendingOptimizer.AllocationBound[] memory bounds = _unconstrainedBounds();
        vm.expectRevert(LendingOptimizer.LendingOptimizer__MarketPaused.selector);
        optimizer.rebalance(actions, bounds);
    }

    function test_lendingOptimizer_rebalance_revert_depositToPausedMarket() public {
        _mockHarvestPermissions();
        _mockMintPaused(cUSDC_WMON_MARKET, true);

        LendingOptimizer.ReallocationAction[] memory actions = new LendingOptimizer.ReallocationAction[](3);
        actions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WMON_MARKET),
            int256(1_000e6) // deposit to paused market
        );
        actions[1] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WBTC_MARKET),
            int256(0)
        );
        actions[2] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WETH_MARKET),
            -int256(1_000e6) // withdraw
        );

        LendingOptimizer.AllocationBound[] memory bounds = _unconstrainedBounds();
        vm.expectRevert(LendingOptimizer.LendingOptimizer__MarketPaused.selector);
        optimizer.rebalance(actions, bounds);
    }

    function test_lendingOptimizer_rebalance_success_zeroAmountOnPausedMarket() public {
        _mockHarvestPermissions();

        // First, bring allocations within caps. setUp deposited 10K to each
        // market (~33% each), but WETH only has a 20% cap.
        // Move excess from WETH into WMON so all markets are within caps.
        uint256 totalAssets = optimizer.totalAssets();
        uint256 wethAssets = IBorrowableCToken(cUSDC_WETH_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WETH_MARKET).balanceOf(address(optimizer))
        );
        // Target WETH at ~15% (under 20% cap).
        uint256 wethTarget = (totalAssets * 15) / 100;
        uint256 excessWeth = wethAssets - wethTarget;

        LendingOptimizer.ReallocationAction[] memory setupActions = new LendingOptimizer.ReallocationAction[](3);
        setupActions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WMON_MARKET), int256(excessWeth)
        );
        setupActions[1] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WBTC_MARKET), int256(0)
        );
        setupActions[2] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WETH_MARKET), -int256(excessWeth)
        );
        optimizer.rebalance(setupActions, _unconstrainedBounds());

        // Now pause mint on WETH market.
        _mockMintPaused(cUSDC_WETH_MARKET, true);

        // Rebalance between the two non-paused markets with 0 for the paused one.
        LendingOptimizer.ReallocationAction[] memory actions = new LendingOptimizer.ReallocationAction[](3);
        actions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WMON_MARKET),
            int256(1_000e6) // deposit
        );
        actions[1] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WBTC_MARKET),
            -int256(1_000e6) // withdraw
        );
        actions[2] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WETH_MARKET),
            int256(0) // no-op on paused market
        );

        // Should succeed — paused market is not touched.
        optimizer.rebalance(actions, _unconstrainedBounds());
    }

    // ============ Mixed Pause State Tests ============

    function test_lendingOptimizer_deposit_autoRoute_twoPausedOneActive() public {
        // Pause 2 out of 3 markets.
        _mockMintPaused(cUSDC_WMON_MARKET, true);
        _mockMintPaused(cUSDC_WBTC_MARKET, true);

        uint256 wethBalanceBefore = IBorrowableCToken(cUSDC_WETH_MARKET).balanceOf(address(optimizer));

        deal(USDC_MONAD, address(this), 1_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000e6);

        uint256 shares = optimizer.deposit(1_000e6, address(this));
        assertGt(shares, 0, "Should route to only active market");

        // Only the non-paused market should have received the deposit.
        uint256 wethBalanceAfter = IBorrowableCToken(cUSDC_WETH_MARKET).balanceOf(address(optimizer));
        assertGt(wethBalanceAfter, wethBalanceBefore, "Only active market should receive deposit");
    }

    function test_lendingOptimizer_rebalance_mixedPauseState() public {
        _mockHarvestPermissions();

        // Pause redeem on WETH market manager, pause mint on WMON market.
        _mockRedeemPaused(marketManagerWETH, true);
        _mockMintPaused(cUSDC_WMON_MARKET, true);

        // Try to withdraw from paused-redeem market → should revert.
        LendingOptimizer.ReallocationAction[] memory actions = new LendingOptimizer.ReallocationAction[](3);
        actions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WMON_MARKET),
            int256(0)
        );
        actions[1] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WBTC_MARKET),
            int256(1_000e6) // deposit
        );
        actions[2] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WETH_MARKET),
            -int256(1_000e6) // withdraw from redeem-paused market
        );

        LendingOptimizer.AllocationBound[] memory bounds = _unconstrainedBounds();
        vm.expectRevert(LendingOptimizer.LendingOptimizer__MarketPaused.selector);
        optimizer.rebalance(actions, bounds);
    }
}
