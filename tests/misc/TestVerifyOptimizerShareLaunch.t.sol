// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    VerifyOptimizerShareLaunch
} from "script/deployment/VerifyOptimizerShareLaunch.s.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IMarketManager} from "contracts/interfaces/IMarketManager.sol";
import {IOracleAdaptor} from "contracts/interfaces/IOracleAdaptor.sol";
import {IPositionManager} from "contracts/interfaces/IPositionManager.sol";
import {
    VaultAggregator
} from "contracts/oracles/adaptors/wrappedAggregators/VaultAggregator.sol";

contract VerifyOptimizerShareLaunchMockRegistry {
    address public immutable oracleManager;

    constructor(address oracleManager_) {
        oracleManager = oracleManager_;
    }
}

contract VerifyOptimizerShareLaunchMockToken {
    uint8 public immutable decimals;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }
}

contract VerifyOptimizerShareLaunchMockOptimizer {
    address public asset;
    ICentralRegistry public immutable centralRegistry;
    uint8 public immutable decimals;

    constructor(
        address asset_,
        ICentralRegistry centralRegistry_,
        uint8 decimals_
    ) {
        asset = asset_;
        centralRegistry = centralRegistry_;
        decimals = decimals_;
    }

    function setAsset(address asset_) external {
        asset = asset_;
    }

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares;
    }
}

contract VerifyOptimizerShareLaunchMockCToken {
    error LendingOptimizerShareCToken__BorrowDisabled();

    address public asset;
    ICentralRegistry public immutable centralRegistry;
    IMarketManager public immutable marketManager;
    bool public borrowDisabled = true;
    bool public borrowForDisabled = true;
    bool public borrowForPositionManagerDisabled = true;
    bool public flashLoanDisabled = true;
    bool public nonzeroDebtSurfacesEnabled;

    constructor(
        address asset_,
        ICentralRegistry centralRegistry_,
        IMarketManager marketManager_
    ) {
        asset = asset_;
        centralRegistry = centralRegistry_;
        marketManager = marketManager_;
    }

    function setAsset(address asset_) external {
        asset = asset_;
    }

    function setBorrowDisabled(bool disabled) external {
        borrowDisabled = disabled;
    }

    function setBorrowForDisabled(bool disabled) external {
        borrowForDisabled = disabled;
    }

    function setBorrowForPositionManagerDisabled(bool disabled) external {
        borrowForPositionManagerDisabled = disabled;
    }

    function setFlashLoanDisabled(bool disabled) external {
        flashLoanDisabled = disabled;
    }

    function setNonzeroDebtSurfacesEnabled(bool enabled) external {
        nonzeroDebtSurfacesEnabled = enabled;
    }

    function borrow(uint256 assets, address) external view {
        if (_shouldRevertDebtSurface(borrowDisabled, assets)) {
            revert LendingOptimizerShareCToken__BorrowDisabled();
        }
    }

    function borrowFor(uint256 assets, address, address) external view {
        if (_shouldRevertDebtSurface(borrowForDisabled, assets)) {
            revert LendingOptimizerShareCToken__BorrowDisabled();
        }
    }

    function borrowForPositionManager(
        uint256 assets,
        address,
        IPositionManager.LeverageAction calldata
    ) external view {
        if (_shouldRevertDebtSurface(borrowForPositionManagerDisabled, assets))
        {
            revert LendingOptimizerShareCToken__BorrowDisabled();
        }
    }

    function flashLoan(uint256 assets, bytes calldata) external view {
        if (_shouldRevertDebtSurface(flashLoanDisabled, assets)) {
            revert LendingOptimizerShareCToken__BorrowDisabled();
        }
    }

    function _shouldRevertDebtSurface(bool surfaceDisabled, uint256 assets)
        internal
        view
        returns (bool)
    {
        return surfaceDisabled && (!nonzeroDebtSurfacesEnabled || assets == 0);
    }
}

contract VerifyOptimizerShareLaunchMockMarketManager {
    ICentralRegistry public immutable centralRegistry;
    mapping(address => bool) public isListed;
    mapping(address => uint256) public debtCaps;
    mapping(address => uint256) public collateralCaps;

    constructor(ICentralRegistry centralRegistry_) {
        centralRegistry = centralRegistry_;
    }

    function setConfig(
        address cToken,
        bool listed,
        uint256 debtCap,
        uint256 collateralCap
    ) external {
        isListed[cToken] = listed;
        debtCaps[cToken] = debtCap;
        collateralCaps[cToken] = collateralCap;
    }
}

