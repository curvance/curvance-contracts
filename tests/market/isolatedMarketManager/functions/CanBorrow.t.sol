// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManagerIsolated } from "../TestBaseMarketManagerIsolated.sol";
import { LiquidityManager } from "contracts/market/LiquidityManager.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";
import { IMToken, AccountSnapshot } from "contracts/interfaces/IMToken.sol";

contract CanBorrowTest is TestBaseMarketManagerIsolated {
    function setUp() public override {
        super.setUp();

        // marketManager.listToken(address(eUSDC));
        skip(gaugeManager.gaugeStartTime() - block.timestamp);

        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);

        deal(address(balRETH), address(this), 42069);
        balRETH.approve(address(pBALRETH), 42069);

        deal(address(_USDC_ADDRESS), address(this), 42069);
        usdc.approve(address(eUSDC), 42069);

        marketManager.listTokens(address(pBALRETH), address(eUSDC));
    }

    function test_canBorrow_fail_whenBorrowPaused() public {
        marketManager.setBorrowPaused(address(eUSDC), true);

        vm.prank(address(eUSDC));

        vm.expectRevert(MarketManager.MarketManager__Paused.selector);
        marketManager.canBorrow(address(eUSDC), user1, 100e6);
    }

    function test_canBorrow_fail_whenMTokenIsNotListed() public {
        // marketManager.listToken(address(eDAI));

        vm.prank(address(eDAI));

        vm.expectRevert(MarketManager.MarketManager__Unauthorized.selector);

        marketManager.canBorrow(address(eUSDC), user1, 100e6);
    }

    function test_canBorrow_fail_whenCallerIsNotMTokenAndBorrowerNotInMarket()
        public
    {
        // marketManager.listToken(address(eDAI));

        vm.prank(address(eUSDC));

        vm.expectRevert(MarketManager.MarketManager__Unauthorized.selector);
        marketManager.canBorrow(address(eDAI), user1, 100e6);
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

        vm.prank(address(eUSDC));

        vm.expectRevert(
            MarketManager.MarketManager__InsufficientCollateral.selector
        );
        marketManager.canBorrow(address(eUSDC), user1, 100e6);
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
        marketManager.setCollateralCaps(tokens, caps);

        // Need some PTokens/collateral to have enough liquidity for borrowing
        _prepareBALRETH(user1, 1_000e18);
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 10e18);
        pBALRETH.deposit(10e18, user1);
        pBALRETH.postCollateral(10e18);
        vm.stopPrank();

        vm.prank(address(eUSDC));

        vm.expectRevert(
            LiquidityManager.LiquidityManager__InsufficientLoanSize.selector
        );
        marketManager.canBorrow(address(eUSDC), user1, 10e6);
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
        marketManager.setCollateralCaps(tokens, caps);

        // Need some PTokens/collateral to have enough liquidity for borrowing
        _prepareBALRETH(user1, 10_000e18);
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1_000e18);
        pBALRETH.deposit(1_000e18, user1);
        pBALRETH.postCollateral(999e18);
        vm.stopPrank();

        vm.prank(address(eUSDC));
        marketManager.canBorrow(address(eUSDC), user1, 100e6);

        AccountSnapshot memory snapshot = pBALRETH.getSnapshotPacked(user1);
        (uint256 price, ) = oracleManager.getPrice(
            pBALRETH.asset(),
            true,
            true
        );
        (, uint256 collRatio, , , , , , , , , , ) = marketManager
            .tokenData(address(pBALRETH));
            
        uint256 assetValue = (price *
            ((999e18 * snapshot.exchangeRate) / 1e18)) /
            10 ** pBALRETH.decimals();
        uint256 maxBorrow = (assetValue * collRatio) / 1e18;

        // max amount of USDC that can be borrowed based on provided collateral in pBALRETH
        uint256 borrowInUSDC = (maxBorrow / 10 ** pBALRETH.decimals()) *
            10 ** eUSDC.decimals();
        vm.prank(address(eUSDC));
        marketManager.canBorrow(address(eUSDC), user1, borrowInUSDC);

        // should fail when borrowing more than is allowed by provided collateral
        vm.expectRevert(
            MarketManager.MarketManager__InsufficientCollateral.selector
        );
        vm.prank(address(eUSDC));
        marketManager.canBorrow(
            address(eUSDC),
            user1,
            borrowInUSDC + 1e6
        );
    }

    function test_canBorrow_fail_entersUserInMarket() external {
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

        vm.expectRevert(MarketManager.MarketManager__Unauthorized.selector);
        marketManager.canBorrow(address(eUSDC), user1, 0);
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
        marketManager.setCollateralCaps(tokens, caps);

        // Need some PTokens/collateral to have enough liquidity for borrowing
        _prepareBALRETH(user1, 10_000e18);
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1_000e18);
        pBALRETH.deposit(1_000e18, user1);
        pBALRETH.postCollateral(999e18);
        vm.stopPrank();

        bool hasPosition;
        (hasPosition, , ) = marketManager.tokenDataOf(user1, address(eUSDC));

        assertFalse(hasPosition);
        IMToken[] memory accountAssets = marketManager.assetsOf(user1);
        assertEq(accountAssets.length, 1);

        vm.prank(address(eUSDC));
        marketManager.canBorrow(address(eUSDC), user1, 1_000e6);

        (hasPosition, , ) = marketManager.tokenDataOf(user1, address(eUSDC));

        assertTrue(hasPosition);

        accountAssets = marketManager.assetsOf(user1);
        assertEq(accountAssets.length, 2);
        assertEq(address(accountAssets[0]), address(pBALRETH));
        assertEq(address(accountAssets[1]), address(eUSDC));
    }

    // function test_canBorrow_fail_whenExceedsBorrowCap() external {
    //     chainlinkUsdcUsd.updateRoundData(
    //         0,
    //         1e8,
    //         block.timestamp,
    //         block.timestamp
    //     );
    //     chainlinkUsdcEth.updateRoundData(
    //         0,
    //         1e18,
    //         block.timestamp,
    //         block.timestamp
    //     );

    //     address[] memory mTokens = new address[](1);
    //     uint256[] memory borrowCaps = new uint256[](1);
    //     mTokens[0] = address(pBALRETH);
    //     borrowCaps[0] = 100e6 - 1;

    //     marketManager.listTokens(address(pBALRETH), address(eUSDC));
    //     marketManager.setCollateralCaps(mTokens, borrowCaps);

    //     vm.expectRevert();
    //     vm.prank(address(pBALRETH));
    //     marketManager.canBorrow(address(pBALRETH), user1, 100e6);
    // }

    // function test_canBorrow_success_whenCapNotExceeded() external {
    //     chainlinkUsdcUsd.updateRoundData(
    //         0,
    //         1e8,
    //         block.timestamp,
    //         block.timestamp
    //     );
    //     chainlinkUsdcEth.updateRoundData(
    //         0,
    //         1e18,
    //         block.timestamp,
    //         block.timestamp
    //     );

    //     address[] memory mTokens = new address[](1);
    //     uint256[] memory borrowCaps = new uint256[](1);
    //     mTokens[0] = address(pBALRETH);
    //     borrowCaps[0] = 100e6;

    //     marketManager.listTokens(address(pBALRETH), address(eUSDC));
    //     marketManager.setCollateralCaps(mTokens, borrowCaps);

    //     vm.prank(address(pBALRETH));
    //     marketManager.canBorrow(address(pBALRETH), user1, borrowCaps[0] - 1);
    // }
}
