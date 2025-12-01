// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BaseSwapChecker } from "contracts/calldata-checker/swap-checker/BaseSwapChecker.sol";

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

import { IMetaAggregationRouterV2 } from "contracts/interfaces/external/kyberswap/IMetaAggregationRouterV2.sol";

/// @notice Inspects the calldata for a KyberSwap related swap action.
/// @dev NOTE: Currently built for MetaAggregationRouterV2.
contract KyberSwapChecker is BaseSwapChecker {
    /// CONSTANTS ///

    /// @notice The address of the KyberSwap Executor on this chain.
    address immutable public KYBER_SWAP_EXECUTOR;

    /// ERRORS ///

    error KyberSwapChecker__InvalidNativeTokenAddress();

    /// CONSTRUCTOR ///

    /// @param _target The address of the KyberSwap contract.
    constructor(
        address _target,
        address _KYBER_SWAP_EXECUTOR
    ) BaseSwapChecker(_target) {
        KYBER_SWAP_EXECUTOR = _KYBER_SWAP_EXECUTOR;
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
        uint256 numFeeReceivers;
        uint256 numSrcReceivers;
        uint256 flags;
        bytes memory permit;
        if (funcSigHash == IMetaAggregationRouterV2.swap.selector) {
            IMetaAggregationRouterV2.SwapExecutionParams memory execution =
                abi.decode(
                    _getFuncParams(swapAction.call),
                    (IMetaAggregationRouterV2.SwapExecutionParams)
                );
            recipient = execution.desc.dstReceiver;
            inputToken = address(execution.desc.srcToken);
            inputAmount = execution.desc.amount;
            outputToken = address(execution.desc.dstToken);
            executor = execution.callTarget;
            path = execution.targetData;
            numFeeReceivers = execution.desc.feeReceivers.length;
            numSrcReceivers = execution.desc.srcReceivers.length;
            flags = execution.desc.flags;
            permit = execution.desc.permit;
        } else {
            revert CalldataChecker__InvalidFuncSig();
        }

        if (recipient != expectedRecipient) {
            revert CalldataChecker__RecipientError();
        }

        if (inputToken != swapAction.inputToken) {
            revert CalldataChecker__InputTokenError();
        }

        // Kyberswap only recognizes address(Eeee) as native.
        if (inputToken == address(0)) {
            revert KyberSwapChecker__InvalidNativeTokenAddress();
        }

        if (inputAmount != swapAction.inputAmount) {
            revert CalldataChecker__InputAmountError();
        }

        if (outputToken != swapAction.outputToken) {
            revert CalldataChecker__OutputTokenError();
        }

        // Kyberswap only recognizes address(Eeee) as native.
        if (outputToken == address(0)) {
            revert KyberSwapChecker__InvalidNativeTokenAddress();
        }

        if (executor != KYBER_SWAP_EXECUTOR) {
            revert CalldataChecker__TargetError();
        }

        if (path.length == 0) {
            revert CalldataChecker__InvalidFuncSig();
        }

        // Curvance enforces a single source of input tokens and single recipient.
        if (numSrcReceivers != 0) {
            revert CalldataChecker__ReferralError();
        }

        if (numFeeReceivers != 0) {
            revert CalldataChecker__ReferralError();
        }

        // Extract flags from the bitmap.
        // _REQUIRES_EXTRA_ETH
        bool requiresExtraEth = (flags & 0x02) != 0;
        // _SHOULD_CLAIM
        bool shouldClaim = (flags & 0x04) != 0;
        // Reject swaps that require extra ETH or use claim-based token collection.
        if (requiresExtraEth || shouldClaim) {
            revert CalldataChecker__InvalidFuncSig();
        }

        // Prevent permit-based approvals.
        if (permit.length != 0) {
            revert CalldataChecker__InvalidFuncSig();
        }
    }
}
