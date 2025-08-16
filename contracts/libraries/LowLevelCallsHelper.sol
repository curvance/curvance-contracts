// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

library LowLevelCallsHelper {
    /// ERRORS ///

    error LowLevelCallsHelper__InsufficientBalance();
    error LowLevelCallsHelper__CallFailed();

    /// INTERNAL FUNCTIONS ///

    /// @notice Executes a low level .call() and validates that execution
    ///         was safely performed.
    /// @dev Bubbles up errors and reverts if anything along the execution
    ///      path failed or was a red flag.
    /// @param target The target contract address to execute .call() at.
    /// @param data The bytecode data to attach to the .call() execution
    ///             including the function signature hash and function call
    ///             parameters.
    function _call(
        address target,
        bytes memory data
    ) internal returns (bytes memory) {
        (bool success, bytes memory returnData) = target.call{value: 0}(data);
        
        return _verifyResult(target, success, returnData);
    }

    /// @notice Executes a low level .call(), with attached native token
    ///         and validates that execution was safely performed.
    /// @dev Bubbles up errors and reverts if anything along the execution
    ///      path failed or was a red flag.
    /// @param target The target contract address to execute .call() at.
    /// @param data The bytecode data to attach to the .call() execution
    ///             including the function signature hash and function call
    ///             parameters.
    /// @param value The amount of native token to attach to the low level
    ///              call.
    function _callWithNative(
        address target,
        bytes memory data,
        uint256 value
    ) internal returns (bytes memory) {
        if (address(this).balance < value) {
            revert LowLevelCallsHelper__InsufficientBalance();
        }

        (bool success, bytes memory returnData) = target.call{
            value: value
        }(data);

        return _verifyResult(target, success, returnData);
    }

    /// @notice Executes a low level .delegatecall() and validates that
    ///         execution was safely performed.
    /// @dev Bubbles up errors and reverts if anything along the execution
    ///      path failed or was a red flag.
    /// @param target The target contract address to execute .delegatecall()
    ///               at.
    /// @param data The bytecode data to attach to the .call() execution
    ///             including the function signature hash and function call
    ///             parameters.
    function _delegateCall(
        address target,
        bytes memory data
    ) internal returns (bytes memory) {
        (bool success, bytes memory returnData) = target.delegatecall(data);

        return _verifyResult(target, success, returnData);
    }

    /// @dev Validates whether the low level call or delegate call was
    ///      successful and reverts in cases of bubbled up revert messages
    ///      or if `target` was not actually a contract.
    function _verifyResult(
        address target,
        bool success,
        bytes memory returnData
    ) internal view returns (bytes memory) {
        _propagateError(success, returnData);

        // If the call was successful but there was no return data we need
        // to make sure a contract was actually called as expected.
        if (returnData.length == 0 && target.code.length == 0) {
            revert LowLevelCallsHelper__CallFailed();
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
                revert LowLevelCallsHelper__CallFailed();
            }

            // Bubble up error if there was one given.
            assembly {
                revert(add(32, resultData), mload(resultData))
            }
        }
    }
}
