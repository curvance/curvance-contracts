// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { IMulticallChecker } from "contracts/interfaces/IMulticallChecker.sol";

abstract contract BaseMulticallChecker is IMulticallChecker {
    /// ERRORS ///
    error MulticallChecker__TargetError();
    error MulticallChecker__InvalidFuncSig();
    error MulticallChecker__InvalidCalldata();

    /// STORAGE ///
    address public centralRegistry;

    /// CONSTRUCTOR ///

    constructor(address _centralRegistry) {
        centralRegistry = _centralRegistry;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Checks attached calldata to validate that the target contract
    ///         is an approved oracle adaptor and the proper function selector
    ///         is being called.
    /// @dev MUST be overridden in every calldata checkers contract's
    ///      implementation.
    function checkCalldata(
        address caller,
        address target,
        bytes memory data
    ) external virtual override;

    /// INTERNAL FUNCTIONS ///

    /// @notice Queries the function signature of `sigData`, this is used
    ///         to check against an expected selector.
    /// @param sigData The bytes array to pull a function signature from.
    function getFuncSigHash(
        bytes memory sigData
    ) internal pure returns (bytes4 sig) {
        assembly {
            sig := mload(add(sigData, add(32, 0)))
        }
    }

    /// @notice Returns the expected parameters for a function call with
    ///         the bytes array.
    /// @param paramsData The bytes array to pull a function parameters from.
    function getFuncParams(
        bytes memory paramsData
    ) internal pure returns (bytes memory) {
        return slice(paramsData, 4, paramsData.length - 4);
    }


    /// @notice Modifies `_bytes` into desired form based on
    ///         `_start` starting point,and `_length` length.
    function slice(
        bytes memory _bytes,
        uint256 _start,
        uint256 _length
    ) internal pure returns (bytes memory) {
        require(_length + 31 >= _length, "slice_overflow");
        require(_start + _length >= _start, "slice_overflow");
        require(_bytes.length >= _start + _length, "slice_outOfBounds");

        bytes memory tempBytes;

        assembly {
            switch iszero(_length)
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
                let lengthmod := and(_length, 31)

                // The multiplication in the next line is necessary
                // because when slicing multiples of 32 bytes (lengthmod == 0)
                // the following copy loop was copying the origin's length
                // and then ending prematurely not copying everything it should.
                let mc := add(
                    add(tempBytes, lengthmod),
                    mul(0x20, iszero(lengthmod))
                )
                let end := add(mc, _length)

                for {
                    // The multiplication in the next line has the same exact purpose
                    // as the one above.
                    let cc := add(
                        add(
                            add(_bytes, lengthmod),
                            mul(0x20, iszero(lengthmod))
                        ),
                        _start
                    )
                } lt(mc, end) {
                    mc := add(mc, 0x20)
                    cc := add(cc, 0x20)
                } {
                    mstore(mc, mload(cc))
                }

                mstore(tempBytes, _length)

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