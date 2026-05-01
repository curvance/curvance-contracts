// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { NO_ERROR } from "contracts/libraries/ConstantsLib.sol";
import { PendleLib } from "contracts/libraries/PendleLib.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { PendleLPPositionManager } from "contracts/market/position-management/PendleLPPositionManager.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IUniswapV2Router } from "contracts/interfaces/external/uniswap/IUniswapV2Router.sol";
import { IPendleRouter, LimitOrderData } from "contracts/interfaces/external/pendle/IPendleRouter.sol";
import { MockOracleAdaptor } from "contracts/mocks/MockOracleAdaptor.sol";

import { TestBaseBorrowableCToken } from "tests/market/token/BorrowableCToken/TestBaseBorrowableCToken.sol";

contract TestFlashOracleLiquidationComposition is TestBaseBorrowableCToken {
    address internal constant _PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;

    error FlashOracleLiquidation_LiquidationCheckpoint();
    error FlashOracleLiquidation_SelfFundingUnavailable(uint256 repaymentGap, uint256 borrowCapacity);
    error FlashOracleLiquidation_PendleSelfFundingUnavailable(uint256 repaymentGap, uint256 safeStEthEstimate, uint256 maxStEthInput);
    error FlashOracleLiquidation_PendleDeleverageRequiresExistingDebt();

    struct FlashLoanInvocation {
        address loanToken;
        uint256 assets;
        uint256 fee;
        bytes callbackData;
    }

    struct OraclePairSnapshot {
        uint256 collateralSharesPrice;
        uint256 debtUnderlyingPrice;
    }

    struct LiquidationProbe {
        bool liquidationAvailable;
        uint256 collateralPosted;
        uint256 debtBalance;
        uint256 liquidatedShares;
        uint256 debtRepaid;
        uint256 badDebtRealized;
        uint256 adjustedDebtAmount;
    }

    struct LiquidationExecution {
        uint256 requestedDebtAmount;
        uint256 borrowerDebtBefore;
        uint256 borrowerDebtAfter;
        uint256 borrowerCollateralBefore;
        uint256 borrowerCollateralAfter;
        uint256 liquidatorCollateralBefore;
        uint256 liquidatorCollateralAfter;
        uint256 marketDebtBefore;
        uint256 marketDebtAfter;
        uint256 collateralSeized;
        uint256 repaymentGapBeforeSelfFunding;
        uint256 collateralPostedForRepayment;
        uint256 selfFundingBorrowCapacity;
        uint256 selfFundingBorrowAmount;
        uint256 selfFundingDebtAfterBorrow;
        uint256 liquidatorUsdcBeforePendleDeleverage;
        uint256 liquidatorUsdcAfterPendleDeleverage;
        uint256 liquidatorDebtBeforePendleDeleverage;
        uint256 liquidatorDebtAfterPendleDeleverage;
        uint256 pendleDeleverageCollateralAssets;
        uint256 pendleDeleverageEstimatedStEthOut;
        uint256 pendleDeleverageSafeStEthEstimate;
        uint256 pendleDeleverageMaxStEthInput;
        uint256 pendleDeleverageUsdcProceeds;
        uint256 flashRepaymentTopUp;
    }

    struct FlashLoanTrace {
        address lender;
        uint256 assets;
        uint256 assetsReturned;
        bytes32 callbackDigest;
    }

    struct OracleMutationExecution {
        address primaryMockAdaptor;
        address secondaryMockAdaptor;
        uint256 configuredPrice;
    }

    struct CallbackObservation {
        bool oracleMutationApplied;
        bool liquidationProbeObserved;
        bool liquidationExecuted;
        OraclePairSnapshot oracleSnapshot;
        LiquidationProbe liquidationProbe;
        OracleMutationExecution oracleMutation;
        LiquidationExecution liquidationExecution;
    }

    struct BranchEconomics {
        uint256 lenderLiquidityDelta;
        uint256 debtRepaid;
        uint256 grossMonetization;
        uint256 netValueGain;
        uint256 collateralSharesPriceAfter;
        uint256 debtUnderlyingPriceAfter;
    }

    uint256 internal constant FLASHLOAN_AMOUNT = 10_000e6;

    uint256 internal flashloanFee;
    bool internal flashloanCallbackSeen;
    FlashLoanTrace internal flashloanTrace;
    CallbackObservation internal callbackObservation;
    PendleLPPositionManager internal pendleLpPositionManager;

    function setUp() public override {
        super.setUp();

        flashloanFee = FixedPointMathLib.mulDivUp(FLASHLOAN_AMOUNT, 4, 10_000);

        vm.startPrank(user1);
        _prepareUSDC(user1, FLASHLOAN_AMOUNT);
        usdc.approve(address(borrowableCUSDC), FLASHLOAN_AMOUNT);
        borrowableCUSDC.deposit(FLASHLOAN_AMOUNT, user1);
        vm.stopPrank();

        _prepareLiquidation();

        pendleLpPositionManager = new PendleLPPositionManager(
            ICentralRegistry(address(centralRegistry)),
            address(marketManagerIsolated),
            _WETH_ADDRESS,
            IPendleRouter(_PENDLE_ROUTER)
        );
        marketManagerIsolated.addPositionManager(address(pendleLpPositionManager));

        // The flash-loan entrypoint accrues pending interest on the borrowable
        // market before handing control to the callback. Settle that debt
        // baseline here so the scaffold measures flash/oracle/liquidation
        // deltas instead of first-touch interest accrual.
        borrowableCUSDC.accrueIfNeeded();
    }

    function test_flashOracleLiquidation_flashloanRoundtripScaffold() public {
        FlashLoanInvocation memory flashLoan = scaffoldFlashLoanInvocation();
        OraclePairSnapshot memory beforeSnapshot = scaffoldOraclePairSnapshot();
        LiquidationProbe memory beforeProbe = scaffoldLiquidationProbe();
        uint256 cTokenLiquidityBefore = usdc.balanceOf(address(borrowableCUSDC));

        flashloanCallbackSeen = false;
        borrowableCUSDC.flashLoan(flashLoan.assets, flashLoan.callbackData);

        OraclePairSnapshot memory afterSnapshot = scaffoldOraclePairSnapshot();
        LiquidationProbe memory afterProbe = scaffoldLiquidationProbe();
        uint256 cTokenLiquidityAfter = usdc.balanceOf(address(borrowableCUSDC));

        assertTrue(flashloanCallbackSeen, "flash-oracle-liquidation:flashloan-callback-not-seen");
        assertEq(flashloanTrace.lender, address(borrowableCUSDC), "flash-oracle-liquidation:unexpected-lender");
        assertEq(flashloanTrace.assets, flashLoan.assets, "flash-oracle-liquidation:unexpected-assets");
        assertEq(flashloanTrace.assetsReturned, flashLoan.assets + flashLoan.fee, "flash-oracle-liquidation:unexpected-assets-returned");
        assertEq(cTokenLiquidityAfter, cTokenLiquidityBefore + flashLoan.fee, "flash-oracle-liquidation:lender-fee-mismatch");
        assertEq(afterSnapshot.collateralSharesPrice, beforeSnapshot.collateralSharesPrice, "flash-oracle-liquidation:unexpected-collateral-price-change");
        assertEq(afterSnapshot.debtUnderlyingPrice, beforeSnapshot.debtUnderlyingPrice, "flash-oracle-liquidation:unexpected-debt-price-change");
        assertEq(afterProbe.liquidationAvailable, beforeProbe.liquidationAvailable, "flash-oracle-liquidation:unexpected-liquidation-state-change");
    }

    function test_flashOracleLiquidation_flashCallbackCanMutateOracleAndProbeLiquidation() public {
        FlashLoanInvocation memory flashLoan = scaffoldFlashLoanInvocation(true, 3e18);
        OraclePairSnapshot memory beforeSnapshot = scaffoldOraclePairSnapshot();
        LiquidationProbe memory beforeProbe = scaffoldLiquidationProbe();
        uint256 cTokenLiquidityBefore = usdc.balanceOf(address(borrowableCUSDC));

        flashloanCallbackSeen = false;
        delete callbackObservation;
        borrowableCUSDC.flashLoan(flashLoan.assets, flashLoan.callbackData);

        OraclePairSnapshot memory afterSnapshot = scaffoldOraclePairSnapshot();
        LiquidationProbe memory afterProbe = scaffoldLiquidationProbe();
        uint256 cTokenLiquidityAfter = usdc.balanceOf(address(borrowableCUSDC));

        assertTrue(flashloanCallbackSeen, "flash-oracle-liquidation:flashloan-callback-not-seen");
        assertEq(cTokenLiquidityAfter, cTokenLiquidityBefore + flashLoan.fee, "flash-oracle-liquidation:lender-fee-mismatch");
        assertTrue(callbackObservation.oracleMutationApplied, "flash-oracle-liquidation:oracle-mutation-not-applied");
        assertTrue(callbackObservation.liquidationProbeObserved, "flash-oracle-liquidation:liquidation-probe-not-observed");
        assertTrue(callbackObservation.oracleMutation.primaryMockAdaptor != address(0), "flash-oracle-liquidation:primary-mock-missing");
        assertTrue(callbackObservation.oracleMutation.secondaryMockAdaptor != address(0), "flash-oracle-liquidation:secondary-mock-missing");
        assertEq(callbackObservation.oracleMutation.configuredPrice, 3e18, "flash-oracle-liquidation:configured-price");
        assertEq(callbackObservation.oracleSnapshot.collateralSharesPrice, beforeSnapshot.collateralSharesPrice, "flash-oracle-liquidation:collateral-price-drift");
        assertGt(callbackObservation.oracleSnapshot.debtUnderlyingPrice, beforeSnapshot.debtUnderlyingPrice, "flash-oracle-liquidation:debt-price-did-not-increase");
        assertEq(afterSnapshot.debtUnderlyingPrice, callbackObservation.oracleSnapshot.debtUnderlyingPrice, "flash-oracle-liquidation:post-callback-price-mismatch");
        assertEq(afterSnapshot.debtUnderlyingPrice, 3e18, "flash-oracle-liquidation:unexpected-mutated-debt-price");
        assertEq(afterProbe.collateralPosted, beforeProbe.collateralPosted, "flash-oracle-liquidation:collateral-posted-drift");
        assertEq(afterProbe.debtBalance, beforeProbe.debtBalance, "flash-oracle-liquidation:debt-balance-drift");
        assertEq(afterProbe.liquidationAvailable, callbackObservation.liquidationProbe.liquidationAvailable, "flash-oracle-liquidation:liquidation-probe-mismatch");
    }

    function test_flashOracleLiquidation_flashCallbackReachesLiquidationCheckpointBeforeRepayment() public {
        FlashLoanInvocation memory flashLoan = scaffoldFlashLoanInvocation(
            true,
            3e18,
            true,
            250e6,
            true,
            false
        );

        _clearAmbientUsdcBalance();

        flashloanCallbackSeen = false;
        delete callbackObservation;
        vm.expectRevert(FlashOracleLiquidation_LiquidationCheckpoint.selector);
        borrowableCUSDC.flashLoan(flashLoan.assets, flashLoan.callbackData);
    }

    function test_flashOracleLiquidation_flashCallbackCannotSettleWithoutSwapLeg() public {
        FlashLoanInvocation memory flashLoan = scaffoldFlashLoanInvocation(
            true,
            3e18,
            true,
            250e6,
            false,
            true
        );

        _clearAmbientUsdcBalance();

        flashloanCallbackSeen = false;
        delete callbackObservation;
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        borrowableCUSDC.flashLoan(flashLoan.assets, flashLoan.callbackData);
    }

    function test_flashOracleLiquidation_flashCallbackCanExecuteLiquidation() public {
        FlashLoanInvocation memory flashLoan = scaffoldFlashLoanInvocation(
            true,
            3e18,
            true,
            250e6
        );
        _clearAmbientUsdcBalance();
        OraclePairSnapshot memory beforeSnapshot = scaffoldOraclePairSnapshot();
        uint256 borrowerDebtBefore = borrowableCUSDC.debtBalance(user1);
        uint256 borrowerCollateralBefore = pendleStrategyCTokenSTETH.balanceOf(user1);
        uint256 liquidatorCollateralBefore = pendleStrategyCTokenSTETH.balanceOf(address(this));

        flashloanCallbackSeen = false;
        delete callbackObservation;
        borrowableCUSDC.flashLoan(flashLoan.assets, flashLoan.callbackData);

        OraclePairSnapshot memory afterSnapshot = scaffoldOraclePairSnapshot();
        uint256 borrowerDebtAfter = borrowableCUSDC.debtBalance(user1);
        uint256 borrowerCollateralAfter = pendleStrategyCTokenSTETH.balanceOf(user1);
        uint256 liquidatorCollateralAfter = pendleStrategyCTokenSTETH.balanceOf(address(this));

        assertTrue(flashloanCallbackSeen, "flash-oracle-liquidation:flashloan-callback-not-seen");
        assertTrue(callbackObservation.oracleMutationApplied, "flash-oracle-liquidation:oracle-mutation-not-applied");
        assertTrue(callbackObservation.liquidationProbeObserved, "flash-oracle-liquidation:liquidation-probe-not-observed");
        assertTrue(callbackObservation.liquidationExecuted, "flash-oracle-liquidation:liquidation-not-executed");
        assertTrue(callbackObservation.liquidationProbe.liquidationAvailable, "flash-oracle-liquidation:liquidation-probe-unavailable");
        assertEq(callbackObservation.liquidationExecution.requestedDebtAmount, 250e6, "flash-oracle-liquidation:requested-debt-amount");
        assertEq(callbackObservation.liquidationExecution.borrowerDebtBefore, borrowerDebtBefore, "flash-oracle-liquidation:borrower-debt-before");
        assertEq(callbackObservation.liquidationExecution.borrowerCollateralBefore, borrowerCollateralBefore, "flash-oracle-liquidation:borrower-collateral-before");
        assertEq(callbackObservation.liquidationExecution.liquidatorCollateralBefore, liquidatorCollateralBefore, "flash-oracle-liquidation:liquidator-collateral-before");
        assertEq(callbackObservation.liquidationExecution.borrowerDebtAfter, borrowerDebtAfter, "flash-oracle-liquidation:borrower-debt-after");
        assertEq(callbackObservation.liquidationExecution.borrowerCollateralAfter, borrowerCollateralAfter, "flash-oracle-liquidation:borrower-collateral-after");
        assertEq(callbackObservation.liquidationExecution.liquidatorCollateralAfter, liquidatorCollateralAfter, "flash-oracle-liquidation:liquidator-collateral-after");
        assertGt(callbackObservation.liquidationExecution.collateralSeized, 0, "flash-oracle-liquidation:missing-collateral-seized");
        assertEq(
            callbackObservation.liquidationExecution.flashRepaymentTopUp,
            flashLoan.fee + callbackObservation.liquidationExecution.requestedDebtAmount,
            "flash-oracle-liquidation:unexpected-flash-topup"
        );
        assertApproxEqAbs(
            callbackObservation.liquidationExecution.collateralSeized,
            callbackObservation.liquidationProbe.liquidatedShares,
            1000,
            "flash-oracle-liquidation:probe-to-execution-collateral-mismatch"
        );
        assertLt(borrowerDebtAfter, borrowerDebtBefore, "flash-oracle-liquidation:borrower-debt-not-reduced");
        assertLt(borrowerCollateralAfter, borrowerCollateralBefore, "flash-oracle-liquidation:borrower-collateral-not-reduced");
        assertGt(liquidatorCollateralAfter, liquidatorCollateralBefore, "flash-oracle-liquidation:liquidator-did-not-receive-collateral");
        assertEq(afterSnapshot.collateralSharesPrice, beforeSnapshot.collateralSharesPrice, "flash-oracle-liquidation:collateral-price-drift");
        assertEq(afterSnapshot.debtUnderlyingPrice, 3e18, "flash-oracle-liquidation:unexpected-mutated-debt-price");
    }

    function test_flashOracleLiquidation_flashCallbackCannotSelfFundRepaymentWithSeizedCollateral() public {
        FlashLoanInvocation memory flashLoan = scaffoldFlashLoanInvocation(
            true,
            3e18,
            true,
            250e6,
            false,
            true,
            true,
            false
        );
        _clearAmbientUsdcBalance();

        flashloanCallbackSeen = false;
        delete callbackObservation;
        vm.expectRevert(
            abi.encodeWithSelector(
                FlashOracleLiquidation_SelfFundingUnavailable.selector,
                254e6,
                0
            )
        );
        borrowableCUSDC.flashLoan(flashLoan.assets, flashLoan.callbackData);
    }

    function test_flashOracleLiquidation_flashCallbackCannotMonetizeSeizedCollateralViaPendleDeleverageWithoutExistingDebt() public {
        FlashLoanInvocation memory flashLoan = scaffoldFlashLoanInvocation(
            true,
            3e18,
            true,
            250e6,
            false,
            false,
            false,
            true
        );
        _clearAmbientUsdcBalance();

        flashloanCallbackSeen = false;
        delete callbackObservation;
        vm.expectRevert(
            FlashOracleLiquidation_PendleDeleverageRequiresExistingDebt.selector
        );
        borrowableCUSDC.flashLoan(flashLoan.assets, flashLoan.callbackData);
    }

    function test_flashOracleLiquidation_flashCallbackCanMonetizeSeizedCollateralViaPendleDeleverageWithExistingDustDebt() public {
        _prepareLiquidatorDustDebtState(0.5e18, 10e6);

        FlashLoanInvocation memory flashLoan = scaffoldFlashLoanInvocation(
            true,
            3e18,
            true,
            250e6,
            false,
            true,
            false,
            true
        );
        OraclePairSnapshot memory beforeSnapshot = scaffoldOraclePairSnapshot();
        uint256 liquidatorDebtBefore = borrowableCUSDC.debtBalance(address(this));
        uint256 cTokenLiquidityBefore = usdc.balanceOf(address(borrowableCUSDC));

        _clearAmbientUsdcBalance();

        flashloanCallbackSeen = false;
        delete callbackObservation;
        borrowableCUSDC.flashLoan(flashLoan.assets, flashLoan.callbackData);

        assertTrue(flashloanCallbackSeen, "flash-oracle-liquidation:flashloan-callback-not-seen");
        assertTrue(callbackObservation.oracleMutationApplied, "flash-oracle-liquidation:oracle-mutation-not-applied");
        assertTrue(callbackObservation.liquidationExecuted, "flash-oracle-liquidation:liquidation-not-executed");
        assertGt(liquidatorDebtBefore, 0, "flash-oracle-liquidation:missing-liquidator-debt");
        assertEq(
            callbackObservation.liquidationExecution.liquidatorDebtBeforePendleDeleverage,
            liquidatorDebtBefore,
            "flash-oracle-liquidation:unexpected-liquidator-debt-before-deleverage"
        );
        assertEq(
            callbackObservation.liquidationExecution.flashRepaymentTopUp,
            0,
            "flash-oracle-liquidation:unexpected-helper-topup"
        );
        assertGt(
            callbackObservation.liquidationExecution.pendleDeleverageUsdcProceeds,
            0,
            "flash-oracle-liquidation:missing-pendle-usdc-proceeds"
        );
        assertGe(
            callbackObservation.liquidationExecution.pendleDeleverageUsdcProceeds,
            callbackObservation.liquidationExecution.repaymentGapBeforeSelfFunding,
            "flash-oracle-liquidation:pendle-proceeds-below-repayment-gap"
        );
        _assertPreExistingDebtPendleBranchAccounting(
            flashLoan,
            liquidatorDebtBefore,
            cTokenLiquidityBefore
        );
        _assertPreExistingDebtPendleOracleAftermath(beforeSnapshot);
    }

    function test_flashOracleLiquidation_flashWrapperOnlyAddsFeeOverDirectPendleLiquidation() public {
        _prepareLiquidatorDustDebtState(0.5e18, 10e6);

        FlashLoanInvocation memory flashLoan = scaffoldFlashLoanInvocation(
            true,
            3e18,
            true,
            250e6,
            false,
            true,
            false,
            true
        );

        uint256 baselineSnapshot = vm.snapshotState();

        BranchEconomics memory flashBranch = _runFlashPendleBranch(flashLoan);

        assertTrue(vm.revertToState(baselineSnapshot), "flash-oracle-liquidation:failed-to-revert-baseline-snapshot");

        BranchEconomics memory directBranch = _runDirectPendleBranch(3e18, 250e6);

        assertEq(
            flashBranch.grossMonetization,
            directBranch.grossMonetization,
            "flash-oracle-liquidation:unexpected-gross-monetization-drift"
        );
        assertEq(
            flashBranch.debtRepaid,
            directBranch.debtRepaid,
            "flash-oracle-liquidation:unexpected-debt-repayment-drift"
        );
        assertEq(
            flashBranch.collateralSharesPriceAfter,
            directBranch.collateralSharesPriceAfter,
            "flash-oracle-liquidation:unexpected-collateral-price-drift-between-branches"
        );
        assertEq(
            flashBranch.debtUnderlyingPriceAfter,
            directBranch.debtUnderlyingPriceAfter,
            "flash-oracle-liquidation:unexpected-debt-price-drift-between-branches"
        );
        assertEq(
            flashBranch.lenderLiquidityDelta,
            directBranch.lenderLiquidityDelta + flashLoan.fee,
            "flash-oracle-liquidation:flash-wrapper-added-more-than-fee"
        );
        assertEq(
            flashBranch.netValueGain + flashLoan.fee,
            directBranch.netValueGain,
            "flash-oracle-liquidation:flash-wrapper-changed-net-economics"
        );
    }

    function scaffoldFlashLoanInvocation() internal view returns (FlashLoanInvocation memory invocation) {
        return scaffoldFlashLoanInvocation(false, 0, false, 0, false, false);
    }

    function scaffoldFlashLoanInvocation(
        bool mutateOracle,
        uint256 targetDebtPrice
    ) internal view returns (FlashLoanInvocation memory invocation) {
        return scaffoldFlashLoanInvocation(mutateOracle, targetDebtPrice, false, 0, false, false);
    }

    function scaffoldFlashLoanInvocation(
        bool mutateOracle,
        uint256 targetDebtPrice,
        bool executeLiquidation,
        uint256 liquidationDebtAmount
    ) internal view returns (FlashLoanInvocation memory invocation) {
        return scaffoldFlashLoanInvocation(
            mutateOracle,
            targetDebtPrice,
            executeLiquidation,
            liquidationDebtAmount,
            false,
            false
        );
    }

    function scaffoldFlashLoanInvocation(
        bool mutateOracle,
        uint256 targetDebtPrice,
        bool executeLiquidation,
        uint256 liquidationDebtAmount,
        bool checkpointAfterLiquidation,
        bool skipRepaymentTopUp
    ) internal view returns (FlashLoanInvocation memory invocation) {
        return scaffoldFlashLoanInvocation(
            mutateOracle,
            targetDebtPrice,
            executeLiquidation,
            liquidationDebtAmount,
            checkpointAfterLiquidation,
            skipRepaymentTopUp,
            false
        );
    }

    function scaffoldFlashLoanInvocation(
        bool mutateOracle,
        uint256 targetDebtPrice,
        bool executeLiquidation,
        uint256 liquidationDebtAmount,
        bool checkpointAfterLiquidation,
        bool skipRepaymentTopUp,
        bool selfFundRepaymentWithSeizedCollateral
    ) internal view returns (FlashLoanInvocation memory invocation) {
        return scaffoldFlashLoanInvocation(
            mutateOracle,
            targetDebtPrice,
            executeLiquidation,
            liquidationDebtAmount,
            checkpointAfterLiquidation,
            skipRepaymentTopUp,
            selfFundRepaymentWithSeizedCollateral,
            false
        );
    }

    function scaffoldFlashLoanInvocation(
        bool mutateOracle,
        uint256 targetDebtPrice,
        bool executeLiquidation,
        uint256 liquidationDebtAmount,
        bool checkpointAfterLiquidation,
        bool skipRepaymentTopUp,
        bool selfFundRepaymentWithSeizedCollateral,
        bool monetizeSeizedCollateralViaPendleDeleverage
    ) internal view returns (FlashLoanInvocation memory invocation) {
        invocation.loanToken = address(borrowableCUSDC);
        invocation.assets = FLASHLOAN_AMOUNT;
        invocation.fee = flashloanFee;
        invocation.callbackData = abi.encode(
            mutateOracle,
            targetDebtPrice,
            executeLiquidation,
            liquidationDebtAmount,
            checkpointAfterLiquidation,
            skipRepaymentTopUp,
            selfFundRepaymentWithSeizedCollateral,
            monetizeSeizedCollateralViaPendleDeleverage
        );
    }

    function scaffoldOraclePairSnapshot() internal returns (OraclePairSnapshot memory snapshot) {
        (snapshot.collateralSharesPrice, snapshot.debtUnderlyingPrice) = oracleManager.getPriceIsolatedPair(
            address(pendleStrategyCTokenSTETH),
            address(borrowableCUSDC),
            2
        );
    }

    function scaffoldLiquidationProbe() internal returns (LiquidationProbe memory probe) {
        return scaffoldLiquidationProbe(false, 250e6);
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
            debtToken: address(borrowableCUSDC),
            numAccounts: 1,
            liquidateExact: liquidateExact,
            liquidatedShares: 0,
            debtRepaid: 0,
            badDebt: 0
        });

        probe.collateralPosted = pendleStrategyCTokenSTETH.collateralPosted(user1);
        probe.debtBalance = borrowableCUSDC.debtBalance(user1);

        vm.prank(address(borrowableCUSDC));
        try marketManagerIsolated.canLiquidate(debtAmounts, address(this), accounts, action) returns (
            IMarketManager.LiqResult memory result,
            uint256[] memory adjustedDebtAmounts
        ) {
            probe.liquidationAvailable = true;
            probe.liquidatedShares = result.liquidatedShares[0];
            probe.debtRepaid = result.debtRepaid;
            probe.badDebtRealized = result.badDebtRealized;
            probe.adjustedDebtAmount = adjustedDebtAmounts[0];
        } catch {
            probe.liquidationAvailable = false;
        }
    }

    function onFlashLoan(uint256 assets, uint256 assetsReturned, bytes calldata data) external returns (bytes32) {
        (
            bool mutateOracle,
            uint256 targetDebtPrice,
            bool executeLiquidation,
            uint256 liquidationDebtAmount,
            bool checkpointAfterLiquidation,
            bool skipRepaymentTopUp,
            bool selfFundRepaymentWithSeizedCollateral,
            bool monetizeSeizedCollateralViaPendleDeleverage
        ) = abi.decode(data, (bool, uint256, bool, uint256, bool, bool, bool, bool));

        flashloanCallbackSeen = true;
        flashloanTrace = FlashLoanTrace({
            lender: msg.sender,
            assets: assets,
            assetsReturned: assetsReturned,
            callbackDigest: keccak256(data)
        });

        if (mutateOracle) {
            callbackObservation.oracleMutation = _applyDebtOracleReplacement(targetDebtPrice);
            callbackObservation.oracleMutationApplied = true;
            callbackObservation.oracleSnapshot = scaffoldOraclePairSnapshot();
            if (executeLiquidation) {
                callbackObservation.liquidationProbe = scaffoldLiquidationProbe(true, liquidationDebtAmount);
            } else {
                callbackObservation.liquidationProbe = scaffoldLiquidationProbe();
            }
            callbackObservation.liquidationProbeObserved = true;
        }

        if (executeLiquidation) {
            callbackObservation.liquidationExecution = _executeFlashLiquidation(liquidationDebtAmount);
            callbackObservation.liquidationExecuted = true;
        }

        if (checkpointAfterLiquidation) {
            revert FlashOracleLiquidation_LiquidationCheckpoint();
        }

        if (executeLiquidation && selfFundRepaymentWithSeizedCollateral) {
            _selfFundFlashRepaymentWithSeizedCollateral(assetsReturned);
        }

        if (executeLiquidation && monetizeSeizedCollateralViaPendleDeleverage) {
            _selfFundFlashRepaymentViaPendleDeleverage(assetsReturned);
        }

        uint256 repaymentTopUp;
        if (skipRepaymentTopUp) {
            usdc.approve(address(borrowableCUSDC), assetsReturned);
        } else {
            repaymentTopUp = _topUpFlashRepayment(assetsReturned);
            if (executeLiquidation) {
                callbackObservation.liquidationExecution.flashRepaymentTopUp = repaymentTopUp;
            }
        }

        return bytes32(0);
    }

    function _applyDebtOracleReplacement(
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

        primaryMock.addAsset(_USDC_ADDRESS);
        secondaryMock.addAsset(_USDC_ADDRESS);

        // MockOracleAdaptor returns `nativePrice` for the queried price, so
        // set both slots identically to keep the mutation explicit.
        primaryMock.setPrice(_USDC_ADDRESS, targetPrice, targetPrice);
        secondaryMock.setPrice(_USDC_ADDRESS, targetPrice, targetPrice);

        oracleManager.replaceAssetPricingAdaptor(
            _USDC_ADDRESS,
            address(chainlinkAdaptor),
            address(primaryMock),
            180,
            130,
            180,
            130
        );
        oracleManager.replaceAssetPricingAdaptor(
            _USDC_ADDRESS,
            address(dualChainlinkAdaptor),
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

    function _executeFlashLiquidation(
        uint256 debtAmount
    ) internal returns (LiquidationExecution memory execution) {
        address[] memory accounts = new address[](1);
        uint256[] memory debtAmounts = new uint256[](1);
        accounts[0] = user1;
        debtAmounts[0] = debtAmount;

        execution.requestedDebtAmount = debtAmount;
        execution.borrowerDebtBefore = borrowableCUSDC.debtBalance(user1);
        execution.borrowerCollateralBefore = pendleStrategyCTokenSTETH.balanceOf(user1);
        execution.liquidatorCollateralBefore = pendleStrategyCTokenSTETH.balanceOf(address(this));
        execution.marketDebtBefore = borrowableCUSDC.marketOutstandingDebt();

        usdc.approve(address(borrowableCUSDC), debtAmount);
        borrowableCUSDC.liquidateExact(
            debtAmounts,
            accounts,
            address(pendleStrategyCTokenSTETH)
        );

        execution.borrowerDebtAfter = borrowableCUSDC.debtBalance(user1);
        execution.borrowerCollateralAfter = pendleStrategyCTokenSTETH.balanceOf(user1);
        execution.liquidatorCollateralAfter = pendleStrategyCTokenSTETH.balanceOf(address(this));
        execution.marketDebtAfter = borrowableCUSDC.marketOutstandingDebt();
        execution.collateralSeized =
            execution.liquidatorCollateralAfter - execution.liquidatorCollateralBefore;
    }

    function _selfFundFlashRepaymentWithSeizedCollateral(uint256 assetsReturned) internal {
        uint256 currentBalance = usdc.balanceOf(address(this));
        if (currentBalance >= assetsReturned) {
            return;
        }

        uint256 repaymentGap = assetsReturned - currentBalance;
        uint256 collateralPostedBefore = pendleStrategyCTokenSTETH.collateralPosted(address(this));
        uint256 seizedShares = callbackObservation.liquidationExecution.collateralSeized;

        callbackObservation.liquidationExecution.repaymentGapBeforeSelfFunding = repaymentGap;

        pendleStrategyCTokenSTETH.postCollateral(seizedShares);

        callbackObservation.liquidationExecution.collateralPostedForRepayment =
            pendleStrategyCTokenSTETH.collateralPosted(address(this)) - collateralPostedBefore;

        uint256 borrowCapacity = _maxCautionBorrowCapacity(repaymentGap);
        callbackObservation.liquidationExecution.selfFundingBorrowCapacity = borrowCapacity;

        if (borrowCapacity < repaymentGap) {
            revert FlashOracleLiquidation_SelfFundingUnavailable(repaymentGap, borrowCapacity);
        }

        borrowableCUSDC.borrow(repaymentGap, address(this));

        callbackObservation.liquidationExecution.selfFundingBorrowAmount = repaymentGap;
        callbackObservation.liquidationExecution.selfFundingDebtAfterBorrow = borrowableCUSDC.debtBalance(address(this));
    }

    function _selfFundFlashRepaymentViaPendleDeleverage(uint256 assetsReturned) internal {
        uint256 liquidatorDebtBefore = borrowableCUSDC.debtBalance(address(this));
        if (liquidatorDebtBefore == 0) {
            revert FlashOracleLiquidation_PendleDeleverageRequiresExistingDebt();
        }

        uint256 currentBalance = usdc.balanceOf(address(this));
        if (currentBalance >= assetsReturned) {
            return;
        }

        uint256 repaymentGap = assetsReturned - currentBalance;
        uint256 collateralShares = callbackObservation.liquidationExecution.collateralSeized;
        uint256 collateralAssets = pendleStrategyCTokenSTETH.convertToAssets(collateralShares);
        uint256 estimatedStEthOut = _estimatePendleLpExitInStEth(collateralAssets);
        uint256 safeStEthEstimate = FixedPointMathLib.mulDiv(estimatedStEthOut, 95, 100);
        uint256 quotedUsdcOut = _quotedUsdcOutFromStEthInput(safeStEthEstimate);

        callbackObservation.liquidationExecution.repaymentGapBeforeSelfFunding = repaymentGap;
        callbackObservation.liquidationExecution.pendleDeleverageCollateralAssets = collateralAssets;
        callbackObservation.liquidationExecution.pendleDeleverageEstimatedStEthOut = estimatedStEthOut;
        callbackObservation.liquidationExecution.pendleDeleverageSafeStEthEstimate = safeStEthEstimate;
        callbackObservation.liquidationExecution.pendleDeleverageMaxStEthInput = safeStEthEstimate;
        callbackObservation.liquidationExecution.liquidatorUsdcBeforePendleDeleverage = currentBalance;
        callbackObservation.liquidationExecution.liquidatorDebtBeforePendleDeleverage = liquidatorDebtBefore;

        if (quotedUsdcOut < repaymentGap) {
            revert FlashOracleLiquidation_PendleSelfFundingUnavailable(
                repaymentGap,
                safeStEthEstimate,
                safeStEthEstimate
            );
        }

        PendleLPPositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(pendleStrategyCTokenSTETH));
        deleverageAction.collateralAssets = collateralAssets;
        deleverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCUSDC));
        deleverageAction.repayAssets = 1;
        deleverageAction.swapActions = new SwapperLib.Swap[](1);
        deleverageAction.swapActions[0].inputToken = _STETH_ADDRESS;
        deleverageAction.swapActions[0].inputAmount = safeStEthEstimate;
        deleverageAction.swapActions[0].outputToken = _USDC_ADDRESS;
        deleverageAction.swapActions[0].target = _UNISWAP_V2_ROUTER;
        deleverageAction.swapActions[0].slippage = 0.2e18;
        deleverageAction.swapActions[0].call = abi.encodeWithSignature(
            "swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256,uint256,address[],address,uint256)",
            safeStEthEstimate,
            0,
            _stEthToUsdcPath(),
            address(pendleLpPositionManager),
            block.timestamp
        );

        PendleLib.PendleAction memory pendleAction;
        deleverageAction.auxData = abi.encode(0, pendleAction);

        pendleStrategyCTokenSTETH.approve(address(pendleLpPositionManager), collateralShares);

        pendleLpPositionManager.deleverage(deleverageAction, 0.05e18);

        callbackObservation.liquidationExecution.liquidatorUsdcAfterPendleDeleverage =
            usdc.balanceOf(address(this));
        callbackObservation.liquidationExecution.liquidatorDebtAfterPendleDeleverage =
            borrowableCUSDC.debtBalance(address(this));
        callbackObservation.liquidationExecution.pendleDeleverageUsdcProceeds =
            callbackObservation.liquidationExecution.liquidatorUsdcAfterPendleDeleverage - currentBalance;
    }

    function _prepareLiquidatorDustDebtState(uint256 collateralShares, uint256 borrowAmount) internal {
        pendleStrategyCTokenSTETH.postCollateral(collateralShares);
        borrowableCUSDC.borrow(borrowAmount, address(this));

        _clearAmbientUsdcBalance();

        skip(20 minutes);
        borrowableCUSDC.accrueIfNeeded();
    }

    function _maxCautionBorrowCapacity(uint256 upperBound) internal returns (uint256 borrowCapacity) {
        uint256 low;
        uint256 high = upperBound;

        while (low < high) {
            uint256 mid = (low + high + 1) / 2;

            vm.prank(address(borrowableCUSDC));
            try marketManagerIsolated.canBorrow(
                address(borrowableCUSDC),
                mid,
                address(this),
                borrowableCUSDC.marketOutstandingDebt() + mid
            ) {
                low = mid;
            } catch {
                high = mid - 1;
            }
        }

        borrowCapacity = low;
    }

    function _estimatePendleLpExitInStEth(uint256 collateralAssets) internal returns (uint256 estimatedStEthOut) {
        (uint256 lpTokenPrice, uint256 lpErrorCode) = oracleManager.getPrice(
            address(LP_wstETH_24Dec2025),
            true,
            true
        );
        (uint256 stEthPrice, uint256 stEthErrorCode) = oracleManager.getPrice(
            _STETH_ADDRESS,
            true,
            true
        );

        require(lpErrorCode == NO_ERROR, "flash-oracle-liquidation:lp-price-error");
        require(stEthErrorCode == NO_ERROR, "flash-oracle-liquidation:steth-price-error");

        estimatedStEthOut = FixedPointMathLib.mulDiv(
            collateralAssets,
            lpTokenPrice,
            stEthPrice
        );
    }

    function _quotedUsdcOutFromStEthInput(uint256 stEthInput) internal view returns (uint256) {
        uint256[] memory amountsOut = IUniswapV2Router(_UNISWAP_V2_ROUTER).getAmountsOut(
            stEthInput,
            _stEthToUsdcPath()
        );
        return amountsOut[amountsOut.length - 1];
    }

    function _assertPreExistingDebtPendleBranchAccounting(
        FlashLoanInvocation memory flashLoan,
        uint256 liquidatorDebtBefore,
        uint256 cTokenLiquidityBefore
    ) internal {
        uint256 liquidatorDebtAfter = borrowableCUSDC.debtBalance(address(this));
        uint256 liquidatorUsdcAfterFlash = usdc.balanceOf(address(this));
        uint256 cTokenLiquidityAfter = usdc.balanceOf(address(borrowableCUSDC));
        uint256 liquidatorDebtRepaid = liquidatorDebtBefore - liquidatorDebtAfter;
        uint256 postSettlementNetValueGain =
            liquidatorUsdcAfterFlash + liquidatorDebtRepaid;

        assertLt(liquidatorDebtAfter, liquidatorDebtBefore, "flash-oracle-liquidation:liquidator-debt-not-reduced");
        assertEq(
            callbackObservation.liquidationExecution.liquidatorDebtAfterPendleDeleverage,
            liquidatorDebtAfter,
            "flash-oracle-liquidation:unexpected-liquidator-debt-after-deleverage"
        );
        assertEq(
            cTokenLiquidityAfter - cTokenLiquidityBefore,
            flashLoan.fee +
                callbackObservation.liquidationExecution.requestedDebtAmount +
                liquidatorDebtRepaid,
            "flash-oracle-liquidation:unexpected-lender-liquidity-delta"
        );
        assertEq(
            callbackObservation.liquidationExecution.repaymentGapBeforeSelfFunding,
            callbackObservation.liquidationExecution.requestedDebtAmount + flashLoan.fee,
            "flash-oracle-liquidation:unexpected-repayment-gap"
        );
        assertEq(
            liquidatorUsdcAfterFlash,
            callbackObservation.liquidationExecution.liquidatorUsdcAfterPendleDeleverage -
                (flashLoan.assets + flashLoan.fee),
            "flash-oracle-liquidation:unexpected-post-flash-usdc"
        );
        assertGt(liquidatorUsdcAfterFlash, 0, "flash-oracle-liquidation:no-post-flash-usdc-profit");
        assertEq(
            postSettlementNetValueGain,
            callbackObservation.liquidationExecution.pendleDeleverageUsdcProceeds +
                liquidatorDebtRepaid -
                callbackObservation.liquidationExecution.requestedDebtAmount -
                flashLoan.fee,
            "flash-oracle-liquidation:unexpected-post-settlement-net-value"
        );
        assertGt(postSettlementNetValueGain, 0, "flash-oracle-liquidation:no-post-settlement-net-value");
        assertGe(
            callbackObservation.liquidationExecution.liquidatorUsdcAfterPendleDeleverage,
            flashLoan.assets + flashLoan.fee,
            "flash-oracle-liquidation:deleverage-did-not-restore-flash-balance"
        );
    }

    function _assertPreExistingDebtPendleOracleAftermath(
        OraclePairSnapshot memory beforeSnapshot
    ) internal {
        OraclePairSnapshot memory afterSnapshot = scaffoldOraclePairSnapshot();
        assertGt(
            afterSnapshot.collateralSharesPrice,
            beforeSnapshot.collateralSharesPrice,
            "flash-oracle-liquidation:collateral-price-did-not-rise"
        );
        assertEq(afterSnapshot.debtUnderlyingPrice, 3e18, "flash-oracle-liquidation:unexpected-mutated-debt-price");
    }

    function _runFlashPendleBranch(
        FlashLoanInvocation memory flashLoan
    ) internal returns (BranchEconomics memory economics) {
        uint256 liquidatorDebtBefore = borrowableCUSDC.debtBalance(address(this));
        uint256 cTokenLiquidityBefore = usdc.balanceOf(address(borrowableCUSDC));

        _clearAmbientUsdcBalance();

        flashloanCallbackSeen = false;
        delete callbackObservation;
        borrowableCUSDC.flashLoan(flashLoan.assets, flashLoan.callbackData);

        uint256 liquidatorDebtRepaid = liquidatorDebtBefore - borrowableCUSDC.debtBalance(address(this));
        OraclePairSnapshot memory afterSnapshot = scaffoldOraclePairSnapshot();

        economics.lenderLiquidityDelta = usdc.balanceOf(address(borrowableCUSDC)) - cTokenLiquidityBefore;
        economics.debtRepaid = liquidatorDebtRepaid;
        economics.grossMonetization =
            callbackObservation.liquidationExecution.pendleDeleverageUsdcProceeds + liquidatorDebtRepaid;
        economics.netValueGain = usdc.balanceOf(address(this)) + liquidatorDebtRepaid;
        economics.collateralSharesPriceAfter = afterSnapshot.collateralSharesPrice;
        economics.debtUnderlyingPriceAfter = afterSnapshot.debtUnderlyingPrice;
    }

    function _runDirectPendleBranch(
        uint256 targetDebtPrice,
        uint256 debtAmount
    ) internal returns (BranchEconomics memory economics) {
        _clearAmbientUsdcBalance();
        _prepareUSDC(address(this), debtAmount);

        uint256 liquidatorDebtBefore = borrowableCUSDC.debtBalance(address(this));
        uint256 cTokenLiquidityBefore = usdc.balanceOf(address(borrowableCUSDC));

        delete callbackObservation;
        callbackObservation.oracleMutation = _applyDebtOracleReplacement(targetDebtPrice);
        callbackObservation.oracleMutationApplied = true;
        callbackObservation.oracleSnapshot = scaffoldOraclePairSnapshot();
        callbackObservation.liquidationExecution = _executeFlashLiquidation(debtAmount);
        callbackObservation.liquidationExecuted = true;
        _selfFundFlashRepaymentViaPendleDeleverage(debtAmount);

        uint256 liquidatorDebtRepaid = liquidatorDebtBefore - borrowableCUSDC.debtBalance(address(this));
        OraclePairSnapshot memory afterSnapshot = scaffoldOraclePairSnapshot();

        economics.lenderLiquidityDelta = usdc.balanceOf(address(borrowableCUSDC)) - cTokenLiquidityBefore;
        economics.debtRepaid = liquidatorDebtRepaid;
        economics.grossMonetization =
            callbackObservation.liquidationExecution.pendleDeleverageUsdcProceeds + liquidatorDebtRepaid;
        economics.netValueGain = usdc.balanceOf(address(this)) + liquidatorDebtRepaid - debtAmount;
        economics.collateralSharesPriceAfter = afterSnapshot.collateralSharesPrice;
        economics.debtUnderlyingPriceAfter = afterSnapshot.debtUnderlyingPrice;
    }

    function _stEthToUsdcPath() internal view returns (address[] memory path) {
        path = new address[](3);
        path[0] = _STETH_ADDRESS;
        path[1] = _WETH_ADDRESS;
        path[2] = _USDC_ADDRESS;
    }

    function _topUpFlashRepayment(uint256 assetsReturned) internal returns (uint256 repaymentTopUp) {
        uint256 currentBalance = usdc.balanceOf(address(this));
        if (currentBalance < assetsReturned) {
            repaymentTopUp = assetsReturned - currentBalance;
            // This explicit top-up marks the missing collateral->debt swap leg
            // instead of hiding it behind a full repayment mint. `_prepareUSDC`
            // sets an absolute balance, so restore the exact repayment balance
            // rather than clobbering the borrowed funds already held.
            _prepareUSDC(address(this), currentBalance + repaymentTopUp);
        }

        usdc.approve(address(borrowableCUSDC), assetsReturned);
    }

    function _clearAmbientUsdcBalance() internal {
        uint256 ambientUsdcBalance = usdc.balanceOf(address(this));
        if (ambientUsdcBalance != 0) {
            usdc.transfer(makeAddr("flashOracleLiquidationBalanceSink"), ambientUsdcBalance);
        }
    }
}
