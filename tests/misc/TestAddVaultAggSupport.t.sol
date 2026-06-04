// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {AddChainlinkVaultAggSupport} from "script/deployment/AddChainlinkVaultAggSupport.s.sol";
import {AddRedstoneVaultAggSupport} from "script/deployment/AddRedstoneVaultAggSupport.s.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IOracleAdaptor} from "contracts/interfaces/IOracleAdaptor.sol";
import {VaultAggregator} from "contracts/oracles/adaptors/wrappedAggregators/VaultAggregator.sol";
import {Bytes32Helper} from "contracts/libraries/Bytes32Helper.sol";

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

    function addAsset(address asset, bool, address aggregator, uint256) external {
        aggregatorForAsset[asset] = aggregator;
    }

    function addAsset(address asset, bool, address aggregator, uint256, string memory) external {
        aggregatorForAsset[asset] = aggregator;
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
            0,
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
