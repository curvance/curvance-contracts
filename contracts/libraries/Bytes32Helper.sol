// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IERC20 } from "contracts/interfaces/IERC20.sol";

/// @title Bytes32 Helper
/// @notice A utility library for converting between strings and bytes32 values
/// @dev Provides functions to convert strings to bytes32 and to create standardized 
///      bytes32 representations of token symbols with optional suffixes
library Bytes32Helper {
    /// ERRORS ///

    error Bytes32Helper__ZeroLengthString();

    /// PUBLIC FUNCTIONS ///

    /// @notice Converts `data`, a string memory value, to bytes32 form.
    /// @dev This will trim the output value to 32 bytes,
    ///      even if the bytes value is > 32 bytes.
    /// @return r The bytes32 converted form of `data`.
    function toBytes32(string memory data) public pure returns (bytes32 r) {
        if (bytes(data).length == 0) {
            revert Bytes32Helper__ZeroLengthString();
        }

        /// @solidity memory-safe-assembly
        assembly {
            r := mload(add(data, 32))
        }
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Converts `token` to bytes32 based on its ERC20 symbol.
    /// @param token Address of desired token to pull ERC20 symbol from.
    /// @return r The bytes 32 output of `token`'s ERC20 symbol.
    function _toBytes32(address token) internal view returns (bytes32 r) {
        r = toBytes32(string.concat(_symbol(token)));
    }

    /// @notice Converts `token` to bytes32 based on its ERC20 symbol,
    ///         and "/`tokenSymbol`" appended.
    /// @param token Address of desired token to pull append symbol to.
    /// @param tokenSymbol Symbol to append with `token`'s symbol.
    /// @return result The bytes32 result of `token`'s symbol with
    ///                "/`tokenSymbol`".
    function _toBytes32Symbol(
        address token,
        string memory tokenSymbol
    ) internal view returns (bytes32 result) {
        result = toBytes32(
            string.concat(string.concat(_symbol(token), "/"), tokenSymbol)
        );
    }

    /// @notice Converts `token` to bytes32 based on its ERC20 symbol,
    ///         and "/USD" appended.
    /// @param token Address of desired token to pull ERC20 symbol from.
    /// @return r The bytes32 result of `token`'s symbol with "/USD" appended.
    function _toBytes32USD(address token) internal view returns (bytes32 r) {
        r = toBytes32(string.concat(_symbol(token), "/USD"));
    }

    /// @notice Returns `token`'s ERC20 symbol as a string.
    /// @param token Address of desired token to pull ERC20 symbol from.
    /// @return r The erc20 symbol of `token` in string form.
    function _symbol(address token) internal view returns (string memory r) {
        r = IERC20(token).symbol();
    }
}
