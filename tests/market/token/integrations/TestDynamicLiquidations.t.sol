// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { console2 } from "forge-std/console2.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract TestDynamicLiquidations is TestBaseMarketIsolated {
    address public owner;

    uint256 lFactorsPreLiquidation;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        super.setUp();

        owner = address(this);

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

        // Setup pendleStrategyCTokenSTETH.
        {
            deal(address(LP_wstETH_24Dec2025), owner, 1 ether);
            LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 1 ether);

        }

        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(borrowableCDAI));

        _setCTokenConfigBasic(address(pendleStrategyCTokenSTETH), 100e18, 0);
        _setCTokenConfigBasic(address(borrowableCDAI), 100e18, 100_000e18);

        // provide enough liquidity
        _provideEnoughLiquidityForLeverage();
    }

    function testDynamicLiquidations_liquidateRevertWhenBelowColReq() public {
        deal(address(LP_wstETH_24Dec2025), user1, 1 ether);

        // try mint()
        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 1 ether);
        pendleStrategyCTokenSTETH.deposit(1 ether, user1);
        pendleStrategyCTokenSTETH.postCollateral(1 ether - 1);

        // try borrow()
        borrowableCDAI.borrow(1000 ether, user1);
        vm.stopPrank();

        // skip sec hold period
        skip(900);

        (uint256 pendleStrategyCTokenSTETHPrice, ) = oracleManager.getPrice(
            address(pendleStrategyCTokenSTETH),
            true,
            true
        );

        // adjust dai price, a bit lower than colReqA
        // 1000 dai > 1 pendleStrategyCTokenSTETH / colReqA
        mockDaiFeed.setMockAnswer(
            int256(
                (pendleStrategyCTokenSTETHPrice * 1 ether * 1e8) / 1000 ether / 1.4 ether - 100
            )
        );

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__NoLiquidationAvailable.selector
        );

        address[] memory accounts = new address[](1);
        accounts[0] = user1;
        uint256[] memory debtAmounts = new uint256[](1);
        debtAmounts[0] = 250 ether;

        borrowableCDAI.liquidateExact(
            debtAmounts, 
            accounts,
            address(pendleStrategyCTokenSTETH));
    }

    function testDynamicLiquidations_liquidateWorksWhenAboveColReq() public {
        deal(address(LP_wstETH_24Dec2025), user1, 1 ether);

        // try mint()
        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 1 ether);
        pendleStrategyCTokenSTETH.deposit(1 ether, user1);
        pendleStrategyCTokenSTETH.postCollateral(1 ether - 1);

        // try borrow()
        borrowableCDAI.borrow(5000 ether, user1);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);

        borrowableCDAI.accrueIfNeeded();

        mockDaiFeed.setMockAnswer(2e8);
        mockDaiFeed.setMockUpdatedAt(block.timestamp);

        ExpectedLiquidationValues memory expectedLiqValues = _calculateExpectedLiquidationValues(
            LiquidationParams({
                borrower: user1,
                collateralToken: address(pendleStrategyCTokenSTETH),
                borrowedToken: address(borrowableCDAI),
                isLiquidateExact: true,
                liquidateExactAmount: 250 ether,
                isAuction: false,
                isMultiMarketTest: false,
                marketManagerId: 0
            })
        );

        // try liquidate half
        _prepareDAI(user2, 250 ether);
        vm.startPrank(user2);
        dai.approve(address(borrowableCDAI), 250 ether);

        address[] memory accounts = new address[](1);
        accounts[0] = user1;
        uint256[] memory debtAmounts = new uint256[](1);
        debtAmounts[0] = 250 ether;
        
        borrowableCDAI.liquidateExact(
            debtAmounts, 
            accounts,
            address(pendleStrategyCTokenSTETH)
        );
        vm.stopPrank();

        uint256 borrowerCollateralAfter = pendleStrategyCTokenSTETH.balanceOf(user1);
        uint256 expectedBorrowerCollateralAfter = (1 ether) - expectedLiqValues.collateralLiquidated;

        console2.log("borrowerCollateralAfter", borrowerCollateralAfter);
        console2.log("expectedBorrowerCollateralAfter", expectedBorrowerCollateralAfter);
        
        assertApproxEqAbs(
            borrowerCollateralAfter,
            expectedBorrowerCollateralAfter,
            1000,
            "Borrower collateral should be reduced by liquidatedPTokens"
        );

        assertEq(pendleStrategyCTokenSTETH.exchangeRate(), 1 ether);

        assertEq(borrowableCDAI.balanceOf(user1), 0);
        assertApproxEqRel(borrowableCDAI.debtBalance(user1), 5000 ether - (expectedLiqValues.badDebt + 250 ether), 0.0001e18, "debt balance mismatch");
        assertLt(borrowableCDAI.exchangeRateUpdated(), 1 ether, "exchange rate should lower because of bad debt");
    }

    function _provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareDAI(liquidityProvider, 200000e18);
        deal(address(LP_wstETH_24Dec2025), liquidityProvider, 10 ether);

        // Mint borrowable cDAI.
        vm.startPrank(liquidityProvider);

        dai.approve(address(borrowableCDAI), 200000 ether);
        borrowableCDAI.mint(200000 ether, liquidityProvider);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 10 ether);
        pendleStrategyCTokenSTETH.deposit(10 ether, liquidityProvider);

        vm.stopPrank();
    }
}
