// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { IOdosRouterV2 } from "contracts/interfaces/external/odos/IOdosRouterV2.sol";
import { BaseCalldataChecker, SwapperLib } from "./BaseCalldataChecker.sol";

/// @notice WARNING: Currently built for Router V2.
contract OdosCalldataChecker is BaseCalldataChecker {
    /// CONSTANTS ///
    uint256 private constant _ONE_FOR_ZERO_MASK = 1 << 255;
    uint256 private constant _REVERSE_MASK =
        0x8000000000000000000000000000000000000000000000000000000000000000;

    /// @dev Address list where addresses can be cached for use when reading from storage is cheaper
    // than reading from calldata. addressListStart is the storage slot of the first dynamic array element
    uint256 private constant addressListStart = 
        80084422859880547211683076133703299733277748156566366325829078699459944778998;
    address[] public addressList;

    /// CONSTRUCTOR ///

    constructor(address _target, address[] memory addresses) BaseCalldataChecker(_target) {
        for (uint256 i = 0; i < addresses.length; i++) {
           addressList.push(addresses[i]);
        }
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Inspects calldata for compliance with other swap instruction
    ///         parameters.
    /// @dev Used on Zap/swap to inspect and validate calldata safety.
    /// @param swapData Zap/swap instruction data including both direct
    ///                 parameters and decodeable calldata.
    /// @param expectedRecipient User who will receive results of Zap/swap.
    function checkCalldata(
        SwapperLib.Swap memory swapData,
        address expectedRecipient
    ) external view override {
        if (swapData.target != target) {
            revert CalldataChecker__TargetError();
        }

        bytes4 funcSigHash = getFuncSigHash(swapData.call);
        address recipient;
        address inputToken;
        uint256 inputAmount;
        address outputToken;
        if (funcSigHash == IOdosRouterV2.swapCompact.selector) {
            IOdosRouterV2.swapTokenInfo memory tokenInfo;
            address executor;

            assembly {
                function getAddress(currPos) -> result, newPos {
                    let inputPos := shr(240, calldataload(currPos))

                    switch inputPos
                    case 0x0000 {
                        newPos := add(currPos, 2)
                    }

                    case 0x0001 {
                        result := and(shr(80, calldataload(currPos)), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
                        newPos := add(currPos, 22)
                    }

                    default {
                        result := sload(add(addressListStart, sub(inputPos, 2)))
                        newPos := add(currPos, 2)
                    }
                }
                let result := 0
                let pos := 296

                result, pos := getAddress(pos)
                mstore(tokenInfo, result)

                result, pos := getAddress(pos)
                mstore(add(tokenInfo, 0x60), result)

                let inputAmountLength := shr(248, calldataload(pos))
                pos := add(pos, 1)

                if inputAmountLength {
                    mstore(add(tokenInfo, 0x20), shr(mul(sub(32, inputAmountLength), 8), calldataload(pos)))
                    pos := add(pos, inputAmountLength)
                }

                let quoteAmountLength := shr(248, calldataload(pos))
                pos := add(pos, 1)

                let outputQuote := shr(mul(sub(32, quoteAmountLength), 8), calldataload(pos))
                mstore(add(tokenInfo, 0x80), outputQuote)
                pos := add(pos, quoteAmountLength)

                {
                    let slippageTolerance := shr(232, calldataload(pos))
                    mstore(add(tokenInfo, 0xA0), div(mul(outputQuote, sub(0xFFFFFF, slippageTolerance)), 0xFFFFFF))
                }
                pos := add(pos, 3)

                executor, pos := getAddress(pos)

                result, pos := getAddress(pos)
                if eq(result, 0) { result := executor }
                mstore(add(tokenInfo, 0x40), result)

                result, pos := getAddress(pos)
                if eq(result, 0) { revert(0, 0) }
                mstore(add(tokenInfo, 0xC0), result)
            }

            recipient = tokenInfo.outputReceiver;
            inputToken = tokenInfo.inputToken;
            inputAmount = tokenInfo.inputAmount;
            outputToken = tokenInfo.outputToken;
        } else if (funcSigHash == IOdosRouterV2.swap.selector) {
            (IOdosRouterV2.swapTokenInfo memory tokenInfo, , ,) = abi
                .decode(
                    getFuncParams(swapData.call),
                    (
                        IOdosRouterV2.swapTokenInfo,
                        bytes,
                        address,
                        uint32
                    )
                );
            recipient = tokenInfo.outputReceiver;
            inputToken = tokenInfo.inputToken;
            inputAmount = tokenInfo.inputAmount;
            outputToken = tokenInfo.outputToken;
        } else if (
            funcSigHash ==
            IOdosRouterV2.swapPermit2.selector
        ) {
            (
                ,
                IOdosRouterV2.swapTokenInfo memory tokenInfo, , ,
            ) = abi.decode(
                    getFuncParams(swapData.call),
                    (
                        IOdosRouterV2.permit2Info,
                        IOdosRouterV2.swapTokenInfo,
                        bytes,
                        address,
                        uint32
                    )
                );

            recipient = tokenInfo.outputReceiver;
            inputToken = tokenInfo.inputToken;
            inputAmount = tokenInfo.inputAmount;
            outputToken = tokenInfo.outputToken;
        } else {
            revert CalldataChecker__InvalidFuncSig();
        }

        if (recipient != expectedRecipient) {
            revert CalldataChecker__RecipientError();
        }

        if (inputToken != swapData.inputToken) {
            revert CalldataChecker__InputTokenError();
        }

        if (inputAmount != swapData.inputAmount) {
            revert CalldataChecker__InputAmountError();
        }

        if (outputToken != swapData.outputToken) {
            revert CalldataChecker__OutputTokenError();
        }
    }
}
