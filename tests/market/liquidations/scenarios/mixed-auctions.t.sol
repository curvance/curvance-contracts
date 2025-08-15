// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { WAD } from "contracts/libraries/ConstantsLib.sol";

import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";

import { TestBaseLiquidations } from "tests/market/liquidations/TestBaseLiquidations.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { console2 } from "forge-std/console2.sol";

// ## Scenario 4: Mixed Regular and Auction Liquidations, all using liquidate() function
// - Setup: 4 users with varying positions
// - User 1: 1.9 strategyCBALRETH ($2,850), 2500 USDC debt (for Auction)
// - User 2: 1.9 strategyCBALRETH ($2,850), 2500 USDC debt (for Auction)
// - User 3: 1.9 strategyCBALRETH ($2,850), 2500 USDC debt (for regular)
// - User 4: 1.9 strategyCBALRETH ($2,850), 2500 USDC debt (for regular)
// - Action 1: Price drop to ~$1,300, Regular liquidation for User 3 and User 4
// - Action 2: Auction transaction with custom parameters for User 1 and User 2
// - Expected: Users 3 and 4 liquidated via regular liquidation first, then Users 1 and 2 via Auction
//          All users have the same underwater position, so each accrue bad debt at the moment.
//          Users who are liquidated via Auction accrue less bad debt because their positions are not completely closed
//                  because they use a lower close factor than using liquiding the maximum amount.
//          Users who are liquidated without Auction are fully liquidated and accrue the full bad debt amount.

// TODO: Use different loan/collateral ratios for each user. Currently each have the same collateral amount and loan.


