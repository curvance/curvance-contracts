// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManagerIsolated } from "../TestBaseMarketManagerIsolated.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { PriceReturnData } from "contracts/interfaces/IOracleAdaptor.sol";
import { WAD } from "contracts/libraries/Constants.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import "forge-std/console2.sol";

contract CanLiquidateTestIsolated is TestBaseMarketManagerIsolated {
    
    address[] accounts = new address[](1);
    uint256[] debtAmounts = new uint256[](1);

    uint256 eTokenUnderlyingPrice = 1e18;

    constructor() {
        accounts[0] = user1;
        debtAmounts[0] = 1000e6;
    }
    
    function test_canLiquidate_fail_whenETokenNotListed() public {
        IMarketManager.LiqInstructions memory liqInstructions = IMarketManager.LiqInstructions({
            collateralToken: address(borrowableCUSDC),
            debtToken: address(simpleCBALRETH),
            numAccounts: 1,
            liquidateExact: false,
            collateralLiquidated: 0,
            debtRepaid: 0,
            badDebt: 0
        });

        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        marketManagerIsolated.canLiquidate(
            address(this),
            accounts,
            debtAmounts,
            liqInstructions);
    }

    function test_canLiquidate_fail_whenPTokenNotListed() public {
        // marketManager.listToken(address(borrowableCUSDC));
        IMarketManager.LiqInstructions memory liqInstructions = IMarketManager.LiqInstructions({
            collateralToken: address(borrowableCUSDC),
            debtToken: address(simpleCBALRETH),
            numAccounts: 1,
            liquidateExact: false,
            collateralLiquidated: 0,
            debtRepaid: 0,
            badDebt: 0
        });

        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        marketManagerIsolated.canLiquidate(
            address(this),
            accounts,
            debtAmounts,
            liqInstructions);
    }

    function test_canLiquidate_fail_whenCollRatioZero() public {
        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(simpleCBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(simpleCBALRETH), address(borrowableCUSDC));

        IMarketManager.LiqInstructions memory liqInstructions = IMarketManager.LiqInstructions({
            collateralToken: address(borrowableCUSDC),
            debtToken: address(simpleCBALRETH),
            numAccounts: 1,
            liquidateExact: false,
            collateralLiquidated: 0,
            debtRepaid: 0,
            badDebt: 0
        });

        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InvalidParameter.selector
        );
        marketManagerIsolated.canLiquidate(
            address(this),
            accounts,
            debtAmounts,
            liqInstructions);
    }

    function test_canLiquidate_fail_whenUserHasNotEnteredAnyMarket() public {
        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(simpleCBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(simpleCBALRETH), address(borrowableCUSDC));
        _setCTokenConfigBasic(address(simpleCBALRETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);

        IMarketManager.LiqInstructions memory liqInstructions = IMarketManager.LiqInstructions({
            collateralToken: address(borrowableCUSDC),
            debtToken: address(simpleCBALRETH),
            numAccounts: 1,
            liquidateExact: false,
            collateralLiquidated: 0,
            debtRepaid: 0,
            badDebt: 0
        });

        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__NoLiquidationAvailable.selector
        );
        marketManagerIsolated.canLiquidate(
            address(this),
            accounts,
            debtAmounts,
            liqInstructions);
    }

    function test_canLiquidate_fail_whenAccountHasNoBorrowsAndCollateralPosted()
        public
    {
        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(simpleCBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(simpleCBALRETH), address(borrowableCUSDC));
        _setCTokenConfigBasic(address(simpleCBALRETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);

        IMarketManager.LiqInstructions memory liqInstructions = IMarketManager.LiqInstructions({
            collateralToken: address(borrowableCUSDC),
            debtToken: address(simpleCBALRETH),
            numAccounts: 1,
            liquidateExact: false,
            collateralLiquidated: 0,
            debtRepaid: 0,
            badDebt: 0
        });

        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__NoLiquidationAvailable.selector
        );
        marketManagerIsolated.canLiquidate(
            address(this),
            accounts,
            debtAmounts,
            liqInstructions);
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
        balRETH.approve(address(simpleCBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(simpleCBALRETH), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(simpleCBALRETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);

        _prepareBALRETH(user1, 10_000e18);
        vm.startPrank(user1);
        balRETH.approve(address(simpleCBALRETH), 1_000e18);
        simpleCBALRETH.deposit(1_000e18, user1);
        simpleCBALRETH.postCollateral(999e18);
        vm.stopPrank();

        IMarketManager.LiqInstructions memory liqInstructions = IMarketManager.LiqInstructions({
            collateralToken: address(borrowableCUSDC),
            debtToken: address(simpleCBALRETH),
            numAccounts: 1,
            liquidateExact: false,
            collateralLiquidated: 0,
            debtRepaid: 0,
            badDebt: 0
        });

        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__NoLiquidationAvailable.selector
        );
        marketManagerIsolated.canLiquidate(
            address(this),
            accounts,
            debtAmounts,
            liqInstructions);
    }

    event DebugUint256(string message, uint256 value);

    function test_canLiquidate_success() public {
        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(simpleCBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(simpleCBALRETH), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(simpleCBALRETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 100_000e6);

        _setupUserPositionAndOracles();

        IMarketManager.LiqInstructions memory liqInstructions = IMarketManager.LiqInstructions({
            collateralToken: address(borrowableCUSDC),
            debtToken: address(simpleCBALRETH),
            numAccounts: 1,
            liquidateExact: false,
            collateralLiquidated: 0,
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
            address(this),
            accounts,
            debtAmounts,
            liqInstructions);

        

        // print out all values returned by canLiquidate
        console2.log("==== CanLiquidate Results ====");
        console2.log("liqResults.liquidatedAmounts[0]", liqResults.liquidatedAmounts[0]);
        console2.log("liqResults.debtRepaid", liqResults.debtRepaid);
        console2.log("liqResults.badDebtRealized", liqResults.badDebtRealized);
        console2.log("debtAmounts", debtAmountsReturned[0]);

        uint256 collateralAvailable = 1e18 - 1;
        (uint256 expectedRepayAmount, uint256 expectedCollateralSeized, uint256 pTokenPrice) = _calculateExpectedRepayAndLiquidated(collateralAvailable);

        uint256 expectedBadDebt = _calculateBadDebt(
            expectedRepayAmount,
            collateralAvailable,
            expectedCollateralSeized,
            pTokenPrice
        );

        // validate liqResults.liquidatedAmounts[0]
        assertEq(
            liqResults.liquidatedAmounts[0],
            collateralAvailable, 
            "liquidatedAmounts = collateralAvailable mismatch"
        );

        assertEq(
            liqResults.liquidatedAmounts[0],
            expectedCollateralSeized,
            "liquidatedAmounts[0] = expectedCollateralSeized mismatch"
        );

        // validate liqResults.debtRepaid
        assertEq(
            liqResults.debtRepaid,
            expectedRepayAmount, 
            "debtRepaid = expectedRepayAmount mismatch"
        );

        // Should have bad debt
        assertEq(liqResults.badDebtRealized, expectedBadDebt, "badDebtRealized mismatch");

        // validate debtAmountsReturned, debt cleared
        assertEq(debtAmountsReturned[0], 1e9, "debtAmountsReturned mismatch");
    }

    function _setupUserPositionAndOracles() internal {
        skip(gaugeManager.gaugeStartTime() - block.timestamp);

        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);
        chainlinkUsdcUsd.updateRoundData(
            0,
            1e8,
            block.timestamp,
            block.timestamp
        );

        // Mint simpleCBALRETH for collateral
        _prepareBALRETH(user1, 10_000e18);
        vm.startPrank(user1);
        balRETH.approve(address(simpleCBALRETH), 1_000e18);
        simpleCBALRETH.deposit(1e18, user1);
        simpleCBALRETH.postCollateral(1e18 - 1);

        // Borrow eUSDC with simpleCBALRETH as collateral
        _prepareUSDC(address(borrowableCUSDC), 100_000e6);
        borrowableCUSDC.borrow(1000e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(user1), 1000e6);
    }

    function _calculateExpectedRepayAndLiquidated(uint256 collateralAvailable) internal view returns (uint256 maxAmount, uint256 liquidatedPTokens, uint256) {
        // Get price data
        PriceReturnData memory priceData = balRETHAdapter.getPrice(
            _BAL_WETH_RETH_ADDRESS,
            true,
            true
        );

        uint256 baseCFactor = 2e17;
        uint256 cFactorCurve = 8e17;
        uint256 liqBaseIncentive = 1.1e18;
        uint256 liqCurve = 5e16;
        
        // Hard liquidation factor (constant)
        uint256 lFactor = 1e18;
        
        // default values since not using ASS
        uint256 auctionCFactor = baseCFactor + ((cFactorCurve * lFactor) / WAD);

        uint256 auctionLiqIncentive = liqBaseIncentive +
                ((liqCurve * lFactor) / WAD);

        // uint256 pTokenDecimals = 1e18;
        // uint256 eTokenDecimals = 1e6;

        uint256 debtToCollateralMultiplier = 
        (((auctionLiqIncentive * eTokenUnderlyingPrice * WAD) /
            (priceData.price * 1e18)) *
            1e18) / 1e6;

        maxAmount = (auctionCFactor * 1000e6) / WAD;

        liquidatedPTokens = (maxAmount * debtToCollateralMultiplier) / WAD;

        console2.log("liquidatedPTokens 000", liquidatedPTokens);

        maxAmount = FixedPointMathLib.mulDivUp(
            maxAmount,
            collateralAvailable,
            liquidatedPTokens
        );

        liquidatedPTokens = collateralAvailable;


        return (maxAmount, liquidatedPTokens, priceData.price);
    }

    function _calculateBadDebt(
        uint256 debtAmount,
        uint256 collateralAvailable, 
        uint256 liquidatedPTokens, 
        uint256 pTokenUnderlyingPrice) internal view returns (uint256 badDebt) {

            uint256 debtBalance = 1e9;

            badDebt = (debtBalance - debtAmount) -
            FixedPointMathLib.mulDivUp(
                ((collateralAvailable - liquidatedPTokens) * 1e18) / WAD,
                pTokenUnderlyingPrice,
                (eTokenUnderlyingPrice * WAD) / 1e6
            );
    }
}
