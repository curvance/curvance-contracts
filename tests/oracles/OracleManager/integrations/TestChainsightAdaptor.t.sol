// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { ChainsightAdaptor } from "contracts/oracles/adaptors/chainsight/ChainsightAdaptor.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IManagementOracle } from "contracts/interfaces/external/chainsight/IManagementOracle.sol";
import { IOracleAdaptor } from "contracts/interfaces/IOracleAdaptor.sol";

contract TestChainsightAdaptor is Test {
    address internal _ASSET = makeAddr("asset");
    address internal _SENDER = makeAddr("sender");
    bytes32 internal _FEED_KEY = bytes32(uint256(0xfeed));
    address internal _PROXY = makeAddr("managementOracleProxy");

    CentralRegistry internal centralRegistry;
    ChainsightAdaptor internal adaptor;

    function setUp() public {
        vm.warp(2_000_000_000);

        centralRegistry = new CentralRegistry(
            address(this),
            address(this),
            block.timestamp + 365 days,
            address(0),
            address(0)
        );

        // Constructor calls readAs* with (address(0), bytes32(0)) for sanity.
        // Mock both selectors to return non-reverting values.
        vm.mockCall(
            _PROXY,
            abi.encodeWithSelector(IManagementOracle.readAsUint256WithTimestamp.selector),
            abi.encode(uint256(0), uint64(0))
        );
        vm.mockCall(
            _PROXY,
            abi.encodeWithSelector(IManagementOracle.readAsInt256WithTimestamp.selector),
            abi.encode(int256(0), uint64(0))
        );

        adaptor = new ChainsightAdaptor(
            ICentralRegistry(address(centralRegistry)),
            _PROXY
        );
    }

    /// @notice Pre-fix: future-dated `readTimestampSigned` underflowed under
    ///         checked arithmetic and panicked. Post-fix: unchecked wrap
    ///         exceeds heartbeat → typed revert.
    function test_addAsset_revertsOnFutureDatedTimestampWithoutPanicking() public {
        uint256 price = 1e18;
        uint256 futureTimestamp = block.timestamp + 1 hours;

        vm.mockCall(
            _PROXY,
            abi.encodeWithSelector(
                IManagementOracle.readAsUint256WithTimestamp.selector,
                _SENDER,
                _FEED_KEY
            ),
            abi.encode(price, uint64(futureTimestamp))
        );
        vm.mockCall(
            _PROXY,
            abi.encodeWithSelector(
                IManagementOracle.readAsInt256WithTimestamp.selector,
                _SENDER,
                _FEED_KEY
            ),
            abi.encode(int256(price), uint64(futureTimestamp))
        );

        vm.expectRevert(
            ChainsightAdaptor.ChainsightAdaptor__InvalidPriceConfiguration.selector
        );
        adaptor.addAsset(_ASSET, true, _SENDER, 18, 0, _FEED_KEY);
    }

    /// @notice Sanity: stale timestamps (past heartbeat) revert with the
    ///         same typed error. Confirms the unchecked wrap doesn't
    ///         change the stale path's behavior.
    function test_addAsset_revertsOnStaleTimestamp() public {
        uint256 price = 1e18;
        // 2 days old; default heartbeat is 1 day + grace.
        uint256 staleTimestamp = block.timestamp - 2 days;

        vm.mockCall(
            _PROXY,
            abi.encodeWithSelector(
                IManagementOracle.readAsUint256WithTimestamp.selector,
                _SENDER,
                _FEED_KEY
            ),
            abi.encode(price, uint64(staleTimestamp))
        );
        vm.mockCall(
            _PROXY,
            abi.encodeWithSelector(
                IManagementOracle.readAsInt256WithTimestamp.selector,
                _SENDER,
                _FEED_KEY
            ),
            abi.encode(int256(price), uint64(staleTimestamp))
        );

        vm.expectRevert(
            ChainsightAdaptor.ChainsightAdaptor__InvalidPriceConfiguration.selector
        );
        adaptor.addAsset(_ASSET, true, _SENDER, 18, 0, _FEED_KEY);
    }

    /// @notice Runtime happy path: fresh feed, valid price, no error.
    function test_getPrice_returnsRawPriceWhenFresh() public {
        _addHappyPathAsset();

        // Mock runtime read with a different price than addAsset's seed.
        _mockRuntimeRead(int256(2e18), uint64(block.timestamp));

        IOracleAdaptor.PricingResult memory result =
            adaptor.getPrice(_ASSET, true, false);

        assertFalse(result.hadError, "expected no error on fresh valid feed");
        assertEq(result.price, 2e18, "expected raw price (no guard)");
        assertTrue(result.inUSD, "expected inUSD passed through");
    }

    /// @notice Runtime zero-price path: early-return at line 187 in
    ///         `_getPrice` bubbles `hadError=true, price=0`.
    function test_getPrice_signalsErrorOnZeroPrice() public {
        _addHappyPathAsset();

        _mockRuntimeRead(int256(0), uint64(block.timestamp));

        IOracleAdaptor.PricingResult memory result =
            adaptor.getPrice(_ASSET, true, false);

        assertTrue(result.hadError, "expected hadError on zero price");
        assertEq(result.price, 0, "expected price=0");
    }

    /// @notice Runtime stale path: timestamp older than DEFAULT_HEARTBEAT
    ///         triggers `_verifyData` → `hadError=true`. Price still
    ///         reported (post-`_adjustPrice`) per existing `_verifyData`
    ///         contract.
    function test_getPrice_signalsErrorOnStaleTimestamp() public {
        _addHappyPathAsset();

        // 2 days > 1 day + grace heartbeat.
        _mockRuntimeRead(int256(1e18), uint64(block.timestamp - 2 days));

        IOracleAdaptor.PricingResult memory result =
            adaptor.getPrice(_ASSET, true, false);

        assertTrue(result.hadError, "expected hadError on stale feed");
    }

    /// @notice Runtime future-dated path: unchecked wrap in `_verifyData`
    ///         turns negative subtraction into huge unsigned exceeding
    ///         heartbeat → `hadError=true` instead of arithmetic panic.
    function test_getPrice_signalsErrorOnFutureDatedTimestamp() public {
        _addHappyPathAsset();

        _mockRuntimeRead(int256(1e18), uint64(block.timestamp + 1 hours));

        IOracleAdaptor.PricingResult memory result =
            adaptor.getPrice(_ASSET, true, false);

        assertTrue(result.hadError, "expected hadError on future-dated feed");
    }

    /// INTERNAL HELPERS ///

    function _addHappyPathAsset() internal {
        // Seed addAsset with a fresh, matching uint/int price.
        _mockRuntimeRead(int256(1e18), uint64(block.timestamp));
        vm.mockCall(
            _PROXY,
            abi.encodeWithSelector(
                IManagementOracle.readAsUint256WithTimestamp.selector,
                _SENDER,
                _FEED_KEY
            ),
            abi.encode(uint256(1e18), uint64(block.timestamp))
        );
        adaptor.addAsset(_ASSET, true, _SENDER, 18, 0, _FEED_KEY);
    }

    function _mockRuntimeRead(int256 price, uint64 timestamp) internal {
        vm.mockCall(
            _PROXY,
            abi.encodeWithSelector(
                IManagementOracle.readAsInt256WithTimestamp.selector,
                _SENDER,
                _FEED_KEY
            ),
            abi.encode(price, timestamp)
        );
    }
}
