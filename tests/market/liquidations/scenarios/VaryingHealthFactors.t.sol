// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { TestBaseLiquidations } from "tests/market/liquidations/TestBaseLiquidations.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { console2 } from "forge-std/console2.sol";

// ## Scenario: Multiple Users Liquidated with varying health factors
// - Setup: 5 users with same collateral (1.0 LP token each) but graduated debt amounts with good variance.
// - User 1: 1.0 Pendle wstETH LP (~$10,287), 6,800 USDC debt (66% LTV initially - healthy).
// - User 2: 1.0 Pendle wstETH LP (~$10,287), 6,950 USDC debt (68% LTV initially - borderline).
// - User 3: 1.0 Pendle wstETH LP (~$10,287), 7,030 USDC debt (68% LTV initially - will be soft liquidated).
// - User 4: 1.0 Pendle wstETH LP (~$10,287), 7,070 USDC debt (69% LTV initially - will be hard liquidated).
// - User 5: 1.0 Pendle wstETH LP (~$10,287), 7,180 USDC debt (70% LTV initially - will be severe hard liquidated).
// - Action: Price drop from ~$10,287 to $7,200 per token (30% drop)
// - Expected: Users 3, 4, and 5 should be liquidated in single transaction
//           After price drop: User 1 and User 2 remain healthy.
//           User 3 has a soft liquidation with remaining debt.
//           User 4 has a hard liquidation, full debt repayment.
//           User 5 has a severe hard liquidation with bad debt.
    

