// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BaseSwapChecker } from "contracts/calldata-checker/swap-checker/BaseSwapChecker.sol";

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";
import { BPS } from "contracts/libraries/ConstantsLib.sol";

import { IMetaAggregationRouterV2 } from "contracts/interfaces/external/kyberswap/IMetaAggregationRouterV2.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @notice Inspects the calldata for a KyberSwap related swap action.
/// @dev NOTE: Currently built for MetaAggregationRouterV2.
///      Fee validation: every swap must include exactly one fee receiver
///      which MUST be the DAO address from centralRegistry, with fee
///      amount == FEE_BPS (isInBps=true on the API). Zero fee receivers
///      is rejected — all swaps must pay the protocol fee.
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

    /// @notice The only permitted value for `desc.flags`.
    /// @dev    _FEE_IN_BPS (0x80) MUST be set so that `feeAmounts[0]` is
    ///         interpreted as basis points, not as an absolute token amount.
    ///
    ///         0x200 is KyberSwap's executor v3 indicator — always present in
    ///         API-generated calldata on Monad. Router-inert (not in the
    ///         router's flag constants), consumed only by the executor contract.
    ///
    ///         All other flag bits are explicitly rejected:
    ///           0x02 _REQUIRES_EXTRA_ETH — unnecessary, opens msg.value attack surface.
    ///           0x08 _BURN_FROM_MSG_SENDER — not used by Curvance.
    ///           0x10 _BURN_FROM_TX_ORIGIN — not used by Curvance.
    ///           0x20 _SIMPLE_SWAP — different execution path, not used by SDK.
    ///           0x40 _FEE_ON_DST — fee must be on input (currency_in) so
    ///                the deducted amount is deterministic before the swap.
    ///
    ///         Exact match (not a bitmask) so any future KyberSwap flags are
    ///         also rejected by default until explicitly reviewed and allowed.
    uint256 public constant REQUIRED_FLAGS = 0x280;

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
    error KyberSwapChecker__InvalidApproveTarget();
    error KyberSwapChecker__InvalidSrcConfig();
    error KyberSwapChecker__InvalidExecutor();

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
        ICentralRegistry cr = ICentralRegistry(centralRegistryInit);
        CentralRegistryLib._isCentralRegistry(cr);
        centralRegistry = cr;

        if (block.chainid != 143) {
            revert KyberSwapChecker__UnsupportedChain();
        }

        uint256 numExecutors = kyberSwapExecutors.length;
        for (uint256 i; i < numExecutors; ++i) {
            _setExecutorApproval(kyberSwapExecutors[i], true);
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

        if (
            _getFuncSigHash(swapAction.call) !=
            IMetaAggregationRouterV2.swap.selector
        ) {
            revert CalldataChecker__InvalidFuncSig();
        }

        // Decode the full execution params.
        IMetaAggregationRouterV2.SwapExecutionParams memory execution = abi
            .decode(
                _getFuncParams(swapAction.call),
                (IMetaAggregationRouterV2.SwapExecutionParams)
            );
        IMetaAggregationRouterV2.SwapDescriptionV2 memory desc = execution
            .desc;

        // Kyberswap's MetaAggregationRouterV2 treats `dstReceiver == address(0)`
        // as a shortcut for sending output to `msg.sender`.
        address recipient = desc.dstReceiver == address(0)
            ? msg.sender
            : desc.dstReceiver;
        if (recipient != expectedRecipient) {
            revert CalldataChecker__RecipientError();
        }

        // Cache token addresses.
        address inputToken = address(desc.srcToken);
        address outputToken = address(desc.dstToken);

        if (inputToken != swapAction.inputToken) {
            revert CalldataChecker__InputTokenError();
        }

        // Kyberswap only recognizes address(Eeee) as native.
        if (inputToken == address(0)) {
            revert KyberSwapChecker__InvalidNativeTokenAddress();
        }

        if (desc.amount != swapAction.inputAmount) {
            revert CalldataChecker__InputAmountError();
        }

        if (outputToken != swapAction.outputToken) {
            revert CalldataChecker__OutputTokenError();
        }

        // Kyberswap only recognizes address(Eeee) as native.
        if (outputToken == address(0)) {
            revert KyberSwapChecker__InvalidNativeTokenAddress();
        }

        if (!isApprovedExecutor[execution.callTarget]) {
            revert CalldataChecker__TargetError();
        }

        if (execution.targetData.length == 0) {
            revert KyberSwapChecker__InvalidTargetData();
        }

        // Validate fee configuration.
        // Required: exactly one receiver == DAO address, fee == FEE_BPS.
        _validateFeeConfig(desc.feeReceivers, desc.feeAmounts);

        // Exact flag match.  See REQUIRED_FLAGS documentation for rationale.
        // Critical: without _FEE_IN_BPS (0x80) the router interprets
        // feeAmounts[0]=4 as 4 wei instead of 4 basis points.
        if (desc.flags != REQUIRED_FLAGS) {
            revert KyberSwapChecker__InvalidFlags();
        }

        // Prevent permit-based approvals.
        if (desc.permit.length != 0) {
            revert KyberSwapChecker__InvalidPermit();
        }

        // approveTarget is unused by MetaAggregationRouterV2.swap() in the
        // current deployment. Lock to address(0) to prevent activation if a
        // future router version introduces _APPROVE_FUND or similar.
        if (execution.approveTarget != address(0)) {
            revert KyberSwapChecker__InvalidApproveTarget();
        }

        // Source-token custody validation: the router sends post-fee input
        // tokens to srcReceivers before executing targetData.
        uint256 srcReceiversLength = desc.srcReceivers.length;
        if (srcReceiversLength != 1) {
            revert KyberSwapChecker__InvalidSrcConfig();
        }

        if (srcReceiversLength != desc.srcAmounts.length) {
            revert KyberSwapChecker__InvalidSrcConfig();
        }

        if (desc.srcReceivers[0] != execution.callTarget) {
            revert KyberSwapChecker__InvalidSrcConfig();
        }

        _validateSrcAmount(desc.amount, desc.srcAmounts[0]);

        // Belt-and-suspenders: the router checks minReturnAmount > 0 but
        // catching it here prevents execution from reaching external code
        // with a guaranteed-revert configuration.
        minOutAmount = desc.minReturnAmount;
        if (minOutAmount == 0) {
            revert CalldataChecker__InvalidMinOut();
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

        _setExecutorApproval(executor, approved);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Sets executor approval after validating the executor address.
    /// @param executor The Kyber executor address to update.
    /// @param approved Whether `executor` should be allowlisted.
    function _setExecutorApproval(address executor, bool approved) internal {
        if (executor == address(0)) {
            revert KyberSwapChecker__InvalidExecutor();
        }

        isApprovedExecutor[executor] = approved;
        emit SwapExecutorUpdated(executor, approved);
    }

    /// @notice Validates fee receiver and amount configuration.
    /// @dev    Every swap must include exactly one fee receiver which is
    ///         centralRegistry.daoAddress(), with feeAmounts[0] == FEE_BPS.
    ///         No exceptions — zero fee receivers is rejected to ensure
    ///         unified fee collection on all swaps.
    ///
    ///         ENCODING: KyberSwap calldata built with isInBps=true stores
    ///         the BPS value directly in feeAmounts[0] (confirmed via API).
    function _validateFeeConfig(
        address[] memory feeReceivers,
        uint256[] memory feeAmounts
    ) internal view {
        // Exactly one fee receiver and one fee amount required.
        if (feeReceivers.length != 1 || feeAmounts.length != 1) {
            revert KyberSwapChecker__InvalidFeeConfig();
        }

        // Receiver must be the DAO.
        if (feeReceivers[0] != centralRegistry.daoAddress()) {
            revert KyberSwapChecker__InvalidFeeConfig();
        }

        // Fee must be exactly the configured BPS value.
        if (feeAmounts[0] != FEE_BPS) {
            revert KyberSwapChecker__InvalidFeeConfig();
        }
    }

    /// @notice Validates that only the enforced input-side DAO fee is withheld.
    /// @dev Kyber floors the input-side BPS fee for current SDK-generated
    ///      `chargeFeeBy=currency_in` routes.
    function _validateSrcAmount(uint256 amount, uint256 srcAmount) internal pure {
        if (srcAmount > amount) {
            revert KyberSwapChecker__InvalidSrcConfig();
        }

        uint256 feeDelta = amount - srcAmount;
        uint256 quotient = amount / BPS;
        uint256 remainder = amount % BPS;
        uint256 expectedFee = quotient * FEE_BPS + (remainder * FEE_BPS) / BPS;

        if (feeDelta != expectedFee) {
            revert KyberSwapChecker__InvalidSrcConfig();
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
