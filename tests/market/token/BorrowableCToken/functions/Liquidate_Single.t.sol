// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseBorrowableCToken } from "tests/market/token/BorrowableCToken/TestBaseBorrowableCToken.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { WAD } from "contracts/libraries/ConstantsLib.sol";
import "forge-std/console2.sol";

// NOTE: Test also uses canLiquidate for extra accounting checks

contract LiquidateSingleTest is TestBaseBorrowableCToken {
    uint256 borrowableCTokenUnderlyingPrice = 1e18;

    function setUp() public override {
        super.setUp();

        _prepareLiquidationCollateralDrop();
    }

    // Test a single liquidation
    function test_liquidate_single_success() public {
        uint256 debtBeforeAccrual = borrowableCUSDC.debtBalance(user1);
        uint256 totalAssetsBeforeAccrual = borrowableCUSDC.totalAssets();

        uint256 initialMarketDebt = borrowableCUSDC.marketOutstandingDebt();
        
        borrowableCUSDC.accrueIfNeeded();
        
        uint256 debtAfterAccrual = borrowableCUSDC.debtBalance(user1);
        uint256 totalAssetsAfterAccrual = borrowableCUSDC.totalAssets();
        uint256 totalMarketDebtAfterAccrual = borrowableCUSDC.marketOutstandingDebt();

        assertGt(debtAfterAccrual, debtBeforeAccrual);
        
        uint256 userDebtIncrease = debtAfterAccrual - debtBeforeAccrual;
        uint256 totalMarketDebtIncrease = totalMarketDebtAfterAccrual - initialMarketDebt;
        uint256 assetsIncrease = totalAssetsAfterAccrual - totalAssetsBeforeAccrual;
        console2.log("debtIncrease", userDebtIncrease);
        console2.log("assetsIncrease", assetsIncrease);
        
        assertEq(totalMarketDebtIncrease, assetsIncrease, "total debt and asset increase should be equal");
        assertGe(userDebtIncrease, assetsIncrease, "debt increase should be greater than or equal to assets increase");
        assertApproxEqAbs(userDebtIncrease, assetsIncrease, 5, "debt should be slightly higher than or equal to assets");

        address[] memory accounts = new address[](1);
        accounts[0] = user1;

        uint256[] memory debtAmounts = new uint256[](1);
        debtAmounts[0] = 0;
        
        _prepareUSDC(user2, 6500e6);
        vm.startPrank(user2);
        usdc.approve(address(borrowableCUSDC), 6500e6);

        IMarketManager.LiqAction memory action = IMarketManager.LiqAction({
            debtToken: address(borrowableCUSDC),
            collateralToken: address(pendleStrategyCTokenSTETH),
            numAccounts: 1,
            liquidateExact: false,
            liquidatedShares: 0,
            debtRepaid: 0,
            badDebt: 0
        });

        (IMarketManager.LiqResult memory result, ) = marketManagerIsolated.canLiquidate(
            debtAmounts,
            user2,
            accounts,
            action
        );

        ExpectedLiquidationValues memory expectedLiquidationValues = _calculateExpectedLiquidationValues(
            LiquidationParams({
                borrower: user1,
                collateralToken: address(pendleStrategyCTokenSTETH),
                borrowedToken: address(borrowableCUSDC),
                isLiquidateExact: false,
                liquidateExactAmount: 0,
                isAuction: false,
                isMultiMarketTest: false,
                marketManagerId: 0
            })
        );

        // Hard liquidation, should have lost all collateral
        assertEq(result.liquidatedShares[0], _ONE - 1, "Liquidated amount mismatch");
        borrowableCUSDC.liquidate(
            accounts,
            address(pendleStrategyCTokenSTETH)
        );
        vm.stopPrank();

        // Hard liquidation, should have lost all collateral
        assertEq(
            pendleStrategyCTokenSTETH.balanceOf(user1),
            1, "Borrower pendleStrategyCTokenSTETH balance mismatch"
        );

        assertEq(expectedLiquidationValues.debtRepaid, result.debtRepaid, "Debt repaid mismatch");

        assertEq(borrowableCUSDC.debtBalance(user1), 0, "borrowableCUSDC debt balance mismatch");
        assertGt(pendleStrategyCTokenSTETH.exchangeRate(), _ONE, "pendleStrategyCTokenSTETH exchange rate mismatch, strategy should have harvested");
        assertLt(borrowableCUSDC.exchangeRate(), _ONE, "borrowableCUSDC exchange rate mismatch, there should be bad debt");
        assertEq(pendleStrategyCTokenSTETH.balanceOf(user2), _ONE - 1, "Liquidator pendleStrategyCTokenSTETH balance mismatch");
        assertEq(usdc.balanceOf(user2), 6500e6 - result.debtRepaid, "Liquidator USDC balance mismatch");
       
    }

    function _prepareLiquidationCollateralDrop() internal {
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

        deal(address(LP_wstETH_24Dec2025), user1, _ONE);

        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE);
        pendleStrategyCTokenSTETH.deposit(_ONE, user1);
        pendleStrategyCTokenSTETH.postCollateral(_ONE - 1);

        borrowableCUSDC.borrow(6500e6, user1);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);
        _harvestPendleLP(1 weeks);

        _setPendleStEthLpPrice(6500e8);

        _prepareUSDC(user2, 250e6);
    }


}