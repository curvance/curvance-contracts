// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {SimpleCToken} from "contracts/market/token/SimpleCToken.sol";
import {BorrowableCToken} from "contracts/market/token/BorrowableCToken.sol";
import {
    MarketManagerIsolated
} from "contracts/market/isolated/MarketManagerIsolated.sol";
import {OracleManager} from "contracts/oracles/OracleManager.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {
    IChainlinkStyleAdaptor
} from "contracts/interfaces/IChainlinkStyleAdaptor.sol";
import {
    IChainlink
} from "contracts/interfaces/external/chainlink/IChainlink.sol";
import {
    IPPrincipalToken
} from "contracts/interfaces/external/pendle/IPPrincipalToken.sol";
import {
    IPYieldToken
} from "contracts/interfaces/external/pendle/IPYieldToken.sol";
import {
    IStandardizedYield
} from "contracts/interfaces/external/pendle/IStandardizedYield.sol";
import {
    FixedPointMathLib
} from "contracts/libraries/external/FixedPointMathLib.sol";

/// @notice Production-consumer regression for PT-earnAUSD's classic-vs-loss-aware
///         wrapper boundary at the historical state where SY is below PY.
/// @dev The borrower receives 100 PT through `deal` only to isolate the live
///      Curvance consumer edge. This is not an acquisition or profit proof.
contract PendlePTLossAwareBorrowEffectMonadFork is Test {
    uint256 internal constant FORK_BLOCK = 88_283_745;

    address internal constant PT = 0xDaf216939826AcABA0C2312F7E30A890213845CD;
    address internal constant CPT = 0x12046BFc04539D0Ac34912039ad266A5aA319b0D;
    address internal constant CAUSD =
        0x9489dc59C3636649f271C9E2ad3C303fd41923b9;
    address internal constant MARKET_MANAGER =
        0xFADE6B86fED641c7840d9E4997666F30D2160210;
    address internal constant ORACLE_MANAGER =
        0x65ADF8aE8420A58278De066593E6fF1713A137c5;
    address internal constant CHAINLINK_ADAPTOR =
        0x42B318abFDE82a43B3685eB65a5863B9367B22e1;
    address internal constant CLASSIC_WRAPPER =
        0x4Fc6c47e19DF74Fd36E910761358492e42ba3577;
    address internal constant SY = 0xE24A28fe8ECD859DB4280D1291783a10017d6fc4;
    address internal constant YT = 0x4147a0C89A83FABa5d401e644E110a1c5F67BD8b;

    uint256 internal constant PT_COLLATERAL = 100e6;
    uint256 internal constant CLASSIC_PRICE = 0.959065158160420371e18;
    uint256 internal constant LOSS_AWARE_PRICE = 0.959047470153294544e18;
    uint256 internal constant CLASSIC_CAPACITY = 88.244839e6;
    uint256 internal constant LOSS_AWARE_CAPACITY = 88.243211e6;
    uint256 internal constant BOUNDARY_BORROW = 88.243212e6;

    SimpleCToken internal constant cPT = SimpleCToken(CPT);
    BorrowableCToken internal constant cAUSD = BorrowableCToken(CAUSD);
    MarketManagerIsolated internal constant marketManager =
        MarketManagerIsolated(MARKET_MANAGER);
    OracleManager internal constant oracleManager =
        OracleManager(ORACLE_MANAGER);
    IChainlink internal constant classicWrapper = IChainlink(CLASSIC_WRAPPER);

    address internal borrower;
    IERC20 internal ausd;

    struct BorrowState {
        uint256 receiverBalance;
        uint256 accountDebt;
        uint256 marketDebt;
        uint256 marketCash;
        uint256 totalAssets;
    }

    struct RoundData {
        uint80 roundId;
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        uint80 answeredInRound;
    }

    function setUp() public {
        vm.createSelectFork(
            vm.envString("MON_NODE_URI_MONAD_ARCHIVE"), FORK_BLOCK
        );

        borrower = makeAddr("pt-boundary-borrower");
        ausd = IERC20(cAUSD.asset());

        assertEq(cPT.asset(), PT, "wrong live PT");
        assertEq(
            address(cPT.marketManager()), MARKET_MANAGER, "wrong cPT manager"
        );
        assertEq(
            address(cAUSD.marketManager()),
            MARKET_MANAGER,
            "wrong cAUSD manager"
        );
        assertEq(oracleManager.cTokens(CPT), PT, "wrong cPT oracle mapping");

        address[] memory adaptors = oracleManager.getPricingAdaptors(PT);
        assertEq(adaptors.length, 1, "unexpected PT route count");
        assertEq(adaptors[0], CHAINLINK_ADAPTOR, "wrong PT adaptor");

        (
            bool configured,
            address aggregator,
            uint8 decimals,
            uint24 heartbeat
        ) = IChainlinkStyleAdaptor(CHAINLINK_ADAPTOR).assetConfig(PT, true);
        assertTrue(configured, "PT route not configured");
        assertEq(aggregator, CLASSIC_WRAPPER, "wrong PT wrapper");
        assertEq(decimals, 18, "wrong wrapper decimals");
        assertEq(heartbeat, 3_720, "wrong wrapper heartbeat");

        assertEq(IPPrincipalToken(PT).SY(), SY, "wrong PT SY");
        assertEq(IPPrincipalToken(PT).YT(), YT, "wrong PT YT");
        assertEq(IPYieldToken(YT).SY(), SY, "YT/SY mismatch");

        // Normalize both live cToken accounting surfaces before branching.
        cPT.accrueIfNeeded();
        cAUSD.accrueIfNeeded();

        // Test-only PT funding isolates consumer reach. No PT acquisition path
        // or profit claim is made by this proof.
        // PT packs metadata with totalSupply; adjusting supply through
        // stdStorage would corrupt that live packed slot. Balance-only funding
        // is sufficient for this explicitly synthetic consumer experiment.
        deal(PT, borrower, PT_COLLATERAL, false);
        vm.startPrank(borrower);
        IERC20(PT).approve(CPT, type(uint256).max);
        uint256 shares = cPT.depositAsCollateral(PT_COLLATERAL, borrower);
        vm.stopPrank();

        assertEq(shares, PT_COLLATERAL, "unexpected cPT shares");
        assertEq(
            cPT.collateralPosted(borrower),
            PT_COLLATERAL,
            "PT collateral not posted"
        );
    }

    function test_classicRouteAllowsOneUnitAboveLossAwareBoundaryWhileLossAwareRejectsAtomically()
        public
    {
        RoundData memory classicRound = _assertLiveLossInputs();

        uint256 classicCapacity = _borrowCapacity();
        assertEq(classicCapacity, CLASSIC_CAPACITY, "wrong classic capacity");

        // Snapshot exactly once after all state normalization. Both terminal
        // branches begin from these same Curvance account and market bytes.
        uint256 normalizedState = vm.snapshotState();
        BorrowState memory beforeClassic = _borrowState();

        vm.prank(borrower);
        cAUSD.borrow(BOUNDARY_BORROW, borrower);
        _assertBorrowDelta(beforeClassic, BOUNDARY_BORROW);

        assertTrue(
            vm.revertToState(normalizedState),
            "failed to restore normalized branch state"
        );

        _installAndAssertLossAwareRound(classicRound);
        _assertLossAwareBorrowBoundary(classicCapacity);
    }

    function _assertLiveLossInputs()
        internal
        view
        returns (RoundData memory round)
    {
        (
            round.roundId,
            round.answer,
            round.startedAt,
            round.updatedAt,
            round.answeredInRound
        ) = classicWrapper.latestRoundData();

        uint256 syRate = IStandardizedYield(SY).exchangeRate();
        uint256 pyIndex = IPYieldToken(YT).pyIndexStored();
        assertFalse(
            IPYieldToken(YT).doCacheIndexSameBlock(),
            "unexpected PY cache mode"
        );
        assertEq(syRate, 1.030184e18, "unexpected live SY rate");
        assertEq(pyIndex, 1.030203e18, "unexpected live PY index");
        assertLt(syRate, pyIndex, "loss branch is not live");
        assertEq(uint256(round.answer), CLASSIC_PRICE, "wrong classic answer");
        assertEq(
            FixedPointMathLib.fullMulDiv(
                uint256(round.answer), syRate, pyIndex
            ),
            LOSS_AWARE_PRICE,
            "wrong loss-aware answer"
        );

        (uint256 oraclePrice, uint256 errorCode) =
            oracleManager.getPrice(PT, true, true);
        assertEq(oraclePrice, CLASSIC_PRICE, "wrong classic oracle price");
        assertEq(errorCode, 0, "classic oracle unhealthy");
    }

    function _installAndAssertLossAwareRound(RoundData memory classicRound)
        internal
    {
        vm.mockCall(
            CLASSIC_WRAPPER,
            abi.encodeWithSelector(IChainlink.latestRoundData.selector),
            abi.encode(
                classicRound.roundId,
                int256(LOSS_AWARE_PRICE),
                classicRound.startedAt,
                classicRound.updatedAt,
                classicRound.answeredInRound
            )
        );

        (
            uint80 mockedRoundId,
            int256 mockedAnswer,
            uint256 mockedStartedAt,
            uint256 mockedUpdatedAt,
            uint80 mockedAnsweredInRound
        ) = classicWrapper.latestRoundData();
        assertEq(mockedRoundId, classicRound.roundId, "round id changed");
        assertEq(mockedAnswer, int256(LOSS_AWARE_PRICE), "answer not replaced");
        assertEq(mockedStartedAt, classicRound.startedAt, "startedAt changed");
        assertEq(mockedUpdatedAt, classicRound.updatedAt, "updatedAt changed");
        assertEq(
            mockedAnsweredInRound,
            classicRound.answeredInRound,
            "answeredInRound changed"
        );
    }

    function _assertLossAwareBorrowBoundary(uint256 classicCapacity) internal {
        (uint256 lossAwareOraclePrice, uint256 lossAwareErrorCode) =
            oracleManager.getPrice(PT, true, true);
        assertEq(
            lossAwareOraclePrice,
            LOSS_AWARE_PRICE,
            "loss-aware answer did not reach OracleManager"
        );
        assertEq(lossAwareErrorCode, 0, "loss-aware route unhealthy");

        uint256 lossAwareCapacity = _borrowCapacity();
        assertEq(
            lossAwareCapacity, LOSS_AWARE_CAPACITY, "wrong loss-aware capacity"
        );
        assertEq(
            classicCapacity - lossAwareCapacity, 1_628, "wrong capacity delta"
        );
        assertEq(
            lossAwareCapacity + 1,
            BOUNDARY_BORROW,
            "borrow is not one base unit over boundary"
        );

        BorrowState memory beforeRejectedBorrow = _borrowState();
        vm.prank(borrower);
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral
            .selector
        );
        cAUSD.borrow(BOUNDARY_BORROW, borrower);
        _assertBorrowStateEq(beforeRejectedBorrow, _borrowState());

        // The immediately adjacent amount is accepted under the same mocked
        // loss-aware route, proving the exact one-base-unit boundary.
        vm.prank(borrower);
        cAUSD.borrow(LOSS_AWARE_CAPACITY, borrower);
        _assertBorrowDelta(beforeRejectedBorrow, LOSS_AWARE_CAPACITY);
    }

    function _borrowCapacity() internal returns (uint256 capacity) {
        (uint256 collateralSharesPrice, uint256 debtUnderlyingPrice) =
            oracleManager.getPriceIsolatedPair(CPT, CAUSD, 1);
        (uint256 collRatio,,) = marketManager.collConfig(CPT);

        uint256 maxDebtValue = FixedPointMathLib.fullMulDiv(
            cPT.collateralPosted(borrower),
            collateralSharesPrice,
            10 ** cPT.decimals()
        );
        maxDebtValue =
            FixedPointMathLib.fullMulDiv(maxDebtValue, collRatio, 10_000);
        capacity = FixedPointMathLib.fullMulDiv(
            maxDebtValue, 10 ** ausd.decimals(), debtUnderlyingPrice
        );
    }

    function _borrowState() internal view returns (BorrowState memory state) {
        state.receiverBalance = ausd.balanceOf(borrower);
        state.accountDebt = cAUSD.debtBalance(borrower);
        state.marketDebt = cAUSD.marketOutstandingDebt();
        state.marketCash = ausd.balanceOf(CAUSD);
        state.totalAssets = cAUSD.totalAssets();
    }

    function _assertBorrowDelta(BorrowState memory beforeState, uint256 amount)
        internal
        view
    {
        BorrowState memory afterState = _borrowState();
        assertEq(
            afterState.receiverBalance,
            beforeState.receiverBalance + amount,
            "wrong receiver delta"
        );
        assertEq(
            afterState.accountDebt,
            beforeState.accountDebt + amount,
            "wrong account debt delta"
        );
        assertEq(
            afterState.marketDebt,
            beforeState.marketDebt + amount,
            "wrong market debt delta"
        );
        assertEq(
            afterState.marketCash,
            beforeState.marketCash - amount,
            "wrong market cash delta"
        );
        assertEq(
            afterState.totalAssets,
            beforeState.totalAssets,
            "borrow changed total assets"
        );
    }

    function _assertBorrowStateEq(
        BorrowState memory expected,
        BorrowState memory actual
    ) internal pure {
        assertEq(
            actual.receiverBalance,
            expected.receiverBalance,
            "receiver changed"
        );
        assertEq(
            actual.accountDebt, expected.accountDebt, "account debt changed"
        );
        assertEq(actual.marketDebt, expected.marketDebt, "market debt changed");
        assertEq(actual.marketCash, expected.marketCash, "market cash changed");
        assertEq(
            actual.totalAssets, expected.totalAssets, "total assets changed"
        );
    }
}
