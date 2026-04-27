// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { ChainsightAdaptor } from "contracts/oracles/adaptors/chainsight/ChainsightAdaptor.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IManagementOracle } from "contracts/interfaces/external/chainsight/IManagementOracle.sol";

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
}
