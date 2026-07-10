// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {TestBaseLendingOptimizer} from "../TestBaseLendingOptimizer.sol";
import {
    LendingOptimizer
} from "contracts/market/optimizer/LendingOptimizer.sol";
import {LendingOptimizerHarness} from "../LendingOptimizerHarness.sol";
import {
    MarketManagerIsolated
} from "contracts/market/isolated/MarketManagerIsolated.sol";
import {BorrowableCToken} from "contracts/market/token/BorrowableCToken.sol";
import {MockV3Aggregator} from "contracts/mocks/MockV3Aggregator.sol";
import {IBorrowableCToken} from "contracts/interfaces/IBorrowableCToken.sol";
import {ICToken} from "contracts/interfaces/ICToken.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {
    FixedPointMathLib
} from "contracts/libraries/external/FixedPointMathLib.sol";
import {BPS} from "contracts/libraries/ConstantsLib.sol";

/// @notice Regression coverage for loss allocation when an optimizer holder
///         exits after a borrower is known to be underwater but before the
///         lending market has realized its bad debt.
contract PreLiquidationExitLossRegression is TestBaseLendingOptimizer {
    struct BranchOutcome {
        uint256 badDebt;
        uint256 firstHolderAssets;
        uint256 secondHolderAssets;
        uint256 riskyMarketFunding;
        uint256 healthyMarketFunding;
    }

    address internal holderOne = makeAddr("preLiquidationHolderOne");
    address internal holderTwo = makeAddr("preLiquidationHolderTwo");
    address internal underwaterBorrower =
        makeAddr("preLiquidationUnderwaterBorrower");
    address internal liquidationAccount = makeAddr("preLiquidationLiquidator");

    address internal riskyMarket;
    address internal healthyMarketOne;
    address internal healthyMarketTwo;

    function setUp() public override {
        super.setUp();

        // Use a fresh market for the impaired loan so the base fixture's
        // seeded borrowers remain unrelated healthy-market background state.
        riskyMarket = _deployMarket(600, 2400, 8000, 1000, 100, 100000);
        healthyMarketOne = cUSDC_WBTC_MARKET;
        healthyMarketTwo = cUSDC_WETH_MARKET;

        address[] memory approvedMarkets = new address[](3);
        approvedMarkets[0] = riskyMarket;
        approvedMarkets[1] = healthyMarketOne;
        approvedMarkets[2] = healthyMarketTwo;

        uint256[] memory allocationCaps = new uint256[](3);
        allocationCaps[0] = 4_000;
        allocationCaps[1] = 4_000;
        allocationCaps[2] = 4_000;

        optimizer = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedMarkets,
            allocationCaps,
            1_000
        );

        deal(USDC_MONAD, address(this), 77777);
        IERC20(USDC_MONAD).approve(address(optimizer), 77777);
        optimizer.initializeDeposits(riskyMarket);

        _productionDeposit(holderOne, 100_000e6);
        _productionDeposit(holderTwo, 100_000e6);
        _openRiskyMarketLoan();
        _rebalanceToCapCompliantAllocation();
        _makeRiskyMarketLoanUnderwater();
    }

    function test_preLiquidationExitUsesHealthyLiquidityAndShiftsRealizedLoss()
        public
    {
        _assertCapCompliantAllocation();

        MarketManagerIsolated riskyManager =
            MarketManagerIsolated(_marketMgrs[riskyMarket]);
        (, uint256 maxDebt, uint256 debt) =
            riskyManager.statusOf(underwaterBorrower);
        assertGt(
            debt, maxDebt, "precondition: borrower must already be underwater"
        );

        uint256 snapshot = vm.snapshotState();
        BranchOutcome memory exitFirst = _runBranch(true);
        assertTrue(
            vm.revertToState(snapshot), "failed to restore branch state"
        );
        BranchOutcome memory liquidateFirst = _runBranch(false);

        assertGt(exitFirst.badDebt, 0, "liquidation must realize bad debt");
        assertEq(
            exitFirst.badDebt,
            liquidateFirst.badDebt,
            "exit timing must not change aggregate protocol bad debt"
        );
        assertGt(
            exitFirst.firstHolderAssets,
            liquidateFirst.firstHolderAssets,
            "pre-liquidation exiter must receive more than a loss-adjusted holder"
        );
        assertLt(
            exitFirst.secondHolderAssets,
            liquidateFirst.secondHolderAssets,
            "remaining holder must absorb the shifted loss"
        );
        assertGt(
            exitFirst.firstHolderAssets - liquidateFirst.firstHolderAssets,
            30_000e6,
            "the first-exit advantage must be economically material"
        );
        assertGt(
            liquidateFirst.secondHolderAssets - exitFirst.secondHolderAssets,
            30_000e6,
            "the remaining-holder loss must be economically material"
        );

        assertGt(
            exitFirst.riskyMarketFunding,
            0,
            "early redemption must consume the risky market's available cash"
        );
        assertGt(
            exitFirst.healthyMarketFunding,
            0,
            "early redemption must use cross-market healthy liquidity"
        );
        assertGt(
            exitFirst.healthyMarketFunding,
            exitFirst.riskyMarketFunding,
            "healthy markets must fund most of the pre-liquidation exit"
        );
    }

    function _productionDeposit(address holder, uint256 assets) internal {
        deal(USDC_MONAD, holder, assets);
        vm.startPrank(holder);
        IERC20(USDC_MONAD).approve(address(optimizer), assets);
        optimizer.deposit(assets, holder);
        vm.stopPrank();
    }

    function _rebalanceToCapCompliantAllocation() internal {
        optimizer.accrueIfNeeded();

        uint256 total = optimizer.totalAssets();
        uint256 riskyAssets = _optimizerMarketAssets(riskyMarket);
        uint256 riskyTarget = FixedPointMathLib.mulDiv(total, 3_990, BPS);
        // Leave one atomic unit below the exact 40% edge so cToken rounding
        // cannot turn an intended cap-compliant action into 4,001 BPS.
        uint256 healthyOneTarget =
            FixedPointMathLib.mulDiv(total, 4_000, BPS) - 1;
        uint256 amountToMove = riskyAssets - riskyTarget;
        uint256 healthyTwoTarget = amountToMove - healthyOneTarget;

        LendingOptimizer.ReallocationAction[] memory actions =
            new LendingOptimizer.ReallocationAction[](3);
        actions[0] = LendingOptimizer.ReallocationAction({
            cToken: IBorrowableCToken(riskyMarket),
            assetsOrBps: -int256(amountToMove)
        });
        actions[1] = LendingOptimizer.ReallocationAction({
            cToken: IBorrowableCToken(healthyMarketOne),
            assetsOrBps: int256(healthyOneTarget)
        });
        actions[2] = LendingOptimizer.ReallocationAction({
            cToken: IBorrowableCToken(healthyMarketTwo),
            assetsOrBps: int256(healthyTwoTarget)
        });

        optimizer.rebalance(actions, _unconstrainedBounds());
    }

    function _openRiskyMarketLoan() internal {
        MarketManagerIsolated manager =
            MarketManagerIsolated(_marketMgrs[riskyMarket]);
        address collateralAsset = _collaterals[riskyMarket];
        address collateralCToken = _collCTokens[riskyMarket];

        // Permit full closeout so the liquidation deterministically realizes
        // the unrecoverable balance in one transaction.
        _configureBadDebtToken(
            manager, collateralCToken, 7_000, 1_000_000e18, 0
        );
        _configureBadDebtToken(manager, riskyMarket, 0, 0, 1_000_000e6);

        uint256 collateralAssets = 100_000e18;
        deal(collateralAsset, underwaterBorrower, collateralAssets);
        vm.startPrank(underwaterBorrower);
        IERC20(collateralAsset).approve(collateralCToken, collateralAssets);
        ICToken(collateralCToken)
            .depositAsCollateral(collateralAssets, underwaterBorrower);
        vm.stopPrank();

        vm.warp(block.timestamp + 1201);
        vm.prank(underwaterBorrower);
        IBorrowableCToken(riskyMarket).borrow(70_000e6, underwaterBorrower);

        // Let debt grow while the position remains healthy, then restore fresh
        // feeds before producing the cap-compliant allocation checkpoint.
        skip(30 days);
        _chainlinkAdaptor.addAsset(
            USDC_MONAD, true, address(new MockV3Aggregator(8, 1e8)), 0
        );
        _chainlinkAdaptor.addAsset(
            collateralAsset, true, address(new MockV3Aggregator(8, 1e8)), 0
        );

        // Pin debt/index accounting before the same-block differential.
        IBorrowableCToken(riskyMarket).exchangeRateUpdated();
    }

    function _makeRiskyMarketLoanUnderwater() internal {
        _chainlinkAdaptor.addAsset(
            _collaterals[riskyMarket],
            true,
            address(new MockV3Aggregator(8, 1)),
            0
        );
    }

    function _runBranch(bool exitBeforeLiquidation)
        internal
        returns (BranchOutcome memory outcome)
    {
        if (exitBeforeLiquidation) {
            uint256 riskyBefore = _optimizerMarketAssets(riskyMarket);
            uint256 healthyBefore = _optimizerMarketAssets(healthyMarketOne)
                + _optimizerMarketAssets(healthyMarketTwo);

            outcome.firstHolderAssets = _redeemAll(holderOne);

            outcome.riskyMarketFunding =
                riskyBefore - _optimizerMarketAssets(riskyMarket);
            outcome.healthyMarketFunding = healthyBefore
                - _optimizerMarketAssets(healthyMarketOne)
                - _optimizerMarketAssets(healthyMarketTwo);
            outcome.badDebt = _liquidateUnderwaterBorrower();
            optimizer.accrueIfNeeded();
            outcome.secondHolderAssets = _redeemAll(holderTwo);
        } else {
            outcome.badDebt = _liquidateUnderwaterBorrower();
            optimizer.accrueIfNeeded();
            outcome.firstHolderAssets = _redeemAll(holderOne);
            outcome.secondHolderAssets = _redeemAll(holderTwo);
        }
    }

    function _liquidateUnderwaterBorrower()
        internal
        returns (uint256 badDebt)
    {
        BorrowableCToken debtCToken = BorrowableCToken(riskyMarket);
        uint256 totalAssetsBefore = debtCToken.totalAssets();
        address[] memory accounts = new address[](1);
        accounts[0] = underwaterBorrower;

        deal(USDC_MONAD, liquidationAccount, 100_000e6);
        vm.startPrank(liquidationAccount);
        IERC20(USDC_MONAD).approve(riskyMarket, type(uint256).max);
        debtCToken.liquidate(accounts, _collCTokens[riskyMarket]);
        vm.stopPrank();

        badDebt = totalAssetsBefore - debtCToken.totalAssets();
    }

    function _redeemAll(address holder) internal returns (uint256 assets) {
        uint256 balanceBefore = IERC20(USDC_MONAD).balanceOf(holder);
        uint256 shares = optimizer.balanceOf(holder);
        vm.prank(holder);
        optimizer.redeem(shares, holder, holder);
        assets = IERC20(USDC_MONAD).balanceOf(holder) - balanceBefore;
    }

    function _optimizerMarketAssets(address market)
        internal
        view
        returns (uint256)
    {
        IBorrowableCToken cToken = IBorrowableCToken(market);
        return cToken.convertToAssets(cToken.balanceOf(address(optimizer)));
    }

    function _assertCapCompliantAllocation() internal view {
        uint256 total = _optimizerMarketAssets(riskyMarket)
            + _optimizerMarketAssets(healthyMarketOne)
            + _optimizerMarketAssets(healthyMarketTwo);

        assertLe(
            FixedPointMathLib.mulDiv(
                _optimizerMarketAssets(riskyMarket), BPS, total
            ),
            4_000,
            "risky allocation must respect its cap"
        );
        assertLe(
            FixedPointMathLib.mulDiv(
                _optimizerMarketAssets(healthyMarketOne), BPS, total
            ),
            4_000,
            "first healthy allocation must respect its cap"
        );
        assertLe(
            FixedPointMathLib.mulDiv(
                _optimizerMarketAssets(healthyMarketTwo), BPS, total
            ),
            4_000,
            "second healthy allocation must respect its cap"
        );
    }

    function _configureBadDebtToken(
        MarketManagerIsolated manager,
        address cToken,
        uint256 collRatio,
        uint256 collateralCap,
        uint256 debtCap
    ) internal {
        MarketManagerIsolated.TokenConfig memory config;
        config.cToken = cToken;
        config.collRatio = collRatio;
        config.collReqSoft = 4_000;
        config.collReqHard = 3_000;
        config.liqIncBase = 1_000;
        config.liqIncHard = 1_500;
        config.liqIncMin = 10;
        config.liqIncMax = 2_000;
        config.closeFactorBase = 5_000;
        config.closeFactorMin = 5_000;
        config.closeFactorMax = 10_000;
        config.collateralCap = collateralCap;
        config.debtCap = debtCap;
        manager.updateTokenConfig(config);
    }
}