contract VerifyOptimizerShareLaunchMockOracleManager {
    mapping(address => address) public cTokens;
    mapping(address => address[]) internal _pricingAdaptors;

    function setCToken(address cToken, address underlying) external {
        cTokens[cToken] = underlying;
    }

    function setPricingAdaptors(address asset, address[] memory adaptors)
        external
    {
        _pricingAdaptors[asset] = adaptors;
    }

    function isSupportedAsset(address asset) external view returns (bool) {
        return _pricingAdaptors[asset].length > 0;
    }

    function getPricingAdaptors(address asset)
        external
        view
        returns (address[] memory)
    {
        return _pricingAdaptors[asset];
    }
}

contract VerifyOptimizerShareLaunchMockAdaptor {
    struct AssetConfig {
        bool isConfigured;
        address aggregator;
        uint8 decimals;
        uint24 heartbeat;
    }

    mapping(address => AssetConfig) internal _assetConfigs;
    mapping(address => IOracleAdaptor.PriceGuard) internal _guards;
    mapping(bool => IOracleAdaptor.PricingResult) internal _priceResults;

    constructor() {
        _priceResults[true] = IOracleAdaptor.PricingResult(1e18, true, false);
        _priceResults[false] = IOracleAdaptor.PricingResult(1e18, true, false);
    }

    function setAssetConfig(
        address asset,
        bool isConfigured,
        address aggregator,
        uint8 decimals,
        uint24 heartbeat
    ) external {
        _assetConfigs[asset] = AssetConfig({
            isConfigured: isConfigured,
            aggregator: aggregator,
            decimals: decimals,
            heartbeat: heartbeat
        });
    }

    function setPriceGuard(
        address asset,
        IOracleAdaptor.PriceGuard memory guard
    ) external {
        _guards[asset] = guard;
    }

    function setPriceResult(
        bool getLower,
        uint256 price,
        bool inUSD,
        bool hadError
    ) external {
        _priceResults[getLower] =
            IOracleAdaptor.PricingResult(price, inUSD, hadError);
    }

    function assetConfig(address asset, bool)
        external
        view
        returns (
            bool isConfigured,
            address aggregator,
            uint8 decimals,
            uint24 heartbeat
        )
    {
        AssetConfig memory config = _assetConfigs[asset];
        return (
            config.isConfigured,
            config.aggregator,
            config.decimals,
            config.heartbeat
        );
    }

    function getPriceGuard(address asset, bool)
        external
        view
        returns (IOracleAdaptor.PriceGuard memory)
    {
        return _guards[asset];
    }

    function getPrice(address, bool, bool getLower)
        external
        view
        returns (IOracleAdaptor.PricingResult memory)
    {
        return _priceResults[getLower];
    }

    function isSupportedAsset(address asset) external view returns (bool) {
        return _assetConfigs[asset].isConfigured;
    }
}

contract VerifyOptimizerShareLaunchMockFeed {
    uint8 public immutable decimals;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function latestRoundData()
        external
        pure
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (1, 1e8, 1, 1, 1);
    }

    function latestRound() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80 roundId)
        external
        pure
        returns (
            uint80,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (roundId, 1e8, 1, 1, roundId);
    }
}

