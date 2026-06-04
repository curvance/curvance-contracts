// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";

import { AddCombinedAggregator } from "script/deployment/AddCombinedAggregator.s.sol";
import { CombinedAggregator } from "contracts/oracles/adaptors/wrappedAggregators/CombinedAggregator.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract AddCombinedAggregatorHarness is AddCombinedAggregator {
    modifier recordEvents() override {
        _;
    }
}

contract AddCombinedAggregatorBroadcastHarness is AddCombinedAggregator {
    address internal immutable broadcastCaller;

    constructor(address broadcastCaller_) {
        broadcastCaller = broadcastCaller_;
    }

    modifier recordEvents() override {
        vm.startPrank(broadcastCaller);
        _;
        vm.stopPrank();
    }
}

contract AddCombinedAggregatorRecordedHarness is AddCombinedAggregator {
    string internal _testDirectory;
    string internal _testFile;

    constructor(
        string memory testDirectory,
        string memory testFile
    ) {
        _testDirectory = testDirectory;
        _testFile = testFile;
    }

    function defaultBroadcastCaller() external returns (address caller) {
        vm.startBroadcast();
        (, caller, ) = vm.readCallers();
        vm.stopBroadcast();
    }

    function _deploymentFilePath() internal view override returns (string memory) {
        return _testFile;
    }

    function _deploymentDirectoryPath() internal view override returns (string memory) {
        return _testDirectory;
    }
}

contract AddCombinedAggregatorRegistry {
    address public immutable oracleManager;
    bool public permissionsOpen = true;
    mapping(address => bool) public hasElevatedPermission;
    mapping(address => bool) public hasMarketPermission;

    constructor(address oracleManager_) {
        oracleManager = oracleManager_;
    }

    function setPermissionsOpen(bool value) external {
        permissionsOpen = value;
    }

    function setElevatedPermission(address account, bool value) external {
        hasElevatedPermission[account] = value;
    }

    function setMarketPermission(address account, bool value) external {
        hasMarketPermission[account] = value;
    }

    function hasElevatedPermissions(
        address account
    ) external view returns (bool) {
        return permissionsOpen || hasElevatedPermission[account];
    }

    function hasMarketPermissions(
        address account
    ) external view returns (bool) {
        return permissionsOpen || hasMarketPermission[account];
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 ||
            interfaceId == type(ICentralRegistry).interfaceId;
    }
}

contract AddCombinedAggregatorOracleManager {
    mapping(address => address[]) internal _pricingAdaptors;

    function setPricingAdaptors(
        address asset,
        address[] memory adaptors
    ) external {
        _pricingAdaptors[asset] = adaptors;
    }

    function getPricingAdaptors(
        address asset
    ) external view returns (address[] memory) {
        return _pricingAdaptors[asset];
    }
}

contract AddCombinedAggregatorAdaptor {
    mapping(address => mapping(bool => bool)) public guardDisabled;
    mapping(address => address) public aggregatorForAsset;
    mapping(address => uint256) public heartbeatForAsset;
    bool public revertOnAddAsset;

    function setRevertOnAddAsset(bool value) external {
        revertOnAddAsset = value;
    }

    function disableGuardedPriceConfig(address asset, bool inUSD) external {
        guardDisabled[asset][inUSD] = true;
    }

    function addAsset(
        address asset,
        bool,
        address aggregator,
        uint256 heartbeat
    ) external {
        if (revertOnAddAsset) {
            revert("addAsset failed");
        }

        aggregatorForAsset[asset] = aggregator;
        heartbeatForAsset[asset] = heartbeat;
    }
}

contract AddCombinedAggregatorToken {
    string public symbol;

    constructor(string memory symbol_) {
        symbol = symbol_;
    }
}

contract AddCombinedAggregatorFeed {
    int256 internal immutable _answer;

    constructor(int256 answer_) {
        _answer = answer_;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (1, _answer, block.timestamp, block.timestamp, 1);
    }

    function latestRound() external pure returns (uint256) {
        return 1;
    }
}

