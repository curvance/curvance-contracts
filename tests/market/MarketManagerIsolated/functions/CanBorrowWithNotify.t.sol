// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { MarketManagerIsolated, LiquidityManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { ICToken, AccountSnapshot } from "contracts/interfaces/ICToken.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";

contract CanBorrowWithNotifyTest is TestBaseMarketIsolated {
    function setUp() public override {
        super.setUp();

        mockWethFeed = new MockDataFeed(_CHAINLINK_ETH_USD);
        chainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            address(mockWethFeed),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            address(mockWethFeed),
            0,
            true
        );

        mockRethFeed = new MockDataFeed(_CHAINLINK_RETH_ETH);
        chainlinkAdaptor.addAsset(
            _RETH_ADDRESS,
            address(mockRethFeed),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _RETH_ADDRESS,
            address(mockRethFeed),
            0,
            true
        );

        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(strategyCBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));
    }

    function test_canBorrowWithNotify_fail_whenCallerIsNotCToken() public {
        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.canBorrowWithNotify(
            address(borrowableCUSDC),
            100e6,
            user1,
            100e6
        );
    }

    function test_canBorrowWithNotify_fail_whenCallerCTokenIsNotListedWithNoDebtCapSet()
        public
    {
        vm.prank(address(borrowableCDAI));

        vm.expectRevert(MarketManagerIsolated.MarketManager__CapReached.selector);
        marketManagerIsolated.canBorrowWithNotify(
            address(borrowableCDAI),
            100e6,
            user1,
            100e6
        );
    }

    function test_canBorrowWithNotify_fail_whenBorrowPaused() public {
        marketManagerIsolated.setBorrowPaused(address(borrowableCUSDC), true);

        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        marketManagerIsolated.canBorrowWithNotify(
            address(borrowableCUSDC),
            100e6,
            user1,
            100e6
        );
    }

    function test_canBorrowWithNotify_fail_whenCTokenIsNotListed() public {
        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.canBorrowWithNotify(
            address(borrowableCDAI),
            100e6,
            user1,
            100e6
        );
    }

    function test_canBorrowWithNotify_fail_whenCallerIsNotCTokenAndBorrowerNotInMarket()
        public
    {
        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.canBorrowWithNotify(
            address(borrowableCDAI),
            100e6,
            user1,
            100e6
        );
    }

    function test_canBorrowWithNotify_fail_whenExceedsBorrowCap() external {
        skip(gaugeManager.gaugeStartTime() - block.timestamp);
        chainlinkUsdcUsd.updateRoundData(0, 1e8, block.timestamp, block.timestamp);
        chainlinkUsdcEth.updateRoundData(0, 1e18, block.timestamp, block.timestamp);

        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 100e6 - 1);

        vm.expectRevert(MarketManagerIsolated.MarketManager__CapReached.selector);
        vm.prank(address(strategyCBALRETH));
        marketManagerIsolated.canBorrowWithNotify(
            address(strategyCBALRETH),
            100e6,
            user1,
            100e6
        );
    }

    function test_canBorrowWithNotify_fail_whenInsufficientCollateral() public {
        vm.warp(gaugeManager.gaugeStartTime());
        chainlinkUsdcUsd.updateRoundData(
            0,
            1e8,
            block.timestamp,
            block.timestamp
        );
        chainlinkUsdcEth.updateRoundData(
            0,
            1e18,
            block.timestamp,
            block.timestamp
        );

        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 10_000_000e6);

        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral.selector
        );
        marketManagerIsolated.canBorrowWithNotify(
            address(borrowableCUSDC),
            100e6,
            user1,
            100e6
        );
    }

    function test_canBorrowWithNotify_fail_whenInsufficientLoanSize() public {
        vm.warp(gaugeManager.gaugeStartTime());

        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);

        chainlinkEthUsd.updateRoundData(
            0,
            1500e8,
            block.timestamp,
            block.timestamp
        );
        chainlinkUsdcUsd.updateRoundData(
            0,
            1e8,
            block.timestamp,
            block.timestamp
        );
        chainlinkUsdcEth.updateRoundData(
            0,
            1500e18,
            block.timestamp,
            block.timestamp
        );

        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 10_000_000e6);

        _prepareBALRETH(user1, 1_000e18);

        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 1_000e18);
        strategyCBALRETH.deposit(10e18, user1);
        strategyCBALRETH.postCollateral(10e18);
        vm.stopPrank();

        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(LiquidityManagerIsolated.LiquidityManager__InsufficientLoanSize.selector);
        // borrow below the minimum loan size
        marketManagerIsolated.canBorrowWithNotify(
            address(borrowableCUSDC),
            1e6,
            user1,
            1e6
        );
    }

    function test_canBorrowWithNotify_success_atDebtCapLimit() external {
        skip(gaugeManager.gaugeStartTime() - block.timestamp);
        chainlinkUsdcUsd.updateRoundData(0, 1e8, block.timestamp, block.timestamp);
        chainlinkUsdcEth.updateRoundData(0, 1e18, block.timestamp, block.timestamp);

        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 100e6);

        _prepareBALRETH(user1, 1_000e18);
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 1_000e18);
        strategyCBALRETH.deposit(10e18, user1);
        strategyCBALRETH.postCollateral(10e18);
        vm.stopPrank();

        vm.prank(address(borrowableCUSDC));
        marketManagerIsolated.canBorrowWithNotify(
            address(borrowableCUSDC),
            100e6 - 1,
            user1,
            100e6 - 1
        );
    }

    function test_canBorrowWithNotify_successA() public {
        vm.warp(gaugeManager.gaugeStartTime());

        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);

        chainlinkEthUsd.updateRoundData(
            0,
            1500e8,
            block.timestamp,
            block.timestamp
        );
        chainlinkUsdcUsd.updateRoundData(
            0,
            1e8,
            block.timestamp,
            block.timestamp
        );
        chainlinkUsdcEth.updateRoundData(
            0,
            1500e18,
            block.timestamp,
            block.timestamp
        );

        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 10_000_000e6);

        _prepareBALRETH(user1, 1_000e18);

        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 1_000e18);
        strategyCBALRETH.deposit(10e18, user1);
        strategyCBALRETH.postCollateral(10e18);
        vm.stopPrank();

        vm.prank(address(borrowableCUSDC));

        // minimum loan size is 50e6
        marketManagerIsolated.canBorrowWithNotify(
            address(borrowableCUSDC),
            50e6,
            user1,
            50e6
        );
    
        uint256 cooldownTimestamp = marketManagerIsolated.accountAssets(user1);
        uint256 expectedCooldownTimestamp;
        assertEq(cooldownTimestamp, block.timestamp);

        vm.expectRevert(MarketManagerIsolated.MarketManager__MinimumHoldPeriod.selector);
        marketManagerIsolated.canRepay(address(borrowableCUSDC), user1);

        vm.warp(block.timestamp + 20 minutes);

        marketManagerIsolated.canRepay(address(borrowableCUSDC), user1);
   
    }

    function test_canBorrowWithNotify_success_withAuxiliaryDataReview() external {
        vm.warp(gaugeManager.gaugeStartTime());

        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);

        chainlinkEthUsd.updateRoundData(
            0,
            1500e8,
            block.timestamp,
            block.timestamp
        );
        chainlinkUsdcUsd.updateRoundData(
            0,
            1e8,
            block.timestamp,
            block.timestamp
        );
        chainlinkUsdcEth.updateRoundData(
            0,
            1e18,
            block.timestamp,
            block.timestamp
        );

        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 10_000_000e6);

        // Need some cTokens/collateral to have enough liquidity for borrowing
        _prepareBALRETH(user1, 10_000e18);
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 1_000e18);
        strategyCBALRETH.deposit(1_000e18, user1);
        strategyCBALRETH.postCollateral(999e18);
        vm.stopPrank();

        bool hasPosition;
        (hasPosition, , ) = auxiliaryData.tokenDataOf(user1, address(borrowableCUSDC));

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

        (hasPosition, , ) = auxiliaryData.tokenDataOf(user1, address(borrowableCUSDC));

        assertTrue(hasPosition);

        accountAssets = marketManagerIsolated.assetsOf(user1);
        assertEq(accountAssets.length, 2);
        assertEq(address(accountAssets[0]), address(strategyCBALRETH));
        assertEq(address(accountAssets[1]), address(borrowableCUSDC));
    }
}