contract TestVerifyOptimizerShareLaunch is Test {
    uint256 internal constant EXPECTED_COLLATERAL_CAP = 100e18;
    uint8 internal constant EXPECTED_FEED_DECIMALS = 8;
    uint24 internal constant EXPECTED_HEARTBEAT = 6 hours;
    uint40 internal constant EXPECTED_GUARD_TIMESTAMP_START = 1000;
    uint40 internal constant EXPECTED_GUARD_IPS = 1e12;
    uint88 internal constant EXPECTED_GUARD_BASE_PRICE = 1e18;
    uint88 internal constant EXPECTED_GUARD_MIN_PRICE = 0.95e18;

    VerifyOptimizerShareLaunch internal script;
    VerifyOptimizerShareLaunchMockToken internal underlying;
    VerifyOptimizerShareLaunchMockRegistry internal registry;
    VerifyOptimizerShareLaunchMockRegistry internal otherRegistry;
    VerifyOptimizerShareLaunchMockOptimizer internal optimizer;
    VerifyOptimizerShareLaunchMockOptimizer internal otherOptimizer;
    VerifyOptimizerShareLaunchMockCToken internal shareCToken;
    VerifyOptimizerShareLaunchMockMarketManager internal marketManager;
    VerifyOptimizerShareLaunchMockOracleManager internal oracleManager;
    VerifyOptimizerShareLaunchMockAdaptor internal adaptor;
    VerifyOptimizerShareLaunchMockFeed internal feed;
    VaultAggregator internal vaultAggregator;

    function setUp() public {
        script = new VerifyOptimizerShareLaunch();
        underlying = new VerifyOptimizerShareLaunchMockToken(18);
        oracleManager = new VerifyOptimizerShareLaunchMockOracleManager();
        registry =
            new VerifyOptimizerShareLaunchMockRegistry(address(oracleManager));
        otherRegistry =
            new VerifyOptimizerShareLaunchMockRegistry(address(oracleManager));
        optimizer = new VerifyOptimizerShareLaunchMockOptimizer(
            address(underlying), ICentralRegistry(address(registry)), 18
        );
        otherOptimizer = new VerifyOptimizerShareLaunchMockOptimizer(
            address(underlying), ICentralRegistry(address(registry)), 18
        );
        marketManager = new VerifyOptimizerShareLaunchMockMarketManager(
            ICentralRegistry(address(registry))
        );
        shareCToken = new VerifyOptimizerShareLaunchMockCToken(
            address(optimizer),
            ICentralRegistry(address(registry)),
            IMarketManager(address(marketManager))
        );
        feed = new VerifyOptimizerShareLaunchMockFeed(EXPECTED_FEED_DECIMALS);
        vaultAggregator = new VaultAggregator(
            address(optimizer), address(underlying), address(feed), ""
        );
        adaptor = new VerifyOptimizerShareLaunchMockAdaptor();

        _configureExpectedLaunch();
    }

    function test_verifyOptimizerShareLaunch_acceptsExpectedConfig() public {
        script.verify(_config());
    }

    function test_verifyOptimizerShareLaunch_rejectsWrongShareUnderlying()
        public
    {
        shareCToken.setAsset(address(otherOptimizer));

        vm.expectRevert(
            VerifyOptimizerShareLaunch.VerifyOptimizerShareLaunch__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyOptimizerShareLaunch_rejectsWrongShareCTokenRegistry()
        public
    {
        VerifyOptimizerShareLaunchMockCToken wrongRegistryShareCToken = new VerifyOptimizerShareLaunchMockCToken(
            address(optimizer),
            ICentralRegistry(address(otherRegistry)),
            IMarketManager(address(marketManager))
        );
        _configureShareMarket(address(wrongRegistryShareCToken));

        VerifyOptimizerShareLaunch.Config memory config = _config();
        config.shareCToken = address(wrongRegistryShareCToken);

        vm.expectRevert(
            VerifyOptimizerShareLaunch.VerifyOptimizerShareLaunch__InvalidConfig
                .selector
        );
        script.verify(config);
    }

    function test_verifyOptimizerShareLaunch_rejectsWrongMarketManagerRegistry()
        public
    {
        VerifyOptimizerShareLaunchMockMarketManager
            wrongRegistryMarketManager =
            new VerifyOptimizerShareLaunchMockMarketManager(
                ICentralRegistry(address(otherRegistry))
            );
        VerifyOptimizerShareLaunchMockCToken wrongManagerShareCToken = new VerifyOptimizerShareLaunchMockCToken(
            address(optimizer),
            ICentralRegistry(address(registry)),
            IMarketManager(address(wrongRegistryMarketManager))
        );
        wrongRegistryMarketManager.setConfig(
            address(wrongManagerShareCToken), true, 0, EXPECTED_COLLATERAL_CAP
        );
        oracleManager.setCToken(
            address(wrongManagerShareCToken), address(optimizer)
        );

        VerifyOptimizerShareLaunch.Config memory config = _config();
        config.shareCToken = address(wrongManagerShareCToken);
        config.marketManager = address(wrongRegistryMarketManager);

        vm.expectRevert(
            VerifyOptimizerShareLaunch.VerifyOptimizerShareLaunch__InvalidConfig
                .selector
        );
        script.verify(config);
    }

    function test_verifyOptimizerShareLaunch_rejectsUnlistedShareCToken()
        public
    {
        marketManager.setConfig(
            address(shareCToken), false, 0, EXPECTED_COLLATERAL_CAP
        );

        vm.expectRevert(
            VerifyOptimizerShareLaunch.VerifyOptimizerShareLaunch__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyOptimizerShareLaunch_rejectsNonzeroDebtCap() public {
        marketManager.setConfig(
            address(shareCToken), true, 1, EXPECTED_COLLATERAL_CAP
        );

        vm.expectRevert(
            VerifyOptimizerShareLaunch.VerifyOptimizerShareLaunch__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyOptimizerShareLaunch_rejectsEnabledBorrowSurface()
        public
    {
        shareCToken.setBorrowDisabled(false);

        vm.expectRevert(
            VerifyOptimizerShareLaunch.VerifyOptimizerShareLaunch__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyOptimizerShareLaunch_rejectsZeroOnlyDebtSurfaceGuards()
        public
    {
        shareCToken.setNonzeroDebtSurfacesEnabled(true);

        vm.expectRevert(
            VerifyOptimizerShareLaunch.VerifyOptimizerShareLaunch__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyOptimizerShareLaunch_rejectsEnabledBorrowForSurface()
        public
    {
        shareCToken.setBorrowForDisabled(false);

        vm.expectRevert(
            VerifyOptimizerShareLaunch.VerifyOptimizerShareLaunch__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyOptimizerShareLaunch_rejectsEnabledBorrowForPositionManagerSurface()
        public
    {
        shareCToken.setBorrowForPositionManagerDisabled(false);

        vm.expectRevert(
            VerifyOptimizerShareLaunch.VerifyOptimizerShareLaunch__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyOptimizerShareLaunch_rejectsEnabledFlashLoanSurface()
        public
    {
        shareCToken.setFlashLoanDisabled(false);

        vm.expectRevert(
            VerifyOptimizerShareLaunch.VerifyOptimizerShareLaunch__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyOptimizerShareLaunch_rejectsWrongCollateralCap()
        public
    {
        marketManager.setConfig(
            address(shareCToken), true, 0, EXPECTED_COLLATERAL_CAP + 1
        );

        vm.expectRevert(
            VerifyOptimizerShareLaunch.VerifyOptimizerShareLaunch__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyOptimizerShareLaunch_rejectsMissingOracleCtokenMapping()
        public
    {
        oracleManager.setCToken(address(shareCToken), address(0));

        vm.expectRevert(
            VerifyOptimizerShareLaunch.VerifyOptimizerShareLaunch__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyOptimizerShareLaunch_rejectsMissingOracleRoute()
        public
    {
        address[] memory emptyAdaptors = new address[](0);
        oracleManager.setPricingAdaptors(address(optimizer), emptyAdaptors);

        vm.expectRevert(
            VerifyOptimizerShareLaunch.VerifyOptimizerShareLaunch__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyOptimizerShareLaunch_rejectsWrongOracleRoute() public {
        address[] memory adaptors = new address[](1);
        adaptors[0] = address(0xbeef);
        oracleManager.setPricingAdaptors(address(optimizer), adaptors);

        vm.expectRevert(
            VerifyOptimizerShareLaunch.VerifyOptimizerShareLaunch__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyOptimizerShareLaunch_rejectsAdaptorAggregatorMismatch()
        public
    {
        VaultAggregator wrongVaultAggregator = new VaultAggregator(
            address(otherOptimizer), address(underlying), address(feed), ""
        );
        adaptor.setAssetConfig(
            address(optimizer),
            true,
            address(wrongVaultAggregator),
            EXPECTED_FEED_DECIMALS,
            EXPECTED_HEARTBEAT
        );

        vm.expectRevert(
            VerifyOptimizerShareLaunch.VerifyOptimizerShareLaunch__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyOptimizerShareLaunch_rejectsWrongVaultAggregatorVault()
        public
    {
        VaultAggregator wrongVaultAggregator = new VaultAggregator(
            address(otherOptimizer), address(underlying), address(feed), ""
        );
        VerifyOptimizerShareLaunch.Config memory config = _config();
        config.vaultAggregator = address(wrongVaultAggregator);

        vm.expectRevert(
            VerifyOptimizerShareLaunch.VerifyOptimizerShareLaunch__InvalidConfig
                .selector
        );
        script.verify(config);
    }

    function test_verifyOptimizerShareLaunch_rejectsWrongUnderlyingAggregator()
        public
    {
        VerifyOptimizerShareLaunchMockFeed wrongFeed =
            new VerifyOptimizerShareLaunchMockFeed(EXPECTED_FEED_DECIMALS);
        VaultAggregator wrongVaultAggregator = new VaultAggregator(
            address(optimizer), address(underlying), address(wrongFeed), ""
        );
        adaptor.setAssetConfig(
            address(optimizer),
            true,
            address(wrongVaultAggregator),
            EXPECTED_FEED_DECIMALS,
            EXPECTED_HEARTBEAT
        );

        VerifyOptimizerShareLaunch.Config memory config = _config();
        config.vaultAggregator = address(wrongVaultAggregator);

        vm.expectRevert(
            VerifyOptimizerShareLaunch.VerifyOptimizerShareLaunch__InvalidConfig
                .selector
        );
        script.verify(config);
    }

    function test_verifyOptimizerShareLaunch_rejectsVaultAggregatorDecimalsMismatch()
        public
    {
        VerifyOptimizerShareLaunchMockFeed wrongDecimalsFeed =
            new VerifyOptimizerShareLaunchMockFeed(EXPECTED_FEED_DECIMALS + 1);
        VaultAggregator wrongDecimalsVaultAggregator = new VaultAggregator(
            address(optimizer),
            address(underlying),
            address(wrongDecimalsFeed),
            ""
        );
        adaptor.setAssetConfig(
            address(optimizer),
            true,
            address(wrongDecimalsVaultAggregator),
            EXPECTED_FEED_DECIMALS,
            EXPECTED_HEARTBEAT
        );

        VerifyOptimizerShareLaunch.Config memory config = _config();
        config.vaultAggregator = address(wrongDecimalsVaultAggregator);
        config.expectedUnderlyingAggregator = address(wrongDecimalsFeed);

        vm.expectRevert(
            VerifyOptimizerShareLaunch.VerifyOptimizerShareLaunch__InvalidConfig
                .selector
        );
        script.verify(config);
    }

    function test_verifyOptimizerShareLaunch_rejectsWrongDataFeedId() public {
        VaultAggregator wrongVaultAggregator = new VaultAggregator(
            address(optimizer), address(underlying), address(feed), "BAD"
        );
        adaptor.setAssetConfig(
            address(optimizer),
            true,
            address(wrongVaultAggregator),
            EXPECTED_FEED_DECIMALS,
            EXPECTED_HEARTBEAT
        );

        VerifyOptimizerShareLaunch.Config memory config = _config();
        config.vaultAggregator = address(wrongVaultAggregator);

        vm.expectRevert(
            VerifyOptimizerShareLaunch.VerifyOptimizerShareLaunch__InvalidConfig
                .selector
        );
        script.verify(config);
    }

    function test_verifyOptimizerShareLaunch_rejectsPriceGuardMismatch()
        public
    {
        adaptor.setPriceGuard(
            address(optimizer),
            IOracleAdaptor.PriceGuard({
                timestampStart: EXPECTED_GUARD_TIMESTAMP_START + 1,
                ips: EXPECTED_GUARD_IPS,
                basePrice: EXPECTED_GUARD_BASE_PRICE,
                minPrice: EXPECTED_GUARD_MIN_PRICE
            })
        );

        vm.expectRevert(
            VerifyOptimizerShareLaunch.VerifyOptimizerShareLaunch__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyOptimizerShareLaunch_rejectsAdaptorLowerPriceError()
        public
    {
        adaptor.setPriceResult(true, 0, true, true);

        vm.expectRevert(
            VerifyOptimizerShareLaunch.VerifyOptimizerShareLaunch__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyOptimizerShareLaunch_rejectsAdaptorUpperPriceError()
        public
    {
        adaptor.setPriceResult(false, 1e18, false, false);

        vm.expectRevert(
            VerifyOptimizerShareLaunch.VerifyOptimizerShareLaunch__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyOptimizerShareLaunch_runReadsEnvTuple() public {
        vm.setEnv("OPTIMIZER_ADDRESS", vm.toString(address(optimizer)));
        vm.setEnv("OPTIMIZER_SHARE_CTOKEN", vm.toString(address(shareCToken)));
        vm.setEnv(
            "OPTIMIZER_MARKET_MANAGER", vm.toString(address(marketManager))
        );
        vm.setEnv(
            "OPTIMIZER_ORACLE_MANAGER", vm.toString(address(oracleManager))
        );
        vm.setEnv("OPTIMIZER_ORACLE_ADAPTOR", vm.toString(address(adaptor)));
        vm.setEnv(
            "OPTIMIZER_VAULT_AGGREGATOR", vm.toString(address(vaultAggregator))
        );
        vm.setEnv(
            "OPTIMIZER_UNDERLYING_AGGREGATOR", vm.toString(address(feed))
        );
        vm.setEnv("OPTIMIZER_UNDERLYING", vm.toString(address(underlying)));
        vm.setEnv("OPTIMIZER_DATA_FEED_ID", vm.toString(bytes32(0)));
        vm.setEnv(
            "OPTIMIZER_SHARE_COLLATERAL_CAP",
            vm.toString(EXPECTED_COLLATERAL_CAP)
        );
        vm.setEnv(
            "OPTIMIZER_FEED_DECIMALS", vm.toString(EXPECTED_FEED_DECIMALS)
        );
        vm.setEnv("OPTIMIZER_FEED_HEARTBEAT", vm.toString(EXPECTED_HEARTBEAT));
        vm.setEnv(
            "OPTIMIZER_GUARD_TIMESTAMP_START",
            vm.toString(EXPECTED_GUARD_TIMESTAMP_START)
        );
        vm.setEnv("OPTIMIZER_GUARD_IPS", vm.toString(EXPECTED_GUARD_IPS));
        vm.setEnv(
            "OPTIMIZER_GUARD_BASE_PRICE",
            vm.toString(EXPECTED_GUARD_BASE_PRICE)
        );
        vm.setEnv(
            "OPTIMIZER_GUARD_MIN_PRICE", vm.toString(EXPECTED_GUARD_MIN_PRICE)
        );

        script.run();
    }

    function _configureExpectedLaunch() internal {
        _configureShareMarket(address(shareCToken));
        address[] memory adaptors = new address[](1);
        adaptors[0] = address(adaptor);
        oracleManager.setPricingAdaptors(address(optimizer), adaptors);
        adaptor.setAssetConfig(
            address(optimizer),
            true,
            address(vaultAggregator),
            EXPECTED_FEED_DECIMALS,
            EXPECTED_HEARTBEAT
        );
        adaptor.setPriceGuard(
            address(optimizer),
            IOracleAdaptor.PriceGuard({
                timestampStart: EXPECTED_GUARD_TIMESTAMP_START,
                ips: EXPECTED_GUARD_IPS,
                basePrice: EXPECTED_GUARD_BASE_PRICE,
                minPrice: EXPECTED_GUARD_MIN_PRICE
            })
        );
    }

    function _configureShareMarket(address cToken) internal {
        marketManager.setConfig(cToken, true, 0, EXPECTED_COLLATERAL_CAP);
        oracleManager.setCToken(cToken, address(optimizer));
    }

    function _config()
        internal
        view
        returns (VerifyOptimizerShareLaunch.Config memory config)
    {
        config.optimizer = address(optimizer);
        config.shareCToken = address(shareCToken);
        config.marketManager = address(marketManager);
        config.oracleManager = address(oracleManager);
        config.oracleAdaptor = address(adaptor);
        config.vaultAggregator = address(vaultAggregator);
        config.expectedUnderlyingAggregator = address(feed);
        config.expectedUnderlying = address(underlying);
        config.expectedDataFeedId = bytes32(0);
        config.expectedCollateralCap = EXPECTED_COLLATERAL_CAP;
        config.expectedFeedDecimals = EXPECTED_FEED_DECIMALS;
        config.expectedHeartbeat = EXPECTED_HEARTBEAT;
        config.expectedGuardTimestampStart = EXPECTED_GUARD_TIMESTAMP_START;
        config.expectedGuardIps = EXPECTED_GUARD_IPS;
        config.expectedGuardBasePrice = EXPECTED_GUARD_BASE_PRICE;
        config.expectedGuardMinPrice = EXPECTED_GUARD_MIN_PRICE;
    }
}
