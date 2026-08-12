// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {TestBaseLendingOptimizer} from "../TestBaseLendingOptimizer.sol";
import {
    LendingOptimizer
} from "contracts/market/optimizer/LendingOptimizer.sol";
import {
    LendingOptimizerShareCToken
} from "contracts/market/token/LendingOptimizerShareCToken.sol";
import {BorrowableCToken} from "contracts/market/token/BorrowableCToken.sol";
import {SimpleCToken} from "contracts/market/token/SimpleCToken.sol";
import {DynamicIRM} from "contracts/market/DynamicIRM.sol";
import {
    MarketManagerIsolated
} from "contracts/market/isolated/MarketManagerIsolated.sol";
import {CentralRegistry} from "contracts/architecture/CentralRegistry.sol";
import {
    VaultAggregator
} from "contracts/oracles/adaptors/wrappedAggregators/VaultAggregator.sol";
import {MockV3Aggregator} from "contracts/mocks/MockV3Aggregator.sol";
import {IBorrowableCToken} from "contracts/interfaces/IBorrowableCToken.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {
    FixedPointMathLib
} from "contracts/libraries/external/FixedPointMathLib.sol";
import {WAD} from "contracts/libraries/ConstantsLib.sol";

/// @notice Regression coverage for the one-hop optimizer admission check.
/// @dev C1 wraps the optimizer, C2 is an ordinary cToken wrapping C1, and D is
///      the optimizer-owned debt market paired with C2:
///      optimizer -> D <-> C2 -> C1 -> optimizer.
contract NestedOptimizerAdmissionRegression is TestBaseLendingOptimizer {
    struct NestedMarket {
        MarketManagerIsolated manager;
        BorrowableCToken debtCToken;
        SimpleCToken nestedCollateralCToken;
    }

    LendingOptimizerShareCToken internal optimizerShareCToken;
    MarketManagerIsolated internal optimizerShareManager;
    BorrowableCToken internal directPairedDebtCToken;

    address internal victim = makeAddr("nestedAdmissionVictim");
    address internal borrowerA = makeAddr("nestedAdmissionBorrowerA");
    address internal borrowerB = makeAddr("nestedAdmissionBorrowerB");
    address internal nestedLiquidator = makeAddr("nestedAdmissionLiquidator");

    function setUp() public override {
        super.setUp();
        _setUpOneMarket();

        optimizerShareManager =
            new MarketManagerIsolated(liveCentralRegistry, 10e18, false);
        CentralRegistry(address(liveCentralRegistry))
            .addMarketManager(address(optimizerShareManager));

        DynamicIRM shareIrm = _newIrm();
        optimizerShareCToken = new LendingOptimizerShareCToken(
            liveCentralRegistry,
            optimizer,
            address(optimizerShareManager),
            address(shareIrm)
        );
        shareIrm.setLinkedToken(address(optimizerShareCToken));

        DynamicIRM debtIrm = _newIrm();
        directPairedDebtCToken = new BorrowableCToken(
            liveCentralRegistry,
            IERC20(USDC_MONAD),
            address(optimizerShareManager),
            address(debtIrm)
        );
        debtIrm.setLinkedToken(address(directPairedDebtCToken));

        _registerNestedPricePath();
        _oracleManager.addCTokenSupport(address(optimizerShareCToken));
        _oracleManager.addCTokenSupport(address(directPairedDebtCToken));

        _depositIntoOptimizer(address(this), 100_000e6);
        IERC20(address(optimizer))
            .approve(address(optimizerShareCToken), 77777);
        deal(USDC_MONAD, address(this), 77777);
        IERC20(USDC_MONAD).approve(address(directPairedDebtCToken), 77777);
        optimizerShareManager.listTokens(
            address(optimizerShareCToken), address(directPairedDebtCToken)
        );
        _configureNestedToken(
            optimizerShareManager,
            address(optimizerShareCToken),
            7_000,
            1_000_000e6,
            0
        );
        _configureNestedToken(
            optimizerShareManager,
            address(directPairedDebtCToken),
            0,
            0,
            1_000_000e6
        );

        // initializeDeposits permanently locks its shares; mint a small owned
        // balance that can seed C2's own locked reserve.
        _mintShareCToken(address(this), address(this), 1e6);
    }

    function test_nestedPairPassesAdmissionAndFeedsBadDebtBackIntoOptimizer()
        public
    {
        _assertDirectPairRejected();
        _assertNormalPairAccepted();

        NestedMarket memory nested = _deployNestedMarket();
        optimizer.addApprovedAsset(address(nested.debtCToken), 10_000);
        assertEq(
            optimizer.allocationCaps(address(nested.debtCToken)),
            WAD,
            "nested pair must pass the current one-hop admission check"
        );

        _depositIntoOptimizer(victim, 100_000e6);
        _depositIntoOptimizer(address(this), 100_000e6);
        _allocateToNestedDebtMarket(nested.debtCToken, 30_000e6);
        _postNestedCollateral(nested, borrowerA, 50_000e6);

        vm.warp(block.timestamp + 1201);
        vm.prank(borrowerA);
        nested.debtCToken.borrow(30_000e6, borrowerA);

        uint256 staleNav = optimizer.totalAssets();
        _mockIndependentMarketLoss(300e6);
        optimizer.accrueIfNeeded();
        uint256 navBeforeFeedback = optimizer.totalAssets();
        assertLt(
            navBeforeFeedback,
            staleNav / 2,
            "independent market loss must materially impair optimizer collateral"
        );

        (, uint256 maxDebt, uint256 debt) = nested.manager.statusOf(borrowerA);
        assertGt(
            debt,
            maxDebt,
            "nested optimizer-backed collateral must become underwater"
        );

        uint256 badDebt = _liquidate(nested, borrowerA);
        assertGt(
            badDebt,
            20_000e6,
            "recursive market must realize material bad debt"
        );
        assertEq(
            optimizer.totalAssets(),
            navBeforeFeedback,
            "recursive market loss must remain cached until optimizer accrual"
        );

        uint256 victimAssetsBeforeFeedback =
            optimizer.convertToAssets(optimizer.balanceOf(victim));
        optimizer.accrueIfNeeded();
        uint256 feedbackLoss = navBeforeFeedback - optimizer.totalAssets();
        uint256 victimAssetsAfterFeedback =
            optimizer.convertToAssets(optimizer.balanceOf(victim));

        assertApproxEqAbs(
            feedbackLoss,
            badDebt,
            1e6,
            "D bad debt must feed back into optimizer NAV"
        );
        assertLt(
            victimAssetsAfterFeedback,
            victimAssetsBeforeFeedback,
            "unrelated optimizer holder must absorb recursive market loss"
        );
    }

    function test_recursiveBadDebtCreatesSecondBorrowerStaleCreditWindow()
        public
    {
        NestedMarket memory nested = _deployNestedMarket();
        optimizer.addApprovedAsset(address(nested.debtCToken), 10_000);

        _depositIntoOptimizer(victim, 100_000e6);
        _depositIntoOptimizer(borrowerA, 50_000e6);
        _depositIntoOptimizer(borrowerB, 100_000e6);
        _allocateToNestedDebtMarket(nested.debtCToken, 30_000e6);

        _postNestedCollateralFromOwner(
            nested, borrowerA, optimizer.balanceOf(borrowerA)
        );
        _postNestedCollateralFromOwner(
            nested, borrowerB, optimizer.balanceOf(borrowerB)
        );

        vm.warp(block.timestamp + 1201);
        vm.prank(borrowerA);
        nested.debtCToken.borrow(30_000e6, borrowerA);

        _mockIndependentMarketLoss(350e6);
        optimizer.accrueIfNeeded();
        uint256 badDebt = _liquidate(nested, borrowerA);
        assertGt(
            badDebt, 20_000e6, "first liquidation must impair D materially"
        );

        (, uint256 staleMaxDebt,) = nested.manager.statusOf(borrowerB);
        uint256 snapshot = vm.snapshotState();
        optimizer.accrueIfNeeded();
        (, uint256 freshMaxDebt,) = nested.manager.statusOf(borrowerB);
        assertLt(
            freshMaxDebt,
            staleMaxDebt,
            "D bad debt must lower optimizer-backed borrowing power"
        );

        uint256 borrowValue = (staleMaxDebt + freshMaxDebt) / 2;
        uint256 borrowAssets = FixedPointMathLib.mulDiv(borrowValue, 1e6, WAD);
        assertGt(
            borrowAssets,
            10e6,
            "stale/fresh window must exceed minimum loan size"
        );

        vm.prank(borrowerB);
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral
            .selector
        );
        nested.debtCToken.borrow(borrowAssets, borrowerB);

        assertTrue(
            vm.revertToState(snapshot), "failed to restore stale-price branch"
        );

        uint256 cachedNavBeforeStaleBorrow = optimizer.totalAssets();
        vm.prank(borrowerB);
        nested.debtCToken.borrow(borrowAssets, borrowerB);
        assertEq(
            optimizer.totalAssets(),
            cachedNavBeforeStaleBorrow,
            "borrow path must leave optimizer NAV cached"
        );

        optimizer.accrueIfNeeded();
        (, uint256 maxDebtAfterAccrual, uint256 debtAfterBorrow) =
            nested.manager.statusOf(borrowerB);
        assertGt(
            debtAfterBorrow,
            maxDebtAfterAccrual,
            "borrow accepted at stale recursive value must become unhealthy"
        );
    }

    function _deployNestedMarket()
        internal
        returns (NestedMarket memory nested)
    {
        nested.manager = new MarketManagerIsolated(
            liveCentralRegistry, 10e18, false
        );
        CentralRegistry(address(liveCentralRegistry))
            .addMarketManager(address(nested.manager));

        DynamicIRM debtIrm = _newIrm();
        nested.debtCToken = new BorrowableCToken(
            liveCentralRegistry,
            IERC20(USDC_MONAD),
            address(nested.manager),
            address(debtIrm)
        );
        debtIrm.setLinkedToken(address(nested.debtCToken));

        nested.nestedCollateralCToken = new SimpleCToken(
            liveCentralRegistry,
            IERC20(address(optimizerShareCToken)),
            address(nested.manager)
        );

        _oracleManager.addCTokenSupport(address(nested.debtCToken));
        _oracleManager.addCTokenSupport(address(nested.nestedCollateralCToken));

        IERC20(address(optimizerShareCToken))
            .approve(address(nested.nestedCollateralCToken), 77777);
        deal(USDC_MONAD, address(this), 77777);
        IERC20(USDC_MONAD).approve(address(nested.debtCToken), 77777);
        nested.manager
            .listTokens(
                address(nested.nestedCollateralCToken),
                address(nested.debtCToken)
            );
        _configureNestedToken(
            nested.manager,
            address(nested.nestedCollateralCToken),
            7_000,
            1_000_000e6,
            0
        );
        _configureNestedToken(
            nested.manager, address(nested.debtCToken), 0, 0, 1_000_000e6
        );
    }

    function _assertDirectPairRejected() internal {
        vm.expectRevert(
            LendingOptimizer.LendingOptimizer__InvalidMarketManager.selector
        );
        optimizer.addApprovedAsset(address(directPairedDebtCToken), 1_000);
    }

    function _assertNormalPairAccepted() internal {
        uint256 snapshot = vm.snapshotState();
        optimizer.addApprovedAsset(cUSDC_WBTC_MARKET, 1_000);
        assertEq(
            optimizer.allocationCaps(cUSDC_WBTC_MARKET),
            WAD / 10,
            "ordinary independent market must remain admissible"
        );
        assertTrue(
            vm.revertToState(snapshot), "failed to restore control state"
        );
    }

    function _allocateToNestedDebtMarket(
        BorrowableCToken debtCToken,
        uint256 assets
    ) internal {
        LendingOptimizer.ReallocationAction[] memory
            actions = new LendingOptimizer.ReallocationAction[](2);
        actions[0] = LendingOptimizer.ReallocationAction({
            cToken: IBorrowableCToken(cUSDC_WMON_MARKET),
            assetsOrBps: -int256(assets)
        });
        actions[1] = LendingOptimizer.ReallocationAction({
            cToken: IBorrowableCToken(address(debtCToken)),
            assetsOrBps: int256(assets)
        });
        optimizer.rebalance(actions, _unconstrainedBounds());
    }

    function _postNestedCollateral(
        NestedMarket memory nested,
        address account,
        uint256 optimizerShares
    ) internal {
        _mintShareCToken(address(this), account, optimizerShares);
        _postShareCTokenAsNestedCollateral(nested, account, optimizerShares);
    }

    function _postNestedCollateralFromOwner(
        NestedMarket memory nested,
        address account,
        uint256 optimizerShares
    ) internal {
        _mintShareCToken(account, account, optimizerShares);
        _postShareCTokenAsNestedCollateral(nested, account, optimizerShares);
    }

    function _mintShareCToken(
        address optimizerShareOwner,
        address receiver,
        uint256 optimizerShares
    ) internal {
        vm.startPrank(optimizerShareOwner);
        IERC20(address(optimizer))
            .approve(address(optimizerShareCToken), optimizerShares);
        optimizerShareCToken.deposit(optimizerShares, receiver);
        vm.stopPrank();
    }

    function _postShareCTokenAsNestedCollateral(
        NestedMarket memory nested,
        address account,
        uint256 shares
    ) internal {
        vm.startPrank(account);
        IERC20(address(optimizerShareCToken))
            .approve(address(nested.nestedCollateralCToken), shares);
        nested.nestedCollateralCToken.depositAsCollateral(shares, account);
        vm.stopPrank();
    }

    function _mockIndependentMarketLoss(uint256 remainingAssets) internal {
        IBorrowableCToken independentMarket =
            IBorrowableCToken(cUSDC_WMON_MARKET);
        uint256 optimizerMarketShares =
            independentMarket.balanceOf(address(optimizer));
        vm.mockCall(
            cUSDC_WMON_MARKET,
            abi.encodeWithSelector(
                IBorrowableCToken.convertToAssets.selector,
                optimizerMarketShares
            ),
            abi.encode(remainingAssets)
        );
    }

    function _liquidate(NestedMarket memory nested, address account)
        internal
        returns (uint256 badDebt)
    {
        uint256 totalAssetsBefore = nested.debtCToken.totalAssets();
        address[] memory accounts = new address[](1);
        accounts[0] = account;

        deal(USDC_MONAD, nestedLiquidator, 100_000e6);
        vm.startPrank(nestedLiquidator);
        IERC20(USDC_MONAD)
            .approve(address(nested.debtCToken), type(uint256).max);
        nested.debtCToken
            .liquidate(accounts, address(nested.nestedCollateralCToken));
        vm.stopPrank();

        badDebt = totalAssetsBefore - nested.debtCToken.totalAssets();
    }

    function _registerNestedPricePath() internal {
        MockV3Aggregator usdcFeed = new MockV3Aggregator(8, 1e8);
        VaultAggregator optimizerFeed = new VaultAggregator(
            address(optimizer), USDC_MONAD, address(usdcFeed), "optimizer/USD"
        );
        _chainlinkAdaptor.addAsset(
            address(optimizer), true, address(optimizerFeed), 0
        );
        _oracleManager.addAssetPricingAdaptor(
            address(optimizer), address(_chainlinkAdaptor), 0, 0, 0, 0
        );

        VaultAggregator shareCTokenFeed = new VaultAggregator(
            address(optimizerShareCToken),
            address(optimizer),
            address(optimizerFeed),
            "optimizer-cToken/USD"
        );
        _chainlinkAdaptor.addAsset(
            address(optimizerShareCToken), true, address(shareCTokenFeed), 0
        );
        _oracleManager.addAssetPricingAdaptor(
            address(optimizerShareCToken),
            address(_chainlinkAdaptor),
            0,
            0,
            0,
            0
        );
    }

    function _depositIntoOptimizer(address receiver, uint256 assets) internal {
        deal(USDC_MONAD, receiver, assets);
        vm.startPrank(receiver);
        IERC20(USDC_MONAD).approve(address(optimizer), assets);
        optimizer.deposit(assets, receiver);
        vm.stopPrank();
    }

    function _configureNestedToken(
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

    function _newIrm() internal returns (DynamicIRM) {
        return new DynamicIRM(
            liveCentralRegistry, 1_200, 2_000, 8_500, 500, 200, 100_000
        );
    }
}
