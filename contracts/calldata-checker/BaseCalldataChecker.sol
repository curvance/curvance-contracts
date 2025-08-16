// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title BaseCalldataChecker
/// @notice A base contract that provides utility functions for parsing
///         and examining calldata.
/// @dev This contract serves as the foundation for all calldata verification
///      contracts in the Curvance protocol. It provides essential low-level
///      utilities to:
///      1. Extract function signatures from calldata
///      2. Extract function parameters from calldata
///      3. Safely slice bytes arrays
///
///      These utilities are used by child contracts in the calldata-checker
///      directory:
///      - swap-checker/: Contains BaseSwapChecker and specific DEX
///                       implementation checkers (1Inch, OogaBooga, Odos,
///                       etc.) that verify swap calls are safe
///      - multicall-checker/: Contains BaseMulticallChecker and specific
///                            oracle adaptor checkers that verify oracle
///                            calls are from approved sources.
///
///      The primary purpose of these checkers is to provide security when
///      interacting with external protocols by validating calldata before
///      execution. This protects against:
///      - Sending tokens to unauthorized recipients
///      - Using incorrect tokens or amounts in swaps
///      - Calling unauthorized functions or contracts
///      - Malicious oracle price manipulation
///
///    The system consults the Central Registry to find the correct calldata
///    checker for the target contract and function signature.
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
    /// @return result The function signature hash of `sigData`.
    function _getFuncSigHash(
        bytes memory sigData
    ) internal pure returns (bytes4 result) {
        if (sigData.length < 4) {
            revert BaseCalldataChecker__InvalidSig();
        }

        assembly {
            result := mload(add(sigData, 32))
        }
    }

    /// @notice Returns the expected parameters for a function call with
    ///         the bytes array.
    /// @param paramsData The bytes array to pull a function parameters from.
    /// @return result A bytes array containing parameters for a function
    ///                call with `paramsData`.
    function _getFuncParams(
        bytes memory paramsData
    ) internal pure returns (bytes memory result) {
        result = _slice(paramsData, 4, paramsData.length - 4);
    }

    /// @notice Modifies `sliceData` into the desired sliced form based on
    ///         `sliceStartPoint` starting point, and `sliceLength` length.
    /// @param sliceData The bytes array to slice.
    /// @param sliceStartPoint The starting point of the slice.
    /// @param sliceLength The length of the slice.
    /// @return result The sliced bytes array.
    function _slice(
        bytes memory sliceData,
        uint256 sliceStartPoint,
        uint256 sliceLength
    ) internal pure returns (bytes memory result) {
        if (sliceLength > _SLICE_OVERFLOW_LIMIT) {
            revert BaseCalldataChecker__OverflowError();
        }

        if (sliceStartPoint > type(uint256).max - sliceLength) {
            revert BaseCalldataChecker__OverflowError();
        }

        if (sliceData.length < sliceStartPoint + sliceLength) {
            revert BaseCalldataChecker__OutOfBounds();
        }

        assembly {
            switch iszero(sliceLength)
            case 0 {
                // Get a location of some free memory and store it in
                // `result`.
                result := mload(0x40)

                // The first word of the slice result is potentially a partial
                // word read from the original array. To read it, we calculate
                // the length of that partial word and start copying that many
                // bytes into the array. The first word we copy will start
                // with data we don't care about, but the last `lengthmod`
                // bytes will land at the beginning of the contents of the new
                // array. When we're done copying, we overwrite the full first
                // word with the actual length of the slice.
                let lengthmod := and(sliceLength, 31)

                // The multiplication in the next line is necessary
                // because when slicing multiples of 32 bytes (lengthmod == 0)
                // the following copy loop was copying the origin's length
                // and then ending prematurely not copying everything it
                // should.
                let mc := add(
                    add(result, lengthmod),
                    mul(0x20, iszero(lengthmod))
                )
                let end := add(mc, sliceLength)

                for {
                    // Same reason for multiplication as above.
                    let cc := add(
                        add(
                            add(sliceData, lengthmod),
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

                mstore(result, sliceLength)

                // Update free-memory pointer, allocate the array padded to
                // 32 bytes like the compiler does.
                mstore(0x40, and(add(mc, 31), not(31)))
            }

            // If we want a zero-length slice just return a zero-length array.
            default {
                result := mload(0x40)
                // Zero out the 32 bytes slice we are about to return.
                // We need to do it because Solidity does not garbage collect.
                mstore(result, 0)

                mstore(0x40, add(result, 0x20))
            }
        }
    }
}
