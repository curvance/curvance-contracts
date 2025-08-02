// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { LowLevelCallsHelper } from "contracts/libraries/LowLevelCallsHelper.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IMulticallChecker } from "contracts/interfaces/IMulticallChecker.sol";

/// @title Curvance Multicall helper.
/// @notice Multicall implementation to support pull based oracles and
///         other chained actions within Curvance.
abstract contract Multicall {
    /// TYPES ///

    /// @notice Struct containing information on the desired
    ///         multicall action to execute. 
    /// @param target The address of the target contract to execute the call at.
    /// @param isPriceUpdate Boolean indicating if the call is a price update.
    /// @param data The data to attach to the call.
    struct MulticallAction {
        address target;
        bool isPriceUpdate;
        bytes data;
    }

    /// ERRORS ///

    error Multicall__InvalidTarget();
    error Multicall__UnknownCalldata();

    /// EXTERNAL FUNCTIONS ///

    /// @notice Executes multiple calls in a single transaction.
    ///         This can be used to update oracle prices before
    ///         a liquidity dependent action.
    function multicall(
        MulticallAction[] calldata calls
    ) external returns (bytes[] memory results) {
        ICentralRegistry centralRegistry = _getCentralRegistry();
        uint256 numCalls = calls.length;
        results = new bytes[](numCalls);
        MulticallAction memory cachedCall;

        for (uint256 i; i < numCalls; ++i) {
            cachedCall = calls[i];
            
            if (cachedCall.isPriceUpdate) {
                // CASE: We need to update a pull based price oracle and we
                //       need a direct call to the target address.
                address checker = centralRegistry.multicallChecker(
                    cachedCall.target
                );

                // Validate we know how to verify this calldata.
                if (checker == address(0)) {
                    revert Multicall__UnknownCalldata();
                }

                IMulticallChecker(checker).checkCalldata(
                    msg.sender,
                    cachedCall.target,
                    cachedCall.data
                );

                results[i] = LowLevelCallsHelper._call(
                    cachedCall.target,
                    cachedCall.data
                );
                continue;
            }

            // CASE: Not a price update and we need delegate the call to the
            //       current address.

            if (address(this) != cachedCall.target) {
                revert Multicall__InvalidTarget();
            }

            results[i] = LowLevelCallsHelper._delegateCall(
                address(this),
                cachedCall.data
            );
        }
    }

    /// @notice Returns the Protocol Central Registry contract in interface
    ///         form.
    /// @dev MUST be overridden in every multicallable contract's
    ///      implementation.
    function _getCentralRegistry()
        internal
        view
        virtual
        returns (ICentralRegistry);
}
