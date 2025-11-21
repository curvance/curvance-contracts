// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { WAD_SQUARED, WAD_SQUARED_BPS_OFFSET } from "contracts/libraries/ConstantsLib.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { console2 } from "forge-std/console2.sol";

  // This test demonstrates multiple liquidations with partial zero values in auction liquidations.
  // Tests that multiple liquidations can use different custom incentives + protocol-derived close factor.

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
  //    Each liquidation uses its own custom incentive for collateral calculation
  //    Both liquidations use protocol-derived close factor for debt repayment amount

contract AuctionCustomIncentiveDerivedCloseFactorMultipleTest is TestBaseMarketIsolated {

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

        // Set up user1 position
        vm.startPrank(user1);
        _prepareDAI(user1, 1000e18);
        dai.approve(address(borrowableCDAI), 1000e18);
        borrowableCDAI.depositAsCollateral(1000e18, user1);
        borrowableCUSDC.borrow(500e6, user1);
        vm.stopPrank();

        // Set up user2 with same position as user1 (both have 1000 DAI collateral, 500 USDC debt)
        vm.startPrank(user2);
        _prepareDAI(user2, 1000e18);
        dai.approve(address(borrowableCDAI), 1000e18);
        borrowableCDAI.depositAsCollateral(1000e18, user2);
        borrowableCUSDC.borrow(500e6, user2);
        vm.stopPrank();

        mockDaiFeed.setMockAnswer(70007000);
    }

    function test_success_MultipleLiquidationsWithDifferentCustomIncentives() public {

        // Prepare liquidator with enough USDC for both liquidations
        _prepareUSDC(auctionPermsUser, 2000e6);

        vm.startPrank(auctionPermsUser);
        usdc.approve(address(borrowableCUSDC), 2000e6);

        // Execute first liquidation with 10500 (105%) custom incentive
        _executeLiquidationAndVerify(user1, 10500, true);

        // Execute second liquidation with 11000 (110%) custom incentive
        _executeLiquidationAndVerify(user2, 11000, false);

        // CRITICAL: Verify both users are healthy after their respective liquidations
        (, uint256 maxDebt1, uint256 debt1) = marketManagerIsolated.statusOf(user1);
        (, uint256 maxDebt2, uint256 debt2) = marketManagerIsolated.statusOf(user2);

        assertLe(debt1, maxDebt1, "User1 must be healthy after liquidation");
        assertLe(debt2, maxDebt2, "User2 must be healthy after liquidation");

        vm.stopPrank();
    }

    function _executeLiquidationAndVerify(
        address borrower,
        uint256 customIncentive,
        bool unlockMarket
    ) internal {
        // Set auction config and verify transient storage
        _setAndVerifyTransientConfig(customIncentive);

        if (unlockMarket) {
            centralRegistry.unlockAuctionForMarket(address(marketManagerIsolated));
        }

        // Verify user is unhealthy before liquidation
        _assertUnhealthy(borrower);

        // Get balances before liquidation
        uint256 debtBefore = borrowableCUSDC.debtBalanceUpdated(borrower);
        uint256 collateralBefore = borrowableCDAI.balanceOf(borrower);
        uint256 liquidatorCollateralBefore = borrowableCDAI.balanceOf(auctionPermsUser);

        // Calculate expected values
        (uint256 expectedDebtRepaid, uint256 expectedCollateralSeized) =
            _calculateExpectedLiquidationAmounts(borrower, debtBefore, customIncentive);

        // Execute liquidation
        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;
        borrowableCUSDC.liquidate(borrowers, address(borrowableCDAI));

        // Verify liquidation results
        _verifyLiquidationResults(
            borrower,
            debtBefore,
            collateralBefore,
            liquidatorCollateralBefore,
            expectedDebtRepaid,
            expectedCollateralSeized
        );
    }

    function _setAndVerifyTransientConfig(uint256 customIncentive) internal {
        marketManagerIsolated.setTransientLiquidationConfig(address(borrowableCDAI), customIncentive, 0);

        (address storedToken, uint256 storedIncentive, uint256 storedCloseFactor) =
            marketManagerIsolated.getTransientLiquidationConfig();

        assertEq(storedToken, address(borrowableCDAI),
            "CRITICAL: Stored token address must match exactly (bit packing check)");
        assertEq(storedIncentive, customIncentive, "Custom incentive should be stored");
        assertEq(storedCloseFactor, 0, "Close factor should be stored as 0 to signal protocol-derived");
    }

    function _assertUnhealthy(address borrower) internal {
        (, uint256 maxDebt, uint256 debt) = marketManagerIsolated.statusOf(borrower);
        assertGt(debt, maxDebt, "CRITICAL: User must be unhealthy before liquidation (debt > maxDebt)");
    }

    function _assertHealthy(address borrower) internal {
        (, uint256 maxDebt, uint256 debt) = marketManagerIsolated.statusOf(borrower);
        assertLe(debt, maxDebt, "CRITICAL: User must be healthy after liquidation (debt <= maxDebt)");
    }

    function _verifyLiquidationResults(
        address borrower,
        uint256 debtBefore,
        uint256 collateralBefore,
        uint256 liquidatorCollateralBefore,
        uint256 expectedDebtRepaid,
        uint256 expectedCollateralSeized
    ) internal {
        uint256 debtAfter = borrowableCUSDC.debtBalanceUpdated(borrower);
        uint256 collateralAfter = borrowableCDAI.balanceOf(borrower);
        uint256 liquidatorCollateralAfter = borrowableCDAI.balanceOf(auctionPermsUser);

        uint256 actualDebtRepaid = debtBefore - debtAfter;
        uint256 actualCollateralSeized = collateralBefore - collateralAfter;
        uint256 liquidatorReceived = liquidatorCollateralAfter - liquidatorCollateralBefore;

        // CRITICAL ASSERTION: Verify the debt repaid matches exactly what we'd expect with protocol-derived close factor
        assertEq(actualDebtRepaid, expectedDebtRepaid,
            "Debt repaid must exactly match expected value from protocol-derived close factor");

        // CRITICAL ASSERTION: Verify we used the exact auction provided incentive
        assertEq(actualCollateralSeized, expectedCollateralSeized,
            "Collateral seized must exactly match expected value from custom liquidation incentive");

        // CRITICAL ASSERTION: Verify liquidator received the seized collateral
        assertEq(liquidatorReceived, actualCollateralSeized,
            "Liquidator should have received seized collateral");

        // Verify user is healthy after liquidation
        _assertHealthy(borrower);
    }

    function _calculateExpectedLiquidationAmounts(
        address borrower,
        uint256 debtBefore,
        uint256 customIncentive
    ) internal returns (uint256 expectedDebtRepaid, uint256 expectedCollateralSeized) {
        // Get liquidation config curves
        (uint256 liqIncBase, uint256 liqIncCurve, , , uint256 closeFactorBase, uint256 closeFactorCurve,,) =
            marketManagerIsolated.liquidationConfig(address(borrowableCDAI));

        // Calculate protocol-derived close factor
        (, , , uint256 lFactor) = _liquidationValuesOfHelper(marketManagerIsolated, borrower);

        // HIGH VALUE ADDITION: Prove the correct code path will be taken
        // CRITICAL: Prove curves exist and will be used for close factor
        assertGt(closeFactorCurve, 0,
            "CRITICAL: closeFactorCurve must be > 0 or protocol-derived close factor won't work");
        assertGt(lFactor, 0,
            "CRITICAL: lFactor must be > 0 for curve calculations to have effect");

        // CRITICAL: Calculate what protocol-derived incentive WOULD be
        uint256 protocolDerivedIncentive = liqIncBase + ((liqIncCurve * lFactor) / 1e18);

        // CRITICAL: Prove custom incentive is LOWER than protocol-derived (this test's scenario)
        assertLt(customIncentive, protocolDerivedIncentive,
            "CRITICAL: Custom incentive must be lower than protocol-derived for this test scenario");

        uint256 expectedCloseFactor = closeFactorBase + ((closeFactorCurve * lFactor) / 1e18);

        // Calculate expected debt repaid
        expectedDebtRepaid = (debtBefore * expectedCloseFactor) / 10000;

        // Calculate expected collateral seized with custom incentive
        expectedCollateralSeized = _calculateExpectedCollateralSeized(
            expectedDebtRepaid,
            customIncentive,
            address(borrowableCDAI),
            address(borrowableCUSDC)
        );
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
        return FixedPointMathLib.mulDiv(
            debtRepaid,
            debtToCollateral,
            WAD_SQUARED
        );
    }
}
