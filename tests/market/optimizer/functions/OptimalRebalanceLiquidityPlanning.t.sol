// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    LendingOptimizer
} from "contracts/market/optimizer/LendingOptimizer.sol";
import {OptimizerReader} from "contracts/views/OptimizerReader.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IDynamicIRM} from "contracts/interfaces/IDynamicIRM.sol";
import {IOracleAdaptor} from "contracts/interfaces/IOracleAdaptor.sol";
import {WAD} from "contracts/libraries/ConstantsLib.sol";

contract TestOptimalRebalanceLiquidityPlanning is Test {
    struct Scenario {
        uint256 sourceAssets;
        uint256 destinationAssets;
        uint256 sourceCash;
        uint256 destinationCash;
        uint256 sourceDebt;
        uint256 destinationDebt;
        uint256 sourceCapBps;
        uint256 destinationCapBps;
    }

    MockOracleManager internal oracleManager;
    OptimizerReader internal reader;

    address internal constant UNDERLYING = address(0xA11CE);
    address internal constant SOURCE_COLLATERAL = address(0xC011);

    function setUp() public {
        oracleManager = new MockOracleManager();
        reader = new OptimizerReader(
            ICentralRegistry(
                address(new MockCentralRegistry(address(oracleManager)))
            ),
            0
        );
    }

    function test_optimalRebalance_normalMarketDoesNotWithdrawMoreThanAssetsHeld()
        public
    {
        MockOptimizer optimizer;
        MockCToken source;
        MockCToken destination;
        (optimizer, source, destination) = _deployTwoMarketOptimizer(
            Scenario({
                sourceAssets: 1_000_000e6,
                destinationAssets: 100_000e6,
                sourceCash: 300_000e6,
                destinationCash: 100_000e6,
                sourceDebt: 500_000e6,
                destinationDebt: 500_000e6,
                sourceCapBps: 10_000,
                destinationCapBps: 5_000
            })
        );

        // Make the destination decisively attractive while retaining the
        // constrained source cash. This isolates the assertion that incentive
        // scoring still cannot plan a withdrawal above assetsHeld().
        OptimizerReader.MarketIncentiveAPYBps[] memory incentives =
            _oneMarketIncentive(address(destination), 1_000);
        (LendingOptimizer.ReallocationAction[] memory actions,) =
            reader.optimalRebalance(address(optimizer), 0, 100, incentives);

        uint256 withdrawAmount = _withdrawAmount(actions, address(source));

        assertGt(
            withdrawAmount, 0, "test setup should produce source withdrawal"
        );
        assertLe(
            withdrawAmount,
            source.assetsHeld(),
            "normal market withdrawal must be capped by executable liquidity"
        );

        assertEq(
            address(destination),
            address(actions[1].cToken),
            "destination action order"
        );
    }

    function test_optimalRebalance_normalMarketStopsWhenSourceRateCatchesDestination()
        public
    {
        MockOptimizer optimizer;
        MockCToken source;
        MockCToken destination;
        (optimizer, source, destination) = _deployTwoMarketOptimizer(
            Scenario({
                sourceAssets: 1_000_000e6,
                destinationAssets: 100_000e6,
                sourceCash: 500_000e6,
                destinationCash: 100_000e6,
                sourceDebt: 500_000e6,
                destinationDebt: 500_000e6,
                sourceCapBps: 10_000,
                destinationCapBps: 10_000
            })
        );

        uint256 chunks = 100;
        (LendingOptimizer.ReallocationAction[] memory actions,) = reader.optimalRebalance(
            address(optimizer), 0, chunks, _emptyMarketIncentives()
        );

        uint256 withdrawAmount = _withdrawAmount(actions, address(source));
        uint256 chunkSize =
            (source.currentAssets() + destination.currentAssets()) / chunks;
        uint256 maxProfitableMove = _maxProfitableMove(
            source.assetsHeld(),
            destination.assetsHeld(),
            source.marketOutstandingDebt(),
            destination.marketOutstandingDebt(),
            chunkSize
        );

        assertGt(
            withdrawAmount, 0, "test setup should produce source withdrawal"
        );
        assertLe(
            withdrawAmount,
            maxProfitableMove,
            "normal market should stop before source APY spikes above destination"
        );
    }

    function test_optimalRebalance_largeDominantMoveAppliesBothSidesRateImpact()
        public
    {
        MockOptimizer optimizer;
        MockCToken source;
        MockCToken destination;
        (optimizer, source, destination) = _deployTwoMarketOptimizer(
            Scenario({
                sourceAssets: 4_000_000e6,
                destinationAssets: 500_000e6,
                sourceCash: 1_200_000e6,
                destinationCash: 200_000e6,
                sourceDebt: 2_000_000e6,
                destinationDebt: 1_400_000e6,
                sourceCapBps: 10_000,
                destinationCapBps: 10_000
            })
        );

        uint256 chunks = 200;
        (LendingOptimizer.ReallocationAction[] memory actions,) = reader.optimalRebalance(
            address(optimizer), 0, chunks, _emptyMarketIncentives()
        );

        uint256 withdrawAmount = _withdrawAmount(actions, address(source));
        uint256 chunkSize =
            (source.currentAssets() + destination.currentAssets()) / chunks;
        uint256 maxProfitableMove = _maxProfitableMove(
            source.assetsHeld(),
            destination.assetsHeld(),
            source.marketOutstandingDebt(),
            destination.marketOutstandingDebt(),
            chunkSize
        );

        assertGt(
            withdrawAmount, 0, "test setup should produce source withdrawal"
        );
        assertLe(
            withdrawAmount,
            maxProfitableMove,
            "dominant allocation must account for source spike and destination dilution"
        );
        _assertActionsBalance(actions);
    }

    function test_optimalRebalance_pathologicalCurveDrainsOnlyExecutableLiquidity()
        public
    {
        MockOptimizer optimizer;
        MockCToken source;
        MockCToken destination;
        (optimizer, source, destination) =
            _deployTwoMarketOptimizerWithRateModels(
                Scenario({
                    sourceAssets: 1_000_000e6,
                    destinationAssets: 100_000e6,
                    sourceCash: 123_456e6,
                    destinationCash: 500_000e6,
                    sourceDebt: 1,
                    destinationDebt: 1,
                    sourceCapBps: 10_000,
                    destinationCapBps: 10_000
                }),
                address(new MockFlatRateModel(1)),
                address(new MockFlatRateModel(2))
            );

        (LendingOptimizer.ReallocationAction[] memory actions,) = reader.optimalRebalance(
            address(optimizer), 0, 100, _emptyMarketIncentives()
        );

        uint256 withdrawAmount = _withdrawAmount(actions, address(source));

        assertEq(
            withdrawAmount,
            source.assetsHeld(),
            "pathological curve can exhaust liquidity but cannot exceed it"
        );
        assertEq(
            uint256(actions[1].assetsOrBps),
            source.assetsHeld(),
            "executable source liquidity should be the routed deposit amount"
        );
        assertEq(
            address(destination),
            address(actions[1].cToken),
            "destination action order"
        );
        _assertActionsBalance(actions);
    }

    function test_optimalRebalance_badMarketEvacuatesOnlyPhysicallyWithdrawableLiquidity()
        public
    {
        MockOptimizer optimizer;
        MockCToken badSource;
        MockCToken destination;
        (optimizer, badSource, destination) = _deployTwoMarketOptimizer(
            Scenario({
                sourceAssets: 1_000_000e6,
                destinationAssets: 100_000e6,
                sourceCash: 300_000e6,
                destinationCash: 100_000e6,
                sourceDebt: 1_000_000e6,
                destinationDebt: 500_000e6,
                sourceCapBps: 10_000,
                destinationCapBps: 10_000
            })
        );

        _markBad(badSource);

        (LendingOptimizer.ReallocationAction[] memory actions,) = reader.optimalRebalance(
            address(optimizer), 0, 100, _emptyMarketIncentives()
        );

        uint256 withdrawAmount = _withdrawAmount(actions, address(badSource));

        assertEq(
            withdrawAmount,
            badSource.assetsHeld(),
            "bad market should evacuate all physically withdrawable liquidity"
        );
        assertEq(
            uint256(actions[1].assetsOrBps),
            withdrawAmount,
            "bad-market proceeds should route to a non-bad destination"
        );
        assertEq(
            address(destination),
            address(actions[1].cToken),
            "destination action order"
        );
    }

    function test_optimalRebalance_badMarketEvacuationOverridesRateComparison()
        public
    {
        MockOptimizer optimizer;
        MockCToken badSource;
        MockCToken destination;
        (optimizer, badSource, destination) = _deployTwoMarketOptimizer(
            Scenario({
                sourceAssets: 1_000_000e6,
                destinationAssets: 100_000e6,
                sourceCash: 300_000e6,
                destinationCash: 100_000e6,
                sourceDebt: 2_000_000e6,
                destinationDebt: 100_000e6,
                sourceCapBps: 10_000,
                destinationCapBps: 10_000
            })
        );

        _markBad(badSource);

        (LendingOptimizer.ReallocationAction[] memory actions,) = reader.optimalRebalance(
            address(optimizer), 0, 100, _emptyMarketIncentives()
        );

        uint256 withdrawAmount = _withdrawAmount(actions, address(badSource));

        assertEq(
            withdrawAmount,
            badSource.assetsHeld(),
            "bad market evacuation should ignore normal yield comparison"
        );
        assertEq(
            uint256(actions[1].assetsOrBps),
            badSource.assetsHeld(),
            "bad-market proceeds should route to a non-bad destination"
        );
        assertEq(
            address(destination),
            address(actions[1].cToken),
            "destination action order"
        );
        _assertActionsBalance(actions);
    }

    /// @dev The destination starts with a lower native per-second rate. A 400
    ///      BPS annual incentive is large enough after unit conversion to make
    ///      its effective rate higher and reverse the planner's preference.
    function test_optimalRebalance_incentiveOvercomesNativeRateDisadvantage()
        public
    {
        (MockOptimizer optimizer, MockCToken source, MockCToken destination) = _deployTwoMarketOptimizerWithRateModels(
            Scenario({
                sourceAssets: 900_000e6,
                destinationAssets: 100_000e6,
                sourceCash: 900_000e6,
                destinationCash: 100_000e6,
                sourceDebt: 1,
                destinationDebt: 1,
                sourceCapBps: 10_000,
                destinationCapBps: 10_000
            }),
            address(new MockFlatRateModel(2e9)),
            address(new MockFlatRateModel(1e9))
        );

        (LendingOptimizer.ReallocationAction[] memory nativeActions,) = reader.optimalRebalance(
            address(optimizer), 0, 100, _emptyMarketIncentives()
        );
        OptimizerReader.MarketIncentiveAPYBps[] memory incentives =
            _oneMarketIncentive(address(destination), 400);
        (LendingOptimizer.ReallocationAction[] memory incentiveActions,) =
            reader.optimalRebalance(address(optimizer), 0, 100, incentives);

        assertEq(
            _depositAmount(nativeActions, address(destination)),
            0,
            "lower native rate should not attract deposits"
        );
        assertGt(
            _depositAmount(incentiveActions, address(destination)),
            0,
            "incentive should overcome the native-rate disadvantage"
        );
        assertGt(
            _withdrawAmount(incentiveActions, address(source)),
            0,
            "incentive move should have an executable source"
        );
    }

    /// @dev Pins the source side of the normal effective-rate comparison and
    ///      the annual-BPS conversion boundary. One BPS converts to roughly
    ///      3.17e6 per-second WAD, so 315 BPS leaves the 1e9 native-rate source
    ///      just below the 2e9 destination while 316 BPS places it just above.
    function test_optimalRebalance_sourceIncentiveReversesNormalMoveDirection()
        public
    {
        (MockOptimizer optimizer, MockCToken source, MockCToken destination) = _deployTwoMarketOptimizerWithRateModels(
            Scenario({
                sourceAssets: 900_000e6,
                destinationAssets: 100_000e6,
                sourceCash: 900_000e6,
                destinationCash: 100_000e6,
                sourceDebt: 1,
                destinationDebt: 1,
                sourceCapBps: 10_000,
                destinationCapBps: 10_000
            }),
            address(new MockFlatRateModel(1e9)),
            address(new MockFlatRateModel(2e9))
        );

        OptimizerReader.MarketIncentiveAPYBps[] memory belowCrossover =
            _oneMarketIncentive(address(source), 315);
        (LendingOptimizer.ReallocationAction[] memory belowActions,) =
            reader.optimalRebalance(address(optimizer), 0, 100, belowCrossover);

        assertGt(
            _withdrawAmount(belowActions, address(source)),
            0,
            "315 BPS should not overcome the native-rate disadvantage"
        );
        assertGt(
            _depositAmount(belowActions, address(destination)),
            0,
            "lower effective-rate source should fund the destination"
        );

        OptimizerReader.MarketIncentiveAPYBps[] memory aboveCrossover =
            _oneMarketIncentive(address(source), 316);
        (LendingOptimizer.ReallocationAction[] memory aboveActions,) =
            reader.optimalRebalance(address(optimizer), 0, 100, aboveCrossover);

        assertEq(
            _withdrawAmount(aboveActions, address(source)),
            0,
            "316 BPS source incentive should prevent source withdrawal"
        );
        assertGt(
            _depositAmount(aboveActions, address(source)),
            0,
            "higher effective-rate source should become the destination"
        );
    }

    /// @dev Runs the same maximum-incentive destination through bad-market,
    ///      mint-paused, and redeem-paused states. Incentives may rank eligible
    ///      destinations but must never make an ineligible destination valid.
    function test_optimalRebalance_maxIncentiveCannotBypassEligibility()
        public
    {
        _assertMaxIncentiveCannotAttract(0);
        _assertMaxIncentiveCannotAttract(1);
        _assertMaxIncentiveCannotAttract(2);
    }

    /// @dev Forces an over-cap withdrawal, then verifies the incentive chooses
    ///      between two otherwise eligible repair destinations without
    ///      changing the amount that must leave the over-cap source.
    function test_optimalRebalance_incentiveRanksHardCapRepairDestination()
        public
    {
        (
            MockOptimizer optimizer,
            MockCToken source,
            MockCToken nativeDestination,
            MockCToken incentivizedDestination
        ) = _deployThreeMarketRankingScenario(5_000);
        OptimizerReader.MarketIncentiveAPYBps[] memory incentives =
            _oneMarketIncentive(address(incentivizedDestination), 1_000);

        (LendingOptimizer.ReallocationAction[] memory actions,) =
            reader.optimalRebalance(address(optimizer), 0, 100, incentives);

        assertGt(
            _withdrawAmount(actions, address(source)),
            0,
            "over-cap source should be repaired"
        );
        assertEq(
            _depositAmount(actions, address(nativeDestination)),
            0,
            "lower effective destination should not win cap repair"
        );
        assertGt(
            _depositAmount(actions, address(incentivizedDestination)),
            0,
            "incentive should rank the cap-repair destination"
        );
    }

    /// @dev Forces evacuation from a bad source and verifies incentives only
    ///      select the best eligible destination; the source still evacuates
    ///      all physically executable liquidity.
    function test_optimalRebalance_incentiveRanksBadMarketDestination()
        public
    {
        (
            MockOptimizer optimizer,
            MockCToken badSource,
            MockCToken nativeDestination,
            MockCToken incentivizedDestination
        ) = _deployThreeMarketRankingScenario(10_000);
        _markBad(badSource);
        OptimizerReader.MarketIncentiveAPYBps[] memory incentives =
            _oneMarketIncentive(address(incentivizedDestination), 1_000);

        (LendingOptimizer.ReallocationAction[] memory actions,) =
            reader.optimalRebalance(address(optimizer), 0, 100, incentives);

        assertEq(
            _withdrawAmount(actions, address(badSource)),
            badSource.assetsHeld(),
            "bad market should evacuate all executable liquidity"
        );
        assertEq(
            _depositAmount(actions, address(nativeDestination)),
            0,
            "lower effective destination should not win evacuation"
        );
        assertGt(
            _depositAmount(actions, address(incentivizedDestination)),
            0,
            "incentive should rank the evacuation destination"
        );
    }

    /// @dev Encodes native-rate-only behavior under the new four-argument ABI.
    function _emptyMarketIncentives()
        internal
        pure
        returns (OptimizerReader.MarketIncentiveAPYBps[] memory incentives)
    {
        incentives = new OptimizerReader.MarketIncentiveAPYBps[](0);
    }

    /// @dev Builds one address-tagged incentive without relying on market order.
    function _oneMarketIncentive(address cToken, uint256 incentiveAPYBps)
        internal
        pure
        returns (OptimizerReader.MarketIncentiveAPYBps[] memory incentives)
    {
        incentives = new OptimizerReader.MarketIncentiveAPYBps[](1);
        incentives[0] = OptimizerReader.MarketIncentiveAPYBps({
            cToken: cToken, incentiveAPYBps: incentiveAPYBps
        });
    }

    /// @dev Applies one eligibility restriction to an otherwise attractive
    ///      destination: 0 = bad, 1 = mint-paused, 2 = redeem-paused.
    function _assertMaxIncentiveCannotAttract(uint8 marketState) internal {
        (MockOptimizer optimizer,, MockCToken destination) = _deployTwoMarketOptimizerWithRateModels(
            Scenario({
                sourceAssets: 900_000e6,
                destinationAssets: 100_000e6,
                sourceCash: 900_000e6,
                destinationCash: 100_000e6,
                sourceDebt: 1,
                destinationDebt: 1,
                sourceCapBps: 10_000,
                destinationCapBps: 10_000
            }),
            address(new MockFlatRateModel(2e9)),
            address(new MockFlatRateModel(1e9))
        );

        if (marketState == 0) {
            _markBad(destination);
        } else if (marketState == 1) {
            destination.manager().setMintPaused(true);
        } else {
            destination.manager().setRedeemPaused(2);
        }

        OptimizerReader.MarketIncentiveAPYBps[] memory incentives =
            _oneMarketIncentive(address(destination), 1_000);
        (LendingOptimizer.ReallocationAction[] memory actions,) =
            reader.optimalRebalance(address(optimizer), 0, 100, incentives);

        assertEq(
            _depositAmount(actions, address(destination)),
            0,
            "incentive must not bypass destination eligibility"
        );
    }

    function _deployTwoMarketOptimizer(Scenario memory scenario)
        internal
        returns (
            MockOptimizer optimizer,
            MockCToken source,
            MockCToken destination
        )
    {
        MockRateModel irm = new MockRateModel();
        return _deployTwoMarketOptimizerWithRateModels(
            scenario, address(irm), address(irm)
        );
    }

    /// @dev Deploys the standard two-market liquidity scenario with independently
    ///      selectable IRMs, allowing tests to pin the native-rate ordering.
    function _deployTwoMarketOptimizerWithRateModels(
        Scenario memory scenario,
        address sourceIrm,
        address destinationIrm
    )
        internal
        returns (
            MockOptimizer optimizer,
            MockCToken source,
            MockCToken destination
        )
    {
        MockMarketManager sourceManager = new MockMarketManager();
        MockMarketManager destinationManager = new MockMarketManager();

        source = new MockCToken(
            UNDERLYING,
            address(sourceManager),
            sourceIrm,
            scenario.sourceAssets,
            scenario.sourceCash,
            scenario.sourceDebt
        );
        destination = new MockCToken(
            UNDERLYING,
            address(destinationManager),
            destinationIrm,
            scenario.destinationAssets,
            scenario.destinationCash,
            scenario.destinationDebt
        );

        address[] memory markets = new address[](2);
        markets[0] = address(source);
        markets[1] = address(destination);

        uint256[] memory caps = new uint256[](2);
        caps[0] = scenario.sourceCapBps * 1e14;
        caps[1] = scenario.destinationCapBps * 1e14;

        optimizer = new MockOptimizer(UNDERLYING, markets, caps);
    }

    /// @dev Creates one funded source and two eligible destinations. The native
    ///      destination has the better IRM rate, while the other can win only
    ///      through its supplied incentive. `sourceCapBps` selects whether the
    ///      forced path is cap repair (5,000) or bad-market evacuation (10,000).
    function _deployThreeMarketRankingScenario(uint256 sourceCapBps)
        internal
        returns (
            MockOptimizer optimizer,
            MockCToken source,
            MockCToken nativeDestination,
            MockCToken incentivizedDestination
        )
    {
        source = new MockCToken(
            UNDERLYING,
            address(new MockMarketManager()),
            address(new MockFlatRateModel(100e9)),
            900_000e6,
            800_000e6,
            1
        );
        nativeDestination = new MockCToken(
            UNDERLYING,
            address(new MockMarketManager()),
            address(new MockFlatRateModel(2e9)),
            0,
            100_000e6,
            1
        );
        incentivizedDestination = new MockCToken(
            UNDERLYING,
            address(new MockMarketManager()),
            address(new MockFlatRateModel(1e9)),
            100_000e6,
            100_000e6,
            1
        );

        address[] memory markets = new address[](3);
        markets[0] = address(source);
        markets[1] = address(nativeDestination);
        markets[2] = address(incentivizedDestination);
        uint256[] memory caps = new uint256[](3);
        caps[0] = sourceCapBps * 1e14;
        caps[1] = WAD;
        caps[2] = WAD;
        optimizer = new MockOptimizer(UNDERLYING, markets, caps);
    }

    /// @dev Makes the reader classify `market` as bad by listing collateral
    ///      whose configured oracle price is zero.
    function _markBad(MockCToken market) internal {
        MockCollateralCToken collateralCToken =
            new MockCollateralCToken(SOURCE_COLLATERAL);
        market.manager().setListed(address(market), address(collateralCToken));
        MockOracleAdaptor adaptor = new MockOracleAdaptor();
        adaptor.setPrice(SOURCE_COLLATERAL, 0);
        oracleManager.setAdaptor(SOURCE_COLLATERAL, address(adaptor));
    }

    function _withdrawAmount(
        LendingOptimizer.ReallocationAction[] memory actions,
        address market
    ) internal pure returns (uint256) {
        for (uint256 i; i < actions.length; ++i) {
            if (address(actions[i].cToken) != market) continue;
            if (actions[i].assetsOrBps >= 0) return 0;
            return uint256(-actions[i].assetsOrBps);
        }

        return 0;
    }

    /// @dev Returns the positive action for `market`, or zero when the market is
    ///      absent from the plan or has a non-deposit action.
    function _depositAmount(
        LendingOptimizer.ReallocationAction[] memory actions,
        address market
    ) internal pure returns (uint256) {
        for (uint256 i; i < actions.length; ++i) {
            if (address(actions[i].cToken) != market) continue;
            if (actions[i].assetsOrBps <= 0) return 0;
            return uint256(actions[i].assetsOrBps);
        }

        return 0;
    }

    function _maxProfitableMove(
        uint256 sourceCash,
        uint256 destinationCash,
        uint256 sourceDebt,
        uint256 destinationDebt,
        uint256 chunkSize
    ) internal pure returns (uint256 moved) {
        while (moved < sourceCash) {
            uint256 amount =
                sourceCash - moved;
            if (amount > chunkSize) amount = chunkSize;

            uint256 sourceRateAfter =
                _rate(sourceCash - moved - amount, sourceDebt);
            uint256 destinationRateAfter =
                _rate(destinationCash + moved + amount, destinationDebt);
            if (destinationRateAfter <= sourceRateAfter) break;

            moved += amount;
        }
    }

    function _assertActionsBalance(LendingOptimizer
                .ReallocationAction[] memory actions) internal pure {
        uint256 deposits;
        uint256 withdrawals;

        for (uint256 i; i < actions.length; ++i) {
            if (actions[i].assetsOrBps > 0) {
                deposits += uint256(actions[i].assetsOrBps);
            } else if (actions[i].assetsOrBps < 0) {
                withdrawals += uint256(-actions[i].assetsOrBps);
            }
        }

        assertEq(deposits, withdrawals, "reader actions must balance exactly");
    }

    function _rate(uint256 cash, uint256 debt)
        internal
        pure
        returns (uint256)
    {
        return debt * WAD / (cash + 1);
    }
}