contract TestAddCombinedAggregator is Test {
    struct CombinedAggregatorTestContext {
        AddCombinedAggregatorRegistry registry;
        AddCombinedAggregatorAdaptor adaptor;
        AddCombinedAggregatorToken asset;
        AddCombinedAggregatorFeed primaryFeed;
        AddCombinedAggregatorFeed secondaryFeed;
    }

    function test_addCombinedAggregator_requiresOracleManagerRouteBeforeMutatingAdaptor()
        public
    {
        vm.warp(1_000_000);

        AddCombinedAggregatorOracleManager oracleManager =
            new AddCombinedAggregatorOracleManager();
        AddCombinedAggregatorRegistry registry =
            new AddCombinedAggregatorRegistry(address(oracleManager));
        AddCombinedAggregatorAdaptor adaptor = new AddCombinedAggregatorAdaptor();
        AddCombinedAggregatorToken asset = new AddCombinedAggregatorToken("ASSET");
        AddCombinedAggregatorFeed primaryFeed = new AddCombinedAggregatorFeed(1e8);
        AddCombinedAggregatorFeed secondaryFeed = new AddCombinedAggregatorFeed(1e8);
        AddCombinedAggregatorHarness script = new AddCombinedAggregatorHarness();

        vm.expectRevert(
            AddCombinedAggregator
                .AddCombinedAggregator__UnsupportedOracleRoute
                .selector
        );
        script.run(
            address(asset),
            address(registry),
            address(primaryFeed),
            address(secondaryFeed),
            1 hours,
            "ASSET/USD",
            AddCombinedAggregator.PriceGuard({
                enabled: false,
                inUSD: true,
                timestampSubtract: 0,
                ips: 0,
                basePrice: 0,
                minPrice: 0
            }),
            address(adaptor),
            6 hours
        );

        assertFalse(adaptor.guardDisabled(address(asset), true));
        assertEq(adaptor.aggregatorForAsset(address(asset)), address(0));
        assertEq(adaptor.heartbeatForAsset(address(asset)), 0);
    }

    function test_addCombinedAggregator_doesNotDisableGuardWhenAdaptorUpdateFails()
        public
    {
        vm.warp(1_000_000);

        AddCombinedAggregatorOracleManager oracleManager =
            new AddCombinedAggregatorOracleManager();
        AddCombinedAggregatorRegistry registry =
            new AddCombinedAggregatorRegistry(address(oracleManager));
        AddCombinedAggregatorAdaptor adaptor = new AddCombinedAggregatorAdaptor();
        AddCombinedAggregatorToken asset = new AddCombinedAggregatorToken("ASSET");
        AddCombinedAggregatorFeed primaryFeed = new AddCombinedAggregatorFeed(1e8);
        AddCombinedAggregatorFeed secondaryFeed = new AddCombinedAggregatorFeed(1e8);
        AddCombinedAggregatorHarness script = new AddCombinedAggregatorHarness();

        address[] memory adaptors = new address[](1);
        adaptors[0] = address(adaptor);
        oracleManager.setPricingAdaptors(address(asset), adaptors);
        adaptor.setRevertOnAddAsset(true);

        vm.expectRevert("addAsset failed");
        script.run(
            address(asset),
            address(registry),
            address(primaryFeed),
            address(secondaryFeed),
            1 hours,
            "ASSET/USD",
            AddCombinedAggregator.PriceGuard({
                enabled: false,
                inUSD: true,
                timestampSubtract: 0,
                ips: 0,
                basePrice: 0,
                minPrice: 0
            }),
            address(adaptor),
            6 hours
        );

        assertFalse(adaptor.guardDisabled(address(asset), true));
        assertEq(adaptor.aggregatorForAsset(address(asset)), address(0));
        assertEq(adaptor.heartbeatForAsset(address(asset)), 0);
    }

    function test_addCombinedAggregator_preflightsMarketPermissionBeforeMutatingAdaptor()
        public
    {
        vm.warp(1_000_000);

        AddCombinedAggregatorOracleManager oracleManager =
            new AddCombinedAggregatorOracleManager();
        AddCombinedAggregatorRegistry registry =
            new AddCombinedAggregatorRegistry(address(oracleManager));
        AddCombinedAggregatorAdaptor adaptor = new AddCombinedAggregatorAdaptor();
        AddCombinedAggregatorToken asset = new AddCombinedAggregatorToken("ASSET");
        AddCombinedAggregatorFeed primaryFeed = new AddCombinedAggregatorFeed(1e8);
        AddCombinedAggregatorFeed secondaryFeed = new AddCombinedAggregatorFeed(1e8);
        address broadcaster = makeAddr("broadcaster");
        AddCombinedAggregatorBroadcastHarness script =
            new AddCombinedAggregatorBroadcastHarness(broadcaster);

        address[] memory adaptors = new address[](1);
        adaptors[0] = address(adaptor);
        oracleManager.setPricingAdaptors(address(asset), adaptors);
        registry.setPermissionsOpen(false);
        registry.setElevatedPermission(broadcaster, true);

        vm.expectRevert(
            AddCombinedAggregator.AddCombinedAggregator__Unauthorized.selector
        );
        script.run(
            address(asset),
            address(registry),
            address(primaryFeed),
            address(secondaryFeed),
            1 hours,
            "ASSET/USD",
            AddCombinedAggregator.PriceGuard({
                enabled: false,
                inUSD: true,
                timestampSubtract: 0,
                ips: 0,
                basePrice: 0,
                minPrice: 0
            }),
            address(adaptor),
            6 hours
        );

        assertFalse(adaptor.guardDisabled(address(asset), true));
        assertEq(adaptor.aggregatorForAsset(address(asset)), address(0));
        assertEq(adaptor.heartbeatForAsset(address(asset)), 0);
    }

    function test_addCombinedAggregator_recordEventsUsesBroadcastCallerPermissions()
        public
    {
        vm.warp(1_000_000);

        CombinedAggregatorTestContext memory ctx =
            _combinedAggregatorContextWithRoute();
        (string memory directory, string memory file) =
            _deploymentOutput("add-combined-aggregator");
        AddCombinedAggregatorRecordedHarness script =
            new AddCombinedAggregatorRecordedHarness(directory, file);

        ctx.registry.setPermissionsOpen(false);
        address broadcaster = script.defaultBroadcastCaller();
        ctx.registry.setElevatedPermission(broadcaster, true);
        ctx.registry.setMarketPermission(broadcaster, true);

        script.run(
            address(ctx.asset),
            address(ctx.registry),
            address(ctx.primaryFeed),
            address(ctx.secondaryFeed),
            1 hours,
            "ASSET/USD",
            AddCombinedAggregator.PriceGuard({
                enabled: false,
                inUSD: true,
                timestampSubtract: 0,
                ips: 0,
                basePrice: 0,
                minPrice: 0
            }),
            address(ctx.adaptor),
            6 hours
        );

        assertGt(ctx.adaptor.aggregatorForAsset(address(ctx.asset)).code.length, 0);
        assertTrue(ctx.adaptor.guardDisabled(address(ctx.asset), true));
        string memory saved = vm.readFile(file);
        assertEq(
            _countOccurrences(saved, '"emitter"'),
            1,
            "recordEvents should write the deployment event"
        );
        vm.parseJson(saved);

        _cleanup(directory, file);
    }

    function test_addCombinedAggregator_configuresCombinedAggregatorForExistingRoute()
        public
    {
        vm.warp(1_000_000);

        AddCombinedAggregatorOracleManager oracleManager =
            new AddCombinedAggregatorOracleManager();
        AddCombinedAggregatorRegistry registry =
            new AddCombinedAggregatorRegistry(address(oracleManager));
        AddCombinedAggregatorAdaptor adaptor = new AddCombinedAggregatorAdaptor();
        AddCombinedAggregatorToken asset = new AddCombinedAggregatorToken("ASSET");
        AddCombinedAggregatorFeed primaryFeed = new AddCombinedAggregatorFeed(1e8);
        AddCombinedAggregatorFeed secondaryFeed = new AddCombinedAggregatorFeed(1e8);
        AddCombinedAggregatorHarness script = new AddCombinedAggregatorHarness();

        address[] memory adaptors = new address[](2);
        adaptors[0] = address(adaptor);
        adaptors[1] = makeAddr("otherAdaptor");
        oracleManager.setPricingAdaptors(address(asset), adaptors);

        script.run(
            address(asset),
            address(registry),
            address(primaryFeed),
            address(secondaryFeed),
            1 hours,
            "ASSET/USD",
            AddCombinedAggregator.PriceGuard({
                enabled: true,
                inUSD: true,
                timestampSubtract: 0,
                ips: 0,
                basePrice: 2e8,
                minPrice: 0
            }),
            address(adaptor),
            6 hours
        );

        address aggregator = adaptor.aggregatorForAsset(address(asset));
        assertGt(aggregator.code.length, 0);
        assertTrue(adaptor.guardDisabled(address(asset), true));
        assertEq(adaptor.heartbeatForAsset(address(asset)), 6 hours);
        assertEq(
            address(CombinedAggregator(aggregator).underlyingAggregator()),
            address(primaryFeed)
        );
        assertEq(
            address(CombinedAggregator(aggregator).secondaryAggregator()),
            address(secondaryFeed)
        );

        (
            uint40 timestampStart,
            uint40 ips,
            uint88 basePrice,
            uint88 minPrice
        ) = CombinedAggregator(aggregator).pg();
        assertEq(timestampStart, 0);
        assertEq(ips, 0);
        assertEq(basePrice, 2e8);
        assertEq(minPrice, 0);

        (, int256 adjustedAnswer,,,) =
            CombinedAggregator(aggregator).latestRoundData();
        assertEq(adjustedAnswer, 1e8);
    }

    function test_addCombinedAggregator_rejectsSecondSlotAdaptorRoute()
        public
    {
        vm.warp(1_000_000);

        AddCombinedAggregatorOracleManager oracleManager =
            new AddCombinedAggregatorOracleManager();
        AddCombinedAggregatorRegistry registry =
            new AddCombinedAggregatorRegistry(address(oracleManager));
        AddCombinedAggregatorAdaptor adaptor = new AddCombinedAggregatorAdaptor();
        AddCombinedAggregatorToken asset = new AddCombinedAggregatorToken("ASSET");
        AddCombinedAggregatorFeed primaryFeed = new AddCombinedAggregatorFeed(1e8);
        AddCombinedAggregatorFeed secondaryFeed = new AddCombinedAggregatorFeed(1e8);
        AddCombinedAggregatorHarness script = new AddCombinedAggregatorHarness();

        address[] memory adaptors = new address[](2);
        adaptors[0] = makeAddr("otherAdaptor");
        adaptors[1] = address(adaptor);
        oracleManager.setPricingAdaptors(address(asset), adaptors);

        vm.expectRevert(
            AddCombinedAggregator
                .AddCombinedAggregator__UnsupportedOracleRoute
                .selector
        );
        script.run(
            address(asset),
            address(registry),
            address(primaryFeed),
            address(secondaryFeed),
            1 hours,
            "ASSET/USD",
            AddCombinedAggregator.PriceGuard({
                enabled: false,
                inUSD: true,
                timestampSubtract: 0,
                ips: 0,
                basePrice: 0,
                minPrice: 0
            }),
            address(adaptor),
            6 hours
        );

        assertFalse(adaptor.guardDisabled(address(asset), true));
        assertEq(adaptor.aggregatorForAsset(address(asset)), address(0));
        assertEq(adaptor.heartbeatForAsset(address(asset)), 0);
    }

    function _deploymentOutput(
        string memory suffix
    ) internal returns (string memory directory, string memory file) {
        directory = string.concat(vm.projectRoot(), "/tmp/", suffix);
        file = string.concat(directory, "/deployment.json");
        _cleanup(directory, file);
    }

    function _combinedAggregatorContextWithRoute()
        internal
        returns (CombinedAggregatorTestContext memory ctx)
    {
        AddCombinedAggregatorOracleManager oracleManager =
            new AddCombinedAggregatorOracleManager();
        ctx.registry = new AddCombinedAggregatorRegistry(address(oracleManager));
        ctx.adaptor = new AddCombinedAggregatorAdaptor();
        ctx.asset = new AddCombinedAggregatorToken("ASSET");
        ctx.primaryFeed = new AddCombinedAggregatorFeed(1e8);
        ctx.secondaryFeed = new AddCombinedAggregatorFeed(1e8);

        address[] memory adaptors = new address[](1);
        adaptors[0] = address(ctx.adaptor);
        oracleManager.setPricingAdaptors(address(ctx.asset), adaptors);
    }

    function _cleanup(
        string memory directory,
        string memory file
    ) internal {
        if (vm.exists(file)) {
            vm.removeFile(file);
        }
        if (vm.exists(directory)) {
            vm.removeDir(directory, true);
        }
    }

    function _countOccurrences(
        string memory haystack,
        string memory needle
    ) internal pure returns (uint256 count) {
        bytes memory haystackBytes = bytes(haystack);
        bytes memory needleBytes = bytes(needle);
        if (needleBytes.length == 0 || haystackBytes.length < needleBytes.length) return 0;

        for (uint256 i; i <= haystackBytes.length - needleBytes.length; ++i) {
            bool matches = true;
            for (uint256 j; j < needleBytes.length; ++j) {
                if (haystackBytes[i + j] != needleBytes[j]) {
                    matches = false;
                    break;
                }
            }
            if (matches) ++count;
        }
    }
}
