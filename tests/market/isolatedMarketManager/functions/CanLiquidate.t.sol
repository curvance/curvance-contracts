// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManagerIsolated } from "../TestBaseMarketManagerIsolated.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";
import { PriceReturnData } from "contracts/interfaces/IOracleAdaptor.sol";
import { WAD } from "contracts/libraries/Constants.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import "forge-std/console2.sol";

contract CanLiquidateTestIsolated is TestBaseMarketManagerIsolated {
    
    address[] accounts = new address[](1);
    uint256[] debtAmounts = new uint256[](1);

    constructor() {
        accounts[0] = user1;
        debtAmounts[0] = 1000e6;
    }
    
    function test_canLiquidate_fail_whenETokenNotListed() public {
        IMarketManager.LiqInstructions memory liqInstructions = IMarketManager.LiqInstructions({
            eToken: address(eUSDC),
            pToken: address(pBALRETH),
            numAccounts: 1,
            liquidateExact: false,
            eTokenRepaid: 0,
            pTokenLiquidated: 0,
            badDebt: 0
        });

        vm.expectRevert(MarketManager.MarketManager__TokenNotListed.selector);
        marketManager.canLiquidate(
            address(this),
            accounts,
            debtAmounts,
            liqInstructions);
    }

    function test_canLiquidate_fail_whenPTokenNotListed() public {
        // marketManager.listToken(address(eUSDC));
        IMarketManager.LiqInstructions memory liqInstructions = IMarketManager.LiqInstructions({
            eToken: address(eUSDC),
            pToken: address(pBALRETH),
            numAccounts: 1,
            liquidateExact: false,
            eTokenRepaid: 0,
            pTokenLiquidated: 0,
            badDebt: 0
        });

        vm.expectRevert(MarketManager.MarketManager__TokenNotListed.selector);
        marketManager.canLiquidate(
            address(this),
            accounts,
            debtAmounts,
            liqInstructions);
    }

    function test_canLiquidate_fail_whenCollRatioZero() public {
        deal(address(balRETH), address(this), 42069);
        balRETH.approve(address(pBALRETH), 42069);

        deal(address(_USDC_ADDRESS), address(this), 42069);
        usdc.approve(address(eUSDC), 42069);

        marketManager.listTokens(address(pBALRETH), address(eUSDC));

        IMarketManager.LiqInstructions memory liqInstructions = IMarketManager.LiqInstructions({
            eToken: address(eUSDC),
            pToken: address(pBALRETH),
            numAccounts: 1,
            liquidateExact: false,
            eTokenRepaid: 0,
            pTokenLiquidated: 0,
            badDebt: 0
        });


        vm.expectRevert(
            MarketManager.MarketManager__InvalidParameter.selector
        );
        marketManager.canLiquidate(
            address(this),
            accounts,
            debtAmounts,
            liqInstructions);
    }

    function test_canLiquidate_fail_whenUserHasNotEnteredAnyMarket() public {
        deal(address(balRETH), address(this), 42069);
        balRETH.approve(address(pBALRETH), 42069);

        deal(address(_USDC_ADDRESS), address(this), 42069);
        usdc.approve(address(eUSDC), 42069);

        marketManager.listTokens(address(pBALRETH), address(eUSDC));
        marketManager.updatePositionToken(
            7000,    // collRatio 70%
            4000,    // collReqSoft 40%
            3000,    // collReqHard 25%
            1000,    // liqIncBase 10%
            1500,    // liqIncHard 15%
            500,     // liqIncMin 5%
            2000,    // liqIncMax 20%
            2000,    // minEffectiveCFactor 20%
            5000,    // maxEffectiveCFactor 50%
            2000     // baseCFactor 20%
        );

        IMarketManager.LiqInstructions memory liqInstructions = IMarketManager.LiqInstructions({
            eToken: address(eUSDC),
            pToken: address(pBALRETH),
            numAccounts: 1,
            liquidateExact: false,
            eTokenRepaid: 0,
            pTokenLiquidated: 0,
            badDebt: 0
        });


        vm.expectRevert(
            MarketManager.MarketManager__NoLiquidationAvailable.selector
        );
        marketManager.canLiquidate(
            address(this),
            accounts,
            debtAmounts,
            liqInstructions);
    }

    function test_canLiquidate_fail_whenAccountHasNoBorrowsAndCollateralPosted()
        public
    {
        deal(address(balRETH), address(this), 42069);
        balRETH.approve(address(pBALRETH), 42069);

        deal(address(_USDC_ADDRESS), address(this), 42069);
        usdc.approve(address(eUSDC), 42069);

        marketManager.listTokens(address(pBALRETH), address(eUSDC));
        marketManager.updatePositionToken(
            7000,    // collRatio 70%
            4000,    // collReqSoft 40%
            3000,    // collReqHard 25%
            1000,    // liqIncBase 10%
            1500,    // liqIncHard 15%
            500,     // liqIncMin 5%
            2000,    // liqIncMax 20%
            2000,    // minEffectiveCFactor 20%
            5000,    // maxEffectiveCFactor 50%
            2000     // baseCFactor 20%
        );

        IMarketManager.LiqInstructions memory liqInstructions = IMarketManager.LiqInstructions({
            eToken: address(eUSDC),
            pToken: address(pBALRETH),
            numAccounts: 1,
            liquidateExact: false,
            eTokenRepaid: 0,
            pTokenLiquidated: 0,
            badDebt: 0
        });


        vm.expectRevert(
            MarketManager.MarketManager__NoLiquidationAvailable.selector
        );
        marketManager.canLiquidate(
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
        deal(address(balRETH), address(this), 42069);
        balRETH.approve(address(pBALRETH), 42069);

        deal(address(_USDC_ADDRESS), address(this), 42069);
        usdc.approve(address(eUSDC), 42069);

        marketManager.listTokens(address(pBALRETH), address(eUSDC));
        marketManager.updatePositionToken(
            7000,    // collRatio 70%
            4000,    // collReqSoft 40%
            3000,    // collReqHard 25%
            1000,    // liqIncBase 10%
            1500,    // liqIncHard 15%
            500,     // liqIncMin 5%
            2000,    // liqIncMax 20%
            2000,    // minEffectiveCFactor 20%
            5000,    // maxEffectiveCFactor 50%
            2000     // baseCFactor 20%
        );

        address[] memory tokens = new address[](1);
        tokens[0] = address(pBALRETH);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManager.setPTokenCollateralCaps(tokens, caps);

        _prepareBALRETH(user1, 10_000e18);
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1_000e18);
        pBALRETH.deposit(1_000e18, user1);
        marketManager.postCollateral(user1, address(pBALRETH), 999e18);
        vm.stopPrank();

        IMarketManager.LiqInstructions memory liqInstructions = IMarketManager.LiqInstructions({
            eToken: address(eUSDC),
            pToken: address(pBALRETH),
            numAccounts: 1,
            liquidateExact: false,
            eTokenRepaid: 0,
            pTokenLiquidated: 0,
            badDebt: 0
        });

        vm.expectRevert(
            MarketManager.MarketManager__NoLiquidationAvailable.selector
        );
        marketManager.canLiquidate(
            address(this),
            accounts,
            debtAmounts,
            liqInstructions);
    }

    event DebugUint256(string message, uint256 value);

    function test_canLiquidate_success() public {
        deal(address(balRETH), address(this), 42069);
        balRETH.approve(address(pBALRETH), 42069);

        deal(address(_USDC_ADDRESS), address(this), 42069);
        usdc.approve(address(eUSDC), 42069);

        marketManager.listTokens(address(pBALRETH), address(eUSDC));
        marketManager.updatePositionToken(
            7000,    // collRatio 70%
            4000,    // collReqSoft 40%
            3000,    // collReqHard 25%
            1000,    // liqIncBase 10%
            1500,    // liqIncHard 15%
            500,     // liqIncMin 5%
            2000,    // liqIncMax 20%,
            2000,    // minEffectiveCFactor 20%
            5000,    // maxEffectiveCFactor 50%
            2000     // baseCFactor 20%
        );
        address[] memory tokens = new address[](1);
        tokens[0] = address(pBALRETH);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManager.setPTokenCollateralCaps(tokens, caps);

        skip(gaugeManager.gaugeStartTime() - block.timestamp);

        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);
        chainlinkUsdcUsd.updateRoundData(
            0,
            1e8,
            block.timestamp,
            block.timestamp
        );

        // Mint pBALRETH for collateral
        _prepareBALRETH(user1, 10_000e18);
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1_000e18);
        pBALRETH.deposit(1e18, user1);
        marketManager.postCollateral(user1, address(pBALRETH), 1e18 - 1);

        // Borrow eUSDC with pBALRETH as collateral
        _prepareUSDC(address(eUSDC), 100_000e6);
        eUSDC.borrow(1000e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(user1), 1000e6);

        IMarketManager.LiqInstructions memory liqInstructions = IMarketManager.LiqInstructions({
            eToken: address(eUSDC),
            pToken: address(pBALRETH),
            numAccounts: 1,
            liquidateExact: false,
            eTokenRepaid: 0,
            pTokenLiquidated: 0,
            badDebt: 0
        });


        // Can not liquidate yet while collateral is above required collateral ratio
        // vm.expectRevert(
        //     MarketManager.MarketManager__NoLiquidationAvailable.selector
        // );
        // marketManager.canLiquidate(
        //     address(this),
        //     accounts,
        //     debtAmounts,
        //     liqInstructions);

        // Price of ETH drops and balRETH collateral goes below required collateral ratio
        // and can now liquidate
        mockWethFeed.setMockAnswer(1000e8);
        mockRethFeed.setMockAnswer(1000e8);

        // =================== RESULTS ==================
        (
            IMarketManager.LiqResults memory liqResults,
            uint256[] memory debtAmountsReturned
        ) = marketManager.canLiquidate(
            address(this),
            accounts,
            debtAmounts,
            liqInstructions);

        (, , , , , , , , uint256 baseCFactor, uint256 cFactorCurve, , ) = marketManager
            .tokenData(address(pBALRETH));

        uint256 cFactor = baseCFactor + ((cFactorCurve * 1e18) / WAD);
        uint256 debtAmount = (cFactor * eUSDC.debtBalanceCached(user1)) / WAD;

        PriceReturnData memory data = balRETHAdapter.getPrice(
            _BAL_WETH_RETH_ADDRESS,
            true,
            true
        );

        uint256 collateralAvailable = 1e18 - 1;
        uint256 expectedLiqAmount;
        {
            (
                ,
                ,
                ,
                ,
                uint256 liqBaseIncentive,
                ,
                ,
                ,
                ,
                ,
                ,
            ) = marketManager.tokenData(address(pBALRETH));

            uint256 earnTokenPrice = 1e18; // USDC price
            
            uint256 incentive = liqBaseIncentive;

            console2.log("data.price", data.price);
            console2.log("pBALRETH.exchangeRateCached()", pBALRETH.exchangeRateCached());
            
            uint256 debtToCollateralRatio = (incentive *
                earnTokenPrice *
                WAD) / (data.price * pBALRETH.exchangeRateCached());
            uint256 amountAdjusted = (debtAmount *
                (10 ** pBALRETH.decimals())) / (10 ** eUSDC.decimals());
            uint256 expectedLiquidatedTokens = (amountAdjusted *
                debtToCollateralRatio) / WAD;
            expectedLiqAmount = FixedPointMathLib.mulDivUp(
                debtAmount,
                collateralAvailable,
                expectedLiquidatedTokens
            );
        }
        // print out all values returned by canLiquidate
        console2.log("==== CanLiquidate Results ====");
        console2.log("liqResults.liquidatedAmounts[0]", liqResults.liquidatedAmounts[0]);
        console2.log("liqResults.debtRepaid", liqResults.debtRepaid);
        console2.log("liqResults.badDebtRealized", liqResults.badDebtRealized);
        console2.log("debtAmounts", debtAmountsReturned[0]);
        emit DebugUint256("debtAmounts", debtAmountsReturned[0]);

        // validate liqResults.liquidatedAmounts[0]
        // Full liquidation
        assertEq(
            liqResults.liquidatedAmounts[0],
            collateralAvailable
        );

        // validate liqResults.debtRepaid
        assertEq(
            liqResults.debtRepaid,
            expectedLiqAmount
        );
        



    }
}