contract MockCentralRegistry {
    address public oracleManager;

    constructor(address oracleManager_) {
        oracleManager = oracleManager_;
    }
}

contract MockOracleManager {
    mapping(address => address[]) internal adaptors;

    function setAdaptor(address asset, address adaptor) external {
        delete adaptors[asset];
        adaptors[asset].push(adaptor);
    }

    function getPrice(address, bool, bool)
        external
        pure
        returns (uint256 price, uint256 errorCode)
    {
        return (WAD, 1);
    }

    function getPricingAdaptors(address asset)
        external
        view
        returns (address[] memory)
    {
        return adaptors[asset];
    }
}

contract MockOracleAdaptor is IOracleAdaptor {
    mapping(address => uint256) internal prices;

    function setPrice(address asset, uint256 price) external {
        prices[asset] = price;
    }

    function getPrice(address asset, bool, bool)
        external
        view
        returns (PricingResult memory result)
    {
        result = PricingResult({
            price: prices[asset], inUSD: true, hadError: false
        });
    }

    function isSupportedAsset(address) external pure returns (bool) {
        return true;
    }

    function getPriceGuard(address, bool)
        external
        pure
        returns (PriceGuard memory guard)
    {}

    function adaptorType() external pure returns (uint256) {
        return 0;
    }
}

