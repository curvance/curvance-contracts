// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManagerIsolated } from "../TestBaseMarketManagerIsolated.sol";
import { MarketManagerIsolated, LiquidityManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { ICToken } from "contracts/interfaces/ICToken.sol";
import { AccountSnapshot } from "contracts/interfaces/ICToken.sol";

contract CanBorrowTest is TestBaseMarketManagerIsolated {
    function setUp() public override {
        super.setUp();

        // marketManager.listToken(address(borrowableCUSDC));
        skip(gaugeManager.gaugeStartTime() - block.timestamp);

        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);

        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(strategyCBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));
    }

    function test_canBorrow_fail_whenBorrowPaused() public {
        marketManagerIsolated.setBorrowPaused(address(borrowableCUSDC), true);

        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        marketManagerIsolated.canBorrow(address(borrowableCUSDC), user1, 100e6, 100e6);
    }

    function test_canBorrow_fail_whenCTokenIsNotListed() public {
        // marketManager.listToken(address(borrowableCDAI));

        vm.prank(address(borrowableCDAI));

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);

        marketManagerIsolated.canBorrow(address(borrowableCUSDC), user1, 100e6, 100e6);
    }

    function test_canBorrow_fail_whenCallerIsNotCTokenAndBorrowerNotInMarket()
        public
    {
        // marketManager.listToken(address(borrowableCDAI));

        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.canBorrow(address(borrowableCDAI), user1, 100e6, 100e6);
    }

    function test_canBorrow_fail_whenInsufficientLiquidity() public {
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
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);

        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral.selector
        );
        marketManagerIsolated.canBorrow(address(borrowableCUSDC), user1, 100e6, 100e6);
    }

    function test_canBorrow_fail_whenInsufficientLoanSize() public {
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
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);

        // Need some cTokens/collateral to have enough liquidity for borrowing
        _prepareBALRETH(user1, 1_000e18);
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 10e18);
        strategyCBALRETH.deposit(10e18, user1);
        strategyCBALRETH.postCollateral(10e18);
        vm.stopPrank();

        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(
            LiquidityManagerIsolated.LiquidityManager__InsufficientLoanSize.selector
        );
        marketManagerIsolated.canBorrow(address(borrowableCUSDC), user1, 10e6, 10e6);
    }

    function test_canBorrow_success_whenSufficientLiquidity() public {
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
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 2_000_000e6);

        // Need some cTokens/collateral to have enough liquidity for borrowing
        _prepareBALRETH(user1, 10_000e18);
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 1_000e18);
        strategyCBALRETH.deposit(1_000e18, user1);
        strategyCBALRETH.postCollateral(999e18);
        vm.stopPrank();

        vm.prank(address(borrowableCUSDC));
        marketManagerIsolated.canBorrow(address(borrowableCUSDC), user1, 100e6, 100e6);

        AccountSnapshot memory snapshot = strategyCBALRETH.getSnapshot(user1);
        (uint256 price, ) = oracleManager.getPrice(
            strategyCBALRETH.asset(),
            true,
            true
        );
        (, uint256 collRatio, , , , , , , , , , ) = marketManagerIsolated
            .tokenData(address(strategyCBALRETH));
            
        uint256 assetValue = (price *
            ((999e18 * snapshot.exchangeRate) / 1e18)) /
            10 ** strategyCBALRETH.decimals();
        uint256 maxBorrow = (assetValue * collRatio) / 1e18;

        // max amount of USDC that can be borrowed based on provided collateral in strategyCBALRETH
        uint256 borrowInUSDC = (maxBorrow / 10 ** strategyCBALRETH.decimals()) *
            10 ** borrowableCUSDC.decimals();
        vm.prank(address(borrowableCUSDC));
        marketManagerIsolated.canBorrow(address(borrowableCUSDC), user1, borrowInUSDC, borrowInUSDC);

        // should fail when borrowing more than is allowed by provided collateral
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral.selector
        );
        vm.prank(address(borrowableCUSDC));
        marketManagerIsolated.canBorrow(
            address(borrowableCUSDC),
            user1,
            borrowInUSDC + 1e6,
            borrowInUSDC + 1e6
        );
    }

    function test_canBorrow_fail_userCallsCanBorrow() external {
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

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.canBorrow(address(borrowableCUSDC), user1, 0, 0);
    }

    function test_canBorrow_success_entersUserInMarket() external {
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
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);

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
        marketManagerIsolated.canBorrow(address(borrowableCUSDC), user1, 1_000e6, 1_000e6);

        (hasPosition, , ) = auxiliaryData.tokenDataOf(user1, address(borrowableCUSDC));

        assertTrue(hasPosition);

        accountAssets = marketManagerIsolated.assetsOf(user1);
        assertEq(accountAssets.length, 2);
        assertEq(address(accountAssets[0]), address(strategyCBALRETH));
        assertEq(address(accountAssets[1]), address(borrowableCUSDC));
    }

    function test_canBorrow_fail_whenExceedsBorrowCap() external {
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
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);

        vm.expectRevert(MarketManagerIsolated.MarketManager__CapReached.selector);
        vm.prank(address(strategyCBALRETH));
        marketManagerIsolated.canBorrow(address(strategyCBALRETH), user1, 100e6, 100e6);
    }

    function test_canBorrow_success_whenCapNotExceeded() external {
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
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 10_000e6);

        _prepareBALRETH(user1, 1_000e18);
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 10e18);
        strategyCBALRETH.deposit(10e18, user1);
        strategyCBALRETH.postCollateral(10e18);
        vm.stopPrank();

        vm.prank(address(borrowableCUSDC));
        marketManagerIsolated.canBorrow(address(borrowableCUSDC), user1, 10_000e6 - 1, 10_000e6 - 1);
    }
}
