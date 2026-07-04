// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    VerifyOptimizerShareDeScope
} from "script/deployment/VerifyOptimizerShareDeScope.s.sol";

contract VerifyOptimizerShareDeScopeMockToken {}

contract VerifyOptimizerShareDeScopeMockOptimizer {
    address public centralRegistry;

    constructor(address centralRegistry_) {
        centralRegistry = centralRegistry_;
    }

    function setCentralRegistry(address centralRegistry_) external {
        centralRegistry = centralRegistry_;
    }
}

contract VerifyOptimizerShareDeScopeMockCToken {
    address public asset;

    constructor(address asset_) {
        asset = asset_;
    }

    function setAsset(address asset_) external {
        asset = asset_;
    }
}

contract VerifyOptimizerShareDeScopeMockOracleManager {
    mapping(address => address) public cTokens;
    mapping(address => bool) public isSupportedAsset;
    mapping(address => address[]) internal pricingAdaptorsByAsset;

    function setCToken(address cToken, address underlying) external {
        cTokens[cToken] = underlying;
    }

    function setSupportedAsset(address asset, bool isSupported) external {
        isSupportedAsset[asset] = isSupported;
    }

    function setPricingAdaptor(address asset, address adaptor) external {
        delete pricingAdaptorsByAsset[asset];
        pricingAdaptorsByAsset[asset].push(adaptor);
    }

    function clearPricingAdaptors(address asset) external {
        delete pricingAdaptorsByAsset[asset];
    }

    function getPricingAdaptors(address asset)
        external
        view
        returns (address[] memory)
    {
        return pricingAdaptorsByAsset[asset];
    }
}

contract VerifyOptimizerShareDeScopeMockCentralRegistry {
    address public feeManager;
    address public feeToken;
    address public oracleManager;

    constructor(address feeToken_) {
        feeToken = feeToken_;
    }

    function setFeeManager(address feeManager_) external {
        feeManager = feeManager_;
    }

    function setFeeToken(address feeToken_) external {
        feeToken = feeToken_;
    }

    function setOracleManager(address oracleManager_) external {
        oracleManager = oracleManager_;
    }
}

contract VerifyOptimizerShareDeScopeMockFeeManager {
    mapping(address => uint256) internal isRewardTokenByAsset;
    mapping(address => uint256) internal forOTCByAsset;

    function rewardTokenInfo(address token)
        external
        view
        returns (uint256 isRewardToken, uint256 forOTC)
    {
        isRewardToken = isRewardTokenByAsset[token];
        forOTC = forOTCByAsset[token];
    }

    function setRewardToken(address token, bool isRewardToken) external {
        isRewardTokenByAsset[token] = isRewardToken ? 2 : 1;
    }

    function setForOTC(address token, bool forOTC) external {
        forOTCByAsset[token] = forOTC ? 2 : 1;
    }
}

contract VerifyOptimizerShareDeScopeMockVaultAggregator {
    address public vault;
    address public asset;

    constructor(address vault_, address asset_) {
        vault = vault_;
        asset = asset_;
    }

    function setVault(address vault_) external {
        vault = vault_;
    }

    function setAsset(address asset_) external {
        asset = asset_;
    }
}

contract VerifyOptimizerShareDeScopeMockLBP {
    address public paymentToken;

    constructor(address paymentToken_) {
        paymentToken = paymentToken_;
    }

    function setPaymentToken(address paymentToken_) external {
        paymentToken = paymentToken_;
    }
}

contract VerifyOptimizerShareDeScopeMockLPAdaptor {
    struct AssetConfig {
        address token0;
        uint8 decimals0;
        address token1;
        uint8 decimals1;
    }

    mapping(address => AssetConfig) public assetConfig;

    function setAssetConfig(address asset, address token0, address token1)
        external
    {
        assetConfig[asset] = AssetConfig({
            token0: token0, decimals0: 18, token1: token1, decimals1: 18
        });
    }
}

