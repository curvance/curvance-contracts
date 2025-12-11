// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BaseSwapChecker } from "contracts/calldata-checker/swap-checker/BaseSwapChecker.sol";

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

import { IOdosRouterV2 } from "contracts/interfaces/external/odos/IOdosRouterV2.sol";

/// @notice Inspects the calldata for an Odos related swap action.
/// @dev NOTE: Currently built for Router V2.
contract OdosV2CalldataChecker is BaseSwapChecker {
    /// CONSTANTS ///

    /// @notice Native token placeholder address that Odos does not recognize.
    address immutable public INVALID_NATIVE_PLACEHOLDER;

    /// @notice The address of the Odos Executor on this chain.
    address immutable public ODOS_EXECUTOR;

    /// ERRORS ///

    error OdosCalldataChecker__InvalidNativeTokenAddress();

    /// CONSTRUCTOR ///

    /// @param _target The address of the Odos Router V2 contract.
    constructor(
        address _target,
        address _odosExecutor,
        address _invalidNativePlaceholder
    ) BaseSwapChecker(_target) {
        ODOS_EXECUTOR = _odosExecutor;
        INVALID_NATIVE_PLACEHOLDER = _invalidNativePlaceholder;
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
    ) external view override returns (uint256 minOutAmount) {
        if (swapAction.target != target) {
            revert CalldataChecker__TargetError();
        }

        bytes4 funcSigHash = _getFuncSigHash(swapAction.call);
        address recipient;
        address inputToken;
        uint256 inputAmount;
        address outputToken;
        address executor;
        bytes memory path;
        uint32 referralCode;
        if (funcSigHash == IOdosRouterV2.swap.selector) {
            (
                IOdosRouterV2.swapTokenInfo memory tokenInfo,
                bytes memory pathDefinition, 
                address exec,
                uint32 refCode
            ) = abi.decode(
                    _getFuncParams(swapAction.call),
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
            executor = exec;
            path = pathDefinition;
            referralCode = refCode;
            minOutAmount = tokenInfo.outputMin;
        } else {
            revert CalldataChecker__InvalidFuncSig();
        }

        if (recipient != expectedRecipient) {
            revert CalldataChecker__RecipientError();
        }

        if (inputToken != swapAction.inputToken) {
            revert CalldataChecker__InputTokenError();
        }

        // Odos only recognizes address(0) as native.
        if (inputToken == INVALID_NATIVE_PLACEHOLDER) {
            revert OdosCalldataChecker__InvalidNativeTokenAddress();
        }

        if (inputAmount != swapAction.inputAmount) {
            revert CalldataChecker__InputAmountError();
        }

        if (outputToken != swapAction.outputToken) {
            revert CalldataChecker__OutputTokenError();
        }

        // Odos only recognizes address(0) as native.
        if (outputToken == INVALID_NATIVE_PLACEHOLDER) {
            revert OdosCalldataChecker__InvalidNativeTokenAddress();
        }

        if (executor != ODOS_EXECUTOR) {
            revert CalldataChecker__TargetError();
        }

        if (path.length == 0) {
            revert CalldataChecker__InvalidFuncSig();
        }

        if (referralCode != 0) {
            revert CalldataChecker__ReferralError();
        }
    }
}
