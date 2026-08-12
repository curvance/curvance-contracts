// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    VerifyLendingOptimizerLaunch
} from "script/deployment/VerifyLendingOptimizerLaunch.s.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {ICToken} from "contracts/interfaces/ICToken.sol";
import {IERC165} from "contracts/interfaces/IERC165.sol";
import {IMarketManager} from "contracts/interfaces/IMarketManager.sol";

contract VerifyLendingOptimizerLaunchMockRegistry {
    mapping(address => bool) public isMarketManager;

    function setMarketManager(address marketManager, bool isRegistered)
        external
    {
        isMarketManager[marketManager] = isRegistered;
    }
}

contract VerifyLendingOptimizerLaunchMockToken {}

contract VerifyLendingOptimizerLaunchMockUnknownReceipt {
    address public asset;

    constructor(address asset_) {
        asset = asset_;
    }
}

contract VerifyLendingOptimizerLaunchMockUnderlyingWrapper {
    address public underlying;

    constructor(address underlying_) {
        underlying = underlying_;
    }
}

contract VerifyLendingOptimizerLaunchMockLPToken {
    address public token0;
    address public token1;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }
}

contract VerifyLendingOptimizerLaunchMockToken1Dependency {
    address public token1;

    constructor(address token1_) {
        token1 = token1_;
    }
}

contract VerifyLendingOptimizerLaunchMockMarketManager {
    mapping(address => bool) public isListed;
    mapping(address => bool) internal omittedFromQuery;
    address[] internal listedTokens;

    function addListedToken(address cToken) external {
        isListed[cToken] = true;
        listedTokens.push(cToken);
    }

    function setOmittedFromQuery(address cToken, bool isOmitted) external {
        omittedFromQuery[cToken] = isOmitted;
    }

    function queryTokensListed()
        external
        view
        returns (address[] memory result)
    {
        uint256 numListedTokens = listedTokens.length;
        uint256 resultLength;
        for (uint256 i; i < numListedTokens; ++i) {
            if (!omittedFromQuery[listedTokens[i]]) {
                ++resultLength;
            }
        }

        result = new address[](resultLength);
        uint256 resultIndex;
        for (uint256 i; i < numListedTokens; ++i) {
            address listedToken = listedTokens[i];
            if (!omittedFromQuery[listedToken]) {
                result[resultIndex++] = listedToken;
            }
        }
    }
}

contract VerifyLendingOptimizerLaunchMockCToken {
    address public asset;
    IMarketManager public marketManager;
    bool public isBorrowable = true;

    constructor(address asset_, IMarketManager marketManager_) {
        asset = asset_;
        marketManager = marketManager_;
    }

    function setAsset(address asset_) external {
        asset = asset_;
    }

    function setIsBorrowable(bool isBorrowable_) external {
        isBorrowable = isBorrowable_;
    }

    function supportsInterface(bytes4 interfaceId)
        external
        pure
        returns (bool)
    {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(ICToken).interfaceId;
    }
}

contract VerifyLendingOptimizerLaunchMockOptimizer {
    string public name;
    string public symbol;
    address public asset;
    ICentralRegistry public centralRegistry;
    uint256 public fee;
    address[] public approvedCTokensList;
    mapping(address => uint256) public allocationCaps;

    constructor(
        string memory name_,
        string memory symbol_,
        address asset_,
        ICentralRegistry centralRegistry_,
        uint256 fee_,
        address[] memory markets,
        uint256[] memory caps
    ) {
        name = name_;
        symbol = symbol_;
        asset = asset_;
        centralRegistry = centralRegistry_;
        fee = fee_;
        approvedCTokensList = markets;

        uint256 numMarkets = markets.length;
        for (uint256 i; i < numMarkets; ++i) {
            allocationCaps[markets[i]] = caps[i];
        }
    }

    function setName(string calldata name_) external {
        name = name_;
    }

    function setSymbol(string calldata symbol_) external {
        symbol = symbol_;
    }

    function setAsset(address asset_) external {
        asset = asset_;
    }

    function setCentralRegistry(ICentralRegistry centralRegistry_) external {
        centralRegistry = centralRegistry_;
    }

    function setFee(uint256 fee_) external {
        fee = fee_;
    }

    function setAllocationCap(address market, uint256 cap) external {
        allocationCaps[market] = cap;
    }

    function setApprovedMarket(uint256 index, address market) external {
        approvedCTokensList[index] = market;
    }

    function numApprovedMarkets() external view returns (uint256) {
        return approvedCTokensList.length;
    }
}

