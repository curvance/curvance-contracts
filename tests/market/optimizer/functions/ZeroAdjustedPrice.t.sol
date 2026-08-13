// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { LendingOptimizerHarness } from "../LendingOptimizerHarness.sol";
import { OptimizerReader } from "contracts/views/OptimizerReader.sol";
import { CombinedAggregator } from "contracts/oracles/adaptors/wrappedAggregators/CombinedAggregator.sol";
import { IOracleAdaptor } from "contracts/interfaces/IOracleAdaptor.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";

/// @title OptimizerReader Zero-Price Checks
/// @notice Tests the simplified bad-market flow where the reader treats a
///         collateral market as bad when its adjusted oracle price is zero.
contract TestZeroAdjustedPrice is TestBaseLendingOptimizer {

    OptimizerReader reader;

    address collAsset0;
    address collAsset1;

    function setUp() public override {
        super.setUp();

        collAsset0 = _collaterals[cUSDC_WMON_MARKET];
        collAsset1 = _collaterals[cUSDC_WBTC_MARKET];

        reader = new OptimizerReader(
            ICentralRegistry(address(liveCentralRegistry)),
            0
        );
    }

    function test_constructor_setsStalenessMultiplier() public {
        OptimizerReader r = new OptimizerReader(
            ICentralRegistry(address(liveCentralRegistry)),
            15000
        );

        assertEq(r.stalenessMultiplierBps(), 15000);
    }

    function test_isBad_zeroAdjustedPrice_marketFlagged() public {
        _setUpThreeMarketsUnconstrained();
        _mockAdaptorPrice(collAsset0, 0, true);

        address[] memory bad = reader.isBad(address(optimizer));

        assertEq(bad.length, 1, "Zero adjusted price should flag market");
        assertEq(bad[0], cUSDC_WMON_MARKET);
    }

    function test_isBad_adaptorPriceGuardBelowMin_returnsZeroAndFlags() public {
        _setUpThreeMarketsUnconstrained();

        _chainlinkAdaptor.setGuardedPriceConfig(
            collAsset0,
            true,
            0,
            0,
            2e18,
            1e18
        );
        _updateAssetFeed(collAsset0, 0.99e8);

        IOracleAdaptor.PricingResult memory result = _chainlinkAdaptor.getPrice(
            collAsset0,
            true,
            true
        );
        assertEq(result.price, 0, "Adaptor guard should zero adjusted price");
        assertTrue(result.hadError, "Adaptor guard should bubble hadError");

        address[] memory bad = reader.isBad(address(optimizer));

        assertEq(bad.length, 1, "Zero adjusted price should flag market");
        assertEq(bad[0], cUSDC_WMON_MARKET);
    }

    function test_isBad_adaptorPriceAtMin_returnsNonZeroAndDoesNotFlag() public {
        _setUpThreeMarketsUnconstrained();

        _chainlinkAdaptor.setGuardedPriceConfig(
            collAsset0,
            true,
            0,
            0,
            2e18,
            1e18
        );

        IOracleAdaptor.PricingResult memory result = _chainlinkAdaptor.getPrice(
            collAsset0,
            true,
            true
        );
        assertEq(result.price, 1e18, "Price exactly at min should stay nonzero");
        assertFalse(result.hadError, "Price exactly at min should not error");

        address[] memory bad = reader.isBad(address(optimizer));

        assertEq(bad.length, 0, "Exact min does not zero, so no bad market");
    }

    function test_isBad_combinedAggregatorPriceGuardBelowMin_returnsZeroAndFlags() public {
        _setUpThreeMarketsUnconstrained();

        MockV3Aggregator secondary = new MockV3Aggregator(18, 1e18);
        CombinedAggregator combined = new CombinedAggregator(
            liveCentralRegistry,
            _getAggregatorProxy(collAsset0),
            address(secondary),
            0,
            "COLL / USD"
        );

        combined.setGuardedPriceConfig(0, 0, 2e18, 1e18);
        _chainlinkAdaptor.addAsset(collAsset0, true, address(combined), 0);
        secondary.updateAnswer(0.99e18);

        IOracleAdaptor.PricingResult memory result = _chainlinkAdaptor.getPrice(
            collAsset0,
            true,
            true
        );
        assertEq(result.price, 0, "Combined guard should zero adjusted price");
        assertTrue(result.hadError, "Combined guard should bubble hadError");

        address[] memory bad = reader.isBad(address(optimizer));

        assertEq(bad.length, 1, "Zero combined price should flag market");
        assertEq(bad[0], cUSDC_WMON_MARKET);
    }

    function test_isBad_combinedAggregatorSecondaryStaleReturnsNonZeroPrice() public {
        _setUpThreeMarketsUnconstrained();
        reader = new OptimizerReader(
            ICentralRegistry(address(liveCentralRegistry)),
            10000
        );

        MockV3Aggregator secondary = new MockV3Aggregator(18, 1e18);
        address primary = _getAggregatorProxy(collAsset0);
        CombinedAggregator combined = new CombinedAggregator(
            liveCentralRegistry,
            primary,
            address(secondary),
            0,
            "COLL / USD"
        );
        _chainlinkAdaptor.addAsset(collAsset0, true, address(combined), 0);

        skip(1 days + 121);
        MockV3Aggregator(primary).updateAnswer(1e8);
        _updateAssetFeed(collAsset1, 1e8);
        _updateAssetFeed(_collaterals[cUSDC_WETH_MARKET], 1e8);

        IOracleAdaptor.PricingResult memory result = _chainlinkAdaptor.getPrice(
            collAsset0,
            true,
            true
        );
        assertEq(result.price, 1e18, "Secondary stale should preserve price");
        assertTrue(result.hadError, "Secondary stale should bubble hadError");

        address[] memory bad = reader.isBad(address(optimizer));

        assertEq(bad.length, 1, "Staleness check should flag market");
        assertEq(bad[0], cUSDC_WMON_MARKET);
    }

    function test_isBad_nonZeroPriceWithAdaptorError_noFlag() public {
        _setUpThreeMarketsUnconstrained();
        _mockAdaptorPrice(collAsset0, 1e18, true);

        address[] memory bad = reader.isBad(address(optimizer));

        assertEq(bad.length, 0, "Nonzero price should not flag by itself");
    }

    function test_isBad_multipleZeroPrices_flagsEachMarket() public {
        _setUpThreeMarketsUnconstrained();
        _mockAdaptorPrice(collAsset0, 0, true);
        _mockAdaptorPrice(collAsset1, 0, true);

        address[] memory bad = reader.isBad(address(optimizer));

        assertEq(bad.length, 2, "Two zero-price markets should be flagged");
        assertEq(bad[0], cUSDC_WMON_MARKET);
        assertEq(bad[1], cUSDC_WBTC_MARKET);
    }

    function test_zeroPrice_integration_defensiveRebalance() public {
        _setUpThreeMarketsUnconstrained();
        _depositToAllMarketsUnconstrained(50_000e6);
        _mockAdaptorPrice(collAsset0, 0, true);

        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500, 200, _emptyMarketIncentives());

        assertTrue(actions.length > 0, "Should have rebalance actions");
        assertLt(
            actions[0].assetsOrBps,
            0,
            "Zero-price market should be withdrawn"
        );
    }

    function test_zeroPrice_integration_rebalanceExecutable() public {
        _setUpThreeMarketsUnconstrained();
        _depositToAllMarketsUnconstrained(50_000e6);
        _mockAdaptorPrice(collAsset0, 0, true);

        (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        ) = reader.optimalRebalance(address(optimizer), 500, 200, _emptyMarketIncentives());

        uint256 totalAssetsBefore = optimizer.totalAssets();

        if (actions.length > 0) {
            optimizer.rebalance(actions, bounds);
        }

        assertApproxEqAbs(
            optimizer.totalAssets(),
            totalAssetsBefore,
            actions.length * 2,
            "Total assets preserved after zero-price rebalance"
        );

        uint256 badAlloc = IBorrowableCToken(cUSDC_WMON_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer))
        );
        uint256 oneChunk = optimizer.totalAssets() / 20;
        assertLe(
            badAlloc,
            oneChunk,
            "Zero-price market should be near-empty after rebalance"
        );
    }

    function _setUpThreeMarketsUnconstrained() internal {
        address[] memory approvedCTokens = new address[](3);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;
        approvedCTokens[2] = cUSDC_WETH_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](3);
        allocationCapsBps[0] = 10_000;
        allocationCapsBps[1] = 10_000;
        allocationCapsBps[2] = 10_000;

        optimizer = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            0
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets);
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(
                ICentralRegistry.hasMarketPermissions.selector,
                address(this)
            ),
            abi.encode(true)
        );
        optimizer.initializeDeposits(cUSDC_WMON_MARKET);

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(
                ICentralRegistry.hasHarvestPermissions.selector,
                address(this)
            ),
            abi.encode(true)
        );
    }

    function _depositToAllMarketsUnconstrained(
        uint256 amountPerMarket
    ) internal {
        address[3] memory markets = [
            cUSDC_WMON_MARKET, cUSDC_WBTC_MARKET, cUSDC_WETH_MARKET
        ];

        for (uint256 i; i < 3; ++i) {
            deal(USDC_MONAD, address(this), amountPerMarket);
            IERC20(USDC_MONAD).approve(address(optimizer), amountPerMarket);
            LendingOptimizerHarness(address(optimizer)).depositToMarket(
                amountPerMarket,
                address(this),
                markets[i]
            );
        }
    }

    function _mockAdaptorPrice(
        address asset,
        uint256 price,
        bool hadError
    ) internal {
        vm.mockCall(
            address(_chainlinkAdaptor),
            abi.encodeWithSelector(
                IOracleAdaptor.getPrice.selector,
                asset,
                true,
                true
            ),
            abi.encode(
                IOracleAdaptor.PricingResult({
                    price: price,
                    inUSD: true,
                    hadError: hadError
                })
            )
        );
    }

    function _getAggregatorProxy(
        address asset
    ) internal view returns (address) {
        (, IChainlink aggregator,,) = _chainlinkAdaptor.assetConfig(asset, true);
        return address(aggregator);
    }

    function _updateAssetFeed(
        address asset,
        int256 price
    ) internal {
        MockV3Aggregator(_getAggregatorProxy(asset)).updateAnswer(price);
    }
}
