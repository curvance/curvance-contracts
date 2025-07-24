// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { PriceReturnData } from "contracts/interfaces/IOracleAdaptor.sol";
import { WAD } from "contracts/libraries/Constants.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import "forge-std/console2.sol";

contract CanLiquidateTest is TestBaseMarketIsolated {
    
    address[] accounts = new address[](1);
    uint256[] debtAmounts = new uint256[](1);

    uint256 borrowableCTokenUnderlyingPrice = 1e18;

    function setUp() public override {
        super.setUp();

        accounts[0] = user1;
        debtAmounts[0] = 1000e6;
    }
    
    function test_canLiquidate_fail_whenBorrowableCTokenNotListed() public {
        IMarketManager.LiqInstructions memory liqInstructions = IMarketManager.LiqInstructions({
            collateralToken: address(strategyCBALRETH),
            debtToken: address(borrowableCUSDC),
            numAccounts: 1,
            liquidateExact: false,
            liquidatedShares: 0,
            debtRepaid: 0,
            badDebt: 0
        });

        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        marketManagerIsolated.canLiquidate(
            debtAmounts,
            address(this),
            accounts,
            liqInstructions
        );
    }

    function test_canLiquidate_fail_whenCTokenNotListed() public {
        // marketManager.listToken(address(borrowableCUSDC));
        IMarketManager.LiqInstructions memory liqInstructions = IMarketManager.LiqInstructions({
            collateralToken: address(strategyCBALRETH),
            debtToken: address(borrowableCUSDC),
            numAccounts: 1,
            liquidateExact: false,
            liquidatedShares: 0,
            debtRepaid: 0,
            badDebt: 0
        });

        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        marketManagerIsolated.canLiquidate(
            debtAmounts,
            address(this),
            accounts,
            liqInstructions
        );
    }

    function test_canLiquidate_fail_whenCollRatioZero() public {
        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(strategyCBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        IMarketManager.LiqInstructions memory liqInstructions = IMarketManager.LiqInstructions({
            collateralToken: address(strategyCBALRETH),
            debtToken: address(borrowableCUSDC),
            numAccounts: 1,
            liquidateExact: false,
            liquidatedShares: 0,
            debtRepaid: 0,
            badDebt: 0
        });

        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InvalidParameter.selector
        );
        marketManagerIsolated.canLiquidate(
            debtAmounts,
            address(this),
            accounts,
            liqInstructions
        );
    }

    function test_canLiquidate_fail_whenUserHasNotEnteredAnyMarket() public {
        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(strategyCBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));
        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);

        IMarketManager.LiqInstructions memory liqInstructions = IMarketManager.LiqInstructions({
            collateralToken: address(strategyCBALRETH),
            debtToken: address(borrowableCUSDC),
            numAccounts: 1,
            liquidateExact: false,
            liquidatedShares: 0,
            debtRepaid: 0,
            badDebt: 0
        });

        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__NoLiquidationAvailable.selector
        );
        marketManagerIsolated.canLiquidate(
            debtAmounts,
            address(this),
            accounts,
            liqInstructions
        );
    }

    function test_canLiquidate_fail_whenAccountHasNoBorrowsAndCollateralPosted()
        public
    {
        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(strategyCBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));
        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);

        IMarketManager.LiqInstructions memory liqInstructions = IMarketManager.LiqInstructions({
            collateralToken: address(strategyCBALRETH),
            debtToken: address(borrowableCUSDC),
            numAccounts: 1,
            liquidateExact: false,
            liquidatedShares: 0,
            debtRepaid: 0,
            badDebt: 0
        });

        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__NoLiquidationAvailable.selector
        );
        marketManagerIsolated.canLiquidate(
            debtAmounts,
            address(this),
            accounts,
            liqInstructions
        );
    }

    function test_canLiquidate_fail_whenShortfallInsufficient() public {
        skip(gaugeManager.gaugeStartTime() - block.timestamp);

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
        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(strategyCBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);

        _prepareBALRETH(user1, 10_000e18);
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 1_000e18);
        strategyCBALRETH.deposit(1_000e18, user1);
        strategyCBALRETH.postCollateral(999e18);
        vm.stopPrank();

        IMarketManager.LiqInstructions memory liqInstructions = IMarketManager.LiqInstructions({
            collateralToken: address(strategyCBALRETH),
            debtToken: address(borrowableCUSDC),
            numAccounts: 1,
            liquidateExact: false,
            liquidatedShares: 0,
            debtRepaid: 0,
            badDebt: 0
        });

        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__NoLiquidationAvailable.selector
        );
        marketManagerIsolated.canLiquidate(
            debtAmounts,
            address(this),
            accounts,
            liqInstructions
        );
    }

    function test_canLiquidate_success() public {
        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(strategyCBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 100_000e6);

        _setupUserPositionAndOracles();

        IMarketManager.LiqInstructions memory liqInstructions = IMarketManager.LiqInstructions({
            collateralToken: address(strategyCBALRETH),
            debtToken: address(borrowableCUSDC),
            numAccounts: 1,
            liquidateExact: false,
            liquidatedShares: 0,
            debtRepaid: 0,
            badDebt: 0
        });

        // Price of ETH drops and balRETH collateral goes below required collateral ratio
        mockWethFeed.setMockAnswer(1000e8);
        mockRethFeed.setMockAnswer(1000e8);

        vm.prank(address(borrowableCUSDC));

        // =================== RESULTS ==================
        (
            IMarketManager.LiqResults memory liqResults,
            uint256[] memory debtAmountsReturned
        ) = marketManagerIsolated.canLiquidate(
            debtAmounts,
            address(this),
            accounts,
            liqInstructions
        );

        // print out all values returned by canLiquidate
        console2.log("==== CanLiquidate Results ====");
        console2.log("liqResults.liquidatedShares[0]", liqResults.liquidatedShares[0]);
        console2.log("liqResults.debtRepaid", liqResults.debtRepaid);
        console2.log("liqResults.badDebtRealized", liqResults.badDebtRealized);
        console2.log("debtAmounts", debtAmountsReturned[0]);

        uint256 collateralAvailable = 1e18 - 1;
        
        ExpectedLiquidationValues memory expectedLiqValues = 
            _calculateExpectedLiquidationValues(
                LiquidationParams ({
                    borrower: user1,
                    collateralToken: address(strategyCBALRETH),
                    borrowedToken: address(borrowableCUSDC),
                    isLiquidateExact: false,
                    liquidateExactAmount: 0,
                    isAuction: false,
                    isMultiMarketTest: false,
                    marketManagerId: 0
                })
            );


        // Validate liqResults.liquidatedShares[0]
        assertEq(
            liqResults.liquidatedShares[0],
            collateralAvailable, 
            "liquidatedShares = collateralAvailable mismatch"
        );

        assertEq(
            liqResults.liquidatedShares[0],
            expectedLiqValues.collateralLiquidated,
            "liquidatedShares[0] = expectedCollateralSeized mismatch"
        );

        // validate liqResults.debtRepaid
        assertEq(
            liqResults.debtRepaid,
            expectedLiqValues.debtRepaid, 
            "debtRepaid = expectedRepayAmount mismatch"
        );

        // Should have bad debt
        assertEq(liqResults.badDebtRealized, expectedLiqValues.badDebt, "badDebtRealized mismatch");

        // validate debtAmountsReturned, debt cleared
        assertEq(debtAmountsReturned[0], 1e9, "debtAmountsReturned mismatch");
    }

    function _setupUserPositionAndOracles() internal {
        skip(gaugeManager.gaugeStartTime() - block.timestamp);

        mockWethFeed.setMockAnswer(3000e8);
        mockRethFeed.setMockAnswer(3000e8);

        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);
        chainlinkUsdcUsd.updateRoundData(
            0,
            1e8,
            block.timestamp,
            block.timestamp
        );

        // Mint strategyCBALRETH for collateral
        _prepareBALRETH(user1, 10_000e18);
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 1_000e18);
        strategyCBALRETH.deposit(1e18, user1);
        strategyCBALRETH.postCollateral(1e18 - 1);

        // Borrow eUSDC with strategyCBALRETH as collateral
        _prepareUSDC(address(borrowableCUSDC), 100_000e6);
        borrowableCUSDC.borrow(1000e6, user1);
        vm.stopPrank();

        assertEq(usdc.balanceOf(user1), 1000e6);
    }

}
