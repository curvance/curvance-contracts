// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { BorrowableCToken, IERC20 } from "contracts/market/token/BorrowableCToken.sol";
import { BorrowableCTokenWithGauge } from "contracts/market/token/withGauge/BorrowableCTokenWithGauge.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";

contract TestBorrowableCTokenDelegatedBorrowing is TestBaseMarketIsolated {
    address public owner;
    address public dao;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        super.setUp();

        owner = address(this);
        dao = address(this);

        // use mock pricing for testing
        mockDaiFeed = new MockDataFeed(_CHAINLINK_DAI_USD);
        chainlinkAdaptor.addAsset(
            _DAI_ADDRESS,
            true,
            address(mockDaiFeed),
            0
        );
        dualChainlinkAdaptor.addAsset(
            _DAI_ADDRESS,
            true,
            address(mockDaiFeed),
            0
        );
        mockWethFeed = new MockDataFeed(_CHAINLINK_ETH_USD);
        chainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            true,
            address(mockWethFeed),
            0
        );
        dualChainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            true,
            address(mockWethFeed),
            0
        );
        mockRethFeed = new MockDataFeed(_CHAINLINK_RETH_ETH);
        chainlinkAdaptor.addAsset(
            _RETH_ADDRESS,
            false,
            address(mockRethFeed),
            0
        );
        dualChainlinkAdaptor.addAsset(
            _RETH_ADDRESS,
            false,
            address(mockRethFeed),
            0
        );

        // start epoch
        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        mockDaiFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);

        (, int256 ethPrice, , , ) = mockWethFeed.latestRoundData();
        chainlinkEthUsd.updateAnswer(ethPrice);

        // Setup borrowable CDAI.
        {
            _prepareDAI(owner, 200000e18);
            dai.approve(address(borrowableCDAI), 200000e18);
            
        }

        // Setup strategyCBALRETH.
        {
            _prepareBALRETH(owner, 1 ether);
            balRETH.approve(address(strategyCBALRETH), 1 ether);
        }

        // List the tokens.
        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCDAI));

        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 100_000e18);
    }

    function testInitialize() public {
        assertEq(centralRegistry.daoAddress(), dao);
        assertEq(borrowableCDAI.interestFee(), 1000);
        assertEq(
            borrowableCDAI.interestFee(),
            centralRegistry.protocolInterestFee(address(marketManagerIsolated))
        );
    }

    function testDelegatedBorrowing() public {
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareDAI(liquidityProvider, 1000 ether);
        _prepareBALRETH(liquidityProvider, 10 ether);
        // Mint borrowable cDAI.
        vm.startPrank(liquidityProvider);
        dai.approve(address(borrowableCDAI), 1000 ether);
        borrowableCDAI.mint(1000 ether, liquidityProvider);
        vm.stopPrank();

        _prepareBALRETH(user1, 1 ether);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 1 ether);
        strategyCBALRETH.deposit(1 ether, user1);
        strategyCBALRETH.postCollateral(1 ether - 1);

        // delegate borrow
        borrowableCDAI.setDelegateApproval(user2, true);
        vm.stopPrank();

        // try borrow()
        vm.prank(user2);
        borrowableCDAI.borrowFor(500 ether, user2, user1);

        assertEq(dai.balanceOf(user1), 0, "user1 should have no dai");
        assertEq(dai.balanceOf(user2), 500 ether, "user2 should have 500 dai");

        {
            // check accrue interest after 1 day
            uint256 exchangeRateBefore = borrowableCDAI.exchangeRate();
            uint256 totalBorrowsBefore = borrowableCDAI.marketOutstandingDebt();
            assertEq(totalBorrowsBefore, 500 ether, "total borrows should be 500");
            uint256 daoBalanceBefore = borrowableCDAI.balanceOf(dao);
            uint256 daoGaugeBalanceBefore = gaugeManager.balanceOf(
                address(borrowableCDAI),
                dao
            );
            uint256 debtBalanceBefore = borrowableCDAI.debtBalance(user1);
            uint256 rateBefore = borrowableCDAI.convertToShares(1e18);

            // skip 1 day
            skip(24 hours);

            borrowableCDAI.accrueIfNeeded();

            uint256 debt = ((borrowableCDAI.marketOutstandingDebt() - totalBorrowsBefore) *
                rateBefore) / 1e18;

            // check borrower debt increased
            assertEq(borrowableCDAI.balanceOf(user1), 0, "user1 should have no cDAI");
            assertEq(borrowableCDAI.debtBalance(user1), debtBalanceBefore + debt, "user1 debt should increase");
            assertGt(borrowableCDAI.exchangeRate(), exchangeRateBefore, "exchange rate should increase");

            // dao eDAI balance SHOULD increase because of the interest accrued
            assertGt(borrowableCDAI.balanceOf(dao), daoBalanceBefore, "dao should have cDAI");

            // check gauge balance, should increase by the actual DAO balance increase
            assertEq(
                gaugeManager.balanceOf(address(borrowableCDAI), dao),
                daoGaugeBalanceBefore + (borrowableCDAI.balanceOf(dao) - daoBalanceBefore),
                "dao gauge balance should increase by actual DAO balance increase"
            );
        }

        {
            // check accrue interest after another day
            uint256 exchangeRateBefore = borrowableCDAI.exchangeRate();
            uint256 totalBorrowsBefore = borrowableCDAI.marketOutstandingDebt();
            uint256 daoBalanceBefore = borrowableCDAI.balanceOf(dao);
            uint256 daoGaugeBalanceBefore = gaugeManager.balanceOf(
                address(borrowableCDAI),
                dao
            );
            uint256 debtBalanceBefore = borrowableCDAI.debtBalance(user1);
            uint256 rateBefore = borrowableCDAI.convertToShares(1e18);

            // skip 1 day
            skip(24 hours);

            borrowableCDAI.accrueIfNeeded();

            uint256 debt = ((borrowableCDAI.marketOutstandingDebt() - totalBorrowsBefore) *
                rateBefore) / 1e18;

            // check borrower debt increased
            assertEq(borrowableCDAI.balanceOf(user1), 0, "user1 should have no cDAI");
            assertApproxEqRel(
                borrowableCDAI.debtBalance(user1),
                debtBalanceBefore + debt,
                1 ether
            );
            assertGt(borrowableCDAI.exchangeRate(), exchangeRateBefore, "exchange rate should increase");

            // dao eDAI balance should increase again because a new vesting period starts
            assertGt(borrowableCDAI.balanceOf(dao), daoBalanceBefore, "dao should have more cDAI from protocol fees");

            // check gauge balance
            assertEq(
                gaugeManager.balanceOf(address(borrowableCDAI), dao),
                daoGaugeBalanceBefore + (borrowableCDAI.balanceOf(dao) - daoBalanceBefore),
                "dao gauge balance should increase by actual DAO balance increase"
            );
        }
    }

    // Deploy BorrowableCToken.
    function _deployBorrowableCToken(
        address asset
    ) internal override initMainVariables returns (BorrowableCToken) {
        BorrowableCToken borrowableCToken = BorrowableCToken(
            address(
                new BorrowableCTokenWithGauge(
                    ICentralRegistry(address(centralRegistry)),
                    IERC20(asset),
                    address(marketManagerIsolated),
                    _deployDynamicIRM(asset)
                )
            )
        );

        IRMs[block.chainid][asset].setLinkedToken(
            address(borrowableCToken)
        );

        return borrowableCToken;
    }
}
