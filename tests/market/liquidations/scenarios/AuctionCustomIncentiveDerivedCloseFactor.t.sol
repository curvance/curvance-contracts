// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { WAD_SQUARED, WAD_SQUARED_BPS_OFFSET } from "contracts/libraries/ConstantsLib.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { console2 } from "forge-std/console2.sol";

  // This test demonstrates partial zero values in auction liquidations.
  // Tests that custom incentive + protocol-derived close factor works correctly.

  // Setup:
  //    User 1 has 1000 DAI collateral worth $1000 ($1 each)
  //    User 1 borrows 500 USDC ($10 each)
  //    Collateral requirement for soft liquidation: 40% (1.4x multiplier)
  //    Liquidation buffer: 10 basis points (0.1%)

  // Liquidation threshold calculation:
  //    For liquidation: debt * collReqSoft >= collateralValue * WAD
  //    Required: $500 * 1.4 >= collateralValue
  //    Threshold: collateralValue <= $700

  // Test scenario:
  //    DAI price drops to $0.70007 per DAI
  //    Collateral value: 1000 * $0.70007 = $700.07
  //    Regular liquidation lFactor: (500 * 1.4) / 700.07 = 0.9999 < 1.0  (Should fail)
  //    Auction liquidation: applies 10bps buffer (700.07 * 0.999 = $699.37)
  //    Auction lFactor: (500 * 1.4) / 699.37 = 1.0009 > 1.0  (Should succeed)

  // Expected results:
  //    Custom incentive (105%) is used for collateral calculation
  //    Protocol-derived close factor is used for debt repayment amount

