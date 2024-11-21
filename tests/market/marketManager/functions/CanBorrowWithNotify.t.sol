// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManager } from "../TestBaseMarketManager.sol";
import { LiquidityManager } from "contracts/market/LiquidityManager.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";
import { IMToken, AccountSnapshot } from "contracts/interfaces/IMToken.sol";

contract CanBorrowWithNotifyTest is TestBaseMarketManager {
    event MarketEntered(address mToken, address account);

    function setUp() public override {
        super.setUp();

        marketManager.listToken(address(eUSDC));
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
        marketManager.listToken(address(eDAI));

        vm.prank(address(eUSDC));

        vm.expectRevert(MarketManager.MarketManager__Unauthorized.selector);
        marketManager.canBorrowWithNotify(address(eDAI), user1, 100e6);
    }

    // function test_canBorrowWithNotify_fail_whenExceedsBorrowCap() external {
    //     skip(gaugeManager.startTime() - block.timestamp);
    //     chainlinkUsdcUsd.updateRoundData(0, 1e8, block.timestamp, block.timestamp);
    //     chainlinkUsdcEth.updateRoundData(0, 1e18, block.timestamp, block.timestamp);

    //     IMToken[] memory mTokens = new IMToken[](1);
    //     uint256[] memory borrowCaps = new uint256[](1);
    //     mTokens[0] = IMToken(address(pBALRETH));
    //     borrowCaps[0] = 100e6 - 1;

    //     marketManager.listToken(address(pBALRETH));
    //     marketManager.setPTokenCollateralCaps(mTokens, borrowCaps);

    //     vm.expectRevert(MarketManager.MarketManager__BorrowCapReached.selector);
    //     vm.prank(address(pBALRETH));
    //     marketManager.canBorrowWithNotify(address(pBALRETH), user1, 100e6);
    // }

    // function test_canBorrowWithNotify_success_whenCapNotExceeded() external {
    //     skip(gaugeManager.startTime() - block.timestamp);
    //     chainlinkUsdcUsd.updateRoundData(0, 1e8, block.timestamp, block.timestamp);
    //     chainlinkUsdcEth.updateRoundData(0, 1e18, block.timestamp, block.timestamp);

    //     IMToken[] memory mTokens = new IMToken[](1);
    //     uint256[] memory borrowCaps = new uint256[](1);
    //     mTokens[0] = IMToken(address(pBALRETH));
    //     borrowCaps[0] = 100e6;

    //     marketManager.listToken(address(pBALRETH));
    //     marketManager.setPTokenCollateralCaps(mTokens, borrowCaps);

    //     vm.prank(address(pBALRETH));
    //     marketManager.canBorrowWithNotify(address(pBALRETH), user1, borrowCaps[0] - 1);
    // }

    function test_canBorrowWithNotify_fail_whenInsufficientLiquidity() public {
        vm.warp(gaugeManager.startTime());
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
        vm.warp(gaugeManager.startTime());

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

        marketManager.listToken(address(pBALRETH));
        marketManager.updatePositionToken(
            IMToken(address(pBALRETH)),
            7000,
            4000,
            3000,
            200,
            400,
            10,
            1000
        );

        address[] memory tokens = new address[](1);
        tokens[0] = address(pBALRETH);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManager.setPTokenCollateralCaps(tokens, caps);

        // Need some PTokens/collateral to have enough liquidity for borrowing
        deal(address(balRETH), user1, 1_000e18);
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 10e18);
        pBALRETH.deposit(10e18, user1);
        marketManager.postCollateral(user1, address(pBALRETH), 10e18);
        vm.stopPrank();

        vm.prank(address(eUSDC));

        vm.expectRevert(
            LiquidityManager.LiquidityManager__InsufficientLoanSize.selector
        );
        marketManager.canBorrowWithNotify(address(eUSDC), user1, 10e6);
    }

    function test_canBorrowWithNotify_success_whenSufficientLiquidity()
        public
    {
        vm.warp(gaugeManager.startTime());

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

        marketManager.listToken(address(pBALRETH));
        marketManager.updatePositionToken(
            IMToken(address(pBALRETH)),
            7000,
            4000,
            3000,
            200,
            400,
            10,
            1000
        );

        address[] memory tokens = new address[](1);
        tokens[0] = address(pBALRETH);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManager.setPTokenCollateralCaps(tokens, caps);

        // Need some PTokens/collateral to have enough liquidity for borrowing
        deal(address(balRETH), user1, 10_000e18);
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1_000e18);
        pBALRETH.deposit(1_000e18, user1);
        marketManager.postCollateral(user1, address(pBALRETH), 999e18);
        vm.stopPrank();

        vm.prank(address(eUSDC));
        marketManager.canBorrowWithNotify(address(eUSDC), user1, 100e6);
        uint256 cooldownTimestamp = marketManager.accountAssets(user1);
        assertEq(cooldownTimestamp, block.timestamp);

        AccountSnapshot memory snapshot = pBALRETH.getSnapshotPacked(user1);
        (uint256 price, ) = oracleManager.getPrice(
            pBALRETH.asset(),
            true,
            true
        );
        (, uint256 collRatio, , , , , , , ) = marketManager.tokenData(
            address(pBALRETH)
        );
        uint256 assetValue = (price *
            ((999e18 * snapshot.exchangeRate) / 1e18)) /
            10 ** pBALRETH.decimals();
        uint256 maxBorrow = (assetValue * collRatio) / 1e18;

        // max amount of USDC that can be borrowed based on provided collateral in pBALRETH
        uint256 borrowInUSDC = (maxBorrow / 10 ** pBALRETH.decimals()) *
            10 ** eUSDC.decimals();
        vm.prank(address(eUSDC));
        marketManager.canBorrowWithNotify(address(eUSDC), user1, borrowInUSDC);
        cooldownTimestamp = marketManager.accountAssets(user1);
        assertEq(cooldownTimestamp, block.timestamp);

        // should fail when borrowing more than is allowed by provided collateral
        vm.expectRevert(
            MarketManager.MarketManager__InsufficientCollateral.selector
        );
        vm.prank(address(eUSDC));
        marketManager.canBorrowWithNotify(
            address(eUSDC),
            user1,
            borrowInUSDC + 1e6
        );
    }

    function test_canBorrowWithNotify_success_entersUserInMarket() external {
        vm.warp(gaugeManager.startTime());

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

        marketManager.listToken(address(pBALRETH));
        marketManager.updatePositionToken(
            IMToken(address(pBALRETH)),
            7000,
            4000,
            3000,
            200,
            400,
            10,
            1000
        );

        address[] memory tokens = new address[](1);
        tokens[0] = address(pBALRETH);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManager.setPTokenCollateralCaps(tokens, caps);

        // Need some PTokens/collateral to have enough liquidity for borrowing
        deal(address(balRETH), user1, 10_000e18);
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
