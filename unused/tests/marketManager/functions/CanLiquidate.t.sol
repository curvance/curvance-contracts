// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManager } from "../TestBaseMarketManager.sol";

import { IOracleAdaptor } from "contracts/interfaces/IOracleAdaptor.sol";
import { WAD } from "contracts/libraries/ConstantsLib.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

contract CanLiquidateTest is TestBaseMarketManager {
    function test_canLiquidate_fail_whenETokenNotListed() public {
        vm.expectRevert(MarketManager.MarketManager__TokenNotListed.selector);
        marketManager.canLiquidate(
            address(borrowableCUSDC),
            address(simpleCBALRETH),
            user1,
            1000,
            false
        );
    }

    function test_canLiquidate_fail_whenPTokenNotListed() public {
        marketManager.listToken(address(borrowableCUSDC));
        vm.expectRevert(MarketManager.MarketManager__TokenNotListed.selector);
        marketManager.canLiquidate(
            address(borrowableCUSDC),
            address(simpleCBALRETH),
            user1,
            1000,
            false
        );
    }

    function test_canLiquidate_fail_whenCollRatioZero() public {
        marketManager.listToken(address(borrowableCUSDC));
        marketManager.listToken(address(simpleCBALRETH));

        vm.expectRevert(
            MarketManager.MarketManager__InvalidParameter.selector
        );
        marketManager.canLiquidate(
            address(borrowableCUSDC),
            address(simpleCBALRETH),
            user1,
            1000,
            false
        );
    }

    function test_canLiquidate_fail_whenUserHasNotEnteredAnyMarket() public {
        marketManager.listToken(address(borrowableCUSDC));
        marketManager.listToken(address(simpleCBALRETH));
        marketManager.updatePositionToken(
            address(simpleCBALRETH),
            7000,
            4000,
            3000,
            200,
            400,
            1000
        );

        vm.expectRevert(
            MarketManager.MarketManager__NoLiquidationAvailable.selector
        );
        marketManager.canLiquidate(
            address(borrowableCUSDC),
            address(simpleCBALRETH),
            user1,
            1000,
            false
        );
    }

    function test_canLiquidate_fail_whenAccountHasNoBorrowsAndCollateralPosted()
        public
    {
        marketManager.listToken(address(borrowableCUSDC));
        marketManager.listToken(address(simpleCBALRETH));
        marketManager.updatePositionToken(
            address(simpleCBALRETH),
            7000,
            4000,
            3000,
            200,
            400,
            1000
        );

        vm.expectRevert(
            MarketManager.MarketManager__NoLiquidationAvailable.selector
        );
        marketManager.canLiquidate(
            address(borrowableCUSDC),
            address(simpleCBALRETH),
            user1,
            1000,
            false
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
        marketManager.listToken(address(borrowableCUSDC));
        marketManager.listToken(address(simpleCBALRETH));
        marketManager.updatePositionToken(
            address(simpleCBALRETH),
            7000,
            4000,
            3000,
            200,
            400,
            1000
        );
        address[] memory tokens = new address[](1);
        tokens[0] = address(simpleCBALRETH);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManager.setCollateralCaps(tokens, caps);

        _prepareBALRETH(user1, 10_000e18);
        vm.startPrank(user1);
        balRETH.approve(address(simpleCBALRETH), 1_000e18);
        simpleCBALRETH.deposit(1_000e18, user1);
        simpleCBALRETH.postCollateral(999e18);
        vm.stopPrank();

        vm.expectRevert(
            MarketManager.MarketManager__NoLiquidationAvailable.selector
        );
        marketManager.canLiquidate(
            address(borrowableCUSDC),
            address(simpleCBALRETH),
            user1,
            1000,
            false
        );
    }

    function test_canLiquidate_success() public {
        marketManager.listToken(address(borrowableCUSDC));
        marketManager.listToken(address(simpleCBALRETH));
        marketManager.updatePositionToken(
            address(simpleCBALRETH),
            7000,
            4000,
            3000,
            200,
            400,
            1000
        );
        address[] memory tokens = new address[](1);
        tokens[0] = address(simpleCBALRETH);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManager.setCollateralCaps(tokens, caps);

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

        // Can not liquidate yet while collateral is above required collateral ratio
        vm.expectRevert(
            MarketManager.MarketManager__NoLiquidationAvailable.selector
        );
        marketManager.canLiquidate(
            address(borrowableCUSDC),
            address(simpleCBALRETH),
            user1,
            1000e6,
            false
        );

        // Price of ETH drops and balRETH collateral goes below required collateral ratio
        // and can now liquidate
        mockWethFeed.setMockAnswer(1000e8);
        mockRethFeed.setMockAnswer(1000e8);

        // =================== RESULTS ==================
        (uint256 liqAmount, uint256 liquidatedTokens) = marketManager
            .canLiquidate(
                address(borrowableCUSDC),
                address(simpleCBALRETH),
                user1,
                1000e6,
                false
            );

        (, , , , , , uint256 closeFactorBase, uint256 closeFactorCurve) = marketManager
            .tokenData(address(simpleCBALRETH));

        uint256 cFactor = closeFactorBase + ((closeFactorCurve * 1e18) / WAD);
        uint256 debtAmount = (cFactor * borrowableCUSDC.debtBalance(user1)) / WAD;

        IOracleAdaptor.PricingResult memory result = balRETHAdapter.getPrice(
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
                uint256 liqCurve,
                ,

            ) = marketManager.tokenData(address(simpleCBALRETH));

            uint256 earnTokenPrice = 1e18; // USDC price
            uint256 incentive = liqBaseIncentive + liqCurve;
            uint256 debtToCollateralRatio = (incentive *
                earnTokenPrice *
                WAD) / (result.price * simpleCBALRETH.exchangeRate());
            uint256 amountAdjusted = (debtAmount *
                (10 ** simpleCBALRETH.decimals())) / (10 ** borrowableCUSDC.decimals());
            uint256 expectedLiquidatedTokens = (amountAdjusted *
                debtToCollateralRatio) / WAD;
            expectedLiqAmount = FixedPointMathLib.mulDivUp(
                debtAmount,
                collateralAvailable,
                expectedLiquidatedTokens
            );
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
    }
}
