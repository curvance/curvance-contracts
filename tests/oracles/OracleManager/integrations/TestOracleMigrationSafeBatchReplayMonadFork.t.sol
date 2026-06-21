// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {CentralRegistry} from "contracts/architecture/CentralRegistry.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {ICToken} from "contracts/interfaces/ICToken.sol";
import {
    IChainlink
} from "contracts/interfaces/external/chainlink/IChainlink.sol";
import {IRedstone} from "contracts/interfaces/external/redstone/IRedstone.sol";
import {IOracleAdaptor} from "contracts/interfaces/IOracleAdaptor.sol";
import {
    BAD_SOURCE,
    HEARTBEAT_GRACE_PERIOD
} from "contracts/libraries/ConstantsLib.sol";
import {OracleManager} from "contracts/oracles/OracleManager.sol";
import {
    ChainlinkAdaptor
} from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import {
    RedstoneClassicAdaptor
} from "contracts/oracles/adaptors/redstone/RedstoneClassicAdaptor.sol";

import {
    OracleMigrationSafeBatchFixture
} from "./fixtures/OracleMigrationSafeBatchFixture.sol";

interface ICombinedAggregatorPriceGuard {
    function pg() external view returns (IOracleAdaptor.PriceGuard memory);
}

contract TestOracleMigrationSafeBatchReplayMonadFork is Test {
    using Strings for uint256;
    using Strings for address;

    string internal constant REPORT_PATH =
        "tests/oracles/OracleManager/integrations/OracleMigrationSafeBatchReplayReport.md";

    bytes4 internal constant SET_ORACLE_MANAGER_SELECTOR =
        bytes4(keccak256("setOracleManager(address)"));
    address internal constant NATIVE_SENTINEL =
        0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    CentralRegistry internal centralRegistry;
    OracleManager internal liveOracleManager;
    OracleManager internal migrationOracleManager;
    ChainlinkAdaptor internal migrationChainlinkAdaptor;
    RedstoneClassicAdaptor internal migrationRedstoneClassicAdaptor;

    function setUp() public {
        vm.createSelectFork(vm.envString("MON_NODE_URI_MONAD_MAINNET"));

        centralRegistry =
            CentralRegistry(OracleMigrationSafeBatchFixture.CENTRAL_REGISTRY);
        liveOracleManager =
            OracleManager(OracleMigrationSafeBatchFixture.LIVE_ORACLE_MANAGER);
        migrationChainlinkAdaptor = ChainlinkAdaptor(
            OracleMigrationSafeBatchFixture.MIGRATION_CHAINLINK_ADAPTOR
        );
        migrationRedstoneClassicAdaptor = RedstoneClassicAdaptor(
            OracleMigrationSafeBatchFixture.MIGRATION_REDSTONE_CLASSIC_ADAPTOR
        );
    }

    function test_monadFork_replayOneShotSafeBatchWithoutRegistrySwitch()
        public
    {
        assertEq(
            centralRegistry.oracleManager(),
            address(liveOracleManager),
            "unexpected live OracleManager"
        );

        _writeReportHeader();

        migrationOracleManager =
            new OracleManager(ICentralRegistry(address(centralRegistry)));

        _reportOverview("Before replay");
        _reportLiveFeedState();
        _replaySafeBatch();

        assertEq(
            centralRegistry.oracleManager(),
            address(liveOracleManager),
            "registry switch should not be part of pre-switch batch"
        );

        _assertMigrationManagerConfig();
        _assertMigrationAdaptorConfigs();
        _assertCombinedAggregatorGuardConfigs();
        _assertCTokenSupport();
        _reportOverview("After replay");
        _reportFeedSideBySideComparisons();
        _reportMigrationFeedState();
        _reportPriceComparisons();
        _reportCTokenComparisons();
    }

    function _replaySafeBatch() internal {
        address emergencyCouncil = centralRegistry.emergencyCouncil();
        assertTrue(
            centralRegistry.hasElevatedPermissions(emergencyCouncil),
            "EC should have elevated permissions"
        );
        assertTrue(
            centralRegistry.hasMarketPermissions(emergencyCouncil),
            "EC should have market permissions"
        );

        uint256 txCount = OracleMigrationSafeBatchFixture.txCount();
        _writeSection("Safe Batch Replay");
        _writeLine(string.concat("- Transactions: ", txCount.toString()));
        _writeLine(
            string.concat(
                "- Candidate OracleManager deployed in-test: ",
                address(migrationOracleManager).toHexString()
            )
        );
        _writeLine(
            string.concat(
                "- Fixture placeholder target: ",
                OracleMigrationSafeBatchFixture.CANDIDATE_ORACLE_MANAGER_PLACEHOLDER
                        .toHexString()
            )
        );

        for (uint256 i; i < txCount; ++i) {
            OracleMigrationSafeBatchFixture.SafeTxPlan memory txPlan =
                OracleMigrationSafeBatchFixture.txAt(i);
            bytes4 selector = _selector(txPlan.data);
            assertNotEq(
                selector,
                SET_ORACLE_MANAGER_SELECTOR,
                "pre-switch batch must not call setOracleManager"
            );

            address target = txPlan.target;
            if (
                target
                    == OracleMigrationSafeBatchFixture.CANDIDATE_ORACLE_MANAGER_PLACEHOLDER
            ) {
                target = address(migrationOracleManager);
            }

            vm.prank(emergencyCouncil);
            (bool success, bytes memory returnData) =
                target.call{value: txPlan.value}(txPlan.data);
            if (!success) {
                console2.log("safe tx failed", i);
                console2.log(txPlan.label);
                console2.log("target", target);
                console2.logBytes(returnData);
            }
            assertTrue(success, txPlan.label);
        }
    }

    function _assertMigrationManagerConfig() internal view {
        assertTrue(
            migrationOracleManager.isApprovedAdaptor(
                OracleMigrationSafeBatchFixture.MIGRATION_CHAINLINK_ADAPTOR
            ),
            "migration Chainlink adaptor not approved"
        );
        assertTrue(
            migrationOracleManager.isApprovedAdaptor(
                OracleMigrationSafeBatchFixture.MIGRATION_REDSTONE_CLASSIC_ADAPTOR
            ),
            "migration Redstone Classic adaptor not approved"
        );

        for (uint256 i; i < OracleMigrationSafeBatchFixture.feedCount(); ++i) {
            OracleMigrationSafeBatchFixture.FeedPlan memory feed =
                OracleMigrationSafeBatchFixture.feedAt(i);
            address expectedAdaptor = _expectedMigrationAdaptor(feed.kind);
            address[] memory actualAdaptors =
                migrationOracleManager.getPricingAdaptors(feed.asset);

            assertEq(actualAdaptors.length, 1, "migration adaptor count");
            assertEq(actualAdaptors[0], expectedAdaptor, "migration adaptor");
            assertTrue(
                migrationOracleManager.isSupportedAsset(feed.asset),
                "migration manager should support asset"
            );

            (
                uint16 badSourceUSD,
                uint16 cautionUSD,
                uint16 badSourceNative,
                uint16 cautionNative
            ) = migrationOracleManager.assetPricingConfig(feed.asset);

            assertEq(badSourceUSD, feed.bounds.badSourceUSD, "badSourceUSD");
            assertEq(cautionUSD, feed.bounds.cautionUSD, "cautionUSD");
            assertEq(
                badSourceNative, feed.bounds.badSourceNative, "badSourceNative"
            );
            assertEq(cautionNative, feed.bounds.cautionNative, "cautionNative");
        }
    }

    function _assertMigrationAdaptorConfigs() internal view {
        for (uint256 i; i < OracleMigrationSafeBatchFixture.feedCount(); ++i) {
            OracleMigrationSafeBatchFixture.FeedPlan memory feed =
                OracleMigrationSafeBatchFixture.feedAt(i);
            if (feed.kind == OracleMigrationSafeBatchFixture.KIND_CHAINLINK) {
                _assertChainlinkConfig(feed);
                _assertGuard(migrationChainlinkAdaptor, feed);
            } else {
                _assertRedstoneConfig(feed);
                _assertGuard(migrationRedstoneClassicAdaptor, feed);
            }
        }
    }

    function _assertCombinedAggregatorGuardConfigs() internal view {
        for (
            uint256 i;
            i < OracleMigrationSafeBatchFixture.combinedAggregatorGuardCount();
            ++i
        ) {
            OracleMigrationSafeBatchFixture.CombinedAggregatorGuardPlan memory
                item = OracleMigrationSafeBatchFixture
                    .combinedAggregatorGuardAt(i);
            IOracleAdaptor.PriceGuard memory actual =
                ICombinedAggregatorPriceGuard(item.aggregator).pg();

            assertTrue(item.guard.enabled, "combined guard should be enabled");
            assertEq(
                actual.timestampStart,
                item.guard.timestampStart,
                "combined guard ts"
            );
            assertEq(actual.ips, item.guard.ips, "combined guard ips");
            assertEq(
                actual.basePrice, item.guard.basePrice, "combined guard base"
            );
            assertEq(
                actual.minPrice, item.guard.minPrice, "combined guard min"
            );
        }
    }

    function _assertCTokenSupport() internal view {
        for (
            uint256 i; i < OracleMigrationSafeBatchFixture.cTokenCount(); ++i) {
            OracleMigrationSafeBatchFixture.CTokenPlan memory cToken =
                OracleMigrationSafeBatchFixture.cTokenAt(i);
            assertEq(
                liveOracleManager.cTokens(cToken.cToken),
                cToken.asset,
                "live cToken underlying"
            );
            assertEq(
                migrationOracleManager.cTokens(cToken.cToken),
                cToken.asset,
                "migration cToken underlying"
            );
            assertEq(ICToken(cToken.cToken).asset(), cToken.asset, "asset()");
        }
    }

    function _assertChainlinkConfig(
        OracleMigrationSafeBatchFixture.FeedPlan memory feed
    ) internal view {
        (
            bool isConfigured,
            IChainlink aggregator,
            uint8 decimals,
            uint24 heartbeat
        ) = migrationChainlinkAdaptor.assetConfig(feed.asset, feed.inUSD);

        assertTrue(isConfigured, "Chainlink asset not configured");
        assertEq(address(aggregator), feed.feed, "Chainlink feed");
        assertGt(decimals, 0, "Chainlink decimals");
        assertEq(
            heartbeat, _storedHeartbeat(feed.heartbeat), "Chainlink heartbeat"
        );
    }

    function _assertRedstoneConfig(
        OracleMigrationSafeBatchFixture.FeedPlan memory feed
    ) internal view {
        (
            bool isConfigured,
            IRedstone proxy,
            uint8 decimals,
            uint24 heartbeat
        ) = migrationRedstoneClassicAdaptor.assetConfig(feed.asset, feed.inUSD);

        assertTrue(isConfigured, "Redstone asset not configured");
        assertEq(address(proxy), feed.feed, "Redstone feed");
        assertGt(decimals, 0, "Redstone decimals");
        assertEq(
            heartbeat, _storedHeartbeat(feed.heartbeat), "Redstone heartbeat"
        );
        assertEq(proxy.getDataFeedId(), _toBytes32(feed.redstoneId), "feed id");
    }

    function _assertGuard(
        IOracleAdaptor adaptor,
        OracleMigrationSafeBatchFixture.FeedPlan memory feed
    ) internal view {
        _assertGuardSide(adaptor, feed, true);
        _assertGuardSide(adaptor, feed, false);
    }

    function _assertGuardSide(
        IOracleAdaptor adaptor,
        OracleMigrationSafeBatchFixture.FeedPlan memory feed,
        bool inUSD
    ) internal view {
        IOracleAdaptor.PriceGuard memory actual =
            adaptor.getPriceGuard(feed.asset, inUSD);
        bool shouldBeEnabled = feed.guard.enabled && feed.guard.inUSD == inUSD;

        if (!shouldBeEnabled) {
            assertEq(actual.timestampStart, 0, "disabled guard timestamp");
            assertEq(actual.ips, 0, "disabled guard ips");
            assertEq(actual.basePrice, 0, "disabled guard base");
            assertEq(actual.minPrice, 0, "disabled guard min");
            return;
        }

        assertEq(actual.timestampStart, feed.guard.timestampStart, "guard ts");
        assertEq(actual.ips, feed.guard.ips, "guard ips");
        assertEq(actual.basePrice, feed.guard.basePrice, "guard base");
        assertEq(actual.minPrice, feed.guard.minPrice, "guard min");
    }

    function _reportOverview(string memory label) internal {
        _writeSection(label);
        _writeLine(string.concat("- Fork block: ", block.number.toString()));
        _writeLine(
            string.concat("- Fork timestamp: ", block.timestamp.toString())
        );
        _writeLine(
            string.concat(
                "- CentralRegistry OracleManager: ",
                centralRegistry.oracleManager().toHexString()
            )
        );
        _writeLine(
            string.concat(
                "- Candidate OracleManager: ",
                address(migrationOracleManager).toHexString()
            )
        );
        _writeLine(
            string.concat(
                "- Safe batch sha256: ",
                uint256(OracleMigrationSafeBatchFixture.SAFE_BATCH_SHA256)
                    .toHexString()
            )
        );
        _writeLine(
            string.concat(
                "- Config sha256: ",
                uint256(OracleMigrationSafeBatchFixture.CONFIG_SHA256)
                    .toHexString()
            )
        );
    }

    function _reportLiveFeedState() internal {
        _writeSection("Live Feed State Before Replay");
        for (uint256 i; i < OracleMigrationSafeBatchFixture.feedCount(); ++i) {
            OracleMigrationSafeBatchFixture.FeedPlan memory feed =
                OracleMigrationSafeBatchFixture.feedAt(i);
            _writeFeedHeader(feed);
            _writeManagerConfig(liveOracleManager, feed.asset, "live manager");
            _writeKnownAdaptorConfig(
                liveOracleManager, feed.asset, "live adaptor"
            );
            _writePriceRows(liveOracleManager, feed.asset, "live asset");
        }
    }

    function _reportMigrationFeedState() internal {
        _writeSection("Candidate Feed State After Replay");
        for (uint256 i; i < OracleMigrationSafeBatchFixture.feedCount(); ++i) {
            OracleMigrationSafeBatchFixture.FeedPlan memory feed =
                OracleMigrationSafeBatchFixture.feedAt(i);
            _writeFeedHeader(feed);
            _writeManagerConfig(
                migrationOracleManager, feed.asset, "candidate manager"
            );
            _writeKnownAdaptorConfig(
                migrationOracleManager, feed.asset, "candidate adaptor"
            );
            _writePriceRows(
                migrationOracleManager, feed.asset, "candidate asset"
            );
        }
    }

    function _reportFeedSideBySideComparisons() internal {
        _writeSection("Feed Config Side By Side");
        _writeLine(
            "Each table compares live state, candidate state after replaying the Safe batch, and the planned values encoded in the Safe batch fixture."
        );

        for (uint256 i; i < OracleMigrationSafeBatchFixture.feedCount(); ++i) {
            OracleMigrationSafeBatchFixture.FeedPlan memory feed =
                OracleMigrationSafeBatchFixture.feedAt(i);

            _writeLine("");
            _writeLine(
                string.concat(
                    "### ", feed.symbol, " (", feed.asset.toHexString(), ")"
                )
            );
            _writeLine(
                "| Field | Live | Candidate After Replay | Planned Safe Batch |"
            );
            _writeLine("| --- | --- | --- | --- |");
            _writeSideBySideRow(
                "Manager adaptors",
                _adaptorsSummary(liveOracleManager, feed.asset),
                _adaptorsSummary(migrationOracleManager, feed.asset),
                _plannedAdaptorSummary(feed.kind)
            );
            _writeSideBySideRow(
                "Deviation bounds",
                _boundsSummary(liveOracleManager, feed.asset),
                _boundsSummary(migrationOracleManager, feed.asset),
                _plannedBoundsSummary(feed)
            );
            _writeSideBySideRowsForConfig(feed, true);
            _writeSideBySideRowsForConfig(feed, false);
        }
    }

    function _reportPriceComparisons() internal {
        _writeSection("Asset Price Comparison");
        _writeLine(
            "| Asset | Mode | Live Price | Live Error | New Price | New Error | Diff Bps |"
        );
        _writeLine("| --- | --- | ---: | ---: | ---: | ---: | ---: |");

        for (uint256 i; i < OracleMigrationSafeBatchFixture.feedCount(); ++i) {
            OracleMigrationSafeBatchFixture.FeedPlan memory feed =
                OracleMigrationSafeBatchFixture.feedAt(i);
            _writePriceCompareRow(feed.symbol, feed.asset, true, true);
            _writePriceCompareRow(feed.symbol, feed.asset, true, false);
            if (feed.asset == NATIVE_SENTINEL) {
                _writeLine(
                    string.concat(
                        "| ",
                        feed.symbol,
                        " | native lower | skipped | skipped | skipped | skipped | skipped |"
                    )
                );
                _writeLine(
                    string.concat(
                        "| ",
                        feed.symbol,
                        " | native upper | skipped | skipped | skipped | skipped | skipped |"
                    )
                );
                continue;
            }
            _writePriceCompareRow(feed.symbol, feed.asset, false, true);
            _writePriceCompareRow(feed.symbol, feed.asset, false, false);
        }
    }

    function _reportCTokenComparisons() internal {
        _writeSection("cToken Price And Support Comparison");
        _writeLine(
            "| cToken | Underlying | Live Underlying | New Underlying | Live Price | Live Error | New Price | New Error | Diff Bps |"
        );
        _writeLine(
            "| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: |"
        );

        for (
            uint256 i; i < OracleMigrationSafeBatchFixture.cTokenCount(); ++i) {
            OracleMigrationSafeBatchFixture.CTokenPlan memory cToken =
                OracleMigrationSafeBatchFixture.cTokenAt(i);
            (uint256 livePrice, uint256 liveError) =
                liveOracleManager.getPrice(cToken.cToken, true, true);
            (uint256 newPrice, uint256 newError) =
                migrationOracleManager.getPrice(cToken.cToken, true, true);

            _writeLine(
                string.concat(
                    "| ",
                    cToken.symbol,
                    " ",
                    cToken.cToken.toHexString(),
                    " | ",
                    cToken.asset.toHexString(),
                    " | ",
                    liveOracleManager.cTokens(cToken.cToken).toHexString(),
                    " | ",
                    migrationOracleManager.cTokens(cToken.cToken)
                        .toHexString(),
                    " | ",
                    livePrice.toString(),
                    " | ",
                    liveError.toString(),
                    " | ",
                    newPrice.toString(),
                    " | ",
                    newError.toString(),
                    " | ",
                    _diffBps(livePrice, newPrice).toString(),
                    " |"
                )
            );

            if (liveError < BAD_SOURCE) {
                assertLt(newError, BAD_SOURCE, "new cToken price errored");
            }
        }
    }

    function _writePriceCompareRow(
        string memory symbol,
        address asset,
        bool inUSD,
        bool getLower
    ) internal {
        (uint256 livePrice, uint256 liveError) =
            liveOracleManager.getPrice(asset, inUSD, getLower);
        (uint256 newPrice, uint256 newError) =
            migrationOracleManager.getPrice(asset, inUSD, getLower);

        _writeLine(
            string.concat(
                "| ",
                symbol,
                " | ",
                inUSD ? "USD" : "native",
                getLower ? " lower" : " upper",
                " | ",
                livePrice.toString(),
                " | ",
                liveError.toString(),
                " | ",
                newPrice.toString(),
                " | ",
                newError.toString(),
                " | ",
                _diffBps(livePrice, newPrice).toString(),
                " |"
            )
        );

        if (liveError < BAD_SOURCE) {
            assertLt(newError, BAD_SOURCE, "new asset price errored");
        }
    }

    function _writeSideBySideRowsForConfig(
        OracleMigrationSafeBatchFixture.FeedPlan memory feed,
        bool inUSD
    ) internal {
        string memory prefix = inUSD ? "USD" : "Native";

        _writeSideBySideRow(
            string.concat(prefix, " configured"),
            _configConfigured(liveOracleManager, feed.asset, inUSD),
            _configConfigured(migrationOracleManager, feed.asset, inUSD),
            _plannedConfigured(feed, inUSD)
        );
        _writeSideBySideRow(
            string.concat(prefix, " feed"),
            _configFeed(liveOracleManager, feed.asset, inUSD),
            _configFeed(migrationOracleManager, feed.asset, inUSD),
            _plannedFeed(feed, inUSD)
        );
        _writeSideBySideRow(
            string.concat(prefix, " decimals"),
            _configDecimals(liveOracleManager, feed.asset, inUSD),
            _configDecimals(migrationOracleManager, feed.asset, inUSD),
            _plannedDecimals(feed, inUSD)
        );
        _writeSideBySideRow(
            string.concat(prefix, " heartbeat"),
            _configHeartbeat(liveOracleManager, feed.asset, inUSD),
            _configHeartbeat(migrationOracleManager, feed.asset, inUSD),
            _plannedHeartbeat(feed, inUSD)
        );
        _writeSideBySideRow(
            string.concat(prefix, " guard timestampStart"),
            _guardTimestampStart(liveOracleManager, feed.asset, inUSD),
            _guardTimestampStart(migrationOracleManager, feed.asset, inUSD),
            _plannedGuardTimestampStart(feed, inUSD)
        );
        _writeSideBySideRow(
            string.concat(prefix, " guard ips"),
            _guardIps(liveOracleManager, feed.asset, inUSD),
            _guardIps(migrationOracleManager, feed.asset, inUSD),
            _plannedGuardIps(feed, inUSD)
        );
        _writeSideBySideRow(
            string.concat(prefix, " guard basePrice"),
            _guardBasePrice(liveOracleManager, feed.asset, inUSD),
            _guardBasePrice(migrationOracleManager, feed.asset, inUSD),
            _plannedGuardBasePrice(feed, inUSD)
        );
        _writeSideBySideRow(
            string.concat(prefix, " guard minPrice"),
            _guardMinPrice(liveOracleManager, feed.asset, inUSD),
            _guardMinPrice(migrationOracleManager, feed.asset, inUSD),
            _plannedGuardMinPrice(feed, inUSD)
        );
    }

    function _writeSideBySideRow(
        string memory field,
        string memory liveValue,
        string memory candidateValue,
        string memory plannedValue
    ) internal {
        _writeLine(
            string.concat(
                "| ",
                field,
                " | ",
                liveValue,
                " | ",
                candidateValue,
                " | ",
                plannedValue,
                " |"
            )
        );
    }

    function _adaptorsSummary(OracleManager manager, address asset)
        internal
        view
        returns (string memory result)
    {
        address[] memory adaptors = manager.getPricingAdaptors(asset);
        result = string.concat(adaptors.length.toString(), " adaptor(s)");
        for (uint256 i; i < adaptors.length; ++i) {
            result = string.concat(result, " ", adaptors[i].toHexString());
        }
    }

    function _plannedAdaptorSummary(uint8 kind)
        internal
        pure
        returns (string memory)
    {
        address adaptor = _expectedMigrationAdaptor(kind);
        if (kind == OracleMigrationSafeBatchFixture.KIND_CHAINLINK) {
            return string.concat("Chainlink ", adaptor.toHexString());
        }

        return string.concat("Redstone Classic ", adaptor.toHexString());
    }

    function _boundsSummary(OracleManager manager, address asset)
        internal
        view
        returns (string memory)
    {
        (
            uint16 badSourceUSD,
            uint16 cautionUSD,
            uint16 badSourceNative,
            uint16 cautionNative
        ) = manager.assetPricingConfig(asset);

        return string.concat(
            "badUSD=",
            uint256(badSourceUSD).toString(),
            ", cautionUSD=",
            uint256(cautionUSD).toString(),
            ", badNative=",
            uint256(badSourceNative).toString(),
            ", cautionNative=",
            uint256(cautionNative).toString()
        );
    }

    function _plannedBoundsSummary(
        OracleMigrationSafeBatchFixture.FeedPlan memory feed
    ) internal pure returns (string memory) {
        return string.concat(
            "badUSD=",
            uint256(feed.bounds.badSourceUSD).toString(),
            ", cautionUSD=",
            uint256(feed.bounds.cautionUSD).toString(),
            ", badNative=",
            uint256(feed.bounds.badSourceNative).toString(),
            ", cautionNative=",
            uint256(feed.bounds.cautionNative).toString()
        );
    }

    function _configConfigured(
        OracleManager manager,
        address asset,
        bool inUSD
    ) internal view returns (string memory) {
        address adaptor = _firstPricingAdaptor(manager, asset);
        if (adaptor == address(0)) {
            return "no adaptor";
        }

        if (_isChainlinkAdaptor(adaptor)) {
            (bool isConfigured,,,) =
                ChainlinkAdaptor(adaptor).assetConfig(asset, inUSD);
            return _bool(isConfigured);
        }

        if (_isRedstoneClassicAdaptor(adaptor)) {
            (bool isConfigured,,,) =
                RedstoneClassicAdaptor(adaptor).assetConfig(asset, inUSD);
            return _bool(isConfigured);
        }

        return string.concat("unknown adaptor ", adaptor.toHexString());
    }

    function _configFeed(OracleManager manager, address asset, bool inUSD)
        internal
        view
        returns (string memory)
    {
        address adaptor = _firstPricingAdaptor(manager, asset);
        if (adaptor == address(0)) {
            return "no adaptor";
        }

        if (_isChainlinkAdaptor(adaptor)) {
            (, IChainlink aggregator,,) =
                ChainlinkAdaptor(adaptor).assetConfig(asset, inUSD);
            return address(aggregator).toHexString();
        }

        if (_isRedstoneClassicAdaptor(adaptor)) {
            (, IRedstone proxy,,) =
                RedstoneClassicAdaptor(adaptor).assetConfig(asset, inUSD);
            return address(proxy).toHexString();
        }

        return string.concat("unknown adaptor ", adaptor.toHexString());
    }

    function _configDecimals(OracleManager manager, address asset, bool inUSD)
        internal
        view
        returns (string memory)
    {
        address adaptor = _firstPricingAdaptor(manager, asset);
        if (adaptor == address(0)) {
            return "no adaptor";
        }

        if (_isChainlinkAdaptor(adaptor)) {
            (,, uint8 decimals,) =
                ChainlinkAdaptor(adaptor).assetConfig(asset, inUSD);
            return uint256(decimals).toString();
        }

        if (_isRedstoneClassicAdaptor(adaptor)) {
            (,, uint8 decimals,) =
                RedstoneClassicAdaptor(adaptor).assetConfig(asset, inUSD);
            return uint256(decimals).toString();
        }

        return string.concat("unknown adaptor ", adaptor.toHexString());
    }

    function _configHeartbeat(OracleManager manager, address asset, bool inUSD)
        internal
        view
        returns (string memory)
    {
        address adaptor = _firstPricingAdaptor(manager, asset);
        if (adaptor == address(0)) {
            return "no adaptor";
        }

        if (_isChainlinkAdaptor(adaptor)) {
            (,,, uint24 heartbeat) =
                ChainlinkAdaptor(adaptor).assetConfig(asset, inUSD);
            return uint256(heartbeat).toString();
        }

        if (_isRedstoneClassicAdaptor(adaptor)) {
            (,,, uint24 heartbeat) =
                RedstoneClassicAdaptor(adaptor).assetConfig(asset, inUSD);
            return uint256(heartbeat).toString();
        }

        return string.concat("unknown adaptor ", adaptor.toHexString());
    }

    function _guardTimestampStart(
        OracleManager manager,
        address asset,
        bool inUSD
    ) internal view returns (string memory) {
        IOracleAdaptor.PriceGuard memory guard =
            _priceGuard(manager, asset, inUSD);
        return uint256(guard.timestampStart).toString();
    }

    function _guardIps(OracleManager manager, address asset, bool inUSD)
        internal
        view
        returns (string memory)
    {
        IOracleAdaptor.PriceGuard memory guard =
            _priceGuard(manager, asset, inUSD);
        return uint256(guard.ips).toString();
    }

    function _guardBasePrice(OracleManager manager, address asset, bool inUSD)
        internal
        view
        returns (string memory)
    {
        IOracleAdaptor.PriceGuard memory guard =
            _priceGuard(manager, asset, inUSD);
        return uint256(guard.basePrice).toString();
    }

    function _guardMinPrice(OracleManager manager, address asset, bool inUSD)
        internal
        view
        returns (string memory)
    {
        IOracleAdaptor.PriceGuard memory guard =
            _priceGuard(manager, asset, inUSD);
        return uint256(guard.minPrice).toString();
    }

    function _priceGuard(OracleManager manager, address asset, bool inUSD)
        internal
        view
        returns (IOracleAdaptor.PriceGuard memory)
    {
        address adaptor = _firstPricingAdaptor(manager, asset);
        if (adaptor == address(0)) {
            return IOracleAdaptor.PriceGuard({
                timestampStart: 0, ips: 0, basePrice: 0, minPrice: 0
            });
        }

        return IOracleAdaptor(adaptor).getPriceGuard(asset, inUSD);
    }

    function _plannedConfigured(
        OracleMigrationSafeBatchFixture.FeedPlan memory feed,
        bool inUSD
    ) internal pure returns (string memory) {
        return feed.inUSD == inUSD ? "true" : "false";
    }

    function _plannedFeed(
        OracleMigrationSafeBatchFixture.FeedPlan memory feed,
        bool inUSD
    ) internal pure returns (string memory) {
        if (feed.inUSD != inUSD) {
            return "not planned";
        }

        return feed.feed.toHexString();
    }

    function _plannedDecimals(
        OracleMigrationSafeBatchFixture.FeedPlan memory feed,
        bool inUSD
    ) internal pure returns (string memory) {
        if (feed.inUSD != inUSD) {
            return "not planned";
        }

        return "from feed";
    }

    function _plannedHeartbeat(
        OracleMigrationSafeBatchFixture.FeedPlan memory feed,
        bool inUSD
    ) internal pure returns (string memory) {
        if (feed.inUSD != inUSD) {
            return "not planned";
        }

        return string.concat(
            feed.heartbeat.toString(),
            " raw / ",
            uint256(_storedHeartbeat(feed.heartbeat)).toString(),
            " stored"
        );
    }

    function _plannedGuardTimestampStart(
        OracleMigrationSafeBatchFixture.FeedPlan memory feed,
        bool inUSD
    ) internal pure returns (string memory) {
        if (!feed.guard.enabled || feed.guard.inUSD != inUSD) {
            return "0";
        }

        return feed.guard.timestampStart.toString();
    }

    function _plannedGuardIps(
        OracleMigrationSafeBatchFixture.FeedPlan memory feed,
        bool inUSD
    ) internal pure returns (string memory) {
        if (!feed.guard.enabled || feed.guard.inUSD != inUSD) {
            return "0";
        }

        return feed.guard.ips.toString();
    }

    function _plannedGuardBasePrice(
        OracleMigrationSafeBatchFixture.FeedPlan memory feed,
        bool inUSD
    ) internal pure returns (string memory) {
        if (!feed.guard.enabled || feed.guard.inUSD != inUSD) {
            return "0";
        }

        return feed.guard.basePrice.toString();
    }

    function _plannedGuardMinPrice(
        OracleMigrationSafeBatchFixture.FeedPlan memory feed,
        bool inUSD
    ) internal pure returns (string memory) {
        if (!feed.guard.enabled || feed.guard.inUSD != inUSD) {
            return "0";
        }

        return feed.guard.minPrice.toString();
    }

    function _firstPricingAdaptor(OracleManager manager, address asset)
        internal
        view
        returns (address)
    {
        address[] memory adaptors = manager.getPricingAdaptors(asset);
        if (adaptors.length == 0) {
            return address(0);
        }

        return adaptors[0];
    }

    function _isChainlinkAdaptor(address adaptor)
        internal
        pure
        returns (bool)
    {
        return adaptor
                == OracleMigrationSafeBatchFixture.LIVE_CHAINLINK_ADAPTOR
            || adaptor
                == OracleMigrationSafeBatchFixture.MIGRATION_CHAINLINK_ADAPTOR;
    }

    function _isRedstoneClassicAdaptor(address adaptor)
        internal
        pure
        returns (bool)
    {
        return adaptor
                == OracleMigrationSafeBatchFixture.LIVE_REDSTONE_CLASSIC_ADAPTOR
            || adaptor
                == OracleMigrationSafeBatchFixture.MIGRATION_REDSTONE_CLASSIC_ADAPTOR;
    }

    function _writeFeedHeader(
        OracleMigrationSafeBatchFixture.FeedPlan memory feed
    ) internal {
        _writeLine("");
        _writeLine(
            string.concat(
                "### ", feed.symbol, " (", feed.asset.toHexString(), ")"
            )
        );
        _writeLine(
            string.concat(
                "- Planned adaptor: ",
                feed.kind == OracleMigrationSafeBatchFixture.KIND_CHAINLINK
                    ? "Chainlink"
                    : "Redstone Classic"
            )
        );
        _writeLine(string.concat("- Planned feed: ", feed.feed.toHexString()));
        _writeLine(
            string.concat("- Planned heartbeat: ", feed.heartbeat.toString())
        );
        _writeLine(
            string.concat(
                "- Planned guard enabled: ", _bool(feed.guard.enabled)
            )
        );
        if (feed.guard.enabled) {
            _writeLine(
                string.concat(
                    "- Planned guard: inUSD=",
                    _bool(feed.guard.inUSD),
                    ", timestampStart=",
                    feed.guard.timestampStart.toString(),
                    ", ips=",
                    feed.guard.ips.toString(),
                    ", basePrice=",
                    feed.guard.basePrice.toString(),
                    ", minPrice=",
                    feed.guard.minPrice.toString()
                )
            );
        }
    }

    function _writeManagerConfig(
        OracleManager manager,
        address asset,
        string memory label
    ) internal {
        (
            uint16 badSourceUSD,
            uint16 cautionUSD,
            uint16 badSourceNative,
            uint16 cautionNative
        ) = manager.assetPricingConfig(asset);
        address[] memory adaptors = manager.getPricingAdaptors(asset);

        _writeLine(
            string.concat(
                "- ", label, " adaptor count: ", adaptors.length.toString()
            )
        );
        for (uint256 i; i < adaptors.length; ++i) {
            _writeLine(
                string.concat(
                    "  - ",
                    label,
                    " adaptor ",
                    i.toString(),
                    ": ",
                    adaptors[i].toHexString()
                )
            );
        }
        _writeLine(
            string.concat(
                "- ",
                label,
                " bounds: badUSD=",
                uint256(badSourceUSD).toString(),
                ", cautionUSD=",
                uint256(cautionUSD).toString(),
                ", badNative=",
                uint256(badSourceNative).toString(),
                ", cautionNative=",
                uint256(cautionNative).toString()
            )
        );
    }

    function _writeKnownAdaptorConfig(
        OracleManager manager,
        address asset,
        string memory label
    ) internal {
        address[] memory adaptors = manager.getPricingAdaptors(asset);
        for (uint256 i; i < adaptors.length; ++i) {
            if (
                adaptors[i]
                        == OracleMigrationSafeBatchFixture.LIVE_CHAINLINK_ADAPTOR
                    || adaptors[i]
                        == OracleMigrationSafeBatchFixture.MIGRATION_CHAINLINK_ADAPTOR
            ) {
                _writeChainlinkConfig(
                    ChainlinkAdaptor(adaptors[i]), asset, label
                );
            } else if (
                adaptors[i]
                        == OracleMigrationSafeBatchFixture.LIVE_REDSTONE_CLASSIC_ADAPTOR
                    || adaptors[i]
                        == OracleMigrationSafeBatchFixture.MIGRATION_REDSTONE_CLASSIC_ADAPTOR
            ) {
                _writeRedstoneConfig(
                    RedstoneClassicAdaptor(adaptors[i]), asset, label
                );
            } else {
                _writeLine(
                    string.concat(
                        "- ",
                        label,
                        " unknown adaptor: ",
                        adaptors[i].toHexString()
                    )
                );
            }
        }
    }

    function _writeChainlinkConfig(
        ChainlinkAdaptor adaptor,
        address asset,
        string memory label
    ) internal {
        _writeChainlinkSide(adaptor, asset, true, label);
        _writeChainlinkSide(adaptor, asset, false, label);
        _writeGuard(adaptor, asset, true, label);
        _writeGuard(adaptor, asset, false, label);
    }

    function _writeChainlinkSide(
        ChainlinkAdaptor adaptor,
        address asset,
        bool inUSD,
        string memory label
    ) internal {
        (
            bool isConfigured,
            IChainlink aggregator,
            uint8 decimals,
            uint24 heartbeat
        ) = adaptor.assetConfig(asset, inUSD);
        _writeLine(
            string.concat(
                "- ",
                label,
                " Chainlink ",
                inUSD ? "USD" : "native",
                ": configured=",
                _bool(isConfigured),
                ", feed=",
                address(aggregator).toHexString(),
                ", decimals=",
                uint256(decimals).toString(),
                ", storedHeartbeat=",
                uint256(heartbeat).toString()
            )
        );
    }

    function _writeRedstoneConfig(
        RedstoneClassicAdaptor adaptor,
        address asset,
        string memory label
    ) internal {
        _writeRedstoneSide(adaptor, asset, true, label);
        _writeRedstoneSide(adaptor, asset, false, label);
        _writeGuard(adaptor, asset, true, label);
        _writeGuard(adaptor, asset, false, label);
    }

    function _writeRedstoneSide(
        RedstoneClassicAdaptor adaptor,
        address asset,
        bool inUSD,
        string memory label
    ) internal {
        (
            bool isConfigured,
            IRedstone proxy,
            uint8 decimals,
            uint24 heartbeat
        ) = adaptor.assetConfig(asset, inUSD);
        _writeLine(
            string.concat(
                "- ",
                label,
                " Redstone ",
                inUSD ? "USD" : "native",
                ": configured=",
                _bool(isConfigured),
                ", feed=",
                address(proxy).toHexString(),
                ", decimals=",
                uint256(decimals).toString(),
                ", storedHeartbeat=",
                uint256(heartbeat).toString()
            )
        );
    }

    function _writeGuard(
        IOracleAdaptor adaptor,
        address asset,
        bool inUSD,
        string memory label
    ) internal {
        IOracleAdaptor.PriceGuard memory guard =
            adaptor.getPriceGuard(asset, inUSD);
        _writeLine(
            string.concat(
                "- ",
                label,
                " guard ",
                inUSD ? "USD" : "native",
                ": timestampStart=",
                uint256(guard.timestampStart).toString(),
                ", ips=",
                uint256(guard.ips).toString(),
                ", basePrice=",
                uint256(guard.basePrice).toString(),
                ", minPrice=",
                uint256(guard.minPrice).toString()
            )
        );
    }

    function _writePriceRows(
        OracleManager manager,
        address asset,
        string memory label
    ) internal {
        _writePriceRow(manager, asset, true, true, label);
        _writePriceRow(manager, asset, true, false, label);
        _writePriceRow(manager, asset, false, true, label);
        _writePriceRow(manager, asset, false, false, label);
    }

    function _writePriceRow(
        OracleManager manager,
        address asset,
        bool inUSD,
        bool getLower,
        string memory label
    ) internal {
        (uint256 price, uint256 errorCode) =
            manager.getPrice(asset, inUSD, getLower);
        _writeLine(
            string.concat(
                "- ",
                label,
                " price ",
                inUSD ? "USD" : "native",
                getLower ? " lower" : " upper",
                ": price=",
                price.toString(),
                ", error=",
                errorCode.toString()
            )
        );
    }

    function _writeReportHeader() internal {
        vm.writeFile(
            REPORT_PATH, "# Oracle Migration Safe Batch Replay Report\n\n"
        );
        _writeLine(
            "This report is generated by `TestOracleMigrationSafeBatchReplayMonadFork`."
        );
        _writeLine(
            "It replays the pre-switch Safe batch semantics on a Monad mainnet fork and intentionally does not call `CentralRegistry.setOracleManager()`."
        );
        _writeLine("");
        _writeLine("## Summary");
        _writeLine(
            string.concat(
                "- Safe batch transactions replayed: ",
                OracleMigrationSafeBatchFixture.txCount().toString()
            )
        );
        _writeLine(
            string.concat(
                "- Feed assets checked: ",
                OracleMigrationSafeBatchFixture.feedCount().toString()
            )
        );
        _writeLine(
            string.concat(
                "- cTokens checked: ",
                OracleMigrationSafeBatchFixture.cTokenCount().toString()
            )
        );
        _writeLine(
            "- Registry switch excluded: `CentralRegistry.setOracleManager()` is rejected by selector."
        );
        _writeLine(
            "- MON native-mode pricing is logged in the detailed sections but skipped in the asset comparison table; MON USD pricing is compared."
        );
    }

    function _writeSection(string memory value) internal {
        _writeLine("");
        _writeLine(string.concat("## ", value));
    }

    function _writeLine(string memory value) internal {
        vm.writeLine(REPORT_PATH, value);
    }

    function _expectedMigrationAdaptor(uint8 kind)
        internal
        pure
        returns (address)
    {
        if (kind == OracleMigrationSafeBatchFixture.KIND_CHAINLINK) {
            return OracleMigrationSafeBatchFixture.MIGRATION_CHAINLINK_ADAPTOR;
        }

        return
            OracleMigrationSafeBatchFixture.MIGRATION_REDSTONE_CLASSIC_ADAPTOR;
    }

    function _storedHeartbeat(uint256 heartbeat)
        internal
        pure
        returns (uint24)
    {
        if (heartbeat == 0) {
            return uint24(1 days + HEARTBEAT_GRACE_PERIOD);
        }

        return uint24(heartbeat + HEARTBEAT_GRACE_PERIOD);
    }

    function _selector(bytes memory data)
        internal
        pure
        returns (bytes4 result)
    {
        require(data.length >= 4, "missing selector");
        assembly {
            result := mload(add(data, 32))
        }
    }

    function _toBytes32(string memory value)
        internal
        pure
        returns (bytes32 result)
    {
        bytes memory raw = bytes(value);
        if (raw.length == 0) {
            return bytes32(0);
        }

        require(raw.length <= 32, "string too long");
        assembly {
            result := mload(add(raw, 32))
        }
    }

    function _diffBps(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == b) {
            return 0;
        }

        uint256 denominator = a == 0 ? b : a;
        if (denominator == 0) {
            return 0;
        }

        uint256 diff = a > b ? a - b : b - a;
        return diff * 10_000 / denominator;
    }

    function _bool(bool value) internal pure returns (string memory) {
        return value ? "true" : "false";
    }
}
