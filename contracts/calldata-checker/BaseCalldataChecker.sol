// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title BaseCalldataChecker
/// @notice A base contract that provides utility functions for parsing and examining calldata
/// @dev This abstract contract serves as the foundation for all calldata verification contracts
///    in the Curvance protocol. It provides essential low-level utilities to:
///     1. Extract function signatures from calldata
///     2. Extract function parameters from calldata
///     3. Safely slice bytes arrays
///
///    These utilities are used by child contracts in the calldata-checker directory:
///      - swap-checker/: Contains BaseSwapChecker and specific DEX implementation checkers
///                      (OneInch, OogaBooga, Odos, etc.) that verify swap calls are safe
///      - multicall-checker/: Contains BaseMulticallChecker and specific oracle adaptor
///                           checkers that verify oracle calls are from approved sources
///
///    The primary purpose of these checkers is to provide security when interacting with
///    external protocols by validating calldata before execution. This protects against:
///      - Sending tokens to unauthorized recipients
///      - Using incorrect tokens or amounts in swaps
///      - Calling unauthorized functions or contracts
///      - Malicious oracle price manipulation
///
///    The system consults the Central Registry to find the correct calldata checker
///    for the target contract and function signature.
///
abstract contract BaseCalldataChecker {
    /// CONSTANTS ///

    uint256 internal constant _SLICE_OVERFLOW_LIMIT = type(uint256).max - 31;

    /// ERRORS /// 

    error BaseCalldataChecker__InvalidSig();
    error BaseCalldataChecker__OutOfBounds();
    error BaseCalldataChecker__OverflowError();

    /// INTERNAL FUNCTIONS ///

    /// @notice Queries the function signature of `sigData`, this is used
    ///         to check against an expected selector.
    /// @dev Byte array must be at least 4 bytes long.
    /// @param sigData The bytes array to pull a function signature from.
    function _getFuncSigHash(
        bytes memory sigData
    ) internal pure returns (bytes4 sig) {
        if (sigData.length < 4) {
            revert BaseCalldataChecker__InvalidSig();
        }

        assembly {
            sig := mload(add(sigData, 32))
        }
    }

    /// @notice Returns the expected parameters for a function call with
    ///         the bytes array.
    /// @param paramsData The bytes array to pull a function parameters from.
    function _getFuncParams(
        bytes memory paramsData
    ) internal pure returns (bytes memory) {
        return _slice(paramsData, 4, paramsData.length - 4);
    }

    /// @notice Modifies `byteArrayToSlice` into desired form based on
    ///         `sliceStartPoint` starting point, and `sliceLength` length.
    /// @param byteArrayToSlice The bytes array to slice.
    /// @param sliceStartPoint The starting point of the slice.
    /// @param sliceLength The length of the slice.
    /// @return The sliced bytes array.
    function _slice(
        bytes memory byteArrayToSlice,
        uint256 sliceStartPoint,
        uint256 sliceLength
    ) internal pure returns (bytes memory) {
        if (sliceLength > _SLICE_OVERFLOW_LIMIT) {
            revert BaseCalldataChecker__OverflowError();
        }

        if (sliceStartPoint > type(uint256).max - sliceLength) {
            revert BaseCalldataChecker__OverflowError();
        }

        if (byteArrayToSlice.length < sliceStartPoint + sliceLength) {
            revert BaseCalldataChecker__OutOfBounds();
        }

        bytes memory tempBytes;

        assembly {
            switch iszero(sliceLength)
            case 0 {
                // Get a location of some free memory and store it in tempBytes as
                // Solidity does for memory variables.
                tempBytes := mload(0x40)

                // The first word of the slice result is potentially a partial
                // word read from the original array. To read it, we calculate
                // the length of that partial word and start copying that many
                // bytes into the array. The first word we copy will start with
                // data we don't care about, but the last `lengthmod` bytes will
                // land at the beginning of the contents of the new array. When
                // we're done copying, we overwrite the full first word with
                // the actual length of the slice.
                let lengthmod := and(sliceLength, 31)

                // The multiplication in the next line is necessary
                // because when slicing multiples of 32 bytes (lengthmod == 0)
                // the following copy loop was copying the origin's length
                // and then ending prematurely not copying everything it should.
                let mc := add(
                    add(tempBytes, lengthmod),
                    mul(0x20, iszero(lengthmod))
                )
                let end := add(mc, sliceLength)

                for {
                    // The multiplication in the next line has the same exact purpose
                    // as the one above.
                    let cc := add(
                        add(
                            add(byteArrayToSlice, lengthmod),
                            mul(0x20, iszero(lengthmod))
                        ),
                        sliceStartPoint
                    )
                } lt(mc, end) {
                    mc := add(mc, 0x20)
                    cc := add(cc, 0x20)
                } {
                    mstore(mc, mload(cc))
                }

                mstore(tempBytes, sliceLength)

                //update free-memory pointer
                //allocating the array padded to 32 bytes like the compiler does now
                mstore(0x40, and(add(mc, 31), not(31)))
            }
            //if we want a zero-length slice let's just return a zero-length array
            default {
                tempBytes := mload(0x40)
                //zero out the 32 bytes slice we are about to return
                //we need to do it because Solidity does not garbage collect
                mstore(tempBytes, 0)

                mstore(0x40, add(tempBytes, 0x20))
            }
        }

        return tempBytes;
    }
}
