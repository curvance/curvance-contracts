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
    error KyberSwapChecker__InvalidFlags();
    error KyberSwapChecker__InvalidTargetData();
    error KyberSwapChecker__InvalidFeeReceivers();
    error KyberSwapChecker__InvalidPermit();
    error KyberSwapChecker__UnsupportedChain();

    /// CONSTRUCTOR ///

    /// @param _target The address of the KyberSwap contract.
    constructor(
        address _target,
        address _KYBER_SWAP_EXECUTOR
    ) BaseSwapChecker(_target) {
        if (block.chainid != 143) {
            revert KyberSwapChecker__UnsupportedChain();
        }

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
        bytes memory targetData;
        uint256 numFeeReceivers;
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
            targetData = execution.targetData;
            numFeeReceivers = execution.desc.feeReceivers.length;
            flags = execution.desc.flags;
            permit = execution.desc.permit;
            minOutAmount = execution.desc.minReturnAmount;
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

        if (targetData.length == 0) {
            revert KyberSwapChecker__InvalidTargetData();
        }

        if (numFeeReceivers != 0) {
            revert KyberSwapChecker__InvalidFeeReceivers();
        }

        // Extract _REQUIRES_EXTRA_ETH flag.
        bool requiresExtraEth = (flags & 0x02) != 0;
        if (requiresExtraEth) {
            revert KyberSwapChecker__InvalidFlags();
        }

        // Prevent permit-based approvals.
        if (permit.length != 0) {
            revert KyberSwapChecker__InvalidPermit();
        }
    }
}
