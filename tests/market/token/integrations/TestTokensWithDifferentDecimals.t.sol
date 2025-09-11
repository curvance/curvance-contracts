// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import "tests/market/TestBaseMarketIsolated.sol";
import { WAD, WAD_SQUARED } from "contracts/libraries/ConstantsLib.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { console2 } from "forge-std/console2.sol";

contract TestTokensWithDifferentDecimals is TestBaseMarketIsolated {
    address public owner;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        super.setUp();

        owner = address(this);

        // use mock pricing for testing
        mockUsdcFeed = new MockDataFeed(_CHAINLINK_USDC_USD);
        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            true,
            address(mockUsdcFeed),
            0
        );
        dualChainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            true,
            address(mockUsdcFeed),
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

        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);

        (, int256 ethPrice, , , ) = mockWethFeed.latestRoundData();
        chainlinkEthUsd.updateAnswer(ethPrice);

        // Setup borrowable cUSDC.
        {
            _prepareUSDC(owner, 200000e6);
            usdc.approve(address(borrowableCUSDC), 200000e6);
        }

        // Setup pendleStrategyCTokenSTETH.
        {
            deal(address(LP_wstETH_24Dec2025), owner, 1 ether);
            LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 1 ether);

        }

        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(pendleStrategyCTokenSTETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 100_000e6);

        // provide enough liquidity
        _provideEnoughLiquidityForLeverage();
    }

    function testTokensWithDifferentDecimals_cTokenMintRedeem() public {
        deal(address(LP_wstETH_24Dec2025), user1, 2 ether);

        // try mint()
        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 1 ether);
        pendleStrategyCTokenSTETH.deposit(1 ether, user1);
        pendleStrategyCTokenSTETH.postCollateral(1 ether);
        assertEq(pendleStrategyCTokenSTETH.balanceOf(user1), 1 ether);

        // try mintFor()
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 1 ether);
        pendleStrategyCTokenSTETH.deposit(1 ether, user2);
        assertEq(pendleStrategyCTokenSTETH.balanceOf(user1), 1 ether);
        assertEq(pendleStrategyCTokenSTETH.balanceOf(user2), 1 ether);

        // skip some period
        skip(20 minutes);

        // try redeem()
        pendleStrategyCTokenSTETH.redeem(1 ether, user1, user1);
        vm.stopPrank();
        assertEq(pendleStrategyCTokenSTETH.balanceOf(user1), 0);
    }

    function testTokensWithDifferentDecimals_borrowableCTokenMintRedeem() public {
        _prepareUSDC(user1, 2e6);

        // try mint()
        vm.startPrank(user1);
        usdc.approve(address(borrowableCUSDC), 1e6);
        borrowableCUSDC.deposit(1e6, user1);
        assertEq(borrowableCUSDC.balanceOf(user1), 1e6);

        // try minting for user2
        usdc.approve(address(borrowableCUSDC), 1e6);
        borrowableCUSDC.deposit(1e6, user2);
        assertEq(borrowableCUSDC.balanceOf(user1), 1e6);
        assertEq(borrowableCUSDC.balanceOf(user2), 1e6);

        // try redeem()
        borrowableCUSDC.redeem(1e6, address(this), user1);
        vm.stopPrank();
        assertEq(borrowableCUSDC.balanceOf(user1), 0);
    }

    function testTokensWithDifferentDecimals_borrowableCTokenBorrowRepay() public {
        deal(address(LP_wstETH_24Dec2025), user1, 1 ether);

        // try mint()
        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 1 ether);
        pendleStrategyCTokenSTETH.deposit(1 ether, user1);
        pendleStrategyCTokenSTETH.postCollateral(1 ether);

        assertEq(pendleStrategyCTokenSTETH.balanceOf(user1), 1 ether);
        assertEq(pendleStrategyCTokenSTETH.exchangeRate(), 1 ether);

        // try borrow()
        borrowableCUSDC.borrow(500e6, user1);

        assertEq(borrowableCUSDC.balanceOf(user1), 0);
        assertEq(borrowableCUSDC.debtBalance(user1), 500e6);
        assertEq(borrowableCUSDC.exchangeRate(), 1 ether);

        // try borrow()
        skip(1200);
        borrowableCUSDC.borrow(100e6, user1);

        assertEq(borrowableCUSDC.balanceOf(user1), 0);
        assertGt(borrowableCUSDC.debtBalance(user1), 600e6);
        assertGt(borrowableCUSDC.exchangeRate(), 1 ether);

        // skip min hold period
        skip(20 minutes);

        // try partial repay
        uint256 borrowBalanceBefore = borrowableCUSDC.debtBalance(user1);
        uint256 exchangeRateBefore = borrowableCUSDC.exchangeRate();
        _prepareUSDC(user1, 200e6);
        usdc.approve(address(borrowableCUSDC), 200e6);
        borrowableCUSDC.repay(200e6);

        assertEq(borrowableCUSDC.balanceOf(user1), 0);
        assertGt(borrowableCUSDC.debtBalance(user1), borrowBalanceBefore - 200e6);
        assertGt(borrowableCUSDC.exchangeRate(), exchangeRateBefore);

        // skip some period
        skip(20 minutes);

        // try repay full
        borrowBalanceBefore = borrowableCUSDC.debtBalance(user1);
        exchangeRateBefore = borrowableCUSDC.exchangeRate();
        _prepareUSDC(user1, borrowBalanceBefore);
        usdc.approve(address(borrowableCUSDC), borrowBalanceBefore);
        borrowableCUSDC.repay(borrowBalanceBefore);
        vm.stopPrank();

        assertEq(borrowableCUSDC.balanceOf(user1), 0);
        assertGt(borrowableCUSDC.debtBalance(user1), 0);
        assertGt(borrowableCUSDC.exchangeRate(), exchangeRateBefore);
    }

    function testTokensWithDifferentDecimals_cTokenRedeemOnBorrow() public {
        deal(address(LP_wstETH_24Dec2025), user1, 1 ether);

        // try mint()
        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 1 ether);
        pendleStrategyCTokenSTETH.deposit(1 ether, user1);
        pendleStrategyCTokenSTETH.postCollateral(1 ether);

        // try borrow()
        borrowableCUSDC.borrow(500e6, user1);

        // skip min hold period
        skip(20 minutes);

        // can't redeem full
        vm.expectRevert(
            bytes4(keccak256("MarketManager__InsufficientCollateral()"))
        );
        pendleStrategyCTokenSTETH.redeem(1 ether, user1, user1);

        // can redeem partially
        pendleStrategyCTokenSTETH.redeem(0.2 ether, user1, user1);
        vm.stopPrank();

        assertEq(pendleStrategyCTokenSTETH.balanceOf(user1), 0.8 ether);
        assertEq(pendleStrategyCTokenSTETH.exchangeRate(), 1 ether);
    }

    function testTokensWithDifferentDecimals_borrowableCTokenRedeemOnBorrow() public {
        // try mint()
        deal(address(LP_wstETH_24Dec2025), user1, 1 ether);
        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 1 ether);
        pendleStrategyCTokenSTETH.deposit(1 ether, user1);
        pendleStrategyCTokenSTETH.postCollateral(1 ether);

        // try mint()
        _prepareUSDC(user1, 1000e6);
        usdc.approve(address(borrowableCUSDC), 1000e6);
        borrowableCUSDC.deposit(1000e6, user1);

        // try borrow()
        borrowableCUSDC.borrow(500e6, user1);

        // fail to redeem before minimum hold time pass
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__MinimumHoldPeriod.selector
        );
        borrowableCUSDC.redeem(1000e6, address(this), user1);

        // skip min hold period
        skip(20 minutes);

        // can redeem fully
        borrowableCUSDC.redeem(1000e6, address(this), user1);
        vm.stopPrank();

        assertEq(pendleStrategyCTokenSTETH.balanceOf(user1), 1 ether);
        assertEq(pendleStrategyCTokenSTETH.exchangeRate(), 1 ether);

        assertEq(borrowableCUSDC.balanceOf(user1), 0);
        assertGt(borrowableCUSDC.debtBalance(user1), 500e6);
        assertGt(borrowableCUSDC.exchangeRate(), 1 ether);
    }

    function testTokensWithDifferentDecimals_cTokenTransferOnBorrow() public {
        deal(address(LP_wstETH_24Dec2025), user1, 1 ether);

        // try mint()
        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 1 ether);
        pendleStrategyCTokenSTETH.deposit(1 ether, user1);
        pendleStrategyCTokenSTETH.postCollateral(1 ether);

        // try borrow()
        borrowableCUSDC.borrow(500e6, user1);

        // skip min hold period
        skip(20 minutes);

        // can't transfer full
        vm.expectRevert(
            bytes4(keccak256("MarketManager__InsufficientCollateral()"))
        );
        pendleStrategyCTokenSTETH.transfer(user2, 1 ether);

        // can redeem partially
        pendleStrategyCTokenSTETH.transfer(user2, 0.2 ether);
        vm.stopPrank();

        assertEq(pendleStrategyCTokenSTETH.balanceOf(user1), 0.8 ether);
        assertEq(pendleStrategyCTokenSTETH.balanceOf(user2), 0.2 ether);
        assertEq(pendleStrategyCTokenSTETH.exchangeRate(), 1 ether);
    }

    function testTokensWithDifferentDecimals_borrowableCTokenTransferOnBorrow() public {
        // try mint()
        deal(address(LP_wstETH_24Dec2025), user1, 1 ether);
        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 1 ether);
        pendleStrategyCTokenSTETH.deposit(1 ether, user1);
        pendleStrategyCTokenSTETH.postCollateral(1 ether);

        // try mint()
        _prepareUSDC(user1, 1000e6);
        usdc.approve(address(borrowableCUSDC), 1000e6);
        borrowableCUSDC.deposit(1000e6, user1);

        // try borrow()
        borrowableCUSDC.borrow(500e6, user1);

        // skip min hold period
        skip(20 minutes);

        // try full transfer
        borrowableCUSDC.transfer(user2, 1000e6);
        vm.stopPrank();

        assertEq(pendleStrategyCTokenSTETH.balanceOf(user1), 1 ether, "collateral balance is not affected");
        assertEq(pendleStrategyCTokenSTETH.exchangeRate(), 1 ether, "collateral token exchange rate is not affected");

        assertEq(borrowableCUSDC.balanceOf(user1), 0);
        // accrueIfNeeded is called in transfer, so debt balance is increased
        assertGt(borrowableCUSDC.debtBalance(user1), 500e6, "debt balance is increased because of interest");
        assertGt(borrowableCUSDC.exchangeRate(), 1 ether, "debt token exchange rate is increased because of interest");

        assertEq(borrowableCUSDC.balanceOf(user2), 1000e6, "receiver balance is not affected");
        assertEq(borrowableCUSDC.debtBalance(user2), 0, "receiver debt balance is 0");
    }

    function testTokensWithDifferentDecimals_liquidationExact() public {
        deal(address(LP_wstETH_24Dec2025), user1, 1 ether);

        // try mint()
        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 1 ether);
        pendleStrategyCTokenSTETH.deposit(1 ether, user1);
        pendleStrategyCTokenSTETH.postCollateral(1 ether);

        // try borrow()
        borrowableCUSDC.borrow(3000e6, user1);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);

        mockUsdcFeed.setMockAnswer(1.5e8);
        mockUsdcFeed.setMockUpdatedAt(block.timestamp);

        ExpectedLiquidationValues memory expectedLiquidationValues = _calculateExpectedLiquidationValues(
            LiquidationParams({
                borrower: user1,
                collateralToken: address(pendleStrategyCTokenSTETH),
                borrowedToken: address(borrowableCUSDC),
                isLiquidateExact: true,
                liquidateExactAmount: 250e6,
                isAuction: false,
                isMultiMarketTest: false,
                marketManagerId: 0
            })
        );

        // try liquidate half
        _prepareUSDC(user2, 250e6);
        vm.startPrank(user2);
        usdc.approve(address(borrowableCUSDC), 250e6);

        address[] memory accounts = new address[](1);
        accounts[0] = user1;
        uint256[] memory debtAmounts = new uint256[](1);
        debtAmounts[0] = 250e6;

        uint256 currentDebtBalance = borrowableCUSDC.debtBalance(user1);

        borrowableCUSDC.liquidateExact(
            debtAmounts,
            accounts,
            address(pendleStrategyCTokenSTETH));
        vm.stopPrank();

        assertApproxEqRel(
            pendleStrategyCTokenSTETH.balanceOf(user1),
            1 ether - expectedLiquidationValues.collateralLiquidated,
            0.001e18
        );
        assertEq(pendleStrategyCTokenSTETH.exchangeRate(), 1 ether);

        assertEq(borrowableCUSDC.balanceOf(user1), 0);
        assertApproxEqRel(borrowableCUSDC.debtBalance(user1), currentDebtBalance - (expectedLiquidationValues.badDebt + 250e6), 0.001e18);
        assertLt(borrowableCUSDC.exchangeRate(), 1 ether, "exchange rate should lower because of bad debt");
    }

    function testTokensWithDifferentDecimals_liquidation() public {
        deal(address(LP_wstETH_24Dec2025), user1, 1 ether);

        // try mint()
        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 1 ether);
        pendleStrategyCTokenSTETH.deposit(1 ether, user1);
        pendleStrategyCTokenSTETH.postCollateral(1 ether);

        // try borrow()
        borrowableCUSDC.borrow(3000e6, user1);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);

        borrowableCUSDC.accrueIfNeeded();

        mockUsdcFeed.setMockAnswer(150000000);

        uint256 currentDebtBalance = borrowableCUSDC.debtBalance(user1);

        ExpectedLiquidationValues memory expectedLiquidationValues = _calculateExpectedLiquidationValues(
            LiquidationParams({
                borrower: user1,
                collateralToken: address(pendleStrategyCTokenSTETH),
                borrowedToken: address(borrowableCUSDC),
                isLiquidateExact: false,
                liquidateExactAmount: 0,
                isAuction: false,
                isMultiMarketTest: false,
                marketManagerId: 0
            })
        );
        
        // try liquidate
        _prepareUSDC(user2, 10000e6);
        vm.startPrank(user2);
        usdc.approve(address(borrowableCUSDC), 10000e6);
        
        address[] memory accounts = new address[](1);
        accounts[0] = user1;

        borrowableCUSDC.liquidate(
            accounts,
            address(pendleStrategyCTokenSTETH));
        vm.stopPrank();

        assertApproxEqRel(
            pendleStrategyCTokenSTETH.balanceOf(user1),
            1 ether - expectedLiquidationValues.collateralLiquidated,
            0.001e18
        );
        assertEq(pendleStrategyCTokenSTETH.exchangeRate(), 1 ether);

        assertEq(borrowableCUSDC.balanceOf(user1), 0);
        assertApproxEqRel(borrowableCUSDC.debtBalance(user1), currentDebtBalance - (expectedLiquidationValues.badDebt + expectedLiquidationValues.debtRepaid), 0.001e18);
        assertLt(borrowableCUSDC.exchangeRate(), 1 ether, "exchange rate should lower because of bad debt");
    }

    function _provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 200000e6);
        deal(address(LP_wstETH_24Dec2025), liquidityProvider, 10 ether);
        // Mint borrowable cUSDC.
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 200000e6);
        borrowableCUSDC.deposit(200000e6, liquidityProvider);
        // Mint cBALETH.
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 10 ether);
        pendleStrategyCTokenSTETH.deposit(10 ether, liquidityProvider);
        vm.stopPrank();
    }

}