contract MixedAuction is TestBaseLiquidations {

    address borrower1 = makeAddr("borrower1");
    address borrower2 = makeAddr("borrower2");
    address borrower3 = makeAddr("borrower3");
    address borrower4 = makeAddr("borrower4");

    uint256 borrowAmount = 2500e6;
    address[] auctionBorrowers = [borrower1, borrower2];
    address[] regularBorrowers = [borrower3, borrower4];
    uint256[] collateralAmounts = [1.9e18,1.9e18,1.9e18,1.9e18];

    // Auction parameters
    uint256 validPenalty = 10400;
    uint256 closeFactor = 5000;

    uint256[] debtBalancesPreLiquidation_auction;
    uint256[] debtBalancesPreLiquidation_regular;
    uint256 totalBadDebtAuction;
    uint256 totalBadDebtRegular;
    uint256 totalBorrowsBefore;
    uint256 totalDebtRepaid;


    event Repay(uint256 assets, address payer, address account);
    event BadDebtRecognized(uint256 assets, address liquidator);

    function setUp() public override {
        super.setUp();
        
        // use mock pricing for testing
        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        chainlinkEthUsd.updateAnswer(1500e8);
        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);

        _prepareUSDC(user1, _ONE);
        _prepareUSDC(address(this), _ONE);

        _prepareBALRETH(user1, _ONE + 77777);

        vm.prank(user1);
        usdc.approve(address(borrowableCUSDC), _ONE);
        balRETH.approve(address(strategyCBALRETH), _ONE + 77777);

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 100_000e6);
        
        mockWethFeed.setMockAnswer(3000e8);
        mockRethFeed.setMockAnswer(3000e8);
        _refreshMockFeeds();

        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 200000e6);
        _prepareBALRETH(liquidityProvider, 10e18);
        // Mint borrowable cUSDC.
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 200000e6);
        borrowableCUSDC.deposit(200000e6, liquidityProvider);
        // Mint cBALETH.
        balRETH.approve(address(strategyCBALRETH), 10e18);
        strategyCBALRETH.deposit(10e18, liquidityProvider);
        vm.stopPrank();
        _createPositions();

        _harvestAuraStrategyRewards(1 weeks);
        borrowableCUSDC.accrueIfNeeded();

        mockWethFeed.setMockAnswer(1300e8);
        mockRethFeed.setMockAnswer(1300e8);

        console2.log("SETUP COMPLETE");
    }

    function test_fail_auctionLiquidationBlocksRegularLiquidation_sameTx() public {
        _prepareUSDC(auctionPermsUser, 100000e6);
        _prepareUSDC(address(this), 100000e6);

        // ===== Cache liquidation values =====

        totalBorrowsBefore = borrowableCUSDC.marketOutstandingDebt();

        debtBalancesPreLiquidation_auction = _getDebtBalancePreLiquidation(auctionBorrowers);

        debtBalancesPreLiquidation_regular = _getDebtBalancePreLiquidation(regularBorrowers);

        console2.log("CHECKPOINT 1");

            // ===== Liquidate =====

        vm.startPrank(auctionPermsUser);
        usdc.approve(address(borrowableCUSDC), 100000e6);

        marketManagerIsolated.setLiquidationConfig(
            address(borrowableCUSDC),  
            validPenalty,
            closeFactor
        );

        centralRegistry.unlockAuctionForMarket(address(marketManagerIsolated));
        marketManagerIsolated.unlockAuctionCollateral(address(strategyCBALRETH));

        ExpectedLiquidationValues memory auctionLiqValuesBorrower1 = _calculateExpectedLiquidationValues(
            LiquidationParams({
                borrower: auctionBorrowers[0],
                collateralToken: address(strategyCBALRETH),
                borrowedToken: address(borrowableCUSDC),
                isLiquidateExact: false,
                liquidateExactAmount: 0,
                isAuction: true,
                isMultiMarketTest: false,
                marketManagerId: 0
            }));

        ExpectedLiquidationValues memory auctionLiqValuesBorrower2 = _calculateExpectedLiquidationValues(
            LiquidationParams({
                borrower: auctionBorrowers[0],
                collateralToken: address(strategyCBALRETH),
                borrowedToken: address(borrowableCUSDC),
                isLiquidateExact: false,
                liquidateExactAmount: 0,
                isAuction: true,
                isMultiMarketTest: false,
                marketManagerId: 0
            }));

        totalBadDebtAuction = auctionLiqValuesBorrower1.badDebt + auctionLiqValuesBorrower2.badDebt;

        // Assert BadDebtRecognized event is emitted with expected total bad debt
        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit BadDebtRecognized(totalBadDebtAuction, auctionPermsUser);
        emit Repay(auctionLiqValuesBorrower1.debtRepaid,auctionPermsUser, auctionBorrowers[0]);
        emit Repay(auctionLiqValuesBorrower2.debtRepaid,auctionPermsUser, auctionBorrowers[1]);

        borrowableCUSDC.liquidate(
            auctionBorrowers,
            address(strategyCBALRETH)
        );
        marketManagerIsolated.lockAuctionCollateral();
        marketManagerIsolated.resetLiquidationConfig();
        vm.stopPrank();

        usdc.approve(address(borrowableCUSDC), 100000e6);

        // Regular liquidation should revert because market is still unlocked for auctions
        // but collateral is locked, creating an invalid auction state
        vm.expectRevert(MarketManagerIsolated.MarketManager__UnauthorizedLiquidation.selector);
        borrowableCUSDC.liquidate(
            regularBorrowers,
            address(strategyCBALRETH)
        );

        // ===== Validate Auction Liquidations Only =====
        
        // Verify debt balances for auction borrowers only
        assertEq(borrowableCUSDC.debtBalance(auctionBorrowers[0]), debtBalancesPreLiquidation_auction[0] - auctionLiqValuesBorrower1.debtRepaid - auctionLiqValuesBorrower1.badDebt, 
        "Auction borrower 1 debt balance mismatch");
        assertEq(borrowableCUSDC.debtBalance(auctionBorrowers[1]), debtBalancesPreLiquidation_auction[1] - auctionLiqValuesBorrower2.debtRepaid - auctionLiqValuesBorrower2.badDebt, 
        "Auction borrower 2 debt balance mismatch");

        // Regular borrowers should remain untouched since their liquidation reverted
        assertEq(borrowableCUSDC.debtBalance(regularBorrowers[0]), debtBalancesPreLiquidation_regular[0], 
        "Regular borrower 1 debt should be unchanged");
        assertEq(borrowableCUSDC.debtBalance(regularBorrowers[1]), debtBalancesPreLiquidation_regular[1], 
        "Regular borrower 2 debt should be unchanged");

        // Verify collateral is reduced by collateralLiquidated for auction borrowers only
        assertApproxEqAbs(
            strategyCBALRETH.balanceOf(auctionBorrowers[0]),
            collateralAmounts[0] - (auctionLiqValuesBorrower1.collateralLiquidated),
            1000, // Tolerance of 1000 wei 
            "Auction borrower 1 collateral post liquidation mismatch"
        );

        assertApproxEqAbs(
            strategyCBALRETH.balanceOf(auctionBorrowers[1]),
            collateralAmounts[1] - (auctionLiqValuesBorrower2.collateralLiquidated),
            1000, // Tolerance of 1000 wei 
            "Auction borrower 2 collateral post liquidation mismatch"
        );

        // Regular borrowers should have unchanged collateral
        assertEq(strategyCBALRETH.balanceOf(regularBorrowers[0]), collateralAmounts[2], 
        "Regular borrower 1 collateral should be unchanged");
        assertEq(strategyCBALRETH.balanceOf(regularBorrowers[1]), collateralAmounts[3], 
        "Regular borrower 2 collateral should be unchanged");

        // Assert Total borrows is reduced by only the auction liquidations
        uint256 auctionDebtRepaid = auctionLiqValuesBorrower1.debtRepaid + auctionLiqValuesBorrower2.debtRepaid;

        assertApproxEqAbs(
            borrowableCUSDC.marketOutstandingDebt(),
            totalBorrowsBefore - auctionDebtRepaid - totalBadDebtAuction,
            100, // Small tolerance
            "Incorrect totalBorrows after auction liquidation"
        );

        // Verify liquidator received the expected collateral from auction only
        uint256 expectedAuctionPermsUserLiquidatorBalance = 
            auctionLiqValuesBorrower1.collateralLiquidated + 
            auctionLiqValuesBorrower2.collateralLiquidated;

        assertApproxEqAbs(
            strategyCBALRETH.balanceOf(auctionPermsUser),
            expectedAuctionPermsUserLiquidatorBalance,
            1000,
            "Dapp control user didn't receive expected collateral from auction"
        );

        // This test liquidator should have no collateral since regular liquidation failed
        assertEq(strategyCBALRETH.balanceOf(address(this)), 0, "Test liquidator should have no collateral");

        // Verify lFactors
        // Auction borrowers should still have lFactor > 0 (partial liquidation)
        for(uint i = 0; i < 2; i++) {
            (uint256 lFactorAfter,,) = marketManagerIsolated.liquidationStatusOf(
                auctionBorrowers[i],
                address(borrowableCUSDC),
                address(strategyCBALRETH)
            );

            assertGt(lFactorAfter, 0, "Auction borrower should still have lFactor > 0");
        }

        // Regular borrowers should still be liquidatable (their liquidation was prevented by auction state)
        for(uint i = 0; i < 2; i++) {
            (uint256 lFactorAfter,,) = marketManagerIsolated.liquidationStatusOf(
                regularBorrowers[i],
                address(borrowableCUSDC),
                address(strategyCBALRETH)
            );

            assertEq(lFactorAfter, WAD, "Regular borrower should still be liquidatable");
        }
    }

    function test_success_regularLiquidationThenAuctionLiquidation_sameTx() public {
        _prepareUSDC(auctionPermsUser, 100000e6);
        _prepareUSDC(address(this), 100000e6);

        // ===== Cache liquidation values =====

        totalBorrowsBefore = borrowableCUSDC.marketOutstandingDebt();

        debtBalancesPreLiquidation_auction = _getDebtBalancePreLiquidation(auctionBorrowers);

        debtBalancesPreLiquidation_regular = _getDebtBalancePreLiquidation(regularBorrowers);

        console2.log("CHECKPOINT 1");

        // ===== Calculate Expected Values =====

        ExpectedLiquidationValues memory regularLiqValuesBorrower3 = _calculateExpectedLiquidationValues(
            LiquidationParams({
                borrower: regularBorrowers[0],
                collateralToken: address(strategyCBALRETH),
                borrowedToken: address(borrowableCUSDC),
                isLiquidateExact: false,
                liquidateExactAmount: 0,
                isAuction: false,
                isMultiMarketTest: false,
                marketManagerId: 0
            }));

        ExpectedLiquidationValues memory regularLiqValuesBorrower4 = _calculateExpectedLiquidationValues(
            LiquidationParams({
                borrower: regularBorrowers[1],
                collateralToken: address(strategyCBALRETH),
                borrowedToken: address(borrowableCUSDC),
                isLiquidateExact: false,
                liquidateExactAmount: 0,
                isAuction: false,
                isMultiMarketTest: false,
                marketManagerId: 0
            }));

        totalBadDebtRegular = regularLiqValuesBorrower3.badDebt + regularLiqValuesBorrower4.badDebt;

        // ===== Regular Liquidations First =====

        usdc.approve(address(borrowableCUSDC), 100000e6);

        // Assert BadDebtRecognized event is emitted with expected total bad debt
        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit BadDebtRecognized(totalBadDebtRegular, address(this));
        emit Repay(regularLiqValuesBorrower3.debtRepaid,address(this), regularBorrowers[0]);
        emit Repay(regularLiqValuesBorrower4.debtRepaid,address(this), regularBorrowers[1]);

        borrowableCUSDC.liquidate(
            regularBorrowers,
            address(strategyCBALRETH)
        );

        // ===== Auction Liquidations Second =====

        vm.startPrank(auctionPermsUser);
        usdc.approve(address(borrowableCUSDC), 100000e6);

        marketManagerIsolated.setLiquidationConfig(
            address(borrowableCUSDC),  
            validPenalty,
            closeFactor
        );

        centralRegistry.unlockAuctionForMarket(address(marketManagerIsolated));
        marketManagerIsolated.unlockAuctionCollateral(address(strategyCBALRETH));

        ExpectedLiquidationValues memory auctionLiqValuesBorrower1 = _calculateExpectedLiquidationValues(
            LiquidationParams({
                borrower: auctionBorrowers[0],
                collateralToken: address(strategyCBALRETH),
                borrowedToken: address(borrowableCUSDC),
                isLiquidateExact: false,
                liquidateExactAmount: 0,
                isAuction: true,
                isMultiMarketTest: false,
                marketManagerId: 0
            }));

        ExpectedLiquidationValues memory auctionLiqValuesBorrower2 = _calculateExpectedLiquidationValues(
            LiquidationParams({
                borrower: auctionBorrowers[1],
                collateralToken: address(strategyCBALRETH),
                borrowedToken: address(borrowableCUSDC),
                isLiquidateExact: false,
                liquidateExactAmount: 0,
                isAuction: true,
                isMultiMarketTest: false,
                marketManagerId: 0
            }));

        totalBadDebtAuction = auctionLiqValuesBorrower1.badDebt + auctionLiqValuesBorrower2.badDebt;

        // Assert BadDebtRecognized event is emitted with expected total bad debt
        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit BadDebtRecognized(totalBadDebtAuction, auctionPermsUser);
        emit Repay(auctionLiqValuesBorrower1.debtRepaid,auctionPermsUser, auctionBorrowers[0]);
        emit Repay(auctionLiqValuesBorrower2.debtRepaid,auctionPermsUser, auctionBorrowers[1]);

        borrowableCUSDC.liquidate(
            auctionBorrowers,
            address(strategyCBALRETH)
        );
        marketManagerIsolated.lockAuctionCollateral();
        marketManagerIsolated.resetLiquidationConfig();
        vm.stopPrank();

        // ===== Validate =====

        // Verify debt balances
        assertEq(borrowableCUSDC.debtBalance(auctionBorrowers[0]), debtBalancesPreLiquidation_auction[0] - auctionLiqValuesBorrower1.debtRepaid - auctionLiqValuesBorrower1.badDebt, 
        "Auction borrower 1 debt balance mismatch");
        assertEq(borrowableCUSDC.debtBalance(auctionBorrowers[1]), debtBalancesPreLiquidation_auction[1] - auctionLiqValuesBorrower2.debtRepaid - auctionLiqValuesBorrower2.badDebt, 
        "Auction borrower 2 debt balance mismatch");
        assertEq(borrowableCUSDC.debtBalance(regularBorrowers[0]), debtBalancesPreLiquidation_regular[0] - regularLiqValuesBorrower3.debtRepaid - regularLiqValuesBorrower3.badDebt, 
        "Regular borrower 1 debt balance mismatch");
        assertEq(borrowableCUSDC.debtBalance(regularBorrowers[1]), debtBalancesPreLiquidation_regular[1] - regularLiqValuesBorrower4.debtRepaid - regularLiqValuesBorrower4.badDebt, 
        "Regular borrower 2 debt balance mismatch");

        // Verify collateral is reduced by collateralLiquidated
        assertApproxEqAbs(
            strategyCBALRETH.balanceOf(auctionBorrowers[0]),
            collateralAmounts[0] - (auctionLiqValuesBorrower1.collateralLiquidated),
            1000, // Tolerance of 1000 wei 
            "Collateral post liquidation mismatch"
        );

        assertApproxEqAbs(
            strategyCBALRETH.balanceOf(auctionBorrowers[1]),
            collateralAmounts[1] - (auctionLiqValuesBorrower2.collateralLiquidated),
            1000, // Tolerance of 1000 wei 
            "Collateral post liquidation mismatch"
        );

        assertApproxEqAbs(
            strategyCBALRETH.balanceOf(regularBorrowers[0]),
            collateralAmounts[2] - (regularLiqValuesBorrower3.collateralLiquidated),
            1000, // Tolerance of 1000 wei 
            "Collateral post liquidation mismatch"
        );

        assertApproxEqAbs(
            strategyCBALRETH.balanceOf(regularBorrowers[1]),
            collateralAmounts[3] - (regularLiqValuesBorrower4.collateralLiquidated),
            1000, // Tolerance of 1000 wei 
            "Collateral post liquidation mismatch"
        );

        // Assert Total borrows is reduced by the amount of debt repaid

        totalDebtRepaid = auctionLiqValuesBorrower1.debtRepaid +
            auctionLiqValuesBorrower2.debtRepaid +
            regularLiqValuesBorrower3.debtRepaid +
            regularLiqValuesBorrower4.debtRepaid;

        assertApproxEqAbs(
            borrowableCUSDC.marketOutstandingDebt(),
            totalBorrowsBefore - totalDebtRepaid - totalBadDebtAuction - totalBadDebtRegular,
            100, // Small tolerance
            "Incorrect totalBorrows after liquidation"
        );

        // Verify liquidator received the expected collateral
        uint256 expectedAuctionPermsUserLiquidatorBalance = 
            auctionLiqValuesBorrower1.collateralLiquidated + 
            auctionLiqValuesBorrower2.collateralLiquidated;

        uint256 expectedNormalUserLiquidatorBalance = 
            regularLiqValuesBorrower3.collateralLiquidated +
            regularLiqValuesBorrower4.collateralLiquidated;

        assertApproxEqAbs(
            strategyCBALRETH.balanceOf(auctionPermsUser),
            expectedAuctionPermsUserLiquidatorBalance,
            1000,
            "Dapp control user didn't receive expected collateral"
        );

        assertApproxEqAbs(
            strategyCBALRETH.balanceOf(address(this)),
            expectedNormalUserLiquidatorBalance,
            1000,
            "Liquidator didn't receive expected collateral"
        );

        // Verify lFactors
        // Auction borrowers should still have lFactor > 0
        // Regular borrowers should have lFactor since fully liquidated

        for(uint i = 0; i < 2; i++) {
            (uint256 lFactorAfter,,) = marketManagerIsolated.liquidationStatusOf(
                auctionBorrowers[i],
                address(borrowableCUSDC),
                address(strategyCBALRETH)
            );

            assertGt(lFactorAfter, 0, "Auction borrower should still have lFactor > 0");
        }

        for(uint i = 0; i < 2; i++) {
            (uint256 lFactorAfter,,) = marketManagerIsolated.liquidationStatusOf(
                regularBorrowers[i],
                address(borrowableCUSDC),
                address(strategyCBALRETH)
            );

            assertEq(lFactorAfter, 0, "Regular borrower should have lFactor = 0");
        }
    }

    function _createPositions() internal {
        _prepareBALRETH(borrower1, collateralAmounts[0]);
        _prepareBALRETH(borrower2, collateralAmounts[1]);
        _prepareBALRETH(borrower3, collateralAmounts[2]);
        _prepareBALRETH(borrower4, collateralAmounts[3]);

        vm.startPrank(borrower1);
        balRETH.approve(address(strategyCBALRETH), collateralAmounts[0]);
        strategyCBALRETH.depositAsCollateral(collateralAmounts[0], borrower1);
        borrowableCUSDC.borrow(borrowAmount, borrower1);
        vm.stopPrank();

        vm.startPrank(borrower2);
        balRETH.approve(address(strategyCBALRETH), collateralAmounts[1]);
        strategyCBALRETH.depositAsCollateral(collateralAmounts[1], borrower2);
        borrowableCUSDC.borrow(borrowAmount, borrower2);
        vm.stopPrank();

        vm.startPrank(borrower3);
        balRETH.approve(address(strategyCBALRETH), collateralAmounts[2]);
        strategyCBALRETH.depositAsCollateral(collateralAmounts[2], borrower3);
        borrowableCUSDC.borrow(borrowAmount, borrower3);
        vm.stopPrank();

        vm.startPrank(borrower4);
        balRETH.approve(address(strategyCBALRETH), collateralAmounts[3]);
        strategyCBALRETH.depositAsCollateral(collateralAmounts[3], borrower4);
        borrowableCUSDC.borrow(borrowAmount, borrower4);
        vm.stopPrank();

    }

    function _getDebtBalancePreLiquidation(address[] memory borrowers) internal view returns (uint256[] memory debtBalances) {
        debtBalances = new uint256[](borrowers.length);
        for(uint i; i < borrowers.length; i++) {
            debtBalances[i] = borrowableCUSDC.debtBalance(borrowers[i]);
        }
        return debtBalances;
    }

}