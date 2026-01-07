// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IERC165 } from "contracts/interfaces/IERC165.sol";
import { IPluginDelegable } from "contracts/interfaces/IPluginDelegable.sol";
import { ERC4626 } from "contracts/libraries/external/ERC4626.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { WAD, BPS } from "contracts/libraries/ConstantsLib.sol";

contract TestLendingOptimizerAddApprovedAsset is TestBaseLendingOptimizer {

    function setUp() public override {
        super.setUp();
    }

    function test_lendingOptimizer_addApprovedAsset_success() public {
        // Setup with one market.
        _setUpOneMarket();

        // Verify initial state.
        assertEq(optimizer.numApprovedMarkets(), 1, "Should have 1 market initially");
        assertEq(optimizer.allocationCaps(cUSDC_WBTC_MARKET), 0, "New market should not be approved yet");

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Add new market with 50% cap.
        optimizer.addApprovedAsset(cUSDC_WBTC_MARKET, 5_000);

        // Verify market was added.
        assertEq(optimizer.numApprovedMarkets(), 2, "Should have 2 markets after adding");
        assertEq(optimizer.allocationCaps(cUSDC_WBTC_MARKET), 5_000 * 1e14, "New market cap should be 50%");
        assertEq(optimizer.approvedCTokensList(1), cUSDC_WBTC_MARKET, "New market should be at index 1");
    }

    function test_lendingOptimizer_addApprovedAsset_success_withMaxCap() public {
        // Setup with one market.
        _setUpOneMarket();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Add new market with 100% cap (max allowed).
        optimizer.addApprovedAsset(cUSDC_WBTC_MARKET, 10_000);

        // Verify market was added with 100% cap.
        assertEq(optimizer.allocationCaps(cUSDC_WBTC_MARKET), WAD, "New market cap should be 100%");
    }

    function test_lendingOptimizer_addApprovedAsset_fail_whenUnauthorized() public {
        _setUpOneMarket();

        // Mock market permissions to return false.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(false)
        );

        vm.expectRevert(LendingOptimizer.LendingOptimizer__Unauthorized.selector);
        optimizer.addApprovedAsset(cUSDC_WBTC_MARKET, 5_000);
    }

    function test_lendingOptimizer_addApprovedAsset_fail_whenZeroAddress() public {
        _setUpOneMarket();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        vm.expectRevert(LendingOptimizer.LendingOptimizer__InvalidParameter.selector);
        optimizer.addApprovedAsset(address(0), 5_000);
    }

    function test_lendingOptimizer_addApprovedAsset_fail_whenCapIsZero() public {
        _setUpOneMarket();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        vm.expectRevert(LendingOptimizer.LendingOptimizer__InvalidParameter.selector);
        optimizer.addApprovedAsset(cUSDC_WBTC_MARKET, 0);
    }

    function test_lendingOptimizer_addApprovedAsset_fail_whenCapExceeds100Percent() public {
        _setUpOneMarket();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Try to add with cap > 10_000 BPS (> 100%).
        vm.expectRevert(LendingOptimizer.LendingOptimizer__InvalidParameter.selector);
        optimizer.addApprovedAsset(cUSDC_WBTC_MARKET, 10_001);
    }

    function test_lendingOptimizer_addApprovedAsset_fail_whenMarketAlreadyApproved() public {
        _setUpOneMarket();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Try to add the already approved market (cUSDC_WMON_MARKET).
        vm.expectRevert(LendingOptimizer.LendingOptimizer__MarketAlreadyApproved.selector);
        optimizer.addApprovedAsset(cUSDC_WMON_MARKET, 5_000);
    }

    function test_lendingOptimizer_addApprovedAsset_fail_whenTooManyMarkets() public {
        // Setup with three markets (already at 3, MAX_MARKETS = 6).
        _setUpThreeMarkets();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // We need to add 3 more markets to reach the limit, then try to add one more.
        // For this test, we'll mock additional markets.
        // Since we only have 3 real markets, let's create mock addresses.
        address mockMarket4 = makeAddr("mockMarket4");
        address mockMarket5 = makeAddr("mockMarket5");
        address mockMarket6 = makeAddr("mockMarket6");
        address mockMarket7 = makeAddr("mockMarket7");

        // Mock the cToken interface for each mock market.
        _mockValidCToken(mockMarket4);
        _mockValidCToken(mockMarket5);
        _mockValidCToken(mockMarket6);
        _mockValidCToken(mockMarket7);

        // Add markets 4, 5, 6 to reach MAX_MARKETS.
        optimizer.addApprovedAsset(mockMarket4, 1_000);
        optimizer.addApprovedAsset(mockMarket5, 1_000);
        optimizer.addApprovedAsset(mockMarket6, 1_000);

        assertEq(optimizer.numApprovedMarkets(), 6, "Should have 6 markets (MAX_MARKETS)");

        // Now try to add one more - should fail.
        vm.expectRevert(LendingOptimizer.LendingOptimizer__TooManyMarkets.selector);
        optimizer.addApprovedAsset(mockMarket7, 1_000);
    }

    function test_lendingOptimizer_addApprovedAsset_fail_whenInvalidUnderlying() public {
        _setUpOneMarket();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Create a mock market with wrong underlying asset.
        address mockMarket = makeAddr("wrongUnderlyingMarket");
        address wrongUnderlying = makeAddr("wrongUnderlying");

        // Mock cToken.asset() to return wrong underlying.
        vm.mockCall(
            mockMarket,
            abi.encodeWithSelector(IBorrowableCToken.asset.selector),
            abi.encode(wrongUnderlying)
        );

        vm.expectRevert(LendingOptimizer.LendingOptimizer__InvalidUnderlying.selector);
        optimizer.addApprovedAsset(mockMarket, 5_000);
    }

    function test_lendingOptimizer_addApprovedAsset_fail_whenInvalidMarketManager() public {
        _setUpOneMarket();

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Create a mock market with correct underlying but invalid market manager.
        address mockMarket = makeAddr("invalidManagerMarket");
        address invalidManager = makeAddr("invalidManager");

        // Mock cToken.asset() to return correct underlying.
        vm.mockCall(
            mockMarket,
            abi.encodeWithSelector(IBorrowableCToken.asset.selector),
            abi.encode(USDC_MONAD)
        );

        // Mock cToken.marketManager() to return invalid manager.
        vm.mockCall(
            mockMarket,
            abi.encodeWithSelector(IBorrowableCToken.marketManager.selector),
            abi.encode(invalidManager)
        );

        // Mock centralRegistry.isMarketManager() to return false.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.isMarketManager.selector, invalidManager),
            abi.encode(false)
        );

        vm.expectRevert(LendingOptimizer.LendingOptimizer__InvalidMarketManager.selector);
        optimizer.addApprovedAsset(mockMarket, 5_000);
    }

    /// @dev Helper to mock a valid cToken for testing TooManyMarkets.
    function _mockValidCToken(address mockMarket) internal {
        address validManager = address(IBorrowableCToken(cUSDC_WMON_MARKET).marketManager());

        // Mock cToken.asset() to return correct underlying.
        vm.mockCall(
            mockMarket,
            abi.encodeWithSelector(IBorrowableCToken.asset.selector),
            abi.encode(USDC_MONAD)
        );

        // Mock cToken.marketManager() to return valid manager.
        vm.mockCall(
            mockMarket,
            abi.encodeWithSelector(IBorrowableCToken.marketManager.selector),
            abi.encode(validManager)
        );
    }
}
