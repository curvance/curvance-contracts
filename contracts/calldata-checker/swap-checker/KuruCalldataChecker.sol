// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BaseSwapChecker } from "contracts/calldata-checker/swap-checker/BaseSwapChecker.sol";

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

import { IKuruFlowRouter } from "contracts/interfaces/external/kuru/IKuruRouter.sol";

/// @notice Inspects the calldata for an Kuru related swap action.
contract KuruCalldataChecker is BaseSwapChecker {
    address public immutable collector;
    address public immutable dao;
    
    /// CONSTANTS ///

    /// @notice Native token placeholder address that Kuru does not recognize.
    address constant INVALID_NATIVE_PLACEHOLDER =
        0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// ERRORS ///

    error KuruCalldataChecker__InvalidNativeTokenAddress();

    /// CONSTRUCTOR ///

    /// @param _target The address of the Kuru Router contract.
    constructor(address _target, address _collector, address _dao) BaseSwapChecker(_target) {
        collector = _collector;
        dao = _dao;
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
        address feeCollectorAddress;
        address referrerAddress;
        if (funcSigHash == IKuruFlowRouter.executeSwap.selector) {
            (
                IKuruFlowRouter.SwapIntent memory swapIntent,
                IKuruFlowRouter.FeeCollection memory feeCollection,
            ) = abi.decode(
                _getFuncParams(swapAction.call),
                (
                    IKuruFlowRouter.SwapIntent,
                    IKuruFlowRouter.FeeCollection,
                    bytes
                )
            );


            recipient = msg.sender;
            inputToken = swapIntent.tokenUserSells;
            inputAmount = swapIntent.amountUserSells;
            outputToken = swapIntent.tokenUserBuys;
            feeCollectorAddress = feeCollection.feeCollectorAddress;
            referrerAddress = feeCollection.referrerAddress;
            minOutAmount = swapIntent.minAmountUserBuys;
        } else {
            revert CalldataChecker__InvalidFuncSig();
        }
        
        if (recipient != expectedRecipient) {
            revert CalldataChecker__RecipientError();
        }

        if (inputToken != swapAction.inputToken) {
            revert CalldataChecker__InputTokenError();
        }

        // Kuru only recognizes address(0) as native.
        if (inputToken == INVALID_NATIVE_PLACEHOLDER) {
            revert KuruCalldataChecker__InvalidNativeTokenAddress();
        }

        if (inputAmount != swapAction.inputAmount) {
            revert CalldataChecker__InputAmountError();
        }

        if (outputToken != swapAction.outputToken) {
            revert CalldataChecker__OutputTokenError();
        }

        // Kuru only recognizes address(0) as native.
        if (outputToken == INVALID_NATIVE_PLACEHOLDER) {
            revert KuruCalldataChecker__InvalidNativeTokenAddress();
        }

        if (feeCollectorAddress != collector) {
            revert CalldataChecker__ReferralError();
        }

        if (referrerAddress != dao) {
            revert CalldataChecker__ReferralError();
        }
    }
}
