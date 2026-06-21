// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {TestBaseLendingOptimizer} from "../TestBaseLendingOptimizer.sol";
import {LendingOptimizerHarness} from "../LendingOptimizerHarness.sol";
import {
    LendingOptimizer
} from "contracts/market/optimizer/LendingOptimizer.sol";
import {
    LendingOptimizerShareCToken
} from "contracts/market/token/LendingOptimizerShareCToken.sol";
import {BorrowableCToken} from "contracts/market/token/BorrowableCToken.sol";
import {DynamicIRM} from "contracts/market/DynamicIRM.sol";
import {
    MarketManagerIsolated
} from "contracts/market/isolated/MarketManagerIsolated.sol";
import {
    VaultAggregator
} from "contracts/oracles/adaptors/wrappedAggregators/VaultAggregator.sol";
import {MockV3Aggregator} from "contracts/mocks/MockV3Aggregator.sol";
import {CentralRegistry} from "contracts/architecture/CentralRegistry.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IBorrowableCToken} from "contracts/interfaces/IBorrowableCToken.sol";
import {ICToken} from "contracts/interfaces/ICToken.sol";
import {ILendingOptimizer} from "contracts/interfaces/ILendingOptimizer.sol";
import {IPositionManager} from "contracts/interfaces/IPositionManager.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {WAD} from "contracts/libraries/ConstantsLib.sol";

