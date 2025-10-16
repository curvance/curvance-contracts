// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BaseSwapChecker } from "contracts/calldata-checker/swap-checker/BaseSwapChecker.sol";

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

import { IOdosRouterV3 } from "contracts/interfaces/external/odos/IOdosRouterV3.sol";

/// @notice Inspects the calldata for an Odos related swap action.
/// @dev NOTE: Currently built for Router V3.
contract OdosV3CalldataChecker is BaseSwapChecker {
    /// CONSTANTS ///

    /// @notice The address of the Odos Executor on this chain.
    address immutable public ODOS_EXECUTOR;

    /// CONSTRUCTOR ///

    /// @param _target The address of the Odos Router V3 contract.
    constructor(
        address _target,
        address _odosExecutor
    ) BaseSwapChecker(_target) {
        ODOS_EXECUTOR = _odosExecutor;
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
        address executor;
        bytes memory path;
        if (funcSigHash == IOdosRouterV3.swap.selector) {
            (
                IOdosRouterV3.swapTokenInfo memory tokenInfo,
                bytes memory pathDefinition, 
                address exec, 
                /*IOdosRouterV3.swapReferralInfo memory referralInfo*/
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

        // Additional validations to restrict execution routing fields.
        if (executor != ODOS_EXECUTOR) {
            revert CalldataChecker__TargetError();
        }

        if (path.length == 0) {
            revert CalldataChecker__InvalidFuncSig();
        }
    }
}
