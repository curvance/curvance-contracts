// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {AddChainlinkVaultAggSupport} from "script/deployment/AddChainlinkVaultAggSupport.s.sol";
import {AddRedstoneVaultAggSupport} from "script/deployment/AddRedstoneVaultAggSupport.s.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IOracleAdaptor} from "contracts/interfaces/IOracleAdaptor.sol";
import {ChainlinkAdaptor} from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import {RedstoneClassicAdaptor} from "contracts/oracles/adaptors/redstone/RedstoneClassicAdaptor.sol";
import {VaultAggregator} from "contracts/oracles/adaptors/wrappedAggregators/VaultAggregator.sol";
import {Bytes32Helper} from "contracts/libraries/Bytes32Helper.sol";
import {IRedstone} from "contracts/interfaces/external/redstone/IRedstone.sol";

contract AddVaultAggSupportHarness is AddChainlinkVaultAggSupport {
    modifier recordEvents() override {
        _;
    }
}

contract AddRedstoneVaultAggSupportHarness is AddRedstoneVaultAggSupport {
    modifier recordEvents() override {
        _;
    }
}

contract AddVaultAggSupportRegistry {
    address public immutable oracleManager;

    constructor(address oracleManager_) {
        oracleManager = oracleManager_;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 ||
            interfaceId == type(ICentralRegistry).interfaceId;
    }

    function hasElevatedPermissions(address) external pure returns (bool) {
        return true;
    }

    function hasMarketPermissions(address) external pure returns (bool) {
        return true;
    }
}

contract AddVaultAggSupportOracleManager {
    struct SupportConfig {
        address adaptor;
        uint256 lowerBound;
        uint256 upperBound;
        uint256 lowerBoundNonPegged;
        uint256 upperBoundNonPegged;
    }

    mapping(address => SupportConfig) public supportConfigs;

    function addAssetPricingAdaptor(
        address vaultToken,
        address adaptor,
        uint256 lowerBound,
        uint256 upperBound,
        uint256 lowerBoundNonPegged,
        uint256 upperBoundNonPegged
    ) external {
        require(
            AddVaultAggSupportAdaptor(adaptor).guardSet(vaultToken, true),
            "vault guard not set before oracle support"
        );

        require(
            AddVaultAggSupportAdaptor(adaptor).isSupportedAsset(vaultToken),
            "vault not supported before oracle support"
        );

        IOracleAdaptor.PricingResult memory lower =
            AddVaultAggSupportAdaptor(adaptor).getPrice(
                vaultToken, true, true
            );
        require(
            lower.price > 0 && lower.inUSD && !lower.hadError,
            "lower price sample failed"
        );

        IOracleAdaptor.PricingResult memory upper =
            AddVaultAggSupportAdaptor(adaptor).getPrice(
                vaultToken, true, false
            );
        require(
            upper.price > 0 && upper.inUSD && !upper.hadError,
            "upper price sample failed"
        );

        supportConfigs[vaultToken] = SupportConfig({
            adaptor: adaptor,
            lowerBound: lowerBound,
            upperBound: upperBound,
            lowerBoundNonPegged: lowerBoundNonPegged,
            upperBoundNonPegged: upperBoundNonPegged
        });
    }
}

contract AddVaultAggSupportRealOracleManager {
    struct SupportConfig {
        address adaptor;
        uint256 lowerBound;
        uint256 upperBound;
        uint256 lowerBoundNonPegged;
        uint256 upperBoundNonPegged;
    }

    mapping(address => SupportConfig) public supportConfigs;

    function addAssetPricingAdaptor(
        address vaultToken,
        address adaptor,
        uint256 lowerBound,
        uint256 upperBound,
        uint256 lowerBoundNonPegged,
        uint256 upperBoundNonPegged
    ) external {
        require(
            IOracleAdaptor(adaptor).isSupportedAsset(vaultToken),
            "vault not supported before oracle support"
        );

        IOracleAdaptor.PricingResult memory lower =
            IOracleAdaptor(adaptor).getPrice(vaultToken, true, true);
        require(
            lower.price > 0 && lower.inUSD && !lower.hadError,
            "lower price sample failed"
        );

        IOracleAdaptor.PricingResult memory upper =
            IOracleAdaptor(adaptor).getPrice(vaultToken, true, false);
        require(
            upper.price > 0 && upper.inUSD && !upper.hadError,
            "upper price sample failed"
        );

        supportConfigs[vaultToken] = SupportConfig({
            adaptor: adaptor,
            lowerBound: lowerBound,
            upperBound: upperBound,
            lowerBoundNonPegged: lowerBoundNonPegged,
            upperBoundNonPegged: upperBoundNonPegged
        });
    }
}

