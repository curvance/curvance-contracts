// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ProtocolManager} from "contracts/architecture/ProtocolManager.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {DynamicIRM} from "contracts/market/DynamicIRM.sol";
import {BorrowableCToken} from "contracts/market/token/BorrowableCToken.sol";
import {
    TestProtocolManagerBase
} from "tests/architecture/ProtocolManager/TestProtocolManagerBase.t.sol";
import {Test} from "forge-std/Test.sol";

abstract contract ProtocolManagerAggregateRateState {
    uint256 internal constant PROOF_WAD = 1e18;
    uint256 internal constant PROOF_WAD_TO_BPS = 1e14;

    function _endpointHash(
        DynamicIRM irm,
        BorrowableCToken cToken,
        ProtocolManager firstManager,
        ProtocolManager secondManager
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                _ratesAndDebtHash(irm, cToken),
                _ledgerHash(firstManager, irm),
                _ledgerHash(secondManager, irm)
            )
        );
    }

    function _ratesAndDebtHash(DynamicIRM irm, BorrowableCToken cToken)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                _rateConfigHash(irm),
                irm.vertexMultiplier(),
                cToken.assetsHeld(),
                cToken.totalAssets(),
                cToken.marketOutstandingDebt()
            )
        );
    }

    function _rateConfigHash(DynamicIRM irm) internal view returns (bytes32) {
        (
            uint64 baseRatePerSecond,
            uint64 vertexRatePerSecond,
            uint64 vertexStart,
            uint24 increaseThresholdStart,
            uint24 decreaseThresholdEnd,
            uint16 adjustmentVelocity,
            uint16 decayPerAdjustment,
            uint80 vertexMultiplierMax,
            address linkedToken
        ) = irm.ratesConfig();

        return keccak256(
            abi.encode(
                baseRatePerSecond,
                vertexRatePerSecond,
                vertexStart,
                increaseThresholdStart,
                decreaseThresholdEnd,
                adjustmentVelocity,
                decayPerAdjustment,
                vertexMultiplierMax,
                linkedToken
            )
        );
    }

    function _ledgerHash(ProtocolManager target, DynamicIRM irm)
        internal
        view
        returns (bytes32)
    {
        (int64 baseAdjustment, int64 vertexAdjustment) = _ledger(target, irm);
        return keccak256(abi.encode(baseAdjustment, vertexAdjustment));
    }

    function _ledger(ProtocolManager target, DynamicIRM irm)
        internal
        view
        returns (int64 baseAdjustment, int64 vertexAdjustment)
    {
        (,,,,, baseAdjustment, vertexAdjustment,,,,) =
            target.getMarketPeriodAdjustments(
                address(irm), target.getPeriodTimestamp()
            );
    }

    function _expectedBaseRate(uint256 annualRateBps, uint256 vertexStart)
        internal
        pure
        returns (uint256)
    {
        return (annualRateBps * PROOF_WAD_TO_BPS * PROOF_WAD)
            / (365 days * vertexStart);
    }

    function _expectedVertexRate(uint256 annualRateBps, uint256 vertexStart)
        internal
        pure
        returns (uint256)
    {
        return (annualRateBps * PROOF_WAD_TO_BPS * PROOF_WAD)
            / (365 days * (PROOF_WAD - vertexStart));
    }
}

