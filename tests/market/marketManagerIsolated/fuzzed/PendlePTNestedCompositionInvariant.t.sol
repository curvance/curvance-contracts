// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {TestBaseMarketIsolated} from "tests/market/TestBaseMarketIsolated.sol";
import {BorrowableCToken} from "contracts/market/token/BorrowableCToken.sol";
import {SimpleCToken} from "contracts/market/token/SimpleCToken.sol";
import {
    MarketManagerIsolated
} from "contracts/market/isolated/MarketManagerIsolated.sol";
import {
    ChainlinkAdaptor
} from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import {
    CombinedAggregator
} from "contracts/oracles/adaptors/wrappedAggregators/CombinedAggregator.sol";
import {
    PendlePrincipalTokenAdaptor
} from "contracts/oracles/adaptors/pendle/PendlePrincipalTokenAdaptor.sol";
import {MockDataFeed} from "contracts/mocks/MockDataFeed.sol";
import {MockV3Aggregator} from "contracts/mocks/MockV3Aggregator.sol";
import {
    PendlePtOracleLib
} from "contracts/libraries/external/pendle/PendlePtOracleLib.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IBorrowableCToken} from "contracts/interfaces/IBorrowableCToken.sol";
import {ICToken} from "contracts/interfaces/ICToken.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {IPositionManager} from "contracts/interfaces/IPositionManager.sol";
import {
    IPendlePTOracle
} from "contracts/interfaces/external/pendle/IPendlePtOracle.sol";
import {IPMarket} from "contracts/interfaces/external/pendle/IPMarket.sol";

/// @notice Stateful launch-risk model for PT-only collateral nested with
///         borrow, PM callback windows, liquidation, and oracle/adaptor faults.
contract PendlePTNestedCompositionInvariant is TestBaseMarketIsolated {
    address internal constant _PT_ORACLE =
        0x14030836AEc15B2ad48bB097bd57032559339c92;
    address internal constant _PT_STETH =
        0x7758896b6AC966BbABcf143eFA963030f17D3EdF;
    address internal constant _LP_STETH =
        0xD0354D4e7bCf345fB117cabe41aCaDb724eccCa2;
    uint32 internal constant _PT_TWAP_DURATION = 12;

    PendlePrincipalTokenAdaptor public ptAdaptor;
    SimpleCToken public pendlePTCToken;
    ChainlinkAdaptor public combinedQuoteAdaptor;
    CombinedAggregator public combinedStethFeed;
    MockV3Aggregator public combinedPrimaryFeed;
    MockV3Aggregator public combinedSecondaryFeed;
    PendlePTNestedCompositionHandler public handler;

    address public liquidityProvider;

    function setUp() public override {
        super.setUp();

        _deployCombinedStethQuoteAdaptor();
        _deployPendlePTMarket();

        liquidityProvider = makeAddr("pt nested liquidity provider");
        _seedMarketLiquidity(liquidityProvider);

        PendlePTNestedCompositionHandler.HandlerConfig memory config;
        config.ptAsset = IERC20(_PT_STETH);
        config.debtAsset = IERC20(address(usdc));
        config.ptCToken = pendlePTCToken;
        config.debtCToken = borrowableCUSDC;
        config.marketManager = marketManagerIsolated;
        config.ptAdaptor = ptAdaptor;
        config.debtFeed = mockUsdcFeed;
        config.stethFallbackFeed = mockStethFeed;
        config.combinedPrimaryFeed = combinedPrimaryFeed;
        config.combinedSecondaryFeed = combinedSecondaryFeed;
        config.pendleMarket = _LP_STETH;
        config.twapDuration = _PT_TWAP_DURATION;
        config.chainlinkHeartbeat = chainlinkAdaptor.DEFAULT_HEARTBEAT();
        config.combinedHeartbeat = combinedStethFeed.secondaryHeartbeat();
        config.borrower = user1;
        config.receiver = user2;
        config.liquidator = user3;
        config.seedHolder = liquidityProvider;

        handler = new PendlePTNestedCompositionHandler(config);

        marketManagerIsolated.addPositionManager(address(handler));

        bytes4[] memory selectors = new bytes4[](25);
        selectors[0] =
        PendlePTNestedCompositionHandler.setDebtOracleMode.selector;
        selectors[1] =
        PendlePTNestedCompositionHandler.setQuoteOracleMode.selector;
        selectors[2] =
        PendlePTNestedCompositionHandler.setPtOracleMode.selector;
        selectors[3] =
        PendlePTNestedCompositionHandler.setPmCallbackMode.selector;
        selectors[4] = PendlePTNestedCompositionHandler.skipTime.selector;
        selectors[5] = PendlePTNestedCompositionHandler.depositPtIdle.selector;
        selectors[6] =
        PendlePTNestedCompositionHandler.depositPtAsCollateral.selector;
        selectors[7] =
        PendlePTNestedCompositionHandler.postPtCollateral.selector;
        selectors[8] =
        PendlePTNestedCompositionHandler.seedDebtRowWithCanBorrow.selector;
        selectors[9] =
        PendlePTNestedCompositionHandler.seedDebtRowWithCanBorrowWithNotify
            .selector;
        selectors[10] = PendlePTNestedCompositionHandler.borrow.selector;
        selectors[11] = PendlePTNestedCompositionHandler.borrowFor.selector;
        selectors[12] =
        PendlePTNestedCompositionHandler.borrowForPositionManager.selector;
        selectors[13] = PendlePTNestedCompositionHandler.repay.selector;
        selectors[14] =
        PendlePTNestedCompositionHandler.removePtCollateral.selector;
        selectors[15] =
        PendlePTNestedCompositionHandler.removePtCollateralFor.selector;
        selectors[16] = PendlePTNestedCompositionHandler.withdrawPt.selector;
        selectors[17] = PendlePTNestedCompositionHandler.redeemPt.selector;
        selectors[18] =
        PendlePTNestedCompositionHandler.redeemPtCollateral.selector;
        selectors[19] =
        PendlePTNestedCompositionHandler.redeemPtCollateralFor.selector;
        selectors[20] =
        PendlePTNestedCompositionHandler.transferPtCTokens.selector;
        selectors[21] =
        PendlePTNestedCompositionHandler.transferFromPtCTokens.selector;
        selectors[22] =
        PendlePTNestedCompositionHandler.withdrawPtByPositionManager.selector;
        selectors[23] = PendlePTNestedCompositionHandler.liquidate.selector;
        selectors[24] =
        PendlePTNestedCompositionHandler.liquidateExact.selector;

        targetContract(address(handler));
        targetSelector(
            FuzzSelector({addr: address(handler), selectors: selectors})
        );

        excludeSender(address(0));
        excludeSender(address(handler));
        excludeSender(address(pendlePTCToken));
        excludeSender(address(borrowableCUSDC));
    }

    function invariant_badOracleNeverAllowsBorrowValue() public view {
        assertFalse(
            handler.badOracleBorrowMovedValue(),
            "bad oracle allowed borrow value movement"
        );
    }

    function invariant_badOracleNeverAllowsCollateralExtraction() public view {
        assertFalse(
            handler.badOracleCollateralMovedValue(),
            "bad oracle allowed PT collateral extraction"
        );
    }

    function invariant_badOracleNeverAllowsLiquidationValue() public view {
        assertFalse(
            handler.badOracleLiquidationMovedValue(),
            "bad oracle allowed liquidation value movement"
        );
    }

    function invariant_pmCallbackRollbackNeverMovesValue() public view {
        assertFalse(
            handler.pmCallbackRollbackMovedValue(),
            "reverting PM callback moved value"
        );
    }

    function invariant_ptCollateralAccounting() public view {
        uint256 borrowerPosted = pendlePTCToken.collateralPosted(user1);
        assertLe(
            borrowerPosted,
            pendlePTCToken.balanceOf(user1),
            "borrower PT collateral exceeds balance"
        );
        assertEq(
            pendlePTCToken.marketCollateralPosted(),
            borrowerPosted,
            "PT market collateral differs from modeled borrower collateral"
        );
        assertEq(
            IERC20(_PT_STETH).balanceOf(address(pendlePTCToken)),
            pendlePTCToken.totalAssets(),
            "PT cToken assets differ from PT held"
        );
    }

    function invariant_debtAccounting() public view {
        assertEq(
            borrowableCUSDC.debtBalance(user2),
            0,
            "receiver unexpectedly has debt"
        );
        assertEq(
            borrowableCUSDC.debtBalance(user3),
            0,
            "liquidator unexpectedly has debt"
        );
        assertEq(
            borrowableCUSDC.debtBalance(address(handler)),
            0,
            "handler unexpectedly has debt"
        );
        assertGe(
            borrowableCUSDC.debtBalance(user1),
            borrowableCUSDC.marketOutstandingDebt(),
            "single borrower debt must cover rounded market debt"
        );
        assertLe(
            borrowableCUSDC.marketOutstandingDebt(),
            borrowableCUSDC.totalAssets(),
            "market debt exceeds total assets"
        );
    }

    function _deployCombinedStethQuoteAdaptor() internal {
        mockStethFeed.setMockAnswer(2_000e8);
        mockStethFeed.setMockUpdatedAt(block.timestamp);

        combinedPrimaryFeed = new MockV3Aggregator(8, 2_000e8);
        combinedSecondaryFeed = new MockV3Aggregator(18, 1e18);
        combinedStethFeed = new CombinedAggregator(
            ICentralRegistry(address(centralRegistry)),
            address(combinedPrimaryFeed),
            address(combinedSecondaryFeed),
            0,
            "STETH_COMBINED"
        );

        combinedQuoteAdaptor =
            new ChainlinkAdaptor(ICentralRegistry(address(centralRegistry)));
        oracleManager.addApprovedAdaptor(address(combinedQuoteAdaptor));
        combinedQuoteAdaptor.addAsset(
            _STETH, true, address(combinedStethFeed), 0
        );
        oracleManager.replaceAssetPricingAdaptor(
            _STETH,
            address(chainlinkAdaptor),
            address(combinedQuoteAdaptor),
            250,
            150,
            250,
            150
        );
    }

    function _deployPendlePTMarket() internal {
        ptAdaptor = new PendlePrincipalTokenAdaptor(
            ICentralRegistry(address(centralRegistry)),
            IPendlePTOracle(_PT_ORACLE)
        );

        PendlePrincipalTokenAdaptor.AssetConfig memory assetConfig;
        assetConfig.market = IPMarket(_LP_STETH);
        assetConfig.twapDuration = _PT_TWAP_DURATION;
        assetConfig.quoteAsset = _STETH;
        assetConfig.quoteAssetDecimals = 18;
        ptAdaptor.addAsset(_PT_STETH, assetConfig);

        oracleManager.addApprovedAdaptor(address(ptAdaptor));
        oracleManager.addAssetPricingAdaptor(
            _PT_STETH, address(ptAdaptor), 100, 50, 100, 50
        );

        pendlePTCToken = new SimpleCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(_PT_STETH),
            address(marketManagerIsolated)
        );
        oracleManager.addCTokenSupport(address(pendlePTCToken));

        _prepareUSDC(address(this), 1_000_000e6);
        usdc.approve(address(borrowableCUSDC), type(uint256).max);
        deal(_PT_STETH, address(this), 100 ether);
        IERC20(_PT_STETH).approve(address(pendlePTCToken), type(uint256).max);

        marketManagerIsolated.listTokens(
            address(pendlePTCToken), address(borrowableCUSDC)
        );
        _setCTokenConfigBasic(address(pendlePTCToken), 1_000_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);
    }

    function _seedMarketLiquidity(address provider) internal {
        _prepareUSDC(provider, 1_000_000e6);
        deal(_PT_STETH, provider, 100 ether);

        vm.startPrank(provider);
        usdc.approve(address(borrowableCUSDC), type(uint256).max);
        borrowableCUSDC.deposit(1_000_000e6, provider);
        IERC20(_PT_STETH).approve(address(pendlePTCToken), type(uint256).max);
        pendlePTCToken.deposit(100 ether, provider);
        vm.stopPrank();
    }
}

