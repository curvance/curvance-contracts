// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "contracts/interfaces/IERC20.sol";

/// @title Bytes32 Helper
/// @notice A utility library for converting between strings and bytes32 values
/// @dev Provides functions to convert strings to bytes32 and to create standardized 
///      bytes32 representations of token symbols with optional suffixes
library Bytes32Helper {
    /// ERRORS ///

    error Bytes32Helper__ZeroLengthString();

    /// PUBLIC FUNCTIONS ///

    /// @notice Converts `stringData`, a string memory value, to bytes32 form.
    /// @dev This will trim the output value to 32 bytes,
    ///      even if the bytes value is > 32 bytes.
    /// @return result The bytes32 converted form of `stringData`.
    function stringToBytes32(
        string memory stringData
    ) public pure returns (bytes32 result) {
        bytes memory bytesData = bytes(stringData);
        if (bytesData.length == 0) {
            revert Bytes32Helper__ZeroLengthString();
        }

        /// @solidity memory-safe-assembly
        assembly {
            result := mload(add(stringData, 32))
        }
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Converts `tokenAddress` to bytes32 based on its ERC20 symbol.
    /// @param tokenAddress Address of desired token to pull ERC20 symbol
    ///                     from.
    function _toBytes32(
        address tokenAddress
    ) internal view returns (bytes32 result) {
        result = stringToBytes32(string.concat(_getSymbol(tokenAddress)));
    }

    /// @notice Converts `tokenAddress` to bytes32 based on its ERC20 symbol,
    ///         and "/`tokenSymbol`" appended.
    /// @param tokenAddress Address of desired token to pull append symbol to.
    /// @param tokenSymbol Symbol to append with `tokenAddress`'s symbol.
    /// @return result The bytes32 result of `tokenAddress`'s symbol with
    ///                "/`tokenSymbol`".
    function _toBytes32WithSymbol(
        address tokenAddress,
        string memory tokenSymbol
    ) internal view returns (bytes32 result) {
        result = stringToBytes32(string.concat(
            string.concat(_getSymbol(tokenAddress), "/"),
            tokenSymbol
        ));
    }

    /// @notice Converts `tokenAddress` to bytes32 based on its ERC20 symbol,
    ///         and "/USD" appended.
    /// @param tokenAddress Address of desired token to pull ERC20 symbol
    ///                     from.
    /// @return result The bytes32 result of `tokenAddress`'s symbol with
    ///                /USD appended.
    function _toBytes32WithUSD(
        address tokenAddress
    ) internal view returns (bytes32 result) {
        result = stringToBytes32(string.concat(
            _getSymbol(tokenAddress),
            "/USD"
        ));
    }

    /// @notice Returns `tokenAddress`'s ERC20 symbol as a string.
    /// @param tokenAddress Address of desired token to pull ERC20 symbol
    ///                     from.
    /// @return result The erc20 symbol of `tokenAddress` in string form.
    function _getSymbol(
        address tokenAddress
    ) internal view returns (string memory result) {
        result = IERC20(tokenAddress).symbol();
    }
}