/// @notice Local-contract proof that ProtocolManager period limits are scoped
///         to each manager contract rather than aggregated by managed IRM.
/// @dev This requires two separately authorized operators. It is not an
///      unprivileged bypass. The result is conditional Medium only if the
///      200/300 BPS limits were intended as one global envelope; otherwise it
///      is the accepted manager-local policy.
contract ProtocolManagerAggregateRateLocalPoC is
    TestProtocolManagerBase,
    ProtocolManagerAggregateRateState
{
    uint256 internal constant INITIAL_BASE_RATE = 1_000;
    uint256 internal constant INITIAL_VERTEX_RATE = 1_000;
    uint256 internal constant VERTEX_START = 5_000;
    uint256 internal constant ADJUSTMENT_VELOCITY = 1_000;
    uint256 internal constant DECAY_RATE = 100;
    uint256 internal constant MULTIPLIER_MAX = 100_000;

    address internal firstOperator;
    address internal secondOperator;
    DynamicIRM internal dynamicIRM;
    ProtocolManager internal firstManager;
    ProtocolManager internal secondManager;

    function setUp() public override {
        super.setUp();

        firstOperator = makeAddr("firstOperator");
        secondOperator = makeAddr("secondOperator");
        dynamicIRM = DynamicIRM(IRMs[block.chainid][_USDC_ADDRESS]);

        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(dynamicIRM);

        ProtocolManager.PeriodLimits[] memory limits =
            new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();

        firstManager = new ProtocolManager(
            ICentralRegistry(address(centralRegistry)),
            firstOperator,
            _getDefaultPermsConfig(),
            managedAddresses,
            limits
        );
        secondManager = new ProtocolManager(
            ICentralRegistry(address(centralRegistry)),
            secondOperator,
            _getDefaultPermsConfig(),
            managedAddresses,
            limits
        );

        centralRegistry.addMarketPermissions(address(firstManager));
        centralRegistry.addMarketPermissions(address(secondManager));
    }

    function test_twoAuthorizedManagersStackIRMPeriodLimitsIntoBorrowRate()
        public
    {
        assertEq(
            dynamicIRM.linkedToken(),
            address(borrowableCUSDC_MONAD),
            "proof IRM must be linked to the actual borrowable cToken"
        );
        assertEq(firstManager.protocolManager(), firstOperator);
        assertEq(secondManager.protocolManager(), secondOperator);
        assertTrue(centralRegistry.hasMarketPermissions(address(firstManager)));
        assertTrue(
            centralRegistry.hasMarketPermissions(address(secondManager))
        );
        _assertLedger(firstManager, 0, 0);
        _assertLedger(secondManager, 0, 0);
        _assertStoredAnnualRates(
            dynamicIRM, INITIAL_BASE_RATE, INITIAL_VERTEX_RATE
        );

        uint256 initialBorrowRate = dynamicIRM.borrowRate(50e18, 50e18);

        vm.prank(firstOperator);
        _updateRates(firstManager, 1_200, 1_300);
        uint256 oneManagerBorrowRate = dynamicIRM.borrowRate(50e18, 50e18);

        vm.prank(secondOperator);
        _updateRates(secondManager, 1_400, 1_600);
        uint256 aggregateBorrowRate = dynamicIRM.borrowRate(50e18, 50e18);

        assertGt(
            oneManagerBorrowRate,
            initialBorrowRate,
            "first local allowance must affect the rate"
        );
        assertGt(
            aggregateBorrowRate,
            oneManagerBorrowRate,
            "second local allowance must stack into the rate"
        );
        _assertAggregateEndpoint();

        vm.prank(address(borrowableCUSDC_MONAD));
        (uint256 authoritativeBorrowRate, uint256 adjustmentRate) =
            dynamicIRM.adjustedBorrowRate(50e18, 50e18);
        assertEq(
            authoritativeBorrowRate,
            aggregateBorrowRate,
            "linked cToken accrual path must consume the aggregate rate"
        );
        assertEq(adjustmentRate, dynamicIRM.ADJUSTMENT_RATE());

        bytes32 endpointBeforeRejects = _endpointHash(
            dynamicIRM, borrowableCUSDC_MONAD, firstManager, secondManager
        );

        vm.prank(firstOperator);
        vm.expectRevert(
            ProtocolManager.ProtocolManager__ParametersAreInvalid.selector
        );
        _updateRates(firstManager, 1_401, 1_600);
        assertEq(
            _endpointHash(
                dynamicIRM, borrowableCUSDC_MONAD, firstManager, secondManager
            ),
            endpointBeforeRejects,
            "first manager +1 rejection must roll back all observed state"
        );

        vm.prank(secondOperator);
        vm.expectRevert(
            ProtocolManager.ProtocolManager__ParametersAreInvalid.selector
        );
        _updateRates(secondManager, 1_401, 1_600);
        assertEq(
            _endpointHash(
                dynamicIRM, borrowableCUSDC_MONAD, firstManager, secondManager
            ),
            endpointBeforeRejects,
            "second manager +1 rejection must roll back all observed state"
        );

        vm.prank(makeAddr("unprivilegedCaller"));
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        _updateRates(firstManager, 1_400, 1_600);
        assertEq(
            _endpointHash(
                dynamicIRM, borrowableCUSDC_MONAD, firstManager, secondManager
            ),
            endpointBeforeRejects,
            "unprivileged rejection must not change the aggregate endpoint"
        );
    }

    function _assertAggregateEndpoint() internal view {
        (int64 firstBase, int64 firstVertex) =
            _assertLedger(firstManager, 200, 300);
        (int64 secondBase, int64 secondVertex) =
            _assertLedger(secondManager, 200, 300);
        assertEq(int256(firstBase) + int256(secondBase), 400);
        assertEq(int256(firstVertex) + int256(secondVertex), 600);

        _assertStoredAnnualRates(dynamicIRM, 1_400, 1_600);
    }

    function _assertLedger(
        ProtocolManager target,
        int64 expectedBase,
        int64 expectedVertex
    ) internal view returns (int64 baseAdjustment, int64 vertexAdjustment) {
        (baseAdjustment, vertexAdjustment) = _ledger(target, dynamicIRM);
        assertEq(baseAdjustment, expectedBase);
        assertEq(vertexAdjustment, expectedVertex);
    }

    function _assertStoredAnnualRates(
        DynamicIRM irm,
        uint256 expectedBaseBps,
        uint256 expectedVertexBps
    ) internal view {
        (
            uint64 baseRatePerSecond,
            uint64 vertexRatePerSecond,
            uint64 vertexStart,,,,,,
        ) = irm.ratesConfig();

        assertEq(
            baseRatePerSecond,
            _expectedBaseRate(expectedBaseBps, vertexStart),
            "aggregate base-rate setting must persist"
        );
        assertEq(
            vertexRatePerSecond,
            _expectedVertexRate(expectedVertexBps, vertexStart),
            "aggregate vertex-rate setting must persist"
        );
    }

    function _updateRates(
        ProtocolManager target,
        uint256 baseRate,
        uint256 vertexRate
    ) internal {
        target.updateDynamicIRM(
            address(dynamicIRM),
            baseRate,
            vertexRate,
            VERTEX_START,
            ADJUSTMENT_VELOCITY,
            DECAY_RATE,
            MULTIPLIER_MAX,
            false
        );
    }
}