contract MockOptimizer {
    address internal immutable underlying;
    address[] internal markets;
    mapping(address => uint256) internal caps;

    constructor(
        address underlying_,
        address[] memory markets_,
        uint256[] memory caps_
    ) {
        underlying = underlying_;
        markets = markets_;
        for (uint256 i; i < markets_.length; ++i) {
            caps[markets_[i]] = caps_[i];
        }
    }

    function asset() external view returns (address) {
        return underlying;
    }

    function getApprovedMarkets() external view returns (address[] memory) {
        return markets;
    }

    function allocationCaps(address cToken) external view returns (uint256) {
        return caps[cToken];
    }

    function accrueIfNeeded() external {}
}

contract MockCToken {
    address internal immutable underlying;
    MockMarketManager internal immutable manager_;
    IDynamicIRM internal immutable irm;
    uint256 public immutable currentAssets;
    uint256 public immutable heldAssets;
    uint256 public immutable debt;

    constructor(
        address underlying_,
        address manager,
        address irm_,
        uint256 currentAssets_,
        uint256 heldAssets_,
        uint256 debt_
    ) {
        underlying = underlying_;
        manager_ = MockMarketManager(manager);
        irm = IDynamicIRM(irm_);
        currentAssets = currentAssets_;
        heldAssets = heldAssets_;
        debt = debt_;
    }

    function asset() external view returns (address) {
        return underlying;
    }

    function marketManager() external view returns (MockMarketManager) {
        return manager_;
    }

    function manager() external view returns (MockMarketManager) {
        return manager_;
    }

    function balanceOf(address) external view returns (uint256) {
        return currentAssets;
    }

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function convertToShares(uint256 assets) external pure returns (uint256) {
        return assets;
    }

    function previewDeposit(uint256 assets) external pure returns (uint256) {
        return assets;
    }

    function previewWithdraw(uint256 assets) external pure returns (uint256) {
        return assets;
    }

    function assetsHeld() external view returns (uint256) {
        return heldAssets;
    }

    function marketOutstandingDebt() external view returns (uint256) {
        return debt;
    }

    function interestFee() external pure returns (uint256) {
        return 0;
    }

    function IRM() external view returns (IDynamicIRM) {
        return irm;
    }
}