contract AddVaultAggSupportAdaptor {
    struct GuardConfig {
        bool enabled;
        bool inUSD;
        uint256 timestampStart;
        uint256 ips;
        uint256 basePrice;
        uint256 minPrice;
    }

    mapping(address => mapping(bool => bool)) public guardSet;
    mapping(address => mapping(bool => GuardConfig)) public guardConfigs;
    mapping(address => address) public aggregatorForAsset;
    mapping(address => uint256) public heartbeatForAsset;

    function addAsset(address asset, bool, address aggregator, uint256 heartbeat) external {
        aggregatorForAsset[asset] = aggregator;
        heartbeatForAsset[asset] = heartbeat;
    }

    function addAsset(address asset, bool, address aggregator, uint256 heartbeat, string memory) external {
        aggregatorForAsset[asset] = aggregator;
        heartbeatForAsset[asset] = heartbeat;
    }

    function isSupportedAsset(address asset) external view returns (bool) {
        return aggregatorForAsset[asset] != address(0);
    }

    function getPrice(
        address asset,
        bool inUSD,
        bool
    ) external view returns (IOracleAdaptor.PricingResult memory result) {
        address aggregator = aggregatorForAsset[asset];
        if (aggregator == address(0) || !guardSet[asset][inUSD]) {
            return IOracleAdaptor.PricingResult(0, inUSD, true);
        }

        (, int256 answer,,,) = VaultAggregator(aggregator).latestRoundData();
        if (answer <= 0) {
            return IOracleAdaptor.PricingResult(0, inUSD, true);
        }

        uint256 price = uint256(answer) * 1e10;
        GuardConfig memory guard = guardConfigs[asset][inUSD];
        if (price < guard.minPrice) {
            return IOracleAdaptor.PricingResult(0, inUSD, true);
        }

        if (guard.basePrice != 0 && price > guard.basePrice) {
            price = guard.basePrice;
        }

        return IOracleAdaptor.PricingResult(price, inUSD, false);
    }

    function setGuardedPriceConfig(
        address asset,
        bool inUSD,
        uint256 timestampStart,
        uint256 ips,
        uint256 basePrice,
        uint256 minPrice
    ) external {
        guardSet[asset][inUSD] = true;
        guardConfigs[asset][inUSD] = GuardConfig({
            enabled: true,
            inUSD: inUSD,
            timestampStart: timestampStart,
            ips: ips,
            basePrice: basePrice,
            minPrice: minPrice
        });
    }
}

contract AddVaultAggSupportToken {
    string public symbol;
    uint8 public immutable decimals;
    address public immutable asset;
    uint256 public immutable assetsPerShare;

    constructor(
        string memory symbol_,
        uint8 decimals_,
        address asset_,
        uint256 assetsPerShare_
    ) {
        symbol = symbol_;
        decimals = decimals_;
        asset = asset_;
        assetsPerShare = assetsPerShare_;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return shares * assetsPerShare / 1e18;
    }
}

contract AddVaultAggSupportFeed {
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
        return (1, 1e8, block.timestamp, block.timestamp, 1);
    }
}

