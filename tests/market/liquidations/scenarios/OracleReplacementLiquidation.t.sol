// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { MockOracleAdaptor } from "contracts/mocks/MockOracleAdaptor.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract TestOracleReplacementLiquidation is TestBaseMarketIsolated {
    struct OraclePairSnapshot {
        uint256 collateralSharesPrice;
        uint256 debtUnderlyingPrice;
    }

    struct OracleMutationPlan {
        address asset;
        address primaryAdaptor;
        address secondaryAdaptor;
        bytes4 replaceAdaptorSelector;
        bytes4 removeAdaptorSelector;
    }

    struct OracleMutationExecution {
        address primaryMockAdaptor;
        address secondaryMockAdaptor;
        uint256 configuredPrice;
    }

    struct LiquidationProbe {
        bool liquidationAvailable;
        uint256 debtAmountInput;
        uint256 debtAmountResolved;
        uint256 collateralPosted;
        uint256 debtBalance;
        uint256 liquidatedShares;
        uint256 debtRepaid;
        uint256 badDebtRealized;
    }

    struct OracleMutationBranch {
        OraclePairSnapshot beforeSnapshot;
        OraclePairSnapshot afterSnapshot;
        LiquidationProbe beforeProbe;
        LiquidationProbe afterProbe;
        OracleMutationExecution execution;
    }

    function setUp() public override {
        super.setUp();

        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);
        _refreshMockFeeds();

        (, int256 ethPrice, , , ) = mockWethFeed.latestRoundData();
        chainlinkEthUsd.updateAnswer(ethPrice);

        // `listTokens` initializes deposits for both markets, so the test
        // harness must front-load the same approval/funding prerequisites as
        // the upstream dynamic liquidation suite.
        _prepareDAI(address(this), 200000e18);
        dai.approve(address(borrowableCDAI), 200000e18);
        deal(address(LP_wstETH_24Dec2025), address(this), 1e18);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 1e18);

        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(borrowableCDAI));

        _setCTokenConfigBasic(address(pendleStrategyCTokenSTETH), 100e18, 0);
        _setCTokenConfigBasic(address(borrowableCDAI), 100e18, 100_000e18);

        _provideEnoughLiquidityForLeverage();

        deal(address(LP_wstETH_24Dec2025), user1, 1e18);
        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 1e18);
        pendleStrategyCTokenSTETH.deposit(1e18, user1);
        pendleStrategyCTokenSTETH.postCollateral(1e18 - 1);
        borrowableCDAI.borrow(5000e18, user1);
        vm.stopPrank();

        skip(20 minutes);
        borrowableCDAI.accrueIfNeeded();
    }

    function test_oracleLiquidation_oracleReplacementEnablesLiquidation() public {
        OracleMutationBranch memory branch = _runOracleMutationBranch(2e18);

        assertGt(branch.beforeSnapshot.collateralSharesPrice, 0, "oracle-liquidation:missing-collateral-price");
        assertApproxEqRel(branch.beforeSnapshot.debtUnderlyingPrice, 1e18, 0.001e18, "oracle-liquidation:baseline-debt-price-drift");
        assertFalse(branch.beforeProbe.liquidationAvailable, "oracle-liquidation:baseline-should-be-healthy");
        assertEq(branch.beforeProbe.debtRepaid, 0, "oracle-liquidation:baseline-debt-repaid");

        assertTrue(branch.execution.primaryMockAdaptor != address(0), "oracle-liquidation:primary-mock-missing");
        assertTrue(branch.execution.secondaryMockAdaptor != address(0), "oracle-liquidation:secondary-mock-missing");
        assertEq(branch.execution.configuredPrice, 2e18, "oracle-liquidation:configured-price");
        assertEq(
            branch.afterSnapshot.collateralSharesPrice,
            branch.beforeSnapshot.collateralSharesPrice,
            "oracle-liquidation:collateral-price-drift"
        );
        assertGt(
            branch.afterSnapshot.debtUnderlyingPrice,
            branch.beforeSnapshot.debtUnderlyingPrice,
            "oracle-liquidation:debt-price-did-not-increase"
        );
        assertEq(branch.afterSnapshot.debtUnderlyingPrice, 2e18, "oracle-liquidation:unexpected-mutated-debt-price");
        assertEq(branch.afterProbe.collateralPosted, branch.beforeProbe.collateralPosted, "oracle-liquidation:collateral-posted-drift");
        assertEq(branch.afterProbe.debtBalance, branch.beforeProbe.debtBalance, "oracle-liquidation:debt-balance-drift");
        assertTrue(branch.afterProbe.liquidationAvailable, "oracle-liquidation:mutation-should-enable-liquidation");
        assertGt(branch.afterProbe.liquidatedShares, 0, "oracle-liquidation:missing-liquidated-shares");
        assertGt(branch.afterProbe.debtRepaid, 0, "oracle-liquidation:missing-debt-repaid");
    }

    function test_oracleLiquidation_parityAdaptorReplacementPreservesLiquidationState() public {
        OracleMutationBranch memory branch = _runOracleMutationBranch(1e18);

        assertEq(branch.execution.configuredPrice, 1e18, "oracle-liquidation:unexpected-parity-config");
        assertEq(
            branch.afterSnapshot.collateralSharesPrice,
            branch.beforeSnapshot.collateralSharesPrice,
            "oracle-liquidation:parity-collateral-price-drift"
        );
        assertApproxEqRel(
            branch.afterSnapshot.debtUnderlyingPrice,
            branch.beforeSnapshot.debtUnderlyingPrice,
            0.001e18,
            "oracle-liquidation:parity-debt-price-drift"
        );
        assertEq(branch.afterProbe.collateralPosted, branch.beforeProbe.collateralPosted, "oracle-liquidation:parity-collateral-posted-drift");
        assertEq(branch.afterProbe.debtBalance, branch.beforeProbe.debtBalance, "oracle-liquidation:parity-debt-balance-drift");
        assertEq(
            branch.afterProbe.liquidationAvailable,
            branch.beforeProbe.liquidationAvailable,
            "oracle-liquidation:parity-liquidation-availability-drift"
        );
        assertEq(branch.afterProbe.liquidatedShares, branch.beforeProbe.liquidatedShares, "oracle-liquidation:parity-liquidated-shares-drift");
        assertEq(branch.afterProbe.debtRepaid, branch.beforeProbe.debtRepaid, "oracle-liquidation:parity-debt-repaid-drift");
        assertEq(
            branch.afterProbe.badDebtRealized,
            branch.beforeProbe.badDebtRealized,
            "oracle-liquidation:parity-bad-debt-drift"
        );
    }

    function test_oracleLiquidation_privilegedPricePressureOnlyChangesLiquidationRelativeToParityReplacement() public {
        uint256 baselineSnapshot = vm.snapshotState();
        OracleMutationBranch memory parityBranch = _runOracleMutationBranch(1e18);

        assertTrue(vm.revertToState(baselineSnapshot), "oracle-liquidation:failed-to-revert-baseline-snapshot");

        OracleMutationBranch memory stressedBranch = _runOracleMutationBranch(2e18);

        assertEq(
            parityBranch.beforeSnapshot.collateralSharesPrice,
            stressedBranch.beforeSnapshot.collateralSharesPrice,
            "oracle-liquidation:mismatched-baseline-collateral-price"
        );
        assertApproxEqRel(
            parityBranch.beforeSnapshot.debtUnderlyingPrice,
            stressedBranch.beforeSnapshot.debtUnderlyingPrice,
            0.001e18,
            "oracle-liquidation:mismatched-baseline-debt-price"
        );
        assertEq(
            parityBranch.beforeProbe.collateralPosted,
            stressedBranch.beforeProbe.collateralPosted,
            "oracle-liquidation:mismatched-baseline-collateral-posted"
        );
        assertEq(
            parityBranch.beforeProbe.debtBalance,
            stressedBranch.beforeProbe.debtBalance,
            "oracle-liquidation:mismatched-baseline-debt-balance"
        );

        assertEq(
            parityBranch.afterSnapshot.collateralSharesPrice,
            stressedBranch.afterSnapshot.collateralSharesPrice,
            "oracle-liquidation:collateral-price-should-not-change-across-branches"
        );
        assertApproxEqRel(
            parityBranch.afterSnapshot.debtUnderlyingPrice,
            parityBranch.beforeSnapshot.debtUnderlyingPrice,
            0.001e18,
            "oracle-liquidation:parity-branch-debt-price-drift"
        );
        assertGt(
            stressedBranch.afterSnapshot.debtUnderlyingPrice,
            parityBranch.afterSnapshot.debtUnderlyingPrice,
            "oracle-liquidation:stressed-branch-did-not-increase-debt-price"
        );

        assertFalse(parityBranch.afterProbe.liquidationAvailable, "oracle-liquidation:parity-branch-should-stay-healthy");
        assertTrue(stressedBranch.afterProbe.liquidationAvailable, "oracle-liquidation:stressed-branch-should-liquidate");
        assertEq(parityBranch.afterProbe.liquidatedShares, 0, "oracle-liquidation:parity-branch-liquidated-shares");
        assertEq(parityBranch.afterProbe.debtRepaid, 0, "oracle-liquidation:parity-branch-debt-repaid");
        assertEq(parityBranch.afterProbe.badDebtRealized, 0, "oracle-liquidation:parity-branch-bad-debt");
        assertGt(stressedBranch.afterProbe.liquidatedShares, 0, "oracle-liquidation:stressed-branch-liquidated-shares");
        assertGt(stressedBranch.afterProbe.debtRepaid, 0, "oracle-liquidation:stressed-branch-debt-repaid");
    }

    function test_oracleLiquidation_oracleReplacementCanBlockLiquidationViaBadSource() public {
        OracleMutationPlan memory mutationPlan = scaffoldOracleMutationPlan();
        OracleMutationExecution memory execution = _applyDebtOracleReplacement(mutationPlan, 2e18);
        LiquidationProbe memory liquidatableProbe = scaffoldLiquidationProbe();

        assertTrue(liquidatableProbe.liquidationAvailable, "oracle-liquidation:expected-liquidatable-baseline");

        _setDebtOracleReplacementPrice(execution, mutationPlan.asset, 0);

        vm.expectRevert(OracleManager.OracleManager__ErrorCodeFlagged.selector);
        scaffoldOraclePairSnapshot();

        _expectLiquidationBlockedByBadSource();
    }

    function test_oracleLiquidation_oracleReplacementLiquidateExactRealizesStateChange() public {
        OracleMutationPlan memory mutationPlan = scaffoldOracleMutationPlan();
        _applyDebtOracleReplacement(mutationPlan, 2e18);

        LiquidationProbe memory exactProbe = scaffoldLiquidationProbe(true, 250e18);
        assertTrue(exactProbe.liquidationAvailable, "oracle-liquidation:expected-liquidatable-exact-probe");
        assertEq(exactProbe.debtAmountInput, 250e18, "oracle-liquidation:unexpected-exact-input");
        assertGt(exactProbe.debtAmountResolved, exactProbe.debtAmountInput, "oracle-liquidation:missing-bad-debt-gross-up");
        assertApproxEqAbs(
            exactProbe.debtAmountResolved,
            exactProbe.debtRepaid + exactProbe.badDebtRealized,
            1000,
            "oracle-liquidation:resolved-debt-amount"
        );
        assertGt(exactProbe.liquidatedShares, 0, "oracle-liquidation:missing-liquidated-shares");
        assertGt(exactProbe.debtRepaid, 0, "oracle-liquidation:missing-debt-repaid");

        _prepareDAI(user2, exactProbe.debtAmountInput);

        uint256 borrowerDebtBefore = borrowableCDAI.debtBalance(user1);
        uint256 borrowerCollateralBefore = pendleStrategyCTokenSTETH.balanceOf(user1);
        uint256 liquidatorCollateralBefore = pendleStrategyCTokenSTETH.balanceOf(user2);
        uint256 liquidatorDebtAssetBefore = dai.balanceOf(user2);
        uint256 marketDebtBefore = borrowableCDAI.marketOutstandingDebt();

        address[] memory accounts = new address[](1);
        accounts[0] = user1;
        uint256[] memory debtAmounts = new uint256[](1);
        debtAmounts[0] = exactProbe.debtAmountInput;

        vm.startPrank(user2);
        dai.approve(address(borrowableCDAI), exactProbe.debtAmountInput);
        borrowableCDAI.liquidateExact(
            debtAmounts,
            accounts,
            address(pendleStrategyCTokenSTETH)
        );
        vm.stopPrank();

        uint256 borrowerDebtAfter = borrowableCDAI.debtBalance(user1);
        uint256 borrowerCollateralAfter = pendleStrategyCTokenSTETH.balanceOf(user1);
        uint256 liquidatorCollateralAfter = pendleStrategyCTokenSTETH.balanceOf(user2);
        uint256 liquidatorDebtAssetAfter = dai.balanceOf(user2);
        uint256 marketDebtAfter = borrowableCDAI.marketOutstandingDebt();

        assertApproxEqAbs(
            borrowerDebtBefore - borrowerDebtAfter,
            exactProbe.debtRepaid + exactProbe.badDebtRealized,
            1000,
            "oracle-liquidation:borrower-debt-delta"
        );
        assertApproxEqAbs(
            borrowerCollateralBefore - borrowerCollateralAfter,
            exactProbe.liquidatedShares,
            1000,
            "oracle-liquidation:borrower-collateral-delta"
        );
        assertApproxEqAbs(
            liquidatorCollateralAfter - liquidatorCollateralBefore,
            exactProbe.liquidatedShares,
            1000,
            "oracle-liquidation:liquidator-collateral-delta"
        );
        assertApproxEqAbs(
            liquidatorDebtAssetBefore - liquidatorDebtAssetAfter,
            exactProbe.debtRepaid,
            1000,
            "oracle-liquidation:liquidator-dai-spend"
        );
        assertApproxEqAbs(
            marketDebtBefore - marketDebtAfter,
            exactProbe.debtRepaid + exactProbe.badDebtRealized,
            1000,
            "oracle-liquidation:market-debt-delta"
        );
    }

    function scaffoldOraclePairSnapshot() internal returns (OraclePairSnapshot memory snapshot) {
        (snapshot.collateralSharesPrice, snapshot.debtUnderlyingPrice) = oracleManager.getPriceIsolatedPair(
            address(pendleStrategyCTokenSTETH),
            address(borrowableCDAI),
            2
        );
    }

    function scaffoldOracleMutationPlan() internal view returns (OracleMutationPlan memory plan) {
        plan.asset = _DAI_ADDRESS;
        plan.primaryAdaptor = address(chainlinkAdaptor);
        plan.secondaryAdaptor = address(dualChainlinkAdaptor);
        plan.replaceAdaptorSelector = OracleManager.replaceAssetPricingAdaptor.selector;
        plan.removeAdaptorSelector = OracleManager.removeAssetPricingAdaptor.selector;
    }

    function scaffoldLiquidationProbe() internal returns (LiquidationProbe memory probe) {
        return scaffoldLiquidationProbe(false, 250e18);
    }

    function _runOracleMutationBranch(uint256 targetPrice) internal returns (OracleMutationBranch memory branch) {
        OracleMutationPlan memory mutationPlan = scaffoldOracleMutationPlan();

        branch.beforeSnapshot = scaffoldOraclePairSnapshot();
        branch.beforeProbe = scaffoldLiquidationProbe();
        branch.execution = _applyDebtOracleReplacement(mutationPlan, targetPrice);
        branch.afterSnapshot = scaffoldOraclePairSnapshot();
        branch.afterProbe = scaffoldLiquidationProbe();
    }

    function scaffoldLiquidationProbe(
        bool liquidateExact,
        uint256 debtAmount
    ) internal returns (LiquidationProbe memory probe) {
        address[] memory accounts = new address[](1);
        uint256[] memory debtAmounts = new uint256[](1);
        accounts[0] = user1;
        debtAmounts[0] = debtAmount;

        IMarketManager.LiqAction memory action = IMarketManager.LiqAction({
            collateralToken: address(pendleStrategyCTokenSTETH),
            debtToken: address(borrowableCDAI),
            numAccounts: 1,
            liquidateExact: liquidateExact,
            liquidatedShares: 0,
            debtRepaid: 0,
            badDebt: 0
        });

        probe.debtAmountInput = debtAmounts[0];
        probe.debtAmountResolved = debtAmounts[0];
        probe.collateralPosted = pendleStrategyCTokenSTETH.collateralPosted(user1);
        probe.debtBalance = borrowableCDAI.debtBalance(user1);

        vm.prank(address(borrowableCDAI));
        try marketManagerIsolated.canLiquidate(debtAmounts, address(this), accounts, action) returns (
            IMarketManager.LiqResult memory result,
            uint256[] memory adjustedDebtAmounts
        ) {
            probe.liquidationAvailable = true;
            probe.liquidatedShares = result.liquidatedShares[0];
            probe.debtRepaid = result.debtRepaid;
            probe.badDebtRealized = result.badDebtRealized;

            if (adjustedDebtAmounts.length != 0) {
                probe.debtAmountResolved = adjustedDebtAmounts[0];
            }
        } catch {
            probe.liquidationAvailable = false;
        }
    }

    function _applyDebtOracleReplacement(
        OracleMutationPlan memory plan,
        uint256 targetPrice
    ) internal returns (OracleMutationExecution memory execution) {
        MockOracleAdaptor primaryMock = new MockOracleAdaptor(
            ICentralRegistry(address(centralRegistry)),
            "OracleMutationPrimary"
        );
        MockOracleAdaptor secondaryMock = new MockOracleAdaptor(
            ICentralRegistry(address(centralRegistry)),
            "OracleMutationSecondary"
        );

        oracleManager.addApprovedAdaptor(address(primaryMock));
        oracleManager.addApprovedAdaptor(address(secondaryMock));

        primaryMock.addAsset(plan.asset);
        secondaryMock.addAsset(plan.asset);

        // MockOracleAdaptor always returns `nativePrice`; setting both slots to the
        // same value keeps this test's USD path explicit and deterministic.
        primaryMock.setPrice(plan.asset, targetPrice, targetPrice);
        secondaryMock.setPrice(plan.asset, targetPrice, targetPrice);

        oracleManager.replaceAssetPricingAdaptor(
            plan.asset,
            plan.primaryAdaptor,
            address(primaryMock),
            180,
            130,
            180,
            130
        );
        oracleManager.replaceAssetPricingAdaptor(
            plan.asset,
            plan.secondaryAdaptor,
            address(secondaryMock),
            180,
            130,
            180,
            130
        );

        execution.primaryMockAdaptor = address(primaryMock);
        execution.secondaryMockAdaptor = address(secondaryMock);
        execution.configuredPrice = targetPrice;
    }

    function _setDebtOracleReplacementPrice(
        OracleMutationExecution memory execution,
        address asset,
        uint256 targetPrice
    ) internal {
        // MockOracleAdaptor returns `nativePrice` for the queried price, so
        // set both slots identically to keep the mutation explicit.
        MockOracleAdaptor(execution.primaryMockAdaptor).setPrice(asset, targetPrice, targetPrice);
        MockOracleAdaptor(execution.secondaryMockAdaptor).setPrice(asset, targetPrice, targetPrice);
    }

    function _expectLiquidationBlockedByBadSource() internal {
        address[] memory accounts = new address[](1);
        uint256[] memory debtAmounts = new uint256[](1);
        accounts[0] = user1;
        debtAmounts[0] = 250e18;

        IMarketManager.LiqAction memory action = IMarketManager.LiqAction({
            collateralToken: address(pendleStrategyCTokenSTETH),
            debtToken: address(borrowableCDAI),
            numAccounts: 1,
            liquidateExact: false,
            liquidatedShares: 0,
            debtRepaid: 0,
            badDebt: 0
        });

        vm.prank(address(borrowableCDAI));
        vm.expectRevert(OracleManager.OracleManager__ErrorCodeFlagged.selector);
        marketManagerIsolated.canLiquidate(debtAmounts, address(this), accounts, action);
    }

    function _provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareDAI(liquidityProvider, 200_000e18);
        deal(address(LP_wstETH_24Dec2025), liquidityProvider, 10e18);

        vm.startPrank(liquidityProvider);
        dai.approve(address(borrowableCDAI), 200_000e18);
        borrowableCDAI.mint(200_000e18, liquidityProvider);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 10e18);
        pendleStrategyCTokenSTETH.deposit(10e18, liquidityProvider);
        vm.stopPrank();
    }
}
