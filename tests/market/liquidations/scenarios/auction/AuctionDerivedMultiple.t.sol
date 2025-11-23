// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { WAD_SQUARED, WAD_SQUARED_BPS_OFFSET } from "contracts/libraries/ConstantsLib.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { console2 } from "forge-std/console2.sol";

  // This test demonstrates multiple liquidations with both protocol-derived values.
  // Tests that multiple liquidations can use protocol-derived incentive + protocol-derived close factor.

  // Setup:
  //    User 1 has 1000 DAI collateral worth $1000 ($1 each)
  //    User 2 has 1000 DAI collateral worth $1000 ($1 each)
  //    Both borrow 500 USDC

  // Test scenario:
  //    DAI price drops to $0.70007 per DAI (both users become liquidatable)
  //    First liquidation: Configure with (0, 0), liquidate user1 - uses protocol-derived values
  //    Second liquidation: Configure with (0, 0), liquidate user2 - uses protocol-derived values

  // Expected results:
  //    Each liquidation uses protocol-derived incentive and protocol-derived close factor

contract AuctionDerivedMultipleTest is TestBaseMarketIsolated {

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

        // Set up user2 with same position as user1
        vm.startPrank(user2);
        _prepareDAI(user2, 1000e18);
        dai.approve(address(borrowableCDAI), 1000e18);
        borrowableCDAI.depositAsCollateral(1000e18, user2);
        borrowableCUSDC.borrow(500e6, user2);
        vm.stopPrank();

        mockDaiFeed.setMockAnswer(70007000);
    }

    function test_success_MultipleLiquidationsWithBothProtocolDerived() public {
        // Prepare liquidator with enough USDC for both liquidations
        _prepareUSDC(auctionPermsUser, 2000e6);

        vm.startPrank(auctionPermsUser);
        usdc.approve(address(borrowableCUSDC), 2000e6);

        // Execute first liquidation with 0, 0 (both protocol-derived)
        _executeLiquidationAndVerify(user1, true);

        // Execute second liquidation with 0, 0 (both protocol-derived)
        _executeLiquidationAndVerify(user2, false);

        // CRITICAL: Verify both users are healthy after their respective liquidations
        (, uint256 maxDebt1, uint256 debt1) = marketManagerIsolated.statusOf(user1);
        (, uint256 maxDebt2, uint256 debt2) = marketManagerIsolated.statusOf(user2);

        assertLe(debt1, maxDebt1, "User1 must be healthy after liquidation");
        assertLe(debt2, maxDebt2, "User2 must be healthy after liquidation");

        vm.stopPrank();
    }

    function _executeLiquidationAndVerify(
        address borrower,
        bool unlockMarket
    ) internal {
        // Set auction config and verify transient storage
        _setAndVerifyTransientConfig();

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
            _calculateExpectedLiquidationAmounts(borrower, debtBefore);

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

    function _setAndVerifyTransientConfig() internal {
        marketManagerIsolated.setTransientLiquidationConfig(address(borrowableCDAI), 0, 0);

        (address storedToken, uint256 storedIncentive, uint256 storedCloseFactor) =
            marketManagerIsolated.getTransientLiquidationConfig();

        assertEq(storedToken, address(borrowableCDAI),
            "CRITICAL: Stored token address must match exactly (bit packing check)");
        assertEq(storedIncentive, 0, "Incentive should be stored as 0 to signal protocol-derived");
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

        // CRITICAL ASSERTION: Verify we used the exact protocol-derived incentive
        assertEq(actualCollateralSeized, expectedCollateralSeized,
            "Collateral seized must exactly match expected value from protocol-derived liquidation incentive");

        // CRITICAL ASSERTION: Verify liquidator received the seized collateral
        assertEq(liquidatorReceived, actualCollateralSeized,
            "Liquidator should have received seized collateral");

        // Verify user is healthy after liquidation
        _assertHealthy(borrower);
    }

    function _calculateExpectedLiquidationAmounts(
        address borrower,
        uint256 debtBefore
    ) internal returns (uint256 expectedDebtRepaid, uint256 expectedCollateralSeized) {
        // Get liquidation config curves
        (uint256 liqIncBase, uint256 liqIncCurve, , , uint256 closeFactorBase, uint256 closeFactorCurve,,) =
            marketManagerIsolated.liquidationConfig(address(borrowableCDAI));

        // Calculate protocol-derived values
        (, , , uint256 lFactor) = _liquidationValuesOfHelper(marketManagerIsolated, borrower);

        // HIGH VALUE ADDITION: Prove BOTH curves exist and will be used
        assertGt(liqIncCurve, 0,
            "CRITICAL: liqIncCurve must be > 0 or protocol-derived incentive won't work");
        assertGt(closeFactorCurve, 0,
            "CRITICAL: closeFactorCurve must be > 0 or protocol-derived close factor won't work");
        assertGt(lFactor, 0,
            "CRITICAL: lFactor must be > 0 for curve calculations to have effect");

        // Calculate expected values
        uint256 expectedCloseFactor = closeFactorBase + ((closeFactorCurve * lFactor) / 1e18);
        expectedDebtRepaid = (debtBefore * expectedCloseFactor) / 10000;

        uint256 expectedLiqIncentive = liqIncBase + ((liqIncCurve * lFactor) / 1e18);
        expectedCollateralSeized = _calculateExpectedCollateralSeized(
            expectedDebtRepaid,
            expectedLiqIncentive,
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
        (uint256 collateralTokenPrice, uint256 debtTokenPrice) =
            oracleManager.getPriceIsolatedPair(collateralToken, debtToken, 2);

        uint256 collateralTokenDecimals = 10 ** borrowableCDAI.decimals();
        uint256 debtTokenDecimals = 10 ** borrowableCUSDC.decimals();

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

        return FixedPointMathLib.mulDiv(
            debtRepaid,
            debtToCollateral,
            WAD_SQUARED
        );
    }
}