contract TestAddVaultAggSupport is Test {
    function test_addChainlinkVaultAggSupport_setsGuardBeforeOracleSupport() public {
        vm.warp(1_000_000);

        AddVaultAggSupportOracleManager oracleManager =
            new AddVaultAggSupportOracleManager();
        AddVaultAggSupportRegistry registry =
            new AddVaultAggSupportRegistry(address(oracleManager));
        AddVaultAggSupportAdaptor adaptor = new AddVaultAggSupportAdaptor();
        AddVaultAggSupportToken asset =
            new AddVaultAggSupportToken("ASSET", 18, address(0), 1e18);
        AddVaultAggSupportToken vault =
            new AddVaultAggSupportToken("VAULT", 18, address(asset), 2e18);
        AddVaultAggSupportFeed feed = new AddVaultAggSupportFeed();

        AddVaultAggSupportHarness script = new AddVaultAggSupportHarness();
        script.run(
            address(registry),
            address(adaptor),
            address(vault),
            address(asset),
            address(feed),
            true,
            6 hours,
            AddChainlinkVaultAggSupport.PriceGuard({
                enabled: true,
                inUSD: true,
                timestampSubtract: 8 days,
                ips: 99,
                basePrice: 1e18,
                minPrice: 0
            })
        );

        _assertGuardConfig(
            adaptor, address(vault), true, 1_000_000 - 8 days, 99, 1e18, 0
        );
        _assertOracleSupport(oracleManager, address(vault), address(adaptor));
        _assertVaultAggregator(adaptor, vault, asset, feed, bytes32(0));
        assertEq(adaptor.heartbeatForAsset(address(vault)), 6 hours);
    }

    function test_addRedstoneVaultAggSupport_setsGuardBeforeOracleSupport() public {
        vm.warp(1_000_000);

        AddVaultAggSupportOracleManager oracleManager =
            new AddVaultAggSupportOracleManager();
        AddVaultAggSupportRegistry registry =
            new AddVaultAggSupportRegistry(address(oracleManager));
        AddVaultAggSupportAdaptor adaptor = new AddVaultAggSupportAdaptor();
        AddVaultAggSupportToken asset =
            new AddVaultAggSupportToken("ASSET", 18, address(0), 1e18);
        AddVaultAggSupportToken vault =
            new AddVaultAggSupportToken("VAULT", 18, address(asset), 2e18);
        AddVaultAggSupportFeed feed = new AddVaultAggSupportFeed();

        AddRedstoneVaultAggSupportHarness script = new AddRedstoneVaultAggSupportHarness();
        script.run(
            address(registry),
            address(adaptor),
            address(vault),
            address(asset),
            address(feed),
            "VAULT",
            true,
            12 hours,
            AddRedstoneVaultAggSupport.PriceGuard({
                enabled: true,
                inUSD: true,
                timestampSubtract: 10 days,
                ips: 77,
                basePrice: 2e18,
                minPrice: 0
            })
        );

        _assertGuardConfig(
            adaptor, address(vault), true, 1_000_000 - 10 days, 77, 2e18, 0
        );
        _assertOracleSupport(oracleManager, address(vault), address(adaptor));
        _assertVaultAggregator(
            adaptor,
            vault,
            asset,
            feed,
            Bytes32Helper.toBytes32("VAULT")
        );
        assertEq(adaptor.heartbeatForAsset(address(vault)), 12 hours);
    }

    function test_addChainlinkVaultAggSupport_configuresRealAdaptorBeforeOracleSupport()
        public
    {
        vm.warp(1_000_000);

        AddVaultAggSupportRealOracleManager oracleManager =
            new AddVaultAggSupportRealOracleManager();
        AddVaultAggSupportRegistry registry =
            new AddVaultAggSupportRegistry(address(oracleManager));
        ChainlinkAdaptor adaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(registry))
        );
        AddVaultAggSupportToken asset =
            new AddVaultAggSupportToken("ASSET", 18, address(0), 1e18);
        AddVaultAggSupportToken vault =
            new AddVaultAggSupportToken("VAULT", 18, address(asset), 2e18);
        AddVaultAggSupportFeed feed = new AddVaultAggSupportFeed();

        AddVaultAggSupportHarness script = new AddVaultAggSupportHarness();
        script.run(
            address(registry),
            address(adaptor),
            address(vault),
            address(asset),
            address(feed),
            true,
            6 hours,
            AddChainlinkVaultAggSupport.PriceGuard({
                enabled: true,
                inUSD: true,
                timestampSubtract: 8 days,
                ips: 0,
                basePrice: 2e18,
                minPrice: 0
            })
        );

        IOracleAdaptor.PricingResult memory lower =
            adaptor.getPrice(address(vault), true, true);
        assertEq(lower.price, 2e18);
        assertTrue(lower.inUSD);
        assertFalse(lower.hadError);

        IOracleAdaptor.PriceGuard memory guard =
            adaptor.getPriceGuard(address(vault), true);
        assertEq(uint256(guard.timestampStart), 0);
        assertEq(uint256(guard.ips), 0);
        assertEq(uint256(guard.basePrice), 2e18);
        assertEq(uint256(guard.minPrice), 0);

        (
            address storedAdaptor,
            uint256 lowerBound,
            uint256 upperBound,
            uint256 lowerBoundNonPegged,
            uint256 upperBoundNonPegged
        ) = oracleManager.supportConfigs(address(vault));
        assertEq(storedAdaptor, address(adaptor));
        assertEq(lowerBound, 250);
        assertEq(upperBound, 220);
        assertEq(lowerBoundNonPegged, 250);
        assertEq(upperBoundNonPegged, 220);

        (
            bool isConfigured,
            ,
            uint8 decimals,
            uint24 heartbeat
        ) = adaptor.assetConfig(address(vault), true);
        assertTrue(isConfigured);
        assertEq(decimals, 8);
        assertEq(heartbeat, 6 hours + 2 minutes);
    }

    function test_addChainlinkVaultAggSupport_revertsRealAdaptorHeartbeatBeforeOracleSupport()
        public
    {
        vm.warp(1_000_000);

        AddVaultAggSupportOracleManager oracleManager =
            new AddVaultAggSupportOracleManager();
        AddVaultAggSupportRegistry registry =
            new AddVaultAggSupportRegistry(address(oracleManager));
        ChainlinkAdaptor adaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(registry))
        );
        AddVaultAggSupportToken asset =
            new AddVaultAggSupportToken("ASSET", 18, address(0), 1e18);
        AddVaultAggSupportToken vault =
            new AddVaultAggSupportToken("VAULT", 18, address(asset), 2e18);
        AddVaultAggSupportFeed feed = new AddVaultAggSupportFeed();

        AddVaultAggSupportHarness script = new AddVaultAggSupportHarness();

        vm.expectRevert(
            ChainlinkAdaptor.ChainlinkAdaptor__InvalidHeartbeat.selector
        );
        script.run(
            address(registry),
            address(adaptor),
            address(vault),
            address(asset),
            address(feed),
            true,
            2 days,
            AddChainlinkVaultAggSupport.PriceGuard({
                enabled: false,
                inUSD: true,
                timestampSubtract: 0,
                ips: 0,
                basePrice: 0,
                minPrice: 0
            })
        );

        assertFalse(adaptor.isSupportedAsset(address(vault)));

        (
            address storedAdaptor,
            uint256 lowerBound,
            uint256 upperBound,
            uint256 lowerBoundNonPegged,
            uint256 upperBoundNonPegged
        ) = oracleManager.supportConfigs(address(vault));
        assertEq(storedAdaptor, address(0));
        assertEq(lowerBound, 0);
        assertEq(upperBound, 0);
        assertEq(lowerBoundNonPegged, 0);
        assertEq(upperBoundNonPegged, 0);
    }

    function test_addRedstoneVaultAggSupport_configuresRealAdaptorBeforeOracleSupport()
        public
    {
        vm.warp(1_000_000);

        AddVaultAggSupportRealOracleManager oracleManager =
            new AddVaultAggSupportRealOracleManager();
        AddVaultAggSupportRegistry registry =
            new AddVaultAggSupportRegistry(address(oracleManager));
        RedstoneClassicAdaptor adaptor = new RedstoneClassicAdaptor(
            ICentralRegistry(address(registry))
        );
        AddVaultAggSupportToken asset =
            new AddVaultAggSupportToken("ASSET", 18, address(0), 1e18);
        AddVaultAggSupportToken vault =
            new AddVaultAggSupportToken("VAULT", 18, address(asset), 2e18);
        AddVaultAggSupportFeed feed = new AddVaultAggSupportFeed();

        AddRedstoneVaultAggSupportHarness script =
            new AddRedstoneVaultAggSupportHarness();
        script.run(
            address(registry),
            address(adaptor),
            address(vault),
            address(asset),
            address(feed),
            "VAULT",
            true,
            12 hours,
            AddRedstoneVaultAggSupport.PriceGuard({
                enabled: true,
                inUSD: true,
                timestampSubtract: 10 days,
                ips: 0,
                basePrice: 2e18,
                minPrice: 0
            })
        );

        IOracleAdaptor.PricingResult memory lower =
            adaptor.getPrice(address(vault), true, true);
        assertEq(lower.price, 2e18);
        assertTrue(lower.inUSD);
        assertFalse(lower.hadError);

        IOracleAdaptor.PriceGuard memory guard =
            adaptor.getPriceGuard(address(vault), true);
        assertEq(uint256(guard.timestampStart), 0);
        assertEq(uint256(guard.ips), 0);
        assertEq(uint256(guard.basePrice), 2e18);
        assertEq(uint256(guard.minPrice), 0);

        (
            address storedAdaptor,
            uint256 lowerBound,
            uint256 upperBound,
            uint256 lowerBoundNonPegged,
            uint256 upperBoundNonPegged
        ) = oracleManager.supportConfigs(address(vault));
        assertEq(storedAdaptor, address(adaptor));
        assertEq(lowerBound, 250);
        assertEq(upperBound, 220);
        assertEq(lowerBoundNonPegged, 250);
        assertEq(upperBoundNonPegged, 220);

        (bool isConfigured, IRedstone feedProxy,, uint24 heartbeat) =
            adaptor.assetConfig(address(vault), true);
        assertTrue(isConfigured);
        assertEq(heartbeat, 12 hours + 2 minutes);
        assertGt(address(feedProxy).code.length, 0);
        assertEq(feedProxy.getDataFeedId(), Bytes32Helper.toBytes32("VAULT"));
    }

    function test_addRedstoneVaultAggSupport_revertsRealAdaptorHeartbeatBeforeOracleSupport()
        public
    {
        vm.warp(1_000_000);

        AddVaultAggSupportOracleManager oracleManager =
            new AddVaultAggSupportOracleManager();
        AddVaultAggSupportRegistry registry =
            new AddVaultAggSupportRegistry(address(oracleManager));
        RedstoneClassicAdaptor adaptor = new RedstoneClassicAdaptor(
            ICentralRegistry(address(registry))
        );
        AddVaultAggSupportToken asset =
            new AddVaultAggSupportToken("ASSET", 18, address(0), 1e18);
        AddVaultAggSupportToken vault =
            new AddVaultAggSupportToken("VAULT", 18, address(asset), 2e18);
        AddVaultAggSupportFeed feed = new AddVaultAggSupportFeed();

        AddRedstoneVaultAggSupportHarness script =
            new AddRedstoneVaultAggSupportHarness();

        vm.expectRevert(
            RedstoneClassicAdaptor.RedstoneClassicAdaptor__InvalidHeartbeat.selector
        );
        script.run(
            address(registry),
            address(adaptor),
            address(vault),
            address(asset),
            address(feed),
            "VAULT",
            true,
            2 days,
            AddRedstoneVaultAggSupport.PriceGuard({
                enabled: false,
                inUSD: true,
                timestampSubtract: 0,
                ips: 0,
                basePrice: 0,
                minPrice: 0
            })
        );

        assertFalse(adaptor.isSupportedAsset(address(vault)));
        _assertNoOracleSupport(oracleManager, address(vault));
    }

    function _assertGuardConfig(
        AddVaultAggSupportAdaptor adaptor,
        address vault,
        bool inUSD,
        uint256 timestampStart,
        uint256 ips,
        uint256 basePrice,
        uint256 minPrice
    ) internal view {
        (
            bool enabled,
            bool guardInUSD,
            uint256 storedTimestampStart,
            uint256 storedIps,
            uint256 storedBasePrice,
            uint256 storedMinPrice
        ) = adaptor.guardConfigs(vault, inUSD);

        assertTrue(enabled);
        assertTrue(adaptor.guardSet(vault, inUSD));
        assertEq(guardInUSD, inUSD);
        assertEq(storedTimestampStart, timestampStart);
        assertEq(storedIps, ips);
        assertEq(storedBasePrice, basePrice);
        assertEq(storedMinPrice, minPrice);
    }

    function _assertOracleSupport(
        AddVaultAggSupportOracleManager oracleManager,
        address vault,
        address adaptor
    ) internal view {
        (
            address storedAdaptor,
            uint256 lowerBound,
            uint256 upperBound,
            uint256 lowerBoundNonPegged,
            uint256 upperBoundNonPegged
        ) = oracleManager.supportConfigs(vault);

        assertEq(storedAdaptor, adaptor);
        assertEq(lowerBound, 250);
        assertEq(upperBound, 220);
        assertEq(lowerBoundNonPegged, 250);
        assertEq(upperBoundNonPegged, 220);
    }

    function _assertNoOracleSupport(
        AddVaultAggSupportOracleManager oracleManager,
        address vault
    ) internal view {
        (
            address storedAdaptor,
            uint256 lowerBound,
            uint256 upperBound,
            uint256 lowerBoundNonPegged,
            uint256 upperBoundNonPegged
        ) = oracleManager.supportConfigs(vault);

        assertEq(storedAdaptor, address(0));
        assertEq(lowerBound, 0);
        assertEq(upperBound, 0);
        assertEq(lowerBoundNonPegged, 0);
        assertEq(upperBoundNonPegged, 0);
    }

    function _assertVaultAggregator(
        AddVaultAggSupportAdaptor adaptor,
        AddVaultAggSupportToken vault,
        AddVaultAggSupportToken asset,
        AddVaultAggSupportFeed feed,
        bytes32 expectedDataFeedId
    ) internal view {
        address aggregator = adaptor.aggregatorForAsset(address(vault));

        assertGt(aggregator.code.length, 0);
        assertEq(VaultAggregator(aggregator).vault(), address(vault));
        assertEq(VaultAggregator(aggregator).asset(), address(asset));
        assertEq(
            address(VaultAggregator(aggregator).underlyingAggregator()),
            address(feed)
        );
        assertEq(VaultAggregator(aggregator).getDataFeedId(), expectedDataFeedId);
        assertEq(VaultAggregator(aggregator).getAdjustedAnswer(1e8), 2e8);

        (, int256 adjustedAnswer,,,) = VaultAggregator(aggregator).latestRoundData();
        assertEq(adjustedAnswer, 2e8);
    }
}
