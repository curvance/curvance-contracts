// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {
    LendingOptimizer
} from "contracts/market/optimizer/LendingOptimizer.sol";
import {
    LendingOptimizerShareCToken
} from "contracts/market/token/LendingOptimizerShareCToken.sol";
import {BaseCToken} from "contracts/market/token/BaseCToken.sol";
import {BorrowableCToken} from "contracts/market/token/BorrowableCToken.sol";
import {SimpleCToken} from "contracts/market/token/SimpleCToken.sol";
import {DynamicIRM} from "contracts/market/DynamicIRM.sol";
import {
    MarketManagerIsolated
} from "contracts/market/isolated/MarketManagerIsolated.sol";
import {
    LiquidityManagerIsolated
} from "contracts/market/isolated/LiquidityManagerIsolated.sol";
import {OracleManager} from "contracts/oracles/OracleManager.sol";
import {
    ChainlinkAdaptor
} from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import {
    VaultAggregator
} from "contracts/oracles/adaptors/wrappedAggregators/VaultAggregator.sol";
import {
    UniswapV3Adaptor
} from "contracts/oracles/adaptors/uniswap/UniswapV3Adaptor.sol";
import {
    PendleLPTokenAdaptor
} from "contracts/oracles/adaptors/pendle/PendleLPTokenAdaptor.sol";
import {
    PendlePrincipalTokenAdaptor
} from "contracts/oracles/adaptors/pendle/PendlePrincipalTokenAdaptor.sol";
import {
    BaseVolatileLPAdaptor
} from "contracts/oracles/adaptors/stableswapBase/BaseVolatileLPAdaptor.sol";
import {
    BaseStableLPAdaptor
} from "contracts/oracles/adaptors/stableswapBase/BaseStableLPAdaptor.sol";
import {RiskReader} from "contracts/views/RiskReader.sol";
import {
    BAD_SOURCE,
    BPS,
    CAUTION,
    NO_ERROR,
    WAD
} from "contracts/libraries/ConstantsLib.sol";
import {Multicall} from "contracts/libraries/Multicall.sol";
import "contracts/libraries/external/pendle/MarketMathCore.sol";
import {
    FixedPointMathLib
} from "contracts/libraries/external/FixedPointMathLib.sol";
import {SwapperLib} from "contracts/libraries/SwapperLib.sol";
import {PluginDelegable} from "contracts/libraries/PluginDelegable.sol";
import {
    BasePositionManager
} from "contracts/market/position-management/BasePositionManager.sol";
import {
    SimplePositionManager
} from "contracts/market/position-management/SimplePositionManager.sol";
import {
    SingleSidedVaultPositionManager
} from "contracts/market/position-management/SingleSidedVaultPositionManager.sol";
import {
    DualSidedVaultPositionManager
} from "contracts/market/position-management/DualSidedVaultPositionManager.sol";
import {BaseZapper} from "contracts/plugins/BaseZapper.sol";
import {SimpleZapper} from "contracts/plugins/market/SimpleZapper.sol";
import {OptimizerZapper} from "contracts/plugins/market/OptimizerZapper.sol";
import {VaultZapper} from "contracts/plugins/market/VaultZapper.sol";
import {
    CCTPBorrowZapper
} from "contracts/plugins/market/crosschain/CCTPBorrowZapper.sol";
import {FeeManager} from "contracts/architecture/FeeManager.sol";
import {UniversalBalance} from "contracts/architecture/UniversalBalance.sol";
import {
    NativeUniversalBalance
} from "contracts/architecture/NativeUniversalBalance.sol";
import {LBP} from "contracts/misc/LBP.sol";
import {
    SimpleRewardZapper
} from "contracts/plugins/rewards/SimpleRewardZapper.sol";
import {ProtocolReader} from "contracts/views/ProtocolReader.sol";
import {
    ICentralRegistry,
    ChainConfig
} from "contracts/interfaces/ICentralRegistry.sol";
import {IBorrowableCToken} from "contracts/interfaces/IBorrowableCToken.sol";
import {ICToken, AccountSnapshot} from "contracts/interfaces/ICToken.sol";
import {ILendingOptimizer} from "contracts/interfaces/ILendingOptimizer.sol";
import {IMarketManager} from "contracts/interfaces/IMarketManager.sol";
import {IOracleAdaptor} from "contracts/interfaces/IOracleAdaptor.sol";
import {IERC165} from "contracts/interfaces/IERC165.sol";
import {IPositionManager} from "contracts/interfaces/IPositionManager.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {
    IChainlink
} from "contracts/interfaces/external/chainlink/IChainlink.sol";
import {IPMarket} from "contracts/interfaces/external/pendle/IPMarket.sol";
import {
    IPendlePTOracle
} from "contracts/interfaces/external/pendle/IPendlePtOracle.sol";
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
    IStaticOracle
} from "contracts/interfaces/external/uniswap/IStaticOracle.sol";
import {
    IVeloPool
} from "contracts/interfaces/external/velodrome/IVeloPool.sol";
import {
    ITokenMessenger
} from "contracts/interfaces/external/wormhole/ITokenMessenger.sol";
import {
    IWormholeRelayer
} from "contracts/interfaces/external/wormhole/IWormholeRelayer.sol";
import {IWormhole} from "contracts/interfaces/external/wormhole/IWormhole.sol";
import {ERC20} from "contracts/libraries/external/ERC20.sol";
import {MockCalldataChecker} from "contracts/mocks/MockCalldataChecker.sol";
import {MockV3Aggregator} from "contracts/mocks/MockV3Aggregator.sol";
import {CentralRegistry} from "contracts/architecture/CentralRegistry.sol";
import {
    VerifyOptimizerShareLaunch
} from "script/deployment/VerifyOptimizerShareLaunch.s.sol";
import {MockERC20} from "tests/libraries/utils/mocks/MockERC20.sol";

import {LendingOptimizerHarness} from "./LendingOptimizerHarness.sol";
import {TestBaseLendingOptimizer} from "./TestBaseLendingOptimizer.sol";

contract TestLendingOptimizerShareCToken is TestBaseLendingOptimizer {
    LendingOptimizerShareCToken internal optimizerCToken;

    struct UnderEncodedDualSidedVaultFixture {
        MarketManagerIsolated optimizerMarket;
        BorrowableCToken debtCToken;
        LendingOptimizerShareCToken shareCToken;
        MockERC20 debtAsset;
        DualSidedVaultPositionManager positionManager;
        OptimizerShareSwapTarget swapTarget;
        address account;
        uint256 collateralBefore;
        uint256 debtBefore;
        uint256 staleTotalAssets;
    }

    struct PlainNestedWrapperDebtRepayFixture {
        MarketManagerIsolated market;
        BorrowableCToken debtCToken;
        address borrower;
        address repayer;
        uint256 repayShares;
        uint256 staleDebtPrice;
        uint256 debtUnit;
        uint256 minLoanSize;
    }

    function setUp() public override {
        super.setUp();
        _setUpOneMarket();

        DynamicIRM irm = _deployOptimizerCTokenIRM();
        optimizerCToken = new LendingOptimizerShareCToken(
            liveCentralRegistry,
            ILendingOptimizer(address(optimizer)),
            _marketMgrs[cUSDC_WMON_MARKET],
            address(irm)
        );
        irm.setLinkedToken(address(optimizerCToken));
        _initializeOptimizerCToken();
    }

    function test_lendingOptimizerShareCToken_symbolsStayReadable() public {
        assertEq(optimizer.symbol(), "FlagUSDC");
        assertEq(optimizerCToken.symbol(), "cFlagUSDC");
        assertEq(optimizerCToken.asset(), address(optimizer));
        assertTrue(
            optimizerCToken.isBorrowable(),
            "DynamicIRM requires borrowable identity"
        );
        assertEq(
            optimizerCToken.marketOutstandingDebt(),
            0,
            "wrapper debt must start at zero"
        );
    }

    function test_lendingOptimizerShareCToken_optimizerSupportsInterface()
        public
        view
    {
        assertTrue(
            optimizer.supportsInterface(type(ILendingOptimizer).interfaceId)
        );
        assertTrue(
            optimizerCToken.supportsInterface(type(ICToken).interfaceId)
        );
    }

    function test_lendingOptimizerShareCToken_rejectsNonOptimizerAsset()
        public
    {
        MockERC20 fakeOptimizer = new MockERC20("Fake Optimizer", "fOPT", 6);
        DynamicIRM irm = _deployOptimizerCTokenIRM();

        vm.expectRevert(
            LendingOptimizerShareCToken.LendingOptimizerShareCToken__InvalidOptimizer
                .selector
        );
        new LendingOptimizerShareCToken(
            liveCentralRegistry,
            ILendingOptimizer(address(fakeOptimizer)),
            _marketMgrs[cUSDC_WMON_MARKET],
            address(irm)
        );
    }

    function test_lendingOptimizerShareCToken_rejectsERC165OptimizerWithZeroAsset()
        public
    {
        MockInvalidLendingOptimizer fakeOptimizer = new MockInvalidLendingOptimizer(
            liveCentralRegistry, address(0), _singleFakeMarket()
        );
        DynamicIRM irm = _deployOptimizerCTokenIRM();

        vm.expectRevert(
            LendingOptimizerShareCToken.LendingOptimizerShareCToken__InvalidOptimizer
                .selector
        );
        new LendingOptimizerShareCToken(
            liveCentralRegistry,
            ILendingOptimizer(address(fakeOptimizer)),
            _marketMgrs[cUSDC_WMON_MARKET],
            address(irm)
        );
    }

    function test_lendingOptimizerShareCToken_rejectsERC165OptimizerWithNoApprovedMarkets()
        public
    {
        MockInvalidLendingOptimizer fakeOptimizer = new MockInvalidLendingOptimizer(
            liveCentralRegistry, USDC_MONAD, new address[](0)
        );
        DynamicIRM irm = _deployOptimizerCTokenIRM();

        vm.expectRevert(
            LendingOptimizerShareCToken.LendingOptimizerShareCToken__InvalidOptimizer
                .selector
        );
        new LendingOptimizerShareCToken(
            liveCentralRegistry,
            ILendingOptimizer(address(fakeOptimizer)),
            _marketMgrs[cUSDC_WMON_MARKET],
            address(irm)
        );
    }

    function test_lendingOptimizerShareCToken_rejectsERC165OptimizerFromDifferentRegistry()
        public
    {
        MockInvalidLendingOptimizer fakeOptimizer = new MockInvalidLendingOptimizer(
            ICentralRegistry(makeAddr("wrongCentralRegistry")),
            USDC_MONAD,
            _singleFakeMarket()
        );
        DynamicIRM irm = _deployOptimizerCTokenIRM();

        vm.expectRevert(
            LendingOptimizerShareCToken.LendingOptimizerShareCToken__InvalidOptimizer
                .selector
        );
        new LendingOptimizerShareCToken(
            liveCentralRegistry,
            ILendingOptimizer(address(fakeOptimizer)),
            _marketMgrs[cUSDC_WMON_MARKET],
            address(irm)
        );
    }

    function test_lendingOptimizerShareCToken_dynamicIRMAcceptsBorrowableIdentity()
        public
    {
        DynamicIRM irm = DynamicIRM(address(optimizerCToken.IRM()));

        assertEq(irm.linkedToken(), address(optimizerCToken));
        assertTrue(
            optimizerCToken.isBorrowable(),
            "wrapper must remain DynamicIRM-compatible"
        );
    }

    function test_lendingOptimizerShareCToken_snapshotHasBorrowableIdentityWithoutDebt()
        public
    {
        uint256 assetsBefore = _depositAndSkipForOptimizerYield();

        AccountSnapshot memory snapshot =
            optimizerCToken.getSnapshotUpdated(address(this));

        assertGt(
            optimizer.totalAssets(),
            assetsBefore,
            "snapshot path must sync optimizer NAV"
        );
        assertEq(snapshot.asset, address(optimizerCToken));
        assertEq(snapshot.underlying, address(optimizer));
        assertEq(snapshot.decimals, optimizerCToken.decimals());
        assertTrue(
            snapshot.isCollateral,
            "zero-debt wrapper snapshot remains collateral-eligible"
        );
        assertEq(snapshot.collateralPosted, 0);
        assertEq(snapshot.debtBalance, 0, "share wrapper must not report debt");
    }

    function test_lendingOptimizerShareCToken_accrueIfNeededAccruesOptimizerAndParent()
        public
    {
        uint256 assetsBefore = _depositAndSkipForOptimizerYield();
        (,, uint256 lastVestingClaimBefore,) =
            optimizerCToken.getYieldInformation();

        optimizerCToken.accrueIfNeeded();

        assertGt(
            optimizer.totalAssets(),
            assetsBefore,
            "direct accrue must sync optimizer NAV"
        );
        (,, uint256 lastVestingClaimAfter,) =
            optimizerCToken.getYieldInformation();
        assertGt(
            lastVestingClaimAfter,
            lastVestingClaimBefore,
            "direct accrue must run parent cToken accrual"
        );
        assertEq(
            lastVestingClaimAfter, block.timestamp, "parent accrual timestamp"
        );
    }

    function test_lendingOptimizerShareCToken_getSnapshotUpdatedAccruesOptimizer()
        public
    {
        uint256 assetsBefore = _depositAndSkipForOptimizerYield();

        optimizerCToken.getSnapshotUpdated(address(this));

        assertGt(
            optimizer.totalAssets(),
            assetsBefore,
            "snapshot path must sync optimizer NAV"
        );
    }

    function test_lendingOptimizerShareCToken_exchangeRateUpdatedAccruesOptimizer()
        public
    {
        uint256 assetsBefore = _depositAndSkipForOptimizerYield();
        (,, uint256 lastVestingClaimBefore,) =
            optimizerCToken.getYieldInformation();

        optimizerCToken.exchangeRateUpdated();

        assertGt(
            optimizer.totalAssets(),
            assetsBefore,
            "liquidation pricing path must sync optimizer NAV"
        );
        (,, uint256 lastVestingClaimAfter,) =
            optimizerCToken.getYieldInformation();
        assertGt(
            lastVestingClaimAfter,
            lastVestingClaimBefore,
            "wrapper parent accrual must run"
        );
        assertEq(
            lastVestingClaimAfter,
            block.timestamp,
            "wrapper parent accrual timestamp"
        );
    }

    function test_lendingOptimizerShareCToken_isolatedPairPricingAccruesOptimizerBeforeVaultAggregator()
        public
    {
        uint256 assetsBefore = _depositIntoWrapperAndSkipForOptimizerYield();
        _registerOptimizerShareVaultPriceFeed();
        _refreshUsdcPriceFeed();
        _oracleManager.addCTokenSupport(address(optimizerCToken));

        assertEq(
            optimizer.totalAssets(),
            assetsBefore,
            "precondition: optimizer NAV is stale before isolated pricing"
        );
        (uint256 staleOptimizerPrice, uint256 staleErrorCode) =
            _oracleManager.getPrice(address(optimizer), true, true);
        assertEq(staleErrorCode, 0);

        (uint256 collateralSharesPrice, uint256 debtUnderlyingPrice) = _oracleManager.getPriceIsolatedPair(
            address(optimizerCToken), cUSDC_WMON_MARKET, BAD_SOURCE
        );

        assertGt(
            optimizer.totalAssets(),
            assetsBefore,
            "isolated pair path must sync optimizer NAV before pricing"
        );
        (uint256 freshOptimizerPrice, uint256 freshErrorCode) =
            _oracleManager.getPrice(address(optimizer), true, true);
        assertEq(freshErrorCode, 0);
        assertGt(
            freshOptimizerPrice,
            staleOptimizerPrice,
            "fresh VaultAggregator price should include accrued NAV"
        );

        uint256 expectedCollateralSharesPrice = FixedPointMathLib.mulDiv(
            freshOptimizerPrice, optimizerCToken.exchangeRate(), WAD
        );
        assertEq(collateralSharesPrice, expectedCollateralSharesPrice);
        assertEq(debtUnderlyingPrice, WAD);
    }

    function test_lendingOptimizerShareCToken_getPricesForMarketAccruesOptimizerBeforeVaultAggregator()
        public
    {
        uint256 assetsBefore =
            _depositWrapperCollateralAndSkipForOptimizerYield();
        _registerOptimizerShareVaultPriceFeed();
        _oracleManager.addCTokenSupport(address(optimizerCToken));

        assertEq(
            optimizer.totalAssets(),
            assetsBefore,
            "precondition: optimizer NAV is stale before market pricing"
        );
        (uint256 staleOptimizerPrice, uint256 staleErrorCode) =
            _oracleManager.getPrice(address(optimizer), true, true);
        assertEq(staleErrorCode, 0);

        address[] memory assets = new address[](1);
        assets[0] = address(optimizerCToken);
        (
            AccountSnapshot[] memory snapshots,
            uint256[] memory prices,
            uint256 numAssets
        ) = _oracleManager.getPricesForMarket(
            address(this), assets, BAD_SOURCE
        );

        assertEq(numAssets, 1);
        assertTrue(
            snapshots[0].isCollateral,
            "wrapper collateral should price in shares"
        );
        assertGt(
            optimizer.totalAssets(),
            assetsBefore,
            "market pricing path must sync optimizer NAV before pricing"
        );

        (uint256 freshOptimizerPrice, uint256 freshErrorCode) =
            _oracleManager.getPrice(address(optimizer), true, true);
        assertEq(freshErrorCode, 0);
        assertGt(
            freshOptimizerPrice,
            staleOptimizerPrice,
            "fresh VaultAggregator price should include accrued NAV"
        );

        uint256 expectedCollateralSharesPrice = FixedPointMathLib.mulDiv(
            freshOptimizerPrice, optimizerCToken.exchangeRate(), WAD
        );
        assertEq(prices[0], expectedCollateralSharesPrice);
    }

    function test_lendingOptimizerShareCToken_directGetPriceOfShareCTokenIsStaleUntilAccrual()
        public
    {
        uint256 assetsBefore = _depositIntoWrapperAndSkipForOptimizerYield();
        _registerOptimizerShareVaultPriceFeed();
        _oracleManager.addCTokenSupport(address(optimizerCToken));

        assertEq(
            optimizer.totalAssets(),
            assetsBefore,
            "precondition: optimizer NAV is stale"
        );
        (uint256 staleShareCTokenPrice, uint256 staleErrorCode) =
            _oracleManager.getPrice(address(optimizerCToken), true, true);
        assertEq(staleErrorCode, 0);
        assertEq(
            optimizer.totalAssets(),
            assetsBefore,
            "direct cToken price read must not accrue optimizer"
        );

        optimizerCToken.exchangeRateUpdated();

        assertGt(
            optimizer.totalAssets(),
            assetsBefore,
            "accrual must refresh optimizer NAV"
        );
        (uint256 freshShareCTokenPrice, uint256 freshErrorCode) =
            _oracleManager.getPrice(address(optimizerCToken), true, true);
        assertEq(freshErrorCode, 0);
        assertGt(
            freshShareCTokenPrice,
            staleShareCTokenPrice,
            "fresh direct price should include accrued optimizer NAV"
        );
    }

    function test_lendingOptimizerShareCToken_directOptimizerVaultFeedIsStaleUntilAccrual()
        public
    {
        uint256 assetsBefore = _depositIntoWrapperAndSkipForOptimizerYield();
        _registerOptimizerShareVaultPriceFeed();

        (bool feedConfigured, IChainlink feed,,) =
            _chainlinkAdaptor.assetConfig(address(optimizer), true);
        assertTrue(feedConfigured, "optimizer share feed must be configured");
        VaultAggregator optimizerVaultFeed = VaultAggregator(address(feed));

        assertEq(
            optimizer.totalAssets(),
            assetsBefore,
            "precondition: optimizer NAV is stale"
        );
        (, int256 staleAnswer,,,) = optimizerVaultFeed.latestRoundData();
        assertEq(
            optimizer.totalAssets(),
            assetsBefore,
            "direct VaultAggregator read must not accrue optimizer"
        );

        optimizer.accrueIfNeeded();

        assertGt(
            optimizer.totalAssets(),
            assetsBefore,
            "explicit accrual must refresh optimizer NAV"
        );
        (, int256 freshAnswer,,,) = optimizerVaultFeed.latestRoundData();
        assertGt(
            freshAnswer,
            staleAnswer,
            "fresh direct feed should include accrued optimizer NAV"
        );
    }

    function test_lendingOptimizerShareCToken_vaultAggregatorRoundDataUsesCurrentOptimizerRate()
        public
    {
        uint256 assetsBefore = _depositIntoWrapperAndSkipForOptimizerYield();
        _registerOptimizerShareVaultPriceFeed();

        (bool feedConfigured, IChainlink feed,,) =
            _chainlinkAdaptor.assetConfig(address(optimizer), true);
        assertTrue(feedConfigured, "optimizer share feed must be configured");
        VaultAggregator optimizerVaultFeed = VaultAggregator(address(feed));

        (uint80 roundId,,,,) = optimizerVaultFeed.latestRoundData();
        (
            uint80 staleRoundId,
            int256 staleAnswer,
            uint256 staleStartedAt,
            uint256 staleUpdatedAt,
            uint80 staleAnsweredInRound
        ) = optimizerVaultFeed.getRoundData(roundId);
        assertEq(
            optimizer.totalAssets(),
            assetsBefore,
            "historical-looking feed read must not accrue optimizer"
        );

        optimizer.accrueIfNeeded();

        (
            uint80 freshRoundId,
            int256 freshAnswer,
            uint256 freshStartedAt,
            uint256 freshUpdatedAt,
            uint80 freshAnsweredInRound
        ) = optimizerVaultFeed.getRoundData(roundId);

        assertEq(freshRoundId, staleRoundId, "round id should be preserved");
        assertEq(
            freshStartedAt, staleStartedAt, "startedAt should be preserved"
        );
        assertEq(
            freshUpdatedAt, staleUpdatedAt, "updatedAt should be preserved"
        );
        assertEq(
            freshAnsweredInRound,
            staleAnsweredInRound,
            "answeredInRound should be preserved"
        );
        assertGt(
            freshAnswer,
            staleAnswer,
            "same round answer should use current optimizer exchange rate"
        );
    }

    function test_lendingOptimizerShareCToken_externalRawVaultAggregatorUsesStaleInnerOptimizerPrice()
        public
    {
        address depositor = makeAddr("externalRawVaultFeedDepositor");
        (ExternalRawOptimizerShareVault vault, uint256 vaultShares,) =
            _depositExternalRawVaultCollateral(depositor);
        _registerOptimizerShareVaultPriceFeed();

        (bool feedConfigured, IChainlink feed,,) =
            _chainlinkAdaptor.assetConfig(address(optimizer), true);
        assertTrue(feedConfigured, "optimizer share feed must be configured");
        VaultAggregator outerVaultFeed = new VaultAggregator(
            address(vault),
            address(optimizer),
            address(feed),
            "external-raw-vault/USD"
        );

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before raw-vault feed read"
        );

        (, int256 staleAnswer,,,) = outerVaultFeed.latestRoundData();
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "chained raw-vault feed read must not accrue optimizer"
        );

        optimizer.accrueIfNeeded();

        (, int256 freshAnswer,,,) = outerVaultFeed.latestRoundData();
        assertGt(
            freshAnswer,
            staleAnswer,
            "fresh chained raw-vault feed should include optimizer NAV"
        );
        assertEq(vault.balanceOf(depositor), vaultShares);
    }

    function test_lendingOptimizerShareCToken_externalSecondLayerVaultAggregatorUsesStaleInnerOptimizerPrice()
        public
    {
        address depositor = makeAddr("externalWrapperVaultFeedDepositor");
        (ExternalOptimizerShareCTokenVault vault, uint256 vaultShares,) =
            _depositExternalWrapperVaultCollateral(depositor);
        _registerOptimizerShareVaultPriceFeed();

        (bool feedConfigured, IChainlink feed,,) =
            _chainlinkAdaptor.assetConfig(address(optimizer), true);
        assertTrue(feedConfigured, "optimizer share feed must be configured");

        VaultAggregator shareCTokenFeed = new VaultAggregator(
            address(optimizerCToken),
            address(optimizer),
            address(feed),
            "optimizer-cToken/USD"
        );
        VaultAggregator outerVaultFeed = new VaultAggregator(
            address(vault),
            address(optimizerCToken),
            address(shareCTokenFeed),
            "external-wrapper-vault/USD"
        );

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before wrapper-vault feed read"
        );

        (, int256 staleAnswer,,,) = outerVaultFeed.latestRoundData();
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "chained wrapper-vault feed read must not accrue optimizer"
        );

        optimizer.accrueIfNeeded();

        (, int256 freshAnswer,,,) = outerVaultFeed.latestRoundData();
        assertGt(
            freshAnswer,
            staleAnswer,
            "fresh chained wrapper-vault feed should include optimizer NAV"
        );
        assertEq(vault.balanceOf(depositor), vaultShares);
    }

    function test_lendingOptimizerShareCToken_riskReaderDirectShareCTokenStatusIsStaleUntilAccrual()
        public
    {
        uint256 assetsBefore = _depositIntoWrapperAndSkipForOptimizerYield();
        _registerOptimizerShareVaultPriceFeed();
        _oracleManager.addCTokenSupport(address(optimizerCToken));

        address[] memory assets = new address[](1);
        assets[0] = address(optimizerCToken);
        RiskReader reader = new RiskReader();

        RiskReader.OraclePriceStatus[] memory staleStatus =
            reader.getOraclePriceStatuses(
                address(_oracleManager), assets, true, true
            );
        assertEq(staleStatus[0].errorCode, 0);
        assertEq(staleStatus[0].flags, 0);
        assertEq(
            optimizer.totalAssets(),
            assetsBefore,
            "RiskReader direct cToken status must not accrue optimizer"
        );

        optimizerCToken.exchangeRateUpdated();

        RiskReader.OraclePriceStatus[] memory freshStatus =
            reader.getOraclePriceStatuses(
                address(_oracleManager), assets, true, true
            );
        assertEq(freshStatus[0].errorCode, 0);
        assertEq(freshStatus[0].flags, 0);
        assertGt(
            freshStatus[0].price,
            staleStatus[0].price,
            "RiskReader direct cToken status should inherit fresh price after accrual"
        );
    }

    function test_lendingOptimizerShareCToken_protocolReaderLeverageSnapshotIsStaleUntilAccrual()
        public
    {
        (
            ,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();

        uint256 optimizerShares = optimizer.balanceOf(address(this));
        IERC20(address(optimizer))
            .approve(address(shareCToken), optimizerShares);
        uint256 wrapperShares =
            shareCToken.deposit(optimizerShares, address(this));
        shareCToken.postCollateral(wrapperShares);

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        _refreshUsdcPriceFeed();
        _setOptimizerVaultFeedAnswer(1e8);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before ProtocolReader"
        );

        ProtocolReader reader = new ProtocolReader(liveCentralRegistry);
        (
            uint256 staleCollateralUsd,,,
            uint256 staleSharePrice,,,
            bool staleOracleError
        ) = reader.getLeverageSnapshot(
            address(this), address(shareCToken), address(debtCToken), 0
        );
        assertFalse(staleOracleError);
        assertGt(staleCollateralUsd, 0, "reader collateral precondition");
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "ProtocolReader leverage snapshot must not accrue optimizer"
        );

        shareCToken.exchangeRateUpdated();

        (
            uint256 freshCollateralUsd,,,
            uint256 freshSharePrice,,,
            bool freshOracleError
        ) = reader.getLeverageSnapshot(
            address(this), address(shareCToken), address(debtCToken), 0
        );
        assertFalse(freshOracleError);
        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "explicit accrual must refresh optimizer NAV"
        );
        assertEq(
            freshSharePrice,
            staleSharePrice,
            "guarded ProtocolReader sharePrice can stay flat after explicit accrual"
        );
        assertEq(
            freshCollateralUsd,
            staleCollateralUsd,
            "guarded ProtocolReader collateralUsd can stay flat after explicit accrual"
        );
    }

    function test_lendingOptimizerShareCToken_marketDebtViewsAccrueOptimizerAndStayZero()
        public
    {
        uint256 assetsBefore = _depositAndSkipForOptimizerYield();

        assertEq(optimizerCToken.marketOutstandingDebtUpdated(), 0);
        assertGt(
            optimizer.totalAssets(),
            assetsBefore,
            "market debt path must sync optimizer NAV"
        );

        assetsBefore = optimizer.totalAssets();
        skip(30 days);

        assertEq(optimizerCToken.debtBalanceUpdated(address(this)), 0);
        assertGt(
            optimizer.totalAssets(),
            assetsBefore,
            "account debt path must sync optimizer NAV"
        );
    }

    function test_lendingOptimizerShareCToken_adminInterestFeeUpdateAccruesOptimizer()
        public
    {
        uint256 assetsBefore = _depositAndSkipForOptimizerYield();

        optimizerCToken.setInterestFee(0);

        assertEq(optimizerCToken.interestFee(), 0);
        assertGt(
            optimizer.totalAssets(),
            assetsBefore,
            "admin fee path must sync optimizer NAV first"
        );
    }

    function test_lendingOptimizer_transferAccruesOptimizer() public {
        address owner = makeAddr("optimizerTransferOwner");
        uint256 assetsBefore = _depositAndSkipForOptimizerYield(owner);
        address receiver = makeAddr("optimizerTransferReceiver");
        uint256 shares = optimizer.balanceOf(owner) / 3;
        uint256 ownerBalanceBefore = optimizer.balanceOf(owner);
        uint256 receiverBalanceBefore = optimizer.balanceOf(receiver);

        vm.prank(owner);
        assertTrue(optimizer.transfer(receiver, shares));

        assertGt(
            optimizer.totalAssets(),
            assetsBefore,
            "optimizer transfer path must sync NAV"
        );
        assertEq(optimizer.balanceOf(owner), ownerBalanceBefore - shares);
        assertEq(optimizer.balanceOf(receiver), receiverBalanceBefore + shares);
    }

    function test_lendingOptimizer_transferFromAccruesOptimizer() public {
        address owner = makeAddr("optimizerTransferFromOwner");
        uint256 assetsBefore = _depositAndSkipForOptimizerYield(owner);
        address spender = makeAddr("optimizerTransferSpender");
        address receiver = makeAddr("optimizerTransferFromReceiver");
        uint256 shares = optimizer.balanceOf(owner) / 3;
        uint256 ownerBalanceBefore = optimizer.balanceOf(owner);
        uint256 receiverBalanceBefore = optimizer.balanceOf(receiver);

        vm.prank(owner);
        optimizer.approve(spender, shares);
        vm.prank(spender);
        assertTrue(optimizer.transferFrom(owner, receiver, shares));

        assertGt(
            optimizer.totalAssets(),
            assetsBefore,
            "optimizer transferFrom path must sync NAV"
        );
        assertEq(optimizer.balanceOf(owner), ownerBalanceBefore - shares);
        assertEq(optimizer.balanceOf(receiver), receiverBalanceBefore + shares);
        assertEq(optimizer.allowance(owner, spender), 0);
    }

    function test_lendingOptimizer_transferRejectsZeroAndSelfTransfer()
        public
    {
        _depositAndSkipForOptimizerYield();

        vm.expectRevert(LendingOptimizer.LendingOptimizer__ZeroAmount.selector);
        optimizer.transfer(makeAddr("optimizerZeroTransferReceiver"), 0);

        vm.expectRevert(
            LendingOptimizer.LendingOptimizer__InvalidParameter.selector
        );
        optimizer.transfer(address(this), 1);
    }

    function test_lendingOptimizer_transferRejectsZeroBeforeSelfTransfer()
        public
    {
        _depositAndSkipForOptimizerYield();

        vm.expectRevert(LendingOptimizer.LendingOptimizer__ZeroAmount.selector);
        optimizer.transfer(address(this), 0);
    }

    function test_lendingOptimizer_transferFromRejectsZeroAndSelfTransfer()
        public
    {
        _depositAndSkipForOptimizerYield();
        address spender = makeAddr("optimizerTransferFromRejectSpender");
        address receiver = makeAddr("optimizerTransferFromRejectReceiver");

        optimizer.approve(spender, 1);
        vm.prank(spender);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__ZeroAmount.selector);
        optimizer.transferFrom(address(this), receiver, 0);

        vm.prank(spender);
        vm.expectRevert(
            LendingOptimizer.LendingOptimizer__InvalidParameter.selector
        );
        optimizer.transferFrom(address(this), address(this), 1);
    }

    function test_lendingOptimizer_transferFromRejectsInvalidBeforeAllowance()
        public
    {
        _depositAndSkipForOptimizerYield();
        address spender = makeAddr("optimizerTransferFromNoAllowanceSpender");
        address receiver = makeAddr("optimizerTransferFromNoAllowanceReceiver");

        vm.prank(spender);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__ZeroAmount.selector);
        optimizer.transferFrom(address(this), receiver, 0);

        vm.prank(spender);
        vm.expectRevert(
            LendingOptimizer.LendingOptimizer__InvalidParameter.selector
        );
        optimizer.transferFrom(address(this), address(this), 1);

        assertEq(optimizer.allowance(address(this), spender), 0);
    }

    function test_lendingOptimizer_transferFromRejectsZeroBeforeSelfTransfer()
        public
    {
        _depositAndSkipForOptimizerYield();
        address spender =
            makeAddr("optimizerTransferFromZeroBeforeSelfSpender");

        vm.prank(spender);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__ZeroAmount.selector);
        optimizer.transferFrom(address(this), address(this), 0);
    }

    function test_lendingOptimizerShareCToken_depositAccruesOptimizerAndMintsWrapperShares()
        public
    {
        uint256 assetsBefore = _depositAndSkipForOptimizerYield();
        uint256 optimizerShares = optimizer.balanceOf(address(this)) / 2;
        address receiver = makeAddr("depositReceiver");
        uint256 expectedShares =
            optimizerCToken.previewDeposit(optimizerShares);
        uint256 receiverBalance = optimizerCToken.balanceOf(receiver);
        uint256 totalAssetsBefore = optimizerCToken.totalAssets();

        IERC20(address(optimizer))
            .approve(address(optimizerCToken), optimizerShares);
        _mockCanMint();
        uint256 shares = optimizerCToken.deposit(optimizerShares, receiver);

        assertGt(
            optimizer.totalAssets(),
            assetsBefore,
            "deposit path must sync optimizer NAV"
        );
        assertEq(shares, expectedShares);
        assertEq(optimizerCToken.balanceOf(receiver), receiverBalance + shares);
        assertEq(
            optimizerCToken.totalAssets(), totalAssetsBefore + optimizerShares
        );
        vm.clearMockedCalls();
    }

    function test_lendingOptimizerShareCToken_mintAccruesOptimizerAndConsumesPreviewAssets()
        public
    {
        uint256 assetsBefore = _depositAndSkipForOptimizerYield();
        uint256 shares = 12345;
        uint256 expectedAssets = optimizerCToken.previewMint(shares);
        address receiver = makeAddr("mintReceiver");
        uint256 receiverBalance = optimizerCToken.balanceOf(receiver);
        uint256 totalAssetsBefore = optimizerCToken.totalAssets();

        IERC20(address(optimizer))
            .approve(address(optimizerCToken), expectedAssets);
        _mockCanMint();
        uint256 assets = optimizerCToken.mint(shares, receiver);

        assertGt(
            optimizer.totalAssets(),
            assetsBefore,
            "mint path must sync optimizer NAV"
        );
        assertEq(assets, expectedAssets);
        assertEq(optimizerCToken.balanceOf(receiver), receiverBalance + shares);
        assertEq(optimizerCToken.totalAssets(), totalAssetsBefore + assets);
        vm.clearMockedCalls();
    }

    function test_lendingOptimizerShareCToken_depositAsCollateralAccruesAndPostsCollateral()
        public
    {
        uint256 assetsBefore = _depositAndSkipForOptimizerYield();
        uint256 optimizerShares = optimizer.balanceOf(address(this)) / 2;
        uint256 expectedShares =
            optimizerCToken.previewDeposit(optimizerShares);

        IERC20(address(optimizer))
            .approve(address(optimizerCToken), optimizerShares);
        _mockCanMint();
        _mockCanCollateralize(address(this), expectedShares);
        uint256 shares = optimizerCToken.depositAsCollateral(
            optimizerShares, address(this)
        );

        assertGt(
            optimizer.totalAssets(),
            assetsBefore,
            "depositAsCollateral path must sync optimizer NAV"
        );
        assertEq(shares, expectedShares);
        assertEq(
            optimizerCToken.collateralPosted(address(this)), expectedShares
        );
        assertEq(optimizerCToken.marketCollateralPosted(), expectedShares);
        vm.clearMockedCalls();
    }

    function test_lendingOptimizerShareCToken_redeemAccruesOptimizerAndReturnsOptimizerShares()
        public
    {
        uint256 assetsBefore = _depositIntoWrapperAndSkipForOptimizerYield();
        address receiver = makeAddr("redeemReceiver");
        uint256 shares = optimizerCToken.balanceOf(address(this)) / 2;
        uint256 expectedAssets = optimizerCToken.previewRedeem(shares);
        uint256 receiverAssetsBefore = optimizer.balanceOf(receiver);
        uint256 totalAssetsBefore = optimizerCToken.totalAssets();

        _mockCanRedeem(address(this), shares, false, 0);
        uint256 assets =
            optimizerCToken.redeem(shares, receiver, address(this));

        assertGt(
            optimizer.totalAssets(),
            assetsBefore,
            "redeem path must sync optimizer NAV"
        );
        assertEq(assets, expectedAssets);
        assertEq(optimizer.balanceOf(receiver), receiverAssetsBefore + assets);
        assertEq(optimizerCToken.totalAssets(), totalAssetsBefore - assets);
        vm.clearMockedCalls();
    }

    function test_lendingOptimizerShareCToken_withdrawAccruesOptimizerAndBurnsPreviewShares()
        public
    {
        uint256 assetsBefore = _depositIntoWrapperAndSkipForOptimizerYield();
        address receiver = makeAddr("withdrawReceiver");
        uint256 assets = optimizerCToken.convertToAssets(
            optimizerCToken.balanceOf(address(this)) / 2
        );
        uint256 expectedShares = optimizerCToken.previewWithdraw(assets);
        uint256 receiverAssetsBefore = optimizer.balanceOf(receiver);
        uint256 totalAssetsBefore = optimizerCToken.totalAssets();

        _mockCanRedeem(address(this), expectedShares, false, 0);
        uint256 shares =
            optimizerCToken.withdraw(assets, receiver, address(this));

        assertGt(
            optimizer.totalAssets(),
            assetsBefore,
            "withdraw path must sync optimizer NAV"
        );
        assertEq(shares, expectedShares);
        assertEq(optimizer.balanceOf(receiver), receiverAssetsBefore + assets);
        assertEq(optimizerCToken.totalAssets(), totalAssetsBefore - assets);
        vm.clearMockedCalls();
    }

    function test_lendingOptimizerShareCToken_directOptimizerShareDonationSkimmableWithoutAccountingImpact()
        public
    {
        _depositAndSkipForOptimizerYield();
        uint256 wrapperDeposit = optimizer.balanceOf(address(this)) / 2;
        uint256 donationShares =
            optimizer.balanceOf(address(this)) - wrapperDeposit;

        IERC20(address(optimizer))
            .approve(address(optimizerCToken), wrapperDeposit);
        _mockCanMint();
        optimizerCToken.deposit(wrapperDeposit, address(this));
        vm.clearMockedCalls();

        uint256 totalAssetsBefore = optimizerCToken.totalAssets();
        uint256 totalSupplyBefore = optimizerCToken.totalSupply();
        uint256 userWrapperBalanceBefore =
            optimizerCToken.balanceOf(address(this));
        uint256 userRedeemBefore =
            optimizerCToken.convertToAssets(userWrapperBalanceBefore);
        uint256 wrapperAssetBalanceBefore =
            optimizer.balanceOf(address(optimizerCToken));
        address dao = liveCentralRegistry.daoAddress();

        optimizer.transfer(address(optimizerCToken), donationShares);

        assertEq(
            optimizer.balanceOf(address(optimizerCToken)),
            wrapperAssetBalanceBefore + donationShares,
            "direct donation should only raise wrapper asset balance"
        );
        assertEq(
            optimizerCToken.totalAssets(),
            totalAssetsBefore,
            "donation should not enter cached assets"
        );
        assertEq(
            optimizerCToken.totalSupply(),
            totalSupplyBefore,
            "donation should not mint wrapper shares"
        );
        assertEq(
            optimizerCToken.balanceOf(address(this)),
            userWrapperBalanceBefore,
            "donation should not alter user wrapper balance"
        );
        assertEq(
            optimizerCToken.convertToAssets(userWrapperBalanceBefore),
            userRedeemBefore,
            "donation should not inflate user redeem value"
        );
        assertEq(
            optimizerCToken.skimAvailable(),
            donationShares,
            "donation should be skimmable excess"
        );

        uint256 daoOptimizerBalanceBeforeSkim = optimizer.balanceOf(dao);
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(
                ICentralRegistry.hasDaoPermissions.selector, address(this)
            ),
            abi.encode(true)
        );
        optimizerCToken.skim();

        assertEq(
            optimizer.balanceOf(dao),
            daoOptimizerBalanceBeforeSkim + donationShares,
            "skim should send donated optimizer shares to DAO"
        );
        assertEq(
            optimizer.balanceOf(address(optimizerCToken)),
            wrapperAssetBalanceBefore,
            "skim should remove only the donated optimizer shares"
        );
        assertEq(
            optimizerCToken.totalAssets(),
            totalAssetsBefore,
            "skim should preserve cached assets"
        );
        assertEq(
            optimizerCToken.totalSupply(),
            totalSupplyBefore,
            "skim should preserve wrapper supply"
        );
        assertEq(
            optimizerCToken.balanceOf(address(this)),
            userWrapperBalanceBefore,
            "skim should preserve user wrapper balance"
        );
        assertEq(
            optimizerCToken.convertToAssets(userWrapperBalanceBefore),
            userRedeemBefore,
            "skim should preserve user redeem value"
        );
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        optimizerCToken.skimAvailable();
        vm.clearMockedCalls();
    }

    function test_lendingOptimizer_directApprovedMarketShareDonationAccruesAsYieldWithoutCreditingDonor()
        public
    {
        IBorrowableCToken market = IBorrowableCToken(cUSDC_WMON_MARKET);
        address donor = makeAddr("approvedMarketShareDonor");
        uint256 donationAssets = 1_000e6;

        deal(USDC_MONAD, donor, donationAssets);
        vm.startPrank(donor);
        IERC20(USDC_MONAD).approve(address(market), donationAssets);
        uint256 donatedMarketShares = market.deposit(donationAssets, donor);
        vm.stopPrank();

        optimizer.accrueIfNeeded();
        uint256 totalAssetsBefore = optimizer.totalAssets();
        uint256 totalSupplyBefore = optimizer.totalSupply();
        uint256 donorOptimizerSharesBefore = optimizer.balanceOf(donor);
        uint256 daoSharesBefore =
            optimizer.balanceOf(liveCentralRegistry.daoAddress());
        uint256 holderAssetsBefore =
            optimizer.convertToAssets(optimizer.balanceOf(address(this)));
        uint256 preDonationPreview = optimizer.previewDeposit(10_000e6);
        uint256 donatedMarketAssets =
            market.convertToAssets(donatedMarketShares);

        vm.prank(donor);
        IERC20(address(market))
            .transfer(address(optimizer), donatedMarketShares);

        assertEq(
            optimizer.totalAssets(),
            totalAssetsBefore,
            "direct market-share donation must not update cached NAV"
        );
        assertEq(
            optimizer.balanceOf(donor),
            donorOptimizerSharesBefore,
            "market-share donation must not mint optimizer shares"
        );

        optimizer.accrueIfNeeded();

        assertApproxEqAbs(
            optimizer.totalAssets(),
            totalAssetsBefore + donatedMarketAssets,
            4,
            "direct market-share donation should accrue as optimizer yield"
        );
        assertEq(
            market.balanceOf(donor),
            0,
            "donor should spend the donated cToken shares"
        );
        assertEq(
            optimizer.balanceOf(donor),
            donorOptimizerSharesBefore,
            "donor still receives no optimizer shares after accrual"
        );
        assertGt(
            optimizer.balanceOf(liveCentralRegistry.daoAddress()),
            daoSharesBefore,
            "performance fee should capture part of donated yield"
        );
        assertGt(
            optimizer.totalSupply(),
            totalSupplyBefore,
            "only fee minting should expand optimizer supply"
        );
        assertGt(
            optimizer.convertToAssets(optimizer.balanceOf(address(this))),
            holderAssetsBefore,
            "existing holders should receive net donated value"
        );

        uint256 postDonationPreview = optimizer.previewDeposit(10_000e6);
        assertLt(
            postDonationPreview,
            preDonationPreview,
            "later deposits should price against donated NAV"
        );

        deal(USDC_MONAD, donor, 10_000e6);
        vm.startPrank(donor);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        uint256 mintedShares = optimizer.deposit(10_000e6, donor);
        vm.stopPrank();

        assertEq(
            optimizer.balanceOf(donor),
            donorOptimizerSharesBefore + mintedShares,
            "donor only receives shares from an actual optimizer deposit"
        );
        assertLt(
            mintedShares,
            preDonationPreview,
            "donor cannot recover donated value through a later deposit"
        );
    }

    function test_lendingOptimizerShareCToken_universalBalanceLentOptimizerSharesAccrueOnWithdraw()
        public
    {
        UniversalBalance universalBalance = new UniversalBalance(
            liveCentralRegistry, address(optimizerCToken)
        );
        assertEq(
            universalBalance.underlying(),
            address(optimizer),
            "UB underlying is raw optimizer shares"
        );
        assertEq(
            address(universalBalance.linkedToken()),
            address(optimizerCToken),
            "UB linked token"
        );

        uint256 assetsBefore = _depositAndSkipForOptimizerYield();
        uint256 optimizerShares = optimizer.balanceOf(address(this)) / 2;
        uint256 expectedLentShares =
            optimizerCToken.previewDeposit(optimizerShares);
        uint256 wrapperAssetsBefore =
            optimizer.balanceOf(address(optimizerCToken));

        IERC20(address(optimizer))
            .approve(address(universalBalance), optimizerShares);
        _mockCanMint();
        universalBalance.deposit(optimizerShares, true);

        (, uint256 lentBalance) = universalBalance.userBalances(address(this));
        assertEq(
            lentBalance,
            expectedLentShares,
            "UB should record wrapper shares as lent balance"
        );
        assertEq(
            optimizer.balanceOf(address(universalBalance)),
            0,
            "UB should not retain raw optimizer shares"
        );
        assertEq(
            optimizer.balanceOf(address(optimizerCToken)),
            wrapperAssetsBefore + optimizerShares,
            "wrapper should hold the lent optimizer shares"
        );
        assertGt(
            optimizer.totalAssets(),
            assetsBefore,
            "UB optimizer-share transfer must sync optimizer NAV"
        );

        skip(30 days);
        uint256 staleAssetsBeforeWithdraw = optimizer.totalAssets();
        address receiver = makeAddr("universalBalanceOptimizerShareReceiver");
        uint256 receiverBalanceBefore = optimizer.balanceOf(receiver);
        vm.mockCall(
            _marketMgrs[cUSDC_WMON_MARKET],
            abi.encodeWithSelector(
                bytes4(
                    keccak256(
                        "canRedeemWithCollateralRemoval(address,uint256,address,uint256,uint256,bool)"
                    )
                )
            ),
            abi.encode(uint256(0))
        );
        (uint256 amountWithdrawn, bool lendingBalanceUsed) =
            universalBalance.withdraw(optimizerShares, true, receiver);

        assertTrue(
            lendingBalanceUsed, "UB withdraw should use lent wrapper balance"
        );
        assertGt(
            optimizer.totalAssets(),
            staleAssetsBeforeWithdraw,
            "UB lent withdraw must sync optimizer NAV"
        );
        assertGe(
            amountWithdrawn,
            optimizerShares,
            "UB withdraw should return requested optimizer shares"
        );
        assertEq(
            optimizer.balanceOf(receiver),
            receiverBalanceBefore + amountWithdrawn,
            "receiver should get raw optimizer shares"
        );
        (, uint256 lentBalanceAfter) =
            universalBalance.userBalances(address(this));
        assertEq(lentBalanceAfter, 0, "UB lent balance should be fully burned");
        assertEq(
            optimizer.balanceOf(address(universalBalance)),
            0,
            "UB optimizer residue"
        );
        vm.clearMockedCalls();
    }

    function test_lendingOptimizerShareCToken_nativeUniversalBalanceRejectsOptimizerShareWrapper()
        public
    {
        vm.expectRevert(
            NativeUniversalBalance.NativeUniversalBalance__UnderlyingTokenMismatch
                .selector
        );
        new NativeUniversalBalance(
            liveCentralRegistry,
            address(optimizerCToken),
            makeAddr("wrappedNativeToken")
        );
    }

    function test_lendingOptimizerShareCToken_redeemForRequiresDelegateAndPreservesReceiver()
        public
    {
        address owner = makeAddr("wrapperRedeemForOwner");
        address delegate = makeAddr("wrapperRedeemForDelegate");
        address receiver = makeAddr("wrapperRedeemForReceiver");
        uint256 assetsBefore =
            _depositIntoWrapperAndSkipForOptimizerYield(owner);
        uint256 shares = optimizerCToken.balanceOf(owner) / 2;
        uint256 expectedAssets = optimizerCToken.previewRedeem(shares);
        uint256 ownerSharesBefore = optimizerCToken.balanceOf(owner);
        uint256 receiverAssetsBefore = optimizer.balanceOf(receiver);
        uint256 delegateAssetsBefore = optimizer.balanceOf(delegate);

        vm.prank(delegate);
        vm.expectRevert(PluginDelegable.PluginDelegable__Unauthorized.selector);
        optimizerCToken.redeemFor(shares, receiver, owner);

        vm.prank(owner);
        optimizerCToken.setDelegateApproval(delegate, true);

        _mockCanRedeem(owner, shares, false, 0);
        vm.prank(delegate);
        uint256 assets = optimizerCToken.redeemFor(shares, receiver, owner);

        assertGt(
            optimizer.totalAssets(),
            assetsBefore,
            "redeemFor must sync optimizer NAV"
        );
        assertEq(assets, expectedAssets);
        assertEq(optimizerCToken.balanceOf(owner), ownerSharesBefore - shares);
        assertEq(optimizer.balanceOf(receiver), receiverAssetsBefore + assets);
        assertEq(optimizer.balanceOf(delegate), delegateAssetsBefore);
        vm.clearMockedCalls();
    }

    function test_lendingOptimizerShareCToken_redeemCollateralForcesCollateralRemoval()
        public
    {
        _depositWrapperCollateral();
        uint256 assetsBefore = optimizer.totalAssets();
        skip(30 days);

        uint256 shares = optimizerCToken.collateralPosted(address(this)) / 2;
        uint256 postedBefore = optimizerCToken.collateralPosted(address(this));
        address receiver = makeAddr("redeemCollateralReceiver");
        uint256 expectedAssets = optimizerCToken.previewRedeem(shares);

        _mockCanRedeem(address(this), shares, true, shares);
        uint256 assets =
            optimizerCToken.redeemCollateral(shares, receiver, address(this));

        assertGt(
            optimizer.totalAssets(),
            assetsBefore,
            "redeemCollateral path must sync optimizer NAV"
        );
        assertEq(assets, expectedAssets);
        assertEq(
            optimizerCToken.collateralPosted(address(this)),
            postedBefore - shares
        );
        assertEq(
            optimizerCToken.marketCollateralPosted(), postedBefore - shares
        );
        vm.clearMockedCalls();
    }

    function test_lendingOptimizerShareCToken_withdrawCollateralForcesCollateralRemoval()
        public
    {
        _depositWrapperCollateral();
        uint256 assetsBefore = optimizer.totalAssets();
        skip(30 days);

        uint256 postedBefore = optimizerCToken.collateralPosted(address(this));
        uint256 assets = optimizerCToken.convertToAssets(postedBefore / 2);
        uint256 expectedShares = optimizerCToken.previewWithdraw(assets);
        address receiver = makeAddr("withdrawCollateralReceiver");

        _mockCanRedeem(address(this), expectedShares, true, expectedShares);
        uint256 shares = optimizerCToken.withdrawCollateral(
            assets, receiver, address(this)
        );

        assertGt(
            optimizer.totalAssets(),
            assetsBefore,
            "withdrawCollateral path must sync optimizer NAV"
        );
        assertEq(shares, expectedShares);
        assertEq(
            optimizerCToken.collateralPosted(address(this)),
            postedBefore - expectedShares
        );
        assertEq(
            optimizerCToken.marketCollateralPosted(),
            postedBefore - expectedShares
        );
        vm.clearMockedCalls();
    }

    function test_lendingOptimizerShareCToken_transferAccruesOptimizer()
        public
    {
        uint256 assetsBefore = _depositIntoWrapperAndSkipForOptimizerYield();
        address receiver = makeAddr("transferReceiver");
        uint256 shares = 1;

        _mockCanTransfer(address(this), receiver, shares);
        optimizerCToken.transfer(receiver, shares);

        assertGt(
            optimizer.totalAssets(),
            assetsBefore,
            "transfer path must sync optimizer NAV"
        );
        vm.clearMockedCalls();
    }

    function test_lendingOptimizerShareCToken_transferFromAccruesOptimizer()
        public
    {
        uint256 assetsBefore = _depositIntoWrapperAndSkipForOptimizerYield();
        address spender = makeAddr("transferSpender");
        address receiver = makeAddr("transferFromReceiver");
        uint256 shares = 1;

        optimizerCToken.approve(spender, shares);
        _mockCanTransfer(address(this), receiver, shares);
        vm.prank(spender);
        optimizerCToken.transferFrom(address(this), receiver, shares);

        assertGt(
            optimizer.totalAssets(),
            assetsBefore,
            "transferFrom path must sync optimizer NAV"
        );
        vm.clearMockedCalls();
    }

    function test_lendingOptimizerShareCToken_transferRejectsZeroAndSelfTransfer()
        public
    {
        _depositIntoWrapperAndSkipForOptimizerYield();

        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        optimizerCToken.transfer(makeAddr("zeroTransferReceiver"), 0);

        vm.expectRevert(BaseCToken.BaseCToken__TransferError.selector);
        optimizerCToken.transfer(address(this), 1);
    }

    function test_lendingOptimizerShareCToken_transferFromRejectsZeroAndSelfTransfer()
        public
    {
        _depositIntoWrapperAndSkipForOptimizerYield();
        address spender = makeAddr("transferFromRejectSpender");
        address receiver = makeAddr("transferFromRejectReceiver");

        optimizerCToken.approve(spender, 1);
        vm.prank(spender);
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        optimizerCToken.transferFrom(address(this), receiver, 0);

        vm.prank(spender);
        vm.expectRevert(BaseCToken.BaseCToken__TransferError.selector);
        optimizerCToken.transferFrom(address(this), address(this), 1);
    }

    function test_lendingOptimizerShareCToken_transferRemovesCollateralReturnedByMarketManager()
        public
    {
        _depositWrapperCollateral();
        uint256 assetsBefore = optimizer.totalAssets();
        skip(30 days);

        address receiver = makeAddr("collateralTransferReceiver");
        uint256 shares = optimizerCToken.collateralPosted(address(this)) / 2;
        uint256 collateralBefore =
            optimizerCToken.collateralPosted(address(this));
        uint256 marketCollateralBefore =
            optimizerCToken.marketCollateralPosted();

        _mockCanTransfer(address(this), receiver, shares, shares);
        optimizerCToken.transfer(receiver, shares);

        assertGt(
            optimizer.totalAssets(),
            assetsBefore,
            "collateralized transfer path must sync optimizer NAV"
        );
        assertEq(
            optimizerCToken.collateralPosted(address(this)),
            collateralBefore - shares
        );
        assertEq(
            optimizerCToken.marketCollateralPosted(),
            marketCollateralBefore - shares
        );
        vm.clearMockedCalls();
    }

    function test_lendingOptimizerShareCToken_cannotBeApprovedOptimizerMarket()
        public
    {
        vm.expectRevert(
            LendingOptimizer.LendingOptimizer__InvalidUnderlying.selector
        );
        optimizer.addApprovedAsset(address(optimizerCToken), 1_000);
    }

    function test_lendingOptimizer_addApprovedAssetAllowsNormalMarketPair()
        public
    {
        optimizer.addApprovedAsset(cUSDC_WBTC_MARKET, 1_000);

        assertEq(optimizer.allocationCaps(cUSDC_WBTC_MARKET), WAD / 10);
    }

    function test_lendingOptimizerShareCToken_launchMarketIsCollateralOnlyAndPriceGuarded()
        public
    {
        (
            MarketManagerIsolated optimizerMarket,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();

        assertEq(
            address(shareCToken.marketManager()), address(optimizerMarket)
        );
        assertEq(address(debtCToken.marketManager()), address(optimizerMarket));
        assertEq(shareCToken.asset(), address(optimizer));
        assertEq(optimizer.asset(), USDC_MONAD);
        assertEq(debtCToken.asset(), USDC_MONAD);
        assertTrue(
            shareCToken.isBorrowable(), "DynamicIRM-compatible identity"
        );
        assertTrue(debtCToken.isBorrowable(), "paired debt side is borrowable");
        assertEq(
            _oracleManager.cTokens(address(shareCToken)), address(optimizer)
        );
        assertEq(_oracleManager.cTokens(address(debtCToken)), USDC_MONAD);

        address[] memory approvedMarkets = optimizer.getApprovedMarkets();
        assertEq(approvedMarkets.length, 1);
        assertEq(approvedMarkets[0], cUSDC_WMON_MARKET);
        assertTrue(
            approvedMarkets[0] != address(debtCToken),
            "launch debt cToken must not be an optimizer market"
        );

        address[] memory listedTokens = optimizerMarket.queryTokensListed();
        assertEq(listedTokens.length, 2);
        assertEq(listedTokens[0], address(shareCToken));
        assertEq(listedTokens[1], address(debtCToken));

        assertEq(
            optimizerMarket.collateralCaps(address(shareCToken)), 1_000_000e6
        );
        assertEq(optimizerMarket.debtCaps(address(shareCToken)), 0);
        assertEq(optimizerMarket.collateralCaps(address(debtCToken)), 0);
        assertEq(optimizerMarket.debtCaps(address(debtCToken)), 1_000_000e6);

        (bool feedConfigured, IChainlink feed, uint8 feedDecimals,) =
            _chainlinkAdaptor.assetConfig(address(optimizer), true);
        assertTrue(feedConfigured, "optimizer share feed must be configured");
        assertEq(feedDecimals, 8);
        VaultAggregator optimizerVaultFeed = VaultAggregator(address(feed));
        assertEq(optimizerVaultFeed.vault(), address(optimizer));
        assertEq(optimizerVaultFeed.asset(), USDC_MONAD);

        (uint256 optimizerPrice, uint256 optimizerPriceError) =
            _oracleManager.getPrice(address(optimizer), true, true);
        assertGt(optimizerPrice, 0, "optimizer share price");
        assertEq(optimizerPriceError, 0, "optimizer share price error");

        (uint256 collateralSharesPrice, uint256 debtUnderlyingPrice) = _oracleManager.getPriceIsolatedPair(
            address(shareCToken), address(debtCToken), BAD_SOURCE
        );
        assertGt(collateralSharesPrice, 0, "optimizer-share collateral price");
        assertGt(debtUnderlyingPrice, 0, "paired debt price");

        IOracleAdaptor.PriceGuard memory guard =
            _chainlinkAdaptor.getPriceGuard(address(optimizer), true);
        assertEq(uint256(guard.minPrice), 0);
        assertEq(uint256(guard.basePrice), WAD);
        assertEq(uint256(guard.ips), 0);
        assertEq(uint256(guard.timestampStart), 0);

        vm.expectRevert(
            LendingOptimizerShareCToken.LendingOptimizerShareCToken__BorrowDisabled
                .selector
        );
        shareCToken.borrow(1, address(this));

        vm.expectRevert(
            LendingOptimizerShareCToken.LendingOptimizerShareCToken__BorrowDisabled
                .selector
        );
        shareCToken.borrowFor(1, address(this), address(this));

        IPositionManager.LeverageAction memory action;
        vm.expectRevert(
            LendingOptimizerShareCToken.LendingOptimizerShareCToken__BorrowDisabled
                .selector
        );
        shareCToken.borrowForPositionManager(1, address(this), action);

        vm.expectRevert(
            LendingOptimizerShareCToken.LendingOptimizerShareCToken__BorrowDisabled
                .selector
        );
        shareCToken.flashLoan(1, "");
    }

    function test_lendingOptimizerShareCToken_nonzeroDebtCapDoesNotEnableDebtIssuance()
        public
    {
        (
            MarketManagerIsolated optimizerMarket,,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();

        _configureToken(
            optimizerMarket, address(shareCToken), 7000, 1_000_000e6, 50_000e6
        );

        assertEq(optimizerMarket.debtCaps(address(shareCToken)), 50_000e6);
        assertEq(shareCToken.marketOutstandingDebt(), 0);
        assertEq(shareCToken.debtBalance(address(this)), 0);
        assertEq(
            optimizerMarket.accountPositions(
                address(shareCToken), address(this)
            ),
            0
        );

        vm.expectRevert(
            LendingOptimizerShareCToken.LendingOptimizerShareCToken__BorrowDisabled
                .selector
        );
        shareCToken.borrow(1, address(this));

        vm.expectRevert(
            LendingOptimizerShareCToken.LendingOptimizerShareCToken__BorrowDisabled
                .selector
        );
        shareCToken.borrowFor(1, address(this), address(this));

        IPositionManager.LeverageAction memory action;
        vm.expectRevert(
            LendingOptimizerShareCToken.LendingOptimizerShareCToken__BorrowDisabled
                .selector
        );
        shareCToken.borrowForPositionManager(1, address(this), action);

        vm.expectRevert(
            LendingOptimizerShareCToken.LendingOptimizerShareCToken__BorrowDisabled
                .selector
        );
        shareCToken.flashLoan(1, "");

        assertEq(shareCToken.marketOutstandingDebt(), 0);
        assertEq(shareCToken.debtBalance(address(this)), 0);
        assertEq(
            optimizerMarket.accountPositions(
                address(shareCToken), address(this)
            ),
            0
        );
    }

    function test_lendingOptimizerShareCToken_cctpBorrowZapperCannotBridgeOptimizerShareDebt()
        public
    {
        CCTPBorrowZapper cctpZapper = new CCTPBorrowZapper(liveCentralRegistry);
        uint256 dstChainId = 42161;
        uint256 relayerFee = 0.01 ether;
        uint256 messageFee = 0.001 ether;
        uint256 borrowAmount = 1e18;

        {
            address tokenMessenger = makeAddr("cctpTokenMessenger");
            address crosschainRelayer = makeAddr("cctpCrosschainRelayer");
            address deliveryProvider = makeAddr("cctpDeliveryProvider");
            address crosschainCore = makeAddr("cctpCrosschainCore");
            uint16 messagingChainId = 23;
            uint32 destinationDomain = 1234;

            ChainConfig memory config = ChainConfig({
                isSupported: true,
                messagingChainId: messagingChainId,
                domain: destinationDomain,
                messagingHub: makeAddr("remoteMessagingHub"),
                votingHub: makeAddr("remoteVotingHub"),
                cveAddress: makeAddr("remoteCVE"),
                feeTokenAddress: USDC_MONAD,
                crosschainRelayer: crosschainRelayer
            });

            vm.mockCall(
                address(liveCentralRegistry),
                abi.encodeWithSelector(
                    ICentralRegistry.hasElevatedPermissions.selector,
                    address(this)
                ),
                abi.encode(true)
            );
            vm.mockCall(
                address(liveCentralRegistry),
                abi.encodeWithSelector(
                    ICentralRegistry.chainConfig.selector, dstChainId
                ),
                abi.encode(config)
            );
            cctpZapper.setCCTPDeliveryProvider(
                dstChainId, deliveryProvider, true
            );

            vm.mockCall(
                address(liveCentralRegistry),
                abi.encodeWithSelector(ICentralRegistry.feeToken.selector),
                abi.encode(USDC_MONAD)
            );
            vm.mockCall(
                address(liveCentralRegistry),
                abi.encodeWithSelector(
                    ICentralRegistry.tokenMessager.selector
                ),
                abi.encode(tokenMessenger)
            );
            vm.mockCall(
                address(liveCentralRegistry),
                abi.encodeWithSelector(
                    ICentralRegistry.crosschainRelayer.selector
                ),
                abi.encode(crosschainRelayer)
            );
            vm.mockCall(
                address(liveCentralRegistry),
                abi.encodeWithSelector(
                    ICentralRegistry.crosschainCore.selector
                ),
                abi.encode(crosschainCore)
            );
            vm.mockCall(
                tokenMessenger,
                abi.encodeWithSelector(
                    ITokenMessenger.remoteTokenMessengers.selector,
                    destinationDomain
                ),
                abi.encode(bytes32(uint256(1)))
            );
            vm.mockCall(
                crosschainRelayer,
                abi.encodeWithSelector(
                    IWormholeRelayer.getDefaultDeliveryProvider.selector
                ),
                abi.encode(deliveryProvider)
            );
            vm.mockCall(
                crosschainRelayer,
                abi.encodeWithSelector(
                    IWormholeRelayer.quoteEVMDeliveryPrice.selector,
                    messagingChainId,
                    uint256(0),
                    uint256(300_000)
                ),
                abi.encode(relayerFee, uint256(0))
            );
            vm.mockCall(
                crosschainCore,
                abi.encodeWithSelector(IWormhole.messageFee.selector),
                abi.encode(messageFee)
            );
        }

        SwapperLib.Swap memory swapAction = SwapperLib.Swap({
            inputToken: address(optimizer),
            inputAmount: borrowAmount,
            outputToken: USDC_MONAD,
            target: makeAddr("unusedCctpSwapTarget"),
            slippage: 0,
            call: bytes("")
        });

        vm.expectCall(
            address(optimizerCToken),
            abi.encodeWithSelector(
                IBorrowableCToken.borrowFor.selector,
                borrowAmount,
                address(cctpZapper),
                address(this)
            )
        );
        vm.expectRevert(
            LendingOptimizerShareCToken.LendingOptimizerShareCToken__BorrowDisabled
                .selector
        );
        cctpZapper.borrowAndBridge{value: relayerFee + messageFee}(
            address(optimizerCToken),
            borrowAmount,
            swapAction,
            dstChainId,
            300_000,
            makeAddr("cctpDestinationReceiver")
        );

        assertEq(optimizerCToken.marketOutstandingDebt(), 0, "wrapper debt");
        assertEq(
            optimizerCToken.debtBalance(address(this)),
            0,
            "caller wrapper debt"
        );
        assertEq(
            optimizer.balanceOf(address(cctpZapper)),
            0,
            "zapper optimizer residue"
        );
        assertEq(
            IERC20(USDC_MONAD).balanceOf(address(cctpZapper)),
            0,
            "zapper fee-token residue"
        );
        vm.clearMockedCalls();
    }

    function test_lendingOptimizer_plainBorrowableOptimizerDebtCanPassStaleBorrowCheckAndEndUnhealthy()
        public
    {
        (
            MarketManagerIsolated optimizerDebtMarket,
            BorrowableCToken optimizerDebtCToken,
            MockERC20 collateral,
            SimpleCToken collateralCToken
        ) = _deployPlainBorrowableOptimizerDebtMarket();

        uint256 lenderShares = 1_000_000e6;
        optimizerDebtCToken.deposit(lenderShares, address(this));

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(365 days);
        _refreshUsdcPriceFeed();
        MockV3Aggregator refreshedCollateralFeed = new MockV3Aggregator(8, 1e8);
        _chainlinkAdaptor.addAsset(
            address(collateral), true, address(refreshedCollateralFeed), 0
        );
        _setOptimizerVaultFeedAnswer(1e8);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before plain debt borrow"
        );

        uint256 borrowShares = 250_000e6;
        (uint256 staleDebtPrice, uint256 staleDebtPriceError) =
            _oracleManager.getPrice(address(optimizer), true, false);
        assertEq(staleDebtPriceError, 0);
        uint256 staleDebtValue =
            FixedPointMathLib.mulDivUp(borrowShares, staleDebtPrice, 1e6);
        uint256 targetMaxDebt = staleDebtValue + 10e18;
        uint256 collateralAmount =
            FixedPointMathLib.mulDivUp(targetMaxDebt, BPS, 7000);
        address borrower = makeAddr("plainOptimizerDebtBorrower");

        collateral.mint(borrower, collateralAmount);
        vm.startPrank(borrower);
        IERC20(address(collateral))
            .approve(address(collateralCToken), collateralAmount);
        collateralCToken.depositAsCollateral(collateralAmount, borrower);
        vm.stopPrank();

        skip(1201);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: collateral setup must not refresh optimizer NAV"
        );

        vm.prank(borrower);
        optimizerDebtCToken.borrow(borrowShares, borrower);

        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "plain optimizer-share debt transfer refreshes only after borrow check"
        );
        assertEq(optimizer.balanceOf(borrower), borrowShares);

        (, uint256 maxDebt, uint256 debt) =
            optimizerDebtMarket.statusOf(borrower);
        assertGt(
            debt,
            maxDebt,
            "plain borrowable optimizer-share debt can become unhealthy after transfer accrual"
        );
    }

    function test_lendingOptimizer_plainBorrowableOptimizerDebtPartialRepayAccruesBeforeResidualReview()
        public
    {
        (
            ,
            BorrowableCToken optimizerDebtCToken,
            MockERC20 collateral,
            SimpleCToken collateralCToken
        ) = _deployPlainBorrowableOptimizerDebtMarket();

        uint256 lenderShares = 1_000_000e6;
        optimizerDebtCToken.deposit(lenderShares, address(this));

        uint256 borrowShares = 250_000e6;
        address borrower = makeAddr("plainOptimizerDebtRepayer");
        uint256 collateralAmount = 1_000_000e18;

        collateral.mint(borrower, collateralAmount);
        vm.startPrank(borrower);
        IERC20(address(collateral))
            .approve(address(collateralCToken), collateralAmount);
        collateralCToken.depositAsCollateral(collateralAmount, borrower);
        vm.stopPrank();

        vm.prank(borrower);
        optimizerDebtCToken.borrow(borrowShares, borrower);
        assertEq(optimizer.balanceOf(borrower), borrowShares);

        uint256 staleTotalAssets =
            _depositAndSkipForOptimizerYield(address(this));
        _setOptimizerVaultFeedAnswer(1e8);
        (uint256 staleDebtPrice, uint256 staleDebtPriceError) =
            _oracleManager.getPrice(address(optimizer), true, true);
        assertEq(staleDebtPriceError, NO_ERROR);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before partial repay"
        );

        uint256 repayShares = 100_000e6;
        vm.startPrank(borrower);
        IERC20(address(optimizer))
            .approve(address(optimizerDebtCToken), repayShares);
        optimizerDebtCToken.repay(repayShares);
        vm.stopPrank();

        (uint256 freshDebtPrice, uint256 freshDebtPriceError) =
            _oracleManager.getPrice(address(optimizer), true, true);
        assertEq(freshDebtPriceError, NO_ERROR);
        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "optimizer-share repay transfer should accrue before residual review"
        );
        assertGt(
            freshDebtPrice,
            staleDebtPrice,
            "residual debt review should see the transfer-refreshed debt asset price"
        );
        assertEq(optimizer.balanceOf(borrower), borrowShares - repayShares);
        assertGt(optimizerDebtCToken.debtBalance(borrower), 0);
    }

    function test_lendingOptimizer_plainBorrowableOptimizerDebtLiquidationWaitsForOptimizerAccrual()
        public
    {
        (
            ,
            BorrowableCToken optimizerDebtCToken,
            MockERC20 collateral,
            SimpleCToken collateralCToken
        ) = _deployPlainBorrowableOptimizerDebtMarket();

        uint256 lenderShares = 1_000_000e6;
        optimizerDebtCToken.deposit(lenderShares, address(this));

        uint256 borrowShares = 250_000e6;
        address borrower = makeAddr("plainOptimizerDebtLiqBorrower");
        {
            (uint256 staleDebtPrice, uint256 staleDebtPriceError) =
                _oracleManager.getPrice(address(optimizer), true, false);
            assertEq(staleDebtPriceError, NO_ERROR);
            uint256 staleDebtValue =
                FixedPointMathLib.mulDivUp(borrowShares, staleDebtPrice, 1e6);
            uint256 collateralAmount =
                FixedPointMathLib.mulDivUp(staleDebtValue + 10e18, BPS, 7000);

            collateral.mint(borrower, collateralAmount);
            vm.startPrank(borrower);
            IERC20(address(collateral))
                .approve(address(collateralCToken), collateralAmount);
            collateralCToken.depositAsCollateral(collateralAmount, borrower);
            optimizerDebtCToken.borrow(borrowShares, borrower);
            vm.stopPrank();
        }

        address liquidator = makeAddr("plainOptimizerDebtLiquidator");
        uint256 liquidatorShares = 500_000e6;
        {
            deal(USDC_MONAD, liquidator, liquidatorShares);
            vm.startPrank(liquidator);
            IERC20(USDC_MONAD).approve(address(optimizer), liquidatorShares);
            optimizer.deposit(liquidatorShares, liquidator);
            IERC20(address(optimizer))
                .approve(address(optimizerDebtCToken), type(uint256).max);
            vm.stopPrank();
        }

        uint256 staleTotalAssets = optimizer.totalAssets();
        _mockOptimizerApprovedMarketAssets(staleTotalAssets * 20);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before plain debt liquidation"
        );

        address[] memory accounts = new address[](1);
        accounts[0] = borrower;

        vm.startPrank(liquidator);
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__NoLiquidationAvailable
                .selector
        );
        optimizerDebtCToken.liquidate(accounts, address(collateralCToken));
        vm.stopPrank();

        optimizer.accrueIfNeeded();
        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "fresh accrual must reveal higher optimizer debt value"
        );

        uint256 borrowerDebtBefore = optimizerDebtCToken.debtBalance(borrower);
        uint256 liquidatorCollateralBefore = collateralCToken.balanceOf(liquidator);
        vm.startPrank(liquidator);
        optimizerDebtCToken.liquidate(accounts, address(collateralCToken));
        vm.stopPrank();

        assertLt(
            optimizerDebtCToken.debtBalance(borrower),
            borrowerDebtBefore,
            "fresh liquidation should reduce borrower optimizer-share debt"
        );
        assertGt(
            collateralCToken.balanceOf(liquidator),
            liquidatorCollateralBefore,
            "liquidator should receive non-optimizer collateral"
        );

        vm.clearMockedCalls();
    }

    function test_lendingOptimizer_plainBorrowableOptimizerDebtLiquidationExactWaitsForOptimizerAccrual()
        public
    {
        (
            ,
            BorrowableCToken optimizerDebtCToken,
            MockERC20 collateral,
            SimpleCToken collateralCToken
        ) = _deployPlainBorrowableOptimizerDebtMarket();

        uint256 lenderShares = 1_000_000e6;
        optimizerDebtCToken.deposit(lenderShares, address(this));

        uint256 borrowShares = 250_000e6;
        address borrower = makeAddr("plainOptimizerDebtExactBorrower");
        {
            (uint256 staleDebtPrice, uint256 staleDebtPriceError) =
                _oracleManager.getPrice(address(optimizer), true, false);
            assertEq(staleDebtPriceError, NO_ERROR);
            uint256 staleDebtValue =
                FixedPointMathLib.mulDivUp(borrowShares, staleDebtPrice, 1e6);
            uint256 collateralAmount =
                FixedPointMathLib.mulDivUp(staleDebtValue + 10e18, BPS, 7000);

            collateral.mint(borrower, collateralAmount);
            vm.startPrank(borrower);
            IERC20(address(collateral))
                .approve(address(collateralCToken), collateralAmount);
            collateralCToken.depositAsCollateral(collateralAmount, borrower);
            optimizerDebtCToken.borrow(borrowShares, borrower);
            vm.stopPrank();
        }

        address liquidator = makeAddr("plainOptimizerDebtExactLiquidator");
        uint256 liquidatorShares = 500_000e6;
        {
            deal(USDC_MONAD, liquidator, liquidatorShares);
            vm.startPrank(liquidator);
            IERC20(USDC_MONAD).approve(address(optimizer), liquidatorShares);
            optimizer.deposit(liquidatorShares, liquidator);
            IERC20(address(optimizer))
                .approve(address(optimizerDebtCToken), type(uint256).max);
            vm.stopPrank();
        }

        uint256 staleTotalAssets = optimizer.totalAssets();
        _mockOptimizerApprovedMarketAssets(staleTotalAssets * 20);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before exact plain debt liquidation"
        );

        address[] memory accounts = new address[](1);
        accounts[0] = borrower;
        uint256[] memory debtAmounts = new uint256[](1);
        debtAmounts[0] = borrowShares / 50;

        vm.startPrank(liquidator);
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__NoLiquidationAvailable
                .selector
        );
        optimizerDebtCToken.liquidateExact(
            debtAmounts,
            accounts,
            address(collateralCToken)
        );
        vm.stopPrank();

        optimizer.accrueIfNeeded();
        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "fresh accrual must reveal higher optimizer debt value"
        );

        uint256 borrowerDebtBefore = optimizerDebtCToken.debtBalance(borrower);
        uint256 liquidatorOptimizerBefore = optimizer.balanceOf(liquidator);
        uint256 liquidatorCollateralBefore = collateralCToken.balanceOf(liquidator);
        vm.startPrank(liquidator);
        optimizerDebtCToken.liquidateExact(
            debtAmounts,
            accounts,
            address(collateralCToken)
        );
        vm.stopPrank();

        assertEq(
            liquidatorOptimizerBefore - optimizer.balanceOf(liquidator),
            debtAmounts[0],
            "fresh exact liquidation should collect requested optimizer-share debt"
        );
        assertLt(
            optimizerDebtCToken.debtBalance(borrower),
            borrowerDebtBefore,
            "fresh exact liquidation should reduce borrower optimizer-share debt"
        );
        assertGt(
            collateralCToken.balanceOf(liquidator),
            liquidatorCollateralBefore,
            "liquidator should receive non-optimizer collateral"
        );

        vm.clearMockedCalls();
    }

    function test_lendingOptimizer_plainSimpleOptimizerCollateralCanPassStaleBorrowCheckAfterLoss()
        public
    {
        (
            MarketManagerIsolated optimizerCollateralMarket,
            BorrowableCToken debtCToken,
            SimpleCToken optimizerCollateralCToken
        ) = _deployPlainOptimizerShareCollateralMarket();

        uint256 lendAssets = 500_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        uint256 collateralShares = optimizer.balanceOf(address(this)) / 2;
        IERC20(address(optimizer))
            .approve(address(optimizerCollateralCToken), collateralShares);
        optimizerCollateralCToken.depositAsCollateral(
            collateralShares, address(this)
        );

        uint256 staleTotalAssets = optimizer.totalAssets();
        address[] memory approvedMarkets = optimizer.getApprovedMarkets();
        for (uint256 i; i < approvedMarkets.length; ++i) {
            uint256 cTokenShares = IBorrowableCToken(approvedMarkets[i])
                .balanceOf(address(optimizer));
            if (cTokenShares == 0) {
                continue;
            }

            vm.mockCall(
                approvedMarkets[i],
                abi.encodeWithSelector(
                    IBorrowableCToken.convertToAssets.selector, cTokenShares
                ),
                abi.encode(staleTotalAssets / 20)
            );
        }
        _refreshUsdcPriceFeed();
        _setOptimizerVaultFeedAnswer(1e8);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before plain collateral borrow"
        );

        uint256 borrowAssets = 30_000e6;
        debtCToken.borrow(borrowAssets, address(this));
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "plain optimizer-share collateral borrow check does not sync optimizer NAV"
        );

        optimizer.accrueIfNeeded();
        assertLt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "fresh accrual must reveal lower optimizer collateral value"
        );

        (, uint256 maxDebt, uint256 debt) =
            optimizerCollateralMarket.statusOf(address(this));
        assertGt(
            debt,
            maxDebt,
            "plain optimizer-share collateral can become unhealthy after fresh accrual"
        );

        vm.clearMockedCalls();
    }

    function test_lendingOptimizer_plainSimpleOptimizerCollateralLiquidationWaitsForOptimizerAccrual()
        public
    {
        (
            MarketManagerIsolated optimizerCollateralMarket,
            BorrowableCToken debtCToken,
            SimpleCToken optimizerCollateralCToken
        ) = _deployPlainOptimizerShareCollateralMarket();

        uint256 lendAssets = 500_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        uint256 collateralShares = optimizer.balanceOf(address(this)) / 2;
        IERC20(address(optimizer))
            .approve(address(optimizerCollateralCToken), collateralShares);
        optimizerCollateralCToken.depositAsCollateral(
            collateralShares, address(this)
        );

        uint256 staleTotalAssets = optimizer.totalAssets();
        address[] memory approvedMarkets = optimizer.getApprovedMarkets();
        for (uint256 i; i < approvedMarkets.length; ++i) {
            uint256 cTokenShares = IBorrowableCToken(approvedMarkets[i])
                .balanceOf(address(optimizer));
            if (cTokenShares == 0) {
                continue;
            }

            vm.mockCall(
                approvedMarkets[i],
                abi.encodeWithSelector(
                    IBorrowableCToken.convertToAssets.selector, cTokenShares
                ),
                abi.encode(staleTotalAssets / 20)
            );
        }
        _refreshUsdcPriceFeed();
        _setOptimizerVaultFeedAnswer(1e8);

        uint256 borrowAssets = 30_000e6;
        debtCToken.borrow(borrowAssets, address(this));
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "plain optimizer-share liquidation setup must leave NAV stale"
        );

        address[] memory accounts = new address[](1);
        accounts[0] = address(this);
        address liquidator = makeAddr("plainOptimizerCollateralLiquidator");
        deal(USDC_MONAD, liquidator, 100_000e6);

        vm.startPrank(liquidator);
        IERC20(USDC_MONAD).approve(address(debtCToken), type(uint256).max);
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__NoLiquidationAvailable
                .selector
        );
        debtCToken.liquidate(accounts, address(optimizerCollateralCToken));
        vm.stopPrank();

        optimizer.accrueIfNeeded();
        assertLt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "fresh accrual must reveal lower plain collateral value"
        );

        uint256 liquidatorCollateralBefore =
            optimizerCollateralCToken.balanceOf(liquidator);
        vm.startPrank(liquidator);
        debtCToken.liquidate(accounts, address(optimizerCollateralCToken));
        vm.stopPrank();

        assertLt(
            debtCToken.debtBalance(address(this)),
            borrowAssets,
            "fresh liquidation should reduce borrower debt"
        );
        assertGt(
            optimizerCollateralCToken.balanceOf(liquidator),
            liquidatorCollateralBefore,
            "liquidator should receive plain optimizer-share collateral"
        );

        vm.clearMockedCalls();
    }

    function test_lendingOptimizerShareCToken_verifyLaunchReadbackRejectsNonzeroDebtCap()
        public
    {
        (
            MarketManagerIsolated optimizerMarket,,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();

        VerifyOptimizerShareLaunch verifier = new VerifyOptimizerShareLaunch();
        VerifyOptimizerShareLaunch.Config memory config =
            _optimizerShareLaunchConfig(optimizerMarket, shareCToken);

        verifier.verify(config);

        _configureToken(
            optimizerMarket, address(shareCToken), 7000, 1_000_000e6, 1
        );

        vm.expectRevert(
            VerifyOptimizerShareLaunch.VerifyOptimizerShareLaunch__InvalidConfig
                .selector
        );
        verifier.verify(config);
    }

    function test_lendingOptimizerShareCToken_verifyLaunchRunReadsEnvTuple()
        public
    {
        (
            MarketManagerIsolated optimizerMarket,,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();

        VerifyOptimizerShareLaunch.Config memory config =
            _optimizerShareLaunchConfig(optimizerMarket, shareCToken);
        _setOptimizerShareLaunchEnv(config);

        (new VerifyOptimizerShareLaunch()).run();
    }

    function test_lendingOptimizerShareCToken_simpleZapperSwapIntoShareWrapperUsesRealizedShares()
        public
    {
        (,, LendingOptimizerShareCToken shareCToken) =
            _deployOptimizerShareLaunchMarket();

        SimpleZapper simpleZapper =
            new SimpleZapper(liveCentralRegistry, USDC_MONAD);
        OptimizerShareSwapTarget swapTarget = new OptimizerShareSwapTarget(
            IERC20(USDC_MONAD), IERC20(address(optimizer))
        );
        CentralRegistry(address(liveCentralRegistry))
            .setExternalCalldataChecker(
                address(swapTarget),
                address(new MockCalldataChecker(address(swapTarget)))
            );

        uint256 inputAssets = 25_000e6;
        uint256 optimizerBalanceBefore =
            IERC20(address(optimizer)).balanceOf(address(this));
        _mintOptimizerShares(inputAssets);
        uint256 optimizerSharesOut = IERC20(address(optimizer))
            .balanceOf(address(this)) - optimizerBalanceBefore;
        assertGt(optimizerSharesOut, 0, "mock swap output must be funded");
        IERC20(address(optimizer))
            .transfer(address(swapTarget), optimizerSharesOut);

        SwapperLib.Swap memory swapAction = SwapperLib.Swap({
            inputToken: USDC_MONAD,
            inputAmount: inputAssets,
            outputToken: address(optimizer),
            target: address(swapTarget),
            slippage: WAD - 1,
            call: abi.encodeWithSelector(
                OptimizerShareSwapTarget.swap.selector,
                inputAssets,
                optimizerSharesOut
            )
        });

        address zapperUser = makeAddr("simpleZapperOptimizerShareUser");
        deal(USDC_MONAD, zapperUser, inputAssets);
        uint256 expectedWrapperShares =
            shareCToken.previewDeposit(optimizerSharesOut);
        uint256 marketCollateralBefore = shareCToken.marketCollateralPosted();

        vm.startPrank(zapperUser);
        IERC20(USDC_MONAD).approve(address(simpleZapper), inputAssets);
        shareCToken.setDelegateApproval(address(simpleZapper), true);
        uint256 wrapperShares = simpleZapper.swapAndDeposit(
            address(shareCToken),
            false,
            swapAction,
            expectedWrapperShares,
            true,
            zapperUser
        );
        vm.stopPrank();

        assertEq(wrapperShares, expectedWrapperShares);
        assertEq(shareCToken.balanceOf(zapperUser), wrapperShares);
        assertEq(shareCToken.collateralPosted(zapperUser), wrapperShares);
        assertEq(
            shareCToken.marketCollateralPosted(),
            marketCollateralBefore + wrapperShares
        );
        assertEq(shareCToken.debtBalance(zapperUser), 0);
        assertEq(shareCToken.marketOutstandingDebt(), 0);
        assertEq(
            IERC20(address(optimizer)).balanceOf(address(simpleZapper)), 0
        );
        assertEq(IERC20(USDC_MONAD).balanceOf(address(simpleZapper)), 0);
        assertEq(IERC20(address(optimizer)).balanceOf(address(swapTarget)), 0);
        assertEq(
            IERC20(USDC_MONAD).balanceOf(address(swapTarget)), inputAssets
        );
    }

    function test_lendingOptimizerShareCToken_rewardZapperClaimSwapDepositsRealizedOptimizerShares()
        public
    {
        (,, LendingOptimizerShareCToken shareCToken) =
            _deployOptimizerShareLaunchMarket();
        OptimizerShareSwapTarget swapTarget = new OptimizerShareSwapTarget(
            IERC20(USDC_MONAD), IERC20(address(optimizer))
        );
        CentralRegistry(address(liveCentralRegistry))
            .setExternalCalldataChecker(
                address(swapTarget),
                address(new MockCalldataChecker(address(swapTarget)))
            );
        MockRewardManagerForZapper rewardManagerMock =
            new MockRewardManagerForZapper(IERC20(USDC_MONAD));
        CentralRegistry(address(liveCentralRegistry))
            .setRewardManager(address(rewardManagerMock));
        SimpleRewardZapper rewardZapper =
            new SimpleRewardZapper(liveCentralRegistry, USDC_MONAD);

        address rewardUser = makeAddr("optimizerShareRewardZapperUser");
        uint256 rewardAssets = 25_000e6;
        deal(USDC_MONAD, address(rewardManagerMock), rewardAssets);
        rewardManagerMock.setReward(rewardUser, rewardAssets);
        uint256 optimizerBalanceBefore =
            IERC20(address(optimizer)).balanceOf(address(this));
        _mintOptimizerShares(rewardAssets);
        uint256 optimizerSharesOut = IERC20(address(optimizer))
            .balanceOf(address(this)) - optimizerBalanceBefore;
        assertGt(
            optimizerSharesOut, 0, "mock reward swap output must be funded"
        );
        IERC20(address(optimizer))
            .transfer(address(swapTarget), optimizerSharesOut);

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        _refreshUsdcPriceFeed();
        _setOptimizerVaultFeedAnswer(1e8);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before reward zap"
        );

        uint256 expectedWrapperShares =
            shareCToken.previewDeposit(optimizerSharesOut);
        uint256 marketCollateralBefore = shareCToken.marketCollateralPosted();

        SwapperLib.Swap memory swapAction = SwapperLib.Swap({
            inputToken: USDC_MONAD,
            inputAmount: rewardAssets,
            outputToken: address(optimizer),
            target: address(swapTarget),
            slippage: WAD - 1,
            call: abi.encodeWithSelector(
                OptimizerShareSwapTarget.swap.selector,
                rewardAssets,
                optimizerSharesOut
            )
        });

        vm.startPrank(rewardUser);
        shareCToken.setDelegateApproval(address(rewardZapper), true);
        uint256 wrapperShares = rewardZapper.claimSwapAndDeposit(
            address(shareCToken),
            swapAction,
            expectedWrapperShares,
            true,
            rewardUser
        );
        vm.stopPrank();

        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "reward zapper optimizer-share output must sync optimizer NAV"
        );
        assertEq(
            wrapperShares,
            expectedWrapperShares,
            "returned final wrapper shares"
        );
        assertEq(
            shareCToken.balanceOf(rewardUser),
            wrapperShares,
            "reward user wrapper shares"
        );
        assertEq(
            shareCToken.collateralPosted(rewardUser),
            wrapperShares,
            "reward user collateralized shares"
        );
        assertEq(
            shareCToken.marketCollateralPosted(),
            marketCollateralBefore + wrapperShares,
            "market collateralized shares"
        );
        assertEq(rewardManagerMock.rewards(rewardUser), 0, "rewards claimed");
        assertEq(
            IERC20(USDC_MONAD).balanceOf(address(rewardZapper)),
            0,
            "reward zapper USDC residue"
        );
        assertEq(
            IERC20(address(optimizer)).balanceOf(address(rewardZapper)),
            0,
            "reward zapper optimizer residue"
        );
        assertEq(
            shareCToken.balanceOf(address(rewardZapper)),
            0,
            "reward zapper wrapper residue"
        );
        assertEq(
            IERC20(address(optimizer)).balanceOf(address(swapTarget)),
            0,
            "swap target spent optimizer output"
        );
        assertEq(
            IERC20(USDC_MONAD).balanceOf(address(swapTarget)),
            rewardAssets,
            "swap target reward input"
        );
    }

    function test_lendingOptimizerShareCToken_vaultZapperDepositsThroughOptimizerAndUsesFinalWrapperShares()
        public
    {
        (,, LendingOptimizerShareCToken shareCToken) =
            _deployOptimizerShareLaunchMarket();
        VaultZapper vaultZapper =
            new VaultZapper(liveCentralRegistry, USDC_MONAD);

        address zapperUser = makeAddr("optimizerVaultZapperUser");
        uint256 inputAssets = 25_000e6;
        deal(USDC_MONAD, zapperUser, inputAssets);

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        _refreshUsdcPriceFeed();
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before vault zapper deposit"
        );

        (uint256 expectedOptimizerShares, uint256 expectedWrapperShares) = _quoteOptimizerVaultZapperShares(
            zapperUser, shareCToken, inputAssets
        );
        uint256[3] memory beforeState = [
            shareCToken.marketCollateralPosted(),
            shareCToken.totalAssets(),
            IERC20(address(optimizer)).balanceOf(address(shareCToken))
        ];

        uint256 wrapperShares = _runOptimizerVaultZapperDeposit(
            vaultZapper,
            shareCToken,
            zapperUser,
            inputAssets,
            expectedWrapperShares
        );

        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "optimizer deposit path must refresh NAV"
        );
        assertEq(
            wrapperShares,
            expectedWrapperShares,
            "returned final wrapper shares"
        );
        assertEq(
            shareCToken.balanceOf(zapperUser),
            wrapperShares,
            "user wrapper shares"
        );
        assertEq(
            shareCToken.collateralPosted(zapperUser),
            wrapperShares,
            "user collateralized shares"
        );
        assertEq(
            shareCToken.marketCollateralPosted(),
            beforeState[0] + wrapperShares,
            "market collateralized shares"
        );
        assertEq(
            shareCToken.totalAssets(),
            beforeState[1] + expectedOptimizerShares,
            "wrapper tracks actual optimizer shares minted by vault deposit"
        );
        assertEq(
            IERC20(address(optimizer)).balanceOf(address(shareCToken)),
            beforeState[2] + expectedOptimizerShares,
            "wrapper received actual optimizer shares"
        );
        assertEq(
            IERC20(USDC_MONAD).balanceOf(address(vaultZapper)),
            0,
            "zapper USDC residue"
        );
        assertEq(
            IERC20(address(optimizer)).balanceOf(address(vaultZapper)),
            0,
            "zapper optimizer residue"
        );
        assertEq(
            shareCToken.balanceOf(address(vaultZapper)),
            0,
            "zapper wrapper residue"
        );
    }

    function test_lendingOptimizerShareCToken_vaultZapperHighExpectedSharesRollsBackNestedOptimizerDeposit()
        public
    {
        (,, LendingOptimizerShareCToken shareCToken) =
            _deployOptimizerShareLaunchMarket();
        VaultZapper vaultZapper =
            new VaultZapper(liveCentralRegistry, USDC_MONAD);

        address zapperUser = makeAddr("optimizerVaultZapperRollbackUser");
        uint256 inputAssets = 25_000e6;
        deal(USDC_MONAD, zapperUser, inputAssets);

        skip(30 days);
        _refreshUsdcPriceFeed();
        (, uint256 expectedWrapperShares) = _quoteOptimizerVaultZapperShares(
            zapperUser, shareCToken, inputAssets
        );

        uint256[5] memory beforeState = [
            optimizer.totalAssets(),
            shareCToken.totalAssets(),
            shareCToken.totalSupply(),
            IERC20(address(optimizer)).balanceOf(address(shareCToken)),
            shareCToken.balanceOf(zapperUser)
        ];

        _expectOptimizerVaultZapperDepositRevert(
            vaultZapper,
            shareCToken,
            zapperUser,
            inputAssets,
            expectedWrapperShares + 1
        );

        assertEq(
            optimizer.totalAssets(), beforeState[0], "optimizer NAV rollback"
        );
        assertEq(
            IERC20(USDC_MONAD).balanceOf(zapperUser),
            inputAssets,
            "user USDC rollback"
        );
        assertEq(
            shareCToken.totalAssets(),
            beforeState[1],
            "wrapper total assets rollback"
        );
        assertEq(
            shareCToken.totalSupply(),
            beforeState[2],
            "wrapper supply rollback"
        );
        assertEq(
            IERC20(address(optimizer)).balanceOf(address(shareCToken)),
            beforeState[3],
            "wrapper optimizer balance rollback"
        );
        assertEq(
            shareCToken.balanceOf(zapperUser),
            beforeState[4],
            "user wrapper balance rollback"
        );
        assertEq(
            IERC20(USDC_MONAD).balanceOf(address(vaultZapper)),
            0,
            "zapper USDC residue"
        );
        assertEq(
            IERC20(address(optimizer)).balanceOf(address(vaultZapper)),
            0,
            "zapper optimizer residue"
        );
        assertEq(
            shareCToken.balanceOf(address(vaultZapper)),
            0,
            "zapper wrapper residue"
        );
    }

    function test_lendingOptimizerShareCToken_simpleZapperCollateralExitRollsBackWhenOptimizerPriceFails()
        public
    {
        (
            ,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();

        SimpleZapper simpleZapper =
            new SimpleZapper(liveCentralRegistry, USDC_MONAD);

        uint256 lendAssets = 100_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        uint256 optimizerShares = optimizer.balanceOf(address(this));
        IERC20(address(optimizer))
            .approve(address(shareCToken), optimizerShares);
        uint256 wrapperShares =
            shareCToken.deposit(optimizerShares, address(this));
        shareCToken.postCollateral(wrapperShares);
        debtCToken.borrow(20_000e6, address(this));
        shareCToken.setDelegateApproval(address(simpleZapper), true);

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        _refreshUsdcPriceFeed();
        uint256 sharesToRedeem = wrapperShares / 20;
        uint256 optimizerSharesToExit =
            shareCToken.previewRedeem(sharesToRedeem);

        address receiver = makeAddr("zapperFailedExitReceiver");
        uint256[7] memory beforeState = [
            staleTotalAssets,
            shareCToken.balanceOf(address(this)),
            shareCToken.collateralPosted(address(this)),
            shareCToken.marketCollateralPosted(),
            debtCToken.debtBalance(address(this)),
            optimizer.balanceOf(address(simpleZapper)),
            optimizer.balanceOf(receiver)
        ];

        vm.mockCall(
            address(optimizer),
            abi.encodeWithSelector(ILendingOptimizer.asset.selector),
            abi.encode(makeAddr("driftedOptimizerAssetForZapperExit"))
        );

        BaseZapper.RedeemAction memory redeemAction;
        redeemAction.cToken = address(shareCToken);
        redeemAction.shares = sharesToRedeem;
        redeemAction.forceRedeemCollateral = true;

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = address(optimizer);
        swapAction.inputAmount = optimizerSharesToExit;
        swapAction.outputToken = USDC_MONAD;

        vm.expectRevert(OracleManager.OracleManager__ErrorCodeFlagged.selector);
        simpleZapper.redeemAndSwap(redeemAction, swapAction, receiver);

        assertEq(
            optimizer.totalAssets(),
            beforeState[0],
            "failed zapper exit must roll back optimizer NAV accrual"
        );
        assertEq(
            shareCToken.balanceOf(address(this)),
            beforeState[1],
            "owner wrapper balance"
        );
        assertEq(
            shareCToken.collateralPosted(address(this)),
            beforeState[2],
            "owner collateral"
        );
        assertEq(
            shareCToken.marketCollateralPosted(),
            beforeState[3],
            "market collateral"
        );
        assertEq(
            debtCToken.debtBalance(address(this)),
            beforeState[4],
            "debt must not change"
        );
        assertEq(
            optimizer.balanceOf(address(simpleZapper)),
            beforeState[5],
            "zapper optimizer residue"
        );
        assertEq(
            optimizer.balanceOf(receiver),
            beforeState[6],
            "receiver optimizer balance"
        );
        assertEq(
            IERC20(USDC_MONAD).balanceOf(address(simpleZapper)),
            0,
            "zapper USDC residue"
        );
    }

    function test_lendingOptimizerShareCToken_simpleZapperCollateralExitSwapSafeUsesGuardedOracleValue()
        public
    {
        (
            ,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();

        SimpleZapper simpleZapper =
            new SimpleZapper(liveCentralRegistry, USDC_MONAD);
        OptimizerShareSwapTarget swapTarget = new OptimizerShareSwapTarget(
            IERC20(address(optimizer)), IERC20(USDC_MONAD)
        );
        CentralRegistry(address(liveCentralRegistry))
            .setExternalCalldataChecker(
                address(swapTarget),
                address(new MockCalldataChecker(address(swapTarget)))
            );

        uint256 lendAssets = 100_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        uint256 yieldSeedAssets = 200_000e6;
        deal(USDC_MONAD, address(this), yieldSeedAssets);
        IERC20(USDC_MONAD).approve(address(optimizer), yieldSeedAssets);
        LendingOptimizerHarness(address(optimizer))
            .depositToMarket(yieldSeedAssets, address(this), cUSDC_WMON_MARKET);

        uint256 optimizerShares = optimizer.balanceOf(address(this));
        IERC20(address(optimizer))
            .approve(address(shareCToken), optimizerShares);
        uint256 wrapperShares =
            shareCToken.deposit(optimizerShares, address(this));
        shareCToken.postCollateral(wrapperShares);
        debtCToken.borrow(20_000e6, address(this));
        shareCToken.setDelegateApproval(address(simpleZapper), true);

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(3650 days);
        _refreshUsdcPriceFeed();
        _setOptimizerVaultFeedAnswer(1e8);
        uint256 sharesToRedeem = wrapperShares / 20;
        uint256 optimizerSharesToExit =
            shareCToken.previewRedeem(sharesToRedeem);
        uint256 staleOutputAssets =
            optimizer.convertToAssets(optimizerSharesToExit);
        {
            (uint256 staleGuardedPrice, uint256 staleGuardedError) =
                _oracleManager.getPrice(address(optimizer), true, true);
            assertEq(staleGuardedError, NO_ERROR);

            uint256 snapshotId = vm.snapshotState();
            optimizer.exchangeRateUpdated();
            uint256 freshOutputAssets =
                optimizer.convertToAssets(optimizerSharesToExit);
            (uint256 freshGuardedPrice, uint256 freshGuardedError) =
                _oracleManager.getPrice(address(optimizer), true, true);
            assertTrue(
                vm.revertToState(snapshotId),
                "failed to restore guarded swap precondition"
            );

            assertGt(
                freshOutputAssets,
                staleOutputAssets,
                "precondition: fresh uncapped optimizer NAV must exceed stale quote"
            );
            assertEq(freshGuardedError, NO_ERROR);
            assertEq(
                freshGuardedPrice,
                staleGuardedPrice,
                "PriceGuard caps optimizer-share oracle value used by swapSafe"
            );
            assertEq(
                staleGuardedPrice,
                WAD,
                "launch PriceGuard should cap optimizer shares at base price"
            );
        }

        deal(USDC_MONAD, address(swapTarget), staleOutputAssets);

        address receiver = makeAddr("zapperGuardedPriceExitReceiver");
        uint256[7] memory beforeState = [
            staleTotalAssets,
            shareCToken.balanceOf(address(this)),
            shareCToken.collateralPosted(address(this)),
            shareCToken.marketCollateralPosted(),
            debtCToken.debtBalance(address(this)),
            optimizer.balanceOf(address(swapTarget)),
            IERC20(USDC_MONAD).balanceOf(address(swapTarget))
        ];

        uint256 outAmount;
        {
            BaseZapper.RedeemAction memory redeemAction;
            redeemAction.cToken = address(shareCToken);
            redeemAction.shares = sharesToRedeem;
            redeemAction.forceRedeemCollateral = true;

            SwapperLib.Swap memory swapAction;
            swapAction.inputToken = address(optimizer);
            swapAction.inputAmount = optimizerSharesToExit;
            swapAction.outputToken = USDC_MONAD;
            swapAction.target = address(swapTarget);
            swapAction.slippage = 0;
            swapAction.call = abi.encodeWithSelector(
                OptimizerShareSwapTarget.swap.selector,
                optimizerSharesToExit,
                staleOutputAssets
            );

            outAmount =
                simpleZapper.redeemAndSwap(redeemAction, swapAction, receiver);
        }

        assertEq(
            outAmount,
            staleOutputAssets,
            "guarded oracle value accepts stale raw output at zero slippage"
        );
        assertGt(
            optimizer.totalAssets(),
            beforeState[0],
            "successful zapper exit should commit optimizer NAV accrual"
        );
        assertEq(
            shareCToken.balanceOf(address(this)),
            beforeState[1] - sharesToRedeem,
            "owner wrapper balance"
        );
        assertEq(
            shareCToken.collateralPosted(address(this)),
            beforeState[2] - sharesToRedeem,
            "owner collateral"
        );
        assertEq(
            shareCToken.marketCollateralPosted(),
            beforeState[3] - sharesToRedeem,
            "market collateral"
        );
        assertGe(
            debtCToken.debtBalance(address(this)),
            beforeState[4],
            "debt must not be reduced by exit swap"
        );
        assertEq(
            optimizer.balanceOf(address(swapTarget)),
            beforeState[5] + optimizerSharesToExit,
            "swap target optimizer balance"
        );
        assertEq(
            IERC20(USDC_MONAD).balanceOf(address(swapTarget)),
            beforeState[6] - staleOutputAssets,
            "swap target USDC balance"
        );
        assertEq(
            IERC20(USDC_MONAD).balanceOf(receiver),
            staleOutputAssets,
            "receiver USDC output"
        );
        assertEq(
            optimizer.balanceOf(address(simpleZapper)),
            0,
            "zapper optimizer residue"
        );
        assertEq(
            IERC20(USDC_MONAD).balanceOf(address(simpleZapper)),
            0,
            "zapper USDC residue"
        );
    }

    function test_lendingOptimizerShareCToken_optimizerZapperOptimizerShareInputAccruesBeforeSwapSafe()
        public
    {
        _registerOptimizerShareVaultPriceFeed();

        OptimizerZapper optimizerZapper =
            new OptimizerZapper(liveCentralRegistry, USDC_MONAD);
        OptimizerShareSwapTarget swapTarget = new OptimizerShareSwapTarget(
            IERC20(address(optimizer)), IERC20(USDC_MONAD)
        );
        CentralRegistry(address(liveCentralRegistry))
            .setExternalCalldataChecker(
                address(swapTarget),
                address(new MockCalldataChecker(address(swapTarget)))
            );

        address zapperUser = makeAddr("optimizerZapperShareInputUser");
        uint256 seedAssets = 25_000e6;
        deal(USDC_MONAD, zapperUser, seedAssets);
        vm.startPrank(zapperUser);
        IERC20(USDC_MONAD).approve(address(optimizer), seedAssets);
        uint256 inputShares = optimizer.deposit(seedAssets, zapperUser) / 2;
        vm.stopPrank();
        assertGt(inputShares, 0, "test setup must mint optimizer shares");

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        _refreshUsdcPriceFeed();
        _setOptimizerVaultFeedAnswer(1e8);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before zapper input transfer"
        );

        uint256 outputAssets = 12_500e6;
        deal(USDC_MONAD, address(swapTarget), outputAssets);

        SwapperLib.Swap memory swapAction = SwapperLib.Swap({
            inputToken: address(optimizer),
            inputAmount: inputShares,
            outputToken: USDC_MONAD,
            target: address(swapTarget),
            slippage: WAD - 1,
            call: abi.encodeWithSelector(
                OptimizerShareSwapTarget.swap.selector,
                inputShares,
                outputAssets
            )
        });

        vm.startPrank(zapperUser);
        IERC20(address(optimizer))
            .approve(address(optimizerZapper), inputShares);
        uint256 mintedShares = optimizerZapper.swapAndDeposit(
            address(optimizer), false, swapAction, 1, zapperUser
        );
        vm.stopPrank();

        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "optimizer share input transfer must refresh NAV before swap valuation"
        );
        assertGt(mintedShares, 0, "zapper should mint optimizer shares");
        assertEq(
            IERC20(address(optimizer)).balanceOf(address(optimizerZapper)),
            0,
            "zapper optimizer share residue"
        );
        assertEq(
            IERC20(USDC_MONAD).balanceOf(address(optimizerZapper)),
            0,
            "zapper USDC residue"
        );
        assertEq(
            IERC20(address(optimizer)).balanceOf(address(swapTarget)),
            inputShares,
            "swap target receives optimizer share input"
        );
    }

    function test_lendingOptimizerShareCToken_partialInputSwapCheckerCanStrandOptimizerShareResidue()
        public
    {
        _registerOptimizerShareVaultPriceFeed();

        OptimizerZapper optimizerZapper =
            new OptimizerZapper(liveCentralRegistry, USDC_MONAD);
        PartialInputOptimizerShareSwapTarget swapTarget = new PartialInputOptimizerShareSwapTarget(
            IERC20(address(optimizer)), IERC20(USDC_MONAD)
        );
        CentralRegistry(address(liveCentralRegistry))
            .setExternalCalldataChecker(
                address(swapTarget),
                address(new MockCalldataChecker(address(swapTarget)))
            );

        address zapperUser = makeAddr("optimizerZapperPartialShareInputUser");
        uint256 seedAssets = 25_000e6;
        deal(USDC_MONAD, zapperUser, seedAssets);
        vm.startPrank(zapperUser);
        IERC20(USDC_MONAD).approve(address(optimizer), seedAssets);
        uint256 inputShares = optimizer.deposit(seedAssets, zapperUser) / 2;
        vm.stopPrank();
        assertGt(inputShares, 1, "test setup must mint optimizer shares");

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        _refreshUsdcPriceFeed();
        _setOptimizerVaultFeedAnswer(1e8);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before zapper input transfer"
        );

        uint256 spentShares = inputShares / 2;
        uint256 strandedShares = inputShares - spentShares;
        uint256 outputAssets = 12_500e6;
        deal(USDC_MONAD, address(swapTarget), outputAssets);

        SwapperLib.Swap memory swapAction = SwapperLib.Swap({
            inputToken: address(optimizer),
            inputAmount: inputShares,
            outputToken: USDC_MONAD,
            target: address(swapTarget),
            slippage: WAD - 1,
            call: abi.encodeWithSelector(
                PartialInputOptimizerShareSwapTarget.partialSwap.selector,
                spentShares,
                outputAssets
            )
        });

        vm.startPrank(zapperUser);
        IERC20(address(optimizer))
            .approve(address(optimizerZapper), inputShares);
        uint256 mintedShares = optimizerZapper.swapAndDeposit(
            address(optimizer), false, swapAction, 1, zapperUser
        );
        vm.stopPrank();

        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "optimizer share input transfer must still refresh NAV"
        );
        assertGt(mintedShares, 0, "partial route still deposits output assets");
        assertEq(
            IERC20(address(optimizer)).balanceOf(address(optimizerZapper)),
            strandedShares,
            "partial input leaves optimizer share residue in the zapper"
        );
        assertEq(
            IERC20(address(optimizer)).balanceOf(address(swapTarget)),
            spentShares,
            "swap target receives only spent optimizer shares"
        );
        assertEq(
            IERC20(USDC_MONAD).balanceOf(address(optimizerZapper)),
            0,
            "zapper deposits realized USDC output"
        );

        _assertNextOptimizerZapperFullSpendLeavesResidue(
            optimizerZapper, swapTarget, seedAssets, outputAssets, strandedShares
        );
    }

    function _assertNextOptimizerZapperFullSpendLeavesResidue(
        OptimizerZapper optimizerZapper,
        PartialInputOptimizerShareSwapTarget swapTarget,
        uint256 seedAssets,
        uint256 outputAssets,
        uint256 expectedResidue
    ) internal {
        address nextUser = makeAddr("optimizerZapperPartialShareNextUser");
        deal(USDC_MONAD, nextUser, seedAssets);
        vm.startPrank(nextUser);
        IERC20(USDC_MONAD).approve(address(optimizer), seedAssets);
        uint256 nextInputShares = optimizer.deposit(seedAssets, nextUser) / 2;
        IERC20(address(optimizer))
            .approve(address(optimizerZapper), nextInputShares);
        vm.stopPrank();
        assertGt(nextInputShares, 1, "next user must mint optimizer shares");

        uint256 swapTargetSharesBefore =
            IERC20(address(optimizer)).balanceOf(address(swapTarget));
        deal(USDC_MONAD, address(swapTarget), outputAssets);

        SwapperLib.Swap memory nextSwapAction = SwapperLib.Swap({
            inputToken: address(optimizer),
            inputAmount: nextInputShares,
            outputToken: USDC_MONAD,
            target: address(swapTarget),
            slippage: WAD - 1,
            call: abi.encodeWithSelector(
                PartialInputOptimizerShareSwapTarget.partialSwap.selector,
                nextInputShares,
                outputAssets
            )
        });

        vm.prank(nextUser);
        uint256 nextMintedShares = optimizerZapper.swapAndDeposit(
            address(optimizer), false, nextSwapAction, 1, nextUser
        );

        assertGt(nextMintedShares, 0, "next route deposits output assets");
        assertEq(
            IERC20(address(optimizer)).balanceOf(address(optimizerZapper)),
            expectedResidue,
            "next full-spend route leaves prior zapper residue stranded"
        );
        assertEq(
            IERC20(address(optimizer)).balanceOf(address(swapTarget)),
            swapTargetSharesBefore + nextInputShares,
            "next target receives only the next caller's declared input"
        );
    }

    function test_lendingOptimizerShareCToken_externalRawConsumerCanUnderpayStaleShares()
        public
    {
        uint256 staleTotalAssets = _depositAndSkipForOptimizerYield();
        uint256 sharesToSell = optimizer.balanceOf(address(this)) / 2;
        assertGt(sharesToSell, 0, "test setup must have optimizer shares");
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before external quote"
        );

        ExternalRawOptimizerShareBuyer buyer =
            new ExternalRawOptimizerShareBuyer(IERC20(USDC_MONAD));
        deal(USDC_MONAD, address(buyer), 1_000_000e6);

        uint256 staleQuote = optimizer.convertToAssets(sharesToSell);
        uint256 sellerAssetBalanceBefore =
            IERC20(USDC_MONAD).balanceOf(address(this));

        IERC20(address(optimizer)).approve(address(buyer), sharesToSell);
        uint256 assetsPaid = buyer.buyAtRawQuote(
            ILendingOptimizer(address(optimizer)), sharesToSell, address(this)
        );

        assertEq(assetsPaid, staleQuote);
        assertEq(
            IERC20(USDC_MONAD).balanceOf(address(this)),
            sellerAssetBalanceBefore + staleQuote
        );
        assertEq(optimizer.balanceOf(address(buyer)), sharesToSell);

        uint256 freshValue = optimizer.convertToAssets(sharesToSell);
        assertGt(
            freshValue,
            assetsPaid,
            "external raw quote can underpay shares before transfer accrual"
        );
    }

    function test_lendingOptimizerShareCToken_externalRawLendingMarketCanOvercreditStaleSharesAfterLoss()
        public
    {
        _mintOptimizerShares(100_000e6);
        uint256 sharesToDeposit = optimizer.balanceOf(address(this)) / 2;
        uint256 staleQuote = optimizer.convertToAssets(sharesToDeposit);
        uint256 cTokenShares =
            IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer));
        uint256 staleTotalAssets = optimizer.totalAssets();
        assertGt(cTokenShares, 0, "test setup must hold cToken shares");
        assertGt(staleQuote, 0, "test setup must quote collateral");

        ExternalRawOptimizerShareLendingMarket lendingMarket =
            new ExternalRawOptimizerShareLendingMarket();

        vm.mockCall(
            cUSDC_WMON_MARKET,
            abi.encodeWithSelector(
                IBorrowableCToken.convertToAssets.selector, cTokenShares
            ),
            abi.encode(staleTotalAssets / 2)
        );

        IERC20(address(optimizer))
            .approve(address(lendingMarket), sharesToDeposit);
        uint256 recordedCollateral = lendingMarket.depositAtRawCollateralValue(
            ILendingOptimizer(address(optimizer)),
            sharesToDeposit,
            address(this)
        );

        uint256 freshValue = optimizer.convertToAssets(sharesToDeposit);
        assertEq(recordedCollateral, staleQuote);
        assertEq(lendingMarket.collateralValue(address(this)), staleQuote);
        assertGt(
            recordedCollateral,
            freshValue,
            "external raw lending market can overcredit stale shares after loss"
        );

        vm.clearMockedCalls();
    }

    function test_lendingOptimizerShareCToken_externalRawLenderCanLiquidateFreshHealthyCollateral()
        public
    {
        address borrower = makeAddr("externalRawLenderBorrower");
        address liquidator = makeAddr("externalRawLenderLiquidator");
        uint256 ltvBps = 8000;

        (
            ExternalRawOptimizerShareLender lender,
            uint256 collateralShares,
            uint256 debtAssets
        ) = _openExternalRawLenderPosition(borrower, ltvBps);

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before external lending health check"
        );

        uint256 rawBorrowLimit = lender.rawBorrowLimit(
            ILendingOptimizer(address(optimizer)), borrower
        );
        assertGt(
            debtAssets, rawBorrowLimit, "raw external health check liquidates"
        );

        _liquidateExternalRawLenderPosition(
            lender, borrower, liquidator, collateralShares, debtAssets, ltvBps
        );
    }

    function test_lendingOptimizerShareCToken_externalRawVaultLenderCanLiquidateFreshHealthyCollateral()
        public
    {
        address borrower = makeAddr("externalRawVaultLenderBorrower");
        address liquidator = makeAddr("externalRawVaultLenderLiquidator");
        uint256 ltvBps = 8000;

        (
            ExternalRawOptimizerShareVault vault,
            ExternalRawOptimizerShareVaultLender lender,
            uint256 vaultShares,
            uint256 debtAssets
        ) = _openExternalRawVaultLenderPosition(borrower, ltvBps);

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before raw-vault health check"
        );

        uint256 staleBorrowLimit = lender.rawBorrowLimit(
            vault, ILendingOptimizer(address(optimizer)), borrower
        );
        assertGt(
            debtAssets,
            staleBorrowLimit,
            "external raw-vault health check liquidates"
        );

        _liquidateExternalRawVaultLenderPosition(
            vault,
            lender,
            borrower,
            liquidator,
            vaultShares,
            debtAssets,
            ltvBps,
            staleTotalAssets
        );
    }

    function test_lendingOptimizerShareCToken_externalWrapperLenderCanLiquidateFreshHealthyCollateral()
        public
    {
        address borrower = makeAddr("externalWrapperLenderBorrower");
        address liquidator = makeAddr("externalWrapperLenderLiquidator");
        uint256 ltvBps = 8000;

        (
            ExternalOptimizerShareCTokenLender lender,
            uint256 wrapperShares,
            uint256 debtAssets
        ) = _openExternalWrapperLenderPosition(borrower, ltvBps);

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before wrapper health check"
        );

        uint256 staleBorrowLimit = lender.rawBorrowLimit(
            optimizerCToken, ILendingOptimizer(address(optimizer)), borrower
        );
        assertGt(
            debtAssets,
            staleBorrowLimit,
            "external wrapper health check liquidates"
        );

        _liquidateExternalWrapperLenderPosition(
            lender,
            borrower,
            liquidator,
            wrapperShares,
            debtAssets,
            ltvBps,
            staleTotalAssets
        );
    }

    function test_lendingOptimizerShareCToken_externalSecondLayerVaultLenderCanLiquidateFreshHealthyCollateral()
        public
    {
        address borrower = makeAddr("externalVaultLenderBorrower");
        address liquidator = makeAddr("externalVaultLenderLiquidator");
        uint256 ltvBps = 8000;

        (
            ExternalOptimizerShareCTokenVault vault,
            ExternalOptimizerShareVaultLender lender,
            uint256 vaultShares,
            uint256 debtAssets
        ) = _openExternalWrapperVaultLenderPosition(borrower, ltvBps);

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before outer-vault health check"
        );

        uint256 staleBorrowLimit = lender.rawBorrowLimit(
            vault, optimizerCToken, ILendingOptimizer(address(optimizer)), borrower
        );
        assertGt(
            debtAssets,
            staleBorrowLimit,
            "external outer-vault health check liquidates"
        );

        _liquidateExternalWrapperVaultLenderPosition(
            vault,
            lender,
            borrower,
            liquidator,
            vaultShares,
            debtAssets,
            ltvBps,
            staleTotalAssets
        );
    }

    function test_lendingOptimizerShareCToken_feeManagerOTCUsesStaleRawOptimizerSharePriceWhenEarmarked()
        public
    {
        _registerOptimizerShareVaultPriceFeed();
        FeeManager otcFeeManager = new FeeManager(liveCentralRegistry);
        CentralRegistry(address(liveCentralRegistry))
            .setFeeManager(address(otcFeeManager));

        uint256 sharesToOTC = optimizer.balanceOf(address(this)) / 4;
        assertGt(sharesToOTC, 0, "test setup must have optimizer shares");
        IERC20(address(optimizer))
            .transfer(address(otcFeeManager), sharesToOTC);

        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = address(optimizer);
        otcFeeManager.addRewardTokens(rewardTokens);
        otcFeeManager.setEarmarked(address(optimizer), true);

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(1 days);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before permissioned OTC quote"
        );
        _refreshUsdcPriceFeed();

        (uint256 staleOptimizerPrice, uint256 staleError) =
            _oracleManager.getPrice(address(optimizer), true, true);
        (uint256 feeTokenPrice, uint256 feeTokenError) =
            _oracleManager.getPrice(USDC_MONAD, true, true);
        assertEq(staleError, NO_ERROR);
        assertEq(feeTokenError, NO_ERROR);

        uint256 staleRequiredFeeTokens = _feeTokenRequiredForOTC(
            address(optimizer), sharesToOTC, staleOptimizerPrice, feeTokenPrice
        );
        deal(USDC_MONAD, address(this), staleRequiredFeeTokens);
        IERC20(USDC_MONAD)
            .approve(address(otcFeeManager), staleRequiredFeeTokens);

        uint256 feeManagerFeeTokenBefore =
            IERC20(USDC_MONAD).balanceOf(address(otcFeeManager));
        uint256 daoSharesBefore =
            optimizer.balanceOf(liveCentralRegistry.daoAddress());

        otcFeeManager.executeOTC(
            address(optimizer),
            sharesToOTC,
            staleRequiredFeeTokens,
            0,
            block.timestamp
        );

        assertEq(
            IERC20(USDC_MONAD).balanceOf(address(otcFeeManager)),
            feeManagerFeeTokenBefore + staleRequiredFeeTokens
        );
        assertGe(
            optimizer.balanceOf(liveCentralRegistry.daoAddress()),
            daoSharesBefore + sharesToOTC,
            "DAO receives OTC shares plus any optimizer performance fee shares"
        );

        (uint256 freshOptimizerPrice, uint256 freshError) =
            _oracleManager.getPrice(address(optimizer), true, true);
        assertEq(freshError, NO_ERROR);

        uint256 freshRequiredFeeTokens = _feeTokenRequiredForOTC(
            address(optimizer), sharesToOTC, freshOptimizerPrice, feeTokenPrice
        );
        assertGt(
            freshRequiredFeeTokens,
            staleRequiredFeeTokens,
            "permissioned OTC can settle optimizer shares from stale raw price"
        );
    }

    function test_lendingOptimizerShareCToken_feeManagerMultiSwapRefreshesOptimizerShareInputBeforeSlippageCheck()
        public
    {
        _registerOptimizerShareVaultPriceFeed();
        _refreshUsdcPriceFeed();

        FeeManager swapFeeManager = new FeeManager(liveCentralRegistry);
        CentralRegistry(address(liveCentralRegistry))
            .setFeeManager(address(swapFeeManager));
        CentralRegistry(address(liveCentralRegistry))
            .addHarvestPermissions(address(this));

        uint256 sharesToSwap = optimizer.balanceOf(address(this)) / 4;
        assertGt(sharesToSwap, 0, "test setup must have optimizer shares");
        IERC20(address(optimizer))
            .transfer(address(swapFeeManager), sharesToSwap);

        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = address(optimizer);
        swapFeeManager.addRewardTokens(rewardTokens);

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(1 days);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before permissioned multiSwap"
        );

        uint256 feeTokenPrice;
        uint256 staleFeeTokenOut;
        {
            (uint256 staleOptimizerPrice, uint256 staleOptimizerError) =
                _oracleManager.getPrice(address(optimizer), true, true);
            uint256 feeTokenError;
            (feeTokenPrice, feeTokenError) =
                _oracleManager.getPrice(USDC_MONAD, true, true);
            assertEq(staleOptimizerError, NO_ERROR);
            assertEq(feeTokenError, NO_ERROR);

            staleFeeTokenOut = _feeTokenRequiredForOTC(
                address(optimizer),
                sharesToSwap,
                staleOptimizerPrice,
                feeTokenPrice
            );
        }
        OptimizerShareSwapTarget swapTarget = new OptimizerShareSwapTarget(
            IERC20(address(optimizer)), IERC20(USDC_MONAD)
        );
        deal(USDC_MONAD, address(swapTarget), staleFeeTokenOut);
        CentralRegistry(address(liveCentralRegistry))
            .setExternalCalldataChecker(
                address(swapTarget),
                address(new MockCalldataChecker(address(swapTarget)))
            );

        SwapperLib.Swap[] memory swapActions = new SwapperLib.Swap[](1);
        swapActions[0] = SwapperLib.Swap({
            inputToken: address(optimizer),
            inputAmount: sharesToSwap,
            outputToken: USDC_MONAD,
            target: address(swapTarget),
            slippage: 1e13,
            call: abi.encodeWithSelector(
                OptimizerShareSwapTarget.swap.selector,
                sharesToSwap,
                staleFeeTokenOut
            )
        });

        address[] memory tokens = new address[](1);
        tokens[0] = address(optimizer);
        uint256 feeManagerFeeTokenBefore =
            IERC20(USDC_MONAD).balanceOf(address(swapFeeManager));

        swapActions[0].slippage = 0;
        vm.expectPartialRevert(SwapperLib.SwapperLib__Slippage.selector);
        swapFeeManager.multiSwap(abi.encode(swapActions), tokens);
        assertEq(
            IERC20(address(optimizer)).balanceOf(address(swapFeeManager)),
            sharesToSwap
        );
        assertEq(
            IERC20(USDC_MONAD).balanceOf(address(swapFeeManager)),
            feeManagerFeeTokenBefore
        );

        swapActions[0].slippage = 1e13;
        swapFeeManager.multiSwap(abi.encode(swapActions), tokens);

        assertEq(
            IERC20(address(optimizer)).balanceOf(address(swapFeeManager)), 0
        );
        assertEq(
            IERC20(USDC_MONAD).balanceOf(address(swapFeeManager)),
            feeManagerFeeTokenBefore + staleFeeTokenOut
        );
        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "optimizer input transfer must sync NAV before slippage pricing"
        );

        optimizer.accrueIfNeeded();
        {
            (uint256 freshOptimizerPrice, uint256 freshOptimizerError) =
                _oracleManager.getPrice(address(optimizer), true, true);
            assertEq(freshOptimizerError, NO_ERROR);

            uint256 freshFeeTokenOut = _feeTokenRequiredForOTC(
                address(optimizer),
                sharesToSwap,
                freshOptimizerPrice,
                feeTokenPrice
            );
            assertGt(
                freshFeeTokenOut,
                staleFeeTokenOut,
                "permissioned multiSwap only accepts stale quotes inside slippage"
            );
        }
    }

    function test_lendingOptimizerShareCToken_lbpStartCachesStaleRawOptimizerSharePaymentTokenPrice()
        public
    {
        _registerOptimizerShareVaultPriceFeed();

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(1 days);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before LBP start"
        );

        (uint256 staleOptimizerPrice, uint256 staleError) =
            _oracleManager.getPrice(address(optimizer), true, true);
        assertEq(staleError, NO_ERROR);

        uint256 cveAmountForSale = 1_000e18;
        MockERC20 mockCve = new MockERC20("CVE", "CVE", 18);
        mockCve.mint(address(this), cveAmountForSale);
        CentralRegistry(address(liveCentralRegistry)).setCVE(address(mockCve));

        LBP lbp = new LBP(liveCentralRegistry);
        IERC20(address(mockCve)).transfer(address(lbp), cveAmountForSale);

        lbp.start(
            block.timestamp, WAD, 2 * WAD, cveAmountForSale, address(optimizer)
        );

        assertEq(lbp.paymentToken(), address(optimizer));
        assertEq(lbp.paymentTokenPrice(), staleOptimizerPrice);

        optimizer.accrueIfNeeded();
        (uint256 freshOptimizerPrice, uint256 freshError) =
            _oracleManager.getPrice(address(optimizer), true, true);
        assertEq(freshError, NO_ERROR);
        assertGt(
            freshOptimizerPrice,
            lbp.paymentTokenPrice(),
            "LBP start can cache stale raw optimizer-share price"
        );
    }

    function test_lendingOptimizerShareCToken_lbpCommitUsesCachedStalePaymentTokenPriceAfterTransferAccrues()
        public
    {
        _registerOptimizerShareVaultPriceFeed();

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(1 days);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before LBP start"
        );

        (uint256 staleOptimizerPrice, uint256 staleError) =
            _oracleManager.getPrice(address(optimizer), true, true);
        assertEq(staleError, NO_ERROR);

        uint256 cveAmountForSale = 1_000e18;
        MockERC20 mockCve = new MockERC20("CVE", "CVE", 18);
        mockCve.mint(address(this), cveAmountForSale);
        CentralRegistry(address(liveCentralRegistry)).setCVE(address(mockCve));

        LBP lbp = new LBP(liveCentralRegistry);
        IERC20(address(mockCve)).transfer(address(lbp), cveAmountForSale);

        lbp.start(
            block.timestamp, WAD, 2 * WAD, cveAmountForSale, address(optimizer)
        );

        uint256 commitAmount = 10e6;
        IERC20(address(optimizer)).approve(address(lbp), commitAmount);
        lbp.commit(commitAmount);

        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "optimizer-share payment transfer must sync NAV"
        );
        assertEq(lbp.paymentTokenPrice(), staleOptimizerPrice);
        assertEq(lbp.saleCommitted(), commitAmount);
        assertEq(lbp.userCommitted(address(this)), commitAmount);

        (uint256 freshOptimizerPrice, uint256 freshError) =
            _oracleManager.getPrice(address(optimizer), true, true);
        assertEq(freshError, NO_ERROR);
        assertGt(freshOptimizerPrice, staleOptimizerPrice);

        uint256 cachedClaimAmount = FixedPointMathLib.mulDiv(
            commitAmount * 1e12, WAD, lbp.currentPrice()
        );
        uint256 freshEquivalentSoftPrice =
            FixedPointMathLib.mulDiv(WAD, WAD, freshOptimizerPrice);
        uint256 freshEquivalentClaimAmount = FixedPointMathLib.mulDiv(
            commitAmount * 1e12, WAD, freshEquivalentSoftPrice
        );
        assertLt(
            cachedClaimAmount,
            freshEquivalentClaimAmount,
            "LBP claim remains priced from cached stale payment-token price"
        );

        skip(lbp.SALE_PERIOD() + 1);
        uint256 claimed = lbp.claim();
        assertEq(claimed, cachedClaimAmount);
        assertEq(mockCve.balanceOf(address(this)), cachedClaimAmount);
    }

    function test_lendingOptimizerShareCToken_lpAdaptorRouteInheritsStaleRawOptimizerSharePrice()
        public
    {
        _registerOptimizerShareVaultPriceFeed();
        _refreshUsdcPriceFeed();

        _mintOptimizerShares(100_000e6);
        uint256 optimizerSharesInLp = optimizer.balanceOf(address(this)) / 2;
        assertGt(
            optimizerSharesInLp, 0, "test setup must mint optimizer shares"
        );

        MockVolatileOptimizerSharePool lp =
            new MockVolatileOptimizerSharePool(address(optimizer), USDC_MONAD);
        lp.setReserves(uint112(optimizerSharesInLp), uint112(100_000e6));
        lp.mint(address(this), 100_000e18);

        MockVolatileLPAdaptor lpAdaptor =
            new MockVolatileLPAdaptor(liveCentralRegistry);
        _oracleManager.addApprovedAdaptor(address(lpAdaptor));
        lpAdaptor.addAsset(address(lp));
        _oracleManager.addAssetPricingAdaptor(
            address(lp), address(lpAdaptor), 0, 0, 0, 0
        );

        uint256 cTokenShares =
            IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer));
        uint256 staleTotalAssets = optimizer.totalAssets();
        vm.mockCall(
            cUSDC_WMON_MARKET,
            abi.encodeWithSelector(
                IBorrowableCToken.convertToAssets.selector, cTokenShares
            ),
            abi.encode(staleTotalAssets / 2)
        );

        (uint256 staleOptimizerPrice, uint256 staleOptimizerError) =
            _oracleManager.getPrice(address(optimizer), true, true);
        (uint256 staleLpPrice, uint256 staleLpError) =
            _oracleManager.getPrice(address(lp), true, true);
        assertEq(staleOptimizerError, NO_ERROR);
        assertEq(staleLpError, NO_ERROR);
        assertGt(staleLpPrice, 0, "stale LP quote must price");
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: LP oracle read must not sync optimizer NAV"
        );

        optimizer.accrueIfNeeded();

        (uint256 freshOptimizerPrice, uint256 freshOptimizerError) =
            _oracleManager.getPrice(address(optimizer), true, true);
        (uint256 freshLpPrice, uint256 freshLpError) =
            _oracleManager.getPrice(address(lp), true, true);
        assertEq(freshOptimizerError, NO_ERROR);
        assertEq(freshLpError, NO_ERROR);
        assertLt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "fresh accrual must reveal lower optimizer NAV"
        );
        assertLt(
            freshOptimizerPrice,
            staleOptimizerPrice,
            "optimizer price should fall after fresh accrual"
        );
        assertLt(
            freshLpPrice,
            staleLpPrice,
            "LP route inherits stale optimizer-share raw price"
        );

        vm.clearMockedCalls();
    }

    function test_lendingOptimizerShareCToken_recursiveLpCollateralStatusOfUsesStaleRawOptimizerSharePrice()
        public
    {
        _registerOptimizerShareVaultPriceFeed();
        _refreshUsdcPriceFeed();

        _mintOptimizerShares(100_000e6);
        uint256 optimizerSharesInLp = optimizer.balanceOf(address(this)) / 2;
        assertGt(
            optimizerSharesInLp, 0, "test setup must mint optimizer shares"
        );

        MockVolatileOptimizerSharePool lp =
            new MockVolatileOptimizerSharePool(address(optimizer), USDC_MONAD);
        lp.setReserves(uint112(optimizerSharesInLp), uint112(100_000e6));
        lp.mint(address(this), 150_000e18);

        MockVolatileLPAdaptor lpAdaptor =
            new MockVolatileLPAdaptor(liveCentralRegistry);
        _oracleManager.addApprovedAdaptor(address(lpAdaptor));
        lpAdaptor.addAsset(address(lp));
        _oracleManager.addAssetPricingAdaptor(
            address(lp), address(lpAdaptor), 0, 0, 0, 0
        );

        CentralRegistry cr = CentralRegistry(address(liveCentralRegistry));
        MarketManagerIsolated recursiveMarket =
            new MarketManagerIsolated(liveCentralRegistry, 10e18, false);
        cr.addMarketManager(address(recursiveMarket));

        DynamicIRM debtIRM = _deployOptimizerCTokenIRM();
        BorrowableCToken debtCToken = new BorrowableCToken(
            liveCentralRegistry,
            IERC20(USDC_MONAD),
            address(recursiveMarket),
            address(debtIRM)
        );
        debtIRM.setLinkedToken(address(debtCToken));

        SimpleCToken lpCToken = new SimpleCToken(
            liveCentralRegistry, IERC20(address(lp)), address(recursiveMarket)
        );
        _oracleManager.addCTokenSupport(address(debtCToken));
        _oracleManager.addCTokenSupport(address(lpCToken));

        deal(USDC_MONAD, address(this), 100_000e6 + 77777);
        IERC20(USDC_MONAD).approve(address(debtCToken), type(uint256).max);
        lp.approve(address(lpCToken), type(uint256).max);
        recursiveMarket.listTokens(address(lpCToken), address(debtCToken));
        _configureToken(
            recursiveMarket, address(lpCToken), 7000, 1_000_000e18, 0
        );
        _configureToken(
            recursiveMarket, address(debtCToken), 0, 0, 1_000_000e6
        );

        debtCToken.deposit(100_000e6, address(this));
        uint256 collateralShares =
            lpCToken.depositAsCollateral(50_000e18, address(this));
        assertGt(collateralShares, 0, "LP collateral deposit must mint shares");

        vm.warp(
            recursiveMarket.accountAssets(address(this))
                + recursiveMarket.MIN_HOLD_PERIOD()
        );
        _refreshUsdcPriceFeed();

        uint256 cTokenShares =
            IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer));
        uint256 staleTotalAssets = optimizer.totalAssets();
        vm.mockCall(
            cUSDC_WMON_MARKET,
            abi.encodeWithSelector(
                IBorrowableCToken.convertToAssets.selector, cTokenShares
            ),
            abi.encode(staleTotalAssets / 2)
        );

        (, uint256 staleMaxDebtBeforeBorrow,) =
            recursiveMarket.statusOf(address(this));
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "recursive LP statusOf must not sync optimizer NAV before accrual"
        );
        uint256 borrowAssets = FixedPointMathLib.mulDiv(
            staleMaxDebtBeforeBorrow, 9970 * 1e6, BPS * WAD
        );
        assertGt(borrowAssets, 10e6, "borrow should exceed minimum loan size");

        debtCToken.borrow(borrowAssets, address(this));

        (, uint256 staleMaxDebtAfterBorrow, uint256 staleDebtAfterBorrow) =
            recursiveMarket.statusOf(address(this));
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "recursive LP borrow/status path must still leave optimizer NAV stale"
        );
        assertGe(
            staleMaxDebtAfterBorrow,
            staleDebtAfterBorrow,
            "stale recursive quote leaves account apparently healthy"
        );

        optimizer.accrueIfNeeded();

        (, uint256 freshMaxDebt, uint256 freshDebt) =
            recursiveMarket.statusOf(address(this));
        assertLt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "explicit optimizer accrual must reveal lower NAV"
        );
        assertLt(
            freshMaxDebt,
            staleMaxDebtAfterBorrow,
            "fresh recursive quote should reduce collateral capacity"
        );
        assertGt(
            freshDebt,
            freshMaxDebt,
            "fresh recursive quote reveals the configured LP-collateral account is underwater"
        );

        vm.clearMockedCalls();
    }

    function _openExternalRawLenderPosition(address borrower, uint256 ltvBps)
        internal
        returns (
            ExternalRawOptimizerShareLender lender,
            uint256 collateralShares,
            uint256 debtAssets
        )
    {
        uint256 depositAmount = 100_000e6;
        deal(USDC_MONAD, address(this), depositAmount);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
        LendingOptimizerHarness(address(optimizer))
            .depositToMarket(depositAmount, borrower, cUSDC_WMON_MARKET);

        collateralShares = optimizer.balanceOf(borrower);
        uint256 rawValueAtDeposit = optimizer.convertToAssets(collateralShares);
        debtAssets =
            FixedPointMathLib.mulDiv(rawValueAtDeposit, ltvBps, 10000) + 10e6;

        lender =
            new ExternalRawOptimizerShareLender(IERC20(USDC_MONAD), ltvBps);
        deal(USDC_MONAD, address(lender), debtAssets);

        vm.startPrank(borrower);
        IERC20(address(optimizer)).approve(address(lender), collateralShares);
        lender.openPosition(
            ILendingOptimizer(address(optimizer)),
            collateralShares,
            debtAssets,
            borrower
        );
        vm.stopPrank();
    }

    function _openExternalRawVaultLenderPosition(
        address borrower,
        uint256 ltvBps
    )
        internal
        returns (
            ExternalRawOptimizerShareVault vault,
            ExternalRawOptimizerShareVaultLender lender,
            uint256 vaultShares,
            uint256 debtAssets
        )
    {
        uint256 rawValueAtDeposit;
        (vault, vaultShares, rawValueAtDeposit) =
            _depositExternalRawVaultCollateral(borrower);

        debtAssets =
            FixedPointMathLib.mulDiv(rawValueAtDeposit, ltvBps, 10000) + 10e6;

        lender = new ExternalRawOptimizerShareVaultLender(
            IERC20(USDC_MONAD), ltvBps
        );
        deal(USDC_MONAD, address(lender), debtAssets);

        vm.startPrank(borrower);
        vault.approve(address(lender), vaultShares);
        lender.openPosition(vault, vaultShares, debtAssets, borrower);
        vm.stopPrank();
    }

    function _depositExternalRawVaultCollateral(
        address borrower
    )
        internal
        returns (
            ExternalRawOptimizerShareVault vault,
            uint256 vaultShares,
            uint256 rawValueAtDeposit
        )
    {
        uint256 depositAmount = 100_000e6;
        deal(USDC_MONAD, address(this), depositAmount);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
        LendingOptimizerHarness(address(optimizer))
            .depositToMarket(depositAmount, borrower, cUSDC_WMON_MARKET);

        uint256 optimizerShares = optimizer.balanceOf(borrower);
        assertGt(optimizerShares, 0, "borrower must have optimizer shares");

        vault = new ExternalRawOptimizerShareVault(
            ILendingOptimizer(address(optimizer))
        );

        vm.startPrank(borrower);
        IERC20(address(optimizer)).approve(address(vault), optimizerShares);
        vaultShares = vault.deposit(optimizerShares, borrower);
        vm.stopPrank();

        uint256 rawSharesAtDeposit = vault.convertToAssets(vaultShares);
        rawValueAtDeposit = optimizer.convertToAssets(rawSharesAtDeposit);
    }

    function _openExternalWrapperLenderPosition(
        address borrower,
        uint256 ltvBps
    )
        internal
        returns (
            ExternalOptimizerShareCTokenLender lender,
            uint256 wrapperShares,
            uint256 debtAssets
        )
    {
        uint256 depositAmount = 100_000e6;
        deal(USDC_MONAD, address(this), depositAmount);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
        LendingOptimizerHarness(address(optimizer))
            .depositToMarket(depositAmount, borrower, cUSDC_WMON_MARKET);

        uint256 optimizerShares = optimizer.balanceOf(borrower);
        assertGt(optimizerShares, 0, "borrower must have optimizer shares");

        _mockCanMint();
        vm.startPrank(borrower);
        IERC20(address(optimizer))
            .approve(address(optimizerCToken), optimizerShares);
        wrapperShares = optimizerCToken.deposit(optimizerShares, borrower);
        vm.stopPrank();
        vm.clearMockedCalls();

        uint256 rawSharesAtDeposit =
            optimizerCToken.convertToAssets(wrapperShares);
        uint256 rawValueAtDeposit =
            optimizer.convertToAssets(rawSharesAtDeposit);
        debtAssets =
            FixedPointMathLib.mulDiv(rawValueAtDeposit, ltvBps, 10000) + 10e6;

        lender = new ExternalOptimizerShareCTokenLender(
            IERC20(USDC_MONAD), ltvBps
        );
        deal(USDC_MONAD, address(lender), debtAssets);

        _mockCanTransfer(borrower, address(lender), wrapperShares);
        vm.startPrank(borrower);
        IERC20(address(optimizerCToken)).approve(address(lender), wrapperShares);
        lender.openPosition(optimizerCToken, wrapperShares, debtAssets, borrower);
        vm.stopPrank();
        vm.clearMockedCalls();
    }

    function _openExternalWrapperVaultLenderPosition(
        address borrower,
        uint256 ltvBps
    )
        internal
        returns (
            ExternalOptimizerShareCTokenVault vault,
            ExternalOptimizerShareVaultLender lender,
            uint256 vaultShares,
            uint256 debtAssets
        )
    {
        uint256 rawValueAtDeposit;
        (vault, vaultShares, rawValueAtDeposit) =
            _depositExternalWrapperVaultCollateral(borrower);

        debtAssets =
            FixedPointMathLib.mulDiv(rawValueAtDeposit, ltvBps, 10000) + 10e6;

        lender = new ExternalOptimizerShareVaultLender(
            IERC20(USDC_MONAD), ltvBps
        );
        deal(USDC_MONAD, address(lender), debtAssets);

        vm.startPrank(borrower);
        vault.approve(address(lender), vaultShares);
        lender.openPosition(vault, vaultShares, debtAssets, borrower);
        vm.stopPrank();
    }

    function _depositExternalWrapperVaultCollateral(
        address borrower
    )
        internal
        returns (
            ExternalOptimizerShareCTokenVault vault,
            uint256 vaultShares,
            uint256 rawValueAtDeposit
        )
    {
        uint256 depositAmount = 100_000e6;
        deal(USDC_MONAD, address(this), depositAmount);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
        LendingOptimizerHarness(address(optimizer))
            .depositToMarket(depositAmount, borrower, cUSDC_WMON_MARKET);

        uint256 optimizerShares = optimizer.balanceOf(borrower);
        assertGt(optimizerShares, 0, "borrower must have optimizer shares");

        _mockCanMint();
        vm.startPrank(borrower);
        IERC20(address(optimizer))
            .approve(address(optimizerCToken), optimizerShares);
        uint256 wrapperShares = optimizerCToken.deposit(
            optimizerShares,
            borrower
        );
        vm.stopPrank();
        vm.clearMockedCalls();

        vault = new ExternalOptimizerShareCTokenVault(optimizerCToken);

        _mockCanTransfer(borrower, address(vault), wrapperShares);
        vm.startPrank(borrower);
        IERC20(address(optimizerCToken)).approve(address(vault), wrapperShares);
        vaultShares = vault.deposit(wrapperShares, borrower);
        vm.stopPrank();
        vm.clearMockedCalls();

        uint256 wrapperSharesAtDeposit = vault.convertToAssets(vaultShares);
        uint256 rawSharesAtDeposit =
            optimizerCToken.convertToAssets(wrapperSharesAtDeposit);
        rawValueAtDeposit = optimizer.convertToAssets(rawSharesAtDeposit);
    }

    function _liquidateExternalRawLenderPosition(
        ExternalRawOptimizerShareLender lender,
        address borrower,
        address liquidator,
        uint256 collateralShares,
        uint256 debtAssets,
        uint256 ltvBps
    ) internal {
        deal(USDC_MONAD, liquidator, debtAssets);
        uint256 lenderAssetsBefore =
            IERC20(USDC_MONAD).balanceOf(address(lender));

        vm.startPrank(liquidator);
        IERC20(USDC_MONAD).approve(address(lender), debtAssets);
        (uint256 seizedShares, uint256 repaidAssets) = lender.liquidateAtRawPrice(
            ILendingOptimizer(address(optimizer)), borrower, liquidator
        );
        vm.stopPrank();

        uint256 freshSeizedValue = optimizer.convertToAssets(seizedShares);
        uint256 freshBorrowLimit =
            FixedPointMathLib.mulDiv(freshSeizedValue, ltvBps, 10000);

        assertEq(seizedShares, collateralShares);
        assertEq(repaidAssets, debtAssets);
        assertGt(freshBorrowLimit, debtAssets, "fresh collateral was healthy");
        assertGt(
            freshSeizedValue, debtAssets, "liquidator seizes borrower surplus"
        );
        assertEq(optimizer.balanceOf(liquidator), seizedShares);
        assertEq(
            IERC20(USDC_MONAD).balanceOf(address(lender)),
            lenderAssetsBefore + debtAssets
        );
        assertEq(lender.collateralShares(borrower), 0);
        assertEq(lender.debtAssets(borrower), 0);
    }

    function _liquidateExternalRawVaultLenderPosition(
        ExternalRawOptimizerShareVault vault,
        ExternalRawOptimizerShareVaultLender lender,
        address borrower,
        address liquidator,
        uint256 vaultShares,
        uint256 debtAssets,
        uint256 ltvBps,
        uint256 staleTotalAssets
    ) internal {
        deal(USDC_MONAD, liquidator, debtAssets);
        vm.startPrank(liquidator);
        IERC20(USDC_MONAD).approve(address(lender), debtAssets);
        (uint256 seizedVaultShares, uint256 repaidAssets) =
            lender.liquidateAtRawPrice(
                vault,
                ILendingOptimizer(address(optimizer)),
                borrower,
                liquidator
            );
        vm.stopPrank();

        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "raw-vault share transfer does not sync optimizer NAV"
        );

        ILendingOptimizer(address(optimizer)).accrueIfNeeded();

        uint256 freshRawShares = vault.convertToAssets(seizedVaultShares);
        uint256 freshSeizedValue = optimizer.convertToAssets(freshRawShares);
        uint256 freshBorrowLimit =
            FixedPointMathLib.mulDiv(freshSeizedValue, ltvBps, 10000);

        assertEq(seizedVaultShares, vaultShares);
        assertEq(repaidAssets, debtAssets);
        assertGt(
            freshBorrowLimit,
            debtAssets,
            "fresh raw-vault collateral was healthy"
        );
        assertGt(
            freshSeizedValue,
            debtAssets,
            "liquidator seizes raw-vault borrower surplus"
        );
        assertEq(vault.balanceOf(liquidator), vaultShares);
        assertEq(lender.collateralShares(borrower), 0);
        assertEq(lender.debtAssets(borrower), 0);
    }

    function _liquidateExternalWrapperLenderPosition(
        ExternalOptimizerShareCTokenLender lender,
        address borrower,
        address liquidator,
        uint256 wrapperShares,
        uint256 debtAssets,
        uint256 ltvBps,
        uint256 staleTotalAssets
    ) internal {
        deal(USDC_MONAD, liquidator, debtAssets);
        _mockCanTransfer(address(lender), liquidator, wrapperShares);
        vm.startPrank(liquidator);
        IERC20(USDC_MONAD).approve(address(lender), debtAssets);
        (uint256 seizedWrapperShares, uint256 repaidAssets) =
            lender.liquidateAtRawPrice(
                optimizerCToken,
                ILendingOptimizer(address(optimizer)),
                borrower,
                liquidator
            );
        vm.stopPrank();
        vm.clearMockedCalls();

        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "wrapper-share transfer must sync optimizer NAV"
        );

        uint256 freshRawShares =
            optimizerCToken.convertToAssets(seizedWrapperShares);
        uint256 freshSeizedValue = optimizer.convertToAssets(freshRawShares);
        uint256 freshBorrowLimit =
            FixedPointMathLib.mulDiv(freshSeizedValue, ltvBps, 10000);

        assertEq(seizedWrapperShares, wrapperShares);
        assertEq(repaidAssets, debtAssets);
        assertGt(
            freshBorrowLimit,
            debtAssets,
            "fresh wrapper collateral was healthy"
        );
        assertEq(optimizerCToken.balanceOf(liquidator), wrapperShares);
        assertEq(lender.collateralShares(borrower), 0);
        assertEq(lender.debtAssets(borrower), 0);
    }

    function _liquidateExternalWrapperVaultLenderPosition(
        ExternalOptimizerShareCTokenVault vault,
        ExternalOptimizerShareVaultLender lender,
        address borrower,
        address liquidator,
        uint256 vaultShares,
        uint256 debtAssets,
        uint256 ltvBps,
        uint256 staleTotalAssets
    ) internal {
        deal(USDC_MONAD, liquidator, debtAssets);
        vm.startPrank(liquidator);
        IERC20(USDC_MONAD).approve(address(lender), debtAssets);
        (uint256 seizedVaultShares, uint256 repaidAssets) =
            lender.liquidateAtRawPrice(
                vault,
                optimizerCToken,
                ILendingOptimizer(address(optimizer)),
                borrower,
                liquidator
            );
        vm.stopPrank();

        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "outer-vault share transfer does not sync optimizer NAV"
        );

        ILendingOptimizer(address(optimizer)).accrueIfNeeded();

        uint256 freshWrapperShares =
            vault.convertToAssets(seizedVaultShares);
        uint256 freshRawShares =
            optimizerCToken.convertToAssets(freshWrapperShares);
        uint256 freshSeizedValue = optimizer.convertToAssets(freshRawShares);
        uint256 freshBorrowLimit =
            FixedPointMathLib.mulDiv(freshSeizedValue, ltvBps, 10000);

        assertEq(seizedVaultShares, vaultShares);
        assertEq(repaidAssets, debtAssets);
        assertGt(
            freshBorrowLimit,
            debtAssets,
            "fresh outer-vault collateral was healthy"
        );
        assertGt(
            freshSeizedValue,
            debtAssets,
            "liquidator seizes outer-vault borrower surplus"
        );
        assertEq(vault.balanceOf(liquidator), vaultShares);
        assertEq(lender.collateralShares(borrower), 0);
        assertEq(lender.debtAssets(borrower), 0);
    }

    function test_lendingOptimizerShareCToken_vaultAssetDriftBlocksIsolatedPairPricing()
        public
    {
        (
            ,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();

        (bool feedConfigured, IChainlink feed,,) =
            _chainlinkAdaptor.assetConfig(address(optimizer), true);
        assertTrue(feedConfigured, "optimizer share feed must be configured");

        VaultAggregator optimizerVaultFeed = VaultAggregator(address(feed));
        vm.mockCall(
            address(optimizer),
            abi.encodeWithSelector(ILendingOptimizer.asset.selector),
            abi.encode(makeAddr("driftedOptimizerAsset"))
        );

        (, int256 directAnswer,,,) = optimizerVaultFeed.latestRoundData();
        assertEq(directAnswer, 0);

        (uint256 optimizerPrice, uint256 optimizerPriceError) =
            _oracleManager.getPrice(address(optimizer), true, true);
        assertEq(optimizerPrice, 0);
        assertEq(optimizerPriceError, BAD_SOURCE);

        vm.expectRevert(OracleManager.OracleManager__ErrorCodeFlagged.selector);
        _oracleManager.getPriceIsolatedPair(
            address(shareCToken), address(debtCToken), BAD_SOURCE
        );
    }

    function test_lendingOptimizerShareCToken_launchBorrowPathAccruesOptimizerBeforeCollateralCheck()
        public
    {
        (
            MarketManagerIsolated optimizerMarket,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();

        uint256 lendAssets = 100_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        uint256 optimizerShares = optimizer.balanceOf(address(this));
        IERC20(address(optimizer))
            .approve(address(shareCToken), optimizerShares);
        uint256 wrapperShares =
            shareCToken.deposit(optimizerShares, address(this));
        shareCToken.postCollateral(wrapperShares);

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        _refreshUsdcPriceFeed();
        _setOptimizerVaultFeedAnswer(1e8);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before borrow"
        );

        debtCToken.borrow(20_000e6, address(this));

        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "borrow collateral check must sync optimizer NAV"
        );
        assertEq(shareCToken.collateralPosted(address(this)), wrapperShares);
        assertEq(debtCToken.debtBalance(address(this)), 20_000e6);
    }

    function test_lendingOptimizerShareCToken_debtOracleCautionBlocksFreshBorrowAndRollsBackOptimizerAccrual()
        public
    {
        (
            ,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();

        uint256 lendAssets = 100_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        uint256 optimizerShares = optimizer.balanceOf(address(this));
        IERC20(address(optimizer))
            .approve(address(shareCToken), optimizerShares);
        uint256 wrapperShares =
            shareCToken.deposit(optimizerShares, address(this));
        shareCToken.postCollateral(wrapperShares);

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        _refreshUsdcPriceFeed();
        _setOptimizerVaultFeedAnswer(1e8);
        _setUsdcDualFeedAnswer(1.016e8, CAUTION);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before CAUTION borrow"
        );

        vm.expectRevert(
            LiquidityManagerIsolated.LiquidityManager__PriceError.selector
        );
        debtCToken.borrow(20_000e6, address(this));

        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "CAUTION borrow revert must roll back optimizer NAV accrual"
        );
        assertEq(
            debtCToken.debtBalance(address(this)),
            0,
            "borrow must not open debt"
        );
    }

    function test_lendingOptimizerShareCToken_debtOracleCautionAllowsLiquidationWithFreshOptimizerCollateral()
        public
    {
        (
            ,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();

        uint256 lendAssets = 300_000e6;
        uint256 borrowAssets = 130_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        uint256 optimizerShares = optimizer.balanceOf(address(this));
        IERC20(address(optimizer))
            .approve(address(shareCToken), optimizerShares);
        uint256 wrapperShares =
            shareCToken.deposit(optimizerShares, address(this));
        shareCToken.postCollateral(wrapperShares);
        debtCToken.borrow(borrowAssets, address(this));

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        _refreshUsdcPriceFeed();
        _setOptimizerVaultFeedAnswer(0.5e8);
        _setUsdcDualFeedAnswer(1.016e8, CAUTION);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before CAUTION liquidation"
        );

        address liquidator = makeAddr("optimizerShareCautionLiquidator");
        deal(USDC_MONAD, liquidator, 100_000e6);
        vm.startPrank(liquidator);
        IERC20(USDC_MONAD).approve(address(debtCToken), type(uint256).max);
        address[] memory accounts = new address[](1);
        accounts[0] = address(this);
        debtCToken.liquidate(accounts, address(shareCToken));
        vm.stopPrank();

        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "liquidation under CAUTION must sync optimizer NAV before seizing collateral"
        );
        assertLt(
            debtCToken.debtBalance(address(this)),
            borrowAssets,
            "CAUTION liquidation should repay borrower debt"
        );
        assertGt(
            shareCToken.balanceOf(liquidator),
            0,
            "liquidator should receive optimizer-share collateral"
        );
    }

    function test_lendingOptimizerShareCToken_rebalanceThenFreshBorrowRevertsAtomicallyWhenOptimizerPriceFails()
        public
    {
        _setUpThreeMarkets();
        _depositToAllMarkets(10_000e6);

        (
            ,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();

        uint256 lendAssets = 100_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        uint256 optimizerShares = optimizer.balanceOf(address(this));
        IERC20(address(optimizer))
            .approve(address(shareCToken), optimizerShares);
        uint256 wrapperShares =
            shareCToken.deposit(optimizerShares, address(this));
        shareCToken.postCollateral(wrapperShares);

        uint256 totalAssetsBefore = optimizer.totalAssets();
        uint256 market0AssetsBefore = IBorrowableCToken(cUSDC_WMON_MARKET)
            .convertToAssets(
                IBorrowableCToken(cUSDC_WMON_MARKET)
                    .balanceOf(address(optimizer))
            );
        uint256 market2AssetsBefore = IBorrowableCToken(cUSDC_WETH_MARKET)
            .convertToAssets(
                IBorrowableCToken(cUSDC_WETH_MARKET)
                    .balanceOf(address(optimizer))
            );
        uint256 market2TargetAssets = (totalAssetsBefore * 20) / 100;
        uint256 rebalanceAssets = market2AssetsBefore - market2TargetAssets;

        LendingOptimizer.ReallocationAction[] memory actions =
            new LendingOptimizer.ReallocationAction[](3);
        actions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WMON_MARKET), int256(rebalanceAssets)
        );
        actions[1] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WBTC_MARKET), int256(0)
        );
        actions[2] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WETH_MARKET), -int256(rebalanceAssets)
        );

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(
                ICentralRegistry.hasHarvestPermissions.selector, address(this)
            ),
            abi.encode(true)
        );
        _rebalance(optimizer, actions, _unconstrainedBounds());

        uint256 rebalancedTotalAssets = optimizer.totalAssets();
        assertApproxEqAbs(
            rebalancedTotalAssets,
            totalAssetsBefore,
            10,
            "rebalance should preserve NAV"
        );
        assertGt(
            IBorrowableCToken(cUSDC_WMON_MARKET)
                .convertToAssets(
                    IBorrowableCToken(cUSDC_WMON_MARKET)
                        .balanceOf(address(optimizer))
                ),
            market0AssetsBefore,
            "rebalance should move assets into market 0"
        );

        vm.mockCall(
            address(optimizer),
            abi.encodeWithSelector(ILendingOptimizer.asset.selector),
            abi.encode(makeAddr("driftedOptimizerAssetAfterRebalance"))
        );

        uint256 borrowerAssetBalanceBefore =
            IERC20(USDC_MONAD).balanceOf(address(this));
        uint256 marketCollateralBefore = shareCToken.marketCollateralPosted();

        vm.expectRevert(OracleManager.OracleManager__ErrorCodeFlagged.selector);
        debtCToken.borrow(20_000e6, address(this));

        assertEq(
            optimizer.totalAssets(),
            rebalancedTotalAssets,
            "optimizer NAV should roll back"
        );
        assertEq(
            IERC20(USDC_MONAD).balanceOf(address(this)),
            borrowerAssetBalanceBefore,
            "borrow assets"
        );
        assertEq(
            debtCToken.debtBalance(address(this)),
            0,
            "fresh debt must not be recorded"
        );
        assertEq(
            shareCToken.collateralPosted(address(this)),
            wrapperShares,
            "collateral should stay posted"
        );
        assertEq(
            shareCToken.marketCollateralPosted(),
            marketCollateralBefore,
            "market collateral"
        );
    }

    function test_lendingOptimizerShareCToken_collateralExitRevertsAtomicallyWhenOptimizerPriceFails()
        public
    {
        (
            ,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();

        uint256 lendAssets = 100_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        uint256 optimizerShares = optimizer.balanceOf(address(this));
        IERC20(address(optimizer))
            .approve(address(shareCToken), optimizerShares);
        uint256 wrapperShares =
            shareCToken.deposit(optimizerShares, address(this));
        shareCToken.postCollateral(wrapperShares);
        debtCToken.borrow(20_000e6, address(this));

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        _refreshUsdcPriceFeed();
        uint256 collateralToExit = wrapperShares / 20;
        uint256 optimizerSharesToWithdraw =
            shareCToken.convertToAssets(collateralToExit);
        uint256 receiverOptimizerSharesBefore = optimizer.balanceOf(user1);
        uint256 ownerWrapperBalanceBefore =
            shareCToken.balanceOf(address(this));
        uint256 ownerCollateralBefore =
            shareCToken.collateralPosted(address(this));
        uint256 marketCollateralBefore = shareCToken.marketCollateralPosted();
        uint256 debtBefore = debtCToken.debtBalance(address(this));

        vm.mockCall(
            address(optimizer),
            abi.encodeWithSelector(ILendingOptimizer.asset.selector),
            abi.encode(makeAddr("driftedOptimizerAssetForCollateralExit"))
        );

        vm.expectRevert(OracleManager.OracleManager__ErrorCodeFlagged.selector);
        shareCToken.removeCollateral(collateralToExit);

        vm.expectRevert(OracleManager.OracleManager__ErrorCodeFlagged.selector);
        shareCToken.withdrawCollateral(
            optimizerSharesToWithdraw, user1, address(this)
        );

        vm.expectRevert(OracleManager.OracleManager__ErrorCodeFlagged.selector);
        shareCToken.redeemCollateral(collateralToExit, user1, address(this));

        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "failed collateral exit must roll back optimizer NAV accrual"
        );
        assertEq(
            optimizer.balanceOf(user1),
            receiverOptimizerSharesBefore,
            "receiver optimizer shares"
        );
        assertEq(
            shareCToken.balanceOf(address(this)),
            ownerWrapperBalanceBefore,
            "owner wrapper balance"
        );
        assertEq(
            shareCToken.collateralPosted(address(this)),
            ownerCollateralBefore,
            "owner collateral"
        );
        assertEq(
            shareCToken.marketCollateralPosted(),
            marketCollateralBefore,
            "market collateral"
        );
        assertEq(
            debtCToken.debtBalance(address(this)),
            debtBefore,
            "debt must not change"
        );
    }

    function test_lendingOptimizerShareCToken_multicallRollsBackPriorAccrualWhenOptimizerPriceFails()
        public
    {
        (
            ,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();

        uint256 lendAssets = 100_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        uint256 optimizerShares = optimizer.balanceOf(address(this));
        IERC20(address(optimizer))
            .approve(address(shareCToken), optimizerShares);
        uint256 wrapperShares =
            shareCToken.deposit(optimizerShares, address(this));
        shareCToken.postCollateral(wrapperShares);
        debtCToken.borrow(20_000e6, address(this));

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        _refreshUsdcPriceFeed();
        uint256 collateralToExit = wrapperShares / 20;

        uint256 ownerWrapperBalanceBefore =
            shareCToken.balanceOf(address(this));
        uint256 ownerCollateralBefore =
            shareCToken.collateralPosted(address(this));
        uint256 marketCollateralBefore = shareCToken.marketCollateralPosted();
        uint256 debtBefore = debtCToken.debtBalance(address(this));

        vm.mockCall(
            address(optimizer),
            abi.encodeWithSelector(ILendingOptimizer.asset.selector),
            abi.encode(makeAddr("driftedOptimizerAssetForMulticall"))
        );

        Multicall.MulticallAction[] memory calls =
            new Multicall.MulticallAction[](2);
        calls[0] = Multicall.MulticallAction({
            target: address(shareCToken),
            isPriceUpdate: false,
            data: abi.encodeWithSelector(
                BaseCToken.exchangeRateUpdated.selector
            )
        });
        calls[1] = Multicall.MulticallAction({
            target: address(shareCToken),
            isPriceUpdate: false,
            data: abi.encodeWithSelector(
                BaseCToken.removeCollateral.selector, collateralToExit
            )
        });

        vm.expectRevert(OracleManager.OracleManager__ErrorCodeFlagged.selector);
        shareCToken.multicall(calls);

        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "failed multicall must roll back optimizer NAV accrual"
        );
        assertEq(
            shareCToken.balanceOf(address(this)),
            ownerWrapperBalanceBefore,
            "owner wrapper balance"
        );
        assertEq(
            shareCToken.collateralPosted(address(this)),
            ownerCollateralBefore,
            "owner collateral"
        );
        assertEq(
            shareCToken.marketCollateralPosted(),
            marketCollateralBefore,
            "market collateral"
        );
        assertEq(
            debtCToken.debtBalance(address(this)),
            debtBefore,
            "debt must not change"
        );
    }

    function test_lendingOptimizerShareCToken_launchWithdrawCollateralAfterRepayAccruesOptimizer()
        public
    {
        (
            MarketManagerIsolated optimizerMarket,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();

        uint256 lendAssets = 100_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        uint256 optimizerShares = optimizer.balanceOf(address(this));
        IERC20(address(optimizer))
            .approve(address(shareCToken), optimizerShares);
        uint256 wrapperShares =
            shareCToken.deposit(optimizerShares, address(this));
        shareCToken.postCollateral(wrapperShares);
        debtCToken.borrow(20_000e6, address(this));

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        _refreshUsdcPriceFeed();
        _setOptimizerVaultFeedAnswer(1e8);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before collateral exit"
        );

        deal(USDC_MONAD, address(this), 25_000e6);
        IERC20(USDC_MONAD).approve(address(debtCToken), type(uint256).max);
        debtCToken.repay(0);

        uint256 optimizerSharesToWithdraw =
            shareCToken.convertToAssets(wrapperShares / 2);
        uint256 expectedWrapperSharesBurned =
            shareCToken.previewWithdraw(optimizerSharesToWithdraw);
        uint256 receiverOptimizerSharesBefore = optimizer.balanceOf(user1);
        uint256 wrapperBalanceBefore = shareCToken.balanceOf(address(this));
        uint256 marketCollateralBefore = shareCToken.marketCollateralPosted();

        uint256 wrapperSharesBurned = shareCToken.withdrawCollateral(
            optimizerSharesToWithdraw, user1, address(this)
        );

        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "collateral exit must sync optimizer NAV"
        );
        assertEq(wrapperSharesBurned, expectedWrapperSharesBurned);
        assertEq(
            optimizer.balanceOf(user1),
            receiverOptimizerSharesBefore + optimizerSharesToWithdraw,
            "receiver should get exact optimizer shares"
        );
        assertEq(
            shareCToken.balanceOf(address(this)),
            wrapperBalanceBefore - wrapperSharesBurned,
            "wrapper shares should burn from owner"
        );
        assertEq(
            shareCToken.collateralPosted(address(this)),
            wrapperShares - wrapperSharesBurned,
            "owner collateral should reduce by burned shares"
        );
        assertEq(
            shareCToken.marketCollateralPosted(),
            marketCollateralBefore - wrapperSharesBurned,
            "market collateral should reduce by burned shares"
        );

        (, uint256 maxDebt, uint256 debt) =
            optimizerMarket.statusOf(address(this));
        assertEq(
            debt, 0, "repay should clear launch debt before collateral exit"
        );
        assertGe(
            maxDebt,
            debt,
            "account should remain healthy after collateral exit"
        );
    }

    function test_lendingOptimizerShareCToken_partialRepayThenCollateralRemovalAccruesOptimizer()
        public
    {
        (
            ,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();

        uint256 lendAssets = 100_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        uint256 optimizerShares = optimizer.balanceOf(address(this));
        IERC20(address(optimizer))
            .approve(address(shareCToken), optimizerShares);
        uint256 wrapperShares =
            shareCToken.deposit(optimizerShares, address(this));
        shareCToken.postCollateral(wrapperShares);
        debtCToken.borrow(20_000e6, address(this));

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        _refreshUsdcPriceFeed();
        _setOptimizerVaultFeedAnswer(1e8);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before partial repay"
        );

        uint256 repayAssets = 5_000e6;
        deal(USDC_MONAD, address(this), repayAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), repayAssets);
        debtCToken.repay(repayAssets);

        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "partial repay reviews debt asset only and should not sync optimizer NAV"
        );
        uint256 debtAfterPartialRepay = debtCToken.debtBalance(address(this));
        assertGt(
            debtAfterPartialRepay,
            10_000e6,
            "partial repay should leave live debt"
        );

        {
            (, uint256 maxDebt, uint256 debt) =
                shareCToken.marketManager().statusOf(address(this));
            assertGt(
                optimizer.totalAssets(),
                staleTotalAssets,
                "statusOf after partial repay must sync optimizer-share collateral NAV"
            );
            assertGt(debt, 0, "partial repay should leave market debt live");
            assertGe(
                maxDebt,
                debt,
                "account should remain healthy after partial repay"
            );
        }

        uint256 secondStaleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        _refreshUsdcPriceFeed();
        _setOptimizerVaultFeedAnswer(1e8);
        assertEq(
            optimizer.totalAssets(),
            secondStaleTotalAssets,
            "precondition: optimizer NAV is stale before collateral removal"
        );

        {
            uint256 optimizerSharesToWithdraw = optimizerShares / 20;
            uint256 receiverOptimizerSharesBefore = optimizer.balanceOf(user1);
            uint256 wrapperBalanceBefore = shareCToken.balanceOf(address(this));
            uint256 marketCollateralBefore =
                shareCToken.marketCollateralPosted();

            uint256 wrapperSharesBurned = shareCToken.withdrawCollateral(
                optimizerSharesToWithdraw, user1, address(this)
            );

            assertGt(
                optimizer.totalAssets(),
                secondStaleTotalAssets,
                "collateral removal with live debt must sync optimizer NAV"
            );
            assertEq(
                optimizer.balanceOf(user1),
                receiverOptimizerSharesBefore + optimizerSharesToWithdraw,
                "receiver should get exact optimizer shares"
            );
            assertEq(
                shareCToken.balanceOf(address(this)),
                wrapperBalanceBefore - wrapperSharesBurned,
                "wrapper shares should burn from owner"
            );
            assertEq(
                shareCToken.marketCollateralPosted(),
                marketCollateralBefore - wrapperSharesBurned,
                "market collateral should reduce by burned shares"
            );
        }

        {
            (, uint256 maxDebt, uint256 debt) =
                shareCToken.marketManager().statusOf(address(this));
            assertGt(
                debt,
                0,
                "partial repay should still leave debt after collateral removal"
            );
            assertGe(
                maxDebt,
                debt,
                "account should remain healthy after collateral removal"
            );
        }
    }

    function test_lendingOptimizerShareCToken_directRemoveCollateralWithLiveDebtAccruesOptimizer()
        public
    {
        (
            MarketManagerIsolated optimizerMarket,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();

        uint256 lendAssets = 100_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        uint256 optimizerShares = optimizer.balanceOf(address(this));
        IERC20(address(optimizer))
            .approve(address(shareCToken), optimizerShares);
        uint256 wrapperShares =
            shareCToken.deposit(optimizerShares, address(this));
        shareCToken.postCollateral(wrapperShares);
        debtCToken.borrow(20_000e6, address(this));

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        _refreshUsdcPriceFeed();
        _setOptimizerVaultFeedAnswer(1e8);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before direct collateral removal"
        );

        uint256 collateralToRemove = wrapperShares / 20;
        assertGt(
            collateralToRemove, 0, "test setup must remove nonzero collateral"
        );
        uint256 marketCollateralBefore = shareCToken.marketCollateralPosted();

        shareCToken.removeCollateral(collateralToRemove);

        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "direct removeCollateral with live debt must sync optimizer NAV"
        );
        assertEq(
            shareCToken.collateralPosted(address(this)),
            wrapperShares - collateralToRemove,
            "owner collateral should decrease by removed shares"
        );
        assertEq(
            shareCToken.marketCollateralPosted(),
            marketCollateralBefore - collateralToRemove,
            "market collateral should decrease by removed shares"
        );

        (, uint256 maxDebt, uint256 debt) =
            optimizerMarket.statusOf(address(this));
        assertGt(debt, 0, "direct collateral removal should leave debt live");
        assertGe(
            maxDebt, debt, "account should remain healthy after direct removal"
        );
    }

    function test_lendingOptimizerShareCToken_delegatedRemoveCollateralWithLiveDebtAccruesOptimizer()
        public
    {
        (
            MarketManagerIsolated optimizerMarket,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();

        uint256 lendAssets = 100_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        uint256 optimizerShares = optimizer.balanceOf(address(this));
        IERC20(address(optimizer))
            .approve(address(shareCToken), optimizerShares);
        uint256 wrapperShares =
            shareCToken.deposit(optimizerShares, address(this));
        shareCToken.postCollateral(wrapperShares);
        debtCToken.borrow(20_000e6, address(this));

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        _refreshUsdcPriceFeed();
        _setOptimizerVaultFeedAnswer(1e8);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before delegated collateral removal"
        );

        uint256 collateralToRemove = wrapperShares / 20;
        assertGt(
            collateralToRemove, 0, "test setup must remove nonzero collateral"
        );
        uint256 marketCollateralBefore = shareCToken.marketCollateralPosted();
        address delegate = makeAddr("collateralRemovalDelegate");

        shareCToken.setDelegateApproval(delegate, true);
        assertTrue(
            shareCToken.isDelegate(address(this), delegate),
            "delegate should be approved"
        );
        vm.prank(delegate);
        shareCToken.removeCollateralFor(collateralToRemove, address(this));

        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "delegated removeCollateralFor with live debt must sync optimizer NAV"
        );
        assertEq(
            shareCToken.collateralPosted(address(this)),
            wrapperShares - collateralToRemove,
            "owner collateral should decrease by removed shares"
        );
        assertEq(
            shareCToken.marketCollateralPosted(),
            marketCollateralBefore - collateralToRemove,
            "market collateral should decrease by removed shares"
        );

        (, uint256 maxDebt, uint256 debt) =
            optimizerMarket.statusOf(address(this));
        assertGt(
            debt, 0, "delegated collateral removal should leave debt live"
        );
        assertGe(
            maxDebt,
            debt,
            "account should remain healthy after delegated removal"
        );
    }

    function test_lendingOptimizerShareCToken_transferPostedCollateralWithLiveDebtAccruesOptimizer()
        public
    {
        (
            MarketManagerIsolated optimizerMarket,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();

        uint256 lendAssets = 100_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        uint256 optimizerShares = optimizer.balanceOf(address(this));
        IERC20(address(optimizer))
            .approve(address(shareCToken), optimizerShares);
        uint256 wrapperShares =
            shareCToken.deposit(optimizerShares, address(this));
        shareCToken.postCollateral(wrapperShares);
        debtCToken.borrow(20_000e6, address(this));

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        _refreshUsdcPriceFeed();
        _setOptimizerVaultFeedAnswer(1e8);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before posted-collateral transfer"
        );

        uint256 sharesToTransfer = wrapperShares / 20;
        assertGt(
            sharesToTransfer, 0, "test setup must transfer nonzero shares"
        );
        uint256 marketCollateralBefore = shareCToken.marketCollateralPosted();
        address receiver = makeAddr("postedCollateralTransferReceiver");

        shareCToken.transfer(receiver, sharesToTransfer);

        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "posted-collateral transfer with live debt must sync optimizer NAV"
        );
        assertEq(
            shareCToken.balanceOf(receiver),
            sharesToTransfer,
            "receiver should get transferred wrapper shares"
        );
        assertEq(
            shareCToken.balanceOf(address(this)),
            wrapperShares - sharesToTransfer,
            "owner wrapper balance should decrease by transferred shares"
        );
        assertEq(
            shareCToken.collateralPosted(address(this)),
            wrapperShares - sharesToTransfer,
            "owner collateral should decrease by redeemed posted shares"
        );
        assertEq(
            shareCToken.marketCollateralPosted(),
            marketCollateralBefore - sharesToTransfer,
            "market collateral should decrease by redeemed posted shares"
        );

        (, uint256 maxDebt, uint256 debt) =
            optimizerMarket.statusOf(address(this));
        assertGt(debt, 0, "posted-collateral transfer should leave debt live");
        assertGe(maxDebt, debt, "account should remain healthy after transfer");
    }

    function test_lendingOptimizerShareCToken_transferFromPostedCollateralWithLiveDebtAccruesOptimizer()
        public
    {
        (
            MarketManagerIsolated optimizerMarket,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();

        uint256 lendAssets = 100_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        uint256 optimizerShares = optimizer.balanceOf(address(this));
        IERC20(address(optimizer))
            .approve(address(shareCToken), optimizerShares);
        uint256 wrapperShares =
            shareCToken.deposit(optimizerShares, address(this));
        shareCToken.postCollateral(wrapperShares);
        debtCToken.borrow(20_000e6, address(this));

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        _refreshUsdcPriceFeed();
        _setOptimizerVaultFeedAnswer(1e8);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before delegated posted-collateral transfer"
        );

        uint256 sharesToTransfer = wrapperShares / 20;
        assertGt(
            sharesToTransfer, 0, "test setup must transfer nonzero shares"
        );
        uint256 marketCollateralBefore = shareCToken.marketCollateralPosted();
        address spender = makeAddr("postedCollateralTransferFromSpender");
        address receiver = makeAddr("postedCollateralTransferFromReceiver");

        shareCToken.approve(spender, sharesToTransfer);
        vm.prank(spender);
        shareCToken.transferFrom(address(this), receiver, sharesToTransfer);

        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "delegated posted-collateral transfer with live debt must sync optimizer NAV"
        );
        assertEq(
            shareCToken.allowance(address(this), spender),
            0,
            "delegated transfer should consume allowance"
        );
        assertEq(
            shareCToken.balanceOf(receiver),
            sharesToTransfer,
            "receiver should get transferred wrapper shares"
        );
        assertEq(
            shareCToken.balanceOf(address(this)),
            wrapperShares - sharesToTransfer,
            "owner wrapper balance should decrease by transferred shares"
        );
        assertEq(
            shareCToken.collateralPosted(address(this)),
            wrapperShares - sharesToTransfer,
            "owner collateral should decrease by redeemed posted shares"
        );
        assertEq(
            shareCToken.marketCollateralPosted(),
            marketCollateralBefore - sharesToTransfer,
            "market collateral should decrease by redeemed posted shares"
        );

        (, uint256 maxDebt, uint256 debt) =
            optimizerMarket.statusOf(address(this));
        assertGt(
            debt,
            0,
            "delegated posted-collateral transfer should leave debt live"
        );
        assertGe(
            maxDebt,
            debt,
            "account should remain healthy after delegated transfer"
        );
    }

    function test_lendingOptimizerShareCToken_positionManagerBorrowPostsFreshOptimizerCollateral()
        public
    {
        (
            MarketManagerIsolated optimizerMarket,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();
        OptimizerSharePositionManagerHarness positionManager =
            _deployOptimizerSharePositionManager(optimizerMarket);

        uint256 lendAssets = 100_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        uint256 optimizerShares = optimizer.balanceOf(address(this)) / 2;
        uint256 expectedShares = shareCToken.previewDeposit(optimizerShares);
        IERC20(address(optimizer))
            .transfer(address(positionManager), optimizerShares);

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        _refreshUsdcPriceFeed();
        _setOptimizerVaultFeedAnswer(1e8);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before PM borrow"
        );

        address account = makeAddr("optimizerSharePmAccount");
        IPositionManager.LeverageAction memory action;
        action.borrowableCToken = IBorrowableCToken(address(debtCToken));
        action.borrowAssets = 20_000e6;
        action.cToken = ICToken(address(shareCToken));
        action.expectedShares = expectedShares;

        vm.prank(account);
        positionManager.leverage(action, 0);

        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "PM borrow collateral check must sync optimizer NAV"
        );
        assertEq(shareCToken.collateralPosted(account), expectedShares);
        assertEq(debtCToken.debtBalance(account), action.borrowAssets);
        assertEq(
            IERC20(address(optimizer)).balanceOf(address(positionManager)),
            0,
            "PM optimizer residue"
        );
        assertEq(
            IERC20(USDC_MONAD).balanceOf(address(positionManager)),
            0,
            "PM debt residue"
        );
        assertEq(
            IERC20(USDC_MONAD).balanceOf(positionManager.swapSink()),
            action.borrowAssets,
            "swap sink debt"
        );
    }

    function test_lendingOptimizerShareCToken_simplePositionManagerLeverageDepositsRealizedOptimizerShares()
        public
    {
        (
            MarketManagerIsolated optimizerMarket,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();
        SimplePositionManager positionManager =
            _deploySimpleOptimizerSharePositionManager(optimizerMarket);
        OptimizerShareSwapTarget swapTarget = new OptimizerShareSwapTarget(
            IERC20(USDC_MONAD), IERC20(address(optimizer))
        );
        CentralRegistry(address(liveCentralRegistry))
            .setExternalCalldataChecker(
                address(swapTarget),
                address(new MockCalldataChecker(address(swapTarget)))
            );

        uint256 lendAssets = 100_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        uint256 borrowAssets = 20_000e6;
        uint256 optimizerSharesOut = optimizer.balanceOf(address(this)) / 2;
        uint256 expectedWrapperShares =
            shareCToken.previewDeposit(optimizerSharesOut);
        IERC20(address(optimizer))
            .transfer(address(swapTarget), optimizerSharesOut);

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        _refreshUsdcPriceFeed();
        _setOptimizerVaultFeedAnswer(1e8);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before simple PM leverage"
        );

        IPositionManager.LeverageAction memory action;
        action.borrowableCToken = IBorrowableCToken(address(debtCToken));
        action.borrowAssets = borrowAssets;
        action.cToken = ICToken(address(shareCToken));
        action.expectedShares = expectedWrapperShares;
        action.swapAction = SwapperLib.Swap({
            inputToken: USDC_MONAD,
            inputAmount: borrowAssets,
            outputToken: address(optimizer),
            target: address(swapTarget),
            slippage: WAD - 1,
            call: abi.encodeWithSelector(
                OptimizerShareSwapTarget.swap.selector,
                borrowAssets,
                optimizerSharesOut
            )
        });

        address account = makeAddr("optimizerShareSimplePmAccount");
        vm.prank(account);
        positionManager.leverage(action, 0.05e18);

        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "simple PM optimizer-share swap output must sync optimizer NAV"
        );
        assertEq(
            shareCToken.collateralPosted(account),
            expectedWrapperShares,
            "simple PM should post realized wrapper shares"
        );
        assertEq(
            debtCToken.debtBalance(account),
            borrowAssets,
            "simple PM should open requested debt"
        );
        assertEq(
            IERC20(address(optimizer)).balanceOf(address(positionManager)),
            0,
            "PM optimizer residue"
        );
        assertEq(
            IERC20(USDC_MONAD).balanceOf(address(positionManager)),
            0,
            "PM USDC residue"
        );
        assertEq(
            IERC20(address(optimizer)).balanceOf(address(swapTarget)),
            0,
            "swap target should spend optimizer-share output"
        );
        assertEq(
            IERC20(USDC_MONAD).balanceOf(address(swapTarget)),
            borrowAssets,
            "swap target should receive PM debt asset input"
        );
    }

    function test_lendingOptimizerShareCToken_singleSidedVaultPositionManagerDepositsBorrowThroughOptimizerVault()
        public
    {
        (
            MarketManagerIsolated optimizerMarket,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();
        SingleSidedVaultPositionManager positionManager =
            _deploySingleSidedOptimizerShareVaultPositionManager(
                optimizerMarket
            );

        uint256 lendAssets = 100_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        address account = makeAddr("optimizerShareSingleSidedVaultPmAccount");
        uint256 initialOptimizerShares = optimizer.balanceOf(address(this)) / 2;
        IERC20(address(optimizer))
            .approve(address(shareCToken), initialOptimizerShares);
        uint256 initialWrapperShares =
            shareCToken.deposit(initialOptimizerShares, account);
        vm.prank(account);
        shareCToken.postCollateral(initialWrapperShares);

        uint256 borrowAssets = 20_000e6;
        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        _refreshUsdcPriceFeed();
        _setOptimizerVaultFeedAnswer(1e8);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before single-sided vault PM leverage"
        );

        (, uint256 expectedWrapperShares) = _quoteOptimizerWrapperSharesFromVaultDeposit(
            address(positionManager), shareCToken, borrowAssets
        );

        IPositionManager.LeverageAction memory action;
        action.borrowableCToken = IBorrowableCToken(address(debtCToken));
        action.borrowAssets = borrowAssets;
        action.cToken = ICToken(address(shareCToken));
        action.expectedShares = expectedWrapperShares;

        vm.prank(account);
        positionManager.leverage(action, 0.05e18);

        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "single-sided vault PM must accrue optimizer through vault deposit"
        );
        assertEq(
            shareCToken.collateralPosted(account),
            initialWrapperShares + expectedWrapperShares,
            "vault PM should post the wrapper shares minted from optimizer deposit"
        );
        assertEq(
            debtCToken.debtBalance(account),
            borrowAssets,
            "vault PM should open requested debt"
        );
        assertEq(
            IERC20(USDC_MONAD).balanceOf(address(positionManager)),
            0,
            "PM USDC residue"
        );
        assertEq(
            IERC20(address(optimizer)).balanceOf(address(positionManager)),
            0,
            "PM optimizer residue"
        );
    }

    function test_lendingOptimizerShareCToken_singleSidedVaultPositionManagerDepositAndLeverageAccruesPredepositAndBorrow()
        public
    {
        (
            MarketManagerIsolated optimizerMarket,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();
        SingleSidedVaultPositionManager positionManager =
            _deploySingleSidedOptimizerShareVaultPositionManager(
                optimizerMarket
            );

        uint256 lendAssets = 100_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        address account = makeAddr("optimizerShareDepositAndLeverageAccount");
        uint256 preDepositOptimizerShares =
            optimizer.balanceOf(address(this)) / 4;
        IERC20(address(optimizer)).transfer(account, preDepositOptimizerShares);

        uint256 borrowAssets = 20_000e6;
        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        _refreshUsdcPriceFeed();
        _setOptimizerVaultFeedAnswer(1e8);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before PM depositAndLeverage"
        );

        (
            uint256 expectedPreDepositWrapperShares,
            uint256 expectedBorrowWrapperShares
        ) = _quoteDepositAndLeverageWrapperShares(
            account,
            address(positionManager),
            shareCToken,
            preDepositOptimizerShares,
            borrowAssets
        );

        IPositionManager.LeverageAction memory action;
        action.borrowableCToken = IBorrowableCToken(address(debtCToken));
        action.borrowAssets = borrowAssets;
        action.cToken = ICToken(address(shareCToken));
        action.expectedShares = expectedBorrowWrapperShares;

        vm.startPrank(account);
        IERC20(address(optimizer))
            .approve(address(positionManager), preDepositOptimizerShares);
        positionManager.depositAndLeverage(
            preDepositOptimizerShares, action, 0.05e18
        );
        vm.stopPrank();

        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "depositAndLeverage must accrue optimizer through predeposit or vault deposit"
        );
        assertEq(
            shareCToken.collateralPosted(account),
            expectedPreDepositWrapperShares + expectedBorrowWrapperShares,
            "PM should post predeposit wrapper shares plus borrowed optimizer-vault shares"
        );
        assertEq(
            shareCToken.balanceOf(account),
            shareCToken.collateralPosted(account),
            "all wrapper shares should be posted as collateral"
        );
        assertEq(
            debtCToken.debtBalance(account),
            borrowAssets,
            "PM should open requested debt"
        );
        assertEq(
            IERC20(address(optimizer)).balanceOf(account),
            0,
            "account optimizer residue"
        );
        assertEq(
            IERC20(USDC_MONAD).balanceOf(address(positionManager)),
            0,
            "PM USDC residue"
        );
        assertEq(
            IERC20(address(optimizer)).balanceOf(address(positionManager)),
            0,
            "PM optimizer residue"
        );
    }

    function test_lendingOptimizerShareCToken_positionManagerBorrowRevertsAtomicallyWhenExpectedSharesTooHigh()
        public
    {
        (
            MarketManagerIsolated optimizerMarket,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();
        OptimizerSharePositionManagerHarness positionManager =
            _deployOptimizerSharePositionManager(optimizerMarket);

        uint256 lendAssets = 100_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        uint256 optimizerShares = optimizer.balanceOf(address(this)) / 2;
        uint256 expectedShares = shareCToken.previewDeposit(optimizerShares);
        IERC20(address(optimizer))
            .transfer(address(positionManager), optimizerShares);

        address account = makeAddr("optimizerSharePmSlippageAccount");
        IPositionManager.LeverageAction memory action;
        action.borrowableCToken = IBorrowableCToken(address(debtCToken));
        action.borrowAssets = 20_000e6;
        action.cToken = ICToken(address(shareCToken));
        action.expectedShares = expectedShares + 1;

        vm.prank(account);
        vm.expectRevert(
            BasePositionManager.BasePositionManager__InvalidSlippage.selector
        );
        positionManager.leverage(action, 0);

        assertEq(
            shareCToken.collateralPosted(account),
            0,
            "collateral must roll back"
        );
        assertEq(debtCToken.debtBalance(account), 0, "debt must roll back");
        assertEq(
            IERC20(address(optimizer)).balanceOf(address(positionManager)),
            optimizerShares,
            "PM inventory"
        );
        assertEq(
            IERC20(USDC_MONAD).balanceOf(address(positionManager)),
            0,
            "PM debt residue"
        );
        assertEq(
            IERC20(USDC_MONAD).balanceOf(positionManager.swapSink()),
            0,
            "swap sink must roll back"
        );
    }

    function test_lendingOptimizerShareCToken_positionManagerDeleverageAccruesOptimizerAndRepaysDebt()
        public
    {
        (
            MarketManagerIsolated optimizerMarket,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();
        OptimizerSharePositionManagerHarness positionManager =
            _deployOptimizerSharePositionManager(optimizerMarket);

        uint256 lendAssets = 100_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        address account = makeAddr("optimizerSharePmDeleverageAccount");
        uint256 optimizerShares = optimizer.balanceOf(address(this)) / 2;
        uint256 expectedShares = shareCToken.previewDeposit(optimizerShares);
        IERC20(address(optimizer))
            .transfer(address(positionManager), optimizerShares);

        IPositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken =
            IBorrowableCToken(address(debtCToken));
        leverageAction.borrowAssets = 20_000e6;
        leverageAction.cToken = ICToken(address(shareCToken));
        leverageAction.expectedShares = expectedShares;

        vm.prank(account);
        positionManager.leverage(leverageAction, 0);

        uint256 collateralBefore = shareCToken.collateralPosted(account);
        uint256 debtBefore = debtCToken.debtBalance(account);
        uint256 collateralAssets = 5_000e6;
        uint256 expectedWrapperSharesBurned =
            shareCToken.previewWithdraw(collateralAssets);
        uint256 repayAssets = 5_000e6;
        deal(USDC_MONAD, address(positionManager), repayAssets);

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        _refreshUsdcPriceFeed();
        _setOptimizerVaultFeedAnswer(1e8);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before PM deleverage"
        );

        IPositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(shareCToken));
        deleverageAction.collateralAssets = collateralAssets;
        deleverageAction.borrowableCToken =
            IBorrowableCToken(address(debtCToken));
        deleverageAction.repayAssets = repayAssets;

        vm.prank(account);
        positionManager.deleverage(deleverageAction, 0.05e18);

        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "PM deleverage must sync optimizer NAV"
        );
        assertEq(
            shareCToken.collateralPosted(account),
            collateralBefore - expectedWrapperSharesBurned,
            "collateral should reduce by redeemed wrapper shares"
        );
        assertLt(
            debtCToken.debtBalance(account),
            debtBefore,
            "deleverage should repay debt"
        );
        assertEq(
            IERC20(USDC_MONAD).balanceOf(address(positionManager)),
            0,
            "PM debt residue"
        );
        assertEq(
            IERC20(address(optimizer)).balanceOf(address(positionManager)),
            0,
            "PM optimizer residue"
        );
        assertEq(
            IERC20(address(optimizer)).balanceOf(positionManager.swapSink()),
            collateralAssets,
            "swap sink should receive redeemed optimizer shares"
        );
    }

    function test_lendingOptimizerShareCToken_simplePositionManagerDeleverageSwapsRealizedOptimizerShares()
        public
    {
        (
            MarketManagerIsolated optimizerMarket,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();
        SimplePositionManager positionManager =
            _deploySimpleOptimizerSharePositionManager(optimizerMarket);
        OptimizerShareSwapTarget swapTarget = new OptimizerShareSwapTarget(
            IERC20(address(optimizer)), IERC20(USDC_MONAD)
        );
        CentralRegistry(address(liveCentralRegistry))
            .setExternalCalldataChecker(
                address(swapTarget),
                address(new MockCalldataChecker(address(swapTarget)))
            );

        uint256 lendAssets = 100_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        address account = makeAddr("optimizerShareSimplePmDeleverageAccount");
        uint256 optimizerShares = optimizer.balanceOf(address(this));
        IERC20(address(optimizer))
            .approve(address(shareCToken), optimizerShares);
        uint256 wrapperShares = shareCToken.deposit(optimizerShares, account);
        vm.startPrank(account);
        shareCToken.postCollateral(wrapperShares);
        debtCToken.borrow(20_000e6, account);
        vm.stopPrank();

        uint256 collateralBefore = shareCToken.collateralPosted(account);
        uint256 debtBefore = debtCToken.debtBalanceUpdated(account);
        uint256 collateralAssets = 5_000e6;
        uint256 expectedWrapperSharesBurned =
            shareCToken.previewWithdraw(collateralAssets);
        uint256 repayAssets = 5_000e6;
        deal(USDC_MONAD, address(swapTarget), repayAssets);

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        _refreshUsdcPriceFeed();
        _setOptimizerVaultFeedAnswer(1e8);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before simple PM deleverage"
        );

        IPositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(shareCToken));
        deleverageAction.collateralAssets = collateralAssets;
        deleverageAction.borrowableCToken =
            IBorrowableCToken(address(debtCToken));
        deleverageAction.repayAssets = repayAssets;
        deleverageAction.swapActions = new SwapperLib.Swap[](1);
        deleverageAction.swapActions[0] = SwapperLib.Swap({
            inputToken: address(optimizer),
            inputAmount: collateralAssets,
            outputToken: USDC_MONAD,
            target: address(swapTarget),
            slippage: WAD - 1,
            call: abi.encodeWithSelector(
                OptimizerShareSwapTarget.swap.selector,
                collateralAssets,
                repayAssets
            )
        });

        vm.prank(account);
        positionManager.deleverage(deleverageAction, 0.05e18);

        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "simple PM deleverage swap must sync optimizer NAV"
        );
        assertEq(
            shareCToken.collateralPosted(account),
            collateralBefore - expectedWrapperSharesBurned,
            "collateral should reduce by redeemed wrapper shares"
        );
        assertLt(
            debtCToken.debtBalance(account),
            debtBefore,
            "deleverage should repay debt"
        );
        assertEq(
            IERC20(USDC_MONAD).balanceOf(address(positionManager)),
            0,
            "PM USDC residue"
        );
        assertEq(
            IERC20(address(optimizer)).balanceOf(address(positionManager)),
            0,
            "PM optimizer residue"
        );
        assertEq(
            IERC20(address(optimizer)).balanceOf(address(swapTarget)),
            collateralAssets,
            "swap target should receive redeemed optimizer shares"
        );
        assertEq(
            IERC20(USDC_MONAD).balanceOf(address(swapTarget)),
            0,
            "swap target should spend USDC output"
        );
    }

    function test_lendingOptimizerShareCToken_dualSidedVaultPositionManagerRedeemsOptimizerVaultAndRepaysDebt()
        public
    {
        (
            MarketManagerIsolated optimizerMarket,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();
        DualSidedVaultPositionManager positionManager =
            _deployDualSidedOptimizerShareVaultPositionManager(optimizerMarket);

        uint256 lendAssets = 100_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        address account = makeAddr("optimizerShareDualSidedVaultPmAccount");
        uint256 optimizerShares = optimizer.balanceOf(address(this));
        IERC20(address(optimizer))
            .approve(address(shareCToken), optimizerShares);
        uint256 wrapperShares = shareCToken.deposit(optimizerShares, account);
        vm.startPrank(account);
        shareCToken.postCollateral(wrapperShares);
        debtCToken.borrow(20_000e6, account);
        vm.stopPrank();

        uint256 collateralBefore = shareCToken.collateralPosted(account);
        uint256 collateralAssets = 1e6;
        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        _refreshUsdcPriceFeed();
        _setOptimizerVaultFeedAnswer(1e8);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before dual-sided vault PM deleverage"
        );
        uint256 debtBefore = debtCToken.debtBalanceUpdated(account);

        IPositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(shareCToken));
        deleverageAction.collateralAssets = collateralAssets;
        deleverageAction.borrowableCToken =
            IBorrowableCToken(address(debtCToken));
        deleverageAction.repayAssets = collateralAssets;

        vm.prank(account);
        positionManager.deleverage(deleverageAction, 0.05e18);

        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "small vault redemption should still leave optimizer NAV above the stale pre-accrual value"
        );
        assertLt(
            shareCToken.collateralPosted(account),
            collateralBefore,
            "dual-sided vault PM should burn wrapper collateral"
        );
        assertLt(
            debtCToken.debtBalance(account),
            debtBefore,
            "dual-sided vault PM should repay debt"
        );
        assertEq(
            IERC20(USDC_MONAD).balanceOf(address(positionManager)),
            0,
            "PM USDC residue"
        );
        assertEq(
            IERC20(address(optimizer)).balanceOf(address(positionManager)),
            0,
            "PM optimizer residue"
        );
    }

    function test_lendingOptimizerShareCToken_dualSidedVaultPositionManagerUnderEncodedSwapLeavesUnderlyingResidue()
        public
    {
        UnderEncodedDualSidedVaultFixture memory fixture =
            _setupUnderEncodedDualSidedVaultFixture();
        uint256 collateralAssets = 1e6;
        uint256 swapInputAssets = 400000;
        uint256 repayAssets = swapInputAssets;
        fixture.debtAsset.mint(address(fixture.swapTarget), repayAssets);

        IPositionManager.DeleverageAction memory deleverageAction =
            _underEncodedDualSidedVaultDeleverageAction(
                fixture, collateralAssets, swapInputAssets
            );
        uint256 accountUsdcBefore =
            IERC20(USDC_MONAD).balanceOf(fixture.account);

        vm.prank(fixture.account);
        fixture.positionManager.deleverage(deleverageAction, 0.05e18);

        assertGt(
            optimizer.totalAssets(),
            fixture.staleTotalAssets,
            "dual-sided vault redemption must sync optimizer NAV"
        );
        assertLt(
            fixture.shareCToken.collateralPosted(fixture.account),
            fixture.collateralBefore,
            "under-encoded deleverage should still burn wrapper collateral"
        );
        assertLt(
            fixture.debtCToken.debtBalance(fixture.account),
            fixture.debtBefore,
            "under-encoded deleverage should still repay debt"
        );
        assertEq(
            IERC20(USDC_MONAD).balanceOf(fixture.account),
            accountUsdcBefore,
            "under-encoded vault underlying is not refunded to owner"
        );
        assertGt(
            IERC20(USDC_MONAD).balanceOf(address(fixture.positionManager)),
            0,
            "under-encoded vault underlying should remain as PM residue"
        );
        assertEq(
            IERC20(address(fixture.debtAsset)).balanceOf(
                address(fixture.positionManager)
            ),
            0,
            "PM debt-asset residue should be repaid or refunded"
        );
        assertEq(
            IERC20(address(optimizer)).balanceOf(
                address(fixture.positionManager)
            ),
            0,
            "PM optimizer residue"
        );
        assertEq(
            IERC20(USDC_MONAD).balanceOf(address(fixture.swapTarget)),
            swapInputAssets,
            "swap target should receive only encoded vault underlying"
        );
        assertEq(
            IERC20(address(fixture.debtAsset)).balanceOf(
                address(fixture.swapTarget)
            ),
            0,
            "swap target should spend debt-asset output"
        );

        uint256 strandedUsdc =
            IERC20(USDC_MONAD).balanceOf(address(fixture.positionManager));
        _assertNextCallerCanSweepUnderEncodedVaultResidue(
            fixture, strandedUsdc
        );
    }

    function _assertNextCallerCanSweepUnderEncodedVaultResidue(
        UnderEncodedDualSidedVaultFixture memory fixture,
        uint256 strandedUsdc
    ) internal {
        address sweeper =
            makeAddr("optimizerShareDualSidedVaultResidueSweeper");
        _postOptimizerShareCollateral(fixture.shareCToken, sweeper, 100_000e6);
        vm.prank(sweeper);
        fixture.debtCToken.borrow(20e6, sweeper);
        vm.warp(
            fixture.optimizerMarket.accountAssets(sweeper) +
                fixture.optimizerMarket.MIN_HOLD_PERIOD()
        );
        _refreshUsdcPriceFeed();
        MockV3Aggregator sweeperDebtFeed = new MockV3Aggregator(8, 1e8);
        _chainlinkAdaptor.addAsset(
            address(fixture.debtAsset), true, address(sweeperDebtFeed), 0
        );
        _setOptimizerVaultFeedAnswer(1e8);
        uint256 sweeperCollateralBefore =
            fixture.shareCToken.collateralPosted(sweeper);
        uint256 sweeperDebtBefore =
            fixture.debtCToken.debtBalanceUpdated(sweeper);
        uint256 sweepCollateralAssets = 1e6;
        uint256 sweepInputAssets = strandedUsdc + sweepCollateralAssets;
        fixture.debtAsset.mint(address(fixture.swapTarget), sweepInputAssets);
        IPositionManager.DeleverageAction memory sweepAction =
            _underEncodedDualSidedVaultDeleverageAction(
                fixture, sweepCollateralAssets, sweepInputAssets
            );

        vm.prank(sweeper);
        fixture.positionManager.deleverage(sweepAction, 0.05e18);

        assertLt(
            IERC20(USDC_MONAD).balanceOf(address(fixture.positionManager)),
            strandedUsdc,
            "next caller should be able to consume prior PM USDC residue"
        );
        assertEq(
            sweeperDebtBefore - fixture.debtCToken.debtBalance(sweeper),
            sweepInputAssets,
            "sweeper debt repayment should be funded by prior PM residue"
        );
        assertLt(
            fixture.shareCToken.collateralPosted(sweeper),
            sweeperCollateralBefore,
            "sweeper burns their own wrapper collateral while sweeping residue"
        );
    }

    function test_lendingOptimizerShareCToken_positionManagerDeleverageRollsBackWhenOptimizerPriceFails()
        public
    {
        (
            MarketManagerIsolated optimizerMarket,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();
        OptimizerSharePositionManagerHarness positionManager =
            _deployOptimizerSharePositionManager(optimizerMarket);

        uint256 lendAssets = 100_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        address account = makeAddr("optimizerSharePmFailedDeleverageAccount");
        uint256 optimizerShares = optimizer.balanceOf(address(this)) / 2;
        IERC20(address(optimizer))
            .transfer(address(positionManager), optimizerShares);

        IPositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken =
            IBorrowableCToken(address(debtCToken));
        leverageAction.borrowAssets = 20_000e6;
        leverageAction.cToken = ICToken(address(shareCToken));
        leverageAction.expectedShares =
            shareCToken.previewDeposit(optimizerShares);

        vm.prank(account);
        positionManager.leverage(leverageAction, 0);

        uint256 collateralAssets = 5_000e6;
        uint256 repayAssets = 5_000e6;
        deal(USDC_MONAD, address(positionManager), repayAssets);

        uint256[7] memory beforeState = [
            optimizer.totalAssets(),
            shareCToken.collateralPosted(account),
            shareCToken.balanceOf(account),
            shareCToken.marketCollateralPosted(),
            debtCToken.debtBalance(account),
            IERC20(address(optimizer)).balanceOf(address(positionManager)),
            IERC20(address(optimizer)).balanceOf(positionManager.swapSink())
        ];

        skip(30 days);
        _refreshUsdcPriceFeed();

        IPositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(shareCToken));
        deleverageAction.collateralAssets = collateralAssets;
        deleverageAction.borrowableCToken =
            IBorrowableCToken(address(debtCToken));
        deleverageAction.repayAssets = repayAssets;

        vm.mockCall(
            address(optimizer),
            abi.encodeWithSelector(ILendingOptimizer.asset.selector),
            abi.encode(makeAddr("driftedOptimizerAssetForPmDeleverage"))
        );

        vm.expectRevert(OracleManager.OracleManager__ErrorCodeFlagged.selector);
        positionManager.withdrawByPositionManagerForTest(
            ICToken(address(shareCToken)),
            collateralAssets,
            account,
            deleverageAction
        );

        assertEq(
            optimizer.totalAssets(),
            beforeState[0],
            "failed PM deleverage must roll back optimizer NAV accrual"
        );
        assertEq(
            shareCToken.collateralPosted(account),
            beforeState[1],
            "collateral must not decrease"
        );
        assertEq(
            shareCToken.balanceOf(account),
            beforeState[2],
            "wrapper balance must not burn"
        );
        assertEq(
            shareCToken.marketCollateralPosted(),
            beforeState[3],
            "market collateral"
        );
        assertEq(
            debtCToken.debtBalance(account),
            beforeState[4],
            "debt must not be repaid"
        );
        assertEq(
            IERC20(address(optimizer)).balanceOf(address(positionManager)),
            beforeState[5],
            "PM optimizer residue"
        );
        assertEq(
            IERC20(address(optimizer)).balanceOf(positionManager.swapSink()),
            beforeState[6],
            "swap sink optimizer"
        );
        assertEq(
            IERC20(USDC_MONAD).balanceOf(address(positionManager)),
            repayAssets,
            "PM debt asset balance"
        );
    }

    function test_lendingOptimizerShareCToken_directSeizeRequiresListedDebtToken()
        public
    {
        (,, LendingOptimizerShareCToken shareCToken) =
            _deployOptimizerShareLaunchMarket();

        uint256[] memory liquidatedShares = new uint256[](1);
        liquidatedShares[0] = 1;
        address[] memory accounts = new address[](1);
        accounts[0] = address(this);

        address attacker = makeAddr("directSeizeAttacker");
        vm.prank(attacker);
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__TokenNotListed.selector
        );
        shareCToken.seize(liquidatedShares, attacker, accounts);
    }

    function test_lendingOptimizerShareCToken_liquidationAccruesStaleOptimizerCollateral()
        public
    {
        (
            ,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();

        uint256 lendAssets = 300_000e6;
        uint256 borrowAssets = 130_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        uint256 optimizerShares = optimizer.balanceOf(address(this));
        IERC20(address(optimizer))
            .approve(address(shareCToken), optimizerShares);
        uint256 wrapperShares =
            shareCToken.deposit(optimizerShares, address(this));
        shareCToken.postCollateral(wrapperShares);
        debtCToken.borrow(borrowAssets, address(this));

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        _refreshUsdcPriceFeed();
        _setOptimizerVaultFeedAnswer(0.5e8);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before liquidation"
        );

        address liquidator = makeAddr("optimizerShareLiquidator");
        deal(USDC_MONAD, liquidator, 100_000e6);
        vm.startPrank(liquidator);
        IERC20(USDC_MONAD).approve(address(debtCToken), type(uint256).max);
        address[] memory accounts = new address[](1);
        accounts[0] = address(this);
        debtCToken.liquidate(accounts, address(shareCToken));
        vm.stopPrank();

        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "liquidation pricing must sync optimizer NAV before seizing collateral"
        );
        assertLt(
            debtCToken.debtBalance(address(this)),
            borrowAssets,
            "liquidation should repay borrower debt"
        );
        assertGt(
            shareCToken.balanceOf(liquidator),
            0,
            "liquidator should receive optimizer-share collateral"
        );
    }

    function test_lendingOptimizerShareCToken_liquidationExactAccruesStaleOptimizerCollateral()
        public
    {
        (
            ,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();

        uint256 lendAssets = 300_000e6;
        uint256 borrowAssets = 130_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        uint256 optimizerShares = optimizer.balanceOf(address(this));
        IERC20(address(optimizer))
            .approve(address(shareCToken), optimizerShares);
        uint256 wrapperShares =
            shareCToken.deposit(optimizerShares, address(this));
        shareCToken.postCollateral(wrapperShares);
        debtCToken.borrow(borrowAssets, address(this));

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        _refreshUsdcPriceFeed();
        _setOptimizerVaultFeedAnswer(0.5e8);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before exact liquidation"
        );

        uint256 repayAssets = borrowAssets / 4;
        address liquidator = makeAddr("optimizerShareExactLiquidator");
        deal(USDC_MONAD, liquidator, repayAssets);
        uint256 liquidatorUsdcBefore = IERC20(USDC_MONAD).balanceOf(liquidator);

        address[] memory accounts = new address[](1);
        accounts[0] = address(this);
        uint256[] memory debtAmounts = new uint256[](1);
        debtAmounts[0] = repayAssets;

        vm.startPrank(liquidator);
        IERC20(USDC_MONAD).approve(address(debtCToken), repayAssets);
        debtCToken.liquidateExact(debtAmounts, accounts, address(shareCToken));
        vm.stopPrank();

        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "exact liquidation pricing must sync optimizer NAV before seizing collateral"
        );
        assertEq(
            liquidatorUsdcBefore - IERC20(USDC_MONAD).balanceOf(liquidator),
            repayAssets,
            "exact liquidation should collect requested debt"
        );
        assertLt(
            debtCToken.debtBalance(address(this)),
            borrowAssets,
            "exact liquidation should reduce borrower debt"
        );
        assertGt(
            shareCToken.balanceOf(liquidator),
            0,
            "liquidator should receive optimizer-share collateral"
        );
    }

    function test_lendingOptimizerShareCToken_priceGuardCapsUpsideAndAllowsDownside()
        public
    {
        _deployOptimizerShareLaunchMarket();

        _setOptimizerVaultFeedAnswer(2e8);
        (uint256 cappedPrice, uint256 cappedErrorCode) =
            _oracleManager.getPrice(address(optimizer), true, false);
        assertEq(cappedErrorCode, 0);
        assertEq(
            cappedPrice,
            WAD,
            "optimizer share price should be capped at basePrice"
        );

        _setOptimizerVaultFeedAnswer(0.5e8);
        (uint256 downsidePrice, uint256 downsideErrorCode) =
            _oracleManager.getPrice(address(optimizer), true, true);
        assertEq(downsideErrorCode, 0);
        assertEq(
            downsidePrice,
            WAD / 2,
            "minPrice zero must not block downside pricing"
        );
    }

    function test_lendingOptimizer_rejectsApprovedDebtMarketPairedWithOptimizerShares()
        public
    {
        (, BorrowableCToken debtCToken,) = _deployOptimizerShareLaunchMarket();

        vm.expectRevert(
            LendingOptimizer.LendingOptimizer__InvalidMarketManager.selector
        );
        optimizer.addApprovedAsset(address(debtCToken), 1_000);
    }

    function test_lendingOptimizerShareCToken_borrowingAndFlashloanDisabledInContract()
        public
    {
        vm.expectRevert(
            LendingOptimizerShareCToken.LendingOptimizerShareCToken__BorrowDisabled
                .selector
        );
        optimizerCToken.borrow(1, address(this));

        vm.expectRevert(
            LendingOptimizerShareCToken.LendingOptimizerShareCToken__BorrowDisabled
                .selector
        );
        optimizerCToken.borrowFor(1, address(this), address(this));

        IPositionManager.LeverageAction memory action;
        vm.expectRevert(
            LendingOptimizerShareCToken.LendingOptimizerShareCToken__BorrowDisabled
                .selector
        );
        optimizerCToken.borrowForPositionManager(1, address(this), action);

        vm.expectRevert(
            LendingOptimizerShareCToken.LendingOptimizerShareCToken__BorrowDisabled
                .selector
        );
        optimizerCToken.flashLoan(1, "");
    }

    function test_lendingOptimizerShareCToken_repaySurfacesCannotCreateWrapperDebtOrDonations()
        public
    {
        uint256 assetsBefore = _depositIntoWrapperAndSkipForOptimizerYield();
        uint256 ownerOptimizerSharesBefore = optimizer.balanceOf(address(this));
        uint256 wrapperOptimizerSharesBefore =
            optimizer.balanceOf(address(optimizerCToken));
        address payer = makeAddr("wrapperRepayPayer");

        deal(address(optimizer), payer, 2);
        vm.prank(payer);
        optimizer.approve(address(optimizerCToken), 2);

        vm.prank(payer);
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        optimizerCToken.repay(0);

        vm.prank(payer);
        vm.expectRevert(BorrowableCToken.BorrowableCToken__InvalidParameter.selector);
        optimizerCToken.repay(1);

        vm.prank(payer);
        vm.expectRevert(BorrowableCToken.BorrowableCToken__InvalidParameter.selector);
        optimizerCToken.repayFor(1, address(this));

        assertEq(
            optimizer.totalAssets(),
            assetsBefore,
            "wrapper repay reverts must roll back optimizer accrual"
        );
        assertEq(optimizerCToken.marketOutstandingDebt(), 0, "wrapper debt");
        assertEq(
            optimizerCToken.debtBalance(address(this)),
            0,
            "owner wrapper debt"
        );
        assertEq(
            optimizer.balanceOf(payer),
            2,
            "payer optimizer shares should not be pulled"
        );
        assertEq(
            optimizer.balanceOf(address(this)),
            ownerOptimizerSharesBefore,
            "owner optimizer shares should not change"
        );
        assertEq(
            optimizer.balanceOf(address(optimizerCToken)),
            wrapperOptimizerSharesBefore,
            "wrapper optimizer shares should not receive repay donation"
        );
    }

    function testFuzz_lendingOptimizerShareCToken_borrowSurfacesAlwaysDisabled(
        uint256 assets,
        address receiver,
        address owner,
        address caller,
        bytes calldata data
    ) public {
        IPositionManager.LeverageAction memory action;

        vm.prank(caller);
        vm.expectRevert(
            LendingOptimizerShareCToken.LendingOptimizerShareCToken__BorrowDisabled
                .selector
        );
        optimizerCToken.borrow(assets, receiver);

        vm.prank(caller);
        vm.expectRevert(
            LendingOptimizerShareCToken.LendingOptimizerShareCToken__BorrowDisabled
                .selector
        );
        optimizerCToken.borrowFor(assets, receiver, owner);

        vm.prank(caller);
        vm.expectRevert(
            LendingOptimizerShareCToken.LendingOptimizerShareCToken__BorrowDisabled
                .selector
        );
        optimizerCToken.borrowForPositionManager(assets, owner, action);

        vm.prank(caller);
        vm.expectRevert(
            LendingOptimizerShareCToken.LendingOptimizerShareCToken__BorrowDisabled
                .selector
        );
        optimizerCToken.flashLoan(assets, data);
    }

    function testFuzz_lendingOptimizer_transferMovesBalancesAndAccrues(
        uint256 rawShares,
        address receiver
    ) public {
        address owner = makeAddr("fuzzOptimizerTransferOwner");
        vm.assume(receiver != address(0));
        vm.assume(receiver != address(this));
        vm.assume(receiver != owner);

        uint256 assetsBefore = _depositAndSkipForOptimizerYield(owner);
        uint256 ownerBalanceBefore = optimizer.balanceOf(owner);
        uint256 receiverBalanceBefore = optimizer.balanceOf(receiver);
        uint256 shares = bound(rawShares, 1, ownerBalanceBefore);

        vm.prank(owner);
        assertTrue(optimizer.transfer(receiver, shares));

        assertGt(
            optimizer.totalAssets(),
            assetsBefore,
            "fuzz optimizer transfer must sync NAV"
        );
        assertEq(optimizer.balanceOf(owner), ownerBalanceBefore - shares);
        assertEq(optimizer.balanceOf(receiver), receiverBalanceBefore + shares);
    }

    function testFuzz_lendingOptimizer_transferFromMovesBalancesAndAccrues(
        uint256 rawShares,
        address receiver
    ) public {
        address owner = makeAddr("fuzzOptimizerTransferFromOwner");
        address spender = makeAddr("fuzzOptimizerTransferFromSpender");
        vm.assume(receiver != address(0));
        vm.assume(receiver != address(this));
        vm.assume(receiver != owner);

        uint256 assetsBefore = _depositAndSkipForOptimizerYield(owner);
        uint256 ownerBalanceBefore = optimizer.balanceOf(owner);
        uint256 receiverBalanceBefore = optimizer.balanceOf(receiver);
        uint256 shares = bound(rawShares, 1, ownerBalanceBefore);

        vm.prank(owner);
        optimizer.approve(spender, shares);
        vm.prank(spender);
        assertTrue(optimizer.transferFrom(owner, receiver, shares));

        assertGt(
            optimizer.totalAssets(),
            assetsBefore,
            "fuzz optimizer transferFrom must sync NAV"
        );
        assertEq(optimizer.balanceOf(owner), ownerBalanceBefore - shares);
        assertEq(optimizer.balanceOf(receiver), receiverBalanceBefore + shares);
        assertEq(optimizer.allowance(owner, spender), 0);
    }

    function testFuzz_lendingOptimizerShareCToken_transferMovesBalancesAndAccrues(
        uint256 rawShares,
        address receiver
    ) public {
        vm.assume(receiver != address(0));
        vm.assume(receiver != address(this));

        uint256 assetsBefore = _depositIntoWrapperAndSkipForOptimizerYield();
        uint256 ownerBalanceBefore = optimizerCToken.balanceOf(address(this));
        uint256 receiverBalanceBefore = optimizerCToken.balanceOf(receiver);
        uint256 shares = bound(rawShares, 1, ownerBalanceBefore);

        _mockCanTransfer(address(this), receiver, shares);
        assertTrue(optimizerCToken.transfer(receiver, shares));

        assertGt(
            optimizer.totalAssets(),
            assetsBefore,
            "fuzz transfer must sync optimizer NAV"
        );
        assertEq(
            optimizerCToken.balanceOf(address(this)),
            ownerBalanceBefore - shares
        );
        assertEq(
            optimizerCToken.balanceOf(receiver), receiverBalanceBefore + shares
        );
        vm.clearMockedCalls();
    }

    function testFuzz_lendingOptimizerShareCToken_transferFromMovesBalancesAndAccrues(
        uint256 rawShares,
        address receiver
    ) public {
        address owner = makeAddr("fuzzTransferFromOwner");
        address spender = makeAddr("fuzzTransferFromSpender");
        vm.assume(receiver != address(0));
        vm.assume(receiver != owner);

        uint256 assetsBefore =
            _depositIntoWrapperAndSkipForOptimizerYield(owner);
        uint256 ownerBalanceBefore = optimizerCToken.balanceOf(owner);
        uint256 receiverBalanceBefore = optimizerCToken.balanceOf(receiver);
        uint256 shares = bound(rawShares, 1, ownerBalanceBefore);

        vm.prank(owner);
        optimizerCToken.approve(spender, shares);
        _mockCanTransfer(owner, receiver, shares);
        vm.prank(spender);
        assertTrue(optimizerCToken.transferFrom(owner, receiver, shares));

        assertGt(
            optimizer.totalAssets(),
            assetsBefore,
            "fuzz transferFrom must sync optimizer NAV"
        );
        assertEq(optimizerCToken.balanceOf(owner), ownerBalanceBefore - shares);
        assertEq(
            optimizerCToken.balanceOf(receiver), receiverBalanceBefore + shares
        );
        assertEq(optimizerCToken.allowance(owner, spender), 0);
        vm.clearMockedCalls();
    }

    function testFuzz_lendingOptimizerShareCToken_depositAndMintAccounting(
        uint256 rawDepositAssets,
        uint256 rawMintShares,
        address receiver
    ) public {
        vm.assume(receiver != address(0));

        uint256 assetsBefore = _depositAndSkipForOptimizerYield();
        uint256 optimizerShares = optimizer.balanceOf(address(this));
        uint256 depositAssets = bound(rawDepositAssets, 1, optimizerShares / 2);
        uint256 expectedDepositShares =
            optimizerCToken.previewDeposit(depositAssets);

        IERC20(address(optimizer))
            .approve(address(optimizerCToken), optimizerShares);
        _mockCanMint();
        uint256 depositShares =
            optimizerCToken.deposit(depositAssets, receiver);

        assertGt(
            optimizer.totalAssets(),
            assetsBefore,
            "fuzz deposit must sync optimizer NAV"
        );
        assertEq(depositShares, expectedDepositShares);
        assertEq(optimizerCToken.balanceOf(receiver), depositShares);

        assetsBefore = optimizer.totalAssets();
        skip(30 days);

        uint256 remainingOptimizerShares = optimizer.balanceOf(address(this));
        uint256 maxMintShares =
            optimizerCToken.convertToShares(remainingOptimizerShares / 2);
        uint256 mintShares = bound(rawMintShares, 1, maxMintShares);
        uint256 expectedMintAssets = optimizerCToken.previewMint(mintShares);
        _mockCanMint();
        uint256 mintAssets = optimizerCToken.mint(mintShares, receiver);

        assertGt(
            optimizer.totalAssets(),
            assetsBefore,
            "fuzz mint must sync optimizer NAV"
        );
        assertEq(mintAssets, expectedMintAssets);
        assertEq(
            optimizerCToken.balanceOf(receiver), depositShares + mintShares
        );
        vm.clearMockedCalls();
    }

    function testFuzz_lendingOptimizerShareCToken_redeemAndWithdrawAccounting(
        uint256 rawRedeemShares,
        uint256 rawWithdrawAssets,
        address receiver
    ) public {
        vm.assume(receiver != address(0));

        uint256 assetsBefore = _depositIntoWrapperAndSkipForOptimizerYield();
        uint256 balanceBeforeRedeem = optimizerCToken.balanceOf(address(this));
        uint256 redeemShares =
            bound(rawRedeemShares, 1, balanceBeforeRedeem / 2);
        uint256 expectedRedeemAssets =
            optimizerCToken.previewRedeem(redeemShares);

        _mockCanRedeem(address(this), redeemShares, false, 0);
        uint256 redeemedAssets =
            optimizerCToken.redeem(redeemShares, receiver, address(this));

        assertGt(
            optimizer.totalAssets(),
            assetsBefore,
            "fuzz redeem must sync optimizer NAV"
        );
        assertEq(redeemedAssets, expectedRedeemAssets);

        assetsBefore = optimizer.totalAssets();
        skip(30 days);

        uint256 maxWithdrawAssets = optimizerCToken.convertToAssets(
            optimizerCToken.balanceOf(address(this))
        );
        uint256 withdrawAssets = bound(rawWithdrawAssets, 1, maxWithdrawAssets);
        uint256 expectedWithdrawShares =
            optimizerCToken.previewWithdraw(withdrawAssets);

        _mockCanRedeem(address(this), expectedWithdrawShares, false, 0);
        uint256 withdrawnShares =
            optimizerCToken.withdraw(withdrawAssets, receiver, address(this));

        assertGt(
            optimizer.totalAssets(),
            assetsBefore,
            "fuzz withdraw must sync optimizer NAV"
        );
        assertEq(withdrawnShares, expectedWithdrawShares);
        assertEq(
            optimizerCToken.balanceOf(address(this)),
            balanceBeforeRedeem - redeemShares - withdrawnShares
        );
        vm.clearMockedCalls();
    }

    function testFuzz_lendingOptimizerShareCToken_collateralizedTransferAccounting(
        uint256 rawPostedShares,
        uint256 rawTransferShares,
        uint256 rawCollateralRedeemed,
        address receiver
    ) public {
        vm.assume(receiver != address(0));
        vm.assume(receiver != address(this));

        _depositIntoWrapperAndSkipForOptimizerYield();
        uint256 ownerBalance = optimizerCToken.balanceOf(address(this));
        uint256 postedShares = bound(rawPostedShares, 1, ownerBalance);

        _mockCanCollateralize(address(this), postedShares);
        optimizerCToken.postCollateral(postedShares);

        uint256 assetsBefore = optimizer.totalAssets();
        skip(30 days);

        uint256 transferShares = bound(rawTransferShares, 1, ownerBalance);
        uint256 collateralRedeemed =
            bound(rawCollateralRedeemed, 0, postedShares);

        _mockCanTransfer(
            address(this), receiver, transferShares, collateralRedeemed
        );
        optimizerCToken.transfer(receiver, transferShares);

        assertGt(
            optimizer.totalAssets(),
            assetsBefore,
            "fuzz collateralized transfer must sync optimizer NAV"
        );
        assertEq(
            optimizerCToken.collateralPosted(address(this)),
            postedShares - collateralRedeemed
        );
        assertEq(
            optimizerCToken.marketCollateralPosted(),
            postedShares - collateralRedeemed
        );
        vm.clearMockedCalls();
    }

    function test_lendingOptimizerShareCToken_stableLpAdaptorRouteInheritsStaleRawOptimizerSharePrice()
        public
    {
        _registerOptimizerShareVaultPriceFeed();
        _refreshUsdcPriceFeed();

        _mintOptimizerShares(100_000e6);
        uint256 optimizerSharesInLp = optimizer.balanceOf(address(this)) / 2;
        assertGt(
            optimizerSharesInLp, 0, "test setup must mint optimizer shares"
        );

        MockStableOptimizerSharePool lp =
            new MockStableOptimizerSharePool(address(optimizer), USDC_MONAD);
        lp.setReserves(uint112(optimizerSharesInLp), uint112(100_000e6));
        lp.mint(address(this), 100_000e18);

        MockStableLPAdaptor lpAdaptor =
            new MockStableLPAdaptor(liveCentralRegistry);
        _oracleManager.addApprovedAdaptor(address(lpAdaptor));
        lpAdaptor.addAsset(address(lp));
        _oracleManager.addAssetPricingAdaptor(
            address(lp), address(lpAdaptor), 0, 0, 0, 0
        );

        uint256 cTokenShares =
            IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer));
        uint256 staleTotalAssets = optimizer.totalAssets();
        vm.mockCall(
            cUSDC_WMON_MARKET,
            abi.encodeWithSelector(
                IBorrowableCToken.convertToAssets.selector, cTokenShares
            ),
            abi.encode(staleTotalAssets / 2)
        );

        (uint256 staleOptimizerPrice, uint256 staleOptimizerError) =
            _oracleManager.getPrice(address(optimizer), true, true);
        (uint256 staleLpPrice, uint256 staleLpError) =
            _oracleManager.getPrice(address(lp), true, true);
        assertEq(staleOptimizerError, NO_ERROR);
        assertEq(staleLpError, NO_ERROR);
        assertGt(staleLpPrice, 0, "stale stable LP quote must price");
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: stable LP oracle read must not sync optimizer NAV"
        );

        optimizer.accrueIfNeeded();

        (uint256 freshOptimizerPrice, uint256 freshOptimizerError) =
            _oracleManager.getPrice(address(optimizer), true, true);
        (uint256 freshLpPrice, uint256 freshLpError) =
            _oracleManager.getPrice(address(lp), true, true);
        assertEq(freshOptimizerError, NO_ERROR);
        assertEq(freshLpError, NO_ERROR);
        assertLt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "fresh accrual must reveal lower optimizer NAV"
        );
        assertLt(
            freshOptimizerPrice,
            staleOptimizerPrice,
            "optimizer price should fall after fresh accrual"
        );
        assertLt(
            freshLpPrice,
            staleLpPrice,
            "stable LP route inherits stale optimizer-share raw price"
        );

        vm.clearMockedCalls();
    }

    function test_lendingOptimizerShareCToken_stableLpCollateralStatusOfUsesStaleRawOptimizerSharePrice()
        public
    {
        _registerOptimizerShareVaultPriceFeed();
        _refreshUsdcPriceFeed();

        _mintOptimizerShares(100_000e6);
        uint256 optimizerSharesInLp = optimizer.balanceOf(address(this)) / 2;
        assertGt(
            optimizerSharesInLp, 0, "test setup must mint optimizer shares"
        );

        MockStableOptimizerSharePool lp =
            new MockStableOptimizerSharePool(address(optimizer), USDC_MONAD);
        lp.setReserves(uint112(optimizerSharesInLp), uint112(100_000e6));
        lp.mint(address(this), 150_000e18);

        MockStableLPAdaptor lpAdaptor =
            new MockStableLPAdaptor(liveCentralRegistry);
        _oracleManager.addApprovedAdaptor(address(lpAdaptor));
        lpAdaptor.addAsset(address(lp));
        _oracleManager.addAssetPricingAdaptor(
            address(lp), address(lpAdaptor), 0, 0, 0, 0
        );

        _assertRecursiveRouteCollateralMarketAuthority(
            address(lp), 50_000e18
        );
    }

    function test_lendingOptimizerShareCToken_stableLpLiquidationWaitsForRawOptimizerShareAccrual()
        public
    {
        _registerOptimizerShareVaultPriceFeed();
        _refreshUsdcPriceFeed();

        _mintOptimizerShares(100_000e6);
        uint256 optimizerSharesInLp = optimizer.balanceOf(address(this)) / 2;
        assertGt(
            optimizerSharesInLp, 0, "test setup must mint optimizer shares"
        );

        MockStableOptimizerSharePool lp =
            new MockStableOptimizerSharePool(address(optimizer), USDC_MONAD);
        lp.setReserves(uint112(optimizerSharesInLp), uint112(100_000e6));
        lp.mint(address(this), 150_000e18);

        MockStableLPAdaptor lpAdaptor =
            new MockStableLPAdaptor(liveCentralRegistry);
        _oracleManager.addApprovedAdaptor(address(lpAdaptor));
        lpAdaptor.addAsset(address(lp));
        _oracleManager.addAssetPricingAdaptor(
            address(lp), address(lpAdaptor), 0, 0, 0, 0
        );

        _assertRecursiveRouteLiquidationBlockedUntilOptimizerAccrual(
            address(lp), 50_000e18
        );
    }

    function test_lendingOptimizerShareCToken_stableLpLiquidationExactWaitsForRawOptimizerShareAccrual()
        public
    {
        _registerOptimizerShareVaultPriceFeed();
        _refreshUsdcPriceFeed();

        _mintOptimizerShares(100_000e6);
        uint256 optimizerSharesInLp = optimizer.balanceOf(address(this)) / 2;
        assertGt(
            optimizerSharesInLp, 0, "test setup must mint optimizer shares"
        );

        MockStableOptimizerSharePool lp =
            new MockStableOptimizerSharePool(address(optimizer), USDC_MONAD);
        lp.setReserves(uint112(optimizerSharesInLp), uint112(100_000e6));
        lp.mint(address(this), 150_000e18);

        MockStableLPAdaptor lpAdaptor =
            new MockStableLPAdaptor(liveCentralRegistry);
        _oracleManager.addApprovedAdaptor(address(lpAdaptor));
        lpAdaptor.addAsset(address(lp));
        _oracleManager.addAssetPricingAdaptor(
            address(lp), address(lpAdaptor), 0, 0, 0, 0
        );

        _assertRecursiveRouteLiquidationExactBlockedUntilOptimizerAccrual(
            address(lp), 50_000e18
        );
    }

    function test_lendingOptimizerShareCToken_uniswapQuoteTokenRouteInheritsStaleRawOptimizerSharePrice()
        public
    {
        _registerOptimizerShareVaultPriceFeed();
        _refreshUsdcPriceFeed();

        MockERC20 baseAsset = new MockERC20("Mock Uni Base", "mUNI", 18);
        MockUniswapV3OptimizerSharePool pool = new MockUniswapV3OptimizerSharePool(
            address(baseAsset), address(optimizer)
        );
        MockUniswapV3StaticOracle staticOracle =
            new MockUniswapV3StaticOracle();
        staticOracle.setQuoteAmount(1e6);

        uint256 currentChainId = block.chainid;
        vm.chainId(1);
        UniswapV3Adaptor uniAdaptor = new UniswapV3Adaptor(
            liveCentralRegistry,
            IStaticOracle(address(staticOracle)),
            USDC_MONAD
        );
        vm.chainId(currentChainId);

        _oracleManager.addApprovedAdaptor(address(uniAdaptor));
        UniswapV3Adaptor.AssetConfig memory config;
        config.priceSource = address(pool);
        config.secondsAgo = 900;
        uniAdaptor.addAsset(address(baseAsset), config);

        _mintOptimizerShares(100_000e6);
        uint256 cTokenShares =
            IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer));
        uint256 staleTotalAssets = optimizer.totalAssets();
        vm.mockCall(
            cUSDC_WMON_MARKET,
            abi.encodeWithSelector(
                IBorrowableCToken.convertToAssets.selector, cTokenShares
            ),
            abi.encode(staleTotalAssets / 2)
        );

        (uint256 staleOptimizerPrice, uint256 staleOptimizerError) =
            _oracleManager.getPrice(address(optimizer), true, true);
        IOracleAdaptor.PricingResult memory staleUniPrice =
            uniAdaptor.getPrice(address(baseAsset), true, true);
        assertEq(staleOptimizerError, NO_ERROR);
        assertFalse(staleUniPrice.hadError);
        assertGt(staleUniPrice.price, 0, "stale Uniswap quote must price");
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: Uniswap quote route must not sync optimizer NAV"
        );

        optimizer.accrueIfNeeded();

        (uint256 freshOptimizerPrice, uint256 freshOptimizerError) =
            _oracleManager.getPrice(address(optimizer), true, true);
        IOracleAdaptor.PricingResult memory freshUniPrice =
            uniAdaptor.getPrice(address(baseAsset), true, true);
        assertEq(freshOptimizerError, NO_ERROR);
        assertFalse(freshUniPrice.hadError);
        assertLt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "fresh accrual must reveal lower optimizer NAV"
        );
        assertLt(
            freshOptimizerPrice,
            staleOptimizerPrice,
            "optimizer price should fall after fresh accrual"
        );
        assertLt(
            freshUniPrice.price,
            staleUniPrice.price,
            "Uniswap quote route inherits stale optimizer-share raw price"
        );

        vm.clearMockedCalls();
    }

    function test_lendingOptimizerShareCToken_uniswapQuoteTokenCollateralStatusOfUsesStaleRawOptimizerSharePrice()
        public
    {
        _registerOptimizerShareVaultPriceFeed();
        _refreshUsdcPriceFeed();

        MockERC20 baseAsset = new MockERC20("Mock Uni Base", "mUNI", 18);
        MockUniswapV3OptimizerSharePool pool = new MockUniswapV3OptimizerSharePool(
            address(baseAsset), address(optimizer)
        );
        MockUniswapV3StaticOracle staticOracle =
            new MockUniswapV3StaticOracle();
        staticOracle.setQuoteAmount(1e6);

        uint256 currentChainId = block.chainid;
        vm.chainId(1);
        UniswapV3Adaptor uniAdaptor = new UniswapV3Adaptor(
            liveCentralRegistry,
            IStaticOracle(address(staticOracle)),
            USDC_MONAD
        );
        vm.chainId(currentChainId);

        _oracleManager.addApprovedAdaptor(address(uniAdaptor));
        UniswapV3Adaptor.AssetConfig memory config;
        config.priceSource = address(pool);
        config.secondsAgo = 900;
        uniAdaptor.addAsset(address(baseAsset), config);
        _oracleManager.addAssetPricingAdaptor(
            address(baseAsset), address(uniAdaptor), 0, 0, 0, 0
        );

        baseAsset.mint(address(this), 75_000e18);
        _assertRecursiveRouteCollateralMarketAuthority(
            address(baseAsset), 50_000e18
        );
    }

    function test_lendingOptimizerShareCToken_uniswapQuoteTokenLiquidationWaitsForRawOptimizerShareAccrual()
        public
    {
        _registerOptimizerShareVaultPriceFeed();
        _refreshUsdcPriceFeed();

        MockERC20 baseAsset = new MockERC20("Mock Uni Base", "mUNI", 18);
        MockUniswapV3OptimizerSharePool pool = new MockUniswapV3OptimizerSharePool(
            address(baseAsset), address(optimizer)
        );
        MockUniswapV3StaticOracle staticOracle =
            new MockUniswapV3StaticOracle();
        staticOracle.setQuoteAmount(1e6);

        uint256 currentChainId = block.chainid;
        vm.chainId(1);
        UniswapV3Adaptor uniAdaptor = new UniswapV3Adaptor(
            liveCentralRegistry,
            IStaticOracle(address(staticOracle)),
            USDC_MONAD
        );
        vm.chainId(currentChainId);

        _oracleManager.addApprovedAdaptor(address(uniAdaptor));
        UniswapV3Adaptor.AssetConfig memory config;
        config.priceSource = address(pool);
        config.secondsAgo = 900;
        uniAdaptor.addAsset(address(baseAsset), config);
        _oracleManager.addAssetPricingAdaptor(
            address(baseAsset), address(uniAdaptor), 0, 0, 0, 0
        );

        baseAsset.mint(address(this), 75_000e18);
        _assertRecursiveRouteLiquidationBlockedUntilOptimizerAccrual(
            address(baseAsset), 50_000e18
        );
    }

    function test_lendingOptimizerShareCToken_uniswapQuoteTokenLiquidationExactWaitsForRawOptimizerShareAccrual()
        public
    {
        _registerOptimizerShareVaultPriceFeed();
        _refreshUsdcPriceFeed();

        MockERC20 baseAsset = new MockERC20("Mock Uni Exact Base", "mUNIX", 18);
        MockUniswapV3OptimizerSharePool pool = new MockUniswapV3OptimizerSharePool(
            address(baseAsset), address(optimizer)
        );
        MockUniswapV3StaticOracle staticOracle =
            new MockUniswapV3StaticOracle();
        staticOracle.setQuoteAmount(1e6);

        uint256 currentChainId = block.chainid;
        vm.chainId(1);
        UniswapV3Adaptor uniAdaptor = new UniswapV3Adaptor(
            liveCentralRegistry,
            IStaticOracle(address(staticOracle)),
            USDC_MONAD
        );
        vm.chainId(currentChainId);

        _oracleManager.addApprovedAdaptor(address(uniAdaptor));
        UniswapV3Adaptor.AssetConfig memory config;
        config.priceSource = address(pool);
        config.secondsAgo = 900;
        uniAdaptor.addAsset(address(baseAsset), config);
        _oracleManager.addAssetPricingAdaptor(
            address(baseAsset), address(uniAdaptor), 0, 0, 0, 0
        );

        baseAsset.mint(address(this), 75_000e18);
        _assertRecursiveRouteLiquidationExactBlockedUntilOptimizerAccrual(
            address(baseAsset), 50_000e18
        );
    }

    function test_lendingOptimizerShareCToken_uniswapQuoteTokenDebtUnderpricedUntilRawOptimizerShareAccrual()
        public
    {
        _registerOptimizerShareVaultPriceFeed();
        _refreshUsdcPriceFeed();

        MockERC20 debtAsset = new MockERC20("Mock Uni Debt", "mDEBT", 18);
        MockUniswapV3OptimizerSharePool pool = new MockUniswapV3OptimizerSharePool(
            address(debtAsset), address(optimizer)
        );
        MockUniswapV3StaticOracle staticOracle =
            new MockUniswapV3StaticOracle();
        staticOracle.setQuoteAmount(1e6);

        uint256 currentChainId = block.chainid;
        vm.chainId(1);
        UniswapV3Adaptor uniAdaptor = new UniswapV3Adaptor(
            liveCentralRegistry,
            IStaticOracle(address(staticOracle)),
            USDC_MONAD
        );
        vm.chainId(currentChainId);

        _oracleManager.addApprovedAdaptor(address(uniAdaptor));
        UniswapV3Adaptor.AssetConfig memory config;
        config.priceSource = address(pool);
        config.secondsAgo = 900;
        uniAdaptor.addAsset(address(debtAsset), config);
        _oracleManager.addAssetPricingAdaptor(
            address(debtAsset), address(uniAdaptor), 0, 0, 0, 0
        );

        debtAsset.mint(address(this), 200_000e18);
        _assertRecursiveRouteDebtMarketAuthority(address(debtAsset));
    }

    function test_lendingOptimizerShareCToken_pendleLpQuoteAssetRouteInheritsStaleRawOptimizerSharePrice()
        public
    {
        _registerOptimizerShareVaultPriceFeed();
        _refreshUsdcPriceFeed();

        (MockPendleMarket market, MockERC20 pt, MockPendlePTOracle ptOracle) =
            _deployPendleOptimizerShareQuoteMarket();
        PendleLPTokenAdaptor lpAdaptor = new PendleLPTokenAdaptor(
            liveCentralRegistry, IPendlePTOracle(address(ptOracle))
        );

        _oracleManager.addApprovedAdaptor(address(lpAdaptor));
        PendleLPTokenAdaptor.AssetConfig memory config;
        config.pt = address(pt);
        config.twapDuration = 12;
        config.quoteAsset = address(optimizer);
        config.quoteAssetDecimals = 6;
        lpAdaptor.addAsset(address(market), config);
        _oracleManager.addAssetPricingAdaptor(
            address(market), address(lpAdaptor), 0, 0, 0, 0
        );

        _assertOracleRouteInheritsStaleRawOptimizerSharePrice(address(market));
    }

    function test_lendingOptimizerShareCToken_pendleLpCollateralStatusOfUsesStaleRawOptimizerSharePrice()
        public
    {
        _registerOptimizerShareVaultPriceFeed();
        _refreshUsdcPriceFeed();

        (MockPendleMarket market, MockERC20 pt, MockPendlePTOracle ptOracle) =
            _deployPendleOptimizerShareQuoteMarket();
        PendleLPTokenAdaptor lpAdaptor = new PendleLPTokenAdaptor(
            liveCentralRegistry, IPendlePTOracle(address(ptOracle))
        );

        _oracleManager.addApprovedAdaptor(address(lpAdaptor));
        PendleLPTokenAdaptor.AssetConfig memory config;
        config.pt = address(pt);
        config.twapDuration = 12;
        config.quoteAsset = address(optimizer);
        config.quoteAssetDecimals = 6;
        lpAdaptor.addAsset(address(market), config);
        _oracleManager.addAssetPricingAdaptor(
            address(market), address(lpAdaptor), 0, 0, 0, 0
        );

        market.mint(address(this), 75_000e18);
        _assertRecursiveRouteCollateralMarketAuthority(
            address(market), 50_000e18
        );
    }

    function test_lendingOptimizerShareCToken_pendleLpLiquidationWaitsForRawOptimizerShareAccrual()
        public
    {
        _registerOptimizerShareVaultPriceFeed();
        _refreshUsdcPriceFeed();

        (MockPendleMarket market, MockERC20 pt, MockPendlePTOracle ptOracle) =
            _deployPendleOptimizerShareQuoteMarket();
        PendleLPTokenAdaptor lpAdaptor = new PendleLPTokenAdaptor(
            liveCentralRegistry, IPendlePTOracle(address(ptOracle))
        );

        _oracleManager.addApprovedAdaptor(address(lpAdaptor));
        PendleLPTokenAdaptor.AssetConfig memory config;
        config.pt = address(pt);
        config.twapDuration = 12;
        config.quoteAsset = address(optimizer);
        config.quoteAssetDecimals = 6;
        lpAdaptor.addAsset(address(market), config);
        _oracleManager.addAssetPricingAdaptor(
            address(market), address(lpAdaptor), 0, 0, 0, 0
        );

        market.mint(address(this), 75_000e18);
        _assertRecursiveRouteLiquidationBlockedUntilOptimizerAccrual(
            address(market), 50_000e18
        );
    }

    function test_lendingOptimizerShareCToken_pendleLpLiquidationExactWaitsForRawOptimizerShareAccrual()
        public
    {
        _registerOptimizerShareVaultPriceFeed();
        _refreshUsdcPriceFeed();

        (MockPendleMarket market, MockERC20 pt, MockPendlePTOracle ptOracle) =
            _deployPendleOptimizerShareQuoteMarket();
        PendleLPTokenAdaptor lpAdaptor = new PendleLPTokenAdaptor(
            liveCentralRegistry, IPendlePTOracle(address(ptOracle))
        );

        _oracleManager.addApprovedAdaptor(address(lpAdaptor));
        PendleLPTokenAdaptor.AssetConfig memory config;
        config.pt = address(pt);
        config.twapDuration = 12;
        config.quoteAsset = address(optimizer);
        config.quoteAssetDecimals = 6;
        lpAdaptor.addAsset(address(market), config);
        _oracleManager.addAssetPricingAdaptor(
            address(market), address(lpAdaptor), 0, 0, 0, 0
        );

        market.mint(address(this), 75_000e18);
        _assertRecursiveRouteLiquidationExactBlockedUntilOptimizerAccrual(
            address(market), 50_000e18
        );
    }

    function test_lendingOptimizerShareCToken_pendlePtQuoteAssetRouteInheritsStaleRawOptimizerSharePrice()
        public
    {
        _registerOptimizerShareVaultPriceFeed();
        _refreshUsdcPriceFeed();

        (MockPendleMarket market, MockERC20 pt, MockPendlePTOracle ptOracle) =
            _deployPendleOptimizerShareQuoteMarket();
        PendlePrincipalTokenAdaptor ptAdaptor = new PendlePrincipalTokenAdaptor(
            liveCentralRegistry, IPendlePTOracle(address(ptOracle))
        );

        _oracleManager.addApprovedAdaptor(address(ptAdaptor));
        PendlePrincipalTokenAdaptor.AssetConfig memory config;
        config.market = IPMarket(address(market));
        config.twapDuration = 12;
        config.quoteAsset = address(optimizer);
        config.quoteAssetDecimals = 6;
        ptAdaptor.addAsset(address(pt), config);
        _oracleManager.addAssetPricingAdaptor(
            address(pt), address(ptAdaptor), 0, 0, 0, 0
        );

        _assertOracleRouteInheritsStaleRawOptimizerSharePrice(address(pt));
    }

    function test_lendingOptimizerShareCToken_pendlePtCollateralStatusOfUsesStaleRawOptimizerSharePrice()
        public
    {
        _registerOptimizerShareVaultPriceFeed();
        _refreshUsdcPriceFeed();

        (MockPendleMarket market, MockERC20 pt, MockPendlePTOracle ptOracle) =
            _deployPendleOptimizerShareQuoteMarket();
        PendlePrincipalTokenAdaptor ptAdaptor = new PendlePrincipalTokenAdaptor(
            liveCentralRegistry, IPendlePTOracle(address(ptOracle))
        );

        _oracleManager.addApprovedAdaptor(address(ptAdaptor));
        PendlePrincipalTokenAdaptor.AssetConfig memory config;
        config.market = IPMarket(address(market));
        config.twapDuration = 12;
        config.quoteAsset = address(optimizer);
        config.quoteAssetDecimals = 6;
        ptAdaptor.addAsset(address(pt), config);
        _oracleManager.addAssetPricingAdaptor(
            address(pt), address(ptAdaptor), 0, 0, 0, 0
        );

        pt.mint(address(this), 75_000e18);
        _assertRecursiveRouteCollateralMarketAuthority(address(pt), 50_000e18);
    }

    function test_lendingOptimizerShareCToken_pendlePtLiquidationWaitsForRawOptimizerShareAccrual()
        public
    {
        _registerOptimizerShareVaultPriceFeed();
        _refreshUsdcPriceFeed();

        (MockPendleMarket market, MockERC20 pt, MockPendlePTOracle ptOracle) =
            _deployPendleOptimizerShareQuoteMarket();
        PendlePrincipalTokenAdaptor ptAdaptor = new PendlePrincipalTokenAdaptor(
            liveCentralRegistry, IPendlePTOracle(address(ptOracle))
        );

        _oracleManager.addApprovedAdaptor(address(ptAdaptor));
        PendlePrincipalTokenAdaptor.AssetConfig memory config;
        config.market = IPMarket(address(market));
        config.twapDuration = 12;
        config.quoteAsset = address(optimizer);
        config.quoteAssetDecimals = 6;
        ptAdaptor.addAsset(address(pt), config);
        _oracleManager.addAssetPricingAdaptor(
            address(pt), address(ptAdaptor), 0, 0, 0, 0
        );

        pt.mint(address(this), 75_000e18);
        _assertRecursiveRouteLiquidationBlockedUntilOptimizerAccrual(
            address(pt), 50_000e18
        );
    }

    function test_lendingOptimizerShareCToken_pendlePtLiquidationExactWaitsForRawOptimizerShareAccrual()
        public
    {
        _registerOptimizerShareVaultPriceFeed();
        _refreshUsdcPriceFeed();

        (MockPendleMarket market, MockERC20 pt, MockPendlePTOracle ptOracle) =
            _deployPendleOptimizerShareQuoteMarket();
        PendlePrincipalTokenAdaptor ptAdaptor = new PendlePrincipalTokenAdaptor(
            liveCentralRegistry, IPendlePTOracle(address(ptOracle))
        );

        _oracleManager.addApprovedAdaptor(address(ptAdaptor));
        PendlePrincipalTokenAdaptor.AssetConfig memory config;
        config.market = IPMarket(address(market));
        config.twapDuration = 12;
        config.quoteAsset = address(optimizer);
        config.quoteAssetDecimals = 6;
        ptAdaptor.addAsset(address(pt), config);
        _oracleManager.addAssetPricingAdaptor(
            address(pt), address(ptAdaptor), 0, 0, 0, 0
        );

        pt.mint(address(this), 75_000e18);
        _assertRecursiveRouteLiquidationExactBlockedUntilOptimizerAccrual(
            address(pt), 50_000e18
        );
    }

    function test_lendingOptimizerShareCToken_plainNestedWrapperCollateralCanPassStaleBorrowCheckAfterLoss()
        public
    {
        (
            MarketManagerIsolated wrapperCollateralMarket,
            BorrowableCToken debtCToken,
            SimpleCToken wrapperCollateralCToken
        ) = _deployPlainWrapperShareCollateralMarket();

        uint256 lendAssets = 500_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        uint256 collateralShares = optimizerCToken.balanceOf(address(this)) / 2;
        _mockCanTransfer(
            address(this), address(wrapperCollateralCToken), collateralShares
        );
        IERC20(address(optimizerCToken))
            .approve(address(wrapperCollateralCToken), collateralShares);
        wrapperCollateralCToken.depositAsCollateral(
            collateralShares, address(this)
        );
        vm.clearMockedCalls();

        uint256 staleTotalAssets = optimizer.totalAssets();
        _mockOptimizerApprovedMarketAssets(staleTotalAssets / 20);
        _refreshUsdcPriceFeed();
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before nested wrapper borrow"
        );

        uint256 borrowAssets = 30_000e6;
        debtCToken.borrow(borrowAssets, address(this));
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "outer cToken borrow check does not sync inner optimizer NAV"
        );

        optimizer.accrueIfNeeded();
        assertLt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "fresh accrual must reveal lower nested wrapper collateral value"
        );

        (, uint256 maxDebt, uint256 debt) =
            wrapperCollateralMarket.statusOf(address(this));
        assertGt(
            debt,
            maxDebt,
            "nested wrapper-share collateral can become unhealthy after fresh accrual"
        );

        vm.clearMockedCalls();
    }

    function test_lendingOptimizerShareCToken_plainNestedWrapperCollateralLiquidationWaitsForOptimizerAccrual()
        public
    {
        (
            ,
            BorrowableCToken debtCToken,
            SimpleCToken wrapperCollateralCToken
        ) = _deployPlainWrapperShareCollateralMarket();

        uint256 lendAssets = 500_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        uint256 collateralShares = optimizerCToken.balanceOf(address(this)) / 2;
        _mockCanTransfer(
            address(this), address(wrapperCollateralCToken), collateralShares
        );
        IERC20(address(optimizerCToken))
            .approve(address(wrapperCollateralCToken), collateralShares);
        wrapperCollateralCToken.depositAsCollateral(
            collateralShares, address(this)
        );
        vm.clearMockedCalls();

        uint256 staleTotalAssets = optimizer.totalAssets();
        _mockOptimizerApprovedMarketAssets(staleTotalAssets / 20);
        _refreshUsdcPriceFeed();

        uint256 borrowAssets = 30_000e6;
        debtCToken.borrow(borrowAssets, address(this));
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "nested wrapper liquidation setup must leave NAV stale"
        );

        address[] memory accounts = new address[](1);
        accounts[0] = address(this);
        address liquidator = makeAddr("nestedWrapperCollateralLiquidator");
        deal(USDC_MONAD, liquidator, 100_000e6);

        vm.startPrank(liquidator);
        IERC20(USDC_MONAD).approve(address(debtCToken), type(uint256).max);
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__NoLiquidationAvailable
                .selector
        );
        debtCToken.liquidate(accounts, address(wrapperCollateralCToken));
        vm.stopPrank();

        optimizer.accrueIfNeeded();
        assertLt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "fresh accrual must reveal lower nested wrapper collateral value"
        );

        uint256 liquidatorCollateralBefore =
            wrapperCollateralCToken.balanceOf(liquidator);
        vm.startPrank(liquidator);
        debtCToken.liquidate(accounts, address(wrapperCollateralCToken));
        vm.stopPrank();

        assertLt(
            debtCToken.debtBalance(address(this)),
            borrowAssets,
            "fresh liquidation should reduce borrower debt"
        );
        assertGt(
            wrapperCollateralCToken.balanceOf(liquidator),
            liquidatorCollateralBefore,
            "liquidator should receive nested wrapper-share collateral"
        );

        vm.clearMockedCalls();
    }

    function test_lendingOptimizerShareCToken_plainNestedWrapperDebtCanPassStaleBorrowCheckAndEndUnhealthy()
        public
    {
        (
            MarketManagerIsolated wrapperDebtMarket,
            BorrowableCToken wrapperDebtCToken,
            MockERC20 collateral,
            SimpleCToken collateralCToken
        ) = _deployPlainBorrowableWrapperDebtMarket();

        uint256 lenderShares = optimizerCToken.balanceOf(address(this)) / 2;
        _mockCanTransfer(address(this), address(wrapperDebtCToken), lenderShares);
        IERC20(address(optimizerCToken))
            .approve(address(wrapperDebtCToken), lenderShares);
        wrapperDebtCToken.deposit(lenderShares, address(this));
        vm.clearMockedCalls();

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(365 days);
        _refreshUsdcPriceFeed();
        _refreshOptimizerShareNestedVaultFeeds();
        _chainlinkAdaptor.addAsset(
            address(collateral), true, address(new MockV3Aggregator(8, 1e8)), 0
        );
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before wrapper-debt borrow"
        );

        uint256 borrowShares = lenderShares / 4;
        (uint256 staleDebtPrice, uint256 staleDebtPriceError) =
            _oracleManager.getPrice(address(optimizerCToken), true, false);
        assertEq(staleDebtPriceError, NO_ERROR);
        uint256 staleDebtValue =
            FixedPointMathLib.mulDivUp(borrowShares, staleDebtPrice, 1e6);
        uint256 targetMaxDebt = staleDebtValue + 10e18;
        uint256 collateralAmount =
            FixedPointMathLib.mulDivUp(targetMaxDebt, BPS, 7000);
        address borrower = makeAddr("plainWrapperDebtBorrower");

        collateral.mint(borrower, collateralAmount);
        vm.startPrank(borrower);
        IERC20(address(collateral))
            .approve(address(collateralCToken), collateralAmount);
        collateralCToken.depositAsCollateral(collateralAmount, borrower);
        vm.stopPrank();

        skip(1201);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: collateral setup must not refresh optimizer NAV"
        );

        _mockCanTransfer(address(wrapperDebtCToken), borrower, borrowShares);
        vm.prank(borrower);
        wrapperDebtCToken.borrow(borrowShares, borrower);
        vm.clearMockedCalls();

        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "wrapper-share debt transfer refreshes only after borrow check"
        );
        assertEq(optimizerCToken.balanceOf(borrower), borrowShares);

        (, uint256 maxDebt, uint256 debt) =
            wrapperDebtMarket.statusOf(borrower);
        assertGt(
            debt,
            maxDebt,
            "plain borrowable wrapper-share debt can become unhealthy after transfer accrual"
        );
    }

    function test_lendingOptimizerShareCToken_plainNestedWrapperDebtLiquidationWaitsForOptimizerAccrual()
        public
    {
        (
            MarketManagerIsolated wrapperDebtMarket,
            BorrowableCToken wrapperDebtCToken,
            MockERC20 collateral,
            SimpleCToken collateralCToken
        ) = _deployPlainBorrowableWrapperDebtMarket();

        uint256 lenderShares = optimizerCToken.balanceOf(address(this)) / 2;
        _mockCanTransfer(address(this), address(wrapperDebtCToken), lenderShares);
        IERC20(address(optimizerCToken))
            .approve(address(wrapperDebtCToken), lenderShares);
        wrapperDebtCToken.deposit(lenderShares, address(this));
        vm.clearMockedCalls();

        uint256 borrowShares = lenderShares / 4;
        address borrower = makeAddr("plainWrapperDebtLiqBorrower");
        {
            (uint256 staleDebtPrice, uint256 staleDebtPriceError) =
                _oracleManager.getPrice(address(optimizerCToken), true, false);
            assertEq(staleDebtPriceError, NO_ERROR);
            uint256 staleDebtValue =
                FixedPointMathLib.mulDivUp(borrowShares, staleDebtPrice, 1e6);
            uint256 collateralAmount =
                FixedPointMathLib.mulDivUp(staleDebtValue + 10e18, BPS, 7000);

            collateral.mint(borrower, collateralAmount);
            vm.startPrank(borrower);
            IERC20(address(collateral))
                .approve(address(collateralCToken), collateralAmount);
            collateralCToken.depositAsCollateral(collateralAmount, borrower);
            _mockCanTransfer(address(wrapperDebtCToken), borrower, borrowShares);
            wrapperDebtCToken.borrow(borrowShares, borrower);
            vm.stopPrank();
            vm.clearMockedCalls();
        }

        address liquidator = makeAddr("plainWrapperDebtLiquidator");
        uint256 liquidatorShares = lenderShares / 2;
        _mockCanTransfer(address(this), liquidator, liquidatorShares);
        optimizerCToken.transfer(liquidator, liquidatorShares);
        vm.clearMockedCalls();
        vm.prank(liquidator);
        IERC20(address(optimizerCToken))
            .approve(address(wrapperDebtCToken), type(uint256).max);

        uint256 staleTotalAssets = optimizer.totalAssets();
        _mockOptimizerApprovedMarketAssets(staleTotalAssets * 20);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before wrapper-debt liquidation"
        );

        address[] memory accounts = new address[](1);
        accounts[0] = borrower;

        vm.startPrank(liquidator);
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__NoLiquidationAvailable
                .selector
        );
        wrapperDebtCToken.liquidate(accounts, address(collateralCToken));
        vm.stopPrank();
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "stale wrapper-debt liquidation attempt must not sync optimizer NAV"
        );

        optimizer.accrueIfNeeded();
        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "fresh accrual must reveal higher wrapper-share debt value"
        );

        uint256 borrowerDebtBefore = wrapperDebtCToken.debtBalance(borrower);
        uint256 liquidatorCollateralBefore = collateralCToken.balanceOf(liquidator);
        _mockWrapperDebtLiquidationRepayTransfer(
            wrapperDebtMarket,
            wrapperDebtCToken,
            collateralCToken,
            liquidator,
            accounts
        );
        vm.startPrank(liquidator);
        wrapperDebtCToken.liquidate(accounts, address(collateralCToken));
        vm.stopPrank();
        vm.clearMockedCalls();

        assertLt(
            wrapperDebtCToken.debtBalance(borrower),
            borrowerDebtBefore,
            "fresh liquidation should reduce borrower wrapper-share debt"
        );
        assertGt(
            collateralCToken.balanceOf(liquidator),
            liquidatorCollateralBefore,
            "liquidator should receive non-wrapper collateral"
        );
    }

    function test_lendingOptimizerShareCToken_plainNestedWrapperDebtPartialRepayAccruesBeforeResidualReview()
        public
    {
        PlainNestedWrapperDebtRepayFixture memory fixture =
            _preparePlainNestedWrapperDebtPartialRepayFixture();

        vm.warp(
            fixture.market.accountAssets(fixture.borrower)
                + fixture.market.MIN_HOLD_PERIOD()
        );

        uint256 staleTotalAssets = optimizer.totalAssets();
        _mockOptimizerApprovedMarketAssets(staleTotalAssets * 20);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before wrapper-debt repay"
        );

        uint256 debtBeforeRepay = fixture.debtCToken.debtBalance(fixture.borrower);
        assertGt(
            debtBeforeRepay, fixture.repayShares, "repay must remain partial"
        );
        uint256 expectedResidualDebt = debtBeforeRepay - fixture.repayShares;
        uint256 staleResidualValue = FixedPointMathLib.mulDiv(
            expectedResidualDebt, fixture.staleDebtPrice, fixture.debtUnit
        );
        assertLt(
            staleResidualValue,
            fixture.minLoanSize,
            "stale residual debt should fail minimum loan size review"
        );

        vm.startPrank(fixture.repayer);
        IERC20(address(optimizerCToken))
            .approve(address(fixture.debtCToken), fixture.repayShares);
        _mockCanTransfer(
            fixture.repayer, address(fixture.debtCToken), fixture.repayShares
        );
        fixture.debtCToken.repayFor(fixture.repayShares, fixture.borrower);
        vm.stopPrank();
        vm.clearMockedCalls();

        (uint256 freshDebtPrice, uint256 freshDebtPriceError) =
            _oracleManager.getPrice(address(optimizerCToken), true, true);
        assertEq(freshDebtPriceError, NO_ERROR);
        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "wrapper-share repay transfer should accrue before residual review"
        );
        assertGt(
            freshDebtPrice,
            fixture.staleDebtPrice,
            "fresh debt price should reflect transfer-triggered optimizer accrual"
        );
        assertGt(
            FixedPointMathLib.mulDiv(
                fixture.debtCToken.debtBalance(fixture.borrower),
                freshDebtPrice,
                fixture.debtUnit
            ),
            fixture.minLoanSize,
            "fresh residual debt should pass minimum loan size review"
        );
        assertEq(
            optimizerCToken.balanceOf(fixture.repayer),
            0,
            "repayer wrapper shares should be consumed"
        );
    }

    function _preparePlainNestedWrapperDebtPartialRepayFixture()
        internal
        returns (PlainNestedWrapperDebtRepayFixture memory fixture)
    {
        MockERC20 collateral;
        SimpleCToken collateralCToken;
        (
            fixture.market,
            fixture.debtCToken,
            collateral,
            collateralCToken
        ) = _deployPlainBorrowableWrapperDebtMarket();

        uint256 lenderShares = optimizerCToken.balanceOf(address(this)) / 2;
        _mockCanTransfer(address(this), address(fixture.debtCToken), lenderShares);
        IERC20(address(optimizerCToken))
            .approve(address(fixture.debtCToken), lenderShares);
        fixture.debtCToken.deposit(lenderShares, address(this));
        vm.clearMockedCalls();

        uint256 staleDebtPriceError;
        (fixture.staleDebtPrice, staleDebtPriceError) =
            _oracleManager.getPrice(address(optimizerCToken), true, true);
        assertEq(staleDebtPriceError, NO_ERROR);

        fixture.minLoanSize = fixture.market.MIN_LOAN_SIZE();
        fixture.debtUnit = 10 ** fixture.debtCToken.decimals();
        uint256 borrowShares = FixedPointMathLib.mulDivUp(
            fixture.minLoanSize * 2, fixture.debtUnit, fixture.staleDebtPrice
        );
        uint256 targetResidualShares = FixedPointMathLib.mulDiv(
            fixture.minLoanSize / 2, fixture.debtUnit, fixture.staleDebtPrice
        );
        assertGt(targetResidualShares, 0, "residual debt must be nonzero");
        assertGt(
            borrowShares,
            targetResidualShares,
            "borrow must leave room for partial repay"
        );

        fixture.borrower = makeAddr("plainWrapperDebtRepayBorrower");
        collateral.mint(fixture.borrower, 1_000e18);
        vm.startPrank(fixture.borrower);
        IERC20(address(collateral)).approve(address(collateralCToken), 1_000e18);
        collateralCToken.depositAsCollateral(1_000e18, fixture.borrower);
        _mockCanTransfer(address(fixture.debtCToken), fixture.borrower, borrowShares);
        fixture.debtCToken.borrow(borrowShares, fixture.borrower);
        vm.stopPrank();
        vm.clearMockedCalls();

        fixture.repayer = makeAddr("plainWrapperDebtRepayer");
        fixture.repayShares = borrowShares - targetResidualShares;
        _mockCanTransfer(address(this), fixture.repayer, fixture.repayShares);
        optimizerCToken.transfer(fixture.repayer, fixture.repayShares);
        vm.clearMockedCalls();
    }

    function _assertRecursiveRouteCollateralMarketAuthority(
        address routeAsset,
        uint256 collateralAmount
    ) internal {
        _mintOptimizerShares(100_000e6);

        CentralRegistry cr = CentralRegistry(address(liveCentralRegistry));
        MarketManagerIsolated recursiveMarket =
            new MarketManagerIsolated(liveCentralRegistry, 10e18, false);
        cr.addMarketManager(address(recursiveMarket));

        DynamicIRM debtIRM = _deployOptimizerCTokenIRM();
        BorrowableCToken debtCToken = new BorrowableCToken(
            liveCentralRegistry,
            IERC20(USDC_MONAD),
            address(recursiveMarket),
            address(debtIRM)
        );
        debtIRM.setLinkedToken(address(debtCToken));

        SimpleCToken routeCToken = new SimpleCToken(
            liveCentralRegistry, IERC20(routeAsset), address(recursiveMarket)
        );
        _oracleManager.addCTokenSupport(address(debtCToken));
        _oracleManager.addCTokenSupport(address(routeCToken));

        deal(USDC_MONAD, address(this), 100_000e6 + 77777);
        IERC20(USDC_MONAD).approve(address(debtCToken), type(uint256).max);
        IERC20(routeAsset).approve(address(routeCToken), type(uint256).max);
        recursiveMarket.listTokens(address(routeCToken), address(debtCToken));
        _configureToken(
            recursiveMarket, address(routeCToken), 7000, 1_000_000e18, 0
        );
        _configureToken(
            recursiveMarket, address(debtCToken), 0, 0, 1_000_000e6
        );

        debtCToken.deposit(100_000e6, address(this));
        assertGt(
            routeCToken.depositAsCollateral(collateralAmount, address(this)),
            0,
            "route collateral deposit must mint shares"
        );

        vm.warp(
            recursiveMarket.accountAssets(address(this))
                + recursiveMarket.MIN_HOLD_PERIOD()
        );
        _refreshUsdcPriceFeed();

        uint256 staleTotalAssets = optimizer.totalAssets();
        vm.mockCall(
            cUSDC_WMON_MARKET,
            abi.encodeWithSelector(
                IBorrowableCToken.convertToAssets.selector,
                IBorrowableCToken(cUSDC_WMON_MARKET)
                    .balanceOf(address(optimizer))
            ),
            abi.encode(staleTotalAssets / 2)
        );

        (, uint256 staleMaxDebtBeforeBorrow,) =
            recursiveMarket.statusOf(address(this));
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "recursive route statusOf must not sync optimizer NAV before accrual"
        );
        uint256 borrowAssets = FixedPointMathLib.mulDiv(
            staleMaxDebtBeforeBorrow, 9970 * 1e6, BPS * WAD
        );
        assertGt(borrowAssets, 10e6, "borrow should exceed minimum loan size");

        debtCToken.borrow(borrowAssets, address(this));

        (, uint256 staleMaxDebtAfterBorrow, uint256 staleDebtAfterBorrow) =
            recursiveMarket.statusOf(address(this));
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "recursive route borrow/status path must still leave optimizer NAV stale"
        );
        assertGe(
            staleMaxDebtAfterBorrow,
            staleDebtAfterBorrow,
            "stale recursive route leaves account apparently healthy"
        );

        optimizer.accrueIfNeeded();

        (, uint256 freshMaxDebt, uint256 freshDebt) =
            recursiveMarket.statusOf(address(this));
        assertLt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "explicit optimizer accrual must reveal lower NAV"
        );
        assertLt(
            freshMaxDebt,
            staleMaxDebtAfterBorrow,
            "fresh recursive route should reduce collateral capacity"
        );
        assertGt(
            freshDebt,
            freshMaxDebt,
            "fresh recursive route reveals the configured collateral account is underwater"
        );

        vm.clearMockedCalls();
    }

    function _assertRecursiveRouteLiquidationBlockedUntilOptimizerAccrual(
        address routeAsset,
        uint256 collateralAmount
    ) internal {
        _mintOptimizerShares(100_000e6);

        CentralRegistry cr = CentralRegistry(address(liveCentralRegistry));
        MarketManagerIsolated recursiveMarket =
            new MarketManagerIsolated(liveCentralRegistry, 10e18, false);
        cr.addMarketManager(address(recursiveMarket));

        DynamicIRM debtIRM = _deployOptimizerCTokenIRM();
        BorrowableCToken debtCToken = new BorrowableCToken(
            liveCentralRegistry,
            IERC20(USDC_MONAD),
            address(recursiveMarket),
            address(debtIRM)
        );
        debtIRM.setLinkedToken(address(debtCToken));

        SimpleCToken routeCToken = new SimpleCToken(
            liveCentralRegistry, IERC20(routeAsset), address(recursiveMarket)
        );
        _oracleManager.addCTokenSupport(address(debtCToken));
        _oracleManager.addCTokenSupport(address(routeCToken));

        deal(USDC_MONAD, address(this), 100_000e6 + 77777);
        IERC20(USDC_MONAD).approve(address(debtCToken), type(uint256).max);
        IERC20(routeAsset).approve(address(routeCToken), type(uint256).max);
        recursiveMarket.listTokens(address(routeCToken), address(debtCToken));
        _configureToken(
            recursiveMarket, address(routeCToken), 7000, 1_000_000e18, 0
        );
        _configureToken(
            recursiveMarket, address(debtCToken), 0, 0, 1_000_000e6
        );

        debtCToken.deposit(100_000e6, address(this));
        uint256 collateralShares =
            routeCToken.depositAsCollateral(collateralAmount, address(this));
        assertGt(
            collateralShares, 0, "route collateral deposit must mint shares"
        );

        vm.warp(
            recursiveMarket.accountAssets(address(this))
                + recursiveMarket.MIN_HOLD_PERIOD()
        );
        _refreshUsdcPriceFeed();

        uint256 cTokenShares =
            IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer));
        uint256 staleTotalAssets = optimizer.totalAssets();
        vm.mockCall(
            cUSDC_WMON_MARKET,
            abi.encodeWithSelector(
                IBorrowableCToken.convertToAssets.selector, cTokenShares
            ),
            abi.encode(staleTotalAssets / 2)
        );

        (, uint256 staleMaxDebtBeforeBorrow,) =
            recursiveMarket.statusOf(address(this));
        uint256 borrowAssets = FixedPointMathLib.mulDiv(
            staleMaxDebtBeforeBorrow, 9970 * 1e6, BPS * WAD
        );
        assertGt(borrowAssets, 10e6, "borrow should exceed minimum loan size");

        debtCToken.borrow(borrowAssets, address(this));
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "recursive route liquidation setup must still leave optimizer NAV stale"
        );

        address[] memory accounts = new address[](1);
        accounts[0] = address(this);
        address liquidator = makeAddr("recursiveRouteLiquidator");
        deal(USDC_MONAD, liquidator, 100_000e6);

        vm.startPrank(liquidator);
        IERC20(USDC_MONAD).approve(address(debtCToken), type(uint256).max);
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__NoLiquidationAvailable
            .selector
        );
        debtCToken.liquidate(accounts, address(routeCToken));
        vm.stopPrank();
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "stale liquidation attempt must not sync recursive optimizer NAV"
        );

        optimizer.accrueIfNeeded();

        assertLt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "explicit optimizer accrual must reveal lower NAV"
        );

        vm.startPrank(liquidator);
        debtCToken.liquidate(accounts, address(routeCToken));
        vm.stopPrank();

        assertLt(
            debtCToken.debtBalance(address(this)),
            borrowAssets,
            "fresh liquidation should reduce borrower debt"
        );
        assertGt(
            routeCToken.balanceOf(liquidator),
            0,
            "liquidator should receive recursive-route collateral"
        );

        vm.clearMockedCalls();
    }

    function _assertRecursiveRouteLiquidationExactBlockedUntilOptimizerAccrual(
        address routeAsset,
        uint256 collateralAmount
    ) internal {
        _mintOptimizerShares(100_000e6);

        CentralRegistry cr = CentralRegistry(address(liveCentralRegistry));
        MarketManagerIsolated recursiveMarket =
            new MarketManagerIsolated(liveCentralRegistry, 10e18, false);
        cr.addMarketManager(address(recursiveMarket));

        DynamicIRM debtIRM = _deployOptimizerCTokenIRM();
        BorrowableCToken debtCToken = new BorrowableCToken(
            liveCentralRegistry,
            IERC20(USDC_MONAD),
            address(recursiveMarket),
            address(debtIRM)
        );
        debtIRM.setLinkedToken(address(debtCToken));

        SimpleCToken routeCToken = new SimpleCToken(
            liveCentralRegistry, IERC20(routeAsset), address(recursiveMarket)
        );
        _oracleManager.addCTokenSupport(address(debtCToken));
        _oracleManager.addCTokenSupport(address(routeCToken));

        deal(USDC_MONAD, address(this), 100_000e6 + 77777);
        IERC20(USDC_MONAD).approve(address(debtCToken), type(uint256).max);
        IERC20(routeAsset).approve(address(routeCToken), type(uint256).max);
        recursiveMarket.listTokens(address(routeCToken), address(debtCToken));
        _configureToken(
            recursiveMarket, address(routeCToken), 7000, 1_000_000e18, 0
        );
        _configureToken(
            recursiveMarket, address(debtCToken), 0, 0, 1_000_000e6
        );

        debtCToken.deposit(100_000e6, address(this));
        uint256 collateralShares =
            routeCToken.depositAsCollateral(collateralAmount, address(this));
        assertGt(
            collateralShares, 0, "route collateral deposit must mint shares"
        );

        vm.warp(
            recursiveMarket.accountAssets(address(this))
                + recursiveMarket.MIN_HOLD_PERIOD()
        );
        _refreshUsdcPriceFeed();

        uint256 cTokenShares =
            IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer));
        uint256 staleTotalAssets = optimizer.totalAssets();
        vm.mockCall(
            cUSDC_WMON_MARKET,
            abi.encodeWithSelector(
                IBorrowableCToken.convertToAssets.selector, cTokenShares
            ),
            abi.encode(staleTotalAssets / 2)
        );

        (, uint256 staleMaxDebtBeforeBorrow,) =
            recursiveMarket.statusOf(address(this));
        uint256 borrowAssets = FixedPointMathLib.mulDiv(
            staleMaxDebtBeforeBorrow, 9970 * 1e6, BPS * WAD
        );
        assertGt(borrowAssets, 10e6, "borrow should exceed minimum loan size");

        debtCToken.borrow(borrowAssets, address(this));
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "recursive route exact-liquidation setup must leave optimizer NAV stale"
        );

        uint256 exactRepayAssets = borrowAssets / 20;
        assertGt(exactRepayAssets, 1e6, "exact liquidation should be material");

        address[] memory accounts = new address[](1);
        accounts[0] = address(this);
        uint256[] memory debtAmounts = new uint256[](1);
        debtAmounts[0] = exactRepayAssets;

        address liquidator = makeAddr("recursiveRouteExactLiquidator");
        deal(USDC_MONAD, liquidator, 100_000e6);

        _assertRecursiveRouteExactLiquidationTransition(
            debtCToken,
            routeCToken,
            debtAmounts,
            accounts,
            exactRepayAssets,
            staleTotalAssets,
            liquidator
        );

        vm.clearMockedCalls();
    }

    function _assertRecursiveRouteExactLiquidationTransition(
        BorrowableCToken debtCToken,
        SimpleCToken routeCToken,
        uint256[] memory debtAmounts,
        address[] memory accounts,
        uint256 exactRepayAssets,
        uint256 staleTotalAssets,
        address liquidator
    ) internal {
        vm.startPrank(liquidator);
        IERC20(USDC_MONAD).approve(address(debtCToken), type(uint256).max);
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__NoLiquidationAvailable
            .selector
        );
        debtCToken.liquidateExact(debtAmounts, accounts, address(routeCToken));
        vm.stopPrank();
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "stale exact liquidation attempt must not sync recursive optimizer NAV"
        );

        optimizer.accrueIfNeeded();

        assertLt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "explicit optimizer accrual must reveal lower NAV"
        );

        uint256 debtBefore = debtCToken.debtBalance(address(this));
        uint256 liquidatorUsdcBefore = IERC20(USDC_MONAD).balanceOf(liquidator);
        uint256 liquidatorRouteSharesBefore = routeCToken.balanceOf(liquidator);

        vm.startPrank(liquidator);
        debtCToken.liquidateExact(debtAmounts, accounts, address(routeCToken));
        vm.stopPrank();

        assertEq(
            liquidatorUsdcBefore - IERC20(USDC_MONAD).balanceOf(liquidator),
            exactRepayAssets,
            "exact liquidation should collect requested debt"
        );
        assertGe(
            debtBefore - debtCToken.debtBalance(address(this)),
            exactRepayAssets,
            "fresh exact liquidation should reduce debt by at least requested amount"
        );
        assertGt(
            routeCToken.balanceOf(liquidator),
            liquidatorRouteSharesBefore,
            "liquidator should receive recursive-route collateral"
        );
    }

    function _assertRecursiveRouteDebtMarketAuthority(address debtAsset)
        internal
    {
        uint256 staleTotalAssets = _depositAndSkipForOptimizerYield();
        _refreshUsdcPriceFeed();
        _setOptimizerVaultFeedAnswer(1e8);

        CentralRegistry cr = CentralRegistry(address(liveCentralRegistry));
        MarketManagerIsolated recursiveMarket =
            new MarketManagerIsolated(liveCentralRegistry, 10e18, false);
        cr.addMarketManager(address(recursiveMarket));

        SimpleCToken collateralCToken = new SimpleCToken(
            liveCentralRegistry, IERC20(USDC_MONAD), address(recursiveMarket)
        );

        DynamicIRM debtIRM = _deployOptimizerCTokenIRM();
        BorrowableCToken debtCToken = new BorrowableCToken(
            liveCentralRegistry,
            IERC20(debtAsset),
            address(recursiveMarket),
            address(debtIRM)
        );
        debtIRM.setLinkedToken(address(debtCToken));

        _oracleManager.addCTokenSupport(address(collateralCToken));
        _oracleManager.addCTokenSupport(address(debtCToken));

        deal(USDC_MONAD, address(this), 100_000e6 + 77777);
        IERC20(USDC_MONAD)
            .approve(address(collateralCToken), type(uint256).max);
        IERC20(debtAsset).approve(address(debtCToken), type(uint256).max);

        recursiveMarket.listTokens(
            address(collateralCToken), address(debtCToken)
        );
        _configureToken(
            recursiveMarket, address(collateralCToken), 7000, 1_000_000e18, 0
        );
        _configureToken(
            recursiveMarket, address(debtCToken), 0, 0, 1_000_000e18
        );

        debtCToken.deposit(100_000e18, address(this));
        assertGt(
            collateralCToken.depositAsCollateral(50_000e6, address(this)),
            0,
            "USDC collateral deposit must mint shares"
        );

        vm.warp(
            recursiveMarket.accountAssets(address(this))
                + recursiveMarket.MIN_HOLD_PERIOD()
        );
        _refreshUsdcPriceFeed();
        _setOptimizerVaultFeedAnswer(1e8);

        (, uint256 staleMaxDebtBeforeBorrow,) =
            recursiveMarket.statusOf(address(this));
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "recursive debt route statusOf must not sync optimizer NAV before accrual"
        );
        uint256 borrowAssets = FixedPointMathLib.mulDiv(
            staleMaxDebtBeforeBorrow, 9999 * 1e18, BPS * WAD
        );
        assertGt(borrowAssets, 1e18, "debt-route borrow should be material");

        debtCToken.borrow(borrowAssets, address(this));

        (, uint256 staleMaxDebtAfterBorrow, uint256 staleDebtAfterBorrow) =
            recursiveMarket.statusOf(address(this));
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "recursive debt borrow/status path must still leave optimizer NAV stale"
        );
        assertGe(
            staleMaxDebtAfterBorrow,
            staleDebtAfterBorrow,
            "stale recursive debt route leaves account apparently healthy"
        );

        address[] memory accounts = new address[](1);
        accounts[0] = address(this);
        address liquidator = makeAddr("recursiveDebtRouteLiquidator");
        MockERC20(debtAsset).mint(liquidator, 100_000e18);

        vm.startPrank(liquidator);
        IERC20(debtAsset).approve(address(debtCToken), type(uint256).max);
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__NoLiquidationAvailable
            .selector
        );
        debtCToken.liquidate(accounts, address(collateralCToken));
        vm.stopPrank();
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "stale debt-route liquidation attempt must not sync optimizer NAV"
        );

        optimizer.accrueIfNeeded();

        (, uint256 freshMaxDebt, uint256 freshDebt) =
            recursiveMarket.statusOf(address(this));
        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "explicit optimizer accrual must reveal higher NAV"
        );
        assertGt(
            freshDebt,
            freshMaxDebt,
            "fresh recursive debt route reveals account over borrow limit"
        );

        vm.startPrank(liquidator);
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__NoLiquidationAvailable
            .selector
        );
        debtCToken.liquidate(accounts, address(collateralCToken));
        vm.stopPrank();

        assertEq(
            collateralCToken.balanceOf(liquidator),
            0,
            "borrow-limit breach alone should not imply DLE liquidation"
        );
    }

    function _assertOracleRouteInheritsStaleRawOptimizerSharePrice(address routeAsset)
        internal
    {
        _mintOptimizerShares(100_000e6);
        uint256 cTokenShares =
            IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer));
        uint256 staleTotalAssets = optimizer.totalAssets();
        vm.mockCall(
            cUSDC_WMON_MARKET,
            abi.encodeWithSelector(
                IBorrowableCToken.convertToAssets.selector, cTokenShares
            ),
            abi.encode(staleTotalAssets / 2)
        );

        (uint256 staleOptimizerPrice, uint256 staleOptimizerError) =
            _oracleManager.getPrice(address(optimizer), true, true);
        (uint256 staleRoutePrice, uint256 staleRouteError) =
            _oracleManager.getPrice(routeAsset, true, true);
        assertEq(staleOptimizerError, NO_ERROR);
        assertEq(staleRouteError, NO_ERROR);
        assertGt(staleRoutePrice, 0, "stale route quote must price");
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: route must not sync optimizer NAV"
        );

        optimizer.accrueIfNeeded();

        (uint256 freshOptimizerPrice, uint256 freshOptimizerError) =
            _oracleManager.getPrice(address(optimizer), true, true);
        (uint256 freshRoutePrice, uint256 freshRouteError) =
            _oracleManager.getPrice(routeAsset, true, true);
        assertEq(freshOptimizerError, NO_ERROR);
        assertEq(freshRouteError, NO_ERROR);
        assertLt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "fresh accrual must reveal lower optimizer NAV"
        );
        assertLt(
            freshOptimizerPrice,
            staleOptimizerPrice,
            "optimizer price should fall after fresh accrual"
        );
        assertLt(
            freshRoutePrice,
            staleRoutePrice,
            "route inherits stale optimizer-share raw price"
        );

        vm.clearMockedCalls();
    }

    function _deployPendleOptimizerShareQuoteMarket()
        internal
        returns (
            MockPendleMarket market,
            MockERC20 pt,
            MockPendlePTOracle ptOracle
        )
    {
        MockPendleSY sy = new MockPendleSY(address(optimizer), 6);
        pt = new MockERC20("Mock Pendle PT", "mPT", 18);
        MockPendleYT yt = new MockPendleYT();
        market = new MockPendleMarket(
            IStandardizedYield(address(sy)),
            IPPrincipalToken(address(pt)),
            IPYieldToken(address(yt))
        );
        market.setExpiredState(0, 100_000e18, 100_000e18);
        ptOracle = new MockPendlePTOracle();
    }

    function _depositAndSkipForOptimizerYield()
        internal
        returns (uint256 assetsBefore)
    {
        return _depositAndSkipForOptimizerYield(address(this));
    }

    function _depositAndSkipForOptimizerYield(address receiver)
        internal
        returns (uint256 assetsBefore)
    {
        uint256 depositAmount = 100_000e6;
        deal(USDC_MONAD, address(this), depositAmount);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
        LendingOptimizerHarness(address(optimizer))
            .depositToMarket(depositAmount, receiver, cUSDC_WMON_MARKET);

        assetsBefore = optimizer.totalAssets();
        skip(30 days);
    }

    function _depositIntoWrapperAndSkipForOptimizerYield()
        internal
        returns (uint256 assetsBefore)
    {
        return _depositIntoWrapperAndSkipForOptimizerYield(address(this));
    }

    function _depositIntoWrapperAndSkipForOptimizerYield(address receiver)
        internal
        returns (uint256 assetsBefore)
    {
        uint256 depositAmount = 100_000e6;
        deal(USDC_MONAD, address(this), depositAmount);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
        LendingOptimizerHarness(address(optimizer))
            .depositToMarket(depositAmount, address(this), cUSDC_WMON_MARKET);

        uint256 optimizerShares = optimizer.balanceOf(address(this));
        IERC20(address(optimizer))
            .approve(address(optimizerCToken), optimizerShares);
        _mockCanMint();
        optimizerCToken.deposit(optimizerShares, receiver);

        assetsBefore = optimizer.totalAssets();
        skip(30 days);
    }

    function _depositWrapperCollateral() internal {
        _depositIntoWrapperAndSkipForOptimizerYield();
        uint256 shares = optimizerCToken.balanceOf(address(this));

        _mockCanCollateralize(address(this), shares);
        optimizerCToken.postCollateral(shares);
        vm.clearMockedCalls();
    }

    function _depositWrapperCollateralAndSkipForOptimizerYield()
        internal
        returns (uint256 assetsBefore)
    {
        _depositIntoWrapperAndSkipForOptimizerYield();
        uint256 shares = optimizerCToken.balanceOf(address(this));

        _mockCanCollateralize(address(this), shares);
        optimizerCToken.postCollateral(shares);
        vm.clearMockedCalls();

        assetsBefore = optimizer.totalAssets();
        skip(30 days);
    }

    function _feeTokenRequiredForOTC(
        address tokenToOTC,
        uint256 amountToOTC,
        uint256 tokenPrice,
        uint256 feeTokenPrice
    ) internal view returns (uint256) {
        return ((tokenPrice
                    * amountToOTC
                    * 10
                    ** IERC20(USDC_MONAD).decimals())
                / feeTokenPrice) / 10 ** IERC20(tokenToOTC).decimals();
    }

    function _deployOptimizerCTokenIRM() internal returns (DynamicIRM) {
        return new DynamicIRM(
            liveCentralRegistry, 1200, 2000, 8500, 500, 200, 100000
        );
    }

    function _initializeOptimizerCToken() internal {
        _mintOptimizerShares(100_000e6);

        IERC20(address(optimizer)).approve(address(optimizerCToken), 77777);
        vm.prank(_marketMgrs[cUSDC_WMON_MARKET]);
        optimizerCToken.initializeDeposits(address(this));
    }

    function _deployPlainBorrowableOptimizerDebtMarket()
        internal
        returns (
            MarketManagerIsolated optimizerDebtMarket,
            BorrowableCToken optimizerDebtCToken,
            MockERC20 collateral,
            SimpleCToken collateralCToken
        )
    {
        CentralRegistry cr = CentralRegistry(address(liveCentralRegistry));
        optimizerDebtMarket =
            new MarketManagerIsolated(liveCentralRegistry, 10e18, false);
        cr.addMarketManager(address(optimizerDebtMarket));

        DynamicIRM optimizerDebtIRM = _deployOptimizerCTokenIRM();
        optimizerDebtCToken = new BorrowableCToken(
            liveCentralRegistry,
            IERC20(address(optimizer)),
            address(optimizerDebtMarket),
            address(optimizerDebtIRM)
        );
        optimizerDebtIRM.setLinkedToken(address(optimizerDebtCToken));

        collateral = new MockERC20("Plain Debt Collateral", "PDC", 18);
        _registerPriceFeed(address(collateral), 1e8);
        collateralCToken = new SimpleCToken(
            liveCentralRegistry,
            IERC20(address(collateral)),
            address(optimizerDebtMarket)
        );

        _registerOptimizerShareVaultPriceFeed();
        _oracleManager.addCTokenSupport(address(optimizerDebtCToken));
        _oracleManager.addCTokenSupport(address(collateralCToken));

        _mintOptimizerShares(2_000_000e6);
        IERC20(address(optimizer))
            .approve(address(optimizerDebtCToken), type(uint256).max);
        collateral.mint(address(this), 77777);
        IERC20(address(collateral)).approve(address(collateralCToken), 77777);
        optimizerDebtMarket.listTokens(
            address(collateralCToken), address(optimizerDebtCToken)
        );

        _configureToken(
            optimizerDebtMarket,
            address(collateralCToken),
            7000,
            10_000_000e18,
            0
        );
        _configureToken(
            optimizerDebtMarket,
            address(optimizerDebtCToken),
            0,
            0,
            2_000_000e6
        );
    }

    function _deployPlainOptimizerShareCollateralMarket()
        internal
        returns (
            MarketManagerIsolated optimizerCollateralMarket,
            BorrowableCToken debtCToken,
            SimpleCToken optimizerCollateralCToken
        )
    {
        CentralRegistry cr = CentralRegistry(address(liveCentralRegistry));
        optimizerCollateralMarket =
            new MarketManagerIsolated(liveCentralRegistry, 10e18, false);
        cr.addMarketManager(address(optimizerCollateralMarket));

        DynamicIRM debtIRM = _deployOptimizerCTokenIRM();
        debtCToken = new BorrowableCToken(
            liveCentralRegistry,
            IERC20(USDC_MONAD),
            address(optimizerCollateralMarket),
            address(debtIRM)
        );
        debtIRM.setLinkedToken(address(debtCToken));

        optimizerCollateralCToken = new SimpleCToken(
            liveCentralRegistry,
            IERC20(address(optimizer)),
            address(optimizerCollateralMarket)
        );

        _registerOptimizerShareVaultPriceFeed();
        _oracleManager.addCTokenSupport(address(debtCToken));
        _oracleManager.addCTokenSupport(address(optimizerCollateralCToken));

        _mintOptimizerShares(100_000e6);
        IERC20(address(optimizer))
            .approve(address(optimizerCollateralCToken), 77777);
        deal(USDC_MONAD, address(this), 77777);
        IERC20(USDC_MONAD).approve(address(debtCToken), 77777);
        optimizerCollateralMarket.listTokens(
            address(optimizerCollateralCToken), address(debtCToken)
        );

        _configureToken(
            optimizerCollateralMarket,
            address(optimizerCollateralCToken),
            7000,
            1_000_000e6,
            0
        );
        _configureToken(
            optimizerCollateralMarket, address(debtCToken), 0, 0, 1_000_000e6
        );
    }

    function _deployPlainWrapperShareCollateralMarket()
        internal
        returns (
            MarketManagerIsolated wrapperCollateralMarket,
            BorrowableCToken debtCToken,
            SimpleCToken wrapperCollateralCToken
        )
    {
        CentralRegistry cr = CentralRegistry(address(liveCentralRegistry));
        wrapperCollateralMarket =
            new MarketManagerIsolated(liveCentralRegistry, 10e18, false);
        cr.addMarketManager(address(wrapperCollateralMarket));

        DynamicIRM debtIRM = _deployOptimizerCTokenIRM();
        debtCToken = new BorrowableCToken(
            liveCentralRegistry,
            IERC20(USDC_MONAD),
            address(wrapperCollateralMarket),
            address(debtIRM)
        );
        debtIRM.setLinkedToken(address(debtCToken));

        wrapperCollateralCToken = new SimpleCToken(
            liveCentralRegistry,
            IERC20(address(optimizerCToken)),
            address(wrapperCollateralMarket)
        );

        _registerOptimizerShareVaultPriceFeed();
        _registerOptimizerShareCTokenVaultPriceFeed();
        _oracleManager.addCTokenSupport(address(debtCToken));
        _oracleManager.addCTokenSupport(address(wrapperCollateralCToken));

        _mintOptimizerShares(100_000e6);
        uint256 optimizerShares = optimizer.balanceOf(address(this));
        IERC20(address(optimizer))
            .approve(address(optimizerCToken), optimizerShares);
        _mockCanMint();
        optimizerCToken.deposit(optimizerShares, address(this));
        vm.clearMockedCalls();

        _mockCanTransfer(address(this), address(wrapperCollateralCToken), 77777);
        IERC20(address(optimizerCToken))
            .approve(address(wrapperCollateralCToken), 77777);
        deal(USDC_MONAD, address(this), 77777);
        IERC20(USDC_MONAD).approve(address(debtCToken), 77777);
        wrapperCollateralMarket.listTokens(
            address(wrapperCollateralCToken), address(debtCToken)
        );
        vm.clearMockedCalls();

        _configureToken(
            wrapperCollateralMarket,
            address(wrapperCollateralCToken),
            7000,
            1_000_000e6,
            0
        );
        _configureToken(
            wrapperCollateralMarket, address(debtCToken), 0, 0, 1_000_000e6
        );
    }

    function _deployPlainBorrowableWrapperDebtMarket()
        internal
        returns (
            MarketManagerIsolated wrapperDebtMarket,
            BorrowableCToken wrapperDebtCToken,
            MockERC20 collateral,
            SimpleCToken collateralCToken
        )
    {
        CentralRegistry cr = CentralRegistry(address(liveCentralRegistry));
        wrapperDebtMarket =
            new MarketManagerIsolated(liveCentralRegistry, 10e18, false);
        cr.addMarketManager(address(wrapperDebtMarket));

        DynamicIRM wrapperDebtIRM = _deployOptimizerCTokenIRM();
        wrapperDebtCToken = new BorrowableCToken(
            liveCentralRegistry,
            IERC20(address(optimizerCToken)),
            address(wrapperDebtMarket),
            address(wrapperDebtIRM)
        );
        wrapperDebtIRM.setLinkedToken(address(wrapperDebtCToken));

        collateral = new MockERC20("Plain Wrapper Debt Collateral", "PWDC", 18);
        _registerPriceFeed(address(collateral), 1e8);
        collateralCToken = new SimpleCToken(
            liveCentralRegistry,
            IERC20(address(collateral)),
            address(wrapperDebtMarket)
        );

        _registerOptimizerShareVaultPriceFeed();
        _registerOptimizerShareCTokenVaultPriceFeed();
        _oracleManager.addCTokenSupport(address(wrapperDebtCToken));
        _oracleManager.addCTokenSupport(address(collateralCToken));

        _mintOptimizerShares(2_000_000e6);
        uint256 optimizerShares = optimizer.balanceOf(address(this));
        IERC20(address(optimizer))
            .approve(address(optimizerCToken), optimizerShares);
        _mockCanMint();
        optimizerCToken.deposit(optimizerShares, address(this));
        vm.clearMockedCalls();

        _mockCanTransfer(address(this), address(wrapperDebtCToken), 77777);
        IERC20(address(optimizerCToken))
            .approve(address(wrapperDebtCToken), type(uint256).max);
        collateral.mint(address(this), 77777);
        IERC20(address(collateral)).approve(address(collateralCToken), 77777);
        wrapperDebtMarket.listTokens(
            address(collateralCToken), address(wrapperDebtCToken)
        );
        vm.clearMockedCalls();

        _configureToken(
            wrapperDebtMarket,
            address(collateralCToken),
            7000,
            10_000_000e18,
            0
        );
        _configureToken(
            wrapperDebtMarket, address(wrapperDebtCToken), 0, 0, 2_000_000e6
        );
    }

    function _mockWrapperDebtLiquidationRepayTransfer(
        MarketManagerIsolated wrapperDebtMarket,
        BorrowableCToken wrapperDebtCToken,
        SimpleCToken collateralCToken,
        address liquidator,
        address[] memory accounts
    ) internal {
        IMarketManager.LiqAction memory action = IMarketManager.LiqAction({
            collateralToken: address(collateralCToken),
            debtToken: address(wrapperDebtCToken),
            numAccounts: accounts.length,
            liquidateExact: false,
            liquidatedShares: 0,
            debtRepaid: 0,
            badDebt: 0
        });
        uint256[] memory debtAmounts = new uint256[](accounts.length);
        vm.prank(address(wrapperDebtCToken));
        (IMarketManager.LiqResult memory liqResult,) =
            wrapperDebtMarket.canLiquidate(
                debtAmounts, liquidator, accounts, action
            );
        _mockCanTransfer(
            liquidator, address(wrapperDebtCToken), liqResult.debtRepaid
        );
    }

    function _deployOptimizerShareLaunchMarket()
        internal
        returns (
            MarketManagerIsolated optimizerMarket,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        )
    {
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
            ILendingOptimizer(address(optimizer)),
            address(optimizerMarket),
            address(shareIRM)
        );
        shareIRM.setLinkedToken(address(shareCToken));

        _registerOptimizerShareVaultPriceFeed();
        _chainlinkAdaptor.setGuardedPriceConfig(
            address(optimizer), true, 0, 0, WAD, 0
        );
        _oracleManager.addCTokenSupport(address(debtCToken));
        _oracleManager.addCTokenSupport(address(shareCToken));

        _mintOptimizerShares(100_000e6);
        IERC20(address(optimizer)).approve(address(shareCToken), 77777);
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

    function _deployOptimizerShareLaunchMarketWithMockDebtAsset()
        internal
        returns (
            MarketManagerIsolated optimizerMarket,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken,
            MockERC20 debtAsset
        )
    {
        CentralRegistry cr = CentralRegistry(address(liveCentralRegistry));
        optimizerMarket =
            new MarketManagerIsolated(liveCentralRegistry, 10e18, false);
        cr.addMarketManager(address(optimizerMarket));

        debtAsset = new MockERC20("Mock Deleverage Debt", "mDD", 6);
        _registerPriceFeed(address(debtAsset), 1e8);

        DynamicIRM debtIRM = _deployOptimizerCTokenIRM();
        debtCToken = new BorrowableCToken(
            liveCentralRegistry,
            IERC20(address(debtAsset)),
            address(optimizerMarket),
            address(debtIRM)
        );
        debtIRM.setLinkedToken(address(debtCToken));

        DynamicIRM shareIRM = _deployOptimizerCTokenIRM();
        shareCToken = new LendingOptimizerShareCToken(
            liveCentralRegistry,
            ILendingOptimizer(address(optimizer)),
            address(optimizerMarket),
            address(shareIRM)
        );
        shareIRM.setLinkedToken(address(shareCToken));

        _registerOptimizerShareVaultPriceFeed();
        _chainlinkAdaptor.setGuardedPriceConfig(
            address(optimizer), true, 0, 0, WAD, 0
        );
        _oracleManager.addCTokenSupport(address(debtCToken));
        _oracleManager.addCTokenSupport(address(shareCToken));

        _mintOptimizerShares(100_000e6);
        IERC20(address(optimizer)).approve(address(shareCToken), 77777);
        debtAsset.mint(address(this), 77777);
        IERC20(address(debtAsset)).approve(address(debtCToken), 77777);
        optimizerMarket.listTokens(address(shareCToken), address(debtCToken));

        _configureToken(
            optimizerMarket, address(shareCToken), 7000, 1_000_000e6, 0
        );
        _configureToken(
            optimizerMarket, address(debtCToken), 0, 0, 1_000_000e6
        );
    }

    function _setupUnderEncodedDualSidedVaultFixture()
        internal
        returns (UnderEncodedDualSidedVaultFixture memory fixture)
    {
        (
            fixture.optimizerMarket,
            fixture.debtCToken,
            fixture.shareCToken,
            fixture.debtAsset
        ) = _deployOptimizerShareLaunchMarketWithMockDebtAsset();
        fixture.positionManager =
            _deployDualSidedOptimizerShareVaultPositionManager(
                fixture.optimizerMarket
            );
        fixture.swapTarget = new OptimizerShareSwapTarget(
            IERC20(USDC_MONAD), IERC20(address(fixture.debtAsset))
        );
        CentralRegistry(address(liveCentralRegistry))
            .setExternalCalldataChecker(
                address(fixture.swapTarget),
                address(new MockCalldataChecker(address(fixture.swapTarget)))
            );

        uint256 lendAssets = 100_000e6;
        fixture.debtAsset.mint(address(this), lendAssets);
        IERC20(address(fixture.debtAsset))
            .approve(address(fixture.debtCToken), lendAssets);
        fixture.debtCToken.deposit(lendAssets, address(this));

        fixture.account =
            makeAddr("optimizerShareDualSidedVaultUnderEncodedAccount");
        uint256 optimizerShares = optimizer.balanceOf(address(this));
        IERC20(address(optimizer))
            .approve(address(fixture.shareCToken), optimizerShares);
        uint256 wrapperShares =
            fixture.shareCToken.deposit(optimizerShares, fixture.account);
        vm.startPrank(fixture.account);
        fixture.shareCToken.postCollateral(wrapperShares);
        fixture.debtCToken.borrow(20_000e6, fixture.account);
        vm.stopPrank();

        fixture.collateralBefore =
            fixture.shareCToken.collateralPosted(fixture.account);
        fixture.staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        _refreshUsdcPriceFeed();
        MockV3Aggregator debtFeed = new MockV3Aggregator(8, 1e8);
        _chainlinkAdaptor.addAsset(
            address(fixture.debtAsset), true, address(debtFeed), 0
        );
        _setOptimizerVaultFeedAnswer(1e8);
        fixture.debtBefore =
            fixture.debtCToken.debtBalanceUpdated(fixture.account);
        assertEq(
            optimizer.totalAssets(),
            fixture.staleTotalAssets,
            "precondition: optimizer NAV is stale before under-encoded dual-sided deleverage"
        );
    }

    function _underEncodedDualSidedVaultDeleverageAction(
        UnderEncodedDualSidedVaultFixture memory fixture,
        uint256 collateralAssets,
        uint256 swapInputAssets
    ) internal view returns (IPositionManager.DeleverageAction memory action) {
        action.cToken = ICToken(address(fixture.shareCToken));
        action.collateralAssets = collateralAssets;
        action.borrowableCToken =
            IBorrowableCToken(address(fixture.debtCToken));
        action.repayAssets = swapInputAssets;
        action.swapActions = new SwapperLib.Swap[](1);
        action.swapActions[0] = SwapperLib.Swap({
            inputToken: USDC_MONAD,
            inputAmount: swapInputAssets,
            outputToken: address(fixture.debtAsset),
            target: address(fixture.swapTarget),
            slippage: WAD - 1,
            call: abi.encodeWithSelector(
                OptimizerShareSwapTarget.swap.selector,
                swapInputAssets,
                swapInputAssets
            )
        });
    }

    function _postOptimizerShareCollateral(
        LendingOptimizerShareCToken shareCToken,
        address account,
        uint256 assets
    ) internal {
        uint256 sharesBefore = optimizer.balanceOf(address(this));
        _mintOptimizerShares(assets);
        uint256 optimizerShares =
            optimizer.balanceOf(address(this)) - sharesBefore;
        IERC20(address(optimizer))
            .approve(address(shareCToken), optimizerShares);
        uint256 wrapperShares = shareCToken.deposit(optimizerShares, account);
        vm.prank(account);
        shareCToken.postCollateral(wrapperShares);
    }

    function _deployOptimizerSharePositionManager(MarketManagerIsolated optimizerMarket)
        internal
        returns (OptimizerSharePositionManagerHarness positionManager)
    {
        positionManager =
            new OptimizerSharePositionManagerHarness(
                liveCentralRegistry,
                address(optimizerMarket),
                address(0),
                makeAddr("optimizerSharePmSwapSink")
            );
        optimizerMarket.addPositionManager(address(positionManager));
    }

    function _deploySimpleOptimizerSharePositionManager(MarketManagerIsolated optimizerMarket)
        internal
        returns (SimplePositionManager positionManager)
    {
        positionManager = new SimplePositionManager(
            liveCentralRegistry, address(optimizerMarket), address(0)
        );
        optimizerMarket.addPositionManager(address(positionManager));
    }

    function _deploySingleSidedOptimizerShareVaultPositionManager(MarketManagerIsolated optimizerMarket)
        internal
        returns (SingleSidedVaultPositionManager positionManager)
    {
        positionManager = new SingleSidedVaultPositionManager(
            liveCentralRegistry, address(optimizerMarket), address(0)
        );
        optimizerMarket.addPositionManager(address(positionManager));
    }

    function _deployDualSidedOptimizerShareVaultPositionManager(MarketManagerIsolated optimizerMarket)
        internal
        returns (DualSidedVaultPositionManager positionManager)
    {
        positionManager = new DualSidedVaultPositionManager(
            liveCentralRegistry, address(optimizerMarket), address(0)
        );
        optimizerMarket.addPositionManager(address(positionManager));
    }

    function _registerOptimizerShareVaultPriceFeed() internal {
        MockV3Aggregator usdcFeed = new MockV3Aggregator(8, 1e8);
        VaultAggregator optimizerVaultFeed = new VaultAggregator(
            address(optimizer), USDC_MONAD, address(usdcFeed), "optimizer/USD"
        );

        _chainlinkAdaptor.addAsset(
            address(optimizer), true, address(optimizerVaultFeed), 0
        );
        _oracleManager.addAssetPricingAdaptor(
            address(optimizer), address(_chainlinkAdaptor), 0, 0, 0, 0
        );
    }

    function _registerOptimizerShareCTokenVaultPriceFeed() internal {
        (bool feedConfigured, IChainlink feed,,) =
            _chainlinkAdaptor.assetConfig(address(optimizer), true);
        assertTrue(feedConfigured, "optimizer share feed must be configured");

        VaultAggregator shareCTokenFeed = new VaultAggregator(
            address(optimizerCToken),
            address(optimizer),
            address(feed),
            "optimizer-cToken/USD"
        );

        _chainlinkAdaptor.addAsset(
            address(optimizerCToken), true, address(shareCTokenFeed), 0
        );
        _oracleManager.addAssetPricingAdaptor(
            address(optimizerCToken), address(_chainlinkAdaptor), 0, 0, 0, 0
        );
    }

    function _setOptimizerVaultFeedAnswer(int256 answer) internal {
        MockV3Aggregator usdcFeed = new MockV3Aggregator(8, answer);
        VaultAggregator optimizerVaultFeed = new VaultAggregator(
            address(optimizer), USDC_MONAD, address(usdcFeed), "optimizer/USD"
        );

        _chainlinkAdaptor.addAsset(
            address(optimizer), true, address(optimizerVaultFeed), 0
        );
    }

    function _refreshOptimizerShareNestedVaultFeeds() internal {
        _setOptimizerVaultFeedAnswer(1e8);

        (bool feedConfigured, IChainlink feed,,) =
            _chainlinkAdaptor.assetConfig(address(optimizer), true);
        assertTrue(feedConfigured, "optimizer share feed must be configured");

        VaultAggregator shareCTokenFeed = new VaultAggregator(
            address(optimizerCToken),
            address(optimizer),
            address(feed),
            "optimizer-cToken/USD"
        );

        _chainlinkAdaptor.addAsset(
            address(optimizerCToken), true, address(shareCTokenFeed), 0
        );
    }

    function _refreshUsdcPriceFeed() internal {
        MockV3Aggregator usdcFeed = new MockV3Aggregator(8, 1e8);
        _chainlinkAdaptor.addAsset(USDC_MONAD, true, address(usdcFeed), 0);
    }

    function _setUsdcDualFeedAnswer(int256 answer, uint256 expectedErrorCode)
        internal
    {
        ChainlinkAdaptor secondAdaptor =
            new ChainlinkAdaptor(liveCentralRegistry);
        _oracleManager.addApprovedAdaptor(address(secondAdaptor));

        MockV3Aggregator usdcFeed = new MockV3Aggregator(8, answer);
        secondAdaptor.addAsset(USDC_MONAD, true, address(usdcFeed), 0);
        _oracleManager.addAssetPricingAdaptor(
            USDC_MONAD, address(secondAdaptor), 180, 130, 180, 130
        );

        (, uint256 errorCode) =
            _oracleManager.getPrice(USDC_MONAD, true, false);
        assertEq(errorCode, expectedErrorCode, "unexpected USDC oracle status");
    }

    function _mintOptimizerShares(uint256 assets) internal {
        deal(USDC_MONAD, address(this), assets);
        IERC20(USDC_MONAD).approve(address(optimizer), assets);
        optimizer.deposit(assets, address(this));
    }

    function _mockOptimizerApprovedMarketAssets(uint256 targetTotalAssets)
        internal
    {
        address[] memory approvedMarkets = optimizer.getApprovedMarkets();
        uint256 nonZeroMarkets;
        for (uint256 i; i < approvedMarkets.length; ++i) {
            if (
                IBorrowableCToken(approvedMarkets[i])
                    .balanceOf(address(optimizer)) > 0
            ) {
                ++nonZeroMarkets;
            }
        }
        assertGt(nonZeroMarkets, 0, "optimizer must have active markets");

        uint256 freshPerMarketAssets =
            FixedPointMathLib.fullMulDiv(targetTotalAssets, 1, nonZeroMarkets);
        for (uint256 i; i < approvedMarkets.length; ++i) {
            uint256 cTokenShares = IBorrowableCToken(approvedMarkets[i])
                .balanceOf(address(optimizer));
            if (cTokenShares == 0) {
                continue;
            }

            vm.mockCall(
                approvedMarkets[i],
                abi.encodeWithSelector(
                    IBorrowableCToken.convertToAssets.selector, cTokenShares
                ),
                abi.encode(freshPerMarketAssets)
            );
        }
    }

    function _quoteOptimizerVaultZapperShares(
        address user,
        LendingOptimizerShareCToken shareCToken,
        uint256 inputAssets
    ) internal returns (uint256 optimizerShares, uint256 wrapperShares) {
        uint256 snapshotId = vm.snapshotState();

        vm.startPrank(user);
        IERC20(USDC_MONAD).approve(address(optimizer), inputAssets);
        optimizerShares = optimizer.deposit(inputAssets, user);
        vm.stopPrank();

        wrapperShares = shareCToken.previewDeposit(optimizerShares);
        assertTrue(
            vm.revertToState(snapshotId),
            "failed to restore optimizer vault zapper quote state"
        );
        assertGt(
            optimizerShares, 0, "optimizer vault deposit must mint shares"
        );
        assertGt(wrapperShares, 0, "wrapper deposit must mint cToken shares");
    }

    function _quoteOptimizerWrapperSharesFromVaultDeposit(
        address depositor,
        LendingOptimizerShareCToken shareCToken,
        uint256 inputAssets
    ) internal returns (uint256 optimizerShares, uint256 wrapperShares) {
        uint256 snapshotId = vm.snapshotState();

        deal(USDC_MONAD, depositor, inputAssets);
        vm.startPrank(depositor);
        IERC20(USDC_MONAD).approve(address(optimizer), inputAssets);
        optimizerShares = optimizer.deposit(inputAssets, depositor);
        vm.stopPrank();

        wrapperShares = shareCToken.previewDeposit(optimizerShares);
        assertTrue(
            vm.revertToState(snapshotId),
            "failed to restore optimizer vault PM quote state"
        );
        assertGt(
            optimizerShares, 0, "optimizer vault PM deposit must mint shares"
        );
        assertGt(wrapperShares, 0, "wrapper deposit must mint cToken shares");
    }

    function _quoteDepositAndLeverageWrapperShares(
        address account,
        address positionManager,
        LendingOptimizerShareCToken shareCToken,
        uint256 preDepositOptimizerShares,
        uint256 borrowAssets
    )
        internal
        returns (uint256 preDepositWrapperShares, uint256 borrowWrapperShares)
    {
        uint256 snapshotId = vm.snapshotState();

        vm.startPrank(account);
        IERC20(address(optimizer))
            .approve(address(shareCToken), preDepositOptimizerShares);
        preDepositWrapperShares = shareCToken.depositAsCollateral(
            preDepositOptimizerShares, account
        );
        vm.stopPrank();

        deal(USDC_MONAD, positionManager, borrowAssets);
        vm.startPrank(positionManager);
        IERC20(USDC_MONAD).approve(address(optimizer), borrowAssets);
        uint256 optimizerShares =
            optimizer.deposit(borrowAssets, positionManager);
        IERC20(address(optimizer))
            .approve(address(shareCToken), optimizerShares);
        borrowWrapperShares =
            shareCToken.depositAsCollateral(optimizerShares, account);
        vm.stopPrank();

        assertTrue(
            vm.revertToState(snapshotId),
            "failed to restore optimizer depositAndLeverage quote state"
        );
        assertGt(
            preDepositWrapperShares, 0, "predeposit must mint wrapper shares"
        );
        assertGt(
            borrowWrapperShares,
            0,
            "borrowed optimizer deposit must mint wrapper shares"
        );
    }

    function _runOptimizerVaultZapperDeposit(
        VaultZapper vaultZapper,
        LendingOptimizerShareCToken shareCToken,
        address user,
        uint256 inputAssets,
        uint256 expectedWrapperShares
    ) internal returns (uint256 wrapperShares) {
        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = USDC_MONAD;
        swapAction.inputAmount = inputAssets;
        swapAction.outputToken = USDC_MONAD;

        vm.startPrank(user);
        IERC20(USDC_MONAD).approve(address(vaultZapper), inputAssets);
        shareCToken.setDelegateApproval(address(vaultZapper), true);
        wrapperShares = vaultZapper.swapAndDeposit(
            address(shareCToken),
            false,
            swapAction,
            expectedWrapperShares,
            true,
            user
        );
        vm.stopPrank();
    }

    function _expectOptimizerVaultZapperDepositRevert(
        VaultZapper vaultZapper,
        LendingOptimizerShareCToken shareCToken,
        address user,
        uint256 inputAssets,
        uint256 expectedWrapperShares
    ) internal {
        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = USDC_MONAD;
        swapAction.inputAmount = inputAssets;
        swapAction.outputToken = USDC_MONAD;

        vm.startPrank(user);
        IERC20(USDC_MONAD).approve(address(vaultZapper), inputAssets);
        shareCToken.setDelegateApproval(address(vaultZapper), true);
        vm.expectRevert(BaseZapper.BaseZapper__ExecutionError.selector);
        vaultZapper.swapAndDeposit(
            address(shareCToken),
            false,
            swapAction,
            expectedWrapperShares,
            true,
            user
        );
        vm.stopPrank();
    }

    function _mockCanMint() internal {
        vm.mockCall(
            _marketMgrs[cUSDC_WMON_MARKET],
            abi.encodeWithSignature(
                "canMint(address)", address(optimizerCToken)
            ),
            hex""
        );
    }

    function _mockCanTransfer(address owner, address receiver, uint256 shares)
        internal
    {
        _mockCanTransfer(owner, receiver, shares, 0);
    }

    function _mockCanTransfer(
        address owner,
        address receiver,
        uint256 shares,
        uint256 collateralRedeemed
    ) internal {
        vm.mockCall(
            _marketMgrs[cUSDC_WMON_MARKET],
            abi.encodeWithSignature(
                "canTransfer(address,uint256,address,uint256,uint256,bool)",
                address(optimizerCToken),
                shares,
                owner,
                optimizerCToken.balanceOf(owner),
                optimizerCToken.collateralPosted(owner),
                optimizerCToken.collateralPosted(owner) > 0 ? true : false
            ),
            abi.encode(collateralRedeemed)
        );
    }

    function _mockCanCollateralize(address owner, uint256 newNetCollateral)
        internal
    {
        vm.mockCall(
            _marketMgrs[cUSDC_WMON_MARKET],
            abi.encodeWithSignature(
                "canCollateralize(address,address,uint256)",
                address(optimizerCToken),
                owner,
                newNetCollateral
            ),
            hex""
        );
    }

    function _mockCanRedeem(
        address owner,
        uint256 shares,
        bool forceRedeemCollateral,
        uint256 collateralRedeemed
    ) internal {
        vm.mockCall(
            _marketMgrs[cUSDC_WMON_MARKET],
            abi.encodeWithSignature(
                "canRedeemWithCollateralRemoval(address,uint256,address,uint256,uint256,bool)",
                address(optimizerCToken),
                shares,
                owner,
                optimizerCToken.balanceOf(owner),
                optimizerCToken.collateralPosted(owner),
                forceRedeemCollateral
            ),
            abi.encode(collateralRedeemed)
        );
    }

    function _singleFakeMarket()
        internal
        pure
        returns (address[] memory markets)
    {
        markets = new address[](1);
        markets[0] = address(1);
    }

    function _optimizerShareLaunchConfig(
        MarketManagerIsolated optimizerMarket,
        LendingOptimizerShareCToken shareCToken
    ) internal view returns (VerifyOptimizerShareLaunch.Config memory config) {
        (
            bool feedConfigured,
            IChainlink feed,
            uint8 feedDecimals,
            uint24 heartbeat
        ) = _chainlinkAdaptor.assetConfig(address(optimizer), true);
        assertTrue(feedConfigured, "optimizer share feed must be configured");
        VaultAggregator optimizerVaultFeed = VaultAggregator(address(feed));

        config = VerifyOptimizerShareLaunch.Config({
            optimizer: address(optimizer),
            shareCToken: address(shareCToken),
            marketManager: address(optimizerMarket),
            oracleManager: address(_oracleManager),
            oracleAdaptor: address(_chainlinkAdaptor),
            vaultAggregator: address(feed),
            expectedUnderlyingAggregator: address(
                optimizerVaultFeed.underlyingAggregator()
            ),
            expectedUnderlying: USDC_MONAD,
            expectedDataFeedId: optimizerVaultFeed.getDataFeedId(),
            expectedCollateralCap: 1_000_000e6,
            expectedFeedDecimals: feedDecimals,
            expectedHeartbeat: heartbeat,
            expectedGuardTimestampStart: 0,
            expectedGuardIps: 0,
            expectedGuardBasePrice: uint88(WAD),
            expectedGuardMinPrice: 0
        });
    }

    function _setOptimizerShareLaunchEnv(
        VerifyOptimizerShareLaunch.Config memory config
    ) internal {
        vm.setEnv("OPTIMIZER_ADDRESS", vm.toString(config.optimizer));
        vm.setEnv("OPTIMIZER_SHARE_CTOKEN", vm.toString(config.shareCToken));
        vm.setEnv(
            "OPTIMIZER_MARKET_MANAGER", vm.toString(config.marketManager)
        );
        vm.setEnv(
            "OPTIMIZER_ORACLE_MANAGER", vm.toString(config.oracleManager)
        );
        vm.setEnv(
            "OPTIMIZER_ORACLE_ADAPTOR", vm.toString(config.oracleAdaptor)
        );
        vm.setEnv(
            "OPTIMIZER_VAULT_AGGREGATOR", vm.toString(config.vaultAggregator)
        );
        vm.setEnv(
            "OPTIMIZER_UNDERLYING_AGGREGATOR",
            vm.toString(config.expectedUnderlyingAggregator)
        );
        vm.setEnv(
            "OPTIMIZER_UNDERLYING", vm.toString(config.expectedUnderlying)
        );
        vm.setEnv(
            "OPTIMIZER_DATA_FEED_ID", vm.toString(config.expectedDataFeedId)
        );
        vm.setEnv(
            "OPTIMIZER_SHARE_COLLATERAL_CAP",
            vm.toString(config.expectedCollateralCap)
        );
        vm.setEnv(
            "OPTIMIZER_FEED_DECIMALS",
            vm.toString(uint256(config.expectedFeedDecimals))
        );
        vm.setEnv(
            "OPTIMIZER_FEED_HEARTBEAT",
            vm.toString(uint256(config.expectedHeartbeat))
        );
        vm.setEnv(
            "OPTIMIZER_GUARD_TIMESTAMP_START",
            vm.toString(uint256(config.expectedGuardTimestampStart))
        );
        vm.setEnv(
            "OPTIMIZER_GUARD_IPS",
            vm.toString(uint256(config.expectedGuardIps))
        );
        vm.setEnv(
            "OPTIMIZER_GUARD_BASE_PRICE",
            vm.toString(uint256(config.expectedGuardBasePrice))
        );
        vm.setEnv(
            "OPTIMIZER_GUARD_MIN_PRICE",
            vm.toString(uint256(config.expectedGuardMinPrice))
        );
    }
}

contract OptimizerSharePositionManagerHarness is BasePositionManager {
    address public immutable swapSink;

    constructor(
        ICentralRegistry cr,
        address mm,
        address wNative,
        address newSwapSink
    ) BasePositionManager(cr, mm, wNative) {
        swapSink = newSwapSink;
    }

    function _swapDebtAssetToCollateralAsset(
        LeverageAction memory action,
        address
    ) internal override {
        bool success = IERC20(action.borrowableCToken.asset())
            .transfer(swapSink, action.borrowAssets);
        require(success, "debt sink transfer failed");
    }

    function _swapCollateralAssetToDebtAsset(DeleverageAction memory action)
        internal
        override
    {
        address collateralAsset = action.cToken.asset();
        uint256 collateralBalance =
            IERC20(collateralAsset).balanceOf(address(this));
        if (collateralBalance > 0) {
            bool success =
                IERC20(collateralAsset).transfer(swapSink, collateralBalance);
            require(success, "collateral sink transfer failed");
        }
    }

    function withdrawByPositionManagerForTest(
        ICToken cToken,
        uint256 assets,
        address owner,
        DeleverageAction memory action
    ) external {
        cToken.withdrawByPositionManager(assets, owner, action);
    }
}

contract OptimizerShareSwapTarget {
    IERC20 internal immutable inputToken;
    IERC20 internal immutable outputToken;

    constructor(IERC20 inputToken_, IERC20 outputToken_) {
        inputToken = inputToken_;
        outputToken = outputToken_;
    }

    function swap(uint256 inputAmount, uint256 outputAmount) external {
        require(
            inputToken.transferFrom(msg.sender, address(this), inputAmount),
            "input transfer failed"
        );
        require(
            outputToken.transfer(msg.sender, outputAmount),
            "output transfer failed"
        );
    }
}

contract PartialInputOptimizerShareSwapTarget {
    IERC20 internal immutable inputToken;
    IERC20 internal immutable outputToken;

    constructor(IERC20 inputToken_, IERC20 outputToken_) {
        inputToken = inputToken_;
        outputToken = outputToken_;
    }

    function partialSwap(uint256 spentInputAmount, uint256 outputAmount)
        external
    {
        require(
            inputToken.transferFrom(
                msg.sender, address(this), spentInputAmount
            ),
            "input transfer failed"
        );
        require(
            outputToken.transfer(msg.sender, outputAmount),
            "output transfer failed"
        );
    }
}

contract MockRewardManagerForZapper {
    IERC20 internal immutable rewardToken;
    mapping(address => uint256) public rewards;

    constructor(IERC20 rewardToken_) {
        rewardToken = rewardToken_;
    }

    function setReward(address user, uint256 amount) external {
        rewards[user] = amount;
    }

    function manageRewardsFor(address user) external returns (uint256 result) {
        result = rewards[user];
        rewards[user] = 0;
        require(
            rewardToken.transfer(msg.sender, result), "reward transfer failed"
        );
    }
}

contract MockVolatileLPAdaptor is BaseVolatileLPAdaptor {
    constructor(ICentralRegistry centralRegistry)
        BaseVolatileLPAdaptor(centralRegistry, "Mock Volatile LP Adaptor")
    {}

    function _checkLPType(IVeloPool) internal view override {}
}

contract MockStableLPAdaptor is BaseStableLPAdaptor {
    constructor(ICentralRegistry centralRegistry)
        BaseStableLPAdaptor(centralRegistry, "Mock Stable LP Adaptor")
    {}

    function _checkLPType(IVeloPool) internal view override {}
}

contract MockUniswapV3OptimizerSharePool {
    address public immutable token0;
    address public immutable token1;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }
}

contract MockUniswapV3StaticOracle {
    uint256 internal quoteAmount;

    function setQuoteAmount(uint256 quoteAmount_) external {
        quoteAmount = quoteAmount_;
    }

    function quoteSpecificPoolsWithTimePeriod(
        uint128,
        address,
        address,
        address[] calldata,
        uint32
    ) external view returns (uint256) {
        return quoteAmount;
    }
}

contract MockPendleSY is MockERC20 {
    address internal immutable underlying;
    uint8 internal immutable underlyingDecimals;

    constructor(address underlying_, uint8 underlyingDecimals_)
        MockERC20("Mock Pendle SY", "mSY", 18)
    {
        underlying = underlying_;
        underlyingDecimals = underlyingDecimals_;
    }

    function exchangeRate() external pure returns (uint256) {
        return 1e18;
    }

    function assetInfo()
        external
        view
        returns (IStandardizedYield.AssetType, address, uint8)
    {
        return (
            IStandardizedYield.AssetType.TOKEN, underlying, underlyingDecimals
        );
    }
}

contract MockPendleYT {
    uint256 public pyIndexStored = 1e18;
    bool public doCacheIndexSameBlock;
    uint128 public pyIndexLastUpdatedBlock;
}

contract MockPendleMarket is MockERC20 {
    IStandardizedYield internal immutable sy;
    IPPrincipalToken internal immutable pt;
    IPYieldToken internal immutable yt;
    MarketState internal marketState;

    constructor(IStandardizedYield sy_, IPPrincipalToken pt_, IPYieldToken yt_)
        MockERC20("Mock Pendle Market LP", "mPENDLE-LP", 18)
    {
        sy = sy_;
        pt = pt_;
        yt = yt_;
    }

    function setExpiredState(int256 totalPt_, int256 totalSy_, int256 totalLp_)
        external
    {
        marketState.totalPt = totalPt_;
        marketState.totalSy = totalSy_;
        marketState.totalLp = totalLp_;
        marketState.expiry = block.timestamp;
    }

    function readTokens()
        external
        view
        returns (IStandardizedYield, IPPrincipalToken, IPYieldToken)
    {
        return (sy, pt, yt);
    }

    function readState(address) external view returns (MarketState memory) {
        return marketState;
    }

    function expiry() external view returns (uint256) {
        return marketState.expiry;
    }
}

contract MockPendlePTOracle {
    function getOracleState(address, uint32)
        external
        pure
        returns (bool, uint16, bool)
    {
        return (false, 0, true);
    }
}

contract MockVolatileOptimizerSharePool is MockERC20, IVeloPool {
    address public immutable token0;
    address public immutable token1;
    address public immutable factory;
    bool public constant stable = false;

    uint112 internal reserve0;
    uint112 internal reserve1;
    uint32 internal blockTimestampLast;

    constructor(address token0_, address token1_)
        MockERC20("Mock Optimizer Share LP", "mockLP", 18)
    {
        token0 = token0_;
        token1 = token1_;
        factory = address(this);
    }

    function setReserves(uint112 reserve0_, uint112 reserve1_) external {
        reserve0 = reserve0_;
        reserve1 = reserve1_;
        blockTimestampLast = uint32(block.timestamp);
    }

    function getK() external view returns (uint256) {
        return uint256(reserve0) * uint256(reserve1);
    }

    function totalSupply()
        public
        view
        override(ERC20, IVeloPool)
        returns (uint256 result)
    {
        return super.totalSupply();
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }
}

contract MockStableOptimizerSharePool is MockERC20, IVeloPool {
    address public immutable token0;
    address public immutable token1;
    address public immutable factory;
    bool public constant stable = true;

    uint112 internal reserve0;
    uint112 internal reserve1;
    uint32 internal blockTimestampLast;

    constructor(address token0_, address token1_)
        MockERC20("Mock Stable Optimizer Share LP", "mockSLP", 18)
    {
        token0 = token0_;
        token1 = token1_;
        factory = address(this);
    }

    function setReserves(uint112 reserve0_, uint112 reserve1_) external {
        reserve0 = reserve0_;
        reserve1 = reserve1_;
        blockTimestampLast = uint32(block.timestamp);
    }

    function getK() external view returns (uint256) {
        return uint256(reserve0) * uint256(reserve1);
    }

    function totalSupply()
        public
        view
        override(ERC20, IVeloPool)
        returns (uint256 result)
    {
        return super.totalSupply();
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }
}

contract ExternalRawOptimizerShareBuyer {
    IERC20 internal immutable asset;

    constructor(IERC20 asset_) {
        asset = asset_;
    }

    function buyAtRawQuote(
        ILendingOptimizer optimizer,
        uint256 shares,
        address seller
    ) external returns (uint256 assetsPaid) {
        assetsPaid = optimizer.convertToAssets(shares);
        require(
            IERC20(address(optimizer))
                .transferFrom(seller, address(this), shares),
            "share transfer failed"
        );
        require(asset.transfer(seller, assetsPaid), "asset transfer failed");
    }
}

contract ExternalRawOptimizerShareLender {
    IERC20 internal immutable asset;
    uint256 internal immutable liquidationLtvBps;

    mapping(address => uint256) public collateralShares;
    mapping(address => uint256) public debtAssets;

    constructor(IERC20 asset_, uint256 liquidationLtvBps_) {
        asset = asset_;
        liquidationLtvBps = liquidationLtvBps_;
    }

    function openPosition(
        ILendingOptimizer optimizer,
        uint256 shares,
        uint256 debt,
        address borrower
    ) external {
        collateralShares[borrower] += shares;
        debtAssets[borrower] += debt;

        require(
            IERC20(address(optimizer))
                .transferFrom(borrower, address(this), shares),
            "collateral transfer failed"
        );
        require(asset.transfer(borrower, debt), "borrow transfer failed");
    }

    function rawBorrowLimit(ILendingOptimizer optimizer, address borrower)
        external
        view
        returns (uint256)
    {
        return _rawBorrowLimit(optimizer, borrower);
    }

    function liquidateAtRawPrice(
        ILendingOptimizer optimizer,
        address borrower,
        address liquidator
    ) external returns (uint256 seizedShares, uint256 repaidAssets) {
        repaidAssets = debtAssets[borrower];
        require(
            repaidAssets > _rawBorrowLimit(optimizer, borrower),
            "raw position healthy"
        );

        seizedShares = collateralShares[borrower];
        collateralShares[borrower] = 0;
        debtAssets[borrower] = 0;

        require(
            asset.transferFrom(liquidator, address(this), repaidAssets),
            "repay transfer failed"
        );
        require(
            IERC20(address(optimizer)).transfer(liquidator, seizedShares),
            "collateral transfer failed"
        );
    }

    function _rawBorrowLimit(ILendingOptimizer optimizer, address borrower)
        internal
        view
        returns (uint256)
    {
        return FixedPointMathLib.mulDiv(
            optimizer.convertToAssets(collateralShares[borrower]),
            liquidationLtvBps,
            10000
        );
    }
}

contract ExternalRawOptimizerShareVault is ERC20 {
    ILendingOptimizer public immutable optimizer;

    constructor(ILendingOptimizer optimizer_) {
        optimizer = optimizer_;
    }

    function name() public pure override returns (string memory) {
        return "External Raw Optimizer Share Vault";
    }

    function symbol() public pure override returns (string memory) {
        return "ext-hyAUSD";
    }

    function decimals() public view override returns (uint8) {
        return IERC20(address(optimizer)).decimals();
    }

    function asset() external view returns (address) {
        return address(optimizer);
    }

    function totalAssets() external view returns (uint256) {
        return IERC20(address(optimizer)).balanceOf(address(this));
    }

    function convertToAssets(uint256 shares)
        public
        view
        returns (uint256 assets)
    {
        uint256 supply = totalSupply();
        uint256 heldShares =
            IERC20(address(optimizer)).balanceOf(address(this));
        if (supply == 0) return shares;

        assets = FixedPointMathLib.mulDiv(shares, heldShares, supply);
    }

    function deposit(uint256 assets, address receiver)
        external
        returns (uint256 shares)
    {
        uint256 supply = totalSupply();
        uint256 heldSharesBefore =
            IERC20(address(optimizer)).balanceOf(address(this));
        shares = supply == 0
            ? assets
            : FixedPointMathLib.mulDiv(assets, supply, heldSharesBefore);

        require(
            IERC20(address(optimizer)).transferFrom(
                msg.sender,
                address(this),
                assets
            ),
            "raw-vault deposit failed"
        );
        _mint(receiver, shares);
    }
}

contract ExternalRawOptimizerShareVaultLender {
    IERC20 internal immutable asset;
    uint256 internal immutable liquidationLtvBps;

    mapping(address => uint256) public collateralShares;
    mapping(address => uint256) public debtAssets;

    constructor(IERC20 asset_, uint256 liquidationLtvBps_) {
        asset = asset_;
        liquidationLtvBps = liquidationLtvBps_;
    }

    function openPosition(
        ExternalRawOptimizerShareVault vault,
        uint256 shares,
        uint256 debt,
        address borrower
    ) external {
        collateralShares[borrower] += shares;
        debtAssets[borrower] += debt;

        require(
            vault.transferFrom(borrower, address(this), shares),
            "raw-vault collateral transfer failed"
        );
        require(asset.transfer(borrower, debt), "borrow transfer failed");
    }

    function rawBorrowLimit(
        ExternalRawOptimizerShareVault vault,
        ILendingOptimizer optimizer,
        address borrower
    ) external view returns (uint256) {
        return _rawBorrowLimit(vault, optimizer, borrower);
    }

    function liquidateAtRawPrice(
        ExternalRawOptimizerShareVault vault,
        ILendingOptimizer optimizer,
        address borrower,
        address liquidator
    ) external returns (uint256 seizedShares, uint256 repaidAssets) {
        repaidAssets = debtAssets[borrower];
        require(
            repaidAssets > _rawBorrowLimit(vault, optimizer, borrower),
            "raw-vault position healthy"
        );

        seizedShares = collateralShares[borrower];
        collateralShares[borrower] = 0;
        debtAssets[borrower] = 0;

        require(
            asset.transferFrom(liquidator, address(this), repaidAssets),
            "repay transfer failed"
        );
        require(
            vault.transfer(liquidator, seizedShares),
            "raw-vault collateral transfer failed"
        );
    }

    function _rawBorrowLimit(
        ExternalRawOptimizerShareVault vault,
        ILendingOptimizer optimizer,
        address borrower
    ) internal view returns (uint256) {
        uint256 optimizerShares =
            vault.convertToAssets(collateralShares[borrower]);
        return FixedPointMathLib.mulDiv(
            optimizer.convertToAssets(optimizerShares),
            liquidationLtvBps,
            10000
        );
    }
}

contract ExternalOptimizerShareCTokenLender {
    IERC20 internal immutable asset;
    uint256 internal immutable liquidationLtvBps;

    mapping(address => uint256) public collateralShares;
    mapping(address => uint256) public debtAssets;

    constructor(IERC20 asset_, uint256 liquidationLtvBps_) {
        asset = asset_;
        liquidationLtvBps = liquidationLtvBps_;
    }

    function openPosition(
        LendingOptimizerShareCToken shareCToken,
        uint256 shares,
        uint256 debt,
        address borrower
    ) external {
        collateralShares[borrower] += shares;
        debtAssets[borrower] += debt;

        require(
            IERC20(address(shareCToken)).transferFrom(
                borrower, address(this), shares
            ),
            "collateral transfer failed"
        );
        require(asset.transfer(borrower, debt), "borrow transfer failed");
    }

    function rawBorrowLimit(
        LendingOptimizerShareCToken shareCToken,
        ILendingOptimizer optimizer,
        address borrower
    ) external view returns (uint256) {
        return _rawBorrowLimit(shareCToken, optimizer, borrower);
    }

    function liquidateAtRawPrice(
        LendingOptimizerShareCToken shareCToken,
        ILendingOptimizer optimizer,
        address borrower,
        address liquidator
    ) external returns (uint256 seizedShares, uint256 repaidAssets) {
        repaidAssets = debtAssets[borrower];
        require(
            repaidAssets > _rawBorrowLimit(shareCToken, optimizer, borrower),
            "wrapper position healthy"
        );

        seizedShares = collateralShares[borrower];
        collateralShares[borrower] = 0;
        debtAssets[borrower] = 0;

        require(
            asset.transferFrom(liquidator, address(this), repaidAssets),
            "repay transfer failed"
        );
        require(
            IERC20(address(shareCToken)).transfer(liquidator, seizedShares),
            "collateral transfer failed"
        );
    }

    function _rawBorrowLimit(
        LendingOptimizerShareCToken shareCToken,
        ILendingOptimizer optimizer,
        address borrower
    ) internal view returns (uint256) {
        uint256 optimizerShares =
            shareCToken.convertToAssets(collateralShares[borrower]);
        return FixedPointMathLib.mulDiv(
            optimizer.convertToAssets(optimizerShares),
            liquidationLtvBps,
            10000
        );
    }
}

contract ExternalOptimizerShareCTokenVault is ERC20 {
    LendingOptimizerShareCToken public immutable shareCToken;

    constructor(LendingOptimizerShareCToken shareCToken_) {
        shareCToken = shareCToken_;
    }

    function name() public pure override returns (string memory) {
        return "External Optimizer Share CToken Vault";
    }

    function symbol() public pure override returns (string memory) {
        return "ext-ocToken";
    }

    function decimals() public view override returns (uint8) {
        return IERC20(address(shareCToken)).decimals();
    }

    function asset() external view returns (address) {
        return address(shareCToken);
    }

    function totalAssets() external view returns (uint256) {
        return IERC20(address(shareCToken)).balanceOf(address(this));
    }

    function convertToAssets(uint256 shares)
        public
        view
        returns (uint256 assets)
    {
        uint256 supply = totalSupply();
        uint256 heldShares =
            IERC20(address(shareCToken)).balanceOf(address(this));
        if (supply == 0) return shares;

        assets = FixedPointMathLib.mulDiv(shares, heldShares, supply);
    }

    function deposit(uint256 assets, address receiver)
        external
        returns (uint256 shares)
    {
        uint256 supply = totalSupply();
        uint256 heldSharesBefore =
            IERC20(address(shareCToken)).balanceOf(address(this));
        shares = supply == 0
            ? assets
            : FixedPointMathLib.mulDiv(assets, supply, heldSharesBefore);

        require(
            IERC20(address(shareCToken)).transferFrom(
                msg.sender,
                address(this),
                assets
            ),
            "vault deposit failed"
        );
        _mint(receiver, shares);
    }
}

contract ExternalOptimizerShareVaultLender {
    IERC20 internal immutable asset;
    uint256 internal immutable liquidationLtvBps;

    mapping(address => uint256) public collateralShares;
    mapping(address => uint256) public debtAssets;

    constructor(IERC20 asset_, uint256 liquidationLtvBps_) {
        asset = asset_;
        liquidationLtvBps = liquidationLtvBps_;
    }

    function openPosition(
        ExternalOptimizerShareCTokenVault vault,
        uint256 shares,
        uint256 debt,
        address borrower
    ) external {
        collateralShares[borrower] += shares;
        debtAssets[borrower] += debt;

        require(
            vault.transferFrom(borrower, address(this), shares),
            "vault collateral transfer failed"
        );
        require(asset.transfer(borrower, debt), "borrow transfer failed");
    }

    function rawBorrowLimit(
        ExternalOptimizerShareCTokenVault vault,
        LendingOptimizerShareCToken shareCToken,
        ILendingOptimizer optimizer,
        address borrower
    ) external view returns (uint256) {
        return _rawBorrowLimit(vault, shareCToken, optimizer, borrower);
    }

    function liquidateAtRawPrice(
        ExternalOptimizerShareCTokenVault vault,
        LendingOptimizerShareCToken shareCToken,
        ILendingOptimizer optimizer,
        address borrower,
        address liquidator
    ) external returns (uint256 seizedShares, uint256 repaidAssets) {
        repaidAssets = debtAssets[borrower];
        require(
            repaidAssets > _rawBorrowLimit(
                vault,
                shareCToken,
                optimizer,
                borrower
            ),
            "outer-vault position healthy"
        );

        seizedShares = collateralShares[borrower];
        collateralShares[borrower] = 0;
        debtAssets[borrower] = 0;

        require(
            asset.transferFrom(liquidator, address(this), repaidAssets),
            "repay transfer failed"
        );
        require(
            vault.transfer(liquidator, seizedShares),
            "vault collateral transfer failed"
        );
    }

    function _rawBorrowLimit(
        ExternalOptimizerShareCTokenVault vault,
        LendingOptimizerShareCToken shareCToken,
        ILendingOptimizer optimizer,
        address borrower
    ) internal view returns (uint256) {
        uint256 wrapperShares =
            vault.convertToAssets(collateralShares[borrower]);
        uint256 optimizerShares = shareCToken.convertToAssets(wrapperShares);
        return FixedPointMathLib.mulDiv(
            optimizer.convertToAssets(optimizerShares),
            liquidationLtvBps,
            10000
        );
    }
}

contract ExternalRawOptimizerShareLendingMarket {
    mapping(address => uint256) public collateralValue;

    function depositAtRawCollateralValue(
        ILendingOptimizer optimizer,
        uint256 shares,
        address borrower
    ) external returns (uint256 recordedCollateral) {
        recordedCollateral = optimizer.convertToAssets(shares);
        collateralValue[borrower] += recordedCollateral;
        require(
            IERC20(address(optimizer))
                .transferFrom(borrower, address(this), shares),
            "share transfer failed"
        );
    }
}

contract MockInvalidLendingOptimizer is MockERC20, ILendingOptimizer {
    uint256 public constant MAX_FEE_BPS = 1000;
    uint256 public constant MAX_MARKETS = 8;

    ICentralRegistry public immutable centralRegistry;
    address public immutable asset;

    address[] internal _approvedMarkets;

    mapping(address => uint256) public allocationCaps;
    uint256 public fee;
    uint256 public exchangeRateHighWatermark;
    uint8 public mintPaused;
    uint256 public totalAssets;

    constructor(
        ICentralRegistry centralRegistry_,
        address asset_,
        address[] memory approvedMarkets
    ) MockERC20("Fake Lending Optimizer", "fLO", 6) {
        centralRegistry = centralRegistry_;
        asset = asset_;
        _approvedMarkets = approvedMarkets;
    }

    function balanceOf(address account)
        public
        view
        override(ERC20, ILendingOptimizer)
        returns (uint256)
    {
        return super.balanceOf(account);
    }

    function approvedCTokensList(uint256 index)
        external
        view
        returns (address)
    {
        return _approvedMarkets[index];
    }

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function deposit(uint256 assets, address receiver)
        external
        returns (uint256 shares)
    {
        shares = assets;
        totalAssets += assets;
        _mint(receiver, shares);
    }

    function initializeDeposits(address) external {}

    function addApprovedAsset(address newAsset, uint256) external {
        _approvedMarkets.push(newAsset);
    }

    function updateCap(address cToken, uint256 newCapBps) external {
        allocationCaps[cToken] = newCapBps;
    }

    function setFee(uint256 newFeeBps) external {
        fee = newFeeBps;
    }

    function setMintPaused(bool state) external {
        mintPaused = state ? 2 : 1;
    }

    function exchangeRate() external pure returns (uint256) {
        return 1e18;
    }

    function exchangeRateUpdated() external pure returns (uint256) {
        return 1e18;
    }

    function accrueIfNeeded() external {}

    function skim() external {}

    function skimAvailable() external pure returns (uint256) {
        return 0;
    }

    function numApprovedMarkets() external view returns (uint256) {
        return _approvedMarkets.length;
    }

    function getApprovedMarkets() external view returns (address[] memory) {
        return _approvedMarkets;
    }

    function supportsInterface(bytes4 interfaceId)
        external
        pure
        returns (bool)
    {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(ILendingOptimizer).interfaceId;
    }
}
