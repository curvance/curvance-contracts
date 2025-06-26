// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManagerIsolated } from "../TestBaseMarketManagerIsolated.sol";
import { MarketManagerIsolated, LiquidityManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { ICToken } from "contracts/interfaces/ICToken.sol";
import { AccountSnapshot } from "contracts/interfaces/ICToken.sol";

contract CanBorrowTest is TestBaseMarketManagerIsolated {
    function setUp() public override {
        super.setUp();

        // marketManager.listToken(address(eUSDC));
        skip(gaugeManager.gaugeStartTime() - block.timestamp);

        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);

        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(pBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(eUSDC), 77777);

        marketManagerIsolated.listTokens(address(pBALRETH), address(eUSDC));
    }

    function test_canBorrow_fail_whenBorrowPaused() public {
        marketManagerIsolated.setBorrowPaused(address(eUSDC), true);

        vm.prank(address(eUSDC));

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        marketManagerIsolated.canBorrow(address(eUSDC), user1, 100e6, 100e6);
    }

    function test_canBorrow_fail_whenMTokenIsNotListed() public {
        // marketManager.listToken(address(eDAI));

        vm.prank(address(eDAI));

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);

        marketManagerIsolated.canBorrow(address(eUSDC), user1, 100e6, 100e6);
    }

    function test_canBorrow_fail_whenCallerIsNotMTokenAndBorrowerNotInMarket()
        public
    {
        // marketManager.listToken(address(eDAI));

        vm.prank(address(eUSDC));

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.canBorrow(address(eDAI), user1, 100e6, 100e6);
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

        marketManagerIsolated.updatePositionToken(
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

        address[] memory mTokens = new address[](1);
        uint256[] memory caps = new uint256[](1);
        mTokens[0] = address(pBALRETH);
        caps[0] = 100e6 - 1;

        marketManagerIsolated.setCollateralCaps(mTokens, caps);

        mTokens[0] = address(eUSDC);
        caps[0] = 200e6;
        marketManagerIsolated.setDebtCaps(mTokens, caps);

        vm.prank(address(eUSDC));

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral.selector
        );
        marketManagerIsolated.canBorrow(address(eUSDC), user1, 100e6, 100e6);
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

        // marketManager.listToken(address(pBALRETH));
        marketManagerIsolated.updatePositionToken(
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
        marketManagerIsolated.setCollateralCaps(tokens, caps);

        tokens[0] = address(eUSDC);
        caps[0] = 200e6;
        marketManagerIsolated.setDebtCaps(tokens, caps);

        // Need some PTokens/collateral to have enough liquidity for borrowing
        _prepareBALRETH(user1, 1_000e18);
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 10e18);
        pBALRETH.deposit(10e18, user1);
        pBALRETH.postCollateral(10e18);
        vm.stopPrank();

        vm.prank(address(eUSDC));

        vm.expectRevert(
            LiquidityManagerIsolated.LiquidityManager__InsufficientLoanSize.selector
        );
        marketManagerIsolated.canBorrow(address(eUSDC), user1, 10e6, 10e6);
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

        // marketManager.listToken(address(pBALRETH));
        marketManagerIsolated.updatePositionToken(
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
        marketManagerIsolated.setCollateralCaps(tokens, caps);

        tokens[0] = address(eUSDC);
        caps[0] = 10_000_000e6;
        marketManagerIsolated.setDebtCaps(tokens, caps);

        // Need some PTokens/collateral to have enough liquidity for borrowing
        _prepareBALRETH(user1, 10_000e18);
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1_000e18);
        pBALRETH.deposit(1_000e18, user1);
        pBALRETH.postCollateral(999e18);
        vm.stopPrank();

        vm.prank(address(eUSDC));
        marketManagerIsolated.canBorrow(address(eUSDC), user1, 100e6, 100e6);

        AccountSnapshot memory snapshot = pBALRETH.getSnapshot(user1);
        (uint256 price, ) = oracleManager.getPrice(
            pBALRETH.asset(),
            true,
            true
        );
        (, uint256 collRatio, , , , , , , , , , ) = marketManagerIsolated
            .tokenData(address(pBALRETH));
            
        uint256 assetValue = (price *
            ((999e18 * snapshot.exchangeRate) / 1e18)) /
            10 ** pBALRETH.decimals();
        uint256 maxBorrow = (assetValue * collRatio) / 1e18;

        // max amount of USDC that can be borrowed based on provided collateral in pBALRETH
        uint256 borrowInUSDC = (maxBorrow / 10 ** pBALRETH.decimals()) *
            10 ** eUSDC.decimals();
        vm.prank(address(eUSDC));
        marketManagerIsolated.canBorrow(address(eUSDC), user1, borrowInUSDC, borrowInUSDC);

        // should fail when borrowing more than is allowed by provided collateral
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral.selector
        );
        vm.prank(address(eUSDC));
        marketManagerIsolated.canBorrow(
            address(eUSDC),
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
        marketManagerIsolated.canBorrow(address(eUSDC), user1, 0, 0);
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

        // marketManager.listToken(address(pBALRETH));
        marketManagerIsolated.updatePositionToken(
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
        marketManagerIsolated.setCollateralCaps(tokens, caps);

        tokens[0] = address(eUSDC);
        caps[0] = 1_000_000e6;
        marketManagerIsolated.setDebtCaps(tokens, caps);

        // Need some PTokens/collateral to have enough liquidity for borrowing
        _prepareBALRETH(user1, 10_000e18);
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1_000e18);
        pBALRETH.deposit(1_000e18, user1);
        pBALRETH.postCollateral(999e18);
        vm.stopPrank();

        bool hasPosition;
        (hasPosition, , ) = auxiliaryData.tokenDataOf(user1, address(eUSDC));

        assertFalse(hasPosition);
        address[] memory accountAssets = marketManagerIsolated.assetsOf(user1);
        assertEq(accountAssets.length, 1);

        vm.prank(address(eUSDC));
        marketManagerIsolated.canBorrow(address(eUSDC), user1, 1_000e6, 1_000e6);

        (hasPosition, , ) = auxiliaryData.tokenDataOf(user1, address(eUSDC));

        assertTrue(hasPosition);

        accountAssets = marketManagerIsolated.assetsOf(user1);
        assertEq(accountAssets.length, 2);
        assertEq(address(accountAssets[0]), address(pBALRETH));
        assertEq(address(accountAssets[1]), address(eUSDC));
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

        marketManagerIsolated.updatePositionToken(
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

        address[] memory mTokens = new address[](1);
        uint256[] memory caps = new uint256[](1);
        mTokens[0] = address(pBALRETH);
        caps[0] = 100e6 - 1;

        marketManagerIsolated.setCollateralCaps(mTokens, caps);

        mTokens[0] = address(eUSDC);
        caps[0] = 50e6;
        marketManagerIsolated.setDebtCaps(mTokens, caps);

        vm.expectRevert(MarketManagerIsolated.MarketManager__CapReached.selector);
        vm.prank(address(pBALRETH));
        marketManagerIsolated.canBorrow(address(pBALRETH), user1, 100e6, 100e6);
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

        marketManagerIsolated.updatePositionToken(
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

        address[] memory mTokens = new address[](1);
        uint256[] memory caps = new uint256[](1);
        mTokens[0] = address(pBALRETH);
        caps[0] = 100e18;

        marketManagerIsolated.setCollateralCaps(mTokens, caps);

        mTokens[0] = address(eUSDC);
        caps[0] = 10_000e6;
        marketManagerIsolated.setDebtCaps(mTokens, caps);

        _prepareBALRETH(user1, 1_000e18);
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 10e18);
        pBALRETH.deposit(10e18, user1);
        pBALRETH.postCollateral(10e18);
        vm.stopPrank();

        vm.prank(address(eUSDC));
        marketManagerIsolated.canBorrow(address(eUSDC), user1, caps[0] - 1, caps[0] - 1);
    }
}
