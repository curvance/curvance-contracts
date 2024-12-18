// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManager } from "../TestBaseMarketManager.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";
import { PriceReturnData } from "contracts/interfaces/IOracleAdaptor.sol";
import { WAD } from "contracts/libraries/Constants.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

contract CanLiquidateTest is TestBaseMarketManager {
    function test_canLiquidate_fail_whenETokenNotListed() public {
        vm.expectRevert(MarketManager.MarketManager__TokenNotListed.selector);
        marketManager.canLiquidate(
            address(eUSDC),
            address(pBALRETH),
            user1,
            1000,
            false
        );
    }

    function test_canLiquidate_fail_whenPTokenNotListed() public {
        marketManager.listToken(address(eUSDC));
        vm.expectRevert(MarketManager.MarketManager__TokenNotListed.selector);
        marketManager.canLiquidate(
            address(eUSDC),
            address(pBALRETH),
            user1,
            1000,
            false
        );
    }

    function test_canLiquidate_fail_whenCollRatioZero() public {
        marketManager.listToken(address(eUSDC));
        marketManager.listToken(address(pBALRETH));

        vm.expectRevert(
            MarketManager.MarketManager__InvalidParameter.selector
        );
        marketManager.canLiquidate(
            address(eUSDC),
            address(pBALRETH),
            user1,
            1000,
            false
        );
    }

    function test_canLiquidate_fail_whenUserHasNotEnteredAnyMarket() public {
        marketManager.listToken(address(eUSDC));
        marketManager.listToken(address(pBALRETH));
        marketManager.updatePositionToken(
            address(pBALRETH),
            7000,
            4000,
            3000,
            200,
            400,
            10,
            1000
        );

        vm.expectRevert(
            MarketManager.MarketManager__NoLiquidationAvailable.selector
        );
        marketManager.canLiquidate(
            address(eUSDC),
            address(pBALRETH),
            user1,
            1000,
            false
        );
    }

    function test_canLiquidate_fail_whenAccountHasNoBorrowsAndCollateralPosted()
        public
    {
        marketManager.listToken(address(eUSDC));
        marketManager.listToken(address(pBALRETH));
        marketManager.updatePositionToken(
            address(pBALRETH),
            7000,
            4000,
            3000,
            200,
            400,
            10,
            1000
        );

        vm.expectRevert(
            MarketManager.MarketManager__NoLiquidationAvailable.selector
        );
        marketManager.canLiquidate(
            address(eUSDC),
            address(pBALRETH),
            user1,
            1000,
            false
        );
    }

    function test_canLiquidate_fail_whenShortfallInsufficient() public {
        skip(gaugeManager.startTime() - block.timestamp);

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
        marketManager.listToken(address(eUSDC));
        marketManager.listToken(address(pBALRETH));
        marketManager.updatePositionToken(
            address(pBALRETH),
            7000,
            4000,
            3000,
            200,
            400,
            10,
            1000
        );
        address[] memory tokens = new address[](1);
        tokens[0] = address(pBALRETH);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManager.setPTokenCollateralCaps(tokens, caps);

        deal(address(balRETH), user1, 10_000e18);
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1_000e18);
        pBALRETH.deposit(1_000e18, user1);
        marketManager.postCollateral(user1, address(pBALRETH), 999e18);
        vm.stopPrank();

        vm.expectRevert(
            MarketManager.MarketManager__NoLiquidationAvailable.selector
        );
        marketManager.canLiquidate(
            address(eUSDC),
            address(pBALRETH),
            user1,
            1000,
            false
        );
    }

    function test_canLiquidate_success() public {
        marketManager.listToken(address(eUSDC));
        marketManager.listToken(address(pBALRETH));
        marketManager.updatePositionToken(
            address(pBALRETH),
            7000,
            4000,
            3000,
            200,
            400,
            10,
            1000
        );
        address[] memory tokens = new address[](1);
        tokens[0] = address(pBALRETH);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManager.setPTokenCollateralCaps(tokens, caps);

        skip(gaugeManager.startTime() - block.timestamp);

        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);
        chainlinkUsdcUsd.updateRoundData(
            0,
            1e8,
            block.timestamp,
            block.timestamp
        );

        // Mint pBALRETH for collateral
        deal(address(balRETH), user1, 10_000e18);
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1_000e18);
        pBALRETH.deposit(1e18, user1);
        marketManager.postCollateral(user1, address(pBALRETH), 1e18 - 1);

        // Borrow eUSDC with pBALRETH as collateral
        deal(_USDC_ADDRESS, address(eUSDC), 100_000e6);
        eUSDC.borrow(1000e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(user1), 1000e6);

        // Can not liquidate yet while collateral is above required collateral ratio
        vm.expectRevert(
            MarketManager.MarketManager__NoLiquidationAvailable.selector
        );
        marketManager.canLiquidate(
            address(eUSDC),
            address(pBALRETH),
            user1,
            1000e6,
            false
        );

        // Price of ETH drops and balRETH collateral goes below required collateral ratio
        // and can now liquidate
        mockWethFeed.setMockAnswer(1000e8);
        mockRethFeed.setMockAnswer(1000e8);

        // =================== RESULTS ==================
        (
            uint256 liqAmount,
            uint256 liquidatedTokens,
            uint256 protocolTokens
        ) = marketManager.canLiquidate(
                address(eUSDC),
                address(pBALRETH),
                user1,
                1000e6,
                false
            );

        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint256 baseCFactor,
            uint256 cFactorCurve
        ) = marketManager.tokenData(address(pBALRETH));

        uint256 cFactor = baseCFactor + ((cFactorCurve * 1e18) / WAD);
        uint256 debtAmount = (cFactor * eUSDC.debtBalanceCached(user1)) / WAD;

        PriceReturnData memory data = balRETHAdapter.getPrice(
            _BAL_WETH_RETH_ADDRESS,
            true,
            true
        );

        uint256 collateralAvailable = 1e18 - 1;
        uint256 expectedLiqAmount;
        uint256 expectedProtocolTokens;
        {
            (
                ,
                ,
                ,
                ,
                uint256 liqBaseIncentive,
                uint256 liqCurve,
                ,
                ,

            ) = marketManager.tokenData(address(pBALRETH));

            uint256 earnTokenPrice = 1e18; // USDC price
            uint256 incentive = liqBaseIncentive + liqCurve;
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
            uint256 liqFee = (WAD * (10 * 1e14)) / liqBaseIncentive;
            expectedProtocolTokens = (collateralAvailable * liqFee) / WAD;
        }

        assertEq(
            liqAmount,
            expectedLiqAmount,
            "canLiquidate() returns the max liquidation amount based on close factor"
        );

        assertEq(
            liquidatedTokens,
            collateralAvailable,
            "canLiquidate() returns the amount of PTokens to be seized in liquidation"
        );

        assertEq(
            protocolTokens,
            expectedProtocolTokens,
            "canLiquidate() returns the amount of PTokens to be seized for the protocol"
        );

        assertGt(liquidatedTokens, protocolTokens);
    }
}
