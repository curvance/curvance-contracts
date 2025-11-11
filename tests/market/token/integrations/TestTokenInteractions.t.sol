// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { ICToken } from "contracts/interfaces/ICToken.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { LiquidityManagerIsolated } from "contracts/market/isolated/LiquidityManagerIsolated.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { WAD_SQUARED, WAD } from "contracts/libraries/ConstantsLib.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { console2 } from "forge-std/console2.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract TestTokenInteractions is TestBaseMarketIsolated {
    address public owner;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        super.setUp();
    }

    function testTokenInteractions_cTokenMintRedeem() public {
        _deployMarket();

        deal(address(LP_wstETH_24Dec2025), user1, 2e18);

        // try mint()
        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE);
        pendleStrategyCTokenSTETH.mint(_ONE, user1);
        assertEq(pendleStrategyCTokenSTETH.balanceOf(user1), _ONE);

        // try mint to another user
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE);
        pendleStrategyCTokenSTETH.mint(_ONE, user2);
        assertEq(pendleStrategyCTokenSTETH.balanceOf(user1), _ONE);
        assertEq(pendleStrategyCTokenSTETH.balanceOf(user2), _ONE);

        // try redeem()
        pendleStrategyCTokenSTETH.redeem(_ONE, user1, user1);
        vm.stopPrank();
        assertEq(pendleStrategyCTokenSTETH.balanceOf(user1), 0);
    }

    function testTokenInteractions_borrowableCTokenMintRedeem() public {
        _deployMarket();

        _prepareDAI(user1, 2e18);

        // try mint()
        vm.startPrank(user1);
        dai.approve(address(borrowableCDAI), _ONE);
        borrowableCDAI.mint(_ONE, user1);
        assertEq(borrowableCDAI.balanceOf(user1), _ONE);

        // try mint to another user
        dai.approve(address(borrowableCDAI), _ONE);
        borrowableCDAI.mint(_ONE, user2);
        assertEq(borrowableCDAI.balanceOf(user1), _ONE);
        assertEq(borrowableCDAI.balanceOf(user2), _ONE);

        // try redeem()
        borrowableCDAI.redeem(_ONE, address(this), user1);
        vm.stopPrank();
        assertEq(borrowableCDAI.balanceOf(user1), 0);
    }

    function testTokenInteractions_borrowableCTokenBorrowRepay() public {
        _deployMarket();
        deal(address(LP_wstETH_24Dec2025), user1, _ONE);

        // try mint(), successfully.
        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE);
        pendleStrategyCTokenSTETH.deposit(_ONE, user1);
        pendleStrategyCTokenSTETH.postCollateral(_ONE);

        assertEq(pendleStrategyCTokenSTETH.balanceOf(user1), _ONE);
        assertEq(pendleStrategyCTokenSTETH.exchangeRate(), _ONE);

        uint256 priceDecimals = mockDaiFeed.decimals();
        (, int256 daiPrice, , , ) = mockDaiFeed.latestRoundData();

        uint256 minimumBorrowAmount = (marketManagerIsolated.MIN_LOAN_SIZE() *
            (10 ** priceDecimals)) / uint256(daiPrice);

        // try borrow() with insufficient loan size.
        vm.expectRevert(
            LiquidityManagerIsolated.LiquidityManager__InsufficientLoanSize.selector
        );
        borrowableCDAI.borrow(minimumBorrowAmount - 1, user1);

        // try borrow(), successfully.
        borrowableCDAI.borrow(minimumBorrowAmount, user1);

        assertEq(borrowableCDAI.balanceOf(user1), 0);
        assertEq(borrowableCDAI.debtBalance(user1), minimumBorrowAmount);
        assertEq(borrowableCDAI.exchangeRate(), _ONE);

        // try adding another borrow(), successfully.
        skip(1200);
        borrowableCDAI.borrow(100e18, user1);

        assertEq(borrowableCDAI.balanceOf(user1), 0);
        assertGt(borrowableCDAI.debtBalance(user1), minimumBorrowAmount + 100e18);
        assertGt(borrowableCDAI.exchangeRate(), _ONE);

        // skip min hold period
        skip(20 minutes);

        // try partial repay().
        uint256 borrowBalanceBefore = borrowableCDAI.debtBalance(user1);
        uint256 exchangeRateBefore = borrowableCDAI.exchangeRate();
        _prepareDAI(user1, 20e18);
        dai.approve(address(borrowableCDAI), 20e18);
        borrowableCDAI.repay(20e18);

        assertEq(borrowableCDAI.balanceOf(user1), 0);
        assertGt(borrowableCDAI.debtBalance(user1), borrowBalanceBefore - 20e18);
        assertGt(borrowableCDAI.exchangeRate(), exchangeRateBefore);

        // skip some time.
        skip(1200);

        borrowBalanceBefore = borrowableCDAI.debtBalance(user1);
        _prepareDAI(user1, borrowBalanceBefore);
        dai.approve(address(borrowableCDAI), borrowBalanceBefore);
        // try repay(), resulting in insufficient loan size from accrued
        // interest dust remaining.
        vm.expectRevert(
            LiquidityManagerIsolated.LiquidityManager__InsufficientLoanSize.selector
        );
        borrowableCDAI.repay(borrowBalanceBefore);

        // try full repay(), including all new interest accrued in loan.
        borrowBalanceBefore = borrowableCDAI.debtBalanceUpdated(user1);
        exchangeRateBefore = borrowableCDAI.exchangeRate();
        _prepareDAI(user1, borrowBalanceBefore);
        dai.approve(address(borrowableCDAI), borrowBalanceBefore);
        borrowableCDAI.repay(0);
        vm.stopPrank();

        assertEq(borrowableCDAI.balanceOf(user1), 0);
        assertEq(borrowableCDAI.debtBalance(user1), 0);
        assertGt(borrowableCDAI.exchangeRate(), exchangeRateBefore);
    }

    function testTokenInteractions_cTokenRedeemOnBorrow() public {
        _deployMarket();
        deal(address(LP_wstETH_24Dec2025), user1, _ONE);

        // try mint()
        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE);
        pendleStrategyCTokenSTETH.deposit(_ONE, user1);
        pendleStrategyCTokenSTETH.postCollateral(_ONE);

        // try borrow()
        borrowableCDAI.borrow(500e18, user1);

        // skip min hold period
        skip(20 minutes);

        // can't redeem full
        vm.expectRevert(
            bytes4(keccak256("MarketManager__InsufficientCollateral()"))
        );
        pendleStrategyCTokenSTETH.redeem(_ONE, user1, user1);

        // can redeem partially
        pendleStrategyCTokenSTETH.redeem(0.2e18, user1, user1);
        vm.stopPrank();

        assertEq(pendleStrategyCTokenSTETH.balanceOf(user1), 0.8e18);
        assertEq(pendleStrategyCTokenSTETH.exchangeRate(), _ONE);
    }

    function testTokenInteractions_borrowableCTokenRedeemOnBorrow() public {
        _deployMarket();
        // try mint()
        deal(address(LP_wstETH_24Dec2025), user1, _ONE);
        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE);
        pendleStrategyCTokenSTETH.deposit(_ONE, user1);
        pendleStrategyCTokenSTETH.postCollateral(_ONE);

        // try mint()
        _prepareDAI(user1, 1000e18);
        dai.approve(address(borrowableCDAI), 1000e18);
        borrowableCDAI.mint(1000e18, user1);

        // try borrow()
        borrowableCDAI.borrow(500e18, user1);

        // fail to redeem before minimum hold time pass
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__MinimumHoldPeriod.selector
        );
        borrowableCDAI.redeem(1000e18, address(this), user1);

        // skip min hold period
        skip(20 minutes);

        // can redeem fully
        borrowableCDAI.redeem(1000e18, address(this), user1);
        vm.stopPrank();

        assertEq(pendleStrategyCTokenSTETH.balanceOf(user1), _ONE);
        assertEq(pendleStrategyCTokenSTETH.exchangeRate(), _ONE);

        assertEq(borrowableCDAI.balanceOf(user1), 0);
        assertGt(borrowableCDAI.debtBalance(user1), 500e18);
        assertGt(borrowableCDAI.exchangeRate(), _ONE);
    }

    function testTokenInteractions_cTokenTransferOnBorrow() public {
        _deployMarket();
        deal(address(LP_wstETH_24Dec2025), user1, _ONE);

        // try mint()
        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE);
        pendleStrategyCTokenSTETH.deposit(_ONE, user1);
        pendleStrategyCTokenSTETH.postCollateral(_ONE);

        // try borrow()
        borrowableCDAI.borrow(500e18, user1);

        // skip min hold period
        skip(20 minutes);

        // can't transfer full
        vm.expectRevert(
            bytes4(keccak256("MarketManager__InsufficientCollateral()"))
        );
        pendleStrategyCTokenSTETH.transfer(user2, _ONE);

        // can redeem partially
        pendleStrategyCTokenSTETH.transfer(user2, 0.2e18);
        vm.stopPrank();

        assertEq(pendleStrategyCTokenSTETH.balanceOf(user1), 0.8e18);
        assertEq(pendleStrategyCTokenSTETH.balanceOf(user2), 0.2e18);
        assertEq(pendleStrategyCTokenSTETH.exchangeRate(), _ONE);
    }

    function testTokenInteractions_borrowableCTokenTransferOnBorrow() public {
        _deployMarket();
        // try mint()
        deal(address(LP_wstETH_24Dec2025), user1, _ONE);
        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE);
        pendleStrategyCTokenSTETH.deposit(_ONE, user1);
        pendleStrategyCTokenSTETH.postCollateral(_ONE);

        // try mint()
        _prepareDAI(user1, 1000e18);
        dai.approve(address(borrowableCDAI), 1000e18);
        borrowableCDAI.deposit(1000e18, user1);

        // try borrow()
        borrowableCDAI.borrow(500e18, user1);

        // skip min hold period
        skip(20 minutes);

        // try full transfer
        borrowableCDAI.transfer(user2, 1000e18);
        vm.stopPrank();

        assertEq(pendleStrategyCTokenSTETH.balanceOf(user1), _ONE);
        assertEq(pendleStrategyCTokenSTETH.exchangeRate(), _ONE);

        assertEq(borrowableCDAI.balanceOf(user1), 0);
        // accrueIfNeeded is called in transfer, so debt balance is increased
        assertGt(borrowableCDAI.debtBalance(user1), 500e18, "debt balance is increased because of interest");

        assertEq(borrowableCDAI.balanceOf(user2), 1000e18);
        assertEq(borrowableCDAI.debtBalance(user2), 0e18);
        assertGt(borrowableCDAI.exchangeRate(), _ONE, "debt token exchange rate is increased because of interest");
    }

    function testTokenInteractions_liquidationExact() public {
        _deployMarket();

        deal(address(LP_wstETH_24Dec2025), user1, _ONE);

        // try mint()
        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE);
        pendleStrategyCTokenSTETH.deposit(_ONE, user1);
        pendleStrategyCTokenSTETH.postCollateral(_ONE);

        // try borrow()
        borrowableCDAI.borrow(5000e18, user1);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);

        mockDaiFeed.setMockAnswer(2e8);
        mockDaiFeed.setMockUpdatedAt(block.timestamp);

        uint256 currentDebtBalance = borrowableCDAI.debtBalanceUpdated(user1);  

        ExpectedLiquidationValues memory expectedLiquidationValues = _calculateExpectedLiquidationValues(
            LiquidationParams({
                borrower: user1,
                collateralToken: address(pendleStrategyCTokenSTETH),
                borrowedToken: address(borrowableCDAI),
                isLiquidateExact: true,
                liquidateExactAmount: 250e18,
                isAuction: false,
                isMultiMarketTest: false,
                marketManagerId: 0
            })
        );

        // try liquidate half
        _prepareDAI(user2, 250e18);
        vm.startPrank(user2);
        dai.approve(address(borrowableCDAI), 250e18);
        address[] memory accounts = new address[](1);
        accounts[0] = user1;
        uint256[] memory debtAmounts = new uint256[](1);
        debtAmounts[0] = 250e18;
        borrowableCDAI.liquidateExact(
            debtAmounts,
            accounts,
            address(pendleStrategyCTokenSTETH));
        vm.stopPrank();

        _assertCollateralSeizure(_ONE, expectedLiquidationValues.collateralLiquidated);
        assertEq(pendleStrategyCTokenSTETH.exchangeRate(), _ONE);

        assertEq(borrowableCDAI.balanceOf(user1), 0);

        _assertDebtReduction(250e18, expectedLiquidationValues.badDebt, currentDebtBalance);

        assertLt(borrowableCDAI.exchangeRate(), _ONE, "exchange rate should lower because of bad debt");
    }

    function testTokenInteractions_liquidation() public {
        _deployMarket();

        deal(address(LP_wstETH_24Dec2025), user1, _ONE);

        // try mint()
        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE);
        pendleStrategyCTokenSTETH.deposit(_ONE, user1);
        pendleStrategyCTokenSTETH.postCollateral(_ONE); 

        // try borrow()
        borrowableCDAI.borrow(5000e18, user1);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);

        mockDaiFeed.setMockAnswer(2e8);
        mockDaiFeed.setMockUpdatedAt(block.timestamp);

        ExpectedLiquidationValues memory expectedLiquidationValues = _calculateExpectedLiquidationValues(
            LiquidationParams({
                borrower: user1,
                collateralToken: address(pendleStrategyCTokenSTETH),
                borrowedToken: address(borrowableCDAI),
                isLiquidateExact: false,
                liquidateExactAmount: 0,
                isAuction: false,
                isMultiMarketTest: false,
                marketManagerId: 0
            })
        );

        // try liquidate
        _prepareDAI(user2, 10_000e18);
        vm.startPrank(user2);
        dai.approve(address(borrowableCDAI), 10_000e18);
        address[] memory accounts = new address[](1);
        accounts[0] = user1;

        borrowableCDAI.liquidate(accounts, address(pendleStrategyCTokenSTETH));
        vm.stopPrank();

        _assertCollateralSeizure(_ONE, expectedLiquidationValues.collateralLiquidated);

        assertEq(pendleStrategyCTokenSTETH.exchangeRate(), _ONE);
        assertEq(borrowableCDAI.balanceOf(user1), 0);
        assertEq(borrowableCDAI.debtBalance(user1), 0);
        assertLt(borrowableCDAI.exchangeRate(), _ONE, "exchange rate should lower because of bad debt");
    }

    function testTokenInteractions_liquidationWithFullValueLoss() public {
        _deployMarket();

        deal(address(LP_wstETH_24Dec2025), user1, _ONE);

        // try mint()
        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE);
        pendleStrategyCTokenSTETH.deposit(_ONE, user1);
        pendleStrategyCTokenSTETH.postCollateral(_ONE);

        // try borrow()
        borrowableCDAI.borrow(1000e18, user1);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);

        mockDaiFeed.setMockAnswer(10e8);

        // try liquidate
        _prepareDAI(user2, 10_000e18);
        vm.startPrank(user2);
        dai.approve(address(borrowableCDAI), 10_000e18);
        address[] memory accounts = new address[](1);
        accounts[0] = user1;
        borrowableCDAI.liquidate(
            accounts,
            address(pendleStrategyCTokenSTETH));
        vm.stopPrank();

        assertEq(pendleStrategyCTokenSTETH.balanceOf(user1), 0);

        assertEq(borrowableCDAI.balanceOf(user1), 0);
        assertApproxEqRel(borrowableCDAI.debtBalance(user1), 0, 1000);
        assertLt(borrowableCDAI.exchangeRateUpdated(), _ONE);
    }

    function testTokenInteractions_softLiquidation() public {
        _deployMarket();

        deal(address(LP_wstETH_24Dec2025), user1, _ONE);

        // try mint()
        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE);
        pendleStrategyCTokenSTETH.deposit(_ONE, user1);
        pendleStrategyCTokenSTETH.postCollateral(_ONE);

        // try borrow()
        borrowableCDAI.borrow(4000e18, user1);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);

        mockDaiFeed.setMockAnswer(1.9e8);
        mockDaiFeed.setMockUpdatedAt(block.timestamp);

        uint256 debtBefore = borrowableCDAI.debtBalanceUpdated(user1);
        console2.log("debtBefore", debtBefore);
        console2.log("collateralBefore", pendleStrategyCTokenSTETH.balanceOf(user1));

        ExpectedLiquidationValues memory expectedLiquidationValues = _calculateExpectedLiquidationValues(
            LiquidationParams({
                borrower: user1,
                collateralToken: address(pendleStrategyCTokenSTETH),
                borrowedToken: address(borrowableCDAI),
                isLiquidateExact: false,
                liquidateExactAmount: 0,
                isAuction: false,
                isMultiMarketTest: false,
                marketManagerId: 0
            })
        );

        // try liquidate
        _prepareDAI(user2, 2300e18);
        vm.startPrank(user2);
        dai.approve(address(borrowableCDAI), 2300e18);

        address[] memory accounts = new address[](1);
        accounts[0] = user1;

        borrowableCDAI.liquidate(
            accounts,
            address(pendleStrategyCTokenSTETH));
        vm.stopPrank();

        assertEq(
            pendleStrategyCTokenSTETH.balanceOf(user1), 
            _ONE - expectedLiquidationValues.collateralLiquidated,
            "pendleStrategyCTokenSTETH balance of user1 should be reduced by collateral liquidated"
        );
        assertEq(pendleStrategyCTokenSTETH.exchangeRate(), _ONE, "pendleStrategyCTokenSTETH exchange rate should be 1");

        assertEq(borrowableCDAI.balanceOf(user1), 0, "borrowableCDAI balance of user1 should be 0");
        assertApproxEqRel(borrowableCDAI.debtBalance(user1), debtBefore - expectedLiquidationValues.debtRepaid, 0.01e18, "borrowableCDAI debt balance should be reduced by debt repaid");
        assertGt(borrowableCDAI.exchangeRate(), _ONE, "borrowableCDAI exchange rate should higher because of interest accrued");
    }

    function testTokenInteractions_revertBorrowAndLiquidateWithZeroCollRatio() public {
        _deployMarketForZeroCollateralTest();

        _setCTokenConfigCollateralOff(address(pendleStrategyCTokenSTETH), 0);

        deal(address(LP_wstETH_24Dec2025), user1, _ONE);

        // try mint()
        vm.startPrank(user1);

        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE);
        pendleStrategyCTokenSTETH.deposit(_ONE, user1);

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__CapReached.selector
        );
        pendleStrategyCTokenSTETH.postCollateral(_ONE);

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral.selector
        );
        borrowableCDAI.borrow(1000e18, user1);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);

        mockDaiFeed.setMockAnswer(1.5e8);

        // try liquidate
        _prepareDAI(user2, 10_000e18);
        vm.startPrank(user2);
        dai.approve(address(borrowableCDAI), 10_000e18);

        address[] memory accounts = new address[](1);
        accounts[0] = user1;

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InvalidParameter.selector
        );
        borrowableCDAI.liquidate(
            accounts,
            address(pendleStrategyCTokenSTETH));
        vm.stopPrank();

        vm.prank(user1);
        pendleStrategyCTokenSTETH.withdraw(_ONE, user1, user1);
    }

    function _assertDebtReduction(uint256 debtAmount, uint256 expectedBadDebt, uint256 debtBalancesPreLiquidation) internal view {
        uint256 debtAfter = borrowableCDAI.debtBalance(user1);

        // bad debt expected

        console2.log("debtAmount + expectedBadDebt", debtAmount + expectedBadDebt);
        console2.log("debtBalancesPreLiquidation", debtBalancesPreLiquidation);
        console2.log("debtAfter", debtAfter);

        uint256 expectedDebtAfter = debtBalancesPreLiquidation - (debtAmount + expectedBadDebt);

        console2.log("expectedBadDebt", expectedBadDebt);

        assertApproxEqAbs(
            debtAfter,
            expectedDebtAfter, 
            1000,
            "Debt reduction should include bad debt"
        );
    }

    function _assertCollateralSeizure(uint256 _collateralAmount, uint256 collateralLiquidated) internal view {

        console2.log("collateralAmount", _collateralAmount);
        console2.log("collateralLiquidated", collateralLiquidated);
        console2.log("borrowerCollateralAfter", pendleStrategyCTokenSTETH.balanceOf(user1));

        uint256 borrowerCollateralAfter = pendleStrategyCTokenSTETH.balanceOf(user1);
        uint256 expectedBorrowerCollateralAfter = _collateralAmount - collateralLiquidated;

        assertApproxEqAbs(
            borrowerCollateralAfter,
            expectedBorrowerCollateralAfter,
            1000,
            "Borrower collateral should be reduced by collateralLiquidated"
        );
    }

    function _deployMarket() internal {
        owner = address(this);

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
        mockBalEthRethFeed = new MockDataFeed(_CHAINLINK_RETH_ETH);
        chainlinkAdaptor.addAsset(
            _BAL_WETH_RETH_ADDRESS,
            false,
            address(mockBalEthRethFeed),
            0
        );
        dualChainlinkAdaptor.addAsset(
            _BAL_WETH_RETH_ADDRESS,
            false,
            address(mockBalEthRethFeed),
            0
        );

        // start epoch
        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        _refreshMockFeeds();

        (, int256 ethPrice, , , ) = mockBalEthRethFeed.latestRoundData();
        chainlinkEthUsd.updateAnswer(ethPrice);

        console2.log("ethPrice", ethPrice);

        // Setup borrowable CDAI.
        {
            _prepareDAI(owner, 200_000e18);
            dai.approve(address(borrowableCDAI), 200_000e18);
        }

        // Setup pendleStrategyCTokenSTETH.
        {
            deal(address(LP_wstETH_24Dec2025), owner, _ONE);
            LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE);
        }

        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(borrowableCDAI));

        _setCTokenConfigBasic(address(pendleStrategyCTokenSTETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 100_000e18);

        // provide enough liquidity
        _provideEnoughLiquidityForLeverage();
    }

    function _deployMarketForZeroCollateralTest() internal {
        owner = address(this);

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
        mockBalEthRethFeed = new MockDataFeed(_CHAINLINK_RETH_ETH);
        chainlinkAdaptor.addAsset(
            _BAL_WETH_RETH_ADDRESS,
            false,
            address(mockBalEthRethFeed),
            0
        );
        dualChainlinkAdaptor.addAsset(
            _BAL_WETH_RETH_ADDRESS,
            false,
            address(mockBalEthRethFeed),
            0
        );

        // start epoch
        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        _refreshMockFeeds();

        (, int256 ethPrice, , , ) = mockBalEthRethFeed.latestRoundData();
        chainlinkEthUsd.updateAnswer(ethPrice);

        console2.log("ethPrice", ethPrice);

        // Setup borrowable CDAI.
        {
            _prepareDAI(owner, 200_000e18);
            dai.approve(address(borrowableCDAI), 200_000e18);
            // Add cToken support on Oracle Manager.
            
        }

        // Setup pendleStrategyCTokenSTETH.
        {
            deal(address(LP_wstETH_24Dec2025), owner, _ONE);
            LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE);
        }

        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(borrowableCDAI));

        _setCTokenConfigCollateralOff(address(pendleStrategyCTokenSTETH), 0);
        _setCTokenConfigBasic(address(borrowableCDAI), 0, 100_000e18);

        // provide enough liquidity
        _provideEnoughLiquidityForLeverage();
    }

    function _provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareDAI(liquidityProvider, 200_000e18);
        deal(address(LP_wstETH_24Dec2025), liquidityProvider, 10e18);
        // Mint borrowable cDAI.
        vm.startPrank(liquidityProvider);
        dai.approve(address(borrowableCDAI), 200_000e18);
        borrowableCDAI.deposit(200_000e18, liquidityProvider);
        // Mint cBALETH.
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 10e18);
        pendleStrategyCTokenSTETH.deposit(10e18, liquidityProvider);
        vm.stopPrank();
    }
}
