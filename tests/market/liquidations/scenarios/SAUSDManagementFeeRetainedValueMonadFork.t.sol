// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {BorrowableCToken} from "contracts/market/token/BorrowableCToken.sol";
import {
    MarketManagerIsolated
} from "contracts/market/isolated/MarketManagerIsolated.sol";
import {OracleManager} from "contracts/oracles/OracleManager.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";

interface IManagedUpshiftVault is IERC20 {
    function asset() external view returns (address);

    function totalAssets() external view returns (uint256);

    function convertToAssets(uint256 shares)
        external
        view
        returns (uint256 assets);

    function requestRedeem(
        uint256 shares,
        address receiverAddr,
        address holderAddr
    ) external returns (uint256 assets, uint256 claimableEpoch);

    function chargeManagementFee() external;

    function totalCollectableFees() external view returns (uint256);

    function feesTimestamp() external view returns (uint256);

    function managementFeePercent() external view returns (uint256);

    function feesCollector() external view returns (address);

    function operator() external view returns (address);

    function owner() external view returns (address);

    function lagDuration() external view returns (uint256);
}

/// @notice Pinned production-fork proof that permissionless realization of a
///         long-accrued sAUSD management fee can leave Curvance's retained
///         nominal valuation healthy while exact vault NAV is deficient.
contract SAUSDManagementFeeRetainedValueMonadFork is Test {
    uint256 internal constant FORK_BLOCK = 88_492_422;

    address internal constant CSAUSD =
        0x84C5aF20b58818631164Bb7d798E457fcFACD9Ac;
    address internal constant CAUSD =
        0xfD493ce1A0ae986e09d17004B7E748817a47d73c;
    address internal constant SAUSD =
        0xD793c04B87386A6bb84ee61D98e0065FdE7fdA5E;
    address internal constant AUSD =
        0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    address internal constant MARKET_MANAGER =
        0xBBE7A3c45aDBb16F6490767b663428c34aA341Eb;
    address internal constant ORACLE_MANAGER =
        0x65ADF8aE8420A58278De066593E6fF1713A137c5;
    address internal constant CHAINLINK_ADAPTOR =
        0x42B318abFDE82a43B3685eB65a5863B9367B22e1;
    address internal constant BORROWER =
        0x58D249A203489D1Cbb991a4558166Baacb4f1bbF;

    uint256 internal constant REDEEM_SHARES = 1.955e6;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant COLLATERAL_RATIO = 9_500;
    uint256 internal constant EXPECTED_FEE = 9.258978e6;
    uint256 internal constant EXPECTED_NO_FEE_EXIT = 1.965308e6;
    uint256 internal constant EXPECTED_CHARGED_EXIT = 1.939457e6;
    uint256 internal constant EXPECTED_REMAINING_SHARES = 10.743897e6;
    uint256 internal constant EXPECTED_NO_FEE_EXACT_COLLATERAL = 10.800549e6;
    uint256 internal constant EXPECTED_CHARGED_EXACT_COLLATERAL = 10.658479e6;
    uint256 internal constant EXPECTED_NO_FEE_EXACT_MAX_DEBT = 10.260521e6;
    uint256 internal constant EXPECTED_CHARGED_EXACT_MAX_DEBT = 10.125555e6;
    uint256 internal constant EXPECTED_DEBT_AUSD = 10.259062e6;
    uint256 internal constant EXPECTED_NOMINAL_COLLATERAL =
        10.798561958816484979e18;
    uint256 internal constant EXPECTED_NOMINAL_MAX_DEBT =
        10.25863386087566073e18;
    uint256 internal constant EXPECTED_NOMINAL_DEBT = 10.258171121069056516e18;
    uint256 internal constant EXPECTED_ORACLE_PRICE = 1.005088001012713076e18;

    BorrowableCToken internal constant cSAUSD = BorrowableCToken(CSAUSD);
    BorrowableCToken internal constant cAUSD = BorrowableCToken(CAUSD);
    MarketManagerIsolated internal constant marketManager =
        MarketManagerIsolated(MARKET_MANAGER);
    OracleManager internal constant oracleManager =
        OracleManager(ORACLE_MANAGER);
    IManagedUpshiftVault internal constant sAUSD = IManagedUpshiftVault(SAUSD);
    IERC20 internal constant ausd = IERC20(AUSD);

    address internal feeCaller;
    address internal liquidator;

    struct Outcome {
        uint256 feeCharged;
        uint256 redeemedSAUSD;
        uint256 realizedAUSD;
        uint256 remainingCTokenShares;
        uint256 remainingSAUSD;
        uint256 exactCollateralAUSD;
        uint256 exactMaxDebtAUSD;
        uint256 debtAUSD;
        uint256 nominalCollateralUSD;
        uint256 nominalMaxDebtUSD;
        uint256 nominalDebtUSD;
        uint256 oraclePrice;
    }

    function setUp() public {
        vm.createSelectFork(
            vm.envString("MON_NODE_URI_MONAD_ARCHIVE"), FORK_BLOCK
        );

        feeCaller = makeAddr("permissionless-fee-caller");
        liquidator = makeAddr("unfunded-liquidator");

        assertEq(block.number, FORK_BLOCK, "wrong fork block");
        assertEq(cSAUSD.asset(), SAUSD, "wrong csAUSD underlying");
        assertEq(cAUSD.asset(), AUSD, "wrong cAUSD underlying");
        assertEq(
            address(cSAUSD.marketManager()),
            MARKET_MANAGER,
            "wrong csAUSD manager"
        );
        assertEq(
            address(cAUSD.marketManager()),
            MARKET_MANAGER,
            "wrong cAUSD manager"
        );
        assertEq(sAUSD.asset(), AUSD, "wrong sAUSD asset");
        assertEq(oracleManager.cTokens(CSAUSD), SAUSD, "wrong oracle mapping");

        address[] memory adaptors = oracleManager.getPricingAdaptors(SAUSD);
        assertEq(adaptors.length, 1, "unexpected sAUSD route count");
        assertEq(adaptors[0], CHAINLINK_ADAPTOR, "wrong sAUSD adaptor");

        assertEq(cSAUSD.decimals(), 6, "wrong csAUSD decimals");
        assertEq(cAUSD.decimals(), 6, "wrong cAUSD decimals");
        assertEq(sAUSD.decimals(), 6, "wrong sAUSD decimals");
        assertEq(sAUSD.lagDuration(), 0, "sAUSD exit is not instant");
        assertEq(sAUSD.managementFeePercent(), 200, "wrong management fee");
        assertEq(sAUSD.totalCollectableFees(), 0, "fees already charged");

        assertTrue(feeCaller != sAUSD.owner(), "fee caller is owner");
        assertTrue(feeCaller != sAUSD.operator(), "fee caller is operator");
        assertTrue(
            feeCaller != sAUSD.feesCollector(), "fee caller is collector"
        );

        cSAUSD.accrueIfNeeded();
        cAUSD.accrueIfNeeded();

        assertEq(cSAUSD.exchangeRate(), 1e18, "unexpected cToken rate");
        assertEq(cSAUSD.balanceOf(BORROWER), 12.698897e6, "wrong shares");
        assertEq(
            cSAUSD.collateralPosted(BORROWER),
            12.698897e6,
            "wrong posted collateral"
        );
    }

    function test_permissionlessFeeLeavesNominalHeadroomButExactNavDeficit()
        public
    {
        uint256 normalizedState = vm.snapshotState();
        Outcome memory noFee = _removeAndRedeem(false);

        assertTrue(
            vm.revertToState(normalizedState),
            "failed to restore normalized state"
        );
        Outcome memory charged = _removeAndRedeem(true);

        assertEq(noFee.feeCharged, 0, "control charged a fee");
        assertEq(charged.feeCharged, EXPECTED_FEE, "wrong fee charged");
        assertEq(
            noFee.realizedAUSD, EXPECTED_NO_FEE_EXIT, "wrong control exit"
        );
        assertEq(
            charged.realizedAUSD, EXPECTED_CHARGED_EXIT, "wrong charged exit"
        );
        assertEq(
            charged.remainingCTokenShares,
            EXPECTED_REMAINING_SHARES,
            "wrong remaining collateral"
        );
        assertEq(
            noFee.exactCollateralAUSD,
            EXPECTED_NO_FEE_EXACT_COLLATERAL,
            "wrong control exact collateral"
        );
        assertEq(
            charged.exactCollateralAUSD,
            EXPECTED_CHARGED_EXACT_COLLATERAL,
            "wrong charged exact collateral"
        );
        assertEq(
            noFee.exactMaxDebtAUSD,
            EXPECTED_NO_FEE_EXACT_MAX_DEBT,
            "wrong control exact max debt"
        );
        assertEq(
            charged.exactMaxDebtAUSD,
            EXPECTED_CHARGED_EXACT_MAX_DEBT,
            "wrong charged exact max debt"
        );
        assertEq(charged.debtAUSD, EXPECTED_DEBT_AUSD, "wrong AUSD debt");
        assertEq(
            charged.nominalCollateralUSD,
            EXPECTED_NOMINAL_COLLATERAL,
            "wrong nominal collateral"
        );
        assertEq(
            charged.nominalMaxDebtUSD,
            EXPECTED_NOMINAL_MAX_DEBT,
            "wrong nominal max debt"
        );
        assertEq(
            charged.nominalDebtUSD, EXPECTED_NOMINAL_DEBT, "wrong nominal debt"
        );
        assertEq(
            charged.oraclePrice,
            EXPECTED_ORACLE_PRICE,
            "wrong retained oracle price"
        );
        assertEq(
            noFee.remainingCTokenShares,
            charged.remainingCTokenShares,
            "branches removed different collateral"
        );
        assertEq(noFee.debtAUSD, charged.debtAUSD, "branch debt drifted");
        assertEq(
            noFee.nominalCollateralUSD,
            charged.nominalCollateralUSD,
            "nominal collateral recognized fee"
        );
        assertEq(
            noFee.nominalMaxDebtUSD,
            charged.nominalMaxDebtUSD,
            "nominal max debt recognized fee"
        );
        assertEq(
            noFee.nominalDebtUSD,
            charged.nominalDebtUSD,
            "nominal debt drifted"
        );
        assertEq(
            noFee.oraclePrice, charged.oraclePrice, "oracle recognized fee"
        );

        assertGe(noFee.exactMaxDebtAUSD, noFee.debtAUSD, "control deficient");
        assertGt(
            charged.nominalMaxDebtUSD,
            charged.nominalDebtUSD,
            "nominal position unhealthy"
        );
        assertLt(
            charged.exactMaxDebtAUSD,
            charged.debtAUSD,
            "exact NAV still healthy"
        );
        assertLt(
            charged.exactCollateralAUSD,
            noFee.exactCollateralAUSD,
            "fee did not reduce exact NAV"
        );
        assertLt(
            charged.realizedAUSD,
            noFee.realizedAUSD,
            "fee did not reduce realized exit"
        );

        _assertLiquidationUnavailableAndAtomic();
    }

    function _removeAndRedeem(bool chargeFee)
        internal
        returns (Outcome memory outcome)
    {
        uint256 feesBefore = sAUSD.totalCollectableFees();
        uint256 feeTimestampBefore = sAUSD.feesTimestamp();
        if (chargeFee) {
            vm.prank(feeCaller);
            sAUSD.chargeManagementFee();
            assertEq(
                sAUSD.feesTimestamp(),
                block.timestamp,
                "fee timestamp not advanced"
            );
        } else {
            assertEq(
                sAUSD.feesTimestamp(),
                feeTimestampBefore,
                "control advanced fee timestamp"
            );
        }
        outcome.feeCharged = sAUSD.totalCollectableFees() - feesBefore;

        uint256 sharesBefore = cSAUSD.balanceOf(BORROWER);
        uint256 postedBefore = cSAUSD.collateralPosted(BORROWER);
        uint256 cTokenSupplyBefore = cSAUSD.totalSupply();
        uint256 cTokenAssetsBefore = cSAUSD.totalAssets();
        uint256 borrowerSAUSDBefore = sAUSD.balanceOf(BORROWER);
        uint256 borrowerAUSDBefore = ausd.balanceOf(BORROWER);

        vm.startPrank(BORROWER);
        outcome.redeemedSAUSD =
            cSAUSD.redeemCollateral(REDEEM_SHARES, BORROWER, BORROWER);
        assertEq(
            outcome.redeemedSAUSD,
            REDEEM_SHARES,
            "csAUSD did not redeem one-for-one"
        );
        assertEq(
            sAUSD.balanceOf(BORROWER),
            borrowerSAUSDBefore + REDEEM_SHARES,
            "borrower did not receive sAUSD"
        );

        (uint256 returnedAssets, uint256 claimableEpoch) =
            sAUSD.requestRedeem(REDEEM_SHARES, BORROWER, BORROWER);
        vm.stopPrank();

        assertEq(
            claimableEpoch,
            block.timestamp,
            "instant exit returned wrong claim epoch"
        );
        outcome.realizedAUSD = ausd.balanceOf(BORROWER) - borrowerAUSDBefore;
        assertEq(
            outcome.realizedAUSD,
            returnedAssets,
            "request return did not match AUSD transfer"
        );
        assertEq(
            sAUSD.balanceOf(BORROWER),
            borrowerSAUSDBefore,
            "request did not burn redeemed sAUSD"
        );

        assertEq(
            cSAUSD.balanceOf(BORROWER),
            sharesBefore - REDEEM_SHARES,
            "wrong borrower share delta"
        );
        assertEq(
            cSAUSD.collateralPosted(BORROWER),
            postedBefore - REDEEM_SHARES,
            "wrong posted collateral delta"
        );
        assertEq(
            cSAUSD.totalSupply(),
            cTokenSupplyBefore - REDEEM_SHARES,
            "wrong csAUSD supply delta"
        );
        assertEq(
            cSAUSD.totalAssets(),
            cTokenAssetsBefore - REDEEM_SHARES,
            "wrong csAUSD asset delta"
        );

        outcome.remainingCTokenShares = cSAUSD.collateralPosted(BORROWER);
        outcome.remainingSAUSD =
            cSAUSD.convertToAssets(outcome.remainingCTokenShares);
        outcome.exactCollateralAUSD =
            sAUSD.convertToAssets(outcome.remainingSAUSD);
        outcome.exactMaxDebtAUSD =
            outcome.exactCollateralAUSD * COLLATERAL_RATIO / BPS;
        outcome.debtAUSD = cAUSD.debtBalance(BORROWER);
        (
            outcome.nominalCollateralUSD,
            outcome.nominalMaxDebtUSD,
            outcome.nominalDebtUSD
        ) = marketManager.statusOf(BORROWER);
        uint256 errorCode;
        (outcome.oraclePrice, errorCode) =
            oracleManager.getPrice(SAUSD, true, true);
        assertEq(errorCode, 0, "sAUSD oracle unhealthy");
    }

    function _assertLiquidationUnavailableAndAtomic() internal {
        address[] memory accounts = new address[](1);
        accounts[0] = BORROWER;
        bytes32 stateBefore = _liquidationStateHash();

        // Manager rejection precedes repayment transfer, so no donor or
        // synthetic AUSD funding is needed for this negative proof.
        assertEq(
            ausd.balanceOf(liquidator), 0, "liquidator unexpectedly funded"
        );
        vm.prank(liquidator);
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__NoLiquidationAvailable
            .selector
        );
        cAUSD.liquidate(accounts, CSAUSD);

        assertEq(
            _liquidationStateHash(),
            stateBefore,
            "failed liquidation was not atomic"
        );
    }

    function _liquidationStateHash() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                cSAUSD.balanceOf(BORROWER),
                cSAUSD.collateralPosted(BORROWER),
                cSAUSD.totalSupply(),
                cSAUSD.totalAssets(),
                sAUSD.totalSupply(),
                sAUSD.totalAssets(),
                sAUSD.totalCollectableFees(),
                sAUSD.balanceOf(BORROWER),
                ausd.balanceOf(BORROWER),
                cAUSD.debtBalance(BORROWER),
                cAUSD.marketOutstandingDebt(),
                cAUSD.totalAssets(),
                ausd.balanceOf(CAUSD),
                ausd.balanceOf(liquidator)
            )
        );
    }
}