/// @notice Stateful zero-row regression model for optimizer-share collateral.
contract OptimizerShareRowStateInvariant is TestBaseLendingOptimizer {
    LendingOptimizerHarness public harness;
    MarketManagerIsolated public optimizerMarket;
    BorrowableCToken public debtCToken;
    LendingOptimizerShareCToken public shareCToken;
    MockV3Aggregator public debtFeed;
    MockV3Aggregator public optimizerUnderlyingFeed;
    OptimizerShareRowStateHandler public handler;

    function setUp() public override {
        super.setUp();

        _deployThreeMarketOptimizerHarness();
        _deployOptimizerShareLaunchMarket();
        _seedDebtLiquidity(100_000e6);

        handler = new OptimizerShareRowStateHandler(
            harness,
            shareCToken,
            debtCToken,
            debtFeed,
            optimizerUnderlyingFeed,
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            _chainlinkAdaptor.DEFAULT_HEARTBEAT(),
            user1,
            user2
        );

        optimizerMarket.addPositionManager(address(handler));

        bytes4[] memory selectors = new bytes4[](26);
        selectors[0] = OptimizerShareRowStateHandler.setDebtOracleMode.selector;
        selectors[1] =
        OptimizerShareRowStateHandler.setOptimizerOracleMode.selector;
        selectors[2] = OptimizerShareRowStateHandler.skipTime.selector;
        selectors[3] =
        OptimizerShareRowStateHandler.depositAndPostOptimizerCollateral
            .selector;
        selectors[4] =
        OptimizerShareRowStateHandler.depositOptimizerShares.selector;
        selectors[5] =
        OptimizerShareRowStateHandler.mintOptimizerShareCTokens.selector;
        selectors[6] =
        OptimizerShareRowStateHandler.depositAsOptimizerCollateral.selector;
        selectors[7] =
        OptimizerShareRowStateHandler.depositAsOptimizerCollateralFor.selector;
        selectors[8] =
        OptimizerShareRowStateHandler.postOptimizerCollateralFor.selector;
        selectors[9] =
        OptimizerShareRowStateHandler.rebalanceOptimizer.selector;
        selectors[10] = OptimizerShareRowStateHandler.borrow.selector;
        selectors[11] = OptimizerShareRowStateHandler.borrowFor.selector;
        selectors[12] =
        OptimizerShareRowStateHandler.borrowForPositionManager.selector;
        selectors[13] = OptimizerShareRowStateHandler.repay.selector;
        selectors[14] =
        OptimizerShareRowStateHandler.withdrawOptimizerCollateral.selector;
        selectors[15] =
        OptimizerShareRowStateHandler.withdrawOptimizerByPositionManager
            .selector;
        selectors[16] =
        OptimizerShareRowStateHandler.withdrawOptimizerShares.selector;
        selectors[17] =
        OptimizerShareRowStateHandler.redeemOptimizerShares.selector;
        selectors[18] =
        OptimizerShareRowStateHandler.redeemOptimizerSharesFor.selector;
        selectors[19] =
        OptimizerShareRowStateHandler.redeemOptimizerCollateral.selector;
        selectors[20] =
        OptimizerShareRowStateHandler.redeemOptimizerCollateralFor.selector;
        selectors[21] =
        OptimizerShareRowStateHandler.removeOptimizerCollateral.selector;
        selectors[22] =
        OptimizerShareRowStateHandler.removeOptimizerCollateralFor.selector;
        selectors[23] =
        OptimizerShareRowStateHandler.transferOptimizerShareCTokens.selector;
        selectors[24] =
        OptimizerShareRowStateHandler.transferFromOptimizerShareCTokens
            .selector;
        selectors[25] =
        OptimizerShareRowStateHandler.attemptOptimizerShareDebt.selector;
        targetContract(address(handler));
        targetSelector(
            FuzzSelector({addr: address(handler), selectors: selectors})
        );

        excludeSender(address(0));
        excludeSender(address(handler));
        excludeSender(address(harness));
        excludeSender(address(shareCToken));
        excludeSender(address(debtCToken));
    }

    function invariant_badOracleNeverAllowsBorrowValue() public view {
        assertFalse(
            handler.badOracleBorrowMovedValue(),
            "bad optimizer/debt oracle allowed borrow value movement"
        );
    }

    function invariant_badOracleWithDebtNeverAllowsOptimizerCollateralExtraction()
        public
        view
    {
        assertFalse(
            handler.badOracleCollateralMovedValue(),
            "bad optimizer/debt oracle allowed collateral extraction with debt"
        );
    }

    function invariant_optimizerShareDebtSurfaceRemainsDisabled() public view {
        assertFalse(
            handler.optimizerShareDebtSurfaceMovedValue(),
            "optimizer-share cToken debt surface moved value"
        );
        assertEq(
            shareCToken.debtBalance(user1), 0, "optimizer-share debt balance"
        );
        assertEq(
            shareCToken.marketOutstandingDebt(),
            0,
            "optimizer-share market debt"
        );
    }

    function invariant_optimizerSharePostedCollateralBackedByShares()
        public
        view
    {
        assertLe(
            shareCToken.collateralPosted(user1),
            shareCToken.balanceOf(user1),
            "posted optimizer-share collateral exceeds share balance"
        );
    }

    function invariant_listedOptimizerMarketRegistration() public view {
        assertTrue(
            optimizerMarket.isListed(address(shareCToken)),
            "optimizer-share cToken not listed"
        );
        assertTrue(
            optimizerMarket.isListed(address(debtCToken)),
            "optimizer debt cToken not listed"
        );
        assertEq(
            _oracleManager.cTokens(address(shareCToken)),
            address(harness),
            "optimizer-share oracle mapping"
        );
        assertEq(
            _oracleManager.cTokens(address(debtCToken)),
            USDC_MONAD,
            "optimizer debt oracle mapping"
        );
        assertEq(shareCToken.asset(), address(harness), "share cToken asset");
        assertEq(debtCToken.asset(), USDC_MONAD, "debt cToken asset");
        assertTrue(
            _oracleManager.isSupportedAsset(address(shareCToken)),
            "optimizer-share cToken oracle unsupported"
        );
        assertTrue(
            _oracleManager.isSupportedAsset(address(debtCToken)),
            "debt cToken oracle unsupported"
        );

        address[] memory listedTokens = optimizerMarket.queryTokensListed();
        assertEq(listedTokens.length, 2, "optimizer market listed length");
        assertEq(
            listedTokens[0],
            address(shareCToken),
            "optimizer market listed token0"
        );
        assertEq(
            listedTokens[1],
            address(debtCToken),
            "optimizer market listed token1"
        );
    }

    function invariant_listedOptimizerShareCTokenAccounting() public view {
        uint256 borrowerPosted = shareCToken.collateralPosted(user1);
        uint256 shareTokenSupply = shareCToken.totalSupply();
        uint256 shareTokenAssets = shareCToken.totalAssets();

        assertEq(
            shareCToken.marketCollateralPosted(),
            borrowerPosted,
            "share cToken market collateral"
        );
        assertLe(
            borrowerPosted,
            shareCToken.balanceOf(user1),
            "borrower posted exceeds share balance"
        );
        assertLe(
            borrowerPosted,
            shareTokenSupply,
            "share cToken collateral exceeds supply"
        );
        assertEq(
            shareTokenAssets,
            harness.balanceOf(address(shareCToken)),
            "share cToken assets not backed by optimizer shares"
        );

        uint256 knownShareCTokenBalances = shareCToken.balanceOf(address(0))
            + shareCToken.balanceOf(user1) + shareCToken.balanceOf(user2)
            + shareCToken.balanceOf(address(handler));
        assertEq(
            knownShareCTokenBalances,
            shareTokenSupply,
            "share cToken supply has unknown holder"
        );
    }

    function invariant_listedDebtMarketAccounting() public view {
        assertEq(
            debtCToken.collateralPosted(user1),
            0,
            "borrower posted debt cToken collateral"
        );
        assertEq(
            debtCToken.marketCollateralPosted(),
            0,
            "debt cToken market collateral"
        );
        assertEq(debtCToken.debtBalance(user2), 0, "receiver debt balance");
        assertEq(
            debtCToken.debtBalance(address(handler)), 0, "handler debt balance"
        );

        uint256 borrowerDebt = debtCToken.debtBalance(user1);
        uint256 marketDebt = debtCToken.marketOutstandingDebt();
        if (borrowerDebt == 0) {
            assertEq(marketDebt, 0, "zero borrower debt left market debt");
        }

        assertGe(
            borrowerDebt, marketDebt, "market debt exceeds sole borrower debt"
        );
        assertLe(
            marketDebt,
            debtCToken.totalAssets(),
            "market debt exceeds debt cToken assets"
        );
        assertGe(
            IERC20(USDC_MONAD).balanceOf(address(debtCToken)),
            debtCToken.assetsHeld(),
            "debt market assetsHeld exceeds cash"
        );
    }

    function invariant_listedOptimizerAccounting() public view {
        assertEq(harness.asset(), USDC_MONAD, "optimizer asset");
        assertEq(
            harness.totalAssets(),
            harness.exposed_totalAssetsIndexed(),
            "optimizer totalAssets cache"
        );
        assertLe(
            harness.totalAssets(),
            _sumOptimizerApprovedMarketAssets(),
            "optimizer assets exceed approved market backing"
        );

        uint256 knownOptimizerShares = harness.balanceOf(address(0))
            + harness.balanceOf(address(this)) + harness.balanceOf(user1)
            + harness.balanceOf(user2) + harness.balanceOf(address(handler))
            + harness.balanceOf(address(shareCToken));
        assertEq(
            knownOptimizerShares,
            harness.totalSupply(),
            "optimizer supply has unknown holder"
        );
    }

    function invariant_optimizerApprovedMarketsStaySeparateFromShareMarket()
        public
        view
    {
        uint256 numMarkets = harness.numApprovedMarkets();
        for (uint256 i; i < numMarkets; ++i) {
            address market = harness.approvedCTokensList(i);
            address marketManager =
                address(IBorrowableCToken(market).marketManager());
            MarketManagerIsolated mm = MarketManagerIsolated(marketManager);

            assertNotEq(
                market,
                address(shareCToken),
                "optimizer approved its share cToken"
            );
            assertNotEq(
                market,
                address(debtCToken),
                "optimizer approved its debt cToken"
            );
            assertNotEq(
                marketManager,
                address(optimizerMarket),
                "optimizer approved its listing market"
            );
            assertEq(
                IBorrowableCToken(market).asset(),
                USDC_MONAD,
                "approved market underlying"
            );
            assertEq(
                _oracleManager.cTokens(market),
                USDC_MONAD,
                "approved market oracle mapping"
            );
            assertTrue(mm.isListed(market), "approved market not listed");

            _assertMarketDoesNotPairOptimizerShareAsset(mm, market);
        }
    }

    function test_optimizerShareRowStateHandler_smokeSequence() public {
        handler.depositAndPostOptimizerCollateral(50_000e6);
        handler.rebalanceOptimizer(2, 0, 5_000e6);
        handler.borrow(20_000e6);
        handler.setOptimizerOracleMode(2);
        handler.borrowFor(20_000e6);
        handler.withdrawOptimizerCollateral(1_000e6);
        handler.removeOptimizerCollateral(1e18);
        handler.attemptOptimizerShareDebt(1_000e6);

        assertFalse(
            handler.badOracleBorrowMovedValue(), "bad oracle borrow smoke"
        );
        assertFalse(
            handler.badOracleCollateralMovedValue(),
            "bad oracle collateral smoke"
        );
        assertFalse(
            handler.optimizerShareDebtSurfaceMovedValue(), "share debt smoke"
        );
    }

    function _deployThreeMarketOptimizerHarness() internal {
        address[] memory approvedCTokens = new address[](3);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;
        approvedCTokens[2] = cUSDC_WETH_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](3);
        allocationCapsBps[0] = 10_000;
        allocationCapsBps[1] = 10_000;
        allocationCapsBps[2] = 10_000;

        harness = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000
        );
        optimizer = LendingOptimizer(address(harness));

        deal(USDC_MONAD, address(this), 77777);
        IERC20(USDC_MONAD).approve(address(harness), 77777);
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(
                ICentralRegistry.hasMarketPermissions.selector, address(this)
            ),
            abi.encode(true)
        );
        harness.initializeDeposits(cUSDC_WMON_MARKET);

        deal(USDC_MONAD, address(this), 300_000e6);
        IERC20(USDC_MONAD).approve(address(harness), 300_000e6);
        harness.depositToMarket(100_000e6, address(this), cUSDC_WMON_MARKET);
        harness.depositToMarket(100_000e6, address(this), cUSDC_WBTC_MARKET);
        harness.depositToMarket(100_000e6, address(this), cUSDC_WETH_MARKET);
    }

    function _deployOptimizerShareLaunchMarket() internal {
        CentralRegistry cr = CentralRegistry(address(liveCentralRegistry));
        optimizerMarket =
            new MarketManagerIsolated(liveCentralRegistry, 10e18, false);
        cr.addMarketManager(address(optimizerMarket));

        DynamicIRM debtIRM = _deployOptimizerCTokenIRM();
        debtCToken = new BorrowableCToken(
            liveCentralRegistry,
            IERC20(USDC_MONAD),
            address(optimizerMarket),
            address(debtIRM)
        );
        debtIRM.setLinkedToken(address(debtCToken));

        DynamicIRM shareIRM = _deployOptimizerCTokenIRM();
        shareCToken = new LendingOptimizerShareCToken(
            liveCentralRegistry,
            ILendingOptimizer(address(harness)),
            address(optimizerMarket),
            address(shareIRM)
        );
        shareIRM.setLinkedToken(address(shareCToken));

        _registerMutableLaunchOracleFeeds();
        _oracleManager.addCTokenSupport(address(debtCToken));
        _oracleManager.addCTokenSupport(address(shareCToken));

        _mintOptimizerShares(100_000e6);
        IERC20(address(harness)).approve(address(shareCToken), 77777);
        deal(USDC_MONAD, address(this), 77777);
        IERC20(USDC_MONAD).approve(address(debtCToken), 77777);
        optimizerMarket.listTokens(address(shareCToken), address(debtCToken));

        _configureToken(
            optimizerMarket, address(shareCToken), 7000, 1_000_000e6, 0
        );
        _configureToken(
            optimizerMarket, address(debtCToken), 0, 0, 1_000_000e6
        );
    }

    function _registerMutableLaunchOracleFeeds() internal {
        debtFeed = new MockV3Aggregator(8, 1e8);
        _chainlinkAdaptor.addAsset(USDC_MONAD, true, address(debtFeed), 0);

        optimizerUnderlyingFeed = new MockV3Aggregator(8, 1e8);
        VaultAggregator optimizerVaultFeed = new VaultAggregator(
            address(harness),
            USDC_MONAD,
            address(optimizerUnderlyingFeed),
            "optimizer/USD"
        );
        _chainlinkAdaptor.addAsset(
            address(harness), true, address(optimizerVaultFeed), 0
        );
        _oracleManager.addAssetPricingAdaptor(
            address(harness), address(_chainlinkAdaptor), 0, 0, 0, 0
        );
        _chainlinkAdaptor.setGuardedPriceConfig(
            address(harness), true, 0, 0, WAD, 0
        );
    }

    function _seedDebtLiquidity(uint256 assets) internal {
        deal(USDC_MONAD, address(this), assets);
        IERC20(USDC_MONAD).approve(address(debtCToken), assets);
        debtCToken.deposit(assets, address(this));
    }

    function _mintOptimizerShares(uint256 assets) internal {
        deal(USDC_MONAD, address(this), assets);
        IERC20(USDC_MONAD).approve(address(harness), assets);
        harness.deposit(assets, address(this));
    }

    function _deployOptimizerCTokenIRM() internal returns (DynamicIRM) {
        return new DynamicIRM(
            liveCentralRegistry, 1200, 2000, 8500, 500, 200, 100000
        );
    }

    function _sumOptimizerApprovedMarketAssets()
        internal
        view
        returns (uint256 sumMarkets)
    {
        uint256 numMarkets = harness.numApprovedMarkets();
        for (uint256 i; i < numMarkets; ++i) {
            address market = harness.approvedCTokensList(i);
            sumMarkets += IBorrowableCToken(market)
                .convertToAssets(
                    IBorrowableCToken(market).balanceOf(address(harness))
                );
        }
    }

    function _assertMarketDoesNotPairOptimizerShareAsset(
        MarketManagerIsolated mm,
        address approvedMarket
    ) internal view {
        address[] memory listedTokens = mm.queryTokensListed();
        for (uint256 i; i < listedTokens.length; ++i) {
            address listedToken = listedTokens[i];
            if (listedToken == approvedMarket) continue;

            assertNotEq(
                ICToken(listedToken).asset(),
                address(harness),
                "approved market pairs optimizer shares"
            );
        }
    }
}

