// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BaseSwapChecker } from "contracts/calldata-checker/swap-checker/BaseSwapChecker.sol";

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

import { IMetaAggregationRouterV2 } from "contracts/interfaces/external/kyberswap/IMetaAggregationRouterV2.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @notice Inspects the calldata for a KyberSwap related swap action.
/// @dev NOTE: Currently built for MetaAggregationRouterV2.
///      Fee validation: allows exactly one fee receiver which MUST be
///      the DAO address from centralRegistry. Fee amount must be in BPS
///      mode (isInBps=true on the API) and == FEE_BPS. Swaps with
///      zero fee receivers are blocked.
contract KyberSwapChecker is BaseSwapChecker {
    /// CONSTANTS ///

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;

    /// @notice Exact fee BPS that the SDK is configured to charge.
    /// @dev    KyberSwap calldata with `isInBps=true` stores the BPS value
    ///         directly in `feeAmounts[0]` (e.g. 4 for 4 bps). We enforce
    ///         an exact match — any other value reverts. To change the fee,
    ///         redeploy this checker with an updated constant.
    uint256 public constant FEE_BPS = 4;

    /// STORAGE ///

    /// @notice Allowlist of Kyber executor addresses that may be used
    ///         as `execution.callTarget`.
    /// @dev If an executor is not approved, `checkCalldata` will revert
    ///      with `CalldataChecker__TargetError`.
    mapping(address => bool) public isApprovedExecutor;

    /// EVENTS ///

    event SwapExecutorUpdated(address executor, bool approved);

    /// ERRORS ///

    error KyberSwapChecker__InvalidNativeTokenAddress();
    error KyberSwapChecker__InvalidFlags();
    error KyberSwapChecker__InvalidTargetData();
    error KyberSwapChecker__InvalidFeeConfig();
    error KyberSwapChecker__InvalidPermit();
    error KyberSwapChecker__UnsupportedChain();
    error KyberSwapChecker__Unauthorized();

    /// CONSTRUCTOR ///

    /// @param target The address of the KyberSwap contract.
    /// @param kyberSwapExecutors The addresses of the KyberSwap Executors
    ///                           on this chain.
    /// @param centralRegistryInit The address of the Central Registry
    ///                            contract.
    constructor(
        address target,
        address[] memory kyberSwapExecutors,
        address centralRegistryInit
    ) BaseSwapChecker(target) {
        centralRegistry = ICentralRegistry(centralRegistryInit);

        if (block.chainid != 143) {
            revert KyberSwapChecker__UnsupportedChain();
        }

        uint256 numExecutors = kyberSwapExecutors.length;
        for (uint256 i; i < numExecutors; ++i) {
            isApprovedExecutor[kyberSwapExecutors[i]] = true;
            emit SwapExecutorUpdated(kyberSwapExecutors[i], true);
        }
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Inspects calldata for compliance with other swap instruction
    ///         parameters.
    /// @dev Used on swap to inspect and validate calldata safety.
    ///      NOTE: If you are a third party using this calldata checker for
    ///            your own implementation you MUST make sure the caller is
    ///            the swap recipient or the desc.dstReceiver adjustment will
    ///            be incorrect.
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
        address[] memory feeReceivers;
        uint256[] memory feeAmounts;
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
            feeReceivers = execution.desc.feeReceivers;
            feeAmounts = execution.desc.feeAmounts;
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

        // Validate fee configuration.
        // Allowed: zero fee receivers (no-fee path), or exactly one
        // receiver which must be the protocol DAO address with fee
        // amount == FEE_BPS.
        _validateFeeConfig(feeReceivers, feeAmounts);

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
        emit SwapExecutorUpdated(executor, approved);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Validates fee receiver and amount configuration.
    /// @dev    Zero fee receivers: always allowed (no-fee swap).
    ///         One fee receiver: must be centralRegistry.daoAddress(),
    ///         feeAmounts must have exactly one entry == FEE_BPS.
    ///         Multiple fee receivers: always rejected.
    ///
    ///         ENCODING: KyberSwap calldata built with isInBps=true stores
    ///         the BPS value directly in feeAmounts[0].
    function _validateFeeConfig(
        address[] memory feeReceivers,
        uint256[] memory feeAmounts
    ) internal view {
        uint256 numReceivers = feeReceivers.length;

        // No fee — always allowed.
        if (numReceivers == 0) return;

        // Multiple fee receivers — never allowed.
        if (numReceivers != 1) {
            revert KyberSwapChecker__InvalidFeeConfig();
        }

        // Exactly one receiver — must be the DAO.
        if (feeReceivers[0] != centralRegistry.daoAddress()) {
            revert KyberSwapChecker__InvalidFeeConfig();
        }

        // feeAmounts must match feeReceivers in length.
        if (feeAmounts.length != 1) {
            revert KyberSwapChecker__InvalidFeeConfig();
        }

        // Fee must be exactly the configured BPS value.
        if (feeAmounts[0] != FEE_BPS) {
            revert KyberSwapChecker__InvalidFeeConfig();
        }
    }

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