contract VerifyOptimizerShareDeScopeMockUniswapAdaptor {
    struct AssetConfig {
        address priceSource;
        uint32 secondsAgo;
        uint8 baseDecimals;
        uint8 quoteDecimals;
        address quoteToken;
    }

    mapping(address => AssetConfig) public assetConfig;

    function setAssetConfig(address asset, address quoteToken) external {
        assetConfig[asset] = AssetConfig({
            priceSource: address(0xbeef),
            secondsAgo: 15 minutes,
            baseDecimals: 18,
            quoteDecimals: 18,
            quoteToken: quoteToken
        });
    }
}

contract VerifyOptimizerShareDeScopeMockPendleAdaptor {
    struct AssetConfig {
        address market;
        uint32 twapDuration;
        address quoteAsset;
        uint8 quoteAssetDecimals;
    }

    mapping(address => AssetConfig) public assetConfig;

    function setAssetConfig(address asset, address quoteAsset) external {
        assetConfig[asset] = AssetConfig({
            market: address(0xbeef),
            twapDuration: 15 minutes,
            quoteAsset: quoteAsset,
            quoteAssetDecimals: 18
        });
    }
}

contract TestVerifyOptimizerShareDeScope is Test {
    VerifyOptimizerShareDeScope internal script;
    VerifyOptimizerShareDeScopeMockOptimizer internal optimizer;
    VerifyOptimizerShareDeScopeMockToken internal firstUnderlying;
    VerifyOptimizerShareDeScopeMockToken internal secondUnderlying;
    VerifyOptimizerShareDeScopeMockToken internal firstVault;
    VerifyOptimizerShareDeScopeMockToken internal secondVault;
    VerifyOptimizerShareDeScopeMockToken internal feeToken;
    VerifyOptimizerShareDeScopeMockToken internal firstLBPPaymentToken;
    VerifyOptimizerShareDeScopeMockToken internal secondLBPPaymentToken;
    VerifyOptimizerShareDeScopeMockToken internal firstAllowedAdaptor;
    VerifyOptimizerShareDeScopeMockToken internal secondAllowedAdaptor;
    VerifyOptimizerShareDeScopeMockToken internal unexpectedAdaptor;
    VerifyOptimizerShareDeScopeMockCToken internal firstCToken;
    VerifyOptimizerShareDeScopeMockCToken internal secondCToken;
    VerifyOptimizerShareDeScopeMockCentralRegistry internal centralRegistry;
    VerifyOptimizerShareDeScopeMockFeeManager internal feeManager;
    VerifyOptimizerShareDeScopeMockVaultAggregator internal
        firstVaultAggregator;
    VerifyOptimizerShareDeScopeMockVaultAggregator internal
        secondVaultAggregator;
    VerifyOptimizerShareDeScopeMockLBP internal firstLBP;
    VerifyOptimizerShareDeScopeMockLBP internal secondLBP;
    VerifyOptimizerShareDeScopeMockOracleManager internal oracleManager;
    VerifyOptimizerShareDeScopeMockToken internal lpRouteAsset;
    VerifyOptimizerShareDeScopeMockToken internal uniswapRouteAsset;
    VerifyOptimizerShareDeScopeMockToken internal pendleRouteAsset;
    VerifyOptimizerShareDeScopeMockLPAdaptor internal lpRouteAdaptor;
    VerifyOptimizerShareDeScopeMockUniswapAdaptor internal uniswapRouteAdaptor;
    VerifyOptimizerShareDeScopeMockPendleAdaptor internal pendleRouteAdaptor;

    function setUp() public {
        script = new VerifyOptimizerShareDeScope();
        firstUnderlying = new VerifyOptimizerShareDeScopeMockToken();
        secondUnderlying = new VerifyOptimizerShareDeScopeMockToken();
        firstVault = new VerifyOptimizerShareDeScopeMockToken();
        secondVault = new VerifyOptimizerShareDeScopeMockToken();
        feeToken = new VerifyOptimizerShareDeScopeMockToken();
        firstLBPPaymentToken = new VerifyOptimizerShareDeScopeMockToken();
        secondLBPPaymentToken = new VerifyOptimizerShareDeScopeMockToken();
        firstAllowedAdaptor = new VerifyOptimizerShareDeScopeMockToken();
        secondAllowedAdaptor = new VerifyOptimizerShareDeScopeMockToken();
        unexpectedAdaptor = new VerifyOptimizerShareDeScopeMockToken();
        oracleManager = new VerifyOptimizerShareDeScopeMockOracleManager();
        centralRegistry = new VerifyOptimizerShareDeScopeMockCentralRegistry(
            address(feeToken)
        );
        feeManager = new VerifyOptimizerShareDeScopeMockFeeManager();
        optimizer = new VerifyOptimizerShareDeScopeMockOptimizer(
            address(centralRegistry)
        );
        centralRegistry.setFeeManager(address(feeManager));
        centralRegistry.setOracleManager(address(oracleManager));
        firstCToken = new VerifyOptimizerShareDeScopeMockCToken(
            address(firstUnderlying)
        );
        secondCToken = new VerifyOptimizerShareDeScopeMockCToken(
            address(secondUnderlying)
        );
        firstVaultAggregator = new VerifyOptimizerShareDeScopeMockVaultAggregator(
            address(firstVault), address(firstUnderlying)
        );
        secondVaultAggregator = new VerifyOptimizerShareDeScopeMockVaultAggregator(
            address(secondVault), address(secondUnderlying)
        );
        firstLBP = new VerifyOptimizerShareDeScopeMockLBP(
            address(firstLBPPaymentToken)
        );
        secondLBP = new VerifyOptimizerShareDeScopeMockLBP(
            address(secondLBPPaymentToken)
        );
        lpRouteAsset = new VerifyOptimizerShareDeScopeMockToken();
        uniswapRouteAsset = new VerifyOptimizerShareDeScopeMockToken();
        pendleRouteAsset = new VerifyOptimizerShareDeScopeMockToken();
        lpRouteAdaptor = new VerifyOptimizerShareDeScopeMockLPAdaptor();
        uniswapRouteAdaptor =
            new VerifyOptimizerShareDeScopeMockUniswapAdaptor();
        pendleRouteAdaptor = new VerifyOptimizerShareDeScopeMockPendleAdaptor();

        oracleManager.setCToken(address(firstCToken), address(firstUnderlying));
        oracleManager.setCToken(
            address(secondCToken), address(secondUnderlying)
        );
        oracleManager.setPricingAdaptor(
            address(firstUnderlying), address(firstAllowedAdaptor)
        );
        oracleManager.setPricingAdaptor(
            address(secondUnderlying), address(secondAllowedAdaptor)
        );
        lpRouteAdaptor.setAssetConfig(
            address(lpRouteAsset),
            address(firstUnderlying),
            address(secondUnderlying)
        );
        uniswapRouteAdaptor.setAssetConfig(
            address(uniswapRouteAsset), address(firstUnderlying)
        );
        pendleRouteAdaptor.setAssetConfig(
            address(pendleRouteAsset), address(secondUnderlying)
        );
    }

    function test_verifyOptimizerShareDeScope_acceptsNoShareSupport()
        public
        view
    {
        script.verify(_config());
    }

    function test_verifyOptimizerShareDeScope_rejectsEmptyCTokenList() public {
        VerifyOptimizerShareDeScope.Config memory config = _config();
        config.marketCTokens = new address[](0);
        config.expectedMarketCTokenCount = 0;

        vm.expectRevert(
            VerifyOptimizerShareDeScope.VerifyOptimizerShareDeScope__InvalidConfig
                .selector
        );
        script.verify(config);
    }

    function test_verifyOptimizerShareDeScope_rejectsCTokenCountMismatch()
        public
    {
        VerifyOptimizerShareDeScope.Config memory config = _config();
        config.expectedMarketCTokenCount = config.marketCTokens.length + 1;

        vm.expectRevert(
            VerifyOptimizerShareDeScope.VerifyOptimizerShareDeScope__InvalidConfig
                .selector
        );
        script.verify(config);
    }

    function test_verifyOptimizerShareDeScope_rejectsDuplicateCToken() public {
        VerifyOptimizerShareDeScope.Config memory config = _config();
        config.marketCTokens[1] = config.marketCTokens[0];

        vm.expectRevert(
            VerifyOptimizerShareDeScope.VerifyOptimizerShareDeScope__InvalidConfig
                .selector
        );
        script.verify(config);
    }

    function test_verifyOptimizerShareDeScope_acceptsEmptyVaultAggregatorList()
        public
        view
    {
        VerifyOptimizerShareDeScope.Config memory config = _config();
        config.expectedVaultAggregatorCount = 0;
        config.vaultAggregators = new address[](0);

        script.verify(config);
    }

    function test_verifyOptimizerShareDeScope_rejectsVaultAggregatorCountMismatch()
        public
    {
        VerifyOptimizerShareDeScope.Config memory config = _config();
        config.expectedVaultAggregatorCount =
            config.vaultAggregators.length + 1;

        vm.expectRevert(
            VerifyOptimizerShareDeScope.VerifyOptimizerShareDeScope__InvalidConfig
                .selector
        );
        script.verify(config);
    }

    function test_verifyOptimizerShareDeScope_rejectsDuplicateVaultAggregator()
        public
    {
        VerifyOptimizerShareDeScope.Config memory config = _config();
        config.vaultAggregators[1] = config.vaultAggregators[0];

        vm.expectRevert(
            VerifyOptimizerShareDeScope.VerifyOptimizerShareDeScope__InvalidConfig
                .selector
        );
        script.verify(config);
    }

    function test_verifyOptimizerShareDeScope_rejectsVaultAggregatorWrappingOptimizer()
        public
    {
        firstVaultAggregator.setVault(address(optimizer));

        vm.expectRevert(
            VerifyOptimizerShareDeScope.VerifyOptimizerShareDeScope__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyOptimizerShareDeScope_rejectsVaultAggregatorAssetOptimizer()
        public
    {
        firstVaultAggregator.setAsset(address(optimizer));

        vm.expectRevert(
            VerifyOptimizerShareDeScope.VerifyOptimizerShareDeScope__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyOptimizerShareDeScope_rejectsVaultAggregatorZeroVault()
        public
    {
        firstVaultAggregator.setVault(address(0));

        vm.expectRevert(
            VerifyOptimizerShareDeScope.VerifyOptimizerShareDeScope__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyOptimizerShareDeScope_acceptsEmptyLBPList()
        public
        view
    {
        VerifyOptimizerShareDeScope.Config memory config = _config();
        config.expectedLBPCount = 0;
        config.lbps = new address[](0);

        script.verify(config);
    }

    function test_verifyOptimizerShareDeScope_rejectsLBPCountMismatch()
        public
    {
        VerifyOptimizerShareDeScope.Config memory config = _config();
        config.expectedLBPCount = config.lbps.length + 1;

        vm.expectRevert(
            VerifyOptimizerShareDeScope.VerifyOptimizerShareDeScope__InvalidConfig
                .selector
        );
        script.verify(config);
    }

    function test_verifyOptimizerShareDeScope_rejectsDuplicateLBP() public {
        VerifyOptimizerShareDeScope.Config memory config = _config();
        config.lbps[1] = config.lbps[0];

        vm.expectRevert(
            VerifyOptimizerShareDeScope.VerifyOptimizerShareDeScope__InvalidConfig
                .selector
        );
        script.verify(config);
    }

    function test_verifyOptimizerShareDeScope_rejectsLBPPaymentTokenOptimizer()
        public
    {
        firstLBP.setPaymentToken(address(optimizer));

        vm.expectRevert(
            VerifyOptimizerShareDeScope.VerifyOptimizerShareDeScope__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyOptimizerShareDeScope_rejectsRegistryFeeTokenOptimizer()
        public
    {
        centralRegistry.setFeeToken(address(optimizer));

        vm.expectRevert(
            VerifyOptimizerShareDeScope.VerifyOptimizerShareDeScope__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyOptimizerShareDeScope_acceptsZeroRegistryFeeManager()
        public
    {
        centralRegistry.setFeeManager(address(0));

        script.verify(_config());
    }

    function test_verifyOptimizerShareDeScope_rejectsOptimizerRewardToken()
        public
    {
        feeManager.setRewardToken(address(optimizer), true);

        vm.expectRevert(
            VerifyOptimizerShareDeScope.VerifyOptimizerShareDeScope__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyOptimizerShareDeScope_rejectsOptimizerEarmarkedForOTC()
        public
    {
        feeManager.setForOTC(address(optimizer), true);

        vm.expectRevert(
            VerifyOptimizerShareDeScope.VerifyOptimizerShareDeScope__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyOptimizerShareDeScope_acceptsMissingCentralRegistry()
        public
        view
    {
        VerifyOptimizerShareDeScope.Config memory config = _config();
        config.centralRegistry = address(0);

        script.verify(config);
    }

    function test_verifyOptimizerShareDeScope_rejectsOptimizerRegistryMismatch()
        public
    {
        VerifyOptimizerShareDeScopeMockCentralRegistry otherRegistry = new VerifyOptimizerShareDeScopeMockCentralRegistry(
            address(feeToken)
        );
        otherRegistry.setOracleManager(address(oracleManager));
        optimizer.setCentralRegistry(address(otherRegistry));

        vm.expectRevert(
            VerifyOptimizerShareDeScope.VerifyOptimizerShareDeScope__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyOptimizerShareDeScope_rejectsRegistryOracleManagerMismatch()
        public
    {
        VerifyOptimizerShareDeScopeMockOracleManager otherOracleManager =
            new VerifyOptimizerShareDeScopeMockOracleManager();
        centralRegistry.setOracleManager(address(otherOracleManager));

        vm.expectRevert(
            VerifyOptimizerShareDeScope.VerifyOptimizerShareDeScope__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyOptimizerShareDeScope_rejectsLPRouteOptimizerLeg()
        public
    {
        lpRouteAdaptor.setAssetConfig(
            address(lpRouteAsset),
            address(optimizer),
            address(secondUnderlying)
        );

        vm.expectRevert(
            VerifyOptimizerShareDeScope.VerifyOptimizerShareDeScope__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyOptimizerShareDeScope_rejectsUniswapRouteOptimizerQuote()
        public
    {
        uniswapRouteAdaptor.setAssetConfig(
            address(uniswapRouteAsset), address(optimizer)
        );

        vm.expectRevert(
            VerifyOptimizerShareDeScope.VerifyOptimizerShareDeScope__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyOptimizerShareDeScope_rejectsPendleRouteOptimizerQuote()
        public
    {
        pendleRouteAdaptor.setAssetConfig(
            address(pendleRouteAsset), address(optimizer)
        );

        vm.expectRevert(
            VerifyOptimizerShareDeScope.VerifyOptimizerShareDeScope__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyOptimizerShareDeScope_rejectsRouteCountMismatch()
        public
    {
        VerifyOptimizerShareDeScope.Config memory config = _config();
        config.expectedLPRouteCount = config.lpRouteAssets.length + 1;

        vm.expectRevert(
            VerifyOptimizerShareDeScope.VerifyOptimizerShareDeScope__InvalidConfig
                .selector
        );
        script.verify(config);
    }

    function test_verifyOptimizerShareDeScope_acceptsEmptyAllowedPricingAdaptorList()
        public
        view
    {
        VerifyOptimizerShareDeScope.Config memory config = _config();
        config.expectedAllowedPricingAdaptorCount = 0;
        config.allowedPricingAdaptors = new address[](0);

        script.verify(config);
    }

    function test_verifyOptimizerShareDeScope_rejectsAllowedPricingAdaptorCountMismatch()
        public
    {
        VerifyOptimizerShareDeScope.Config memory config = _config();
        config.expectedAllowedPricingAdaptorCount =
            config.allowedPricingAdaptors.length + 1;

        vm.expectRevert(
            VerifyOptimizerShareDeScope.VerifyOptimizerShareDeScope__InvalidConfig
                .selector
        );
        script.verify(config);
    }

    function test_verifyOptimizerShareDeScope_rejectsMissingPricingAdaptor()
        public
    {
        oracleManager.clearPricingAdaptors(address(firstUnderlying));

        vm.expectRevert(
            VerifyOptimizerShareDeScope.VerifyOptimizerShareDeScope__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyOptimizerShareDeScope_rejectsUnexpectedPricingAdaptor()
        public
    {
        oracleManager.setPricingAdaptor(
            address(firstUnderlying), address(unexpectedAdaptor)
        );

        vm.expectRevert(
            VerifyOptimizerShareDeScope.VerifyOptimizerShareDeScope__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyOptimizerShareDeScope_rejectsCTokenUnderlyingOptimizer()
        public
    {
        firstCToken.setAsset(address(optimizer));
        oracleManager.setCToken(address(firstCToken), address(optimizer));

        vm.expectRevert(
            VerifyOptimizerShareDeScope.VerifyOptimizerShareDeScope__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyOptimizerShareDeScope_rejectsOracleMappingOptimizer()
        public
    {
        oracleManager.setCToken(address(firstCToken), address(optimizer));

        vm.expectRevert(
            VerifyOptimizerShareDeScope.VerifyOptimizerShareDeScope__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyOptimizerShareDeScope_rejectsOracleMappingMismatch()
        public
    {
        oracleManager.setCToken(
            address(firstCToken), address(secondUnderlying)
        );

        vm.expectRevert(
            VerifyOptimizerShareDeScope.VerifyOptimizerShareDeScope__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyOptimizerShareDeScope_rejectsOptimizerRegisteredAsCToken()
        public
    {
        oracleManager.setCToken(address(optimizer), address(firstUnderlying));

        vm.expectRevert(
            VerifyOptimizerShareDeScope.VerifyOptimizerShareDeScope__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyOptimizerShareDeScope_rejectsOptimizerSupportedAsset()
        public
    {
        oracleManager.setSupportedAsset(address(optimizer), true);

        vm.expectRevert(
            VerifyOptimizerShareDeScope.VerifyOptimizerShareDeScope__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyOptimizerShareDeScope_runReadsEnvTuple() public {
        vm.setEnv("OPTIMIZER_DESCOPE_ADDRESS", vm.toString(address(optimizer)));
        vm.setEnv(
            "OPTIMIZER_DESCOPE_ORACLE_MANAGER",
            vm.toString(address(oracleManager))
        );
        vm.setEnv(
            "OPTIMIZER_DESCOPE_CENTRAL_REGISTRY",
            vm.toString(address(centralRegistry))
        );
        vm.setEnv("OPTIMIZER_DESCOPE_MARKET_CTOKEN_COUNT", "2");
        vm.setEnv("OPTIMIZER_DESCOPE_ALLOWED_PRICING_ADAPTOR_COUNT", "2");
        vm.setEnv("OPTIMIZER_DESCOPE_VAULT_AGGREGATOR_COUNT", "2");
        vm.setEnv("OPTIMIZER_DESCOPE_LBP_COUNT", "2");
        vm.setEnv("OPTIMIZER_DESCOPE_LP_ROUTE_COUNT", "1");
        vm.setEnv("OPTIMIZER_DESCOPE_UNISWAP_ROUTE_COUNT", "1");
        vm.setEnv("OPTIMIZER_DESCOPE_PENDLE_ROUTE_COUNT", "1");
        vm.setEnv(
            "OPTIMIZER_DESCOPE_MARKET_CTOKENS",
            string.concat(
                vm.toString(address(firstCToken)),
                ",",
                vm.toString(address(secondCToken))
            )
        );
        vm.setEnv(
            "OPTIMIZER_DESCOPE_ALLOWED_PRICING_ADAPTORS",
            string.concat(
                vm.toString(address(firstAllowedAdaptor)),
                ",",
                vm.toString(address(secondAllowedAdaptor))
            )
        );
        vm.setEnv(
            "OPTIMIZER_DESCOPE_VAULT_AGGREGATORS",
            string.concat(
                vm.toString(address(firstVaultAggregator)),
                ",",
                vm.toString(address(secondVaultAggregator))
            )
        );
        vm.setEnv(
            "OPTIMIZER_DESCOPE_LBPS",
            string.concat(
                vm.toString(address(firstLBP)),
                ",",
                vm.toString(address(secondLBP))
            )
        );
        vm.setEnv(
            "OPTIMIZER_DESCOPE_LP_ROUTE_ADAPTORS",
            vm.toString(address(lpRouteAdaptor))
        );
        vm.setEnv(
            "OPTIMIZER_DESCOPE_LP_ROUTE_ASSETS",
            vm.toString(address(lpRouteAsset))
        );
        vm.setEnv(
            "OPTIMIZER_DESCOPE_UNISWAP_ROUTE_ADAPTORS",
            vm.toString(address(uniswapRouteAdaptor))
        );
        vm.setEnv(
            "OPTIMIZER_DESCOPE_UNISWAP_ROUTE_ASSETS",
            vm.toString(address(uniswapRouteAsset))
        );
        vm.setEnv(
            "OPTIMIZER_DESCOPE_PENDLE_ROUTE_ADAPTORS",
            vm.toString(address(pendleRouteAdaptor))
        );
        vm.setEnv(
            "OPTIMIZER_DESCOPE_PENDLE_ROUTE_ASSETS",
            vm.toString(address(pendleRouteAsset))
        );

        script.run();
    }

    function _config()
        internal
        view
        returns (VerifyOptimizerShareDeScope.Config memory config)
    {
        config = VerifyOptimizerShareDeScope.Config({
            optimizer: address(optimizer),
            centralRegistry: address(centralRegistry),
            oracleManager: address(oracleManager),
            expectedAllowedPricingAdaptorCount: 2,
            allowedPricingAdaptors: _allowedPricingAdaptors(),
            expectedMarketCTokenCount: 2,
            marketCTokens: _marketCTokens(),
            expectedVaultAggregatorCount: 2,
            vaultAggregators: _vaultAggregators(),
            expectedLBPCount: 2,
            lbps: _lbps(),
            expectedLPRouteCount: 1,
            lpRouteAdaptors: _singleAddress(address(lpRouteAdaptor)),
            lpRouteAssets: _singleAddress(address(lpRouteAsset)),
            expectedUniswapRouteCount: 1,
            uniswapRouteAdaptors: _singleAddress(address(uniswapRouteAdaptor)),
            uniswapRouteAssets: _singleAddress(address(uniswapRouteAsset)),
            expectedPendleRouteCount: 1,
            pendleRouteAdaptors: _singleAddress(address(pendleRouteAdaptor)),
            pendleRouteAssets: _singleAddress(address(pendleRouteAsset))
        });
    }

    function _allowedPricingAdaptors()
        internal
        view
        returns (address[] memory allowedPricingAdaptors)
    {
        allowedPricingAdaptors = new address[](2);
        allowedPricingAdaptors[0] = address(firstAllowedAdaptor);
        allowedPricingAdaptors[1] = address(secondAllowedAdaptor);
    }

    function _marketCTokens()
        internal
        view
        returns (address[] memory marketCTokens)
    {
        marketCTokens = new address[](2);
        marketCTokens[0] = address(firstCToken);
        marketCTokens[1] = address(secondCToken);
    }

    function _vaultAggregators()
        internal
        view
        returns (address[] memory vaultAggregators)
    {
        vaultAggregators = new address[](2);
        vaultAggregators[0] = address(firstVaultAggregator);
        vaultAggregators[1] = address(secondVaultAggregator);
    }

    function _lbps() internal view returns (address[] memory lbps) {
        lbps = new address[](2);
        lbps[0] = address(firstLBP);
        lbps[1] = address(secondLBP);
    }

    function _singleAddress(address value)
        internal
        pure
        returns (address[] memory values)
    {
        values = new address[](1);
        values[0] = value;
    }
}
