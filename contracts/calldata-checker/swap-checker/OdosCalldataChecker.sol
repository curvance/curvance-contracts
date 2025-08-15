// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { BaseSwapChecker } from "./BaseSwapChecker.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

import { IOdosRouterV2 } from "contracts/interfaces/external/odos/IOdosRouterV2.sol";

/// @notice WARNING: Currently built for Router V2.
contract OdosCalldataChecker is BaseSwapChecker {
    /// CONSTANTS ///
    
    /// @notice The mask for the one for zero flag
    uint256 private constant _ONE_FOR_ZERO_MASK = 1 << 255;
    /// @notice The mask for the reverse flag
    uint256 private constant _REVERSE_MASK =
        0x8000000000000000000000000000000000000000000000000000000000000000;

    /// @dev Address list where addresses can be cached for use when reading from storage is cheaper
    // than reading from calldata. addressListStart is the storage slot of the first dynamic array element
    uint256 private constant addressListStart =
        80084422859880547211683076133703299733277748156566366325829078699459944778998;

    /// STORAGE ///

    /// @notice List of cached addresses used for validating Odos swaps
    address[] public addressList;

    /// CONSTRUCTOR ///

    constructor(
        address _target,
        address[] memory addresses
    ) BaseSwapChecker(_target) {
        for (uint256 i; i < addresses.length; i++) {
            addressList.push(addresses[i]);
        }
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Inspects calldata for compliance with other swap instruction
    ///         parameters.
    /// @dev Used on swap to inspect and validate calldata safety.
    /// @param swapAction Swap action instructions including both direct
    ///                   parameters and decodeable calldata.
    /// @param expectedRecipient Address who will receive proceeds of
    ///                          `swapAction`.
    function checkCalldata(
        SwapperLib.Swap memory swapAction,
        address expectedRecipient
    ) external view override {
        if (swapAction.target != target) {
            revert CalldataChecker__TargetError();
        }

        bytes4 funcSigHash = _getFuncSigHash(swapAction.call);
        address recipient;
        address inputToken;
        uint256 inputAmount;
        address outputToken;
        if (funcSigHash == IOdosRouterV2.swap.selector) {
            (IOdosRouterV2.swapTokenInfo memory tokenInfo, , , ) = abi.decode(
                _getFuncParams(swapAction.call),
                (IOdosRouterV2.swapTokenInfo, bytes, address, uint32)
            );
            recipient = tokenInfo.outputReceiver;
            inputToken = tokenInfo.inputToken;
            inputAmount = tokenInfo.inputAmount;
            outputToken = tokenInfo.outputToken;
        } else if (funcSigHash == IOdosRouterV2.swapPermit2.selector) {
            (, IOdosRouterV2.swapTokenInfo memory tokenInfo, , , ) = abi
                .decode(
                    _getFuncParams(swapAction.call),
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

        if (inputToken != swapAction.inputToken) {
            revert CalldataChecker__InputTokenError();
        }

        if (inputAmount != swapAction.inputAmount) {
            revert CalldataChecker__InputAmountError();
        }

        if (outputToken != swapAction.outputToken) {
            revert CalldataChecker__OutputTokenError();
        }
    }
}
