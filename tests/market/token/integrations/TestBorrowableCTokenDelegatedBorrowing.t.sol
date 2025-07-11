// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { BorrowableCToken, IERC20 } from "contracts/market/token/BorrowableCToken.sol";
import { BorrowableCTokenWithGauge } from "contracts/market/token/withGauge/BorrowableCTokenWithGauge.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract TestBorrowableCTokenDelegatedBorrowing is TestBaseMarketIsolated {
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
            // Add cToken support on Oracle Manager.
            oracleManager.addCTokenSupport(address(borrowableCDAI));
        }

        // deploy strategyCBALRETH
        {
            // support market
            _prepareBALRETH(owner, 1 ether);
            balRETH.approve(address(strategyCBALRETH), 1 ether);
        }

        // First, list the tokens before updating position token parameters
        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCDAI));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(strategyCBALRETH);
        tokenConfig.collRatio = 7000;
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.minEffectiveCloseFactor = 2000;
        tokenConfig.maxEffectiveCloseFactor = 5000;
        tokenConfig.baseCFactor = 2000;
        tokenConfig.collateralCap = 100_000e18;
        tokenConfig.debtCap = 0;

        marketManagerIsolated.updateTokenConfig(tokenConfig);

        tokenConfig.cToken = address(borrowableCDAI);
        tokenConfig.debtCap = 100_000e18;
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function testInitialize() public {
        assertEq(centralRegistry.daoAddress(), dao);
        assertEq(borrowableCDAI.interestFee(), (marketInterestFactor * 1e18) / 10000);
        assertEq(
            borrowableCDAI.interestFee(),
            centralRegistry.protocolInterestFee(address(marketManagerIsolated))
        );
    }

    function testDelegatedBorrowing() public {
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareDAI(liquidityProvider, 1000 ether);
        _prepareBALRETH(liquidityProvider, 10 ether);
        // mint eDAI
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
        borrowableCDAI.borrowFor(user1, user2, 500 ether);

        assertEq(dai.balanceOf(user1), 0);
        assertEq(dai.balanceOf(user2), 500 ether);

        {
            // check accrue interest after 1 day
            uint256 exchangeRateBefore = borrowableCDAI.exchangeRate();
            uint256 totalBorrowsBefore = borrowableCDAI.marketOutstandingDebt();
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

            borrowableCDAI.accrueIfNeeded();

            uint256 debt = ((borrowableCDAI.marketOutstandingDebt() - totalBorrowsBefore) *
                rateBefore) / 1e18;

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

    // Deploy BorrowableCToken
    function _deployBorrowableCToken(
        address asset
    ) internal override initMainVariables returns (BorrowableCToken) {
        BorrowableCToken borrowableCToken = BorrowableCToken(
            address(
                new BorrowableCTokenWithGauge(
                    ICentralRegistry(address(centralRegistry)),
                    IERC20(asset),
                    address(marketManagerIsolated),
                    _deployDynamicInterestRateModel(asset)
                )
            )
        );

        interestRateModels[block.chainid][asset].setLinkedToken(
            address(borrowableCToken)
        );

        return borrowableCToken;
    }
}
