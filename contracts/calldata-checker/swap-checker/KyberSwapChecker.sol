// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BaseSwapChecker } from "contracts/calldata-checker/swap-checker/BaseSwapChecker.sol";

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

import { IMetaAggregationRouterV2 } from "contracts/interfaces/external/kyberswap/IMetaAggregationRouterV2.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @notice Inspects the calldata for a KyberSwap related swap action.
/// @dev NOTE: Currently built for MetaAggregationRouterV2.
contract KyberSwapChecker is BaseSwapChecker {
    /// CONSTANTS ///

    /// @notice The central registry contract.
    ICentralRegistry public immutable centralRegistry;
    
    /// STORAGE ///

    /// @notice Allowlist of Kyber executor addresses that may be used as `execution.callTarget`.
    /// @dev If an executor is not approved, `checkCalldata` will revert with `CalldataChecker__TargetError`.
    mapping(address => bool) public isApprovedExecutor;

    /// ERRORS ///

    error KyberSwapChecker__InvalidNativeTokenAddress();
    error KyberSwapChecker__InvalidFlags();
    error KyberSwapChecker__InvalidTargetData();
    error KyberSwapChecker__InvalidFeeReceivers();
    error KyberSwapChecker__InvalidPermit();
    error KyberSwapChecker__UnsupportedChain();
    error KyberSwapChecker__Unauthorized();

    /// CONSTRUCTOR ///

    /// @param _target The address of the KyberSwap contract.
    /// @param _KYBER_SWAP_EXECUTOR The address of the KyberSwap Executor on this chain.
    /// @param _centralRegistry The address of the Central Registry contract.
    constructor(
        address _target,
        address _KYBER_SWAP_EXECUTOR,
        address _centralRegistry
    ) BaseSwapChecker(_target) {
        centralRegistry = ICentralRegistry(_centralRegistry);

        if (block.chainid != 143) {
            revert KyberSwapChecker__UnsupportedChain();
        }

        isApprovedExecutor[_KYBER_SWAP_EXECUTOR] = true;
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
            // Kyberswap's MetaAggregationRouterV2 treats `dstReceiver == address(0)`
            // as a shortcut for sending output to `msg.sender`.
            recipient = execution.desc.dstReceiver == address(0)
                ? msg.sender
                : execution.desc.dstReceiver;
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

        if (!isApprovedExecutor[executor]) {
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

    /// @notice Sets whether an executor is allowed to be used by Kyber swaps.
    /// @dev Only callable by an address with DAO permissions in `centralRegistry`.
    ///      This controls the allowlist check against `execution.callTarget` in
    ///      `checkCalldata`.
    /// @param executor The Kyber executor address to update.
    /// @param approved Whether `executor` should be allowlisted.
    function setExecutorApproval(address executor, bool approved) external {
        _hasDaoPermissions();

        isApprovedExecutor[executor] = approved;
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Reverts unless the caller has DAO permissions in `centralRegistry`.
    /// @dev Used to restrict administrative functions (e.g. executor allowlist
    ///      updates) to DAO-authorized callers.
    ///      Reverts with `KyberSwapChecker__Unauthorized` if `msg.sender` is not DAO-authorized.
    function _hasDaoPermissions() internal view {
        if (!centralRegistry.hasDaoPermissions(msg.sender)) {
            revert KyberSwapChecker__Unauthorized();
        }
    }
}