contract VaryingHealthFactors is TestBaseLiquidations {

    address borrower1 = address(0x0000000000000000000000000000000000000001);
    address borrower2 = address(0x0000000000000000000000000000000000000002);
    address borrower3 = address(0x0000000000000000000000000000000000000003);
    address borrower4 = address(0x0000000000000000000000000000000000000004);
    address borrower5 = address(0x0000000000000000000000000000000000000005);

    uint256[] borrowAmounts = [6800e6, 6950e6, 7030e6, 7070e6, 7180e6];
    address[] borrowers = [borrower1, borrower2, borrower3, borrower4, borrower5];

    uint256[] badDebt = [0,0,0,0,0];

    event Repay(uint256 assets, address payer, address account);
    event BadDebtRecognized(uint256 assets, address liquidator);

    function setUp() public override {
        super.setUp();

        // use mock pricing for testing
        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        _prepareUSDC(user1, _ONE);
        _prepareUSDC(address(this), _ONE);

        deal(address(LP_wstETH_24Dec2025), user1, _ONE + 77777);

        vm.prank(user1);
        usdc.approve(address(borrowableCUSDC), _ONE);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE + 77777);

        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(borrowableCUSDC));

        _setCTokenConfigHighValues(address(pendleStrategyCTokenSTETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 100_000e6);

        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 200000e6);
        deal(address(LP_wstETH_24Dec2025), liquidityProvider, 10e18);
        // Mint borrowable cUSDC.
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 200000e6);
        borrowableCUSDC.deposit(200000e6, liquidityProvider);
        // Mint cBALETH.
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 10e18);
        pendleStrategyCTokenSTETH.deposit(10e18, liquidityProvider);
        vm.stopPrank();

        _createPositions();

        _setPendleStEthLpPrice(7200e8);
    }

    function test_multipleUsersLiquidatedWithVaryingHealthFactors() public {
        _prepareUSDC(address(this), 100000e6);

        // ===== Cache liquidation values =====

        uint256[] memory lFactorsPreLiquidation = _getLFactorsPreLiquidation();
        uint256[] memory debtBalancesPreLiquidation = _getDebtBalancePreLiquidation();

        uint256[] memory maxAmount = new uint256[](5);
        uint256[] memory collateralLiquidated = new uint256[](5);
        uint256[] memory collateralRequired = new uint256[](5);
        uint256 expectedTotalBadDebt;

        for(uint i; i < 5; i++) {

            ExpectedLiquidationValues memory expectedValues = _calculateExpectedLiquidationValues(
                LiquidationParams({
                    borrower: borrowers[i],
                    collateralToken: address(pendleStrategyCTokenSTETH),
                    borrowedToken: address(borrowableCUSDC),
                    isLiquidateExact: false,
                    liquidateExactAmount: 0,
                    isAuction: false,
                    isMultiMarketTest: false,
                    marketManagerId: 0
                })
            );

            maxAmount[i] = expectedValues.maxAmountRepaid;
            collateralLiquidated[i] = expectedValues.collateralLiquidated;
            collateralRequired[i] = expectedValues.collateralRequired;
            badDebt[i] = expectedValues.badDebt;
            expectedTotalBadDebt += badDebt[i];
        }

        uint256 totalBorrowsBefore = borrowableCUSDC.marketOutstandingDebt();

        // ===== Liquidate =====

        borrowableCUSDC.approve(address(marketManagerIsolated), 100000e6);

        // Expect BadDebtRecognized event and Repay events for users 3, 4, and 5
        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit BadDebtRecognized(expectedTotalBadDebt, address(this));
        emit Repay(maxAmount[2] + badDebt[2], address(this), borrowers[2]);
        emit Repay(maxAmount[3] + badDebt[3], address(this), borrowers[3]);
        emit Repay(maxAmount[4] + badDebt[4], address(this), borrowers[4]);

        borrowableCUSDC.liquidate(
            borrowers,
            address(pendleStrategyCTokenSTETH)
        );

        // ===== Validate =====

        // Verify healthy accounts (1 and 2) are not liquidated
        assertEq(borrowableCUSDC.debtBalance(borrowers[0]), debtBalancesPreLiquidation[0], "Healthy account 1 shouldn't be liquidated");
        assertEq(borrowableCUSDC.debtBalance(borrowers[1]), debtBalancesPreLiquidation[1], "Healthy account 2 shouldn't be liquidated");

        // Verify liquidated accounts (3, 4, and 5) are liquidated
        for (uint i = 2; i < 5; i++) {
            // Debt should be reduced by maxAmount if soft liquidation
            if(borrowers[i] == borrower3) {

                assertEq(borrowableCUSDC.debtBalance(borrowers[i]), debtBalancesPreLiquidation[i] - maxAmount[i], "Borrower 3 should be soft liquidated");
            } else {
                assertEq(borrowableCUSDC.debtBalance(borrowers[i]), 0, "Borrower should be hard liquidated");
            }

            // Collateral should be reduced by collateralLiquidated
            assertApproxEqAbs(
                pendleStrategyCTokenSTETH.balanceOf(borrowers[i]), 
                _ONE - collateralLiquidated[i],
                1000, // Tolerance of 1000 wei 
                "Collateral post liquidation mismatch"
            );
        }

        uint256 totalDebtRepaid = maxAmount[2] + borrowAmounts[3] + borrowAmounts[4];

        assertApproxEqAbs(
            borrowableCUSDC.marketOutstandingDebt(),
            totalBorrowsBefore - totalDebtRepaid,
            100, // Small tolerance
            "Incorrect totalBorrows after liquidation"
        );

        // Verify liquidator received the expected collateral
        uint256 expectedLiquidatorBalance = collateralLiquidated[2] + collateralLiquidated[3] + collateralLiquidated[4];
        assertApproxEqAbs(
            pendleStrategyCTokenSTETH.balanceOf(address(this)),
            expectedLiquidatorBalance,
            1000,
            "Liquidator didn't receive expected collateral"
        );

        // Test accounts health factor after liquidation
        for (uint i = 2; i < 5; i++) {
            (, , , uint256 lFactorAfter) = _liquidationValuesOfHelper(marketManagerIsolated, borrowers[i]);
            
            if (borrowableCUSDC.debtBalance(borrowers[i]) > 0) {
                // If there's still debt, health factor should be improved
                assertTrue(
                    lFactorAfter < lFactorsPreLiquidation[i],
                    "Health factor should improve after partial liquidation"
                );
            } else {
                // If fully liquidated, lFactor should be 0
                assertEq(lFactorAfter, 0, "Fully liquidated account should have 0 lFactor");
            }
        }
    }

    function _createPositions() internal {
        deal(address(LP_wstETH_24Dec2025), borrower1, _ONE);
        deal(address(LP_wstETH_24Dec2025), borrower2, _ONE);
        deal(address(LP_wstETH_24Dec2025), borrower3, _ONE);
        deal(address(LP_wstETH_24Dec2025), borrower4, _ONE);
        deal(address(LP_wstETH_24Dec2025), borrower5, _ONE);

        vm.startPrank(borrower1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE);
        pendleStrategyCTokenSTETH.depositAsCollateral(_ONE, borrower1);
        borrowableCUSDC.borrow(borrowAmounts[0], borrower1);
        vm.stopPrank();

        vm.startPrank(borrower2);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE);
        pendleStrategyCTokenSTETH.depositAsCollateral(_ONE, borrower2);
        borrowableCUSDC.borrow(borrowAmounts[1], borrower2);
        vm.stopPrank();

        vm.startPrank(borrower3);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE);
        pendleStrategyCTokenSTETH.depositAsCollateral(_ONE, borrower3);
        borrowableCUSDC.borrow(borrowAmounts[2], borrower3);
        vm.stopPrank();

        vm.startPrank(borrower4);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE);
        pendleStrategyCTokenSTETH.depositAsCollateral(_ONE, borrower4);
        borrowableCUSDC.borrow(borrowAmounts[3], borrower4);
        vm.stopPrank();

        vm.startPrank(borrower5);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE);
        pendleStrategyCTokenSTETH.depositAsCollateral(_ONE, borrower5);
        borrowableCUSDC.borrow(borrowAmounts[4], borrower5);
        vm.stopPrank();
    }

    function _getLFactorsPreLiquidation() internal returns (uint256[] memory lFactors) {
        lFactors = new uint256[](5);

        for(uint i; i < 5; i++) {
            (, , , lFactors[i]) = _liquidationValuesOfHelper(marketManagerIsolated, borrowers[i]);
        }

        return lFactors;
    }

    function _getDebtBalancePreLiquidation() internal view returns (uint256[] memory debtBalances) {
        debtBalances = new uint256[](5);
        for(uint i; i < 5; i++) {
            debtBalances[i] = borrowableCUSDC.debtBalance(borrowers[i]);
        }
        return debtBalances;
    }

}