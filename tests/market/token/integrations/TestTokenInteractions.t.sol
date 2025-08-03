// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

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

    function provideEnoughLiquidityForLeverage() internal {
        
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareDAI(liquidityProvider, 200_000e18);
        _prepareBALRETH(liquidityProvider, 10e18);
        // Mint borrowable cDAI.
        vm.startPrank(liquidityProvider);
        dai.approve(address(borrowableCDAI), 200_000e18);
        borrowableCDAI.deposit(200_000e18, liquidityProvider);
        // Mint cBALETH.
        balRETH.approve(address(strategyCBALRETH), 10e18);
        strategyCBALRETH.deposit(10e18, liquidityProvider);
        vm.stopPrank();
    }

    function testCTokenMintRedeem() public {
        _deployMarket();

        _prepareBALRETH(user1, 2e18);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.mint(_ONE, user1);
        assertEq(strategyCBALRETH.balanceOf(user1), _ONE);

        // try mint to another user
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.mint(_ONE, user2);
        assertEq(strategyCBALRETH.balanceOf(user1), _ONE);
        assertEq(strategyCBALRETH.balanceOf(user2), _ONE);

        // try redeem()
        strategyCBALRETH.redeem(_ONE, user1, user1);
        vm.stopPrank();
        assertEq(strategyCBALRETH.balanceOf(user1), 0);
    }

    function testBorrowableCTokenMintRedeem() public {
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

    function testBorrowableCTokenBorrowRepay() public {
        _deployMarket();
        _prepareBALRETH(user1, _ONE);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.deposit(_ONE, user1);
        strategyCBALRETH.postCollateral(_ONE);

        assertEq(strategyCBALRETH.balanceOf(user1), _ONE);
        assertEq(strategyCBALRETH.exchangeRate(), _ONE);

        uint256 priceDecimals = mockDaiFeed.decimals();
        (, int256 daiPrice, , , ) = mockDaiFeed.latestRoundData();

        uint256 minimumBorrowAmount = (marketManagerIsolated.MIN_ACTIVE_LOAN_SIZE() *
            (10 ** priceDecimals)) / uint256(daiPrice);

        // try borrow() with insufficient loan size
        vm.expectRevert(
            LiquidityManagerIsolated.LiquidityManager__InsufficientLoanSize.selector
        );
        borrowableCDAI.borrow(minimumBorrowAmount - 1, user1);

        // try borrow()
        borrowableCDAI.borrow(minimumBorrowAmount, user1);

        assertEq(borrowableCDAI.balanceOf(user1), 0);
        assertEq(borrowableCDAI.debtBalance(user1), minimumBorrowAmount);
        assertEq(borrowableCDAI.exchangeRate(), _ONE);

        // try borrow()
        skip(1200);
        borrowableCDAI.borrow(100e18, user1);

        assertEq(borrowableCDAI.balanceOf(user1), 0);
        assertGt(borrowableCDAI.debtBalance(user1), minimumBorrowAmount + 100e18);
        assertGt(borrowableCDAI.exchangeRate(), _ONE);

        // skip min hold period
        skip(20 minutes);

        // try partial repay
        uint256 borrowBalanceBefore = borrowableCDAI.debtBalance(user1);
        uint256 exchangeRateBefore = borrowableCDAI.exchangeRate();
        _prepareDAI(user1, 20e18);
        dai.approve(address(borrowableCDAI), 20e18);
        borrowableCDAI.repay(20e18);

        assertEq(borrowableCDAI.balanceOf(user1), 0);
        assertGt(borrowableCDAI.debtBalance(user1), borrowBalanceBefore - 20e18);
        assertGt(borrowableCDAI.exchangeRate(), exchangeRateBefore);

        // skip some period
        skip(1200);

        // try repay full
        borrowBalanceBefore = borrowableCDAI.debtBalance(user1);
        exchangeRateBefore = borrowableCDAI.exchangeRate();
        _prepareDAI(user1, borrowBalanceBefore);
        dai.approve(address(borrowableCDAI), borrowBalanceBefore);
        borrowableCDAI.repay(borrowBalanceBefore);
        vm.stopPrank();

        assertEq(borrowableCDAI.balanceOf(user1), 0);
        assertGt(borrowableCDAI.debtBalance(user1), 0);
        assertGt(borrowableCDAI.exchangeRate(), exchangeRateBefore);
    }

    function testCTokenRedeemOnBorrow() public {
        _deployMarket();
        _prepareBALRETH(user1, _ONE);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.deposit(_ONE, user1);
        strategyCBALRETH.postCollateral(_ONE);

        // try borrow()
        borrowableCDAI.borrow(500e18, user1);

        // skip min hold period
        skip(20 minutes);

        // can't redeem full
        vm.expectRevert(
            bytes4(keccak256("MarketManager__InsufficientCollateral()"))
        );
        strategyCBALRETH.redeem(_ONE, user1, user1);

        // can redeem partially
        strategyCBALRETH.redeem(0.2e18, user1, user1);
        vm.stopPrank();

        assertEq(strategyCBALRETH.balanceOf(user1), 0.8e18);
        assertEq(strategyCBALRETH.exchangeRate(), _ONE);
    }

    function testBorrowableCTokenRedeemOnBorrow() public {
        _deployMarket();
        // try mint()
        _prepareBALRETH(user1, _ONE);
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.deposit(_ONE, user1);
        strategyCBALRETH.postCollateral(_ONE);

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

        assertEq(strategyCBALRETH.balanceOf(user1), _ONE);
        assertEq(strategyCBALRETH.exchangeRate(), _ONE);

        assertEq(borrowableCDAI.balanceOf(user1), 0);
        assertGt(borrowableCDAI.debtBalance(user1), 500e18);
        assertGt(borrowableCDAI.exchangeRate(), _ONE);
    }

    function testCTokenTransferOnBorrow() public {
        _deployMarket();
        _prepareBALRETH(user1, _ONE);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.deposit(_ONE, user1);
        strategyCBALRETH.postCollateral(_ONE);

        // try borrow()
        borrowableCDAI.borrow(500e18, user1);

        // skip min hold period
        skip(20 minutes);

        // can't transfer full
        vm.expectRevert(
            bytes4(keccak256("MarketManager__InsufficientCollateral()"))
        );
        strategyCBALRETH.transfer(user2, _ONE);

        // can redeem partially
        strategyCBALRETH.transfer(user2, 0.2e18);
        vm.stopPrank();

        assertEq(strategyCBALRETH.balanceOf(user1), 0.8e18);
        assertEq(strategyCBALRETH.balanceOf(user2), 0.2e18);
        assertEq(strategyCBALRETH.exchangeRate(), _ONE);
    }

    function testBorrowableCTokenTransferOnBorrow() public {
        _deployMarket();
        // try mint()
        _prepareBALRETH(user1, _ONE);
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.deposit(_ONE, user1);
        strategyCBALRETH.postCollateral(_ONE);

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

        assertEq(strategyCBALRETH.balanceOf(user1), _ONE);
        assertEq(strategyCBALRETH.exchangeRate(), _ONE);

        assertEq(borrowableCDAI.balanceOf(user1), 0);
        assertEq(borrowableCDAI.debtBalance(user1), 500e18);

        assertEq(borrowableCDAI.balanceOf(user2), 1000e18);
        assertEq(borrowableCDAI.debtBalance(user2), 0e18);
        assertEq(borrowableCDAI.exchangeRate(), _ONE);
    }

    function testLiquidationExact() public {
        _deployMarket();

        _prepareBALRETH(user1, _ONE);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.deposit(_ONE, user1);
        strategyCBALRETH.postCollateral(_ONE);

        // try borrow()
        borrowableCDAI.borrow(1000e18, user1);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);

        mockDaiFeed.setMockAnswer(2e8);

        uint256 currentDebtBalance = borrowableCDAI.debtBalanceUpdated(user1);  

        ExpectedLiquidationValues memory expectedLiquidationValues = _calculateExpectedLiquidationValues(
            LiquidationParams({
                borrower: user1,
                collateralToken: address(strategyCBALRETH),
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
            address(strategyCBALRETH));
        vm.stopPrank();

        _assertCollateralSeizure(_ONE, expectedLiquidationValues.collateralLiquidated);
        assertEq(strategyCBALRETH.exchangeRate(), _ONE);

        assertEq(borrowableCDAI.balanceOf(user1), 0);


        _assertDebtReduction(250e18, expectedLiquidationValues.badDebt, currentDebtBalance);

        assertApproxEqRel(borrowableCDAI.exchangeRate(), _ONE, 0.01e18);


    }

    function testLiquidation() public {
        _deployMarket();

        _prepareBALRETH(user1, _ONE);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.deposit(_ONE, user1);
        strategyCBALRETH.postCollateral(_ONE); 

        // try borrow()
        borrowableCDAI.borrow(1000e18, user1);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);

        mockDaiFeed.setMockAnswer(1.5e8);

        ExpectedLiquidationValues memory expectedLiquidationValues = _calculateExpectedLiquidationValues(
            LiquidationParams({
                borrower: user1,
                collateralToken: address(strategyCBALRETH),
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

        borrowableCDAI.liquidate(accounts, address(strategyCBALRETH));
        vm.stopPrank();

        _assertCollateralSeizure(_ONE, expectedLiquidationValues.collateralLiquidated);

        assertEq(strategyCBALRETH.exchangeRate(), _ONE);
        assertEq(borrowableCDAI.balanceOf(user1), 0);
        assertEq(borrowableCDAI.debtBalance(user1), 0);
        assertApproxEqRel(borrowableCDAI.exchangeRate(), _ONE, 0.01e18);
    }

    function testLiquidationWithFullValueLoss() public {
        _deployMarket();

        _prepareBALRETH(user1, _ONE);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.deposit(_ONE, user1);
        strategyCBALRETH.postCollateral(_ONE);

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
            address(strategyCBALRETH));
        vm.stopPrank();

        assertEq(strategyCBALRETH.balanceOf(user1), 0);

        assertEq(borrowableCDAI.balanceOf(user1), 0);
        assertApproxEqRel(borrowableCDAI.debtBalance(user1), 0, 0.01e18);
        assertLt(borrowableCDAI.exchangeRateUpdated(), _ONE);
    }

    function testSoftLiquidation() public {
        _deployMarket();

        _prepareBALRETH(user1, _ONE);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.deposit(_ONE, user1);
        strategyCBALRETH.postCollateral(_ONE);

        // try borrow()
        borrowableCDAI.borrow(1000e18, user1);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);

        (uint256 balRETHPrice, ) = oracleManager.getPrice(
            address(balRETH),
            true,
            true
        );

        uint256 debtBalance = borrowableCDAI.debtBalanceUpdated(user1);

        uint256 daiPrice = ((balRETHPrice * 1e8 * 1e18) / debtBalance) /
            1.4e18 +
            1;

        mockDaiFeed.setMockAnswer(int256(daiPrice));

        ExpectedLiquidationValues memory expectedLiquidationValues = _calculateExpectedLiquidationValues(
            LiquidationParams({
                borrower: user1,
                collateralToken: address(strategyCBALRETH),
                borrowedToken: address(borrowableCDAI),
                isLiquidateExact: false,
                liquidateExactAmount: 0,
                isAuction: false,
                isMultiMarketTest: false,
                marketManagerId: 0
            })
        );

        // try liquidate
        _prepareDAI(user2, 1000e18);
        vm.startPrank(user2);
        dai.approve(address(borrowableCDAI), 1000e18);

        address[] memory accounts = new address[](1);
        accounts[0] = user1;

        borrowableCDAI.liquidate(
            accounts,
            address(strategyCBALRETH));
        vm.stopPrank();

        assertEq(
            strategyCBALRETH.balanceOf(user1), 
            _ONE - expectedLiquidationValues.collateralLiquidated
        );
        assertEq(strategyCBALRETH.exchangeRate(), _ONE);

        assertEq(borrowableCDAI.balanceOf(user1), 0);
        assertApproxEqRel(borrowableCDAI.debtBalance(user1), 1000e18 - expectedLiquidationValues.debtRepaid, 0.01e18);
        assertApproxEqRel(borrowableCDAI.exchangeRate(), _ONE, 0.01e18);
    }

    function testRevertBorrowAndLiquidateWithZeroCollRatio() public {
        _deployMarketForZeroCollateralTest();

        _setCTokenConfigCollateralOff(address(strategyCBALRETH), 0);

        _prepareBALRETH(user1, _ONE);

        // try mint()
        vm.startPrank(user1);

        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.deposit(_ONE, user1);

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__CapReached.selector
        );
        strategyCBALRETH.postCollateral(_ONE);

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
            address(strategyCBALRETH));
        vm.stopPrank();

        vm.prank(user1);
        strategyCBALRETH.withdraw(_ONE, user1, user1);
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
        console2.log("borrowerCollateralAfter", strategyCBALRETH.balanceOf(user1));

        uint256 borrowerCollateralAfter = strategyCBALRETH.balanceOf(user1);
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

        console2.log("ethPrice", ethPrice);

        // Setup borrowable CDAI.
        {
            _prepareDAI(owner, 200_000e18);
            dai.approve(address(borrowableCDAI), 200_000e18);
        }

        // Setup strategyCBALRETH.
        {
            _prepareBALRETH(owner, _ONE);
            balRETH.approve(address(strategyCBALRETH), _ONE);
        }

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCDAI));

        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 100_000e18);

        // provide enough liquidity
        provideEnoughLiquidityForLeverage();
    }

    function _deployMarketForZeroCollateralTest() internal {
        owner = address(this);

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

        console2.log("ethPrice", ethPrice);

        // Setup borrowable CDAI.
        {
            _prepareDAI(owner, 200_000e18);
            dai.approve(address(borrowableCDAI), 200_000e18);
            // Add cToken support on Oracle Manager.
            
        }

        // Setup strategyCBALRETH.
        {
            _prepareBALRETH(owner, _ONE);
            balRETH.approve(address(strategyCBALRETH), _ONE);
        }

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCDAI));

        _setCTokenConfigCollateralOff(address(strategyCBALRETH), 0);
        _setCTokenConfigBasic(address(borrowableCDAI), 0, 100_000e18);

        // provide enough liquidity
        provideEnoughLiquidityForLeverage();
    }
}
