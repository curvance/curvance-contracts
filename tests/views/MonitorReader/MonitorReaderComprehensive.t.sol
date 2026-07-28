// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {
    MonitorReaderTest,
    MonitorMockCentralRegistry,
    MonitorMockCToken,
    MonitorMockMarketManager,
    MonitorMockOptimizer,
    MonitorMockUnderlying
} from "./MonitorReader.t.sol";

import {MonitorReader} from "contracts/views/MonitorReader.sol";

contract MonitorMockLargeMarketManager {
    function queryTokensListed()
        external
        pure
        returns (address[] memory cTokens)
    {
        cTokens = new address[](513);
        for (uint256 i; i < cTokens.length; ++i) {
            cTokens[i] = address(uint160(i + 1));
        }
    }
}

contract MonitorReaderHarness is MonitorReader {
    function packSignal(
        address subject,
        uint8 findingCode,
        uint8 family,
        uint16 affectedCount,
        uint8 subjectType
    ) external pure returns (uint256) {
        SignalAccumulator memory signal = SignalAccumulator({
            firstSubject: subject,
            affectedCount: affectedCount,
            findingCode: findingCode,
            subjectType: subjectType
        });
        return _packSignal(signal, family);
    }

    function recordBehavior()
        external
        pure
        returns (
            address subject,
            uint16 count,
            uint8 findingCode,
            uint8 subjectType
        )
    {
        SignalAccumulator memory signal;
        _record(signal, address(0xA11CE), SUBJECT_CTOKEN, 7);
        _record(signal, address(0xB0B), SUBJECT_OPTIMIZER, 0);
        _record(signal, address(0xB0B), SUBJECT_OPTIMIZER, 9);
        return (
            signal.firstSubject,
            signal.affectedCount,
            signal.findingCode,
            signal.subjectType
        );
    }

    function saturatedRecordCount() external pure returns (uint16) {
        SignalAccumulator memory signal = SignalAccumulator({
            firstSubject: address(0xA11CE),
            affectedCount: type(uint16).max,
            findingCode: 1,
            subjectType: SUBJECT_CTOKEN
        });
        _record(signal, address(0xB0B), SUBJECT_OPTIMIZER, 2);
        return signal.affectedCount;
    }

    function cTokenLimitSignal(address centralRegistry)
        external
        pure
        returns (uint256)
    {
        SignalAccumulator[5] memory signals;
        AdvisoryScanState memory state;
        state.seenCTokens = new address[](MAX_TRACKED_CTOKENS);
        state.seenAssets = new address[](MAX_TRACKED_ORACLE_ASSETS);
        state.seenCTokenCount = MAX_TRACKED_CTOKENS;
        CTokenStatus memory token;

        _processAdvisoryToken(
            centralRegistry, address(1), address(2), token, signals, state
        );
        return _packSignal(signals[4], FAMILY_ADVISORY_READ_FAILURE);
    }

    function oracleAssetLimitSignal(address centralRegistry)
        external
        pure
        returns (uint256)
    {
        SignalAccumulator[5] memory signals;
        AdvisoryScanState memory state;
        state.seenCTokens = new address[](MAX_TRACKED_CTOKENS);
        state.seenAssets = new address[](MAX_TRACKED_ORACLE_ASSETS);
        state.seenAssetCount = MAX_TRACKED_ORACLE_ASSETS;
        CTokenStatus memory token;
        token.underlying = address(3);

        _processAdvisoryToken(
            centralRegistry, address(1), address(2), token, signals, state
        );
        return _packSignal(signals[4], FAMILY_ADVISORY_READ_FAILURE);
    }

    function bitCode(uint256 mask) external pure returns (uint8) {
        return _bitCode(mask);
    }

    function firstBitIndex(uint256 mask) external pure returns (uint8) {
        return _firstBitIndex(mask);
    }

    function withinTolerance(uint256 a, uint256 b, uint256 tolerance)
        external
        pure
        returns (bool)
    {
        return _withinTolerance(a, b, tolerance);
    }
}

