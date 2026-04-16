// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { LendingOptimizerHarness } from "../LendingOptimizerHarness.sol";
import { OptimizerReader } from "contracts/views/OptimizerReader.sol";
import { IOracleAdaptor } from "contracts/interfaces/IOracleAdaptor.sol";
import { ICombinedAggregator } from "contracts/interfaces/ICombinedAggregator.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";
import { WAD } from "contracts/libraries/ConstantsLib.sol";

/// @title Guard Config & Price Guard Breach Tests
/// @notice Tests addGuardConfig, removeGuardConfig swap-and-pop correctness,
///         isBad with adaptor-level and aggregator-level price guard breaches,
///         dynamic guards, and integration with optimalRebalance defensive mode.
contract TestGuardConfig is TestBaseLendingOptimizer {

    OptimizerReader reader;

    // Collateral cToken addresses (keyed in guardConfigs).
    address collCToken0;
    address collCToken1;
    address collCToken2;

    // Collateral underlying asset addresses (used in _isGuardBreached).
    address collAsset0;
    address collAsset1;
    address collAsset2;

    function setUp() public override {
        super.setUp();

        collCToken0 = _collCTokens[cUSDC_WMON_MARKET];
        collCToken1 = _collCTokens[cUSDC_WBTC_MARKET];
        collCToken2 = _collCTokens[cUSDC_WETH_MARKET];

        collAsset0 = _collaterals[cUSDC_WMON_MARKET];
        collAsset1 = _collaterals[cUSDC_WBTC_MARKET];
        collAsset2 = _collaterals[cUSDC_WETH_MARKET];

        reader = new OptimizerReader(
            ICentralRegistry(address(liveCentralRegistry)),
            new OptimizerReader.CollateralGuardConfig[](0),
            0 // staleness disabled
        );
    }

    // ==================== Constructor ====================

    function test_constructor_withInitialConfigs() public {
        OptimizerReader.CollateralGuardConfig[] memory configs =
            new OptimizerReader.CollateralGuardConfig[](2);
        configs[0] = OptimizerReader.CollateralGuardConfig({
            cToken: collCToken0, guardType: 1
        });
        configs[1] = OptimizerReader.CollateralGuardConfig({
            cToken: collCToken1, guardType: 2
        });

        OptimizerReader r = new OptimizerReader(
            ICentralRegistry(address(liveCentralRegistry)),
            configs,
            15000
        );

        (address c0, uint256 t0) = r.guardConfigs(0);
        (address c1, uint256 t1) = r.guardConfigs(1);

        assertEq(c0, collCToken0, "Config 0 cToken");
        assertEq(t0, 1, "Config 0 guardType");
        assertEq(c1, collCToken1, "Config 1 cToken");
        assertEq(t1, 2, "Config 1 guardType");
        assertEq(r.stalenessMultiplierBps(), 15000);
    }

    function test_constructor_emptyConfigs() public view {
        // Default reader has empty configs — accessing index 0 should revert
        // but we just verify the reader deployed successfully with no configs.
        assertEq(reader.stalenessMultiplierBps(), 0);
    }

    // ==================== addGuardConfig ====================

    function test_addGuardConfig_success() public {
        vm.expectEmit();
        emit OptimizerReader.GuardConfigAdded(collCToken0, 1);
        reader.addGuardConfig(collCToken0, 1);

        (address c, uint256 t) = reader.guardConfigs(0);
        assertEq(c, collCToken0);
        assertEq(t, 1);
    }

    function test_addGuardConfig_success_multiple() public {
        reader.addGuardConfig(collCToken0, 1);
        reader.addGuardConfig(collCToken1, 2);
        reader.addGuardConfig(collCToken2, 1);

        (address c0,) = reader.guardConfigs(0);
        (address c1,) = reader.guardConfigs(1);
        (address c2,) = reader.guardConfigs(2);

        assertEq(c0, collCToken0);
        assertEq(c1, collCToken1);
        assertEq(c2, collCToken2);
    }

    function test_addGuardConfig_revert_unauthorized() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(OptimizerReader.OptimizerReader__Unauthorized.selector);
        reader.addGuardConfig(collCToken0, 1);
    }

    function test_addGuardConfig_revert_duplicate() public {
        reader.addGuardConfig(collCToken0, 1);
        vm.expectRevert(
            OptimizerReader.OptimizerReader__GuardConfigAlreadyExists.selector
        );
        reader.addGuardConfig(collCToken0, 2);
    }

    // ==================== removeGuardConfig ====================

    function test_removeGuardConfig_success_single() public {
        reader.addGuardConfig(collCToken0, 1);

        vm.expectEmit();
        emit OptimizerReader.GuardConfigRemoved(collCToken0);
        reader.removeGuardConfig(collCToken0);

        // Array should be empty.
        vm.expectRevert();
        reader.guardConfigs(0);
    }

    function test_removeGuardConfig_success_removeLast() public {
        reader.addGuardConfig(collCToken0, 1);
        reader.addGuardConfig(collCToken1, 2);

        reader.removeGuardConfig(collCToken1);

        (address c0, uint256 t0) = reader.guardConfigs(0);
        assertEq(c0, collCToken0);
        assertEq(t0, 1);

        vm.expectRevert();
        reader.guardConfigs(1);
    }

    function test_removeGuardConfig_success_removeFirst_swapAndPop() public {
        reader.addGuardConfig(collCToken0, 1);
        reader.addGuardConfig(collCToken1, 2);
        reader.addGuardConfig(collCToken2, 1);

        // Remove first: last element (collCToken2) moves to index 0.
        reader.removeGuardConfig(collCToken0);

        (address c0, uint256 t0) = reader.guardConfigs(0);
        (address c1, uint256 t1) = reader.guardConfigs(1);

        assertEq(c0, collCToken2, "Last element swapped to index 0");
        assertEq(t0, 1);
        assertEq(c1, collCToken1, "Middle element unchanged");
        assertEq(t1, 2);

        vm.expectRevert();
        reader.guardConfigs(2);
    }

    function test_removeGuardConfig_success_removeMiddle_swapAndPop() public {
        reader.addGuardConfig(collCToken0, 1);
        reader.addGuardConfig(collCToken1, 2);
        reader.addGuardConfig(collCToken2, 1);

        // Remove middle: last element (collCToken2) moves to index 1.
        reader.removeGuardConfig(collCToken1);

        (address c0, uint256 t0) = reader.guardConfigs(0);
        (address c1, uint256 t1) = reader.guardConfigs(1);

        assertEq(c0, collCToken0, "First unchanged");
        assertEq(t0, 1);
        assertEq(c1, collCToken2, "Last swapped to middle");
        assertEq(t1, 1);
    }

    function test_removeGuardConfig_success_reAddAfterRemove() public {
        reader.addGuardConfig(collCToken0, 1);
        reader.addGuardConfig(collCToken1, 2);
        reader.addGuardConfig(collCToken2, 1);

        reader.removeGuardConfig(collCToken0);

        // Re-add collCToken0 at the end.
        reader.addGuardConfig(collCToken0, 2);

        (address c2, uint256 t2) = reader.guardConfigs(2);
        assertEq(c2, collCToken0);
        assertEq(t2, 2);
    }

    function test_removeGuardConfig_success_removeAllThenReAdd() public {
        reader.addGuardConfig(collCToken0, 1);
        reader.addGuardConfig(collCToken1, 2);

        reader.removeGuardConfig(collCToken0);
        reader.removeGuardConfig(collCToken1);

        reader.addGuardConfig(collCToken0, 2);

        (address c0, uint256 t0) = reader.guardConfigs(0);
        assertEq(c0, collCToken0);
        assertEq(t0, 2);
    }

    function test_removeGuardConfig_revert_unauthorized() public {
        reader.addGuardConfig(collCToken0, 1);
        vm.prank(address(0xDEAD));
        vm.expectRevert(OptimizerReader.OptimizerReader__Unauthorized.selector);
        reader.removeGuardConfig(collCToken0);
    }

    function test_removeGuardConfig_revert_notExists() public {
        vm.expectRevert(
            OptimizerReader.OptimizerReader__GuardConfigDoesNotExist.selector
        );
        reader.removeGuardConfig(collCToken0);
    }

    // ==================== isBad: Adaptor-Level Guard (Type 1) ====================

    /// @notice Adaptor guard breached (minPrice > current price) → market flagged.
    function test_isBad_adaptorGuard_breached_marketFlagged() public {
        _setUpOptimizerWithGuard(collCToken0, 1);

        // Static guard: minPrice = 2e18 WAD ($2.00). Oracle price = $1 (1e18).
        // price (1e18) <= effectiveMin (2e18) → breached.
        _mockAdaptorPriceGuard(collAsset0, 0, 0, 2e18, 2e18);

        address[] memory bad = reader.isBad(address(optimizer));
        assertEq(bad.length, 1, "Breached guard should flag market");
        assertEq(bad[0], cUSDC_WMON_MARKET);
    }

    /// @notice Adaptor guard not breached (minPrice < current price) → no flag.
    function test_isBad_adaptorGuard_notBreached_noFlag() public {
        _setUpOptimizerWithGuard(collCToken0, 1);

        // minPrice = 0.5e18 WAD ($0.50). price (1e18) > 0.5e18 → safe.
        _mockAdaptorPriceGuard(collAsset0, 0, 0, 2e18, 0.5e18);

        address[] memory bad = reader.isBad(address(optimizer));
        assertEq(bad.length, 0, "Non-breached guard should not flag");
    }

    /// @notice basePrice == 0 means no guard configured → skip.
    function test_isBad_adaptorGuard_basePriceZero_noGuard() public {
        _setUpOptimizerWithGuard(collCToken0, 1);

        _mockAdaptorPriceGuard(collAsset0, 0, 0, 0, 2e18);

        address[] memory bad = reader.isBad(address(optimizer));
        assertEq(bad.length, 0, "basePrice=0 means no guard");
    }

    /// @notice Price exactly at minPrice → breached (<=, not <).
    function test_isBad_adaptorGuard_exactlyAtMin_breached() public {
        _setUpOptimizerWithGuard(collCToken0, 1);

        // minPrice = 1e18 WAD ($1.00) = exactly the oracle price.
        // price (1e18) <= effectiveMin (1e18) → breached.
        _mockAdaptorPriceGuard(collAsset0, 0, 0, 2e18, 1e18);

        address[] memory bad = reader.isBad(address(optimizer));
        assertEq(bad.length, 1, "Price at min should be breached (<=)");
    }

    // ==================== isBad: Aggregator-Level Guard (Type 2) ====================

    /// @notice Aggregator-level guard breached → market flagged.
    function test_isBad_aggregatorGuard_breached_marketFlagged() public {
        _setUpOptimizerWithGuard(collCToken0, 2);

        address aggregatorProxy = _getAggregatorProxy(collAsset0);
        // minPrice = 2e18 > price (1e18) → breached.
        _mockAggregatorPg(aggregatorProxy, 0, 0, 2e18, 2e18);

        address[] memory bad = reader.isBad(address(optimizer));
        assertEq(bad.length, 1, "Aggregator guard breach should flag");
        assertEq(bad[0], cUSDC_WMON_MARKET);
    }

    /// @notice Aggregator-level guard not breached → no flag.
    function test_isBad_aggregatorGuard_notBreached_noFlag() public {
        _setUpOptimizerWithGuard(collCToken0, 2);

        address aggregatorProxy = _getAggregatorProxy(collAsset0);
        _mockAggregatorPg(aggregatorProxy, 0, 0, 2e18, 0.5e18);

        address[] memory bad = reader.isBad(address(optimizer));
        assertEq(bad.length, 0, "Non-breached aggregator guard: no flag");
    }

    // ==================== isBad: Dynamic Guard (ips > 0) ====================

    /// @notice Dynamic guard: effectiveMin increases over time until breach.
    ///         ips = 1e12 (fits uint40), minPrice = 0.9e18.
    ///         At t=0: effectiveMin = 0.9e18 (safe, price = 1e18).
    ///         At t=120000s: effectiveMin = 0.9e18 * (120000*1e12 + 1e18)/1e18
    ///                     = 0.9e18 * 1.12 ≈ 1.008e18 → breached.
    function test_isBad_dynamicGuard_breachesOverTime() public {
        _setUpOptimizerWithGuard(collCToken0, 1);

        uint40 timestampStart = uint40(block.timestamp);
        _mockAdaptorPriceGuard(
            collAsset0, timestampStart, uint40(1e12), 2e18, 0.9e18
        );

        // Initially safe.
        address[] memory bad0 = reader.isBad(address(optimizer));
        assertEq(bad0.length, 0, "Initially not breached");

        // Skip 120000s → effectiveMin > 1e18 → breached.
        skip(120000);
        address[] memory bad1 = reader.isBad(address(optimizer));
        assertEq(bad1.length, 1, "Breached after time passes");
    }

    // ==================== isBad: guardType 0 Skips ====================

    function test_isBad_guardTypeZero_skipsCheck() public {
        _setUpOptimizerWithGuard(collCToken0, 0);

        // Even with a "breached" guard mocked, guardType=0 means skip.
        _mockAdaptorPriceGuard(collAsset0, 0, 0, 2e18, 2e18);

        address[] memory bad = reader.isBad(address(optimizer));
        assertEq(bad.length, 0, "guardType=0 should skip guard check");
    }

    // ==================== isBad: Multiple Markets ====================

    /// @notice Two guards configured, only one breached → only that market flagged.
    function test_isBad_multipleGuards_oneBreach() public {
        OptimizerReader.CollateralGuardConfig[] memory configs =
            new OptimizerReader.CollateralGuardConfig[](2);
        configs[0] = OptimizerReader.CollateralGuardConfig({
            cToken: collCToken0, guardType: 1
        });
        configs[1] = OptimizerReader.CollateralGuardConfig({
            cToken: collCToken1, guardType: 1
        });

        reader = new OptimizerReader(
            ICentralRegistry(address(liveCentralRegistry)), configs, 0
        );
        _setUpThreeMarketsUnconstrained();

        // Market 0: breached (minPrice 2e18 > price 1e18).
        _mockAdaptorPriceGuard(collAsset0, 0, 0, 2e18, 2e18);
        // Market 1: safe (minPrice 0.5e18 < price 1e18).
        _mockAdaptorPriceGuard(collAsset1, 0, 0, 2e18, 0.5e18);

        address[] memory bad = reader.isBad(address(optimizer));
        assertEq(bad.length, 1, "Only breached market flagged");
        assertEq(bad[0], cUSDC_WMON_MARKET);
    }

    /// @notice Both guards breached → both flagged.
    function test_isBad_multipleGuards_bothBreached() public {
        OptimizerReader.CollateralGuardConfig[] memory configs =
            new OptimizerReader.CollateralGuardConfig[](2);
        configs[0] = OptimizerReader.CollateralGuardConfig({
            cToken: collCToken0, guardType: 1
        });
        configs[1] = OptimizerReader.CollateralGuardConfig({
            cToken: collCToken1, guardType: 1
        });

        reader = new OptimizerReader(
            ICentralRegistry(address(liveCentralRegistry)), configs, 0
        );
        _setUpThreeMarketsUnconstrained();

        _mockAdaptorPriceGuard(collAsset0, 0, 0, 2e18, 2e18);
        _mockAdaptorPriceGuard(collAsset1, 0, 0, 2e18, 2e18);

        address[] memory bad = reader.isBad(address(optimizer));
        assertEq(bad.length, 2, "Both breached markets flagged");
    }

    // ==================== Swap-and-Pop Index Correctness in isBad ====================

    /// @notice After removing a guard config via swap-and-pop, the remaining
    ///         config should still be correctly looked up by isBad.
    function test_isBad_afterSwapAndPop_remainingConfigCorrect() public {
        OptimizerReader.CollateralGuardConfig[] memory configs =
            new OptimizerReader.CollateralGuardConfig[](2);
        configs[0] = OptimizerReader.CollateralGuardConfig({
            cToken: collCToken0, guardType: 1
        });
        configs[1] = OptimizerReader.CollateralGuardConfig({
            cToken: collCToken1, guardType: 1
        });

        reader = new OptimizerReader(
            ICentralRegistry(address(liveCentralRegistry)), configs, 0
        );
        _setUpThreeMarketsUnconstrained();

        // Mock market 1's guard as breached.
        _mockAdaptorPriceGuard(collAsset1, 0, 0, 2e18, 2e18);
        // Market 0's guard: safe.
        _mockAdaptorPriceGuard(collAsset0, 0, 0, 2e18, 0.5e18);

        // Verify market 1 is flagged.
        address[] memory bad1 = reader.isBad(address(optimizer));
        assertEq(bad1.length, 1);
        assertEq(bad1[0], cUSDC_WBTC_MARKET);

        // Remove collCToken0's guard → swap-and-pop: collCToken1 moves to index 0.
        reader.removeGuardConfig(collCToken0);

        // isBad should STILL find collCToken1's breached guard.
        address[] memory bad2 = reader.isBad(address(optimizer));
        assertEq(bad2.length, 1, "Guard still found after swap-and-pop");
        assertEq(bad2[0], cUSDC_WBTC_MARKET);
    }

    /// @notice After removing a guard config, isBad should no longer check
    ///         the removed config's market.
    function test_isBad_afterRemove_removedConfigNotChecked() public {
        _setUpOptimizerWithGuard(collCToken0, 1);

        // Mock guard as breached.
        _mockAdaptorPriceGuard(collAsset0, 0, 0, 2e18, 2e18);

        // Should flag.
        address[] memory bad1 = reader.isBad(address(optimizer));
        assertEq(bad1.length, 1);

        // Remove the guard.
        reader.removeGuardConfig(collCToken0);

        // Should no longer flag (guard config gone).
        address[] memory bad2 = reader.isBad(address(optimizer));
        assertEq(bad2.length, 0, "Removed guard should not be checked");
    }

    // ==================== Integration: Guard Breach → Defensive Rebalance ====================

    /// @notice Guard breach triggers a defensive exit from the breached market.
    function test_guardBreach_integration_defensiveRebalance() public {
        OptimizerReader.CollateralGuardConfig[] memory configs =
            new OptimizerReader.CollateralGuardConfig[](1);
        configs[0] = OptimizerReader.CollateralGuardConfig({
            cToken: collCToken0, guardType: 1
        });

        reader = new OptimizerReader(
            ICentralRegistry(address(liveCentralRegistry)), configs, 0
        );
        _setUpThreeMarketsUnconstrained();
        _depositToAllMarketsUnconstrained(50_000e6);

        // Breach market 0's guard.
        _mockAdaptorPriceGuard(collAsset0, 0, 0, 2e18, 2e18);

        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500);

        assertTrue(actions.length > 0, "Should have rebalance actions");

        // Market 0 should have a withdrawal (negative action).
        assertLt(
            actions[0].assetsOrBps,
            0,
            "Breached market should be withdrawn"
        );

        // At least one good market should receive deposits.
        bool hasDeposit;
        for (uint256 i = 1; i < actions.length; ++i) {
            if (actions[i].assetsOrBps > 0) {
                hasDeposit = true;
                break;
            }
        }
        assertTrue(hasDeposit, "Good markets should receive deposits");
    }

    /// @notice Guard-triggered defensive rebalance is executable without revert.
    function test_guardBreach_integration_rebalanceExecutable() public {
        OptimizerReader.CollateralGuardConfig[] memory configs =
            new OptimizerReader.CollateralGuardConfig[](1);
        configs[0] = OptimizerReader.CollateralGuardConfig({
            cToken: collCToken0, guardType: 1
        });

        reader = new OptimizerReader(
            ICentralRegistry(address(liveCentralRegistry)), configs, 0
        );
        _setUpThreeMarketsUnconstrained();
        _depositToAllMarketsUnconstrained(50_000e6);

        _mockAdaptorPriceGuard(collAsset0, 0, 0, 2e18, 2e18);

        (LendingOptimizer.ReallocationAction[] memory actions,
         LendingOptimizer.AllocationBound[] memory bounds) =
            reader.optimalRebalance(address(optimizer), 500);

        uint256 totalAssetsBefore = optimizer.totalAssets();

        if (actions.length > 0) {
            optimizer.rebalance(actions, bounds);
        }

        assertApproxEqAbs(
            optimizer.totalAssets(),
            totalAssetsBefore,
            actions.length * 2,
            "Total assets preserved after guard-triggered rebalance"
        );

        // Breached market should be near-empty after rebalance.
        uint256 badAlloc = IBorrowableCToken(cUSDC_WMON_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer))
        );
        uint256 oneChunk = optimizer.totalAssets() / 20;
        assertLe(
            badAlloc,
            oneChunk,
            "Breached market should be near-empty after rebalance"
        );
    }

    // ==================== Internal Helpers ====================

    /// @dev Sets up an optimizer and reader with a single guard config.
    function _setUpOptimizerWithGuard(
        address collCToken,
        uint256 guardType
    ) internal {
        OptimizerReader.CollateralGuardConfig[] memory configs =
            new OptimizerReader.CollateralGuardConfig[](1);
        configs[0] = OptimizerReader.CollateralGuardConfig({
            cToken: collCToken, guardType: guardType
        });

        reader = new OptimizerReader(
            ICentralRegistry(address(liveCentralRegistry)), configs, 0
        );

        _setUpThreeMarketsUnconstrained();
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
        for (uint256 i = 0; i < 3; i++) {
            deal(USDC_MONAD, address(this), amountPerMarket);
            IERC20(USDC_MONAD).approve(address(optimizer), amountPerMarket);
            LendingOptimizerHarness(address(optimizer)).depositToMarket(
                amountPerMarket, address(this), markets[i]
            );
        }
    }

    /// @dev Mocks IOracleAdaptor.getPriceGuard on the chainlink adaptor.
    function _mockAdaptorPriceGuard(
        address asset,
        uint40 timestampStart,
        uint40 ips,
        uint256 basePrice,
        uint256 minPrice
    ) internal {
        vm.mockCall(
            address(_chainlinkAdaptor),
            abi.encodeWithSelector(
                IOracleAdaptor.getPriceGuard.selector,
                asset,
                true
            ),
            abi.encode(
                IOracleAdaptor.PriceGuard({
                    timestampStart: timestampStart,
                    ips: ips,
                    basePrice: uint88(basePrice),
                    minPrice: uint88(minPrice)
                })
            )
        );
    }

    /// @dev Returns the aggregator proxy address for an asset from the
    ///      chainlink adaptor's assetConfig.
    function _getAggregatorProxy(
        address asset
    ) internal view returns (address) {
        (, IChainlink agg,,) = _chainlinkAdaptor.assetConfig(asset, true);
        return address(agg);
    }

    /// @dev Mocks ICombinedAggregator.pg() on an aggregator proxy address.
    function _mockAggregatorPg(
        address aggregator,
        uint40 timestampStart,
        uint40 ips,
        uint256 basePrice,
        uint256 minPrice
    ) internal {
        vm.mockCall(
            aggregator,
            abi.encodeWithSelector(ICombinedAggregator.pg.selector),
            abi.encode(
                timestampStart,
                ips,
                uint88(basePrice),
                uint88(minPrice)
            )
        );
    }
}
