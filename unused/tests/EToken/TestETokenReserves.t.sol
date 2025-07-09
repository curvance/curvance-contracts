// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { BorrowableCTokenWithGauge } from "contracts/market/token/withGauge/BorrowableCTokenWithGauge.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract TestETokenReserves is TestBaseMarketIsolated {
    address public owner;
    address public dao;

    MockDataFeed public mockDaiFeed;
    MockDataFeed public mockWethFeed;
    MockDataFeed public mockRethFeed;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        super.setUp();

        owner = address(this);
        dao = address(this);

        // use mock pricing for testing
        mockDaiFeed = new MockDataFeed(_CHAINLINK_DAI_USD);
        chainlinkAdaptor.addAsset(_DAI_ADDRESS, address(mockDaiFeed), 0, true);
        dualChainlinkAdaptor.addAsset(
            _DAI_ADDRESS,
            address(mockDaiFeed),
            0,
            true
        );
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
            false
        );
        dualChainlinkAdaptor.addAsset(
            _RETH_ADDRESS,
            address(mockRethFeed),
            0,
            false
        );

        // start epoch
        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        mockDaiFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);

        (, int256 ethPrice, , , ) = mockWethFeed.latestRoundData();
        chainlinkEthUsd.updateAnswer(ethPrice);

        // deploy eDAI
        {
            // support market
            _prepareDAI(owner, 200000e18);
            dai.approve(address(borrowableCDAI), 200000e18);
            // add CToken support on oracle manager
            oracleManager.addCTokenSupport(address(borrowableCDAI));
        }

        // deploy pBALRETH
        {
            // support market
            _prepareBALRETH(owner, 1 ether);
            balRETH.approve(address(pBALRETH), 1 ether);
        }

        marketManagerIsolated.listTokens(address(pBALRETH), address(borrowableCDAI));

            // set collateral factor
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
            1000     // baseCFactor 20%
        );
        address[] memory tokens = new address[](1);
        tokens[0] = address(pBALRETH);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManagerIsolated.setCollateralCaps(tokens, caps);

        tokens[0] = address(borrowableCDAI);
        caps[0] = 100_000e18;
        marketManagerIsolated.setDebtCaps(tokens, caps);
    }

    function testInitialize() public {
        assertEq(centralRegistry.daoAddress(), dao);
        assertEq(borrowableCDAI.interestFactor(), (marketInterestFactor * 1e18) / 10000);
        assertEq(
            borrowableCDAI.interestFactor(),
            centralRegistry.protocolInterestFee(address(marketManagerIsolated))
        );
    }

    function testDaoInterestFromEToken() public {
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareDAI(liquidityProvider, 1000 ether);
        _prepareBALRETH(liquidityProvider, 10 ether);
        // mint eDAI
        vm.startPrank(liquidityProvider);
        dai.approve(address(borrowableCDAI), 1000 ether);
        borrowableCDAI.mint(1000 ether);
        vm.stopPrank();

        _prepareBALRETH(user1, 1 ether);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1 ether);
        pBALRETH.deposit(1 ether, user1);
        pBALRETH.postCollateral(1 ether - 1);

        // try borrow()
        borrowableCDAI.borrow(500 ether);
        vm.stopPrank();

        {
            // check accrue interest after 1 day
            uint256 exchangeRateBefore = borrowableCDAI.exchangeRate();
            uint256 totalReserves = borrowableCDAI.totalReserves();
            assertEq(totalReserves, 0);
            uint256 totalBorrowsBefore = borrowableCDAI.totalBorrows();
            assertEq(totalBorrowsBefore, 500 ether);
            uint256 daoBalanceBefore = borrowableCDAI.balanceOf(dao);
            uint256 daoGaugeBalanceBefore = gaugeManager.balanceOf(
                address(borrowableCDAI),
                dao
            );
            uint256 debtBalanceBefore = borrowableCDAI.debtBalance(user1);
            uint256 rateBefore = borrowableCDAI.convertToShares(1e18);

            // skip 1 day
            skip(24 hours);

            borrowableCDAI.accrueInterest();

            uint256 debt = ((borrowableCDAI.totalBorrows() - totalBorrowsBefore) *
                rateBefore) / 1e18;

            // check interest calculation from debt accrued
            assertEq(
                borrowableCDAI.totalReserves(),
                totalReserves + (debt * marketInterestFactor) / 10000
            );

            // check borrower debt increased
            assertEq(borrowableCDAI.balanceOf(user1), 0);
            assertEq(borrowableCDAI.debtBalance(user1), debtBalanceBefore + debt);
            assertGt(borrowableCDAI.exchangeRate(), exchangeRateBefore);

            // dao eDAI balance doesn't increase
            assertEq(borrowableCDAI.balanceOf(dao), daoBalanceBefore);

            // check gauge balance
            assertEq(
                gaugeManager.balanceOf(address(borrowableCDAI), dao),
                daoGaugeBalanceBefore + (debt * marketInterestFactor) / 10000
            );
        }

        {
            // check accrue interest after another day
            uint256 exchangeRateBefore = borrowableCDAI.exchangeRate();
            uint256 totalReserves = borrowableCDAI.totalReserves();
            uint256 totalBorrowsBefore = borrowableCDAI.totalBorrows();
            uint256 daoBalanceBefore = borrowableCDAI.balanceOf(dao);
            uint256 daoGaugeBalanceBefore = gaugeManager.balanceOf(
                address(borrowableCDAI),
                dao
            );
            uint256 debtBalanceBefore = borrowableCDAI.debtBalance(user1);
            uint256 rateBefore = borrowableCDAI.convertToShares(1e18);

            // skip 1 day
            skip(24 hours);

            borrowableCDAI.accrueInterest();

            uint256 debt = ((borrowableCDAI.totalBorrows() - totalBorrowsBefore) *
                rateBefore) / 1e18;

            // check interest calculation from debt accrued
            assertEq(
                borrowableCDAI.totalReserves(),
                totalReserves + (debt * marketInterestFactor) / 10000
            );

            // check borrower debt increased
            assertEq(borrowableCDAI.balanceOf(user1), 0);
            assertApproxEqRel(
                borrowableCDAI.debtBalance(user1),
                debtBalanceBefore + debt,
                1 ether
            );
            assertGt(borrowableCDAI.exchangeRate(), exchangeRateBefore);

            // dao eDAI balance doesn't increase
            assertEq(borrowableCDAI.balanceOf(dao), daoBalanceBefore);

            // check gauge balance
            assertEq(
                gaugeManager.balanceOf(address(borrowableCDAI), dao),
                daoGaugeBalanceBefore + (debt * marketInterestFactor) / 10000
            );
        }
    }

    function testDaoDepositReserves() public {
        testDaoInterestFromEToken();

        uint256 exchangeRate = borrowableCDAI.exchangeRate();
        uint256 totalReservesBefore = borrowableCDAI.totalReserves();
        uint256 gaugeBalanceBefore = gaugeManager.balanceOf(
            address(borrowableCDAI),
            dao
        );

        uint256 depositAmount = 100 ether;
        _prepareDAI(dao, depositAmount);
        vm.startPrank(dao);
        dai.approve(address(borrowableCDAI), depositAmount);
        borrowableCDAI.depositReserves(depositAmount);
        vm.stopPrank();

        assertEq(
            borrowableCDAI.totalReserves(),
            totalReservesBefore + (depositAmount * 1e18) / exchangeRate
        );
        assertEq(
            gaugeManager.balanceOf(address(borrowableCDAI), dao),
            gaugeBalanceBefore + (depositAmount * 1e18) / exchangeRate
        );
    }

    function testDaoWithdrawReserves() public {
        testDaoDepositReserves();

        {
            // withdraw half
            uint256 exchangeRate = borrowableCDAI.exchangeRate();
            uint256 totalReservesBefore = borrowableCDAI.totalReserves();
            uint256 daiBalanceBefore = dai.balanceOf(dao);
            uint256 gaugeBalanceBefore = gaugeManager.balanceOf(
                address(borrowableCDAI),
                dao
            );

            uint256 withdrawAmount = ((totalReservesBefore / 2) *
                exchangeRate) / 1e18;
            vm.prank(dao);
            borrowableCDAI.withdrawReserves(withdrawAmount);

            assertEq(
                borrowableCDAI.totalReserves(),
                totalReservesBefore - ((withdrawAmount * 1e18) / exchangeRate)
            );
            assertEq(
                gaugeManager.balanceOf(address(borrowableCDAI), dao),
                gaugeBalanceBefore - ((withdrawAmount * 1e18) / exchangeRate)
            );
            assertEq(dai.balanceOf(dao), daiBalanceBefore + withdrawAmount);
        }

        {
            // withdraw half
            uint256 exchangeRate = borrowableCDAI.exchangeRate();
            uint256 totalReservesBefore = borrowableCDAI.totalReserves();
            uint256 daiBalanceBefore = dai.balanceOf(dao);

            uint256 withdrawAmount = ((totalReservesBefore) * exchangeRate) /
                1e18;
            if ((withdrawAmount * 1e18) / exchangeRate < totalReservesBefore) {
                withdrawAmount += 1;
            }
            vm.prank(dao);
            borrowableCDAI.withdrawReserves(withdrawAmount);

            assertEq(borrowableCDAI.totalReserves(), 0);
            assertEq(gaugeManager.balanceOf(address(borrowableCDAI), dao), 0);
            assertEq(dai.balanceOf(dao), daiBalanceBefore + withdrawAmount);
        }
    }

    // Deploy BorrowableCToken
    function _deployBorrowableCToken(
        address token
    ) internal override initMainVariables returns (BorrowableCToken) {
        BorrowableCToken eToken = BorrowableCToken(
            address(
                new BorrowableCTokenWithGauge(
                    ICentralRegistry(address(centralRegistry)),
                    token,
                    address(marketManagerIsolated),
                    _deployDynamicInterestRateModel(token)
                )
            )
        );

        interestRateModels[block.chainid][token].setLinkedToken(
            address(eToken)
        );

        return eToken;
    }
}