contract MonitorReaderComprehensiveTest is MonitorReaderTest {
    MonitorReaderHarness internal harness;

    function setUp() public override {
        super.setUp();
        harness = new MonitorReaderHarness();
    }

    /// SIGNAL ENCODING ///

    function testFuzz_signalPackingRoundTripsWithoutFieldCollisions(
        address subject,
        uint8 findingCode,
        uint8 family,
        uint16 affectedCount,
        uint8 subjectType
    ) public view {
        if (affectedCount == 0) affectedCount = 1;

        uint256 signal = harness.packSignal(
            subject, findingCode, family, affectedCount, subjectType
        );
        (
            address decodedSubject,
            uint8 decodedCode,
            uint8 decodedFamily,
            uint16 decodedCount,
            uint8 decodedType,
            uint8 decodedVersion
        ) = reader.decodeSignal(signal);

        assertEq(decodedSubject, subject);
        assertEq(decodedCode, findingCode);
        assertEq(decodedFamily, family);
        assertEq(decodedCount, affectedCount);
        assertEq(decodedType, subjectType);
        assertEq(decodedVersion, reader.SIGNAL_ENCODING_VERSION());
        assertEq(signal >> 208, 0);
    }

    function test_signalFieldsUseDisjointBitRanges() public view {
        uint256 base = harness.packSignal(address(1), 1, 1, 1, 1);
        assertNotEq(base, harness.packSignal(address(2), 1, 1, 1, 1));
        assertNotEq(base, harness.packSignal(address(1), 2, 1, 1, 1));
        assertNotEq(base, harness.packSignal(address(1), 1, 2, 1, 1));
        assertNotEq(base, harness.packSignal(address(1), 1, 1, 2, 1));
        assertNotEq(base, harness.packSignal(address(1), 1, 1, 1, 2));

        uint256 maximum = harness.packSignal(
            address(type(uint160).max),
            type(uint8).max,
            type(uint8).max,
            type(uint16).max,
            type(uint8).max
        );
        (
            address subject,
            uint8 code,
            uint8 family,
            uint16 count,
            uint8 subjectType,
            uint8 version
        ) = reader.decodeSignal(maximum);
        assertEq(subject, address(type(uint160).max));
        assertEq(code, type(uint8).max);
        assertEq(family, type(uint8).max);
        assertEq(count, type(uint16).max);
        assertEq(subjectType, type(uint8).max);
        assertEq(version, 1);
    }

    function test_decodeIgnoresReservedBitsWithoutCorruptingFields()
        public
        view
    {
        uint256 signal = harness.packSignal(address(0xA11CE), 36, 1, 17, 3);
        signal |= uint256(type(uint48).max) << 208;

        _assertDecoded(signal, address(0xA11CE), 36, 1, 17, 3);
    }

    function test_zeroSignalAndEmptyAccumulatorDecodeToAllZero() public view {
        assertEq(harness.packSignal(address(1), 1, 1, 0, 1), 0);

        (
            address subject,
            uint8 code,
            uint8 family,
            uint16 count,
            uint8 subjectType,
            uint8 version
        ) = reader.decodeSignal(0);
        assertEq(subject, address(0));
        assertEq(code, 0);
        assertEq(family, 0);
        assertEq(count, 0);
        assertEq(subjectType, 0);
        assertEq(version, 0);
    }

    function test_recordIgnoresZeroPreservesFirstAndCountsAllFindings()
        public
        view
    {
        (address subject, uint16 count, uint8 code, uint8 subjectType) =
            harness.recordBehavior();
        assertEq(subject, address(0xA11CE));
        assertEq(count, 2);
        assertEq(code, 7);
        assertEq(subjectType, reader.SUBJECT_CTOKEN());
        assertEq(harness.saturatedRecordCount(), type(uint16).max);
    }

    function test_definedSignalNamespacesHaveNoCollisions() public view {
        assertEq(reader.SUBJECT_CENTRAL_REGISTRY(), 1);
        assertEq(reader.SUBJECT_MARKET_MANAGER(), 2);
        assertEq(reader.SUBJECT_CTOKEN(), 3);
        assertEq(reader.SUBJECT_ASSET(), 4);
        assertEq(reader.SUBJECT_OPTIMIZER(), 5);

        assertEq(reader.FAMILY_CRITICAL_WIRING(), 1);
        assertEq(reader.FAMILY_CRITICAL_TOKEN_ACCOUNTING(), 2);
        assertEq(reader.FAMILY_CRITICAL_BACKING(), 3);
        assertEq(reader.FAMILY_CRITICAL_BORROW_ACCOUNTING(), 4);
        assertEq(reader.FAMILY_CRITICAL_OPTIMIZER(), 5);
        assertEq(reader.FAMILY_ADVISORY_ORACLE_ZERO(), 6);
        assertEq(reader.FAMILY_ADVISORY_ORACLE_DEGRADED(), 7);
        assertEq(reader.FAMILY_ADVISORY_COLLATERAL_OR_CAP(), 8);
        assertEq(reader.FAMILY_ADVISORY_OPTIMIZER(), 9);
        assertEq(reader.FAMILY_ADVISORY_READ_FAILURE(), 10);

        uint256[] memory cTokenBroken = new uint256[](16);
        cTokenBroken[0] = reader.CTOKEN_BROKEN_MANAGER_ZERO();
        cTokenBroken[1] = reader.CTOKEN_BROKEN_ASSET_ZERO();
        cTokenBroken[2] = reader.CTOKEN_BROKEN_NOT_LISTED();
        cTokenBroken[3] = reader.CTOKEN_BROKEN_MANAGER_MISMATCH();
        cTokenBroken[4] = reader.CTOKEN_BROKEN_ORACLE_BINDING();
        cTokenBroken[5] = reader.CTOKEN_BROKEN_COLLATERAL_SHARES();
        cTokenBroken[6] = reader.CTOKEN_BROKEN_SUPPLY_ZERO();
        cTokenBroken[7] = reader.CTOKEN_BROKEN_TOTAL_ASSETS_ZERO();
        cTokenBroken[8] = reader.CTOKEN_BROKEN_EXCHANGE_RATE_ZERO();
        cTokenBroken[9] = reader.CTOKEN_BROKEN_CONVERSION();
        cTokenBroken[10] = reader.CTOKEN_BROKEN_RESERVE();
        cTokenBroken[11] = reader.CTOKEN_BROKEN_CASH();
        cTokenBroken[12] = reader.CTOKEN_BROKEN_VESTING_CLOCK();
        cTokenBroken[13] = reader.CTOKEN_BROKEN_DEBT_INDEX();
        cTokenBroken[14] = reader.CTOKEN_BROKEN_ORACLE_LOWER();
        cTokenBroken[15] = reader.CTOKEN_BROKEN_ORACLE_UPPER();
        _assertUniqueOneHot(cTokenBroken);

        uint256[] memory cTokenWarnings = new uint256[](4);
        cTokenWarnings[0] = reader.CTOKEN_WARNING_ORACLE_LOWER();
        cTokenWarnings[1] = reader.CTOKEN_WARNING_ORACLE_UPPER();
        cTokenWarnings[2] = reader.CTOKEN_WARNING_COLLATERAL_CAP();
        cTokenWarnings[3] = reader.CTOKEN_WARNING_DEBT_CAP();
        _assertUniqueOneHot(cTokenWarnings);

        uint256[] memory cTokenReads = new uint256[](19);
        cTokenReads[0] = reader.CTOKEN_READ_IS_BORROWABLE();
        cTokenReads[1] = reader.CTOKEN_READ_MANAGER();
        cTokenReads[2] = reader.CTOKEN_READ_ASSET();
        cTokenReads[3] = reader.CTOKEN_READ_LISTED();
        cTokenReads[4] = reader.CTOKEN_READ_SUPPLY();
        cTokenReads[5] = reader.CTOKEN_READ_TOTAL_ASSETS();
        cTokenReads[6] = reader.CTOKEN_READ_DEAD_SHARES();
        cTokenReads[7] = reader.CTOKEN_READ_COLLATERAL();
        cTokenReads[8] = reader.CTOKEN_READ_EXCHANGE_RATE();
        cTokenReads[9] = reader.CTOKEN_READ_CONVERSION();
        cTokenReads[10] = reader.CTOKEN_READ_ORACLE_BINDING();
        cTokenReads[11] = reader.CTOKEN_READ_UNDERLYING_BALANCE();
        cTokenReads[12] = reader.CTOKEN_READ_DEBT();
        cTokenReads[13] = reader.CTOKEN_READ_ASSETS_HELD();
        cTokenReads[14] = reader.CTOKEN_READ_YIELD();
        cTokenReads[15] = reader.CTOKEN_READ_ORACLE_LOWER();
        cTokenReads[16] = reader.CTOKEN_READ_ORACLE_UPPER();
        cTokenReads[17] = reader.CTOKEN_READ_COLLATERAL_CAP();
        cTokenReads[18] = reader.CTOKEN_READ_DEBT_CAP();
        _assertUniqueOneHot(cTokenReads);

        uint256[] memory optimizerBroken = new uint256[](15);
        optimizerBroken[0] = reader.OPTIMIZER_BROKEN_ADDRESS_ZERO();
        optimizerBroken[1] = reader.OPTIMIZER_BROKEN_ASSET_ZERO();
        optimizerBroken[2] = reader.OPTIMIZER_BROKEN_MARKET_COUNT();
        optimizerBroken[3] = reader.OPTIMIZER_BROKEN_MARKET_ZERO();
        optimizerBroken[4] = reader.OPTIMIZER_BROKEN_DUPLICATE_MARKET();
        optimizerBroken[5] = reader.OPTIMIZER_BROKEN_CAP();
        optimizerBroken[6] = reader.OPTIMIZER_BROKEN_CAP_SUM();
        optimizerBroken[7] = reader.OPTIMIZER_BROKEN_NOT_BORROWABLE();
        optimizerBroken[8] = reader.OPTIMIZER_BROKEN_UNDERLYING();
        optimizerBroken[9] = reader.OPTIMIZER_BROKEN_NOT_LISTED();
        optimizerBroken[10] = reader.OPTIMIZER_BROKEN_ACCOUNTING();
        optimizerBroken[11] = reader.OPTIMIZER_BROKEN_SUPPLY_ZERO();
        optimizerBroken[12] = reader.OPTIMIZER_BROKEN_DEAD_SHARES();
        optimizerBroken[13] = reader.OPTIMIZER_BROKEN_EXCHANGE_RATE();
        optimizerBroken[14] = reader.OPTIMIZER_BROKEN_CONVERSION();
        _assertUniqueOneHot(optimizerBroken);

        uint256[] memory optimizerWarnings = new uint256[](2);
        optimizerWarnings[0] = reader.OPTIMIZER_WARNING_BELOW_HIGH_WATERMARK();
        optimizerWarnings[1] = reader.OPTIMIZER_WARNING_MINT_PAUSED();
        _assertUniqueOneHot(optimizerWarnings);

        uint256[] memory optimizerReads = new uint256[](12);
        optimizerReads[0] = reader.OPTIMIZER_READ_ASSET();
        optimizerReads[1] = reader.OPTIMIZER_READ_MARKET_COUNT();
        optimizerReads[2] = reader.OPTIMIZER_READ_MARKET();
        optimizerReads[3] = reader.OPTIMIZER_READ_CAP();
        optimizerReads[4] = reader.OPTIMIZER_READ_TOTAL_ASSETS();
        optimizerReads[5] = reader.OPTIMIZER_READ_SUPPLY();
        optimizerReads[6] = reader.OPTIMIZER_READ_DEAD_SHARES();
        optimizerReads[7] = reader.OPTIMIZER_READ_EXCHANGE_RATE();
        optimizerReads[8] = reader.OPTIMIZER_READ_HIGH_WATERMARK();
        optimizerReads[9] = reader.OPTIMIZER_READ_CONVERSION();
        optimizerReads[10] = reader.OPTIMIZER_READ_MINT_PAUSED();
        optimizerReads[11] = reader.OPTIMIZER_READ_POSITION();
        _assertUniqueOneHot(optimizerReads);

        for (uint256 i; i < optimizerBroken.length; ++i) {
            assertEq(harness.bitCode(optimizerBroken[i]), i + 1);
        }
        for (uint256 i; i < optimizerWarnings.length; ++i) {
            assertEq(harness.bitCode(optimizerWarnings[i]), i + 1);
        }
        assertEq(harness.bitCode(0), 0);
        assertEq(harness.firstBitIndex(0), 0);
    }

    function test_withinToleranceIsSymmetricAndInclusive() public view {
        assertTrue(harness.withinTolerance(100, 101, 1));
        assertTrue(harness.withinTolerance(101, 100, 1));
        assertFalse(harness.withinTolerance(100, 102, 1));
        assertFalse(harness.withinTolerance(102, 100, 1));
    }

    /// ORACLE SIGNALS ///

    function test_checkOracleClassifiesEveryStateWithoutOverlap() public {
        MonitorReader.OracleStatus memory status = reader.checkOracle(
            address(oracleManager), address(underlying), true, true
        );
        assertEq(status.price, 1e18);
        assertEq(status.brokenMask, 0);
        assertEq(status.warningMask, 0);
        assertEq(status.readErrorMask, 0);

        oracleManager.setDirectionalPrices(0, 0, 1e18, 0);
        status = reader.checkOracle(
            address(oracleManager), address(underlying), true, true
        );
        assertEq(status.brokenMask, reader.ORACLE_BROKEN_PRICE_ZERO());

        oracleManager.setDirectionalPrices(1e18, 1, 1e18, 0);
        status = reader.checkOracle(
            address(oracleManager), address(underlying), true, true
        );
        assertEq(status.warningMask, reader.ORACLE_WARNING_CAUTION());
        assertEq(status.brokenMask, 0);

        oracleManager.setDirectionalPrices(1e18, 2, 1e18, 0);
        status = reader.checkOracle(
            address(oracleManager), address(underlying), true, true
        );
        assertEq(status.brokenMask, reader.ORACLE_BROKEN_BAD_SOURCE());

        oracleManager.setDirectionalPrices(1e18, 3, 1e18, 0);
        status = reader.checkOracle(
            address(oracleManager), address(underlying), true, true
        );
        assertEq(status.brokenMask, reader.ORACLE_BROKEN_UNKNOWN_ERROR());

        oracleManager.setDirectionalReverts(true, false);
        status = reader.checkOracle(
            address(oracleManager), address(underlying), true, true
        );
        assertEq(status.brokenMask, 0);
        assertEq(status.warningMask, 0);
        assertEq(status.readErrorMask, reader.ORACLE_READ_PRICE());
    }

    function test_oracleZeroCodesDistinguishLowerAndUpper() public {
        oracleManager.setDirectionalPrices(0, 0, 1e18, 0);
        _assertOracleZeroCode(1);

        oracleManager.setDirectionalPrices(1e18, 0, 0, 0);
        _assertOracleZeroCode(2);

        oracleManager.setDirectionalPrices(0, 0, 0, 0);
        _assertOracleZeroCode(1);
    }

    function test_oracleDegradedCodesCoverAllDirectionsAndStates() public {
        _assertOracleDegradedCode(1e18, 2, 1e18, 0, 1);
        _assertOracleDegradedCode(1e18, 0, 1e18, 2, 2);
        _assertOracleDegradedCode(1e18, 3, 1e18, 0, 3);
        _assertOracleDegradedCode(1e18, 0, 1e18, 3, 4);
        _assertOracleDegradedCode(1e18, 1, 1e18, 0, 5);
        _assertOracleDegradedCode(1e18, 0, 1e18, 1, 6);

        _assertOracleDegradedCode(1e18, 2, 1e18, 2, 1);
    }

    function test_sameOracleAssetIsCountedOnceAcrossCTokens() public {
        MonitorMockCToken secondCToken =
            new MonitorMockCToken(address(underlying), address(manager));
        manager.addToken(address(secondCToken));
        manager.setCaps(
            address(secondCToken), type(uint256).max, type(uint256).max
        );
        oracleManager.setCToken(address(secondCToken), address(underlying));
        _configureHealthyCToken(secondCToken, underlying);
        oracleManager.setPrice(0, 0);

        address[] memory optimizers = new address[](0);
        (uint256 oracleZero,,,,) =
            reader.advisorySignals(address(registry), optimizers);
        _assertDecoded(
            oracleZero,
            address(underlying),
            1,
            reader.FAMILY_ADVISORY_ORACLE_ZERO(),
            1,
            reader.SUBJECT_ASSET()
        );
    }

    /// REGISTRY AND WIRING SIGNALS ///

    function test_registryFailureModesAreSeparatedByCodeAndLane() public {
        address[] memory optimizers = new address[](0);

        (uint256 wiring,,,,) = reader.criticalSignals(address(0), optimizers);
        _assertDecoded(
            wiring,
            address(0),
            1,
            reader.FAMILY_CRITICAL_WIRING(),
            1,
            reader.SUBJECT_CENTRAL_REGISTRY()
        );
        (,,,, uint256 readFailure) =
            reader.advisorySignals(address(0), optimizers);
        _assertDecoded(
            readFailure,
            address(0),
            1,
            reader.FAMILY_ADVISORY_READ_FAILURE(),
            1,
            reader.SUBJECT_CENTRAL_REGISTRY()
        );

        registry.setRevertMarkets(true);
        (wiring,,,,) = reader.criticalSignals(address(registry), optimizers);
        assertEq(wiring, 0);
        (,,,, readFailure) =
            reader.advisorySignals(address(registry), optimizers);
        _assertDecoded(
            readFailure,
            address(registry),
            2,
            reader.FAMILY_ADVISORY_READ_FAILURE(),
            1,
            reader.SUBJECT_CENTRAL_REGISTRY()
        );

        registry.setRevertMarkets(false);
        registry.setRevertOracleManager(true);
        (wiring,,,,) = reader.criticalSignals(address(registry), optimizers);
        assertEq(wiring, 0);
        (,,,, readFailure) =
            reader.advisorySignals(address(registry), optimizers);
        _assertDecoded(
            readFailure,
            address(registry),
            3,
            reader.FAMILY_ADVISORY_READ_FAILURE(),
            1,
            reader.SUBJECT_CENTRAL_REGISTRY()
        );

        registry.setRevertOracleManager(false);
        registry.setOracleManager(address(0));
        (wiring,,,,) = reader.criticalSignals(address(registry), optimizers);
        _assertDecoded(
            wiring,
            address(registry),
            2,
            reader.FAMILY_CRITICAL_WIRING(),
            1,
            reader.SUBJECT_CENTRAL_REGISTRY()
        );
    }

    function test_marketWiringCodesCoverZeroAndDuplicates() public {
        registry.addMarket(address(0));
        _assertCriticalWiring(address(0), 16, 1);

        setUp();
        manager.addToken(address(0));
        _assertCriticalWiring(address(manager), 18, 1);

        setUp();
        manager.addToken(address(cToken));
        _assertCriticalWiring(address(manager), 19, 1);

        setUp();
        registry.addMarket(address(manager));
        _assertCriticalWiring(address(manager), 20, 1);
    }

    function test_cTokenWiringCodesAndPriorityAreCollisionFree() public {
        vm.mockCall(
            address(cToken),
            abi.encodeWithSignature("marketManager()"),
            abi.encode(address(0))
        );
        _assertCriticalWiring(address(cToken), 32, 1);

        setUp();
        vm.mockCall(
            address(cToken),
            abi.encodeWithSignature("asset()"),
            abi.encode(address(0))
        );
        _assertCriticalWiring(address(cToken), 33, 1);

        setUp();
        manager.setListed(address(cToken), false);
        _assertCriticalWiring(address(cToken), 34, 1);

        setUp();
        MonitorMockMarketManager secondManager = new MonitorMockMarketManager();
        secondManager.addToken(address(cToken));
        vm.mockCall(
            address(cToken),
            abi.encodeWithSignature("marketManager()"),
            abi.encode(address(secondManager))
        );
        _assertCriticalWiring(address(cToken), 35, 1);

        setUp();
        oracleManager.setCToken(address(cToken), address(0xBAD));
        _assertCriticalWiring(address(cToken), 36, 1);

        setUp();
        vm.mockCall(
            address(cToken),
            abi.encodeWithSignature("marketManager()"),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(cToken),
            abi.encodeWithSignature("asset()"),
            abi.encode(address(0))
        );
        _assertCriticalWiring(address(cToken), 32, 1);
    }

    function test_checkMarketDirectFailureAndAggregationPaths() public {
        MonitorReader.MarketStatus memory status =
            reader.checkMarket(address(0), address(oracleManager));
        assertEq(status.brokenMask, reader.MARKET_BROKEN_MANAGER_ZERO());

        MonitorMockMarketManager empty = new MonitorMockMarketManager();
        status = reader.checkMarket(address(empty), address(oracleManager));
        assertEq(status.brokenMask, reader.MARKET_BROKEN_NO_TOKENS());

        empty.setRevertTokenList(true);
        status = reader.checkMarket(address(empty), address(oracleManager));
        assertEq(status.readErrorMask, reader.MARKET_READ_TOKEN_LIST());

        manager.setCaps(address(cToken), 99_999_999, type(uint256).max);
        status = reader.checkMarket(address(manager), address(oracleManager));
        assertEq(status.warningMask, reader.MARKET_WARNING_TOKEN());

        vm.mockCallRevert(
            address(cToken),
            abi.encodeWithSignature("totalAssets()"),
            bytes("read")
        );
        status = reader.checkMarket(address(manager), address(oracleManager));
        assertEq(status.readErrorMask, reader.MARKET_READ_TOKEN());
    }

    /// CTOKEN ACCOUNTING AND ACTIVATION ///

    function test_tokenAccountingCodesAndPriorityAreExact() public {
        cToken.setShareData(0, TOTAL_ASSETS, 0, 0);
        _assertCriticalTokenAccounting(1);

        setUp();
        cToken.setShareData(TOTAL_ASSETS, 0, RESERVE, 0);
        _assertCriticalTokenAccounting(2);

        setUp();
        vm.mockCall(
            address(cToken),
            abi.encodeWithSignature("exchangeRate()"),
            abi.encode(0)
        );
        _assertCriticalTokenAccounting(3);

        setUp();
        vm.mockCall(
            address(cToken),
            abi.encodeWithSignature("convertToAssets(uint256)", TOTAL_ASSETS),
            abi.encode(TOTAL_ASSETS + 2)
        );
        _assertCriticalTokenAccounting(4);

        setUp();
        cToken.setShareData(0, 0, 0, 0);
        _assertCriticalTokenAccounting(1);
    }

    function test_conversionToleranceBoundariesAreInclusive() public {
        vm.mockCall(
            address(cToken),
            abi.encodeWithSignature("convertToAssets(uint256)", TOTAL_ASSETS),
            abi.encode(TOTAL_ASSETS + 1)
        );
        MonitorReader.CTokenStatus memory status = reader.checkMarketCToken(
            address(cToken), address(manager), address(oracleManager)
        );
        assertEq(status.brokenMask & reader.CTOKEN_BROKEN_CONVERSION(), 0);

        vm.clearMockedCalls();
        vm.mockCall(
            address(cToken),
            abi.encodeWithSignature("convertToAssets(uint256)", TOTAL_ASSETS),
            abi.encode(TOTAL_ASSETS - 1)
        );
        status = reader.checkMarketCToken(
            address(cToken), address(manager), address(oracleManager)
        );
        assertEq(status.brokenMask & reader.CTOKEN_BROKEN_CONVERSION(), 0);

        vm.clearMockedCalls();
        vm.mockCall(
            address(cToken),
            abi.encodeWithSignature("convertToAssets(uint256)", TOTAL_ASSETS),
            abi.encode(TOTAL_ASSETS - 2)
        );
        status = reader.checkMarketCToken(
            address(cToken), address(manager), address(oracleManager)
        );
        assertTrue(status.brokenMask & reader.CTOKEN_BROKEN_CONVERSION() != 0);
    }

    function test_reserveAndCashBoundariesAreExact() public {
        cToken.setBorrowData(TOTAL_ASSETS - RESERVE, 0, 200, 100, 1e18);
        underlying.setBalance(address(cToken), RESERVE);
        _assertAllCriticalSignalsZero();

        cToken.setBorrowData(TOTAL_ASSETS - RESERVE + 1, 0, 200, 100, 1e18);
        _assertCriticalBacking(1);

        cToken.setBorrowData(DEBT, HELD, 200, 100, 1e18);
        underlying.setBalance(address(cToken), HELD + RESERVE);
        _assertAllCriticalSignalsZero();

        underlying.setBalance(address(cToken), HELD + RESERVE - 1);
        _assertCriticalBacking(2);
    }

    function test_reserveFailureSkipsAssetsHeldAndDoesNotInventCashFailure()
        public
    {
        cToken.setBorrowData(TOTAL_ASSETS - RESERVE + 1, HELD, 200, 100, 1e18);
        vm.mockCallRevert(
            address(cToken),
            abi.encodeWithSignature("assetsHeld()"),
            bytes("should not be called")
        );

        MonitorReader.CTokenStatus memory status = reader.checkMarketCToken(
            address(cToken), address(manager), address(oracleManager)
        );
        assertTrue(status.brokenMask & reader.CTOKEN_BROKEN_RESERVE() != 0);
        assertEq(status.brokenMask & reader.CTOKEN_BROKEN_CASH(), 0);
        assertEq(status.readErrorMask & reader.CTOKEN_READ_ASSETS_HELD(), 0);
    }

    function test_borrowAccountingCodesAndActivationBoundary() public {
        cToken.setBorrowData(DEBT, HELD, 100, 101, 1e18);
        _assertCriticalBorrowAccounting(1);

        cToken.setBorrowData(DEBT, HELD, 200, 100, 1e18 - 1);
        _assertCriticalBorrowAccounting(2);

        cToken.setBorrowData(DEBT, HELD, 200, 100, 1e18);
        _assertAllCriticalSignalsZero();

        manager.setCaps(address(cToken), type(uint256).max, 0);
        cToken.setBorrowData(type(uint256).max, type(uint256).max, 0, 1, 0);
        _assertAllCriticalSignalsZero();
    }

    function test_collateralAndCapWarningCodesAndPriorityAreExact() public {
        cToken.setShareData(
            TOTAL_ASSETS, TOTAL_ASSETS, RESERVE, TOTAL_ASSETS - RESERVE + 1
        );
        _assertCollateralOrCapCode(1);

        setUp();
        manager.setCaps(address(cToken), 99_999_999, type(uint256).max);
        _assertCollateralOrCapCode(2);

        setUp();
        manager.setCaps(address(cToken), type(uint256).max, DEBT - 1);
        _assertCollateralOrCapCode(3);

        cToken.setShareData(
            TOTAL_ASSETS, TOTAL_ASSETS, RESERVE, TOTAL_ASSETS - RESERVE + 1
        );
        _assertCollateralOrCapCode(1);
    }

    function test_zeroOracleManagerSkipsOracleReadsWithoutReadFailure()
        public
    {
        registry.setOracleManager(address(0));
        oracleManager.setShouldRevert(true);
        address[] memory optimizers = new address[](0);

        (uint256 wiring,,,,) =
            reader.criticalSignals(address(registry), optimizers);
        _assertDecoded(
            wiring,
            address(registry),
            2,
            reader.FAMILY_CRITICAL_WIRING(),
            1,
            reader.SUBJECT_CENTRAL_REGISTRY()
        );

        (uint256 oracleZero, uint256 degraded,,, uint256 readFailure) =
            reader.advisorySignals(address(registry), optimizers);
        assertEq(oracleZero, 0);
        assertEq(degraded, 0);
        assertEq(readFailure, 0);
    }

    /// READ FAILURE ROUTING ///

    function test_allCTokenReadFailuresMapToCodes32Through50() public {
        address[] memory targets = new address[](19);
        bytes[] memory calls = new bytes[](19);

        targets[0] = address(cToken);
        calls[0] = abi.encodeWithSignature("isBorrowable()");
        targets[1] = address(cToken);
        calls[1] = abi.encodeWithSignature("marketManager()");
        targets[2] = address(cToken);
        calls[2] = abi.encodeWithSignature("asset()");
        targets[3] = address(manager);
        calls[3] =
            abi.encodeWithSignature("isListed(address)", address(cToken));
        targets[4] = address(cToken);
        calls[4] = abi.encodeWithSignature("totalSupply()");
        targets[5] = address(cToken);
        calls[5] = abi.encodeWithSignature("totalAssets()");
        targets[6] = address(cToken);
        calls[6] = abi.encodeWithSignature("balanceOf(address)", address(0));
        targets[7] = address(cToken);
        calls[7] = abi.encodeWithSignature("marketCollateralPosted()");
        targets[8] = address(cToken);
        calls[8] = abi.encodeWithSignature("exchangeRate()");
        targets[9] = address(cToken);
        calls[9] =
            abi.encodeWithSignature("convertToAssets(uint256)", TOTAL_ASSETS);
        targets[10] = address(oracleManager);
        calls[10] =
            abi.encodeWithSignature("cTokens(address)", address(cToken));
        targets[11] = address(underlying);
        calls[11] =
            abi.encodeWithSignature("balanceOf(address)", address(cToken));
        targets[12] = address(cToken);
        calls[12] = abi.encodeWithSignature("marketOutstandingDebt()");
        targets[13] = address(cToken);
        calls[13] = abi.encodeWithSignature("assetsHeld()");
        targets[14] = address(cToken);
        calls[14] = abi.encodeWithSignature("getYieldInformation()");
        targets[15] = address(oracleManager);
        calls[15] = abi.encodeWithSignature(
            "getPrice(address,bool,bool)", address(underlying), true, true
        );
        targets[16] = address(oracleManager);
        calls[16] = abi.encodeWithSignature(
            "getPrice(address,bool,bool)", address(underlying), true, false
        );
        targets[17] = address(manager);
        calls[17] = abi.encodeWithSignature(
            "collateralCaps(address)", address(cToken)
        );
        targets[18] = address(manager);
        calls[18] =
            abi.encodeWithSignature("debtCaps(address)", address(cToken));

        for (uint256 i; i < targets.length; ++i) {
            _assertCTokenReadFailure(targets[i], calls[i], uint8(32 + i));
        }
    }

    function test_readerHealthLimitCodesAreReachableAndDistinct() public {
        uint256 signal = harness.cTokenLimitSignal(address(registry));
        _assertDecoded(
            signal,
            address(registry),
            96,
            reader.FAMILY_ADVISORY_READ_FAILURE(),
            1,
            reader.SUBJECT_CENTRAL_REGISTRY()
        );

        signal = harness.oracleAssetLimitSignal(address(registry));
        _assertDecoded(
            signal,
            address(registry),
            97,
            reader.FAMILY_ADVISORY_READ_FAILURE(),
            1,
            reader.SUBJECT_CENTRAL_REGISTRY()
        );

        MonitorMockOptimizer optimizer = _healthyOptimizer();
        address[] memory optimizers =
            new address[](reader.MAX_INPUT_OPTIMIZERS() + 1);
        for (uint256 i; i < optimizers.length; ++i) {
            optimizers[i] = address(optimizer);
        }
        (,,,, signal) = reader.advisorySignals(address(registry), optimizers);
        _assertDecoded(
            signal,
            address(0),
            98,
            reader.FAMILY_ADVISORY_READ_FAILURE(),
            1,
            reader.SUBJECT_OPTIMIZER()
        );

        (,,,, uint256 optimizerCritical) =
            reader.criticalSignals(address(registry), optimizers);
        assertEq(optimizerCritical, 0);
    }

    function test_criticalCTokenTrackingLimitDoesNotOverflowMemory() public {
        MonitorMockLargeMarketManager largeMarket =
            new MonitorMockLargeMarketManager();
        MonitorMockCentralRegistry largeRegistry =
            new MonitorMockCentralRegistry();
        largeRegistry.addMarket(address(largeMarket));
        largeRegistry.setOracleManager(address(oracleManager));
        address[] memory optimizers = new address[](0);

        (
            uint256 wiring,
            uint256 tokenAccounting,
            uint256 backing,
            uint256 borrowAccounting,
            uint256 optimizerCritical
        ) = reader.criticalSignals(address(largeRegistry), optimizers);
        assertEq(wiring, 0);
        assertEq(tokenAccounting, 0);
        assertEq(backing, 0);
        assertEq(borrowAccounting, 0);
        assertEq(optimizerCritical, 0);
    }

    function test_marketListReadFailureUsesCode16() public {
        manager.setRevertTokenList(true);
        address[] memory optimizers = new address[](0);

        (,,,, uint256 signal) =
            reader.advisorySignals(address(registry), optimizers);
        _assertDecoded(
            signal,
            address(manager),
            16,
            reader.FAMILY_ADVISORY_READ_FAILURE(),
            1,
            reader.SUBJECT_MARKET_MANAGER()
        );
    }

    function test_malformedSubjectsReturnDiagnosticsInsteadOfReverting()
        public
        view
    {
        address eoa = address(0xBEEF);

        MonitorReader.CTokenStatus memory token =
            reader.checkCToken(eoa, address(oracleManager));
        assertTrue(token.readErrorMask != 0);

        MonitorReader.MarketStatus memory market =
            reader.checkMarket(eoa, address(oracleManager));
        assertEq(market.readErrorMask, reader.MARKET_READ_TOKEN_LIST());

        MonitorReader.OptimizerStatus memory optimizer =
            reader.checkOptimizer(eoa);
        assertTrue(optimizer.readErrorMask != 0);
    }

    function test_nonContractDependenciesBecomeReaderHealthFailures() public {
        address eoa = address(0xBEEF);

        MonitorReader.OracleStatus memory oracle =
            reader.checkOracle(eoa, address(underlying), true, true);
        assertEq(oracle.readErrorMask, reader.ORACLE_READ_PRICE());

        address[] memory optimizers = new address[](0);
        (
            uint256 wiring,
            uint256 accounting,
            uint256 backing,
            uint256 borrow,
            uint256 optimizerCritical
        ) = reader.criticalSignals(eoa, optimizers);
        assertEq(wiring, 0);
        assertEq(accounting, 0);
        assertEq(backing, 0);
        assertEq(borrow, 0);
        assertEq(optimizerCritical, 0);

        (,,,, uint256 readFailure) = reader.advisorySignals(eoa, optimizers);
        _assertDecoded(
            readFailure,
            eoa,
            2,
            reader.FAMILY_ADVISORY_READ_FAILURE(),
            1,
            reader.SUBJECT_CENTRAL_REGISTRY()
        );

        vm.mockCall(
            address(cToken),
            abi.encodeWithSignature("marketManager()"),
            abi.encode(eoa)
        );
        MonitorReader.CTokenStatus memory token =
            reader.checkCToken(address(cToken), address(oracleManager));
        assertTrue(token.readErrorMask & reader.CTOKEN_READ_LISTED() != 0);
        assertTrue(
            token.readErrorMask & reader.CTOKEN_READ_COLLATERAL_CAP() != 0
        );
        assertTrue(token.readErrorMask & reader.CTOKEN_READ_DEBT_CAP() != 0);

        vm.clearMockedCalls();
        token =
            reader.checkMarketCToken(address(cToken), address(manager), eoa);
        assertTrue(
            token.readErrorMask & reader.CTOKEN_READ_ORACLE_BINDING() != 0
        );
        assertTrue(
            token.readErrorMask & reader.CTOKEN_READ_ORACLE_LOWER() != 0
        );
        assertTrue(
            token.readErrorMask & reader.CTOKEN_READ_ORACLE_UPPER() != 0
        );

        vm.mockCall(
            address(cToken),
            abi.encodeWithSignature("asset()"),
            abi.encode(eoa)
        );
        token = reader.checkMarketCToken(
            address(cToken), address(manager), address(oracleManager)
        );
        assertTrue(
            token.readErrorMask & reader.CTOKEN_READ_UNDERLYING_BALANCE() != 0
        );
    }

    function test_nonContractOptimizerMarketsDoNotRevert() public {
        address eoa = address(0xBEEF);
        MonitorMockOptimizer optimizer =
            new MonitorMockOptimizer(address(underlying));
        optimizer.addMarket(eoa, 1e18);
        optimizer.setAccounting(1, 1, RESERVE);

        MonitorReader.OptimizerStatus memory status =
            reader.checkOptimizer(address(optimizer));
        assertTrue(status.readErrorMask & reader.OPTIMIZER_READ_MARKET() != 0);
        assertTrue(
            status.readErrorMask & reader.OPTIMIZER_READ_POSITION() != 0
        );

        MonitorMockOptimizer healthy = _healthyOptimizer();
        vm.mockCall(
            address(cToken),
            abi.encodeWithSignature("marketManager()"),
            abi.encode(eoa)
        );
        status = reader.checkOptimizer(address(healthy));
        assertTrue(status.readErrorMask & reader.OPTIMIZER_READ_MARKET() != 0);
    }

    function test_advisorySkipsZeroCTokenEntryWithoutReverting() public {
        manager.addToken(address(0));
        address[] memory optimizers = new address[](0);
        reader.advisorySignals(address(registry), optimizers);
    }

    /// OPTIMIZER SIGNALS ///

    function test_optimizerCriticalCodesCoverEveryDefinedBrokenBit() public {
        _assertOptimizerCritical(address(0), 1);

        MonitorMockOptimizer optimizer = _healthyOptimizer();
        vm.mockCall(
            address(optimizer),
            abi.encodeWithSignature("asset()"),
            abi.encode(address(0))
        );
        _assertOptimizerCritical(address(optimizer), 2);

        setUp();
        optimizer = new MonitorMockOptimizer(address(underlying));
        optimizer.setAccounting(1, 1, RESERVE);
        _assertOptimizerCritical(address(optimizer), 3);

        setUp();
        optimizer = new MonitorMockOptimizer(address(underlying));
        optimizer.addMarket(address(0), 1e18);
        optimizer.setAccounting(1, 1, RESERVE);
        _assertOptimizerCritical(address(optimizer), 4);

        setUp();
        optimizer = new MonitorMockOptimizer(address(underlying));
        optimizer.addMarket(address(cToken), 0.5e18);
        optimizer.addMarket(address(cToken), 0.5e18);
        optimizer.setAccounting(1_000_000_000, 1_000_000_000, RESERVE);
        cToken.setBalance(address(optimizer), 500_000_000);
        _assertOptimizerCritical(address(optimizer), 5);

        setUp();
        optimizer = _healthyOptimizer();
        vm.mockCall(
            address(optimizer),
            abi.encodeWithSignature(
                "allocationCaps(address)", address(cToken)
            ),
            abi.encode(0)
        );
        _assertOptimizerCritical(address(optimizer), 6);

        setUp();
        optimizer = new MonitorMockOptimizer(address(underlying));
        optimizer.addMarket(address(cToken), 0.5e18);
        optimizer.setAccounting(500_000_000, 500_000_000, RESERVE);
        cToken.setBalance(address(optimizer), 500_000_000);
        _assertOptimizerCritical(address(optimizer), 7);

        setUp();
        optimizer = _healthyOptimizer();
        cToken.setBorrowable(false);
        _assertOptimizerCritical(address(optimizer), 8);

        setUp();
        optimizer = _healthyOptimizer();
        vm.mockCall(
            address(cToken),
            abi.encodeWithSignature("asset()"),
            abi.encode(address(0xBAD))
        );
        _assertOptimizerCritical(address(optimizer), 9);

        setUp();
        optimizer = _healthyOptimizer();
        manager.setListed(address(cToken), false);
        _assertOptimizerCritical(address(optimizer), 10);

        setUp();
        optimizer = _healthyOptimizer();
        optimizer.setAccounting(600_000_000, 600_000_000, RESERVE);
        _assertOptimizerCritical(address(optimizer), 11);

        setUp();
        optimizer = _healthyOptimizer();
        optimizer.setAccounting(500_000_000, 0, RESERVE);
        _assertOptimizerCritical(address(optimizer), 12);

        setUp();
        optimizer = _healthyOptimizer();
        optimizer.setAccounting(500_000_000, 500_000_000, 0);
        _assertOptimizerCritical(address(optimizer), 13);

        setUp();
        optimizer = _healthyOptimizer();
        vm.mockCall(
            address(optimizer),
            abi.encodeWithSignature("exchangeRate()"),
            abi.encode(0)
        );
        _assertOptimizerCritical(address(optimizer), 14);

        setUp();
        optimizer = _healthyOptimizer();
        vm.mockCall(
            address(optimizer),
            abi.encodeWithSignature("convertToAssets(uint256)", 500_000_000),
            abi.encode(500_000_002)
        );
        _assertOptimizerCritical(address(optimizer), 15);
    }

    function test_optimizerWarningCodesAndPriorityAreExact() public {
        MonitorMockOptimizer optimizer = _healthyOptimizer();
        vm.mockCall(
            address(optimizer),
            abi.encodeWithSignature("exchangeRate()"),
            abi.encode(0.9e18)
        );
        _assertOptimizerWarning(address(optimizer), 1);

        vm.clearMockedCalls();
        optimizer.setMintPaused(2);
        _assertOptimizerWarning(address(optimizer), 2);

        vm.mockCall(
            address(optimizer),
            abi.encodeWithSignature("exchangeRate()"),
            abi.encode(0.9e18)
        );
        _assertOptimizerWarning(address(optimizer), 1);
    }

    function test_optimizerMarketCountAboveLimitIsClampedAndCritical() public {
        MonitorMockOptimizer optimizer =
            new MonitorMockOptimizer(address(underlying));
        for (uint256 i; i < reader.MAX_OPTIMIZER_MARKETS() + 1; ++i) {
            optimizer.addMarket(address(cToken), 1e18);
        }
        optimizer.setAccounting(500_000_000, 500_000_000, RESERVE);
        cToken.setBalance(address(optimizer), 500_000_000);

        MonitorReader.OptimizerStatus memory status =
            reader.checkOptimizer(address(optimizer));
        assertEq(status.markets.length, reader.MAX_OPTIMIZER_MARKETS());
        assertTrue(
            status.brokenMask & reader.OPTIMIZER_BROKEN_MARKET_COUNT() != 0
        );
        _assertOptimizerCritical(address(optimizer), 3);
    }

    function test_optimizerPositionSumOverflowIsCriticalAccounting() public {
        MonitorMockCToken secondCToken =
            new MonitorMockCToken(address(underlying), address(manager));
        manager.addToken(address(secondCToken));
        manager.setCaps(
            address(secondCToken), type(uint256).max, type(uint256).max
        );
        oracleManager.setCToken(address(secondCToken), address(underlying));
        _configureHealthyCToken(secondCToken, underlying);

        MonitorMockOptimizer optimizer =
            new MonitorMockOptimizer(address(underlying));
        optimizer.addMarket(address(cToken), 0.5e18);
        optimizer.addMarket(address(secondCToken), 0.5e18);
        optimizer.setAccounting(1, 1, RESERVE);
        cToken.setBalance(address(optimizer), 1);
        secondCToken.setBalance(address(optimizer), 1);
        vm.mockCall(
            address(cToken),
            abi.encodeWithSignature("convertToAssets(uint256)", 1),
            abi.encode(type(uint256).max)
        );
        vm.mockCall(
            address(secondCToken),
            abi.encodeWithSignature("convertToAssets(uint256)", 1),
            abi.encode(1)
        );

        _assertOptimizerCritical(address(optimizer), 11);
    }

    function test_allOptimizerReadFailuresMapToCodes64Through75() public {
        MonitorMockMarketManager optimizerManager =
            new MonitorMockMarketManager();
        MonitorMockCToken optimizerCToken = new MonitorMockCToken(
            address(underlying), address(optimizerManager)
        );
        optimizerManager.addToken(address(optimizerCToken));
        _configureHealthyCToken(optimizerCToken, underlying);
        MonitorMockOptimizer optimizer =
            new MonitorMockOptimizer(address(underlying));
        optimizer.addMarket(address(optimizerCToken), 1e18);
        optimizer.setAccounting(500_000_000, 500_000_000, RESERVE);
        optimizerCToken.setBalance(address(optimizer), 500_000_000);

        address[] memory targets = new address[](17);
        bytes[] memory calls = new bytes[](17);
        uint8[] memory codes = new uint8[](17);

        targets[0] = address(optimizer);
        calls[0] = abi.encodeWithSignature("asset()");
        codes[0] = 64;
        targets[1] = address(optimizer);
        calls[1] = abi.encodeWithSignature("numApprovedMarkets()");
        codes[1] = 65;
        targets[2] = address(optimizer);
        calls[2] = abi.encodeWithSignature("approvedCTokensList(uint256)", 0);
        codes[2] = 66;
        targets[3] = address(optimizerCToken);
        calls[3] = abi.encodeWithSignature("isBorrowable()");
        codes[3] = 66;
        targets[4] = address(optimizerCToken);
        calls[4] = abi.encodeWithSignature("asset()");
        codes[4] = 66;
        targets[5] = address(optimizerCToken);
        calls[5] = abi.encodeWithSignature("marketManager()");
        codes[5] = 66;
        targets[6] = address(optimizerManager);
        calls[6] = abi.encodeWithSignature(
            "isListed(address)", address(optimizerCToken)
        );
        codes[6] = 66;
        targets[7] = address(optimizer);
        calls[7] = abi.encodeWithSignature(
            "allocationCaps(address)", address(optimizerCToken)
        );
        codes[7] = 67;
        targets[8] = address(optimizer);
        calls[8] = abi.encodeWithSignature("totalAssets()");
        codes[8] = 68;
        targets[9] = address(optimizer);
        calls[9] = abi.encodeWithSignature("totalSupply()");
        codes[9] = 69;
        targets[10] = address(optimizer);
        calls[10] = abi.encodeWithSignature("balanceOf(address)", address(0));
        codes[10] = 70;
        targets[11] = address(optimizer);
        calls[11] = abi.encodeWithSignature("exchangeRate()");
        codes[11] = 71;
        targets[12] = address(optimizer);
        calls[12] = abi.encodeWithSignature("exchangeRateHighWatermark()");
        codes[12] = 72;
        targets[13] = address(optimizer);
        calls[13] =
            abi.encodeWithSignature("convertToAssets(uint256)", 500_000_000);
        codes[13] = 73;
        targets[14] = address(optimizer);
        calls[14] = abi.encodeWithSignature("mintPaused()");
        codes[14] = 74;
        targets[15] = address(optimizerCToken);
        calls[15] =
            abi.encodeWithSignature("balanceOf(address)", address(optimizer));
        codes[15] = 75;
        targets[16] = address(optimizerCToken);
        calls[16] =
            abi.encodeWithSignature("convertToAssets(uint256)", 500_000_000);
        codes[16] = 75;

        for (uint256 i; i < targets.length; ++i) {
            _assertOptimizerReadFailure(
                address(optimizer), targets[i], calls[i], codes[i]
            );
        }
    }

    /// HELPERS ///

    function _assertUniqueOneHot(uint256[] memory values) internal pure {
        uint256 seen;
        for (uint256 i; i < values.length; ++i) {
            uint256 value = values[i];
            assertTrue(value != 0);
            assertEq(value & (value - 1), 0);
            assertEq(seen & value, 0);
            seen |= value;
        }
    }

    function _assertOracleZeroCode(uint8 expectedCode) internal view {
        address[] memory optimizers = new address[](0);
        (uint256 oracleZero,,,,) =
            reader.advisorySignals(address(registry), optimizers);
        _assertDecoded(
            oracleZero,
            address(underlying),
            expectedCode,
            reader.FAMILY_ADVISORY_ORACLE_ZERO(),
            1,
            reader.SUBJECT_ASSET()
        );
    }

    function _assertOracleDegradedCode(
        uint256 lowerPrice,
        uint256 lowerError,
        uint256 upperPrice,
        uint256 upperError,
        uint8 expectedCode
    ) internal {
        oracleManager.setDirectionalPrices(
            lowerPrice, lowerError, upperPrice, upperError
        );
        address[] memory optimizers = new address[](0);
        (, uint256 degraded,,,) =
            reader.advisorySignals(address(registry), optimizers);
        _assertDecoded(
            degraded,
            address(underlying),
            expectedCode,
            reader.FAMILY_ADVISORY_ORACLE_DEGRADED(),
            1,
            reader.SUBJECT_ASSET()
        );
    }

    function _assertCriticalWiring(
        address expectedSubject,
        uint8 expectedCode,
        uint16 expectedCount
    ) internal view {
        address[] memory optimizers = new address[](0);
        (uint256 wiring,,,,) =
            reader.criticalSignals(address(registry), optimizers);
        _assertDecoded(
            wiring,
            expectedSubject,
            expectedCode,
            reader.FAMILY_CRITICAL_WIRING(),
            expectedCount,
            expectedSubject == address(manager)
                ? reader.SUBJECT_MARKET_MANAGER()
                : expectedSubject == address(cToken)
                    ? reader.SUBJECT_CTOKEN()
                    : reader.SUBJECT_MARKET_MANAGER()
        );
    }

    function _assertCriticalTokenAccounting(uint8 expectedCode) internal view {
        address[] memory optimizers = new address[](0);
        (, uint256 signal,,,) =
            reader.criticalSignals(address(registry), optimizers);
        _assertDecoded(
            signal,
            address(cToken),
            expectedCode,
            reader.FAMILY_CRITICAL_TOKEN_ACCOUNTING(),
            1,
            reader.SUBJECT_CTOKEN()
        );
    }

    function _assertCriticalBacking(uint8 expectedCode) internal view {
        address[] memory optimizers = new address[](0);
        (,, uint256 signal,,) =
            reader.criticalSignals(address(registry), optimizers);
        _assertDecoded(
            signal,
            address(cToken),
            expectedCode,
            reader.FAMILY_CRITICAL_BACKING(),
            1,
            reader.SUBJECT_CTOKEN()
        );
    }

    function _assertCriticalBorrowAccounting(uint8 expectedCode)
        internal
        view
    {
        address[] memory optimizers = new address[](0);
        (,,, uint256 signal,) =
            reader.criticalSignals(address(registry), optimizers);
        _assertDecoded(
            signal,
            address(cToken),
            expectedCode,
            reader.FAMILY_CRITICAL_BORROW_ACCOUNTING(),
            1,
            reader.SUBJECT_CTOKEN()
        );
    }

    function _assertCollateralOrCapCode(uint8 expectedCode) internal view {
        address[] memory optimizers = new address[](0);
        (,, uint256 signal,,) =
            reader.advisorySignals(address(registry), optimizers);
        _assertDecoded(
            signal,
            address(cToken),
            expectedCode,
            reader.FAMILY_ADVISORY_COLLATERAL_OR_CAP(),
            1,
            reader.SUBJECT_CTOKEN()
        );
    }

    function _assertAllCriticalSignalsZero() internal view {
        address[] memory optimizers = new address[](0);
        (
            uint256 wiring,
            uint256 accounting,
            uint256 backing,
            uint256 borrow,
            uint256 optimizer
        ) = reader.criticalSignals(address(registry), optimizers);
        assertEq(wiring, 0);
        assertEq(accounting, 0);
        assertEq(backing, 0);
        assertEq(borrow, 0);
        assertEq(optimizer, 0);
    }

    function _assertCTokenReadFailure(
        address target,
        bytes memory callData,
        uint8 expectedCode
    ) internal {
        vm.mockCallRevert(target, callData, bytes("read"));
        address[] memory optimizers = new address[](0);
        (,,,, uint256 signal) =
            reader.advisorySignals(address(registry), optimizers);
        _assertDecoded(
            signal,
            address(cToken),
            expectedCode,
            reader.FAMILY_ADVISORY_READ_FAILURE(),
            1,
            reader.SUBJECT_CTOKEN()
        );
        vm.clearMockedCalls();
    }

    function _assertOptimizerCritical(address optimizer, uint8 expectedCode)
        internal
        view
    {
        address[] memory optimizers = new address[](1);
        optimizers[0] = optimizer;
        (,,,, uint256 signal) =
            reader.criticalSignals(address(registry), optimizers);
        _assertDecoded(
            signal,
            optimizer,
            expectedCode,
            reader.FAMILY_CRITICAL_OPTIMIZER(),
            1,
            reader.SUBJECT_OPTIMIZER()
        );
    }

    function _assertOptimizerWarning(address optimizer, uint8 expectedCode)
        internal
        view
    {
        address[] memory optimizers = new address[](1);
        optimizers[0] = optimizer;
        (,,, uint256 signal,) =
            reader.advisorySignals(address(registry), optimizers);
        _assertDecoded(
            signal,
            optimizer,
            expectedCode,
            reader.FAMILY_ADVISORY_OPTIMIZER(),
            1,
            reader.SUBJECT_OPTIMIZER()
        );
    }

    function _assertOptimizerReadFailure(
        address optimizer,
        address target,
        bytes memory callData,
        uint8 expectedCode
    ) internal {
        vm.mockCallRevert(target, callData, bytes("read"));
        address[] memory optimizers = new address[](1);
        optimizers[0] = optimizer;
        (,,,, uint256 signal) =
            reader.advisorySignals(address(registry), optimizers);
        _assertDecoded(
            signal,
            optimizer,
            expectedCode,
            reader.FAMILY_ADVISORY_READ_FAILURE(),
            1,
            reader.SUBJECT_OPTIMIZER()
        );
        vm.clearMockedCalls();
    }
}
