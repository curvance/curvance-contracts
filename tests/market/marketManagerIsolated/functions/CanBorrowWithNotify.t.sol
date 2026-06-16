// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { MarketManagerIsolated, LiquidityManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { ILiquidityManager } from "contracts/interfaces/ILiquidityManager.sol";
import { ICToken, AccountSnapshot } from "contracts/interfaces/ICToken.sol";
import { CAUTION, BAD_SOURCE } from "contracts/libraries/ConstantsLib.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";

contract CanBorrowWithNotifyTest is TestBaseMarketIsolated {
    function setUp() public override {
        super.setUp();

        mockUsdcFeed.setMockAnswer(1e8);
        mockWethFeed.setMockAnswer(1500e8);
        mockRethFeed.setMockAnswer(1500e8);
        _refreshMockFeeds();

        deal(address(LP_wstETH_24Dec2025), address(this), 77777);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(pendleStrategyCTokenSTETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 100e6);
    }

    function test_canBorrowWithNotify_fail_whenCallerIsNotCToken() public {
        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.canBorrowWithNotify(
            address(borrowableCUSDC),
            88e6,
            user1,
            88e6
        );
    }

    function test_canBorrowWithNotify_fail_whenCallerCTokenIsNotListedWithNoDebtCapSet()
        public
    {
        vm.prank(address(borrowableCDAI));

        vm.expectRevert(MarketManagerIsolated.MarketManager__CapReached.selector);
        marketManagerIsolated.canBorrowWithNotify(
            address(borrowableCDAI),
            88e6,
            user1,
            88e6
        );
    }

    function test_canBorrowWithNotify_fail_whenBorrowPaused() public {
        marketManagerIsolated.setBorrowPaused(address(borrowableCUSDC), true);

        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        marketManagerIsolated.canBorrowWithNotify(
            address(borrowableCUSDC),
            88e6,
            user1,
            88e6
        );
    }

    function test_canBorrowWithNotify_fail_whenCTokenIsNotListed() public {
        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.canBorrowWithNotify(
            address(borrowableCDAI),
            88e6,
            user1,
            88e6
        );
    }

    function test_canBorrowWithNotify_fail_whenCallerIsWrongCTokenAndNotListed()
        public
    {
        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.canBorrowWithNotify(
            address(borrowableCDAI),
            88e6,
            user1,
            88e6
        );
    }

    function test_canBorrowWithNotify_fail_whenExceedsBorrowCap() external {
        vm.prank(address(pendleStrategyCTokenSTETH));

        vm.expectRevert(MarketManagerIsolated.MarketManager__CapReached.selector);
        marketManagerIsolated.canBorrowWithNotify(
            address(pendleStrategyCTokenSTETH),
            100e6 + 1,
            user1,
            100e6 + 1
        );
    }

    function test_canBorrowWithNotify_fail_whenInsufficientCollateral() public {
        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral.selector
        );
        marketManagerIsolated.canBorrowWithNotify(
            address(borrowableCUSDC),
            88e6,
            user1,
            88e6
        );
    }

    function test_canBorrowWithNotify_fail_whenInsufficientLoanSize() public {
        deal(address(LP_wstETH_24Dec2025), user1, 1_000e18);

        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 1_000e18);
        pendleStrategyCTokenSTETH.deposit(10e18, user1);
        pendleStrategyCTokenSTETH.postCollateral(10e18);
        vm.stopPrank();

        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(LiquidityManagerIsolated.LiquidityManager__InsufficientLoanSize.selector);
        // Borrow below the minimum loan size.
        marketManagerIsolated.canBorrowWithNotify(
            address(borrowableCUSDC),
            1e6,
            user1,
            1e6
        );
    }

    function test_canBorrowWithNotify_success_atDebtCapLimit() external {
        deal(address(LP_wstETH_24Dec2025), user1, 1_000e18);

        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 1_000e18);
        pendleStrategyCTokenSTETH.deposit(10e18, user1);
        pendleStrategyCTokenSTETH.postCollateral(10e18);
        vm.stopPrank();

        vm.prank(address(borrowableCUSDC));
        marketManagerIsolated.canBorrowWithNotify(
            address(borrowableCUSDC),
            100e6 - 1,
            user1,
            100e6 - 1
        );
    }

    function test_canBorrowWithNotify_success_atLoanMinimumSize() public {
        deal(address(LP_wstETH_24Dec2025), user1, 1_000e18);

        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 1_000e18);
        pendleStrategyCTokenSTETH.deposit(10e18, user1);
        pendleStrategyCTokenSTETH.postCollateral(10e18);
        vm.stopPrank();

        vm.prank(address(borrowableCUSDC));

        // minimum loan size is 10e6
        marketManagerIsolated.canBorrowWithNotify(
            address(borrowableCUSDC),
            10e6,
            user1,
            10e6
        );
    
        uint256 cooldownTimestamp = marketManagerIsolated.accountAssets(user1);
        assertEq(cooldownTimestamp, block.timestamp);

        vm.expectRevert(MarketManagerIsolated.MarketManager__MinimumHoldPeriod.selector);
        vm.startPrank(address(borrowableCUSDC));
        marketManagerIsolated.canRepayWithReview(address(borrowableCUSDC), 10e6, address(usdc), 6, user1);
        vm.stopPrank();

        vm.warp(block.timestamp + 20 minutes);

        vm.startPrank(address(borrowableCUSDC));
        marketManagerIsolated.canRepayWithReview(address(borrowableCUSDC), 10e6, address(usdc), 6, user1);
        vm.stopPrank();
    }

    function test_canRepayWithReview_fail_whenPartialRepayDebtOracleInCaution()
        public
    {
        _openDebtPositionForRepayReview(user1, 10e6);
        _setUsdcDualFeedAnswer(1.016e8, CAUTION);

        vm.warp(block.timestamp + 20 minutes);

        vm.expectRevert(MarketManagerIsolated.MarketManager__PriceError.selector);
        vm.prank(address(borrowableCUSDC));
        marketManagerIsolated.canRepayWithReview(
            address(borrowableCUSDC),
            10e6,
            address(usdc),
            6,
            user1
        );
    }

    function test_canRepayWithReview_fail_whenPartialRepayDebtOracleIsStale()
        public
    {
        _openDebtPositionForRepayReview(user1, 10e6);
        _makeDefaultUsdcFeedsStale(BAD_SOURCE);

        vm.warp(block.timestamp + 20 minutes);

        vm.expectRevert(MarketManagerIsolated.MarketManager__PriceError.selector);
        vm.prank(address(borrowableCUSDC));
        marketManagerIsolated.canRepayWithReview(
            address(borrowableCUSDC),
            10e6,
            address(usdc),
            6,
            user1
        );
    }

    function test_canRepayWithReview_fail_whenFullRepayDuringCooldown()
        public
    {
        _openDebtPositionForRepayReview(user1, 10e6);

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__MinimumHoldPeriod.selector
        );
        vm.prank(address(borrowableCUSDC));
        marketManagerIsolated.canRepayWithReview(
            address(borrowableCUSDC),
            0,
            address(usdc),
            6,
            user1
        );
    }

    function test_canRepayWithReview_enforcesMinimumLoanSizeBoundary() public {
        _openDebtPositionForRepayReview(user1, 20e6);

        vm.warp(block.timestamp + 20 minutes);

        vm.prank(address(borrowableCUSDC));
        marketManagerIsolated.canRepayWithReview(
            address(borrowableCUSDC),
            10e6,
            address(usdc),
            6,
            user1
        );

        vm.expectRevert(
            LiquidityManagerIsolated
                .LiquidityManager__InsufficientLoanSize
                .selector
        );
        vm.prank(address(borrowableCUSDC));
        marketManagerIsolated.canRepayWithReview(
            address(borrowableCUSDC),
            10e6 - 1,
            address(usdc),
            6,
            user1
        );
    }

    function test_canRepayWithReview_usesDebtAssetPriceGuardForMinimumLoanSize()
        public
    {
        _openDebtPositionForRepayReview(user1, 20e6);

        chainlinkAdaptor.setGuardedPriceConfig(
            _USDC_ADDRESS,
            true,
            0,
            0,
            5e17,
            0
        );
        dualChainlinkAdaptor.setGuardedPriceConfig(
            _USDC_ADDRESS,
            true,
            0,
            0,
            5e17,
            0
        );

        (uint256 guardedPrice, uint256 errorCode) =
            oracleManager.getPrice(_USDC_ADDRESS, true, true);
        assertEq(errorCode, 0, "guarded USDC price should be clean");
        assertEq(guardedPrice, 5e17, "price guard must clamp runtime price");

        vm.warp(block.timestamp + 20 minutes);

        vm.expectRevert(
            LiquidityManagerIsolated
                .LiquidityManager__InsufficientLoanSize
                .selector
        );
        vm.prank(address(borrowableCUSDC));
        marketManagerIsolated.canRepayWithReview(
            address(borrowableCUSDC),
            10e6,
            address(usdc),
            6,
            user1
        );
    }

    function test_canRepayWithReview_success_fullRepayBypassesBadSourceDebtOracle()
        public
    {
        _openDebtPositionForRepayReview(user1, 10e6);
        _setUsdcDualFeedAnswer(1.03e8, BAD_SOURCE);

        vm.warp(block.timestamp + 20 minutes);

        vm.prank(address(borrowableCUSDC));
        marketManagerIsolated.canRepayWithReview(
            address(borrowableCUSDC),
            0,
            address(usdc),
            6,
            user1
        );
    }

    function test_canBorrowWithNotify_success_withProtocolReaderReview() external {
        deal(address(LP_wstETH_24Dec2025), user1, 10_000e18);

        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 100_000e6);

        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 1_000e18);
        pendleStrategyCTokenSTETH.deposit(1_000e18, user1);
        pendleStrategyCTokenSTETH.postCollateral(999e18);
        vm.stopPrank();

        bool hasPosition = ILiquidityManager(address(marketManagerIsolated))
            .accountPositions(address(borrowableCUSDC), user1) == 2;

        assertFalse(hasPosition);
        address[] memory accountAssets = marketManagerIsolated.assetsOf(user1);
        assertEq(accountAssets.length, 1);

        vm.prank(address(borrowableCUSDC));
        marketManagerIsolated.canBorrowWithNotify(
            address(borrowableCUSDC),
            1_000e6,
            user1,
            1_000e6
        );

        hasPosition = ILiquidityManager(address(marketManagerIsolated))
            .accountPositions(address(borrowableCUSDC), user1) == 2;

        assertTrue(hasPosition);

        accountAssets = marketManagerIsolated.assetsOf(user1);
        assertEq(accountAssets.length, 2);
        assertEq(address(accountAssets[0]), address(pendleStrategyCTokenSTETH));
        assertEq(address(accountAssets[1]), address(borrowableCUSDC));
    }

    function _openDebtPositionForRepayReview(
        address account,
        uint256 debtAmount
    ) internal {
        deal(address(LP_wstETH_24Dec2025), account, 1_000e18);

        vm.startPrank(account);
        LP_wstETH_24Dec2025.approve(
            address(pendleStrategyCTokenSTETH),
            1_000e18
        );
        pendleStrategyCTokenSTETH.deposit(10e18, account);
        pendleStrategyCTokenSTETH.postCollateral(10e18);
        vm.stopPrank();

        vm.prank(address(borrowableCUSDC));
        marketManagerIsolated.canBorrowWithNotify(
            address(borrowableCUSDC),
            debtAmount,
            account,
            debtAmount
        );
    }

    function _setUsdcDualFeedAnswer(
        int256 answer,
        uint256 expectedErrorCode
    ) internal {
        MockV3Aggregator usdcFeed = new MockV3Aggregator(8, answer);
        dualChainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            true,
            address(usdcFeed),
            0
        );

        (, uint256 errorCode) =
            oracleManager.getPrice(_USDC_ADDRESS, true, true);
        assertEq(errorCode, expectedErrorCode, "unexpected USDC oracle status");
    }

    function _makeDefaultUsdcFeedsStale(
        uint256 expectedErrorCode
    ) internal {
        uint256 staleTimestamp =
            block.timestamp - chainlinkAdaptor.DEFAULT_HEARTBEAT() - 1;
        mockUsdcFeed.setMockUpdatedAt(staleTimestamp);

        (, uint256 errorCode) =
            oracleManager.getPrice(_USDC_ADDRESS, true, true);
        assertEq(errorCode, expectedErrorCode, "unexpected stale USDC status");
    }
}