contract PendlePTNestedCompositionHandler is Test, IPositionManager {
    using PendlePtOracleLib for IPMarket;

    struct HandlerConfig {
        IERC20 ptAsset;
        IERC20 debtAsset;
        SimpleCToken ptCToken;
        BorrowableCToken debtCToken;
        MarketManagerIsolated marketManager;
        PendlePrincipalTokenAdaptor ptAdaptor;
        MockDataFeed debtFeed;
        MockDataFeed stethFallbackFeed;
        MockV3Aggregator combinedPrimaryFeed;
        MockV3Aggregator combinedSecondaryFeed;
        address pendleMarket;
        uint32 twapDuration;
        uint256 chainlinkHeartbeat;
        uint256 combinedHeartbeat;
        address borrower;
        address receiver;
        address liquidator;
        address seedHolder;
    }

    enum DebtOracleMode {
        Normal,
        High,
        Stale,
        Zero
    }

    enum QuoteOracleMode {
        Normal,
        Low,
        CombinedPrimaryZero,
        CombinedSecondaryZero,
        CombinedSecondaryStale,
        BothQuoteAdaptorsStale
    }

    enum PtOracleMode {
        Normal,
        RateFailure
    }

    enum PmCallbackMode {
        Noop,
        BorrowRevert,
        BorrowTransferThenRevert,
        RedeemRevert,
        RedeemTransferThenRevert
    }

    struct PtSnapshot {
        uint256 borrowerBalance;
        uint256 receiverBalance;
        uint256 liquidatorBalance;
        uint256 handlerBalance;
        uint256 seedBalance;
        uint256 borrowerPosted;
        uint256 marketPosted;
        uint256 totalSupply;
        uint256 totalAssets;
        uint256 underlyingHeld;
        uint256 borrowerUnderlying;
        uint256 receiverUnderlying;
        uint256 liquidatorUnderlying;
        uint256 handlerUnderlying;
    }

    struct DebtSnapshot {
        uint256 borrowerDebt;
        uint256 marketDebt;
        uint256 totalAssets;
        uint256 marketCash;
        uint256 borrowerCash;
        uint256 receiverCash;
        uint256 liquidatorCash;
        uint256 handlerCash;
    }

    IERC20 public immutable ptAsset;
    IERC20 public immutable debtAsset;
    SimpleCToken public immutable ptCToken;
    BorrowableCToken public immutable debtCToken;
    MarketManagerIsolated public immutable marketManager;
    PendlePrincipalTokenAdaptor public immutable ptAdaptor;
    MockDataFeed public immutable debtFeed;
    MockDataFeed public immutable stethFallbackFeed;
    MockV3Aggregator public immutable combinedPrimaryFeed;
    MockV3Aggregator public immutable combinedSecondaryFeed;
    address public immutable pendleMarket;
    uint32 public immutable twapDuration;
    uint256 public immutable chainlinkHeartbeat;
    uint256 public immutable combinedHeartbeat;
    address public immutable borrower;
    address public immutable receiver;
    address public immutable liquidator;
    address public immutable seedHolder;

    DebtOracleMode public debtOracleMode;
    QuoteOracleMode public quoteOracleMode;
    PtOracleMode public ptOracleMode;
    PmCallbackMode public pmCallbackMode;

    bool public badOracleBorrowMovedValue;
    bool public badOracleCollateralMovedValue;
    bool public badOracleLiquidationMovedValue;
    bool public pmCallbackRollbackMovedValue;

    uint256 public borrowAttempts;
    uint256 public pmBorrowAttempts;
    uint256 public successfulBorrows;
    uint256 public collateralExtractionAttempts;
    uint256 public liquidationAttempts;
    uint256 public successfulLiquidations;

    constructor(HandlerConfig memory config) {
        ptAsset = config.ptAsset;
        debtAsset = config.debtAsset;
        ptCToken = config.ptCToken;
        debtCToken = config.debtCToken;
        marketManager = config.marketManager;
        ptAdaptor = config.ptAdaptor;
        debtFeed = config.debtFeed;
        stethFallbackFeed = config.stethFallbackFeed;
        combinedPrimaryFeed = config.combinedPrimaryFeed;
        combinedSecondaryFeed = config.combinedSecondaryFeed;
        pendleMarket = config.pendleMarket;
        twapDuration = config.twapDuration;
        chainlinkHeartbeat = config.chainlinkHeartbeat;
        combinedHeartbeat = config.combinedHeartbeat;
        borrower = config.borrower;
        receiver = config.receiver;
        liquidator = config.liquidator;
        seedHolder = config.seedHolder;

        _syncOracles();
    }

    modifier checkPostActionInvariants() {
        _;
        _assertPostActionInvariants();
    }

    function setDebtOracleMode(uint256 modeSeed)
        external
        checkPostActionInvariants
    {
        debtOracleMode = DebtOracleMode(modeSeed % 4);
        _syncOracles();
    }

    function setQuoteOracleMode(uint256 modeSeed)
        external
        checkPostActionInvariants
    {
        quoteOracleMode = QuoteOracleMode(modeSeed % 6);
        _syncOracles();
    }

    function setPtOracleMode(uint256 modeSeed)
        external
        checkPostActionInvariants
    {
        ptOracleMode = PtOracleMode(modeSeed % 2);
        _syncOracles();
    }

    function setPmCallbackMode(uint256 modeSeed)
        external
        checkPostActionInvariants
    {
        pmCallbackMode = PmCallbackMode(modeSeed % 5);
    }

    function skipTime(uint256 secondsSeed) external checkPostActionInvariants {
        skip(bound(secondsSeed, 1, 2 hours));
        _syncOracles();
    }

    function depositPtIdle(uint256 assets) public checkPostActionInvariants {
        assets = bound(assets, 1e15, 25 ether);
        deal(address(ptAsset), borrower, assets);

        PtSnapshot memory beforeAction = _ptSnapshot();
        vm.startPrank(borrower);
        ptAsset.approve(address(ptCToken), assets);
        try ptCToken.deposit(assets, borrower) returns (uint256 shares) {
            _assertPtDepositDelta(beforeAction, shares, assets, false);
        } catch {}
        vm.stopPrank();

        skip(1201);
        _syncOracles();
    }

    function depositPtAsCollateral(uint256 assets)
        public
        checkPostActionInvariants
    {
        assets = bound(assets, 1e15, 25 ether);
        deal(address(ptAsset), borrower, assets);

        PtSnapshot memory beforeAction = _ptSnapshot();
        vm.startPrank(borrower);
        ptAsset.approve(address(ptCToken), assets);
        try ptCToken.depositAsCollateral(assets, borrower) returns (
            uint256 shares
        ) {
            _assertPtDepositDelta(beforeAction, shares, assets, true);
        } catch {}
        vm.stopPrank();

        skip(1201);
        _syncOracles();
    }

    function postPtCollateral(uint256 sharesSeed)
        external
        checkPostActionInvariants
    {
        uint256 balance = ptCToken.balanceOf(borrower);
        uint256 posted = ptCToken.collateralPosted(borrower);
        if (balance <= posted) return;

        uint256 shares = bound(sharesSeed, 1, balance - posted);
        PtSnapshot memory beforeAction = _ptSnapshot();
        vm.prank(borrower);
        try ptCToken.postCollateral(shares) {
            _assertPostCollateralDelta(beforeAction, shares);
        } catch {}

        skip(1201);
        _syncOracles();
    }

    function seedDebtRowWithCanBorrow(uint256 assets)
        external
        checkPostActionInvariants
    {
        assets = bound(assets, 10e6, 2_000e6);
        _syncOracles();

        uint256 debtBefore = debtCToken.debtBalance(borrower);
        uint256 marketDebtBefore = debtCToken.marketOutstandingDebt();
        uint256 borrowerCashBefore = debtAsset.balanceOf(borrower);

        vm.prank(address(debtCToken));
        try marketManager.canBorrow(
            address(debtCToken),
            assets,
            borrower,
            debtCToken.marketOutstandingDebt() + assets
        ) {
            assertEq(
                debtCToken.debtBalance(borrower),
                debtBefore,
                "SEED ROW: borrower debt changed"
            );
            assertEq(
                debtCToken.marketOutstandingDebt(),
                marketDebtBefore,
                "SEED ROW: market debt changed"
            );
            assertEq(
                debtAsset.balanceOf(borrower),
                borrowerCashBefore,
                "SEED ROW: borrower cash changed"
            );
        } catch {}
    }

    function seedDebtRowWithCanBorrowWithNotify(uint256 assets)
        external
        checkPostActionInvariants
    {
        assets = bound(assets, 10e6, 2_000e6);
        _syncOracles();

        uint256 debtBefore = debtCToken.debtBalance(borrower);
        uint256 marketDebtBefore = debtCToken.marketOutstandingDebt();
        uint256 borrowerCashBefore = debtAsset.balanceOf(borrower);

        vm.prank(address(debtCToken));
        try marketManager.canBorrowWithNotify(
            address(debtCToken),
            assets,
            borrower,
            debtCToken.marketOutstandingDebt() + assets
        ) {
            assertEq(
                debtCToken.debtBalance(borrower),
                debtBefore,
                "SEED NOTIFY ROW: borrower debt changed"
            );
            assertEq(
                debtCToken.marketOutstandingDebt(),
                marketDebtBefore,
                "SEED NOTIFY ROW: market debt changed"
            );
            assertEq(
                debtAsset.balanceOf(borrower),
                borrowerCashBefore,
                "SEED NOTIFY ROW: borrower cash changed"
            );
        } catch {}
    }

    function borrow(uint256 assets) external checkPostActionInvariants {
        _attemptBorrow(assets, false);
    }

    function borrowFor(uint256 assets) external checkPostActionInvariants {
        _attemptBorrow(assets, true);
    }

    function borrowForPositionManager(uint256 assets)
        external
        checkPostActionInvariants
    {
        assets = bound(assets, 10e6, 2_000e6);
        borrowAttempts++;
        pmBorrowAttempts++;
        _syncOracles();
        try debtCToken.accrueIfNeeded() {} catch {}

        bool badOracle = _badOracle();
        DebtSnapshot memory beforeAction = _debtSnapshot();

        bool success;
        try debtCToken.borrowForPositionManager(
            assets, borrower, _emptyLeverageAction(assets)
        ) {
            success = true;
        } catch {}

        DebtSnapshot memory afterAction = _debtSnapshot();
        if (_pmBorrowCallbackReverts()) {
            if (success) {
                pmCallbackRollbackMovedValue = true;
            } else {
                _assertPmBorrowRollback(beforeAction, afterAction);
            }
            return;
        }

        if (badOracle) {
            _flagBadOracleBorrowMovement(success, beforeAction, afterAction);
            return;
        }

        if (success) {
            successfulBorrows++;
            _assertBorrowDelta(
                beforeAction, afterAction, assets, address(this)
            );
        }
    }

    function repay(uint256 repaySeed) external checkPostActionInvariants {
        try debtCToken.accrueIfNeeded() {} catch {}

        uint256 debt = debtCToken.debtBalance(borrower);
        if (debt == 0) return;

        uint256 repayAssets =
            repaySeed % 4 == 0 ? 0 : bound(repaySeed, 1, debt);
        uint256 assetsToFund = repayAssets == 0 ? debt : repayAssets;
        deal(address(debtAsset), borrower, assetsToFund);

        DebtSnapshot memory beforeAction = _debtSnapshot();
        vm.startPrank(borrower);
        debtAsset.approve(address(debtCToken), assetsToFund);
        try debtCToken.repay(repayAssets) {
            assertEq(
                debtCToken.debtBalance(borrower),
                beforeAction.borrowerDebt - assetsToFund,
                "POST REPAY: borrower debt delta"
            );
            assertEq(
                debtCToken.marketOutstandingDebt(),
                beforeAction.marketDebt < assetsToFund
                    ? 0
                    : beforeAction.marketDebt - assetsToFund,
                "POST REPAY: market debt delta"
            );
            assertEq(
                debtAsset.balanceOf(address(debtCToken)),
                beforeAction.marketCash + assetsToFund,
                "POST REPAY: debt cash delta"
            );
        } catch {}
        vm.stopPrank();
    }

    function removePtCollateral(uint256 sharesSeed)
        public
        checkPostActionInvariants
    {
        uint256 posted = ptCToken.collateralPosted(borrower);
        if (posted == 0) return;

        _syncOracles();
        try debtCToken.accrueIfNeeded() {} catch {}

        uint256 shares = bound(sharesSeed, 1, posted);
        _attemptRemoveCollateral(shares, false);
    }

    function removePtCollateralFor(uint256 sharesSeed)
        external
        checkPostActionInvariants
    {
        uint256 posted = ptCToken.collateralPosted(borrower);
        if (posted == 0) return;

        _syncOracles();
        try debtCToken.accrueIfNeeded() {} catch {}

        uint256 shares = bound(sharesSeed, 1, posted);
        vm.prank(borrower);
        ptCToken.setDelegateApproval(address(this), true);
        _attemptRemoveCollateral(shares, true);
    }

    function withdrawPt(uint256 assetsSeed) public checkPostActionInvariants {
        uint256 balance = ptCToken.balanceOf(borrower);
        if (balance == 0) return;

        _syncOracles();
        try debtCToken.accrueIfNeeded() {} catch {}

        uint256 maxAssets = ptCToken.convertToAssets(balance);
        if (maxAssets == 0) return;
        uint256 assets = bound(assetsSeed, 1, maxAssets);
        uint256 shares = ptCToken.previewWithdraw(assets);
        _attemptWithdraw(assets, shares, receiver, false);
    }

    function redeemPt(uint256 sharesSeed) public checkPostActionInvariants {
        uint256 balance = ptCToken.balanceOf(borrower);
        if (balance == 0) return;

        _syncOracles();
        try debtCToken.accrueIfNeeded() {} catch {}

        uint256 shares = bound(sharesSeed, 1, balance);
        uint256 assets = ptCToken.previewRedeem(shares);
        if (assets == 0) return;
        _attemptRedeem(shares, assets, receiver, false, false);
    }

    function redeemPtCollateral(uint256 sharesSeed)
        public
        checkPostActionInvariants
    {
        uint256 posted = ptCToken.collateralPosted(borrower);
        if (posted == 0) return;

        _syncOracles();
        try debtCToken.accrueIfNeeded() {} catch {}

        uint256 shares = bound(sharesSeed, 1, posted);
        uint256 assets = ptCToken.previewRedeem(shares);
        if (assets == 0) return;
        _attemptRedeem(shares, assets, receiver, true, false);
    }

    function redeemPtCollateralFor(uint256 sharesSeed)
        external
        checkPostActionInvariants
    {
        uint256 posted = ptCToken.collateralPosted(borrower);
        if (posted == 0) return;

        _syncOracles();
        try debtCToken.accrueIfNeeded() {} catch {}

        uint256 shares = bound(sharesSeed, 1, posted);
        uint256 assets = ptCToken.previewRedeem(shares);
        if (assets == 0) return;

        vm.prank(borrower);
        ptCToken.setDelegateApproval(address(this), true);
        _attemptRedeem(shares, assets, receiver, true, true);
    }

    function transferPtCTokens(uint256 sharesSeed)
        external
        checkPostActionInvariants
    {
        uint256 balance = ptCToken.balanceOf(borrower);
        if (balance == 0) return;

        _syncOracles();
        try debtCToken.accrueIfNeeded() {} catch {}

        uint256 shares = bound(sharesSeed, 1, balance);
        _attemptTransfer(shares, false);
    }

    function transferFromPtCTokens(uint256 sharesSeed)
        external
        checkPostActionInvariants
    {
        uint256 balance = ptCToken.balanceOf(borrower);
        if (balance == 0) return;

        _syncOracles();
        try debtCToken.accrueIfNeeded() {} catch {}

        uint256 shares = bound(sharesSeed, 1, balance);
        vm.prank(borrower);
        ptCToken.approve(address(this), shares);
        _attemptTransfer(shares, true);
    }

    function withdrawPtByPositionManager(uint256 assetsSeed)
        external
        checkPostActionInvariants
    {
        uint256 balance = ptCToken.balanceOf(borrower);
        if (balance == 0) return;

        _syncOracles();
        try debtCToken.accrueIfNeeded() {} catch {}

        uint256 maxAssets = ptCToken.convertToAssets(balance);
        if (maxAssets == 0) return;
        uint256 assets = bound(assetsSeed, 1, maxAssets);
        uint256 shares = ptCToken.previewWithdraw(assets);
        _attemptWithdraw(assets, shares, address(this), true);
    }

    function liquidate() external checkPostActionInvariants {
        _attemptLiquidation(0, false);
    }

    function liquidateExact(uint256 debtAmountSeed)
        external
        checkPostActionInvariants
    {
        uint256 debt = debtCToken.debtBalance(borrower);
        if (debt == 0) return;

        uint256 debtAmount = bound(debtAmountSeed, 1, debt);
        _attemptLiquidation(debtAmount, true);
    }

    function onBorrow(
        address,
        uint256 borrowAssets,
        address,
        IPositionManager.LeverageAction memory
    ) external override {
        if (pmCallbackMode == PmCallbackMode.BorrowTransferThenRevert) {
            debtAsset.transfer(receiver, borrowAssets);
            revert("PM_BORROW_CALLBACK_REVERT");
        }
        if (pmCallbackMode == PmCallbackMode.BorrowRevert) {
            revert("PM_BORROW_CALLBACK_REVERT");
        }
    }

    function onRedeem(
        address,
        uint256 collateralAssets,
        address,
        IPositionManager.DeleverageAction memory
    ) external override {
        if (pmCallbackMode == PmCallbackMode.RedeemTransferThenRevert) {
            ptAsset.transfer(receiver, collateralAssets);
            revert("PM_REDEEM_CALLBACK_REVERT");
        }
        if (pmCallbackMode == PmCallbackMode.RedeemRevert) {
            revert("PM_REDEEM_CALLBACK_REVERT");
        }
    }

    function supportsInterface(bytes4 interfaceId)
        external
        pure
        returns (bool)
    {
        return interfaceId == 0x01ffc9a7
            || interfaceId == type(IPositionManager).interfaceId;
    }

    function _attemptBorrow(uint256 assets, bool delegated) internal {
        assets = bound(assets, 10e6, 2_000e6);
        borrowAttempts++;
        _syncOracles();
        try debtCToken.accrueIfNeeded() {} catch {}

        bool badOracle = _badOracle();
        DebtSnapshot memory beforeAction = _debtSnapshot();
        address selectedReceiver = assets % 2 == 0 ? receiver : borrower;

        bool success;
        if (delegated) {
            vm.prank(borrower);
            debtCToken.setDelegateApproval(address(this), true);
            try debtCToken.borrowFor(assets, selectedReceiver, borrower) {
                success = true;
            } catch {}
        } else {
            vm.prank(borrower);
            try debtCToken.borrow(assets, selectedReceiver) {
                success = true;
            } catch {}
        }

        DebtSnapshot memory afterAction = _debtSnapshot();
        if (badOracle) {
            _flagBadOracleBorrowMovement(success, beforeAction, afterAction);
            return;
        }

        if (success) {
            successfulBorrows++;
            _assertBorrowDelta(
                beforeAction, afterAction, assets, selectedReceiver
            );
        }
    }

    function _attemptRemoveCollateral(uint256 shares, bool delegated)
        internal
    {
        bool badOracle = _badOracle();
        uint256 debtBefore = debtCToken.debtBalance(borrower);
        collateralExtractionAttempts++;

        PtSnapshot memory beforeAction = _ptSnapshot();
        bool success;
        if (delegated) {
            try ptCToken.removeCollateralFor(shares, borrower) {
                success = true;
            } catch {}
        } else {
            vm.prank(borrower);
            try ptCToken.removeCollateral(shares) {
                success = true;
            } catch {}
        }

        PtSnapshot memory afterAction = _ptSnapshot();
        if (badOracle && debtBefore > 0) {
            _flagBadOracleCollateralMovement(
                success, beforeAction, afterAction, true
            );
            return;
        }

        if (success) {
            _assertRemoveCollateralDelta(beforeAction, shares);
        }
    }

    function _attemptWithdraw(
        uint256 assets,
        uint256 shares,
        address outputReceiver,
        bool positionManager
    ) internal {
        bool badOracle = _badOracle();
        uint256 debtBefore = debtCToken.debtBalance(borrower);
        collateralExtractionAttempts++;

        PtSnapshot memory beforeAction = _ptSnapshot();
        uint256 collateralRedeemed = _collateralRedeemed(
            shares,
            beforeAction.borrowerBalance,
            beforeAction.borrowerPosted,
            false
        );

        bool success;
        if (positionManager) {
            try ptCToken.withdrawByPositionManager(
                assets, borrower, _emptyDeleverageAction(assets)
            ) {
                success = true;
            } catch {}
        } else {
            vm.prank(borrower);
            try ptCToken.withdraw(assets, outputReceiver, borrower) returns (
                uint256 actualShares
            ) {
                success = true;
                assertEq(actualShares, shares, "POST WITHDRAW: shares");
            } catch {}
        }

        PtSnapshot memory afterAction = _ptSnapshot();
        if (positionManager && _pmRedeemCallbackReverts()) {
            if (success) {
                pmCallbackRollbackMovedValue = true;
            } else {
                _assertPmRedeemRollback(beforeAction, afterAction);
            }
            return;
        }

        if (badOracle && debtBefore > 0 && collateralRedeemed > 0) {
            _flagBadOracleCollateralMovement(
                success, beforeAction, afterAction, true
            );
            return;
        }

        if (success) {
            _assertPtWithdrawalDelta(
                beforeAction,
                shares,
                assets,
                outputReceiver,
                collateralRedeemed
            );
        }
    }

    function _attemptRedeem(
        uint256 shares,
        uint256 assets,
        address outputReceiver,
        bool forceCollateral,
        bool delegated
    ) internal {
        bool badOracle = _badOracle();
        uint256 debtBefore = debtCToken.debtBalance(borrower);
        collateralExtractionAttempts++;

        PtSnapshot memory beforeAction = _ptSnapshot();
        uint256 collateralRedeemed = _collateralRedeemed(
            shares,
            beforeAction.borrowerBalance,
            beforeAction.borrowerPosted,
            forceCollateral
        );

        bool success;
        if (forceCollateral) {
            if (delegated) {
                try ptCToken.redeemCollateralFor(
                    shares, outputReceiver, borrower
                ) returns (
                    uint256 actualAssets
                ) {
                    success = true;
                    assertEq(actualAssets, assets, "POST REDEEM FOR: assets");
                } catch {}
            } else {
                vm.prank(borrower);
                try ptCToken.redeemCollateral(
                    shares, outputReceiver, borrower
                ) returns (
                    uint256 actualAssets
                ) {
                    success = true;
                    assertEq(actualAssets, assets, "POST REDEEM: assets");
                } catch {}
            }
        } else {
            vm.prank(borrower);
            try ptCToken.redeem(shares, outputReceiver, borrower) returns (
                uint256 actualAssets
            ) {
                success = true;
                assertEq(actualAssets, assets, "POST REDEEM IDLE: assets");
            } catch {}
        }

        PtSnapshot memory afterAction = _ptSnapshot();
        if (badOracle && debtBefore > 0 && collateralRedeemed > 0) {
            _flagBadOracleCollateralMovement(
                success, beforeAction, afterAction, true
            );
            return;
        }

        if (success) {
            _assertPtWithdrawalDelta(
                beforeAction,
                shares,
                assets,
                outputReceiver,
                collateralRedeemed
            );
        }
    }

    function _attemptTransfer(uint256 shares, bool delegated) internal {
        bool badOracle = _badOracle();
        uint256 debtBefore = debtCToken.debtBalance(borrower);
        collateralExtractionAttempts++;

        PtSnapshot memory beforeAction = _ptSnapshot();
        uint256 collateralRedeemed = _collateralRedeemed(
            shares,
            beforeAction.borrowerBalance,
            beforeAction.borrowerPosted,
            false
        );

        bool success;
        if (delegated) {
            try ptCToken.transferFrom(borrower, receiver, shares) returns (
                bool ok
            ) {
                success = ok;
            } catch {}
        } else {
            vm.prank(borrower);
            try ptCToken.transfer(receiver, shares) returns (bool ok) {
                success = ok;
            } catch {}
        }

        PtSnapshot memory afterAction = _ptSnapshot();
        if (badOracle && debtBefore > 0 && collateralRedeemed > 0) {
            _flagBadOracleCollateralMovement(
                success, beforeAction, afterAction, false
            );
            return;
        }

        if (success) {
            assertEq(
                afterAction.borrowerBalance,
                beforeAction.borrowerBalance - shares,
                "POST TRANSFER: borrower balance delta"
            );
            assertEq(
                afterAction.receiverBalance,
                beforeAction.receiverBalance + shares,
                "POST TRANSFER: receiver balance delta"
            );
            assertEq(
                afterAction.borrowerPosted,
                beforeAction.borrowerPosted - collateralRedeemed,
                "POST TRANSFER: borrower posted delta"
            );
            assertEq(
                afterAction.marketPosted,
                beforeAction.marketPosted - collateralRedeemed,
                "POST TRANSFER: market posted delta"
            );
        }
    }

    function _attemptLiquidation(uint256 debtAmount, bool exact) internal {
        _syncOracles();
        try debtCToken.accrueIfNeeded() {} catch {}

        if (debtCToken.debtBalance(borrower) == 0) return;
        if (ptCToken.collateralPosted(borrower) == 0) return;

        liquidationAttempts++;
        bool badOracle = _badOracle();

        uint256 borrowerDebt = debtCToken.debtBalance(borrower);
        deal(
            address(debtAsset),
            liquidator,
            debtAsset.balanceOf(liquidator) + borrowerDebt
        );
        DebtSnapshot memory debtBefore = _debtSnapshot();
        PtSnapshot memory ptBefore = _ptSnapshot();

        vm.startPrank(liquidator);
        debtAsset.approve(address(debtCToken), debtBefore.borrowerDebt);

        address[] memory accounts = new address[](1);
        accounts[0] = borrower;
        bool success;
        if (exact) {
            uint256[] memory debtAmounts = new uint256[](1);
            debtAmounts[0] = debtAmount;
            try debtCToken.liquidateExact(
                debtAmounts, accounts, address(ptCToken)
            ) {
                success = true;
            } catch {}
        } else {
            try debtCToken.liquidate(accounts, address(ptCToken)) {
                success = true;
            } catch {}
        }
        vm.stopPrank();

        DebtSnapshot memory debtAfter = _debtSnapshot();
        PtSnapshot memory ptAfter = _ptSnapshot();

        if (badOracle) {
            if (
                success || debtAfter.borrowerDebt < debtBefore.borrowerDebt
                    || debtAfter.marketDebt < debtBefore.marketDebt
                    || ptAfter.borrowerPosted < ptBefore.borrowerPosted
                    || ptAfter.liquidatorBalance > ptBefore.liquidatorBalance
                    || debtAfter.liquidatorCash < debtBefore.liquidatorCash
            ) {
                badOracleLiquidationMovedValue = true;
            }
            return;
        }

        if (success) {
            successfulLiquidations++;
            uint256 paid = debtBefore.liquidatorCash - debtAfter.liquidatorCash;
            uint256 seized = ptBefore.borrowerPosted - ptAfter.borrowerPosted;
            uint256 badDebt = debtBefore.totalAssets - debtAfter.totalAssets;

            assertGt(paid + badDebt, 0, "POST LIQ: no debt removed");
            assertEq(
                debtAfter.borrowerDebt,
                debtBefore.borrowerDebt - paid - badDebt,
                "POST LIQ: borrower debt delta"
            );
            assertEq(
                debtAfter.marketDebt,
                debtBefore.marketDebt > paid + badDebt
                    ? debtBefore.marketDebt - paid - badDebt
                    : 0,
                "POST LIQ: market debt delta"
            );
            assertEq(
                debtAfter.marketCash,
                debtBefore.marketCash + paid,
                "POST LIQ: market cash delta"
            );
            assertEq(
                ptAfter.liquidatorBalance,
                ptBefore.liquidatorBalance + seized,
                "POST LIQ: liquidator seized shares"
            );
            assertEq(
                ptAfter.marketPosted,
                ptBefore.marketPosted - seized,
                "POST LIQ: market collateral delta"
            );
        }
    }

    function _syncOracles() internal {
        _syncDebtOracle();
        _syncQuoteOracle();
        _syncPtOracle();
    }

    function _syncDebtOracle() internal {
        if (debtOracleMode == DebtOracleMode.Normal) {
            debtFeed.setMockAnswer(1e8);
            debtFeed.setMockUpdatedAt(block.timestamp);
        } else if (debtOracleMode == DebtOracleMode.High) {
            debtFeed.setMockAnswer(4e8);
            debtFeed.setMockUpdatedAt(block.timestamp);
        } else if (debtOracleMode == DebtOracleMode.Stale) {
            debtFeed.setMockAnswer(1e8);
            debtFeed.setMockUpdatedAt(block.timestamp - chainlinkHeartbeat - 1);
        } else {
            debtFeed.setMockAnswer(-1);
            debtFeed.setMockUpdatedAt(block.timestamp);
        }
    }

    function _syncQuoteOracle() internal {
        if (quoteOracleMode == QuoteOracleMode.Normal) {
            _setStethFallbackFeed(2_000e8, block.timestamp);
            combinedPrimaryFeed.updateAnswer(2_000e8);
            combinedSecondaryFeed.updateAnswer(1e18);
        } else if (quoteOracleMode == QuoteOracleMode.Low) {
            _setStethFallbackFeed(600e8, block.timestamp);
            combinedPrimaryFeed.updateAnswer(600e8);
            combinedSecondaryFeed.updateAnswer(1e18);
        } else if (quoteOracleMode == QuoteOracleMode.CombinedPrimaryZero) {
            _setStethFallbackFeed(2_000e8, block.timestamp);
            combinedPrimaryFeed.updateAnswer(0);
            combinedSecondaryFeed.updateAnswer(1e18);
        } else if (quoteOracleMode == QuoteOracleMode.CombinedSecondaryZero) {
            _setStethFallbackFeed(2_000e8, block.timestamp);
            combinedPrimaryFeed.updateAnswer(2_000e8);
            combinedSecondaryFeed.updateAnswer(0);
        } else if (quoteOracleMode == QuoteOracleMode.CombinedSecondaryStale) {
            _setStethFallbackFeed(2_000e8, block.timestamp);
            combinedPrimaryFeed.updateAnswer(2_000e8);
            combinedSecondaryFeed.updateRoundData(
                uint80(combinedSecondaryFeed.latestRound() + 1),
                1e18,
                block.timestamp - combinedHeartbeat - 1,
                block.timestamp - combinedHeartbeat - 1
            );
        } else {
            _setStethFallbackFeed(
                2_000e8, block.timestamp - chainlinkHeartbeat - 1
            );
            combinedPrimaryFeed.updateAnswer(2_000e8);
            combinedSecondaryFeed.updateRoundData(
                uint80(combinedSecondaryFeed.latestRound() + 1),
                1e18,
                block.timestamp - combinedHeartbeat - 1,
                block.timestamp - combinedHeartbeat - 1
            );
        }
    }

    function _syncPtOracle() internal {
        bytes memory callData = abi.encodeWithSelector(
            PendlePrincipalTokenAdaptor.fetchPtToAssetRate.selector,
            IPMarket(pendleMarket),
            twapDuration
        );

        if (ptOracleMode == PtOracleMode.RateFailure) {
            vm.mockCallRevert(address(ptAdaptor), callData, "pt rate failed");
            return;
        }

        uint256 rate = IPMarket(pendleMarket).getPtToAssetRate(twapDuration);
        vm.mockCall(address(ptAdaptor), callData, abi.encode(rate));
    }

    function _setStethFallbackFeed(int256 answer, uint256 updatedAt) internal {
        stethFallbackFeed.setMockAnswer(answer);
        stethFallbackFeed.setMockUpdatedAt(updatedAt);
    }

    function _badOracle() internal view returns (bool) {
        return debtOracleMode == DebtOracleMode.Stale
            || debtOracleMode == DebtOracleMode.Zero
            || uint256(quoteOracleMode) >= 2
            || ptOracleMode == PtOracleMode.RateFailure;
    }

    function _pmBorrowCallbackReverts() internal view returns (bool) {
        return pmCallbackMode == PmCallbackMode.BorrowRevert
            || pmCallbackMode == PmCallbackMode.BorrowTransferThenRevert;
    }

    function _pmRedeemCallbackReverts() internal view returns (bool) {
        return pmCallbackMode == PmCallbackMode.RedeemRevert
            || pmCallbackMode == PmCallbackMode.RedeemTransferThenRevert;
    }

    function _ptSnapshot() internal view returns (PtSnapshot memory snapshot) {
        snapshot.borrowerBalance = ptCToken.balanceOf(borrower);
        snapshot.receiverBalance = ptCToken.balanceOf(receiver);
        snapshot.liquidatorBalance = ptCToken.balanceOf(liquidator);
        snapshot.handlerBalance = ptCToken.balanceOf(address(this));
        snapshot.seedBalance = ptCToken.balanceOf(seedHolder);
        snapshot.borrowerPosted = ptCToken.collateralPosted(borrower);
        snapshot.marketPosted = ptCToken.marketCollateralPosted();
        snapshot.totalSupply = ptCToken.totalSupply();
        snapshot.totalAssets = ptCToken.totalAssets();
        snapshot.underlyingHeld = ptAsset.balanceOf(address(ptCToken));
        snapshot.borrowerUnderlying = ptAsset.balanceOf(borrower);
        snapshot.receiverUnderlying = ptAsset.balanceOf(receiver);
        snapshot.liquidatorUnderlying = ptAsset.balanceOf(liquidator);
        snapshot.handlerUnderlying = ptAsset.balanceOf(address(this));
    }

    function _debtSnapshot()
        internal
        view
        returns (DebtSnapshot memory snapshot)
    {
        snapshot.borrowerDebt = debtCToken.debtBalance(borrower);
        snapshot.marketDebt = debtCToken.marketOutstandingDebt();
        snapshot.totalAssets = debtCToken.totalAssets();
        snapshot.marketCash = debtAsset.balanceOf(address(debtCToken));
        snapshot.borrowerCash = debtAsset.balanceOf(borrower);
        snapshot.receiverCash = debtAsset.balanceOf(receiver);
        snapshot.liquidatorCash = debtAsset.balanceOf(liquidator);
        snapshot.handlerCash = debtAsset.balanceOf(address(this));
    }

    function _assertPostActionInvariants() internal view {
        uint256 borrowerPosted = ptCToken.collateralPosted(borrower);
        assertFalse(
            badOracleBorrowMovedValue,
            "POST ACTION: bad oracle borrow moved value"
        );
        assertFalse(
            badOracleCollateralMovedValue,
            "POST ACTION: bad oracle collateral moved value"
        );
        assertFalse(
            badOracleLiquidationMovedValue,
            "POST ACTION: bad oracle liquidation moved value"
        );
        assertFalse(
            pmCallbackRollbackMovedValue,
            "POST ACTION: PM callback rollback moved value"
        );
        assertLe(
            borrowerPosted,
            ptCToken.balanceOf(borrower),
            "POST ACTION: posted PT exceeds borrower balance"
        );
        assertEq(
            ptCToken.marketCollateralPosted(),
            borrowerPosted,
            "POST ACTION: PT market posted drift"
        );
        assertEq(
            ptAsset.balanceOf(address(ptCToken)),
            ptCToken.totalAssets(),
            "POST ACTION: PT cToken backing drift"
        );
        assertEq(
            debtCToken.debtBalance(receiver), 0, "POST ACTION: receiver debt"
        );
        assertEq(
            debtCToken.debtBalance(liquidator),
            0,
            "POST ACTION: liquidator debt"
        );
        assertEq(
            debtCToken.debtBalance(address(this)),
            0,
            "POST ACTION: handler debt"
        );
        assertGe(
            debtCToken.debtBalance(borrower),
            debtCToken.marketOutstandingDebt(),
            "POST ACTION: borrower debt below market debt"
        );
        assertLe(
            debtCToken.marketOutstandingDebt(),
            debtCToken.totalAssets(),
            "POST ACTION: market debt exceeds assets"
        );

        uint256 knownPtBalances = ptCToken.balanceOf(address(0))
            + ptCToken.balanceOf(borrower) + ptCToken.balanceOf(receiver)
            + ptCToken.balanceOf(liquidator)
            + ptCToken.balanceOf(address(this))
            + ptCToken.balanceOf(seedHolder);
        assertEq(
            knownPtBalances,
            ptCToken.totalSupply(),
            "POST ACTION: PT cToken supply differs from known holders"
        );
    }

    function _assertPtDepositDelta(
        PtSnapshot memory beforeAction,
        uint256 shares,
        uint256 assets,
        bool postsCollateral
    ) internal view {
        PtSnapshot memory afterAction = _ptSnapshot();
        assertEq(
            afterAction.borrowerBalance,
            beforeAction.borrowerBalance + shares,
            "POST PT DEPOSIT: borrower share delta"
        );
        assertEq(
            afterAction.totalSupply,
            beforeAction.totalSupply + shares,
            "POST PT DEPOSIT: supply delta"
        );
        assertEq(
            afterAction.totalAssets,
            beforeAction.totalAssets + assets,
            "POST PT DEPOSIT: assets delta"
        );
        assertEq(
            afterAction.underlyingHeld,
            beforeAction.underlyingHeld + assets,
            "POST PT DEPOSIT: underlying held delta"
        );
        assertEq(
            afterAction.borrowerUnderlying,
            beforeAction.borrowerUnderlying - assets,
            "POST PT DEPOSIT: borrower underlying delta"
        );
        assertEq(
            afterAction.borrowerPosted,
            postsCollateral
                ? beforeAction.borrowerPosted + shares
                : beforeAction.borrowerPosted,
            "POST PT DEPOSIT: borrower posted delta"
        );
        assertEq(
            afterAction.marketPosted,
            postsCollateral
                ? beforeAction.marketPosted + shares
                : beforeAction.marketPosted,
            "POST PT DEPOSIT: market posted delta"
        );
    }

    function _assertPostCollateralDelta(
        PtSnapshot memory beforeAction,
        uint256 shares
    ) internal view {
        assertEq(
            ptCToken.collateralPosted(borrower),
            beforeAction.borrowerPosted + shares,
            "POST COLLATERAL: borrower posted delta"
        );
        assertEq(
            ptCToken.marketCollateralPosted(),
            beforeAction.marketPosted + shares,
            "POST COLLATERAL: market posted delta"
        );
        assertEq(
            ptCToken.balanceOf(borrower),
            beforeAction.borrowerBalance,
            "POST COLLATERAL: borrower balance changed"
        );
    }

    function _assertRemoveCollateralDelta(
        PtSnapshot memory beforeAction,
        uint256 shares
    ) internal view {
        assertEq(
            ptCToken.collateralPosted(borrower),
            beforeAction.borrowerPosted - shares,
            "POST REMOVE: borrower posted delta"
        );
        assertEq(
            ptCToken.marketCollateralPosted(),
            beforeAction.marketPosted - shares,
            "POST REMOVE: market posted delta"
        );
        assertEq(
            ptCToken.balanceOf(borrower),
            beforeAction.borrowerBalance,
            "POST REMOVE: borrower balance changed"
        );
    }

    function _assertPtWithdrawalDelta(
        PtSnapshot memory beforeAction,
        uint256 shares,
        uint256 assets,
        address outputReceiver,
        uint256 collateralRedeemed
    ) internal view {
        PtSnapshot memory afterAction = _ptSnapshot();
        assertEq(
            afterAction.borrowerBalance,
            beforeAction.borrowerBalance - shares,
            "POST PT WITHDRAW: borrower share delta"
        );
        assertEq(
            afterAction.totalSupply,
            beforeAction.totalSupply - shares,
            "POST PT WITHDRAW: supply delta"
        );
        assertEq(
            afterAction.totalAssets,
            beforeAction.totalAssets - assets,
            "POST PT WITHDRAW: assets delta"
        );
        assertEq(
            afterAction.underlyingHeld,
            beforeAction.underlyingHeld - assets,
            "POST PT WITHDRAW: underlying held delta"
        );
        assertEq(
            afterAction.borrowerPosted,
            beforeAction.borrowerPosted - collateralRedeemed,
            "POST PT WITHDRAW: borrower posted delta"
        );
        assertEq(
            afterAction.marketPosted,
            beforeAction.marketPosted - collateralRedeemed,
            "POST PT WITHDRAW: market posted delta"
        );

        if (outputReceiver == receiver) {
            assertEq(
                afterAction.receiverUnderlying,
                beforeAction.receiverUnderlying + assets,
                "POST PT WITHDRAW: receiver underlying delta"
            );
        } else {
            assertEq(
                afterAction.handlerUnderlying,
                beforeAction.handlerUnderlying + assets,
                "POST PT WITHDRAW: handler underlying delta"
            );
        }
    }

    function _assertBorrowDelta(
        DebtSnapshot memory beforeAction,
        DebtSnapshot memory afterAction,
        uint256 assets,
        address selectedReceiver
    ) internal view {
        assertEq(
            afterAction.borrowerDebt,
            beforeAction.borrowerDebt + assets,
            "POST BORROW: borrower debt delta"
        );
        assertEq(
            afterAction.marketDebt,
            beforeAction.marketDebt + assets,
            "POST BORROW: market debt delta"
        );
        assertEq(
            afterAction.marketCash,
            beforeAction.marketCash - assets,
            "POST BORROW: market cash delta"
        );

        if (selectedReceiver == address(this)) {
            assertEq(
                afterAction.handlerCash,
                beforeAction.handlerCash + assets,
                "POST BORROW: handler cash delta"
            );
            assertEq(
                afterAction.borrowerCash,
                beforeAction.borrowerCash,
                "POST BORROW: borrower cash unchanged"
            );
            assertEq(
                afterAction.receiverCash,
                beforeAction.receiverCash,
                "POST BORROW: receiver cash unchanged"
            );
        } else if (selectedReceiver == receiver) {
            assertEq(
                afterAction.receiverCash,
                beforeAction.receiverCash + assets,
                "POST BORROW: receiver cash delta"
            );
            assertEq(
                afterAction.borrowerCash,
                beforeAction.borrowerCash,
                "POST BORROW: borrower cash unchanged"
            );
        } else {
            assertEq(
                afterAction.borrowerCash,
                beforeAction.borrowerCash + assets,
                "POST BORROW: borrower cash delta"
            );
            assertEq(
                afterAction.receiverCash,
                beforeAction.receiverCash,
                "POST BORROW: receiver cash unchanged"
            );
        }
    }

    function _flagBadOracleBorrowMovement(
        bool success,
        DebtSnapshot memory beforeAction,
        DebtSnapshot memory afterAction
    ) internal {
        if (
            success || afterAction.borrowerDebt > beforeAction.borrowerDebt
                || afterAction.marketDebt > beforeAction.marketDebt
                || afterAction.borrowerCash > beforeAction.borrowerCash
                || afterAction.receiverCash > beforeAction.receiverCash
                || afterAction.handlerCash > beforeAction.handlerCash
        ) {
            badOracleBorrowMovedValue = true;
        }
    }

    function _assertPmBorrowRollback(
        DebtSnapshot memory beforeAction,
        DebtSnapshot memory afterAction
    ) internal view {
        assertEq(
            afterAction.borrowerDebt,
            beforeAction.borrowerDebt,
            "POST PM BORROW REVERT: borrower debt changed"
        );
        assertEq(
            afterAction.marketDebt,
            beforeAction.marketDebt,
            "POST PM BORROW REVERT: market debt changed"
        );
        assertEq(
            afterAction.marketCash,
            beforeAction.marketCash,
            "POST PM BORROW REVERT: market cash changed"
        );
        assertEq(
            afterAction.handlerCash,
            beforeAction.handlerCash,
            "POST PM BORROW REVERT: handler cash changed"
        );
        assertEq(
            afterAction.receiverCash,
            beforeAction.receiverCash,
            "POST PM BORROW REVERT: receiver cash changed"
        );
    }

    function _assertPmRedeemRollback(
        PtSnapshot memory beforeAction,
        PtSnapshot memory afterAction
    ) internal view {
        assertEq(
            afterAction.borrowerBalance,
            beforeAction.borrowerBalance,
            "POST PM REDEEM REVERT: borrower balance changed"
        );
        assertEq(
            afterAction.handlerBalance,
            beforeAction.handlerBalance,
            "POST PM REDEEM REVERT: handler balance changed"
        );
        assertEq(
            afterAction.borrowerPosted,
            beforeAction.borrowerPosted,
            "POST PM REDEEM REVERT: borrower posted changed"
        );
        assertEq(
            afterAction.marketPosted,
            beforeAction.marketPosted,
            "POST PM REDEEM REVERT: market posted changed"
        );
        assertEq(
            afterAction.totalSupply,
            beforeAction.totalSupply,
            "POST PM REDEEM REVERT: totalSupply changed"
        );
        assertEq(
            afterAction.totalAssets,
            beforeAction.totalAssets,
            "POST PM REDEEM REVERT: totalAssets changed"
        );
        assertEq(
            afterAction.underlyingHeld,
            beforeAction.underlyingHeld,
            "POST PM REDEEM REVERT: underlying held changed"
        );
        assertEq(
            afterAction.handlerUnderlying,
            beforeAction.handlerUnderlying,
            "POST PM REDEEM REVERT: handler underlying changed"
        );
        assertEq(
            afterAction.receiverUnderlying,
            beforeAction.receiverUnderlying,
            "POST PM REDEEM REVERT: receiver underlying changed"
        );
    }

    function _flagBadOracleCollateralMovement(
        bool success,
        PtSnapshot memory beforeAction,
        PtSnapshot memory afterAction,
        bool checksUnderlying
    ) internal {
        if (
            success || afterAction.borrowerPosted < beforeAction.borrowerPosted
                || afterAction.marketPosted < beforeAction.marketPosted
                || afterAction.receiverBalance > beforeAction.receiverBalance
                || (checksUnderlying
                    && (afterAction.receiverUnderlying
                            > beforeAction.receiverUnderlying
                        || afterAction.handlerUnderlying
                            > beforeAction.handlerUnderlying))
        ) {
            badOracleCollateralMovedValue = true;
        }
    }

    function _collateralRedeemed(
        uint256 shares,
        uint256 balance,
        uint256 posted,
        bool forceRedeemCollateral
    ) internal pure returns (uint256) {
        if (posted == 0) return 0;
        if (forceRedeemCollateral) return shares;
        if (posted + shares >= balance) return posted + shares - balance;
        return 0;
    }

    function _emptyLeverageAction(uint256 assets)
        internal
        view
        returns (IPositionManager.LeverageAction memory action)
    {
        action.borrowableCToken = IBorrowableCToken(address(debtCToken));
        action.borrowAssets = assets;
        action.cToken = ICToken(address(ptCToken));
    }

    function _emptyDeleverageAction(uint256 assets)
        internal
        view
        returns (IPositionManager.DeleverageAction memory action)
    {
        action.cToken = ICToken(address(ptCToken));
        action.collateralAssets = assets;
        action.borrowableCToken = IBorrowableCToken(address(debtCToken));
    }
}
