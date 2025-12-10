// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BaseSwapChecker } from "contracts/calldata-checker/swap-checker/BaseSwapChecker.sol";

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

import { IOdosRouterV3 } from "contracts/interfaces/external/odos/IOdosRouterV3.sol";

/// @notice Inspects the calldata for an Odos related swap action.
/// @dev NOTE: Currently built for Router V3.
contract OdosV3CalldataChecker is BaseSwapChecker {
    /// CONSTANTS ///

    /// @notice Native token placeholder address that Odos does not recognize.
    address immutable public INVALID_NATIVE_PLACEHOLDER;

    /// @notice The address of the Odos Executor on this chain.
    address immutable public ODOS_EXECUTOR;

    /// ERRORS ///

    error OdosCalldataChecker__InvalidNativeTokenAddress();

    /// CONSTRUCTOR ///

    /// @param _target The address of the Odos Router V3 contract.
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
        IOdosRouterV3.swapReferralInfo memory referralInfo;
        if (funcSigHash == IOdosRouterV3.swap.selector) {
            (
                IOdosRouterV3.swapTokenInfo memory tokenInfo,
                bytes memory pathDefinition, 
                address exec, 
                IOdosRouterV3.swapReferralInfo memory ref
            ) = abi.decode(
                    _getFuncParams(swapAction.call),
                    (
                        IOdosRouterV3.swapTokenInfo, 
                        bytes, 
                        address, 
                        IOdosRouterV3.swapReferralInfo
                    )
                );
            recipient = tokenInfo.outputReceiver;
            inputToken = tokenInfo.inputToken;
            inputAmount = tokenInfo.inputAmount;
            outputToken = tokenInfo.outputToken;
            executor = exec;
            path = pathDefinition;
            referralInfo = ref;
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

        if (referralInfo.code != 0) {
            revert CalldataChecker__ReferralError();
        }
    }
}
