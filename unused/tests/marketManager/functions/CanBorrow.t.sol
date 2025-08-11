// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManager } from "../TestBaseMarketManager.sol";


import { IMToken, AccountSnapshot } from "contracts/interfaces/IMToken.sol";

contract CanBorrowTest is TestBaseMarketManager {
    function setUp() public override {
        super.setUp();

        marketManager.listToken(address(borrowableCUSDC));
        skip(gaugeManager.gaugeStartTime() - block.timestamp);

        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);
    }

    function test_canBorrow_fail_whenBorrowPaused() public {
        marketManager.setBorrowPaused(address(borrowableCUSDC), true);

        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(MarketManager.MarketManager__Paused.selector);
        marketManager.canBorrow(address(borrowableCUSDC), user1, 100e6);
    }

    function test_canBorrow_fail_whenMTokenIsNotListed() public {
        marketManager.listToken(address(borrowableCDAI));

        vm.prank(address(borrowableCDAI));

        vm.expectRevert(MarketManager.MarketManager__Unauthorized.selector);

        marketManager.canBorrow(address(borrowableCUSDC), user1, 100e6);
    }

    function test_canBorrow_fail_whenCallerIsNotMTokenAndBorrowerNotInMarket()
        public
    {
        marketManager.listToken(address(borrowableCDAI));

        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(MarketManager.MarketManager__Unauthorized.selector);
        marketManager.canBorrow(address(borrowableCDAI), user1, 100e6);
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

        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(
            MarketManager.MarketManager__InsufficientCollateral.selector
        );
        marketManager.canBorrow(address(borrowableCUSDC), user1, 100e6);
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

        marketManager.listToken(address(simpleCBALRETH));
        marketManager.updatePositionToken(
            address(simpleCBALRETH),
            7000,
            4000,
            3000,
            200,
            400,
            1000
        );
        address[] memory tokens = new address[](1);
        tokens[0] = address(simpleCBALRETH);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManager.setCollateralCaps(tokens, caps);

        // Need some PTokens/collateral to have enough liquidity for borrowing
        _prepareBALRETH(user1, 1_000e18);
        vm.startPrank(user1);
        balRETH.approve(address(simpleCBALRETH), 10e18);
        simpleCBALRETH.deposit(10e18, user1);
        simpleCBALRETH.postCollateral(10e18);
        vm.stopPrank();

        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(
            LiquidityManager.LiquidityManager__InsufficientLoanSize.selector
        );
        marketManager.canBorrow(address(borrowableCUSDC), user1, 10e6);
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

        marketManager.listToken(address(simpleCBALRETH));
        marketManager.updatePositionToken(
            address(simpleCBALRETH),
            7000,
            4000,
            3000,
            200,
            400,
            1000
        );
        address[] memory tokens = new address[](1);
        tokens[0] = address(simpleCBALRETH);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManager.setCollateralCaps(tokens, caps);

        // Need some PTokens/collateral to have enough liquidity for borrowing
        _prepareBALRETH(user1, 10_000e18);
        vm.startPrank(user1);
        balRETH.approve(address(simpleCBALRETH), 1_000e18);
        simpleCBALRETH.deposit(1_000e18, user1);
        simpleCBALRETH.postCollateral(999e18);
        vm.stopPrank();

        vm.prank(address(borrowableCUSDC));
        marketManager.canBorrow(address(borrowableCUSDC), user1, 100e6);

        AccountSnapshot memory snapshot = simpleCBALRETH.getSnapshot(user1);
        (uint256 price, ) = oracleManager.getPrice(
            simpleCBALRETH.asset(),
            true,
            true
        );
        (, uint256 collRatio, , , , , , ) = marketManager.tokenData(
            address(simpleCBALRETH)
        );
        uint256 assetValue = (price *
            ((999e18 * snapshot.exchangeRate) / 1e18)) /
            10 ** simpleCBALRETH.decimals();
        uint256 maxBorrow = (assetValue * collRatio) / 1e18;

        // max amount of USDC that can be borrowed based on provided collateral in simpleCBALRETH
        uint256 borrowInUSDC = (maxBorrow / 10 ** simpleCBALRETH.decimals()) *
            10 ** borrowableCUSDC.decimals();
        vm.prank(address(borrowableCUSDC));
        marketManager.canBorrow(address(borrowableCUSDC), user1, borrowInUSDC);

        // should fail when borrowing more than is allowed by provided collateral
        vm.expectRevert(
            MarketManager.MarketManager__InsufficientCollateral.selector
        );
        vm.prank(address(borrowableCUSDC));
        marketManager.canBorrow(
            address(borrowableCUSDC),
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
        marketManager.canBorrow(address(borrowableCUSDC), user1, 0);
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

        marketManager.listToken(address(simpleCBALRETH));
        marketManager.updatePositionToken(
            address(simpleCBALRETH),
            7000,
            4000,
            3000,
            200,
            400,
            1000
        );

        address[] memory tokens = new address[](1);
        tokens[0] = address(simpleCBALRETH);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManager.setCollateralCaps(tokens, caps);

        // Need some PTokens/collateral to have enough liquidity for borrowing
        _prepareBALRETH(user1, 10_000e18);
        vm.startPrank(user1);
        balRETH.approve(address(simpleCBALRETH), 1_000e18);
        simpleCBALRETH.deposit(1_000e18, user1);
        simpleCBALRETH.postCollateral(999e18);
        vm.stopPrank();

        bool hasPosition = ILiquidityManager(address(marketManagerIsolated))
            .accountPositions(address(borrowableCUSDC), user1) == 2;

        assertFalse(hasPosition);
        IMToken[] memory accountAssets = marketManager.assetsOf(user1);
        assertEq(accountAssets.length, 1);

        vm.prank(address(borrowableCUSDC));
        marketManager.canBorrow(address(borrowableCUSDC), user1, 1_000e6);

        hasPosition = ILiquidityManager(address(marketManagerIsolated))
            .accountPositions(address(borrowableCUSDC), user1) == 2;

        assertTrue(hasPosition);

        accountAssets = marketManager.assetsOf(user1);
        assertEq(accountAssets.length, 2);
        assertEq(address(accountAssets[0]), address(simpleCBALRETH));
        assertEq(address(accountAssets[1]), address(borrowableCUSDC));
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

    //     IMToken[] memory mTokens = new IMToken[](1);
    //     uint256[] memory borrowCaps = new uint256[](1);
    //     mTokens[0] = IMToken(address(simpleCBALRETH));
    //     borrowCaps[0] = 100e6 - 1;

    //     marketManager.listToken(address(simpleCBALRETH));
    //     marketManager.setCollateralCaps(mTokens, borrowCaps);

    //     vm.expectRevert(MarketManager.MarketManager__BorrowCapReached.selector);
    //     vm.prank(address(simpleCBALRETH));
    //     marketManager.canBorrow(address(simpleCBALRETH), user1, 100e6);
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

    //     IMToken[] memory mTokens = new IMToken[](1);
    //     uint256[] memory borrowCaps = new uint256[](1);
    //     mTokens[0] = IMToken(address(simpleCBALRETH));
    //     borrowCaps[0] = 100e6;

    //     marketManager.listToken(address(simpleCBALRETH));
    //     marketManager.setCollateralCaps(mTokens, borrowCaps);

    //     vm.prank(address(simpleCBALRETH));
    //     marketManager.canBorrow(address(simpleCBALRETH), user1, borrowCaps[0] - 1);
    // }
}