contract AuctionCustomIncentiveDerivedCloseFactorTest is TestBaseMarketIsolated {
    address[] borrowers = [user1];

    function setUp() public override {
        super.setUp();

        // set up market
        _prepareDAI(address(this), 77777);
        _prepareUSDC(address(this), 100_000e6 + 77777);

        usdc.approve(address(borrowableCUSDC), 100_000e18 + 77777);
        dai.approve(address(borrowableCDAI), 77777);

        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(borrowableCDAI));

        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e6, 100_000e6);
        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 100_000e18);

        borrowableCUSDC.deposit(100_000e6, address(this));

        mockUsdcFeed.setMockAnswer(1e8);
        mockDaiFeed.setMockAnswer(1e8);

        // Set up user positions
        vm.startPrank(user1);
        _prepareDAI(user1, 1000e18);
        dai.approve(address(borrowableCDAI), 1000e18);
        borrowableCDAI.depositAsCollateral(1000e18, user1);
        borrowableCUSDC.borrow(500e6, user1);
        vm.stopPrank();

        mockDaiFeed.setMockAnswer(70007000);
    }

    function test_success_AuctionLiquidationWithNonZeroIncentiveAndZeroCloseFactor() public {
        _prepareUSDC(auctionPermsUser, 1000e6);

        vm.startPrank(auctionPermsUser);
        usdc.approve(address(borrowableCUSDC), 1000e6);
        // Set auction with lower non-zero incentive but zero close factor
        // liqIncMin = 10, so use 10500 (105%) which is lower than protocol-derived
        // Lower incentive = less collateral seized per unit debt
        uint256 lowerIncentive = 10500;
        marketManagerIsolated.setTransientLiquidationConfig(address(borrowableCDAI), lowerIncentive, 0);

        centralRegistry.unlockAuctionForMarket(address(marketManagerIsolated));

        // Verify values are stored correctly in transient storage
        {
            (, uint256 storedIncentive, uint256 storedCloseFactor) = marketManagerIsolated.getTransientLiquidationConfig();

            // CRITICAL ASSERTION 1: transient values are set correctly.
            assertEq(storedIncentive, lowerIncentive, "Custom lower incentive should be stored");
            assertEq(storedCloseFactor, 0, "Close factor should be stored as 0 to signal protocol-derived");
        }

        uint256 debtBefore = borrowableCUSDC.debtBalanceUpdated(user1);
        uint256 collateralBefore = borrowableCDAI.balanceOf(user1);
        uint256 expectedMaxDebtRepaid;
        {
            // Get protocol liquidation config to calculate expected close factor
            (,, , , uint256 closeFactorBase, uint256 closeFactorCurve,,)
                = marketManagerIsolated.liquidationConfig(address(borrowableCDAI));

            // Calculate expected protocol-derived close factor
            // Get lFactor (liquidation severity) for the borrower
            (, , , uint256 lFactor) = _liquidationValuesOfHelper(marketManagerIsolated, user1);

            // Calculate expected close factor: closeFactorBase + (closeFactorCurve * lFactor / WAD)
            uint256 expectedCloseFactor = closeFactorBase + ((closeFactorCurve * lFactor) / 1e18);

            // Calculate expected max debt that can be repaid with protocol-derived close factor
            expectedMaxDebtRepaid = (debtBefore * expectedCloseFactor) / 10000;
        }

        // Execute liquidation with custom lower incentive + protocol-derived close factor
        borrowableCUSDC.liquidate(borrowers, address(borrowableCDAI));

        vm.stopPrank();

        // Verify liquidation occurred
        uint256 debtAfter = borrowableCUSDC.debtBalanceUpdated(user1);
        uint256 collateralAfter = borrowableCDAI.balanceOf(user1);
        uint256 liquidatorCollateral = borrowableCDAI.balanceOf(auctionPermsUser);

        uint256 debtRepaid = debtBefore - debtAfter;
        uint256 collateralSeized = collateralBefore - collateralAfter;

        assertEq(liquidatorCollateral, collateralSeized, "Liquidator should have received seized collateral");

        // CRITICAL ASSERTION 2: Verify the debt repaid matches exactly what we'd expect with protocol-derived close factor.
        // This indirectly proves aData.closeFactorCurve != 0 (first if block executed and loaded curves).
        assertEq(debtRepaid, expectedMaxDebtRepaid,
            "Debt repaid must exactly match expected value from protocol-derived close factor");

        // CRITICAL ASSERTION 3: Verify we used the exact auction provided incentive (105%).
        // This indirectly proves aData.liqIncCurve == 0 (second if block was skipped).
        {
            uint256 expectedCollateralSeized = _calculateExpectedCollateralSeized(
                debtRepaid,
                lowerIncentive,
                address(borrowableCDAI),
                address(borrowableCUSDC)
            );

            assertEq(collateralSeized, expectedCollateralSeized,
                "Collateral seized must exactly match expected value from custom 105% liquidation incentive");
        }
    }

    function _calculateExpectedCollateralSeized(
        uint256 debtRepaid,
        uint256 liqIncentive,
        address collateralToken,
        address debtToken
    ) internal returns (uint256) {
        // Get prices
        (uint256 collateralTokenPrice, uint256 debtTokenPrice) =
            oracleManager.getPriceIsolatedPair(collateralToken, debtToken, 2);

        // Get decimals
        uint256 collateralTokenDecimals = 10 ** borrowableCDAI.decimals();
        uint256 debtTokenDecimals = 10 ** borrowableCUSDC.decimals();

        // Calculate debtToCollateral using the exact formula from MarketManagerIsolated
        // debtToCollateral = (((liqInc * debtPrice * WAD_SQUARED_BPS_OFFSET) / collateralPrice) * collateralDecimals) / debtDecimals
        uint256 temp = FixedPointMathLib.mulDiv(
            FixedPointMathLib.mulDiv(liqIncentive, debtTokenPrice, 1),
            WAD_SQUARED_BPS_OFFSET,
            collateralTokenPrice
        );
        uint256 debtToCollateral = FixedPointMathLib.mulDiv(
            temp,
            collateralTokenDecimals,
            debtTokenDecimals
        );

        // Calculate expected collateral seized
        return FixedPointMathLib.mulDivUp(
            debtRepaid,
            debtToCollateral,
            WAD_SQUARED
        );
    }
}