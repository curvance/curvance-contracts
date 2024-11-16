// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { BaseCallDataChecker } from "contracts/calldata-checker/BaseCallDataChecker.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IMulticallChecker } from "contracts/interfaces/IMulticallChecker.sol";

/// @title Curvance Multicall helper.
/// @notice Multicall implementation to support pull based oracles and
///         other combined actions.
abstract contract Multicall is BaseCallDataChecker {
    /// TYPES ///
    struct MulticallData {
        address target;
        bool isPriceUpdate;
        bytes data;
    }

    /// ERRORS ///

    error Multicall__InvalidTarget();
    error Multicall__UnknownCalldata();
    error Multicall__InvalidCallData();
    error Multicall__CallFailed();

    /// EXTERNAL FUNCTIONS ///

    /// @notice Executes multiple calls in a single transaction.
    ///         This can be used to update oracle prices before
    ///         a liquidity dependent action.
    function multicall(
        MulticallData[] calldata calls
    ) external returns (bytes[] memory results) {
        ICentralRegistry centralRegistry = _getCentralRegistry();
        uint256 numCalls = calls.length;

        results = new bytes[](numCalls);
        for (uint256 i; i < numCalls; ++i) {
            if (calls[i].isPriceUpdate) {
                address callDataChecker = centralRegistry.multicallChecker(
                    calls[i].target
                );

                // Validate we know how to verify this calldata.
                if (callDataChecker == address(0)) {
                    revert Multicall__UnknownCalldata();
                }

                IMulticallChecker(callDataChecker).checkCalldata(
                    msg.sender,
                    calls[i].target,
                    calls[i].data
                );

                results[i] = _call(
                    calls[i].target,
                    calls[i].data
                );
            } else {
                if (address(this) != calls[i].target) {
                    revert Multicall__InvalidTarget();
                }

                results[i] = _delegateCall(
                    address(this),
                    calls[i].data
                );
            }
        }
    }

    /// @notice Executes a low level .call() and validates that execution
    ///         was safely performed.
    /// @dev Performs a Solidity function call using a low level `call`.
    ///      If `target` reverts with a revert reason or custom error,
    ///      it is bubbled up by this function (like regular Solidity function
    ///      calls). However, if the call reverted with no returned reason,
    ///      this function reverts with a {Multicall__CallFailed} error.
    ///
    ///      Requirements:
    ///      - `target` must be a contract.
    ///      - calling `target` with `data` must not revert.
    ///
    ///      Workflow validated against industry standard OpenZeppelin's
    ///      Address.sol for safe low level call usage.
    /// @param targetContract The target contract address to execute .call()
    ///                       at.
    /// @param data The bytecode data to attach to the .call() execution
    ///             including the function signature hash and function call
    ///             parameters.
    function _call(
        address targetContract,
        bytes memory data
    ) internal returns (bytes memory) {
        (bool success, bytes memory returnData) = targetContract.call{value: 0}(data);
        return _verifyResult(targetContract, success, returnData);
    }

    /// @notice Executes a low level .delegatecall() and validates that
    ///         execution was safely performed.
    /// @dev Performs a Solidity function delegated call using a low level
    ///      `delegatecall`.
    ///      If `target` reverts with a revert reason or custom error,
    ///      it is bubbled up by this function (like regular Solidity function
    ///      calls). However, if the call reverted with no returned reason,
    ///      this function reverts with a {Multicall__CallFailed} error.
    ///
    ///      Requirements:
    ///      - `target` must be a contract.
    ///      - calling `target` with `data` must not revert.
    ///
    ///      Workflow validated against industry standard OpenZeppelin's
    ///      Address.sol for safe low level call usage.
    /// @param targetContract The target contract address to execute
    ///                       .delegatecall() at.
    /// @param data The bytecode data to attach to the .call() execution
    ///             including the function signature hash and function call
    ///             parameters.
    function _delegateCall(
        address targetContract,
        bytes memory data
    ) internal returns (bytes memory) {
        (bool success, bytes memory returnData) = targetContract.delegatecall(data);
        return _verifyResult(targetContract, success, returnData);
    }

    /// @dev Validates whether the low level call or delegate call was
    ///      successful and reverts in cases of bubbled up revert messages
    ///      or if `targetContract` was not actually a contract.
    function _verifyResult(
        address targetContract,
        bool success,
        bytes memory returnData
    ) internal view returns (bytes memory) {
        _propagateError(success, returnData);

        // If the call was successful but there was no return data we need
        // to make sure a contract was actually called as expected.
        if (returnData.length == 0 && targetContract.code.length == 0) {
            revert Multicall__CallFailed();
        }

        return returnData;
    }

    /// @dev Propagates an error message, if necessary.
    /// @param success If transaction was successful.
    /// @param resultData The transaction result data.
    function _propagateError(
        bool success,
        bytes memory resultData
    ) internal pure {
        if (!success) {
            if (resultData.length == 0) {
                revert Multicall__CallFailed();
            }

            // Bubble up error if there was one given.
            assembly {
                revert(add(32, resultData), mload(resultData))
            }
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