/// @notice Fixed-block proof that the actual RapidResponse and Avant managers
///         have independent ledgers over the savUSD/AUSD AUSD IRM and that the
///         stacked endpoint changes cAUSD's one-day debt growth.
/// @dev Full use requires both authorized operators. There is no unprivileged
///      bypass. The result is conditional Medium only if governance intended
///      one global 200/300 BPS envelope; otherwise it is accepted policy.
contract ProtocolManagerAggregateRateLivePoC is
    Test,
    ProtocolManagerAggregateRateState
{
    uint256 internal constant FORK_BLOCK = 88_379_768;
    bytes32 internal constant FORK_BLOCK_HASH =
        0x26f308eaa95c859e0b49c040213b40005a03e0c60d97b892c7d662efe3c22d3e;

    ICentralRegistry internal constant CENTRAL_REGISTRY =
        ICentralRegistry(0x1310f352f1389969Ece6741671c4B919523912fF);
    ProtocolManager internal constant RAPID_RESPONSE =
        ProtocolManager(0xC3a2974593BB729e5A62fE74a8ab091Fed5321A1);
    ProtocolManager internal constant AVANT =
        ProtocolManager(0x7D89822C41191541D6A02AebC23f4F398D6E4441);
    DynamicIRM internal constant AUSD_IRM =
        DynamicIRM(0x65120989A1f8B1F24b6446a6c08AD1f6BE039Bcf);
    BorrowableCToken internal constant CAUSD =
        BorrowableCToken(0xD1BFEA1728ffe98F515f26082fACfcc3341691D4);

    address internal constant RAPID_RESPONSE_OPERATOR =
        0x25D4134861b30Ba7215d2A280DD84C57c5780902;
    address internal constant AVANT_OPERATOR =
        0xb32a5d4Ff4839C48De0ec8971C369d46Ab972b0b;
    address internal constant SAVUSD_AUSD_MARKET =
        0x4B0a39eCC3e5A5dA3ce6D492D4D255cD1F0209F7;
    address internal constant AUSD =
        0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;

    function setUp() public {
        string memory rpc = vm.envString("MON_NODE_URI_MONAD_ARCHIVE");
        vm.createSelectFork(rpc, FORK_BLOCK + 1);
        assertEq(
            blockhash(FORK_BLOCK), FORK_BLOCK_HASH, "fork block hash drift"
        );
        vm.createSelectFork(rpc, FORK_BLOCK);

        assertEq(block.chainid, 143, "wrong chain");
        assertEq(block.number, FORK_BLOCK, "wrong fork block");
        _assertLiveIdentity();
    }

    function test_liveOverlappingManagersIncreaseOneDayDebtBeyondSingleEnvelope()
        public
    {
        _assertLedger(RAPID_RESPONSE, -30, 0);
        _assertLedger(AVANT, 0, 0);

        uint256 startingDebt = CAUSD.marketOutstandingDebtUpdated();
        uint256 startingRate =
            AUSD_IRM.borrowRate(CAUSD.assetsHeld(), startingDebt);
        uint256 startingTimestamp = block.timestamp;
        bytes32 normalizedEndpoint =
            _endpointHash(AUSD_IRM, CAUSD, RAPID_RESPONSE, AVANT);

        uint256 baselineState = vm.snapshotState();
        vm.warp(startingTimestamp + 1 days);
        uint256 baselineGrowth =
            CAUSD.marketOutstandingDebtUpdated() - startingDebt;

        assertTrue(
            vm.revertToState(baselineState),
            "failed to restore normalized baseline state"
        );
        _assertNormalizedReset(
            startingTimestamp, startingDebt, normalizedEndpoint
        );

        uint256 stackedState = vm.snapshotState();

        vm.prank(RAPID_RESPONSE_OPERATOR);
        _updateLiveRates(RAPID_RESPONSE, 905, 1_200);

        vm.prank(AVANT_OPERATOR);
        _updateLiveRates(AVANT, 1_105, 1_500);

        _assertLiveAggregateEndpoint();
        uint256 stackedRate = AUSD_IRM.borrowRate(
            CAUSD.assetsHeld(), CAUSD.marketOutstandingDebt()
        );
        assertGt(
            stackedRate,
            startingRate,
            "stacked config must increase the live borrow rate"
        );

        bytes32 endpointBeforeRejects =
            _endpointHash(AUSD_IRM, CAUSD, RAPID_RESPONSE, AVANT);

        vm.prank(RAPID_RESPONSE_OPERATOR);
        vm.expectRevert(
            ProtocolManager.ProtocolManager__ParametersAreInvalid.selector
        );
        _updateLiveRates(RAPID_RESPONSE, 1_106, 1_500);
        assertEq(
            _endpointHash(AUSD_IRM, CAUSD, RAPID_RESPONSE, AVANT),
            endpointBeforeRejects,
            "RapidResponse +1 rejection must not drift live state"
        );

        vm.prank(AVANT_OPERATOR);
        vm.expectRevert(
            ProtocolManager.ProtocolManager__ParametersAreInvalid.selector
        );
        _updateLiveRates(AVANT, 1_106, 1_500);
        assertEq(
            _endpointHash(AUSD_IRM, CAUSD, RAPID_RESPONSE, AVANT),
            endpointBeforeRejects,
            "Avant +1 rejection must not drift live state"
        );

        vm.warp(startingTimestamp + 1 days);
        uint256 stackedGrowth =
            CAUSD.marketOutstandingDebtUpdated() - startingDebt;
        uint256 excessGrowth = stackedGrowth - baselineGrowth;

        emit log_named_uint(
            "normalized baseline one-day debt growth", baselineGrowth
        );
        emit log_named_uint("stacked one-day debt growth", stackedGrowth);
        emit log_named_uint("stacked excess one-day debt", excessGrowth);

        assertEq(
            baselineGrowth,
            2_118_227_100,
            "fixed-block baseline debt growth drifted"
        );
        assertEq(
            stackedGrowth,
            3_463_564_512,
            "fixed-block stacked debt growth drifted"
        );
        assertEq(
            excessGrowth,
            1_345_337_412,
            "fixed-block aggregate-authority differential drifted"
        );

        assertTrue(
            vm.revertToState(stackedState),
            "failed to restore stacked comparison state"
        );
        _assertNormalizedReset(
            startingTimestamp, startingDebt, normalizedEndpoint
        );
    }

    function _assertLiveIdentity() internal view {
        assertEq(RAPID_RESPONSE.protocolManager(), RAPID_RESPONSE_OPERATOR);
        assertEq(AVANT.protocolManager(), AVANT_OPERATOR);
        assertEq(
            address(RAPID_RESPONSE.centralRegistry()),
            address(CENTRAL_REGISTRY)
        );
        assertEq(address(AVANT.centralRegistry()), address(CENTRAL_REGISTRY));
        assertTrue(
            CENTRAL_REGISTRY.hasMarketPermissions(address(RAPID_RESPONSE))
        );
        assertTrue(CENTRAL_REGISTRY.hasMarketPermissions(address(AVANT)));
        assertTrue(RAPID_RESPONSE.canModifyIRM());
        assertTrue(AVANT.canModifyIRM());

        _assertLiveManagerConfig(RAPID_RESPONSE);
        _assertLiveManagerConfig(AVANT);

        assertEq(AUSD_IRM.linkedToken(), address(CAUSD));
        assertEq(address(CAUSD.IRM()), address(AUSD_IRM));
        assertEq(address(CAUSD.marketManager()), SAVUSD_AUSD_MARKET);
        assertEq(CAUSD.asset(), AUSD);
    }

    function _assertLiveManagerConfig(ProtocolManager target) internal view {
        (bool hasAuthority, ProtocolManager.PeriodLimits memory limits) =
            target.config(address(AUSD_IRM));

        assertTrue(hasAuthority, "live manager lost AUSD IRM authority");
        assertEq(limits.baseInterestRateLimit, 200);
        assertEq(limits.vertexInterestRateLimit, 300);
    }

    function _assertLiveAggregateEndpoint() internal view {
        (int64 rapidBase, int64 rapidVertex) =
            _assertLedger(RAPID_RESPONSE, 200, 300);
        (int64 avantBase, int64 avantVertex) = _assertLedger(AVANT, 200, 300);

        assertEq(int256(rapidBase) + int256(avantBase), 400);
        assertEq(int256(rapidVertex) + int256(avantVertex), 600);
        _assertStoredAnnualRates(AUSD_IRM, 1_105, 1_500);
    }

    function _assertNormalizedReset(
        uint256 expectedTimestamp,
        uint256 expectedDebt,
        bytes32 expectedEndpoint
    ) internal view {
        assertEq(block.timestamp, expectedTimestamp, "timestamp reset drifted");
        assertEq(
            CAUSD.marketOutstandingDebt(), expectedDebt, "debt reset drifted"
        );
        assertEq(
            _endpointHash(AUSD_IRM, CAUSD, RAPID_RESPONSE, AVANT),
            expectedEndpoint,
            "snapshot reset failed to isolate comparison branches"
        );
        _assertLedger(RAPID_RESPONSE, -30, 0);
        _assertLedger(AVANT, 0, 0);
    }

    function _assertLedger(
        ProtocolManager target,
        int64 expectedBase,
        int64 expectedVertex
    ) internal view returns (int64 baseAdjustment, int64 vertexAdjustment) {
        (baseAdjustment, vertexAdjustment) = _ledger(target, AUSD_IRM);
        assertEq(baseAdjustment, expectedBase);
        assertEq(vertexAdjustment, expectedVertex);
    }

    function _assertStoredAnnualRates(
        DynamicIRM irm,
        uint256 expectedBaseBps,
        uint256 expectedVertexBps
    ) internal view {
        (
            uint64 baseRatePerSecond,
            uint64 vertexRatePerSecond,
            uint64 vertexStart,,,,,,
        ) = irm.ratesConfig();

        assertEq(
            baseRatePerSecond,
            _expectedBaseRate(expectedBaseBps, vertexStart),
            "live aggregate base rate must persist"
        );
        assertEq(
            vertexRatePerSecond,
            _expectedVertexRate(expectedVertexBps, vertexStart),
            "live aggregate vertex rate must persist"
        );
    }

    function _updateLiveRates(
        ProtocolManager target,
        uint256 baseRate,
        uint256 vertexRate
    ) internal {
        target.updateDynamicIRM(
            address(AUSD_IRM),
            baseRate,
            vertexRate,
            9_000,
            250,
            200,
            20_000,
            false
        );
    }
}