contract TestVerifyLendingOptimizerLaunch is Test {
    uint256 internal constant FIRST_CAP = 0.9e18;
    uint256 internal constant SECOND_CAP = 0.2e18;
    uint256 internal constant GRAPH_NODE_LIMIT = 64;

    VerifyLendingOptimizerLaunch internal script;
    VerifyLendingOptimizerLaunchMockToken internal underlying;
    VerifyLendingOptimizerLaunchMockToken internal otherUnderlying;
    VerifyLendingOptimizerLaunchMockRegistry internal registry;
    VerifyLendingOptimizerLaunchMockRegistry internal otherRegistry;
    VerifyLendingOptimizerLaunchMockMarketManager internal marketManager;
    VerifyLendingOptimizerLaunchMockMarketManager internal otherMarketManager;
    VerifyLendingOptimizerLaunchMockCToken internal firstMarket;
    VerifyLendingOptimizerLaunchMockCToken internal secondMarket;
    VerifyLendingOptimizerLaunchMockOptimizer internal optimizer;

    function setUp() public {
        script = new VerifyLendingOptimizerLaunch();
        underlying = new VerifyLendingOptimizerLaunchMockToken();
        otherUnderlying = new VerifyLendingOptimizerLaunchMockToken();
        registry = new VerifyLendingOptimizerLaunchMockRegistry();
        otherRegistry = new VerifyLendingOptimizerLaunchMockRegistry();
        marketManager = new VerifyLendingOptimizerLaunchMockMarketManager();
        otherMarketManager =
            new VerifyLendingOptimizerLaunchMockMarketManager();
        registry.setMarketManager(address(marketManager), true);
        registry.setMarketManager(address(otherMarketManager), true);
        firstMarket = _deployListedCToken(address(underlying), marketManager);
        secondMarket = _deployListedCToken(address(underlying), marketManager);
        _deployListedCToken(address(otherUnderlying), marketManager);

        optimizer = new VerifyLendingOptimizerLaunchMockOptimizer(
            "High Yield AUSD Vault",
            "hyAUSD",
            address(underlying),
            ICentralRegistry(address(registry)),
            0,
            _markets(),
            _caps()
        );
    }

    function test_verifyLendingOptimizerLaunch_acceptsExpectedConfig() public {
        script.verify(_config());
    }

    function test_verifyLendingOptimizerLaunch_acceptsOrdinaryTerminalSibling()
        public
    {
        _deployListedCToken(address(otherUnderlying), marketManager);

        script.verify(_config());
    }

    function test_verifyLendingOptimizerLaunch_rejectsDirectOptimizerSibling()
        public
    {
        _deployListedCToken(address(optimizer), marketManager);

        _expectInvalidConfig();
        script.verify(_config());
    }

    function test_verifyLendingOptimizerLaunch_rejectsNestedOptimizerAncestry()
        public
    {
        VerifyLendingOptimizerLaunchMockCToken innerReceipt =
            _deployListedCToken(address(optimizer), otherMarketManager);
        _deployListedCToken(address(innerReceipt), marketManager);

        _expectInvalidConfig();
        script.verify(_config());
    }

    function test_verifyLendingOptimizerLaunch_rejectsTransitiveSiblingMarketOptimizerDependency()
        public
    {
        // D1 (approved) -> sibling C1 -> asset B2. B2 itself terminates in a
        // plain asset, but its separate market sibling C2 reaches optimizer.
        VerifyLendingOptimizerLaunchMockCToken borrowableB2 =
            _deployListedCToken(address(otherUnderlying), otherMarketManager);
        _deployListedCToken(address(optimizer), otherMarketManager);
        _deployListedCToken(address(borrowableB2), marketManager);

        _expectInvalidConfig();
        script.verify(_config());
    }

    function test_verifyLendingOptimizerLaunch_acceptsConnectedSiblingBackedges()
        public
    {
        VerifyLendingOptimizerLaunchMockCToken borrowableB2 =
            _deployListedCToken(address(otherUnderlying), otherMarketManager);
        _deployListedCToken(address(otherUnderlying), otherMarketManager);
        _deployListedCToken(address(borrowableB2), marketManager);

        script.verify(_config());
    }

    function test_verifyLendingOptimizerLaunch_rejectsReceiptCycle() public {
        VerifyLendingOptimizerLaunchMockCToken innerReceipt =
            _deployListedCToken(address(otherUnderlying), otherMarketManager);
        VerifyLendingOptimizerLaunchMockCToken outerReceipt =
            _deployListedCToken(address(innerReceipt), marketManager);
        innerReceipt.setAsset(address(outerReceipt));

        _expectInvalidConfig();
        script.verify(_config());
    }

    function test_verifyLendingOptimizerLaunch_rejectsExcessiveReceiptDepth()
        public
    {
        address current = address(otherUnderlying);
        for (uint256 i; i < 8; ++i) {
            current = address(_deployListedCToken(current, otherMarketManager));
        }
        _deployListedCToken(current, marketManager);

        _expectInvalidConfig();
        script.verify(_config());
    }

    function test_verifyLendingOptimizerLaunch_rejectsGraphNodeOverflow()
        public
    {
        // Three cTokens are listed in setUp. Add enough unique siblings to
        // exceed the verifier's global graph-node bound by one.
        for (uint256 i; i < GRAPH_NODE_LIMIT - 2; ++i) {
            _deployListedCToken(address(otherUnderlying), marketManager);
        }

        _expectInvalidConfig();
        script.verify(_config());
    }

    function test_verifyLendingOptimizerLaunch_acceptsMaximumReceiptDepth()
        public
    {
        address current = address(otherUnderlying);
        for (uint256 i; i < 7; ++i) {
            current = address(_deployListedCToken(current, otherMarketManager));
        }
        _deployListedCToken(current, marketManager);

        script.verify(_config());
    }

    function test_verifyLendingOptimizerLaunch_rejectsUnknownReceiptAncestry()
        public
    {
        VerifyLendingOptimizerLaunchMockUnknownReceipt unknownReceipt = new VerifyLendingOptimizerLaunchMockUnknownReceipt(
            address(otherUnderlying)
        );
        _deployListedCToken(address(unknownReceipt), marketManager);

        _expectInvalidConfig();
        script.verify(_config());
    }

    function test_verifyLendingOptimizerLaunch_rejectsReceiptAsTerminalAsset()
        public
    {
        VerifyLendingOptimizerLaunchMockUnknownReceipt unknownReceipt = new VerifyLendingOptimizerLaunchMockUnknownReceipt(
            address(otherUnderlying)
        );
        VerifyLendingOptimizerLaunch.Config memory config = _config();
        config.expectedTerminalAssets[0] = address(unknownReceipt);

        _expectInvalidConfig();
        script.verify(config);
    }

    function test_verifyLendingOptimizerLaunch_rejectsZeroAssetReceiptAsTerminal()
        public
    {
        VerifyLendingOptimizerLaunchMockUnknownReceipt unknownReceipt =
            new VerifyLendingOptimizerLaunchMockUnknownReceipt(address(0));
        VerifyLendingOptimizerLaunch.Config memory config = _config();
        config.expectedTerminalAssets[0] = address(unknownReceipt);

        _expectInvalidConfig();
        script.verify(config);
    }

    function test_verifyLendingOptimizerLaunch_rejectsUnderlyingWrapperAsTerminal()
        public
    {
        VerifyLendingOptimizerLaunchMockUnderlyingWrapper wrapper = new VerifyLendingOptimizerLaunchMockUnderlyingWrapper(
            address(otherUnderlying)
        );
        VerifyLendingOptimizerLaunch.Config memory config = _config();
        config.expectedTerminalAssets[0] = address(wrapper);

        _expectInvalidConfig();
        script.verify(config);
    }

    function test_verifyLendingOptimizerLaunch_rejectsLPTokenAsTerminal()
        public
    {
        VerifyLendingOptimizerLaunchMockLPToken lpToken = new VerifyLendingOptimizerLaunchMockLPToken(
            address(underlying), address(otherUnderlying)
        );
        VerifyLendingOptimizerLaunch.Config memory config = _config();
        config.expectedTerminalAssets[0] = address(lpToken);

        _expectInvalidConfig();
        script.verify(config);
    }

    function test_verifyLendingOptimizerLaunch_rejectsToken1DependencyAsTerminal()
        public
    {
        VerifyLendingOptimizerLaunchMockToken1Dependency dependency = new VerifyLendingOptimizerLaunchMockToken1Dependency(
            address(otherUnderlying)
        );
        VerifyLendingOptimizerLaunch.Config memory config = _config();
        config.expectedTerminalAssets[0] = address(dependency);

        _expectInvalidConfig();
        script.verify(config);
    }

    function test_verifyLendingOptimizerLaunch_rejectsNonBorrowableApprovedMarket()
        public
    {
        firstMarket.setIsBorrowable(false);

        _expectInvalidConfig();
        script.verify(_config());
    }

    function test_verifyLendingOptimizerLaunch_rejectsUnregisteredMarketManager()
        public
    {
        registry.setMarketManager(address(marketManager), false);

        _expectInvalidConfig();
        script.verify(_config());
    }

    function test_verifyLendingOptimizerLaunch_rejectsListedTokenManagerMismatch()
        public
    {
        VerifyLendingOptimizerLaunchMockCToken foreignToken =
            _deployListedCToken(address(otherUnderlying), otherMarketManager);
        marketManager.addListedToken(address(foreignToken));

        _expectInvalidConfig();
        script.verify(_config());
    }

    function test_verifyLendingOptimizerLaunch_rejectsApprovedMarketOmittedFromQuery()
        public
    {
        marketManager.setOmittedFromQuery(address(firstMarket), true);

        _expectInvalidConfig();
        script.verify(_config());
    }

    function test_verifyLendingOptimizerLaunch_rejectsOptimizerTerminalAttestation()
        public
    {
        VerifyLendingOptimizerLaunch.Config memory config = _config();
        config.expectedTerminalAssets[0] = address(optimizer);

        _expectInvalidConfig();
        script.verify(config);
    }

    function test_verifyLendingOptimizerLaunch_rejectsZeroTerminalAttestation()
        public
    {
        VerifyLendingOptimizerLaunch.Config memory config = _config();
        config.expectedTerminalAssets[0] = address(0);

        _expectInvalidConfig();
        script.verify(config);
    }

    function test_verifyLendingOptimizerLaunch_rejectsDuplicateTerminalAttestation()
        public
    {
        VerifyLendingOptimizerLaunch.Config memory config = _config();
        config.expectedTerminalAssets = new address[](2);
        config.expectedTerminalAssets[0] = address(otherUnderlying);
        config.expectedTerminalAssets[1] = address(otherUnderlying);

        _expectInvalidConfig();
        script.verify(config);
    }

    function test_verifyLendingOptimizerLaunch_rejectsUnderlyingDuplicatedAsTerminal()
        public
    {
        VerifyLendingOptimizerLaunch.Config memory config = _config();
        config.expectedTerminalAssets[0] = address(underlying);

        _expectInvalidConfig();
        script.verify(config);
    }

    function test_verifyLendingOptimizerLaunch_rejectsUnusedTerminalAttestation()
        public
    {
        VerifyLendingOptimizerLaunchMockToken unusedTerminal =
            new VerifyLendingOptimizerLaunchMockToken();
        VerifyLendingOptimizerLaunch.Config memory config = _config();
        config.expectedTerminalAssets = new address[](2);
        config.expectedTerminalAssets[0] = address(otherUnderlying);
        config.expectedTerminalAssets[1] = address(unusedTerminal);

        _expectInvalidConfig();
        script.verify(config);
    }

    function test_verifyLendingOptimizerLaunch_rejectsWrongName() public {
        optimizer.setName("AUSD-Test");

        vm.expectRevert(
            VerifyLendingOptimizerLaunch.VerifyLendingOptimizerLaunch__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyLendingOptimizerLaunch_rejectsWrongSymbol() public {
        optimizer.setSymbol("badAUSD");

        vm.expectRevert(
            VerifyLendingOptimizerLaunch.VerifyLendingOptimizerLaunch__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyLendingOptimizerLaunch_rejectsWrongUnderlying()
        public
    {
        optimizer.setAsset(address(otherUnderlying));

        vm.expectRevert(
            VerifyLendingOptimizerLaunch.VerifyLendingOptimizerLaunch__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyLendingOptimizerLaunch_rejectsWrongRegistry() public {
        optimizer.setCentralRegistry(ICentralRegistry(address(otherRegistry)));

        vm.expectRevert(
            VerifyLendingOptimizerLaunch.VerifyLendingOptimizerLaunch__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyLendingOptimizerLaunch_rejectsFeeMismatch() public {
        optimizer.setFee(100);

        vm.expectRevert(
            VerifyLendingOptimizerLaunch.VerifyLendingOptimizerLaunch__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyLendingOptimizerLaunch_rejectsMarketCountMismatch()
        public
    {
        VerifyLendingOptimizerLaunch.Config memory config = _config();
        address[] memory markets = new address[](1);
        markets[0] = address(firstMarket);
        uint256[] memory caps = new uint256[](1);
        caps[0] = FIRST_CAP;
        config.expectedMarkets = markets;
        config.expectedAllocationCapsWad = caps;

        vm.expectRevert(
            VerifyLendingOptimizerLaunch.VerifyLendingOptimizerLaunch__InvalidConfig
                .selector
        );
        script.verify(config);
    }

    function test_verifyLendingOptimizerLaunch_rejectsMarketOrderMismatch()
        public
    {
        VerifyLendingOptimizerLaunch.Config memory config = _config();
        config.expectedMarkets[0] = address(secondMarket);
        config.expectedMarkets[1] = address(firstMarket);

        vm.expectRevert(
            VerifyLendingOptimizerLaunch.VerifyLendingOptimizerLaunch__InvalidConfig
                .selector
        );
        script.verify(config);
    }

    function test_verifyLendingOptimizerLaunch_rejectsAllocationCapMismatch()
        public
    {
        optimizer.setAllocationCap(address(firstMarket), FIRST_CAP - 1);

        vm.expectRevert(
            VerifyLendingOptimizerLaunch.VerifyLendingOptimizerLaunch__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyLendingOptimizerLaunch_rejectsMarketUnderlyingMismatch()
        public
    {
        firstMarket.setAsset(address(otherUnderlying));

        vm.expectRevert(
            VerifyLendingOptimizerLaunch.VerifyLendingOptimizerLaunch__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyLendingOptimizerLaunch_rejectsInsufficientExpectedCaps()
        public
    {
        optimizer.setAllocationCap(address(firstMarket), 0.4e18);
        optimizer.setAllocationCap(address(secondMarket), 0.5e18);

        VerifyLendingOptimizerLaunch.Config memory config = _config();
        config.expectedAllocationCapsWad[0] = 0.4e18;
        config.expectedAllocationCapsWad[1] = 0.5e18;

        vm.expectRevert(
            VerifyLendingOptimizerLaunch.VerifyLendingOptimizerLaunch__InvalidConfig
                .selector
        );
        script.verify(config);
    }

    function test_verifyLendingOptimizerLaunch_runReadsEnvTuple() public {
        vm.setEnv("LENDING_OPTIMIZER_ADDRESS", vm.toString(address(optimizer)));
        vm.setEnv("LENDING_OPTIMIZER_NAME", "High Yield AUSD Vault");
        vm.setEnv("LENDING_OPTIMIZER_SYMBOL", "hyAUSD");
        vm.setEnv(
            "LENDING_OPTIMIZER_UNDERLYING", vm.toString(address(underlying))
        );
        vm.setEnv(
            "LENDING_OPTIMIZER_CENTRAL_REGISTRY",
            vm.toString(address(registry))
        );
        vm.setEnv("LENDING_OPTIMIZER_FEE_BPS", "0");
        vm.setEnv(
            "LENDING_OPTIMIZER_MARKETS",
            string.concat(
                vm.toString(address(firstMarket)),
                ",",
                vm.toString(address(secondMarket))
            )
        );
        vm.setEnv(
            "LENDING_OPTIMIZER_ALLOCATION_CAPS_WAD",
            "900000000000000000,200000000000000000"
        );
        vm.setEnv(
            "LENDING_OPTIMIZER_TERMINAL_ASSETS",
            vm.toString(address(otherUnderlying))
        );

        script.run();
    }

    function _config()
        internal
        view
        returns (VerifyLendingOptimizerLaunch.Config memory config)
    {
        config = VerifyLendingOptimizerLaunch.Config({
            optimizer: address(optimizer),
            expectedName: "High Yield AUSD Vault",
            expectedSymbol: "hyAUSD",
            expectedUnderlying: address(underlying),
            expectedCentralRegistry: address(registry),
            expectedFeeBps: 0,
            expectedMarkets: _markets(),
            expectedAllocationCapsWad: _caps(),
            expectedTerminalAssets: _terminalAssets()
        });
    }

    function _deployListedCToken(
        address asset,
        VerifyLendingOptimizerLaunchMockMarketManager manager
    ) internal returns (VerifyLendingOptimizerLaunchMockCToken cToken) {
        cToken = new VerifyLendingOptimizerLaunchMockCToken(
            asset, IMarketManager(address(manager))
        );
        manager.addListedToken(address(cToken));
    }

    function _expectInvalidConfig() internal {
        vm.expectRevert(
            VerifyLendingOptimizerLaunch.VerifyLendingOptimizerLaunch__InvalidConfig
                .selector
        );
    }

    function _markets() internal view returns (address[] memory markets) {
        markets = new address[](2);
        markets[0] = address(firstMarket);
        markets[1] = address(secondMarket);
    }

    function _caps() internal pure returns (uint256[] memory caps) {
        caps = new uint256[](2);
        caps[0] = FIRST_CAP;
        caps[1] = SECOND_CAP;
    }

    function _terminalAssets()
        internal
        view
        returns (address[] memory terminalAssets)
    {
        terminalAssets = new address[](1);
        terminalAssets[0] = address(otherUnderlying);
    }
}