contract OptimizerShareRowStateHandler is Test, IPositionManager {
    enum OracleMode {
        Normal,
        Stale,
        Zero
    }

    LendingOptimizerHarness public optimizer;
    LendingOptimizerShareCToken public shareCToken;
    BorrowableCToken public debtCToken;
    MockV3Aggregator public debtFeed;
    MockV3Aggregator public optimizerFeed;
    IERC20 public usdc;
    ICentralRegistry public centralRegistry;

    uint256 public heartbeat;
    address public borrower;
    address public receiver;
    address public optimizerSeedHolder;
    OracleMode public debtOracleMode;
    OracleMode public optimizerOracleMode;

    bool public badOracleBorrowMovedValue;
    bool public badOracleCollateralMovedValue;
    bool public optimizerShareDebtSurfaceMovedValue;

    struct ShareSnapshot {
        uint256 borrowerBalance;
        uint256 receiverBalance;
        uint256 handlerBalance;
        uint256 borrowerPosted;
        uint256 marketCollateral;
        uint256 totalSupply;
        uint256 totalAssets;
        uint256 underlyingHeld;
        uint256 borrowerOptimizer;
        uint256 receiverOptimizer;
        uint256 handlerOptimizer;
    }

    uint256 public borrowAttempts;
    uint256 public badOracleBorrowAttempts;
    uint256 public successfulBorrows;
    uint256 public collateralRemovalAttempts;
    uint256 public optimizerRebalances;

    constructor(
        LendingOptimizerHarness optimizer_,
        LendingOptimizerShareCToken shareCToken_,
        BorrowableCToken debtCToken_,
        MockV3Aggregator debtFeed_,
        MockV3Aggregator optimizerFeed_,
        IERC20 usdc_,
        ICentralRegistry centralRegistry_,
        uint256 heartbeat_,
        address borrower_,
        address receiver_
    ) {
        optimizer = optimizer_;
        shareCToken = shareCToken_;
        debtCToken = debtCToken_;
        debtFeed = debtFeed_;
        optimizerFeed = optimizerFeed_;
        usdc = usdc_;
        centralRegistry = centralRegistry_;
        heartbeat = heartbeat_;
        borrower = borrower_;
        receiver = receiver_;
        optimizerSeedHolder = msg.sender;

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
        debtOracleMode = OracleMode(modeSeed % 3);
        _syncOracles();
    }

    function setOptimizerOracleMode(uint256 modeSeed)
        public
        checkPostActionInvariants
    {
        optimizerOracleMode = OracleMode(modeSeed % 3);
        _syncOracles();
    }

    function skipTime(uint256 secondsSeed) external checkPostActionInvariants {
        skip(bound(secondsSeed, 1, 7 days));
    }

    function depositOptimizerShares(uint256 assets)
        public
        checkPostActionInvariants
    {
        assets = bound(assets, 1_000e6, 100_000e6);
        uint256 optimizerShares = _mintOptimizerSharesFor(borrower, assets);
        if (optimizerShares == 0) return;

        ShareSnapshot memory beforeAction = _shareSnapshot();
        vm.startPrank(borrower);
        IERC20(address(optimizer))
            .approve(address(shareCToken), optimizerShares);
        try shareCToken.deposit(optimizerShares, borrower) returns (
            uint256 wrapperShares
        ) {
            _assertShareDepositDelta(
                beforeAction, wrapperShares, optimizerShares, false
            );
        } catch {}
        vm.stopPrank();

        skip(1201);
    }

    function mintOptimizerShareCTokens(uint256 sharesSeed)
        external
        checkPostActionInvariants
    {
        uint256 optimizerShares = _mintOptimizerSharesFor(borrower, 100_000e6);
        if (optimizerShares == 0) return;

        uint256 maxWrapperShares = shareCToken.convertToShares(optimizerShares);
        if (maxWrapperShares == 0) return;
        uint256 wrapperShares = bound(sharesSeed, 1, maxWrapperShares);
        uint256 requiredOptimizerShares =
            shareCToken.previewMint(wrapperShares);
        if (requiredOptimizerShares > optimizerShares) return;

        ShareSnapshot memory beforeAction = _shareSnapshot();
        vm.startPrank(borrower);
        IERC20(address(optimizer))
            .approve(address(shareCToken), requiredOptimizerShares);
        try shareCToken.mint(wrapperShares, borrower) returns (
            uint256 assets
        ) {
            _assertShareDepositDelta(
                beforeAction, wrapperShares, assets, false
            );
        } catch {}
        vm.stopPrank();

        skip(1201);
    }

    function depositAsOptimizerCollateral(uint256 assets)
        external
        checkPostActionInvariants
    {
        assets = bound(assets, 1_000e6, 100_000e6);
        uint256 optimizerShares = _mintOptimizerSharesFor(borrower, assets);
        if (optimizerShares == 0) return;

        ShareSnapshot memory beforeAction = _shareSnapshot();
        vm.startPrank(borrower);
        IERC20(address(optimizer))
            .approve(address(shareCToken), optimizerShares);
        try shareCToken.depositAsCollateral(
            optimizerShares, borrower
        ) returns (
            uint256 wrapperShares
        ) {
            _assertShareDepositDelta(
                beforeAction, wrapperShares, optimizerShares, true
            );
        } catch {}
        vm.stopPrank();

        skip(1201);
    }

    function depositAsOptimizerCollateralFor(uint256 assets)
        external
        checkPostActionInvariants
    {
        assets = bound(assets, 1_000e6, 100_000e6);
        uint256 optimizerShares =
            _mintOptimizerSharesFor(address(this), assets);
        if (optimizerShares == 0) return;

        vm.prank(borrower);
        shareCToken.setDelegateApproval(address(this), true);
        IERC20(address(optimizer))
            .approve(address(shareCToken), optimizerShares);

        ShareSnapshot memory beforeAction = _shareSnapshot();
        try shareCToken.depositAsCollateralFor(
            optimizerShares, borrower
        ) returns (
            uint256 wrapperShares
        ) {
            _assertShareDepositDelta(
                beforeAction, wrapperShares, optimizerShares, true
            );
        } catch {}

        skip(1201);
    }

    function depositAndPostOptimizerCollateral(uint256 assets)
        public
        checkPostActionInvariants
    {
        assets = bound(assets, 1_000e6, 100_000e6);
        uint256 optimizerShares = _mintOptimizerSharesFor(borrower, assets);
        if (optimizerShares == 0) return;

        ShareSnapshot memory beforeAction = _shareSnapshot();
        vm.startPrank(borrower);
        IERC20(address(optimizer))
            .approve(address(shareCToken), optimizerShares);
        try shareCToken.deposit(optimizerShares, borrower) returns (
            uint256 wrapperShares
        ) {
            _assertShareDepositDelta(
                beforeAction, wrapperShares, optimizerShares, false
            );
            ShareSnapshot memory beforePost = _shareSnapshot();
            try shareCToken.postCollateral(wrapperShares) {
                _assertPostCollateralDelta(beforePost, wrapperShares);
            } catch {}
        } catch {}
        vm.stopPrank();

        skip(1201);
    }

    function postOptimizerCollateralFor(uint256 sharesSeed)
        external
        checkPostActionInvariants
    {
        uint256 balance = shareCToken.balanceOf(borrower);
        uint256 posted = shareCToken.collateralPosted(borrower);
        if (balance <= posted) return;

        uint256 shares = bound(sharesSeed, 1, balance - posted);

        vm.prank(borrower);
        shareCToken.setDelegateApproval(address(this), true);

        ShareSnapshot memory beforeAction = _shareSnapshot();
        try shareCToken.postCollateralFor(shares, borrower) {
            _assertPostCollateralDelta(beforeAction, shares);
        } catch {}
    }

    function rebalanceOptimizer(
        uint256 withdrawMarketIndex,
        uint256 depositMarketIndex,
        uint256 amount
    ) public checkPostActionInvariants {
        uint256 numMarkets = optimizer.numApprovedMarkets();
        if (numMarkets < 2) return;

        withdrawMarketIndex = bound(withdrawMarketIndex, 0, numMarkets - 1);
        depositMarketIndex = bound(depositMarketIndex, 0, numMarkets - 1);
        if (withdrawMarketIndex == depositMarketIndex) {
            depositMarketIndex = (depositMarketIndex + 1) % numMarkets;
        }

        address withdrawMarket =
            optimizer.approvedCTokensList(withdrawMarketIndex);
        uint256 marketAssets = IBorrowableCToken(withdrawMarket)
            .convertToAssets(
                IBorrowableCToken(withdrawMarket).balanceOf(address(optimizer))
            );
        uint256 marketLiquidity =
            IBorrowableCToken(withdrawMarket).assetsHeld();
        uint256 maxAmount =
            marketAssets < marketLiquidity ? marketAssets : marketLiquidity;
        if (maxAmount == 0) return;

        amount = bound(amount, 1, maxAmount);
        LendingOptimizer.ReallocationAction[] memory actions =
            new LendingOptimizer.ReallocationAction[](numMarkets);
        for (uint256 i; i < numMarkets; ++i) {
            actions[i].cToken =
                IBorrowableCToken(optimizer.approvedCTokensList(i));
            if (i == withdrawMarketIndex) {
                actions[i].assetsOrBps = -int256(amount);
            } else if (i == depositMarketIndex) {
                actions[i].assetsOrBps = int256(amount);
            }
        }

        _mockHarvestPermissions(address(this));
        try optimizer.rebalance(actions, _unconstrainedBounds()) {
            optimizerRebalances++;
        } catch {}
    }

    function borrow(uint256 assets) external checkPostActionInvariants {
        _attemptBorrow(assets, false);
    }

    function borrowFor(uint256 assets) public checkPostActionInvariants {
        _attemptBorrow(assets, true);
    }

    function borrowForPositionManager(uint256 assets)
        external
        checkPostActionInvariants
    {
        _attemptBorrowForPositionManager(assets);
    }

    function repay(uint256 repaySeed) external checkPostActionInvariants {
        try debtCToken.accrueIfNeeded() {} catch {}
        uint256 debt = debtCToken.debtBalance(borrower);
        if (debt == 0) return;

        uint256 repayAssets =
            repaySeed % 4 == 0 ? 0 : bound(repaySeed, 1, debt);
        uint256 assetsToFund = repayAssets == 0 ? debt : repayAssets;
        uint256 marketDebtBefore = debtCToken.marketOutstandingDebt();
        uint256 debtCashBefore = usdc.balanceOf(address(debtCToken));

        deal(address(usdc), borrower, assetsToFund);
        vm.startPrank(borrower);
        usdc.approve(address(debtCToken), assetsToFund);
        try debtCToken.repay(repayAssets) {
            assertEq(
                debtCToken.debtBalance(borrower),
                debt - assetsToFund,
                "POST REPAY: borrower debt delta"
            );
            assertEq(
                debtCToken.marketOutstandingDebt(),
                marketDebtBefore < assetsToFund
                    ? 0
                    : marketDebtBefore - assetsToFund,
                "POST REPAY: market debt delta"
            );
            assertEq(
                usdc.balanceOf(address(debtCToken)),
                debtCashBefore + assetsToFund,
                "POST REPAY: debt cash delta"
            );
        } catch {}
        vm.stopPrank();
    }

    function withdrawOptimizerCollateral(uint256 assetsSeed)
        public
        checkPostActionInvariants
    {
        uint256 posted = shareCToken.collateralPosted(borrower);
        if (posted == 0) return;

        _syncOracles();
        try debtCToken.accrueIfNeeded() {} catch {}

        uint256 maxAssets = shareCToken.convertToAssets(posted);
        if (maxAssets == 0) return;
        uint256 assets = bound(assetsSeed, 1, maxAssets);

        bool badOracle = _badOracle();
        uint256 debtBefore = debtCToken.debtBalance(borrower);
        uint256 postedBefore = shareCToken.collateralPosted(borrower);
        uint256 receiverOptimizerBefore = optimizer.balanceOf(receiver);
        collateralRemovalAttempts++;

        ShareSnapshot memory beforeAction = _shareSnapshot();
        vm.prank(borrower);
        try shareCToken.withdrawCollateral(
            assets, receiver, borrower
        ) returns (
            uint256 shares
        ) {
            _assertShareWithdrawalDelta(
                beforeAction, shares, assets, receiver, true
            );
        } catch {}

        if (badOracle && debtBefore > 0) {
            if (
                shareCToken.collateralPosted(borrower) < postedBefore
                    || optimizer.balanceOf(receiver) > receiverOptimizerBefore
            ) {
                badOracleCollateralMovedValue = true;
            }
        }
    }

    function withdrawOptimizerByPositionManager(uint256 assetsSeed)
        public
        checkPostActionInvariants
    {
        uint256 balance = shareCToken.balanceOf(borrower);
        if (balance == 0) return;

        _syncOracles();
        try debtCToken.accrueIfNeeded() {} catch {}

        uint256 maxAssets = shareCToken.convertToAssets(balance);
        if (maxAssets == 0) return;
        uint256 assets = bound(assetsSeed, 1, maxAssets);

        (
            uint256 debtBefore,
            uint256 postedBefore,
            uint256 borrowerOptimizerBefore,
            uint256 receiverOptimizerBefore,
            uint256 handlerOptimizerBefore
        ) = _collateralSnapshot();

        ShareSnapshot memory beforeAction = _shareSnapshot();
        uint256 shares = shareCToken.previewWithdraw(assets);
        vm.prank(address(this));
        try shareCToken.withdrawByPositionManager(
            assets, borrower, _emptyDeleverageAction(assets)
        ) {
            _assertShareWithdrawalDelta(
                beforeAction, shares, assets, address(this), false
            );
        } catch {}

        _flagBadOracleCollateralMovement(
            debtBefore,
            postedBefore,
            borrowerOptimizerBefore,
            receiverOptimizerBefore,
            handlerOptimizerBefore
        );
    }

    function withdrawOptimizerShares(uint256 assetsSeed)
        public
        checkPostActionInvariants
    {
        uint256 balance = shareCToken.balanceOf(borrower);
        if (balance == 0) return;

        _syncOracles();
        try debtCToken.accrueIfNeeded() {} catch {}

        uint256 maxAssets = shareCToken.convertToAssets(balance);
        if (maxAssets == 0) return;
        uint256 assets = bound(assetsSeed, 1, maxAssets);

        (
            uint256 debtBefore,
            uint256 postedBefore,
            uint256 borrowerOptimizerBefore,
            uint256 receiverOptimizerBefore,
            uint256 handlerOptimizerBefore
        ) = _collateralSnapshot();

        ShareSnapshot memory beforeAction = _shareSnapshot();
        vm.prank(borrower);
        try shareCToken.withdraw(assets, receiver, borrower) returns (
            uint256 shares
        ) {
            _assertShareWithdrawalDelta(
                beforeAction, shares, assets, receiver, false
            );
        } catch {}

        _flagBadOracleCollateralMovement(
            debtBefore,
            postedBefore,
            borrowerOptimizerBefore,
            receiverOptimizerBefore,
            handlerOptimizerBefore
        );
    }

    function redeemOptimizerShares(uint256 sharesSeed)
        public
        checkPostActionInvariants
    {
        uint256 balance = shareCToken.balanceOf(borrower);
        if (balance == 0) return;

        _syncOracles();
        try debtCToken.accrueIfNeeded() {} catch {}

        uint256 shares = bound(sharesSeed, 1, balance);

        (
            uint256 debtBefore,
            uint256 postedBefore,
            uint256 borrowerOptimizerBefore,
            uint256 receiverOptimizerBefore,
            uint256 handlerOptimizerBefore
        ) = _collateralSnapshot();

        ShareSnapshot memory beforeAction = _shareSnapshot();
        vm.prank(borrower);
        try shareCToken.redeem(shares, receiver, borrower) returns (
            uint256 assets
        ) {
            _assertShareWithdrawalDelta(
                beforeAction, shares, assets, receiver, false
            );
        } catch {}

        _flagBadOracleCollateralMovement(
            debtBefore,
            postedBefore,
            borrowerOptimizerBefore,
            receiverOptimizerBefore,
            handlerOptimizerBefore
        );
    }

    function redeemOptimizerSharesFor(uint256 sharesSeed)
        external
        checkPostActionInvariants
    {
        uint256 balance = shareCToken.balanceOf(borrower);
        if (balance == 0) return;

        _syncOracles();
        try debtCToken.accrueIfNeeded() {} catch {}

        uint256 shares = bound(sharesSeed, 1, balance);

        (
            uint256 debtBefore,
            uint256 postedBefore,
            uint256 borrowerOptimizerBefore,
            uint256 receiverOptimizerBefore,
            uint256 handlerOptimizerBefore
        ) = _collateralSnapshot();

        vm.prank(borrower);
        shareCToken.setDelegateApproval(address(this), true);
        ShareSnapshot memory beforeAction = _shareSnapshot();
        try shareCToken.redeemFor(shares, receiver, borrower) returns (
            uint256 assets
        ) {
            _assertShareWithdrawalDelta(
                beforeAction, shares, assets, receiver, false
            );
        } catch {}

        _flagBadOracleCollateralMovement(
            debtBefore,
            postedBefore,
            borrowerOptimizerBefore,
            receiverOptimizerBefore,
            handlerOptimizerBefore
        );
    }

    function redeemOptimizerCollateral(uint256 sharesSeed)
        public
        checkPostActionInvariants
    {
        _redeemOptimizerCollateral(sharesSeed, false);
    }

    function redeemOptimizerCollateralFor(uint256 sharesSeed)
        external
        checkPostActionInvariants
    {
        _redeemOptimizerCollateral(sharesSeed, true);
    }

    function removeOptimizerCollateral(uint256 sharesSeed)
        public
        checkPostActionInvariants
    {
        uint256 posted = shareCToken.collateralPosted(borrower);
        if (posted == 0) return;

        _syncOracles();
        try debtCToken.accrueIfNeeded() {} catch {}

        uint256 shares = bound(sharesSeed, 1, posted);
        bool badOracle = _badOracle();
        uint256 debtBefore = debtCToken.debtBalance(borrower);
        uint256 postedBefore = posted;
        collateralRemovalAttempts++;

        ShareSnapshot memory beforeAction = _shareSnapshot();
        vm.prank(borrower);
        try shareCToken.removeCollateral(shares) {
            _assertRemoveCollateralDelta(beforeAction, shares);
        } catch {}

        if (
            badOracle && debtBefore > 0
                && shareCToken.collateralPosted(borrower) < postedBefore
        ) {
            badOracleCollateralMovedValue = true;
        }
    }

    function removeOptimizerCollateralFor(uint256 sharesSeed)
        external
        checkPostActionInvariants
    {
        uint256 posted = shareCToken.collateralPosted(borrower);
        if (posted == 0) return;

        _syncOracles();
        try debtCToken.accrueIfNeeded() {} catch {}

        uint256 shares = bound(sharesSeed, 1, posted);
        bool badOracle = _badOracle();
        uint256 debtBefore = debtCToken.debtBalance(borrower);
        uint256 postedBefore = posted;
        collateralRemovalAttempts++;

        ShareSnapshot memory beforeAction = _shareSnapshot();
        vm.prank(borrower);
        shareCToken.setDelegateApproval(address(this), true);
        try shareCToken.removeCollateralFor(shares, borrower) {
            _assertRemoveCollateralDelta(beforeAction, shares);
        } catch {}

        if (
            badOracle && debtBefore > 0
                && shareCToken.collateralPosted(borrower) < postedBefore
        ) {
            badOracleCollateralMovedValue = true;
        }
    }

    function transferOptimizerShareCTokens(uint256 sharesSeed)
        external
        checkPostActionInvariants
    {
        _transferOptimizerShareCTokens(sharesSeed, false);
    }

    function transferFromOptimizerShareCTokens(uint256 sharesSeed)
        external
        checkPostActionInvariants
    {
        _transferOptimizerShareCTokens(sharesSeed, true);
    }

    function attemptOptimizerShareDebt(uint256 assetsSeed)
        public
        checkPostActionInvariants
    {
        uint256 assets = bound(assetsSeed, 1, 100_000e6);
        uint256 borrowerOptimizerBefore = optimizer.balanceOf(borrower);
        uint256 receiverOptimizerBefore = optimizer.balanceOf(receiver);
        uint256 debtBefore = shareCToken.debtBalance(borrower);
        uint256 marketDebtBefore = shareCToken.marketOutstandingDebt();

        vm.prank(borrower);
        try shareCToken.borrow(assets, receiver) {
            optimizerShareDebtSurfaceMovedValue = true;
        } catch {}

        vm.prank(borrower);
        try shareCToken.borrowFor(assets, receiver, borrower) {
            optimizerShareDebtSurfaceMovedValue = true;
        } catch {}

        try shareCToken.borrowForPositionManager(
            assets, borrower, _emptyLeverageAction(assets)
        ) {
            optimizerShareDebtSurfaceMovedValue = true;
        } catch {}

        try shareCToken.flashLoan(assets, bytes("")) {
            optimizerShareDebtSurfaceMovedValue = true;
        } catch {}

        if (
            optimizer.balanceOf(borrower) > borrowerOptimizerBefore
                || optimizer.balanceOf(receiver) > receiverOptimizerBefore
                || shareCToken.debtBalance(borrower) > debtBefore
                || shareCToken.marketOutstandingDebt() > marketDebtBefore
        ) {
            optimizerShareDebtSurfaceMovedValue = true;
        }
    }

    function _assertPostActionInvariants() internal view {
        uint256 borrowerShareBalance = shareCToken.balanceOf(borrower);
        uint256 borrowerPosted = shareCToken.collateralPosted(borrower);
        uint256 shareTokenSupply = shareCToken.totalSupply();
        uint256 shareTokenAssets = shareCToken.totalAssets();
        uint256 shareTokenUnderlyingHeld =
            optimizer.balanceOf(address(shareCToken));
        uint256 optimizerSupply = optimizer.totalSupply();
        uint256 optimizerTrackedAssets = optimizer.totalAssets();
        assertFalse(
            badOracleBorrowMovedValue,
            "POST ACTION: bad oracle borrow moved value"
        );
        assertFalse(
            badOracleCollateralMovedValue,
            "POST ACTION: bad oracle collateral moved value"
        );
        assertFalse(
            optimizerShareDebtSurfaceMovedValue,
            "POST ACTION: optimizer share debt surface moved value"
        );

        assertEq(
            shareCToken.debtBalance(borrower),
            0,
            "POST ACTION: optimizer share borrower debt"
        );
        assertEq(
            shareCToken.marketOutstandingDebt(),
            0,
            "POST ACTION: optimizer share market debt"
        );
        assertLe(
            borrowerPosted,
            borrowerShareBalance,
            "POST ACTION: posted collateral exceeds share balance"
        );
        assertEq(
            shareCToken.marketCollateralPosted(),
            borrowerPosted,
            "POST ACTION: market collateral differs from borrower collateral"
        );
        assertLe(
            shareCToken.marketCollateralPosted(),
            shareTokenSupply,
            "POST ACTION: market collateral exceeds supply"
        );
        assertEq(
            shareTokenUnderlyingHeld,
            shareTokenAssets,
            "POST ACTION: share cToken assets differ from underlying held"
        );
        assertEq(
            shareCToken.asset(),
            address(optimizer),
            "POST ACTION: share cToken asset drift"
        );
        assertEq(
            debtCToken.asset(),
            address(usdc),
            "POST ACTION: debt cToken asset drift"
        );
        assertEq(
            optimizer.asset(),
            address(usdc),
            "POST ACTION: optimizer asset drift"
        );

        uint256 knownShareCTokenBalances = shareCToken.balanceOf(address(0))
            + borrowerShareBalance + shareCToken.balanceOf(receiver)
            + shareCToken.balanceOf(address(this));
        assertEq(
            knownShareCTokenBalances,
            shareTokenSupply,
            "POST ACTION: supply differs from known share holders"
        );

        uint256 knownOptimizerBalances = optimizer.balanceOf(address(0))
            + optimizer.balanceOf(optimizerSeedHolder)
            + optimizer.balanceOf(borrower) + optimizer.balanceOf(receiver)
            + optimizer.balanceOf(address(this)) + shareTokenUnderlyingHeld;
        assertEq(
            knownOptimizerBalances,
            optimizerSupply,
            "POST ACTION: optimizer supply differs from known holders"
        );
        assertLe(
            optimizerTrackedAssets,
            _sumOptimizerApprovedMarketAssets(),
            "POST ACTION: optimizer assets exceed approved markets"
        );
    }

    function _shareSnapshot()
        internal
        returns (ShareSnapshot memory snapshot)
    {
        try shareCToken.accrueIfNeeded() {} catch {}
        snapshot.borrowerBalance = shareCToken.balanceOf(borrower);
        snapshot.receiverBalance = shareCToken.balanceOf(receiver);
        snapshot.handlerBalance = shareCToken.balanceOf(address(this));
        snapshot.borrowerPosted = shareCToken.collateralPosted(borrower);
        snapshot.marketCollateral = shareCToken.marketCollateralPosted();
        snapshot.totalSupply = shareCToken.totalSupply();
        snapshot.totalAssets = shareCToken.totalAssets();
        snapshot.underlyingHeld = optimizer.balanceOf(address(shareCToken));
        snapshot.borrowerOptimizer = optimizer.balanceOf(borrower);
        snapshot.receiverOptimizer = optimizer.balanceOf(receiver);
        snapshot.handlerOptimizer = optimizer.balanceOf(address(this));
    }

    function _assertShareDepositDelta(
        ShareSnapshot memory beforeAction,
        uint256 wrapperShares,
        uint256 optimizerShares,
        bool posted
    ) internal view {
        assertEq(
            shareCToken.balanceOf(borrower),
            beforeAction.borrowerBalance + wrapperShares,
            "POST SHARE DEPOSIT: borrower balance delta"
        );
        assertEq(
            shareCToken.totalSupply(),
            beforeAction.totalSupply + wrapperShares,
            "POST SHARE DEPOSIT: supply delta"
        );
        assertEq(
            shareCToken.totalAssets(),
            beforeAction.totalAssets + optimizerShares,
            "POST SHARE DEPOSIT: totalAssets delta"
        );
        assertEq(
            optimizer.balanceOf(address(shareCToken)),
            beforeAction.underlyingHeld + optimizerShares,
            "POST SHARE DEPOSIT: underlying held delta"
        );

        if (posted) {
            assertEq(
                shareCToken.collateralPosted(borrower),
                beforeAction.borrowerPosted + wrapperShares,
                "POST SHARE DEPOSIT: borrower posted delta"
            );
            assertEq(
                shareCToken.marketCollateralPosted(),
                beforeAction.marketCollateral + wrapperShares,
                "POST SHARE DEPOSIT: market collateral delta"
            );
        } else {
            assertEq(
                shareCToken.collateralPosted(borrower),
                beforeAction.borrowerPosted,
                "POST SHARE DEPOSIT: borrower posted unchanged"
            );
            assertEq(
                shareCToken.marketCollateralPosted(),
                beforeAction.marketCollateral,
                "POST SHARE DEPOSIT: market collateral unchanged"
            );
        }
    }

    function _assertPostCollateralDelta(
        ShareSnapshot memory beforeAction,
        uint256 shares
    ) internal view {
        assertEq(
            shareCToken.balanceOf(borrower),
            beforeAction.borrowerBalance,
            "POST COLLATERAL: borrower balance changed"
        );
        assertEq(
            shareCToken.collateralPosted(borrower),
            beforeAction.borrowerPosted + shares,
            "POST COLLATERAL: borrower posted delta"
        );
        assertEq(
            shareCToken.marketCollateralPosted(),
            beforeAction.marketCollateral + shares,
            "POST COLLATERAL: market collateral delta"
        );
        assertEq(
            shareCToken.totalSupply(),
            beforeAction.totalSupply,
            "POST COLLATERAL: supply changed"
        );
        assertEq(
            shareCToken.totalAssets(),
            beforeAction.totalAssets,
            "POST COLLATERAL: totalAssets changed"
        );
    }

    function _assertRemoveCollateralDelta(
        ShareSnapshot memory beforeAction,
        uint256 shares
    ) internal view {
        assertEq(
            shareCToken.balanceOf(borrower),
            beforeAction.borrowerBalance,
            "POST REMOVE COLLATERAL: borrower balance changed"
        );
        assertEq(
            shareCToken.collateralPosted(borrower),
            beforeAction.borrowerPosted - shares,
            "POST REMOVE COLLATERAL: borrower posted delta"
        );
        assertEq(
            shareCToken.marketCollateralPosted(),
            beforeAction.marketCollateral - shares,
            "POST REMOVE COLLATERAL: market collateral delta"
        );
        assertEq(
            shareCToken.totalSupply(),
            beforeAction.totalSupply,
            "POST REMOVE COLLATERAL: supply changed"
        );
        assertEq(
            shareCToken.totalAssets(),
            beforeAction.totalAssets,
            "POST REMOVE COLLATERAL: totalAssets changed"
        );
    }

    function _assertShareWithdrawalDelta(
        ShareSnapshot memory beforeAction,
        uint256 shares,
        uint256 assets,
        address optimizerReceiver,
        bool forceRedeemCollateral
    ) internal view {
        uint256 collateralRedeemed =
            _expectedCollateralRedeemed(
                beforeAction, shares, forceRedeemCollateral
            );

        assertEq(
            shareCToken.balanceOf(borrower),
            beforeAction.borrowerBalance - shares,
            "POST SHARE WITHDRAW: borrower balance delta"
        );
        assertEq(
            shareCToken.collateralPosted(borrower),
            beforeAction.borrowerPosted - collateralRedeemed,
            "POST SHARE WITHDRAW: borrower posted delta"
        );
        assertEq(
            shareCToken.marketCollateralPosted(),
            beforeAction.marketCollateral - collateralRedeemed,
            "POST SHARE WITHDRAW: market collateral delta"
        );
        assertEq(
            shareCToken.totalSupply(),
            beforeAction.totalSupply - shares,
            "POST SHARE WITHDRAW: supply delta"
        );
        assertEq(
            shareCToken.totalAssets(),
            beforeAction.totalAssets - assets,
            "POST SHARE WITHDRAW: totalAssets delta"
        );
        assertEq(
            optimizer.balanceOf(address(shareCToken)),
            beforeAction.underlyingHeld - assets,
            "POST SHARE WITHDRAW: underlying held delta"
        );

        if (optimizerReceiver == receiver) {
            assertEq(
                optimizer.balanceOf(receiver),
                beforeAction.receiverOptimizer + assets,
                "POST SHARE WITHDRAW: receiver optimizer delta"
            );
            assertEq(
                optimizer.balanceOf(address(this)),
                beforeAction.handlerOptimizer,
                "POST SHARE WITHDRAW: handler optimizer changed"
            );
        } else {
            assertEq(
                optimizer.balanceOf(address(this)),
                beforeAction.handlerOptimizer + assets,
                "POST SHARE WITHDRAW: handler optimizer delta"
            );
            assertEq(
                optimizer.balanceOf(receiver),
                beforeAction.receiverOptimizer,
                "POST SHARE WITHDRAW: receiver optimizer changed"
            );
        }
        assertEq(
            optimizer.balanceOf(borrower),
            beforeAction.borrowerOptimizer,
            "POST SHARE WITHDRAW: borrower optimizer changed"
        );
    }

    function _assertShareTransferDelta(
        ShareSnapshot memory beforeAction,
        uint256 shares,
        bool delegated
    ) internal view {
        uint256 collateralRedeemed = _expectedCollateralRedeemed(
            beforeAction, shares, false
        );

        assertEq(
            shareCToken.balanceOf(borrower),
            beforeAction.borrowerBalance - shares,
            "POST SHARE TRANSFER: borrower balance delta"
        );
        assertEq(
            shareCToken.balanceOf(receiver),
            beforeAction.receiverBalance + shares,
            "POST SHARE TRANSFER: receiver balance delta"
        );
        assertEq(
            shareCToken.collateralPosted(borrower),
            beforeAction.borrowerPosted - collateralRedeemed,
            "POST SHARE TRANSFER: borrower posted delta"
        );
        assertEq(
            shareCToken.marketCollateralPosted(),
            beforeAction.marketCollateral - collateralRedeemed,
            "POST SHARE TRANSFER: market collateral delta"
        );
        assertEq(
            shareCToken.totalSupply(),
            beforeAction.totalSupply,
            "POST SHARE TRANSFER: supply changed"
        );
        assertEq(
            shareCToken.totalAssets(),
            beforeAction.totalAssets,
            "POST SHARE TRANSFER: totalAssets changed"
        );
        assertEq(
            optimizer.balanceOf(address(shareCToken)),
            beforeAction.underlyingHeld,
            "POST SHARE TRANSFER: underlying held changed"
        );
        if (delegated) {
            assertEq(
                shareCToken.allowance(borrower, address(this)),
                0,
                "POST SHARE TRANSFER: allowance delta"
            );
        }
    }

    function _expectedCollateralRedeemed(
        ShareSnapshot memory beforeAction,
        uint256 shares,
        bool forceRedeemCollateral
    ) internal pure returns (uint256) {
        if (forceRedeemCollateral) return shares;
        if (
            beforeAction.borrowerPosted + shares
                >= beforeAction.borrowerBalance
        ) {
            return beforeAction.borrowerPosted + shares
                - beforeAction.borrowerBalance;
        }
        return 0;
    }

    function _attemptBorrow(uint256 assets, bool delegated) internal {
        assets = bound(assets, 10e6, 500e6);
        borrowAttempts++;
        _syncOracles();
        try debtCToken.accrueIfNeeded() {} catch {}

        bool badOracle = _badOracle();
        if (badOracle) badOracleBorrowAttempts++;

        address selectedReceiver = assets % 2 == 0 ? receiver : borrower;
        uint256 borrowerBalanceBefore = usdc.balanceOf(borrower);
        uint256 receiverBalanceBefore = usdc.balanceOf(receiver);
        uint256 debtBefore = debtCToken.debtBalance(borrower);
        uint256 marketDebtBefore = debtCToken.marketOutstandingDebt();

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

        uint256 borrowerBalanceAfter = usdc.balanceOf(borrower);
        uint256 receiverBalanceAfter = usdc.balanceOf(receiver);
        uint256 debtAfter = debtCToken.debtBalance(borrower);
        uint256 marketDebtAfter = debtCToken.marketOutstandingDebt();

        if (badOracle) {
            if (
                success || borrowerBalanceAfter > borrowerBalanceBefore
                    || receiverBalanceAfter > receiverBalanceBefore
                    || debtAfter > debtBefore
                    || marketDebtAfter > marketDebtBefore
            ) {
                badOracleBorrowMovedValue = true;
            }
            return;
        }

        if (success) {
            successfulBorrows++;
            assertEq(
                debtAfter,
                debtBefore + assets,
                "POST BORROW: borrower debt delta"
            );
            assertEq(
                marketDebtAfter,
                marketDebtBefore + assets,
                "POST BORROW: market debt delta"
            );
            if (selectedReceiver == borrower) {
                assertEq(
                    borrowerBalanceAfter,
                    borrowerBalanceBefore + assets,
                    "POST BORROW: borrower cash delta"
                );
                assertEq(
                    receiverBalanceAfter,
                    receiverBalanceBefore,
                    "POST BORROW: receiver cash unchanged"
                );
            } else {
                assertEq(
                    receiverBalanceAfter,
                    receiverBalanceBefore + assets,
                    "POST BORROW: receiver cash delta"
                );
                assertEq(
                    borrowerBalanceAfter,
                    borrowerBalanceBefore,
                    "POST BORROW: borrower cash unchanged"
                );
            }
        }
    }

    function _attemptBorrowForPositionManager(uint256 assets) internal {
        assets = bound(assets, 10e6, 500e6);
        borrowAttempts++;
        _syncOracles();
        try debtCToken.accrueIfNeeded() {} catch {}

        bool badOracle = _badOracle();
        if (badOracle) badOracleBorrowAttempts++;

        uint256 borrowerBalanceBefore = usdc.balanceOf(borrower);
        uint256 receiverBalanceBefore = usdc.balanceOf(receiver);
        uint256 handlerBalanceBefore = usdc.balanceOf(address(this));
        uint256 debtBefore = debtCToken.debtBalance(borrower);
        uint256 marketDebtBefore = debtCToken.marketOutstandingDebt();

        bool success;
        try debtCToken.borrowForPositionManager(
            assets, borrower, _emptyLeverageAction(assets)
        ) {
            success = true;
        } catch {}

        uint256 borrowerBalanceAfter = usdc.balanceOf(borrower);
        uint256 receiverBalanceAfter = usdc.balanceOf(receiver);
        uint256 handlerBalanceAfter = usdc.balanceOf(address(this));
        uint256 debtAfter = debtCToken.debtBalance(borrower);
        uint256 marketDebtAfter = debtCToken.marketOutstandingDebt();

        if (badOracle) {
            if (
                success || borrowerBalanceAfter > borrowerBalanceBefore
                    || receiverBalanceAfter > receiverBalanceBefore
                    || handlerBalanceAfter > handlerBalanceBefore
                    || debtAfter > debtBefore
                    || marketDebtAfter > marketDebtBefore
            ) {
                badOracleBorrowMovedValue = true;
            }
            return;
        }

        if (success) {
            successfulBorrows++;
            assertEq(
                debtAfter,
                debtBefore + assets,
                "POST PM BORROW: borrower debt delta"
            );
            assertEq(
                marketDebtAfter,
                marketDebtBefore + assets,
                "POST PM BORROW: market debt delta"
            );
            assertEq(
                handlerBalanceAfter,
                handlerBalanceBefore + assets,
                "POST PM BORROW: handler cash delta"
            );
            assertEq(
                borrowerBalanceAfter,
                borrowerBalanceBefore,
                "POST PM BORROW: borrower cash unchanged"
            );
            assertEq(
                receiverBalanceAfter,
                receiverBalanceBefore,
                "POST PM BORROW: receiver cash unchanged"
            );
        }
    }

    function _redeemOptimizerCollateral(uint256 sharesSeed, bool delegated)
        internal
    {
        uint256 posted = shareCToken.collateralPosted(borrower);
        if (posted == 0) return;

        _syncOracles();
        try debtCToken.accrueIfNeeded() {} catch {}

        uint256 shares = bound(sharesSeed, 1, posted);

        (
            uint256 debtBefore,
            uint256 postedBefore,
            uint256 borrowerOptimizerBefore,
            uint256 receiverOptimizerBefore,
            uint256 handlerOptimizerBefore
        ) = _collateralSnapshot();
        collateralRemovalAttempts++;

        ShareSnapshot memory beforeAction = _shareSnapshot();
        if (delegated) {
            vm.prank(borrower);
            shareCToken.setDelegateApproval(address(this), true);
            try shareCToken.redeemCollateralFor(
                shares, receiver, borrower
            ) returns (
                uint256 assets
            ) {
                _assertShareWithdrawalDelta(
                    beforeAction, shares, assets, receiver, true
                );
            } catch {}
        } else {
            vm.prank(borrower);
            try shareCToken.redeemCollateral(
                shares, receiver, borrower
            ) returns (
                uint256 assets
            ) {
                _assertShareWithdrawalDelta(
                    beforeAction, shares, assets, receiver, true
                );
            } catch {}
        }

        _flagBadOracleCollateralMovement(
            debtBefore,
            postedBefore,
            borrowerOptimizerBefore,
            receiverOptimizerBefore,
            handlerOptimizerBefore
        );
    }

    function _transferOptimizerShareCTokens(uint256 sharesSeed, bool delegated)
        internal
    {
        uint256 balance = shareCToken.balanceOf(borrower);
        if (balance == 0) return;

        _syncOracles();
        try debtCToken.accrueIfNeeded() {} catch {}

        uint256 shares = bound(sharesSeed, 1, balance);

        (
            uint256 debtBefore,
            uint256 postedBefore,
            uint256 borrowerOptimizerBefore,
            uint256 receiverOptimizerBefore,
            uint256 handlerOptimizerBefore
        ) = _collateralSnapshot();

        ShareSnapshot memory beforeAction = _shareSnapshot();
        if (delegated) {
            vm.prank(borrower);
            shareCToken.approve(address(this), shares);
            try shareCToken.transferFrom(borrower, receiver, shares) returns (
                bool
            ) {
                _assertShareTransferDelta(beforeAction, shares, true);
            } catch {}
        } else {
            vm.prank(borrower);
            try shareCToken.transfer(receiver, shares) returns (bool) {
                _assertShareTransferDelta(beforeAction, shares, false);
            } catch {}
        }

        _flagBadOracleCollateralMovement(
            debtBefore,
            postedBefore,
            borrowerOptimizerBefore,
            receiverOptimizerBefore,
            handlerOptimizerBefore
        );
    }

    function _collateralSnapshot()
        internal
        view
        returns (
            uint256 debtBefore,
            uint256 postedBefore,
            uint256 borrowerOptimizerBefore,
            uint256 receiverOptimizerBefore,
            uint256 handlerOptimizerBefore
        )
    {
        debtBefore = debtCToken.debtBalance(borrower);
        postedBefore = shareCToken.collateralPosted(borrower);
        borrowerOptimizerBefore = optimizer.balanceOf(borrower);
        receiverOptimizerBefore = optimizer.balanceOf(receiver);
        handlerOptimizerBefore = optimizer.balanceOf(address(this));
    }

    function _flagBadOracleCollateralMovement(
        uint256 debtBefore,
        uint256 postedBefore,
        uint256 borrowerOptimizerBefore,
        uint256 receiverOptimizerBefore,
        uint256 handlerOptimizerBefore
    ) internal {
        if (!_badOracle() || debtBefore == 0) {
            return;
        }

        if (shareCToken.collateralPosted(borrower) < postedBefore) {
            badOracleCollateralMovedValue = true;
        }
    }

    function _mintOptimizerSharesFor(address account, uint256 assets)
        internal
        returns (uint256 optimizerShares)
    {
        deal(address(usdc), account, assets);

        vm.startPrank(account);
        usdc.approve(address(optimizer), assets);
        try optimizer.deposit(assets, account) returns (uint256 shares) {
            optimizerShares = shares;
        } catch {}
        vm.stopPrank();
    }

    function _emptyLeverageAction(uint256 assets)
        internal
        view
        returns (IPositionManager.LeverageAction memory action)
    {
        action.borrowableCToken = IBorrowableCToken(address(debtCToken));
        action.borrowAssets = assets;
        action.cToken = ICToken(address(shareCToken));
    }

    function _emptyDeleverageAction(uint256 assets)
        internal
        view
        returns (IPositionManager.DeleverageAction memory action)
    {
        action.cToken = ICToken(address(shareCToken));
        action.collateralAssets = assets;
        action.borrowableCToken = IBorrowableCToken(address(debtCToken));
    }

    function _sumOptimizerApprovedMarketAssets()
        internal
        view
        returns (uint256 sumMarkets)
    {
        uint256 numMarkets = optimizer.numApprovedMarkets();
        for (uint256 i; i < numMarkets; ++i) {
            address market = optimizer.approvedCTokensList(i);
            sumMarkets += IBorrowableCToken(market)
                .convertToAssets(
                    IBorrowableCToken(market).balanceOf(address(optimizer))
                );
        }
    }

    function _badOracle() internal view returns (bool) {
        return debtOracleMode != OracleMode.Normal
            || optimizerOracleMode != OracleMode.Normal;
    }

    function _syncOracles() internal {
        _syncFeed(debtFeed, debtOracleMode, 1e8);
        _syncFeed(optimizerFeed, optimizerOracleMode, 1e8);
    }

    function _syncFeed(
        MockV3Aggregator feed,
        OracleMode mode,
        int256 normalAnswer
    ) internal {
        if (mode == OracleMode.Normal) {
            feed.updateAnswer(normalAnswer);
        } else if (mode == OracleMode.Stale) {
            uint256 staleTimestamp = block.timestamp > heartbeat + 1
                ? block.timestamp - heartbeat - 1
                : 1;
            feed.updateRoundData(
                uint80(feed.latestRound() + 1),
                normalAnswer,
                staleTimestamp,
                staleTimestamp
            );
        } else {
            feed.updateAnswer(0);
        }
    }

    function _unconstrainedBounds()
        internal
        view
        returns (LendingOptimizer.AllocationBound[] memory bounds)
    {
        uint256 l = optimizer.numApprovedMarkets();
        bounds = new LendingOptimizer.AllocationBound[](l);
        for (uint256 i; i < l; ++i) {
            bounds[i] = LendingOptimizer.AllocationBound({
                cToken: optimizer.approvedCTokensList(i),
                minBps: 0,
                maxBps: 10000
            });
        }
    }

    function _mockHarvestPermissions(address caller) internal {
        vm.mockCall(
            address(centralRegistry),
            abi.encodeWithSelector(
                ICentralRegistry.hasHarvestPermissions.selector, caller
            ),
            abi.encode(true)
        );
    }

    function onBorrow(
        address,
        uint256,
        address,
        IPositionManager.LeverageAction memory
    ) external override {
        // No-op PM callback: the terminal market liquidity check is the property.
    }

    function onRedeem(
        address,
        uint256,
        address,
        IPositionManager.DeleverageAction memory
    ) external override {
        // No-op PM callback: unsafe redemptions must revert after this callback.
    }

    function supportsInterface(bytes4 interfaceId)
        external
        pure
        returns (bool)
    {
        return interfaceId == 0x01ffc9a7
            || interfaceId == type(IPositionManager).interfaceId;
    }
}
