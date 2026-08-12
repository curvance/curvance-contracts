// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {TestBaseMarketIsolated} from "tests/market/TestBaseMarketIsolated.sol";
import {
    MarketManagerIsolated
} from "contracts/market/isolated/MarketManagerIsolated.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";

/// @notice Proves that a borrower whose collateral is another BorrowableCToken
/// can order an unrelated bad-debt recognition after their own liquidation so
/// the liquidator receives fewer collateral shares before those shares reprice.
contract ReciprocalBorrowableLossOrderingRegression is TestBaseMarketIsolated {
    struct BranchOutcome {
        uint256 sourceDebtRemoved;
        uint256 sourceDebtRepaid;
        uint256 sourceBadDebt;
        uint256 sourceCollateralAward;
        uint256 targetDebtRepaid;
        uint256 victimSeizedShares;
        uint256 victimTerminalAssets;
        uint256 targetRetainedShares;
        uint256 targetRetainedAssets;
        uint256 usdcTotalAssets;
        uint256 usdcTotalSupply;
        uint256 usdcCash;
        uint256 usdcDebt;
        uint256 daiTotalAssets;
        uint256 daiTotalSupply;
        uint256 daiCash;
        uint256 daiDebt;
    }

    address internal sourceBorrower = makeAddr("reciprocalSourceBorrower");
    address internal targetBorrower = makeAddr("reciprocalTargetBorrower");
    address internal victimLiquidator = makeAddr("reciprocalVictimLiquidator");
    address internal liquidityProvider =
        makeAddr("reciprocalLiquidityProvider");

    uint256 internal constant TARGET_LIQUIDATION = 1_000e18;

    function setUp() public override {
        super.setUp();

        _prepareUSDC(address(this), 77777);
        _prepareDAI(address(this), 77777);
        IERC20(_USDC_ADDRESS).approve(address(borrowableCUSDC), 77777);
        IERC20(_DAI_ADDRESS).approve(address(borrowableCDAI), 77777);
        marketManagerIsolated.listTokens(
            address(borrowableCUSDC), address(borrowableCDAI)
        );
        _setCTokenConfigBasic(
            address(borrowableCUSDC), 2_000_000e6, 2_000_000e6
        );
        _setCTokenConfigBasic(
            address(borrowableCDAI), 2_000_000e18, 2_000_000e18
        );

        _seedLiquidity();
        _openSourceLoan();

        skip(20 * 365 days);
        _refreshMockFeeds();
        borrowableCUSDC.exchangeRateUpdated();

        _openTargetLoan();

        skip(1201);
        mockDaiFeed.setMockAnswer(1e8);
        _refreshMockFeeds();

        (, uint256 sourceMaxDebt, uint256 sourceDebt) =
            marketManagerIsolated.statusOf(sourceBorrower);
        (, uint256 targetMaxDebt, uint256 targetDebt) =
            marketManagerIsolated.statusOf(targetBorrower);
        assertGt(sourceDebt, sourceMaxDebt);
        assertGt(targetDebt, targetMaxDebt);
    }

    function test_targetBorrowerBackrunTransfersTerminalLiquidationValue()
        public
    {
        uint256 snapshot = vm.snapshotState();
        BranchOutcome memory backrun = _runBranch(false);

        assertTrue(vm.revertToState(snapshot));
        BranchOutcome memory recognizeLossFirst = _runBranch(true);

        assertGt(backrun.sourceBadDebt, 0);
        assertEq(
            backrun.sourceDebtRemoved, recognizeLossFirst.sourceDebtRemoved
        );
        assertEq(backrun.sourceDebtRepaid, recognizeLossFirst.sourceDebtRepaid);
        assertEq(backrun.sourceBadDebt, recognizeLossFirst.sourceBadDebt);
        assertEq(
            backrun.sourceCollateralAward,
            recognizeLossFirst.sourceCollateralAward
        );
        assertEq(backrun.targetDebtRepaid, TARGET_LIQUIDATION);
        assertEq(recognizeLossFirst.targetDebtRepaid, TARGET_LIQUIDATION);

        assertLt(
            backrun.victimSeizedShares, recognizeLossFirst.victimSeizedShares
        );
        assertLt(
            backrun.victimTerminalAssets,
            recognizeLossFirst.victimTerminalAssets
        );
        assertGt(
            backrun.targetRetainedShares,
            recognizeLossFirst.targetRetainedShares
        );
        assertGt(
            backrun.targetRetainedAssets,
            recognizeLossFirst.targetRetainedAssets
        );

        uint256 victimLoss = recognizeLossFirst.victimTerminalAssets
            - backrun.victimTerminalAssets;
        uint256 targetGain = backrun.targetRetainedAssets
            - recognizeLossFirst.targetRetainedAssets;
        assertGt(victimLoss, 1e6);
        assertApproxEqAbs(victimLoss, targetGain, 1);

        assertApproxEqAbs(
            backrun.victimTerminalAssets + backrun.targetRetainedAssets,
            recognizeLossFirst.victimTerminalAssets
                + recognizeLossFirst.targetRetainedAssets,
            1
        );
        _assertPoolAccountingEqual(backrun, recognizeLossFirst);
    }

    function test_recognizeLossFirstLeavesNoSourceLossToBackrun() public {
        _recognizeSourceLoss();
        _liquidateTarget();

        BranchOutcome memory beforeRetry = _recordOutcome(0, 0, 0, 0);
        address[] memory accounts = new address[](1);
        accounts[0] = sourceBorrower;

        vm.startPrank(targetBorrower);
        IERC20(_USDC_ADDRESS)
            .approve(address(borrowableCUSDC), type(uint256).max);
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__NoLiquidationAvailable
            .selector
        );
        borrowableCUSDC.liquidate(accounts, address(borrowableCDAI));
        vm.stopPrank();

        BranchOutcome memory afterRetry = _recordOutcome(0, 0, 0, 0);
        assertEq(
            keccak256(abi.encode(beforeRetry)),
            keccak256(abi.encode(afterRetry))
        );
    }

    function _seedLiquidity() internal {
        _prepareUSDC(liquidityProvider, 1_000_000e6);
        _prepareDAI(liquidityProvider, 1_000_000e18);

        vm.startPrank(liquidityProvider);
        IERC20(_USDC_ADDRESS)
            .approve(address(borrowableCUSDC), type(uint256).max);
        IERC20(_DAI_ADDRESS)
            .approve(address(borrowableCDAI), type(uint256).max);
        borrowableCUSDC.deposit(1_000_000e6, liquidityProvider);
        borrowableCDAI.deposit(1_000_000e18, liquidityProvider);
        vm.stopPrank();
    }

    function _openSourceLoan() internal {
        _prepareDAI(sourceBorrower, 100_000e18);

        vm.startPrank(sourceBorrower);
        IERC20(_DAI_ADDRESS)
            .approve(address(borrowableCDAI), type(uint256).max);
        borrowableCDAI.depositAsCollateral(100_000e18, sourceBorrower);
        vm.stopPrank();

        skip(1201);
        _refreshMockFeeds();

        vm.prank(sourceBorrower);
        borrowableCUSDC.borrow(69_000e6, sourceBorrower);
    }

    function _openTargetLoan() internal {
        _prepareUSDC(targetBorrower, 20_000e6);

        vm.startPrank(targetBorrower);
        IERC20(_USDC_ADDRESS)
            .approve(address(borrowableCUSDC), type(uint256).max);
        borrowableCUSDC.depositAsCollateral(20_000e6, targetBorrower);

        IERC20(_DAI_ADDRESS)
            .approve(address(borrowableCDAI), type(uint256).max);
        vm.stopPrank();

        mockDaiFeed.setMockAnswer(9e7);
        _refreshMockFeeds();

        vm.prank(targetBorrower);
        borrowableCDAI.borrow(15_000e18, targetBorrower);

        _prepareUSDC(targetBorrower, 500_000e6);
        _prepareDAI(victimLiquidator, 10_000e18);
    }

    function _runBranch(bool recognizeLossFirst)
        internal
        returns (BranchOutcome memory outcome)
    {
        uint256 sourceDebtRemoved;
        uint256 sourceDebtRepaid;
        uint256 sourceBadDebt;
        uint256 sourceCollateralAward;

        if (recognizeLossFirst) {
            (
                sourceDebtRemoved,
                sourceDebtRepaid,
                sourceBadDebt,
                sourceCollateralAward
            ) = _recognizeSourceLoss();
            _liquidateTarget();
        } else {
            _liquidateTarget();
            (
                sourceDebtRemoved,
                sourceDebtRepaid,
                sourceBadDebt,
                sourceCollateralAward
            ) = _recognizeSourceLoss();
        }

        outcome = _recordOutcome(
            sourceDebtRemoved,
            sourceDebtRepaid,
            sourceBadDebt,
            sourceCollateralAward
        );
    }

    function _liquidateTarget() internal {
        uint256[] memory debtAmounts = new uint256[](1);
        debtAmounts[0] = TARGET_LIQUIDATION;
        address[] memory accounts = new address[](1);
        accounts[0] = targetBorrower;

        vm.startPrank(victimLiquidator);
        IERC20(_DAI_ADDRESS)
            .approve(address(borrowableCDAI), type(uint256).max);
        borrowableCDAI.liquidateExact(
            debtAmounts, accounts, address(borrowableCUSDC)
        );
        vm.stopPrank();
    }

    function _recognizeSourceLoss()
        internal
        returns (
            uint256 debtRemoved,
            uint256 debtRepaid,
            uint256 badDebt,
            uint256 collateralAward
        )
    {
        uint256 debtBefore = borrowableCUSDC.debtBalance(sourceBorrower);
        uint256 totalAssetsBefore = borrowableCUSDC.totalAssets();
        uint256 cashBefore =
            IERC20(_USDC_ADDRESS).balanceOf(address(borrowableCUSDC));
        uint256 collateralBefore = borrowableCDAI.balanceOf(targetBorrower);

        address[] memory accounts = new address[](1);
        accounts[0] = sourceBorrower;
        vm.startPrank(targetBorrower);
        IERC20(_USDC_ADDRESS)
            .approve(address(borrowableCUSDC), type(uint256).max);
        borrowableCUSDC.liquidate(accounts, address(borrowableCDAI));
        vm.stopPrank();

        uint256 debtAfter = borrowableCUSDC.debtBalance(sourceBorrower);
        debtRemoved = debtBefore - debtAfter;
        debtRepaid = IERC20(_USDC_ADDRESS).balanceOf(address(borrowableCUSDC))
            - cashBefore;
        badDebt = totalAssetsBefore - borrowableCUSDC.totalAssets();
        collateralAward =
            borrowableCDAI.balanceOf(targetBorrower) - collateralBefore;
        assertEq(debtRemoved, debtRepaid + badDebt);
    }

    function _recordOutcome(
        uint256 sourceDebtRemoved,
        uint256 sourceDebtRepaid,
        uint256 sourceBadDebt,
        uint256 sourceCollateralAward
    ) internal view returns (BranchOutcome memory outcome) {
        outcome.sourceDebtRemoved = sourceDebtRemoved;
        outcome.sourceDebtRepaid = sourceDebtRepaid;
        outcome.sourceBadDebt = sourceBadDebt;
        outcome.sourceCollateralAward = sourceCollateralAward;
        outcome.targetDebtRepaid = TARGET_LIQUIDATION;
        outcome.victimSeizedShares =
            borrowableCUSDC.balanceOf(victimLiquidator);
        outcome.victimTerminalAssets =
            borrowableCUSDC.convertToAssets(outcome.victimSeizedShares);
        outcome.targetRetainedShares =
            borrowableCUSDC.collateralPosted(targetBorrower);
        outcome.targetRetainedAssets =
            borrowableCUSDC.convertToAssets(outcome.targetRetainedShares);

        outcome.usdcTotalAssets = borrowableCUSDC.totalAssets();
        outcome.usdcTotalSupply = borrowableCUSDC.totalSupply();
        outcome.usdcCash =
            IERC20(_USDC_ADDRESS).balanceOf(address(borrowableCUSDC));
        outcome.usdcDebt = borrowableCUSDC.marketOutstandingDebt();
        outcome.daiTotalAssets = borrowableCDAI.totalAssets();
        outcome.daiTotalSupply = borrowableCDAI.totalSupply();
        outcome.daiCash =
            IERC20(_DAI_ADDRESS).balanceOf(address(borrowableCDAI));
        outcome.daiDebt = borrowableCDAI.marketOutstandingDebt();
    }

    function _assertPoolAccountingEqual(
        BranchOutcome memory a,
        BranchOutcome memory b
    ) internal pure {
        assertEq(a.usdcTotalAssets, b.usdcTotalAssets);
        assertEq(a.usdcTotalSupply, b.usdcTotalSupply);
        assertEq(a.usdcCash, b.usdcCash);
        assertEq(a.usdcDebt, b.usdcDebt);
        assertEq(a.daiTotalAssets, b.daiTotalAssets);
        assertEq(a.daiTotalSupply, b.daiTotalSupply);
        assertEq(a.daiCash, b.daiCash);
        assertEq(a.daiDebt, b.daiDebt);
    }
}