contract MockCollateralCToken {
    address internal immutable underlying;

    constructor(address underlying_) {
        underlying = underlying_;
    }

    function asset() external view returns (address) {
        return underlying;
    }
}

contract MockMarketManager {
    address[] internal listed;
    /// @dev Mutable pause state lets one scenario test each destination policy
    ///      without changing the planner or deploying a different mock type.
    bool internal mintPaused;
    uint8 public redeemPaused;

    /// @dev Mirrors the mint-pause component returned by actionsPaused().
    function setMintPaused(bool paused) external {
        mintPaused = paused;
    }

    /// @dev Uses value 2 to mirror the production manager's full redeem pause.
    function setRedeemPaused(uint8 paused) external {
        redeemPaused = paused;
    }

    function setListed(address borrowable, address collateral) external {
        delete listed;
        listed.push(borrowable);
        listed.push(collateral);
    }

    function actionsPaused(address) external view returns (bool, bool, bool) {
        return (mintPaused, false, false);
    }

    function queryTokensListed() external view returns (address[] memory) {
        return listed;
    }
}

contract MockRateModel {
    function supplyRate(uint256 assetsHeld, uint256 debt, uint256)
        external
        pure
        returns (uint256)
    {
        return debt * WAD / (assetsHeld + 1);
    }
}

/// @dev Deterministic per-second WAD rate model used to isolate incentive
///      arithmetic from utilization-dependent IRM movement in ranking tests.
contract MockFlatRateModel {
    uint256 internal immutable rate;

    constructor(uint256 rate_) {
        rate = rate_;
    }

    function supplyRate(uint256, uint256, uint256)
        external
        view
        returns (uint256)
    {
        return rate;
    }
}
