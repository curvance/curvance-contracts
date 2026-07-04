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

        (LendingOptimizer.ReallocationAction[] memory actions,) =
            reader.optimalRebalance(address(optimizer), 0, 100);

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
        (LendingOptimizer.ReallocationAction[] memory actions,) =
            reader.optimalRebalance(address(optimizer), 0, chunks);

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
        (LendingOptimizer.ReallocationAction[] memory actions,) =
            reader.optimalRebalance(address(optimizer), 0, chunks);

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

        (LendingOptimizer.ReallocationAction[] memory actions,) =
            reader.optimalRebalance(address(optimizer), 0, 100);

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

        _markSourceBad(badSource);

        (LendingOptimizer.ReallocationAction[] memory actions,) =
            reader.optimalRebalance(address(optimizer), 0, 100);

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

        _markSourceBad(badSource);

        (LendingOptimizer.ReallocationAction[] memory actions,) =
            reader.optimalRebalance(address(optimizer), 0, 100);

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

    function _markSourceBad(MockCToken source) internal {
        MockCollateralCToken collateralCToken =
            new MockCollateralCToken(SOURCE_COLLATERAL);
        source.manager().setListed(address(source), address(collateralCToken));
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
    uint8 public redeemPaused;

    function setListed(address borrowable, address collateral) external {
        delete listed;
        listed.push(borrowable);
        listed.push(collateral);
    }

    function actionsPaused(address) external pure returns (bool, bool, bool) {
        return (false, false, false);
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
