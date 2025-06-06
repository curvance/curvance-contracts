// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManagerIsolated } from "../TestBaseMarketManagerIsolated.sol";
import { LiquidityManager } from "contracts/market/LiquidityManager.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";
import { IMToken, AccountSnapshot } from "contracts/interfaces/IMToken.sol";

contract CanBorrowWithNotifyTest is TestBaseMarketManagerIsolated {
    function setUp() public override {
        super.setUp();

        deal(address(balRETH), address(this), 42069);
        balRETH.approve(address(pBALRETH), 42069);

        deal(address(_USDC_ADDRESS), address(this), 42069);
        usdc.approve(address(eUSDC), 42069);

        marketManager.listTokens(address(pBALRETH), address(eUSDC));
    }

    function test_canBorrowWithNotify_fail_whenCallerIsNotMToken() public {
        vm.expectRevert(MarketManager.MarketManager__Unauthorized.selector);
        marketManager.canBorrowWithNotify(address(eUSDC), user1, 100e6);
    }

    function test_canBorrowWithNotify_fail_whenCallerMTokenIsNotListed()
        public
    {
        vm.prank(address(eDAI));

        vm.expectRevert(MarketManager.MarketManager__TokenNotListed.selector);
        marketManager.canBorrowWithNotify(address(eDAI), user1, 100e6);
    }

    function test_canBorrowWithNotify_fail_whenBorrowPaused() public {
        marketManager.setBorrowPaused(address(eUSDC), true);

        vm.prank(address(eUSDC));

        vm.expectRevert(MarketManager.MarketManager__Paused.selector);
        marketManager.canBorrowWithNotify(address(eUSDC), user1, 100e6);
    }

    function test_canBorrowWithNotify_fail_whenMTokenIsNotListed() public {
        vm.prank(address(eUSDC));

        vm.expectRevert(MarketManager.MarketManager__Unauthorized.selector);
        marketManager.canBorrowWithNotify(address(eDAI), user1, 100e6);
    }

    function test_canBorrowWithNotify_fail_whenCallerIsNotMTokenAndBorrowerNotInMarket()
        public
    {
        vm.prank(address(eUSDC));

        vm.expectRevert(MarketManager.MarketManager__Unauthorized.selector);
        marketManager.canBorrowWithNotify(address(eDAI), user1, 100e6);
    }

    // function test_canBorrowWithNotify_fail_whenExceedsBorrowCap() external {
    //     skip(gaugeManager.gaugeStartTime() - block.timestamp);
    //     chainlinkUsdcUsd.updateRoundData(0, 1e8, block.timestamp, block.timestamp);
    //     chainlinkUsdcEth.updateRoundData(0, 1e18, block.timestamp, block.timestamp);

    //     address[] memory mTokens = new address[](1);
    //     uint256[] memory borrowCaps = new uint256[](1);
    //     mTokens[0] = address(pBALRETH);
    //     borrowCaps[0] = 100e6 - 1;

    //     marketManager.updatePositionToken(
    //         7000,    // collRatio 70%
    //         4000,    // collReqSoft 40%
    //         3000,    // collReqHard 25%
    //         1000,    // liqIncBase 10%
    //         1500,    // liqIncHard 15%
    //         500,     // liqIncMin 5%
    //         2000,    // liqIncMax 20%
    //         2000,    // minEffectiveCFactor 20%
    //         5000,    // maxEffectiveCFactor 50%
    //         2000     // baseCFactor 20%
    //     );

    //     marketManager.setPTokenCollateralCaps(mTokens, borrowCaps);

    //     vm.expectRevert();
    //     vm.prank(address(pBALRETH));
    //     marketManager.canBorrowWithNotify(address(pBALRETH), user1, 100e6);
    // }

    // function test_canBorrowWithNotify_success_whenCapNotExceeded() external {
    //     skip(gaugeManager.gaugeStartTime() - block.timestamp);
    //     chainlinkUsdcUsd.updateRoundData(0, 1e8, block.timestamp, block.timestamp);
    //     chainlinkUsdcEth.updateRoundData(0, 1e18, block.timestamp, block.timestamp);

    //     address[] memory mTokens = new address[](1);
    //     uint256[] memory borrowCaps = new uint256[](1);
    //     mTokens[0] = address(pBALRETH);
    //     borrowCaps[0] = 100e6;

    //     marketManager.listTokens(address(pBALRETH), address(eUSDC));

    //     marketManager.setPTokenCollateralCaps(
    //         mTokens,
    //         borrowCaps
    //     );

    //     vm.prank(address(pBALRETH));
    //     marketManager.canBorrowWithNotify(address(pBALRETH), user1, borrowCaps[0] - 1);
    // }

    function test_canBorrowWithNotify_fail_whenInsufficientLiquidity() public {
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

        vm.prank(address(eUSDC));

        vm.expectRevert(
            MarketManager.MarketManager__InsufficientCollateral.selector
        );
        marketManager.canBorrowWithNotify(address(eUSDC), user1, 100e6);
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

        marketManager.updatePositionToken(
            7000,    // collRatio 70%
            4000,    // collReqSoft 40%
            3000,    // collReqHard 25%
            1000,    // liqIncBase 10%
            1500,    // liqIncHard 15%
            500,     // liqIncMin 5%
            2000,    // liqIncMax 20%
            2000,    // minEffectiveCFactor 20%
            5000,    // maxEffectiveCFactor 50%
            2000     // baseCFactor 20%
        );

        address[] memory tokens = new address[](1);
        tokens[0] = address(pBALRETH);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManager.setPTokenCollateralCaps(tokens, caps);

        _prepareBALRETH(user1, 1_000e18);

        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1_000e18);
        pBALRETH.deposit(10e18, user1);
        marketManager.postCollateral(user1, address(pBALRETH), 10e18);
        vm.stopPrank();

        vm.prank(address(eUSDC));

        vm.expectRevert(LiquidityManager.LiquidityManager__InsufficientLoanSize.selector);
        // borrow below the minimum loan size
        marketManager.canBorrowWithNotify(address(eUSDC), user1, 10e6);
    }

    function test_canBorrowWithNotify_Success_whenSufficientLiquidity() public {
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

        marketManager.updatePositionToken(
            7000,    // collRatio 70%
            4000,    // collReqSoft 40%
            3000,    // collReqHard 25%
            1000,    // liqIncBase 10%
            1500,    // liqIncHard 15%
            500,     // liqIncMin 5%
            2000,    // liqIncMax 20%
            2000,    // minEffectiveCFactor 20%
            5000,    // maxEffectiveCFactor 50%
            2000     // baseCFactor 20%
        );

        address[] memory tokens = new address[](1);
        tokens[0] = address(pBALRETH);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManager.setPTokenCollateralCaps(tokens, caps);

        _prepareBALRETH(user1, 1_000e18);

        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1_000e18);
        pBALRETH.deposit(10e18, user1);
        marketManager.postCollateral(user1, address(pBALRETH), 10e18);
        vm.stopPrank();

        vm.prank(address(eUSDC));

        // minimum loan size is 50e6
        marketManager.canBorrowWithNotify(address(eUSDC), user1, 50e6);
    
        uint256 cooldownTimestamp = marketManager.accountAssets(user1);
        uint256 expectedCooldownTimestamp;
        assertEq(cooldownTimestamp, block.timestamp);

        vm.expectRevert(MarketManager.MarketManager__MinimumHoldPeriod.selector);
        marketManager.canRepay(address(eUSDC), user1);

        vm.warp(block.timestamp + 20 minutes);

        marketManager.canRepay(address(eUSDC), user1);
   
    }

    function test_canBorrowWithNotify_success_entersUserInMarket() external {
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

        // marketManager.listToken(address(pBALRETH));
        marketManager.updatePositionToken(
            7000,    // collRatio 70%
            4000,    // collReqSoft 40%
            3000,    // collReqHard 25%
            1000,    // liqIncBase 10%
            1500,    // liqIncHard 15%
            500,     // liqIncMin 5%
            2000,    // liqIncMax 20%
            2000,    // minEffectiveCFactor 20%
            5000,    // maxEffectiveCFactor 50%
            2000     // baseCFactor 20%
        );

        address[] memory tokens = new address[](1);
        tokens[0] = address(pBALRETH);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManager.setPTokenCollateralCaps(tokens, caps);

        // Need some PTokens/collateral to have enough liquidity for borrowing
        _prepareBALRETH(user1, 10_000e18);
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1_000e18);
        pBALRETH.deposit(1_000e18, user1);
        marketManager.postCollateral(user1, address(pBALRETH), 999e18);
        vm.stopPrank();

        bool hasPosition;
        (hasPosition, , ) = marketManager.tokenDataOf(user1, address(eUSDC));

        assertFalse(hasPosition);
        IMToken[] memory accountAssets = marketManager.assetsOf(user1);
        assertEq(accountAssets.length, 1);

        vm.prank(address(eUSDC));
        marketManager.canBorrowWithNotify(address(eUSDC), user1, 1_000e6);

        (hasPosition, , ) = marketManager.tokenDataOf(user1, address(eUSDC));

        assertTrue(hasPosition);

        accountAssets = marketManager.assetsOf(user1);
        assertEq(accountAssets.length, 2);
        assertEq(address(accountAssets[0]), address(pBALRETH));
        assertEq(address(accountAssets[1]), address(eUSDC));
    }
}
