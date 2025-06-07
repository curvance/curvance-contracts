// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { EToken } from "contracts/market/token/EToken.sol";
import { ETokenWithGauge } from "contracts/market/token/withGauge/ETokenWithGauge.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract TestETokenDelegatedBorrowing is TestBaseMarketIsolated {
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
            dai.approve(address(eDAI), 200000e18);
            marketManagerIsolated.listToken(address(eDAI));
            // add MToken support on oracle manager
            oracleManager.addMTokenSupport(address(eDAI));
        }

        // deploy pBALRETH
        {
            // support market
            _prepareBALRETH(owner, 1 ether);
            balRETH.approve(address(pBALRETH), 1 ether);
            marketManagerIsolated.listToken(address(pBALRETH));
            // set collateral factor
            marketManagerIsolated.updatePositionToken(
                address(pBALRETH),
                5000,
                1500,
                1200,
                200,
                400,
                1000
            );
            address[] memory tokens = new address[](1);
            tokens[0] = address(pBALRETH);
            uint256[] memory caps = new uint256[](1);
            caps[0] = 100_000e18;
            marketManagerIsolated.setCollateralCaps(tokens, caps);
        }
    }

    function testInitialize() public {
        assertEq(centralRegistry.daoAddress(), dao);
        assertEq(eDAI.interestFactor(), (marketInterestFactor * 1e18) / 10000);
        assertEq(
            eDAI.interestFactor(),
            centralRegistry.protocolInterestFactor(address(marketManagerIsolated))
        );
    }

    function testDelegatedBorrowing() public {
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareDAI(liquidityProvider, 1000 ether);
        _prepareBALRETH(liquidityProvider, 10 ether);
        // mint eDAI
        vm.startPrank(liquidityProvider);
        dai.approve(address(eDAI), 1000 ether);
        eDAI.mint(1000 ether);
        vm.stopPrank();

        _prepareBALRETH(user1, 1 ether);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1 ether);
        pBALRETH.deposit(1 ether, user1);
        pBALRETH.postCollateral(1 ether - 1);

        // delegate borrow
        eDAI.setDelegateApproval(user2, true);
        vm.stopPrank();

        // try borrow()
        vm.prank(user2);
        eDAI.borrowFor(user1, user2, 500 ether);

        assertEq(dai.balanceOf(user1), 0);
        assertEq(dai.balanceOf(user2), 500 ether);

        {
            // check accrue interest after 1 day
            uint256 exchangeRateBefore = eDAI.exchangeRateCached();
            uint256 totalReserves = eDAI.totalReserves();
            assertEq(totalReserves, 0);
            uint256 totalBorrowsBefore = eDAI.totalBorrows();
            assertEq(totalBorrowsBefore, 500 ether);
            uint256 daoBalanceBefore = eDAI.balanceOf(dao);
            uint256 daoGaugeBalanceBefore = gaugeManager.balanceOf(
                address(eDAI),
                dao
            );
            uint256 debtBalanceBefore = eDAI.debtBalanceCached(user1);
            uint256 rateBefore = eDAI.convertToShares(1e18);

            // skip 1 day
            skip(24 hours);

            eDAI.accrueInterest();

            uint256 debt = ((eDAI.totalBorrows() - totalBorrowsBefore) *
                rateBefore) / 1e18;

            // check interest calculation from debt accrued
            assertEq(
                eDAI.totalReserves(),
                totalReserves + (debt * marketInterestFactor) / 10000
            );

            // check borrower debt increased
            assertEq(eDAI.balanceOf(user1), 0);
            assertEq(eDAI.debtBalanceCached(user1), debtBalanceBefore + debt);
            assertGt(eDAI.exchangeRateCached(), exchangeRateBefore);

            // dao eDAI balance doesn't increase
            assertEq(eDAI.balanceOf(dao), daoBalanceBefore);

            // check gauge balance
            assertEq(
                gaugeManager.balanceOf(address(eDAI), dao),
                daoGaugeBalanceBefore + (debt * marketInterestFactor) / 10000
            );
        }

        {
            // check accrue interest after another day
            uint256 exchangeRateBefore = eDAI.exchangeRateCached();
            uint256 totalReserves = eDAI.totalReserves();
            uint256 totalBorrowsBefore = eDAI.totalBorrows();
            uint256 daoBalanceBefore = eDAI.balanceOf(dao);
            uint256 daoGaugeBalanceBefore = gaugeManager.balanceOf(
                address(eDAI),
                dao
            );
            uint256 debtBalanceBefore = eDAI.debtBalanceCached(user1);
            uint256 rateBefore = eDAI.convertToShares(1e18);

            // skip 1 day
            skip(24 hours);

            eDAI.accrueInterest();

            uint256 debt = ((eDAI.totalBorrows() - totalBorrowsBefore) *
                rateBefore) / 1e18;

            // check interest calculation from debt accrued
            assertEq(
                eDAI.totalReserves(),
                totalReserves + (debt * marketInterestFactor) / 10000
            );

            // check borrower debt increased
            assertEq(eDAI.balanceOf(user1), 0);
            assertApproxEqRel(
                eDAI.debtBalanceCached(user1),
                debtBalanceBefore + debt,
                1 ether
            );
            assertGt(eDAI.exchangeRateCached(), exchangeRateBefore);

            // dao eDAI balance doesn't increase
            assertEq(eDAI.balanceOf(dao), daoBalanceBefore);

            // check gauge balance
            assertEq(
                gaugeManager.balanceOf(address(eDAI), dao),
                daoGaugeBalanceBefore + (debt * marketInterestFactor) / 10000
            );
        }
    }

    // Deploy ETokenWithGauge
    function _deployEToken(
        address token
    ) internal override initMainVariables returns (EToken) {
        EToken eToken = EToken(
            address(
                new ETokenWithGauge(
                    ICentralRegistry(address(centralRegistry)),
                    token,
                    address(marketManagerIsolated),
                    _deployDynamicInterestRateModel(token)
                )
            )
        );

        interestRateModels[block.chainid][token].setLinkedEToken(
            address(eToken)
        );

        return eToken;
    }
}
