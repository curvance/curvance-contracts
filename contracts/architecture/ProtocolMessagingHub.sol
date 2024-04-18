// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { GaugeController } from "contracts/gauge/GaugeController.sol";
import { FeeTokenBridgingHub } from "contracts/architecture/FeeTokenBridgingHub.sol";

import { WAD } from "contracts/libraries/Constants.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { BytesParsing } from "contracts/libraries/external/BytesParsing.sol";
import { EthCallQueryResponse, ParsedQueryResponse, QueryResponse, IWormhole } from "contracts/libraries/external/wormhole/QueryResponse.sol";
import { TypedMemView } from "contracts/libraries/external/TypedMemView.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICVE } from "contracts/interfaces/ICVE.sol";
import { ICentralRegistry, ChainData, OmnichainData } from "contracts/interfaces/ICentralRegistry.sol";
import { ICVELocker } from "contracts/interfaces/ICVELocker.sol";
import { IVeCVE } from "contracts/interfaces/IVeCVE.sol";
import { IWormhole } from "contracts/interfaces/external/wormhole/IWormhole.sol";
import { IWormholeRelayer } from "contracts/interfaces/external/wormhole/IWormholeRelayer.sol";
import { ITokenBridge } from "contracts/interfaces/external/wormhole/ITokenBridge.sol";
import { RewardsData } from "contracts/interfaces/ICVELocker.sol";

/// @title Curvance Protocol Messaging Hub.
/// @notice A system for sending messages across the Curvance Protocol from
///         chain to chain.
/// @dev The Protocol Messaging Hub acts as a unified hub for sending messages
///      crosschain. Various actions can be taken such as managing Gauge
///      Emissions offchain -> onchain porting, veCVE token locking data,
///      moving protocol fees, bridging CVE, moving a veCVE lock crosschain,
///      etc.
///
///      Native gas tokens are stored inside the contract to pay for all
///      crosschain actions. Locked token data actions are intended to be
///      moved over to Wormhole's CCQ prior to mainnet deployment.
///      At this time, payload/MessageType configuration + encoding/decoding
///      are not production ready.
///
contract ProtocolMessagingHub is FeeTokenBridgingHub, QueryResponse {
    using BytesParsing for bytes;

    /// CONSTANTS ///

    /// @notice CVE contract address.
    ICVE public immutable cve;
    /// @notice veCVE contract address.
    IVeCVE public immutable veCVE;

    /// @dev `keccak256(bytes("queryLockPoints()"))`.
    bytes4 internal _QUERY_POINTS_SELECTOR = bytes4(hex"c8aed262");

    /// @dev `bytes4(keccak256(bytes("ProtocolMessagingHub__Unauthorized()")))`.
    uint256 internal constant _UNAUTHORIZED_SELECTOR = 0xc70c67ab;
    /// @dev `bytes4(keccak256(bytes("ProtocolMessagingHub__InvalidParameter()")))`.
    uint256 internal constant _INVALID_PARAMETER_SELECTOR = 0xee61d28c;

    /// STORAGE ///

    /// @notice Whether the Protocol Messaging Hub is paused or not.
    /// @dev 1 = activate; 2 = paused.
    uint256 public isPaused = 1;
    /// @notice Status of message hash whether it's delivered or not.
    /// @dev False = undelivered; True = delivered.
    mapping(bytes32 => bool) public isDeliveredMessageHash;

    /// ERRORS ///

    error ProtocolMessagingHub__Unauthorized();
    error ProtocolMessagingHub__InvalidParameter();
    error ProtocolMessagingHub__MessagingHubPaused();
    error ProtocolMessagingHub__MessageHashIsAlreadyDelivered(
        bytes32 messageHash
    );
    error ProtocolMessagingHub__InvalidWormholeChainId();
    error ProtocolMessagingHub__InvalidRecipient();

    receive() external payable {}

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_
    )
        FeeTokenBridgingHub(centralRegistry_)
        QueryResponse(address(centralRegistry_.wormholeCore()))
    {
        cve = ICVE(centralRegistry.cve());
        veCVE = IVeCVE(centralRegistry.veCVE());
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Executes a protocol epoch via CCQ by querying `queryLockPoints`
    ///         on all other chains, stores the results for the other chains,
    ///         and updates the data for this chain.
    function executeEpoch(
        bytes memory response,
        IWormhole.Signature[] memory signatures,
        uint256 gasLimit
    ) external {
        ICVELocker locker = ICVELocker(centralRegistry.cveLocker());
        uint256 epoch = locker.nextEpochToDeliver();

        if (locker.currentEpoch(block.timestamp) <= epoch) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        ParsedQueryResponse memory r = parseAndVerifyQueryResponse(
            response,
            signatures
        );
        uint256 numResponses = r.responses.length;
        uint256[] memory chainIds = centralRegistry.getForeignChainIds();
        if (numResponses != chainIds.length) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        uint256[] memory chainPoints = new uint256[](numResponses);
        uint256 currentPoints;
        uint256 totalPoints;

        for (uint256 i; i < numResponses; ++i) {
            if (
                r.responses[i].chainId !=
                centralRegistry.GETHToMessagingChainId(chainIds[i])
            ) {
                _revert(_INVALID_PARAMETER_SELECTOR);
            }

            EthCallQueryResponse memory eqr = parseEthCallQueryResponse(
                r.responses[i]
            );

            // Validate that update is not stale.
            validateBlockTime(eqr.blockTime, block.timestamp - 300);

            if (eqr.result.length != 1) {
                _revert(_INVALID_PARAMETER_SELECTOR);
            }

            // Validate addresses and function signatures.
            address[] memory validAddresses = new address[](1);
            bytes4[] memory validFunctionSignatures = new bytes4[](1);

            // Validate our responses came from the expected contract (Messaging Hub),
            // and expected function.
            validAddresses[0] = centralRegistry
                .supportedChainData(chainIds[i])
                .messagingHub;
            validFunctionSignatures[0] = _QUERY_POINTS_SELECTOR;
            validateMultipleEthCallData(
                eqr.result,
                validAddresses,
                validFunctionSignatures
            );

            // Validate that the result is a uint256.
            if (eqr.result[0].result.length != 32) {
                _revert(_INVALID_PARAMETER_SELECTOR);
            }

            currentPoints = abi.decode(eqr.result[0].result, (uint256));
            // Document points on current foreign chain.
            chainPoints[i] = currentPoints;
            totalPoints += currentPoints;
        }

        currentPoints = queryLockPoints();
        // Add this chains points to sum.
        totalPoints += currentPoints;

        // Scoping to avoid stack too deep.
        {
            address feeAccumulator = centralRegistry.feeAccumulator();
            uint256 feeTokenBalance = IERC20(feeToken).balanceOf(
                feeAccumulator
            );
            uint256 compoundingFee = (feeTokenBalance *
                centralRegistry.protocolCompoundFee()) /
                centralRegistry.protocolHarvestFee();

            // Move 1% of fees accumulated to central registry to be used
            // for Gelato Network bots.
            SafeTransferLib.safeTransferFrom(
                feeToken,
                feeAccumulator,
                address(centralRegistry),
                compoundingFee
            );

            feeTokenBalance -= compoundingFee;

            // Move remaining fees on this chain to PMH to distribute.
            SafeTransferLib.safeTransferFrom(
                feeToken,
                feeAccumulator,
                address(this),
                feeTokenBalance
            );
        }

        // Execute crosschain fee distribution.
        _executeCrosschainEpoch(
            chainIds,
            chainPoints,
            numResponses,
            currentPoints,
            totalPoints,
            gasLimit
        );
    }

    function receiveMessage(
        bytes calldata message,
        bytes calldata /* attestation */
    ) external view returns (bool success) {
        bytes32 destinationCaller = TypedMemView.index(
            TypedMemView.ref(message, 0),
            84, // DESTINATION_CALLER_INDEX
            32
        );

        // Validate destination caller
        if (
            destinationCaller != bytes32(0) &&
            destinationCaller == bytes32(uint256(uint160(msg.sender)))
        ) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        return true;
    }

    /// @notice Used when fees are received from other chains.
    ///         When a `send` is performed with this contract as the target,
    ///         this function will be invoked by the WormholeRelayer contract.
    /// NOTE: This function should be restricted such that only
    ///       the Wormhole Relayer contract can call it.
    /// @param payload An arbitrary message which was included in the delivery
    ///                by the requester. This message's signature will already
    ///                have been verified (as long as msg.sender is
    ///                the Wormhole Relayer contract).
    /// @param srcAddress The (wormhole format) address on the sending chain
    ///                   which requested this delivery.
    /// @param srcChainId The wormhole chain ID where delivery was requested.
    /// @param deliveryHash The VAA hash of the deliveryVAA.
    function receiveWormholeMessages(
        bytes memory payload,
        bytes[] memory /* additionalMessages */,
        bytes32 srcAddress,
        uint16 srcChainId,
        bytes32 deliveryHash
    ) external payable {
        _checkMessagingHubStatus();

        // Validate that this is not a replay attack.
        if (isDeliveredMessageHash[deliveryHash]) {
            revert ProtocolMessagingHub__MessageHashIsAlreadyDelivered(
                deliveryHash
            );
        }

        isDeliveredMessageHash[deliveryHash] = true;

        // Validate that the Wormhole Relayer is the caller.
        if (msg.sender != address(centralRegistry.wormholeRelayer())) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        uint256 gethChainId = centralRegistry.messagingToGETHChainId(
            srcChainId
        );
        address srcAddr = address(uint160(uint256(srcAddress)));

        OmnichainData memory operator = centralRegistry.getOmnichainOperators(
            srcAddr,
            gethChainId
        );
        // Validate the operator is authorized.
        if (operator.isAuthorized < 2) {
            return;
        }

        ChainData memory chainData = centralRegistry.supportedChainData(
            gethChainId
        );
        // Validate message came directly from MessagingHub on the source chain.
        if (chainData.messagingHub != srcAddr) {
            return;
        }

        uint8 payloadType = abi.decode(payload, (uint8));

        if (payloadType == 1) {
            // PayloadType = 1: Submitting fees and epoch lock data for THIS chain,
            //                  for a reported epoch.

            (, address srcFeeToken, uint256 amount) = abi.decode(
                payload,
                (uint8, address, uint256)
            );
            // Validate fee token address
            if (chainData.feeTokenAddress != srcFeeToken) {
                _revert(_INVALID_PARAMETER_SELECTOR);
            }

            address feeToken = centralRegistry.feeToken();
            ICVELocker locker = ICVELocker(centralRegistry.cveLocker());

            // In terms of funds inside fee accumulator, 1/16 or 6.25% of fee token
            // should be sent and deposited to Gelato 1Balance on polygon.
            uint256 oneBalanceFee = (amount *
                centralRegistry.protocolCompoundFee()) /
                centralRegistry.protocolHarvestFee();
            SafeTransferLib.safeTransfer(
                feeToken,
                address(centralRegistry),
                oneBalanceFee
            );

            amount -= oneBalanceFee;

            // If the locker is shutdown, transfer fees to DAO
            // instead of recording epoch rewards.
            if (locker.isShutdown() == 2) {
                SafeTransferLib.safeTransfer(
                    feeToken,
                    centralRegistry.daoAddress(),
                    amount
                );
                return;
            }

            // Transfer fees to locker and record newest epoch rewards.
            SafeTransferLib.safeTransfer(feeToken, address(locker), amount);
            locker.recordEpochRewards(amount);
        } else if (payloadType == 2) {
            // payloadType = 2: Crosschain Gauge Emission Configuration.

            (, bytes memory emissionData) = abi.decode(
                payload,
                (uint8, bytes)
            );

            (
                address[] memory gaugePools,
                uint256[] memory emissionTotals,
                address[][] memory tokens,
                uint256[][] memory emissions
            ) = abi.decode(
                    emissionData,
                    (address[], uint256[], address[][], uint256[][])
                );

            uint256 numPools = gaugePools.length;
            GaugeController gaugePool;

            for (uint256 i; i < numPools; ) {
                gaugePool = GaugeController(gaugePools[i]);
                // Mint epoch gauge emissions to the gauge pool.
                cve.mintGaugeEmissions(address(gaugePool), emissionTotals[i]);
                // Set upcoming epoch emissions for voted configuration.
                gaugePool.setEmissionRates(
                    gaugePool.currentEpoch() + 1,
                    tokens[i],
                    emissions[i]
                );

                unchecked {
                    ++i;
                }
            }
        } else if (payloadType == 3) {
            // payloadType = 3: Receive finalized epoch rewards data.

            (, uint256 chainLockedAmount) = abi.decode(
                payload,
                (uint8, uint256)
            );

            ICVELocker(centralRegistry.cveLocker()).recordEpochRewards(
                chainLockedAmount
            );
        } else if (payloadType == 4) {
            // payloadType = 4: Indicates migrating a veCVE lock from the source
            //                  chain to this destination chain.

            (, address recipient, uint256 amount, bool continuousLock) = abi
                .decode(payload, (uint8, address, uint256, bool));

            cve.mintVeCVELock(amount);
            cve.approve(address(veCVE), amount);

            RewardsData memory rewardData;

            // RewardData is forced to be an empty struct since Curvance does
            // not how long it has been between lock destruction and creation,
            // and any dynamic action could have stale characteristics.
            IVeCVE(veCVE).createLockFor(
                recipient,
                amount,
                continuousLock,
                rewardData,
                "",
                0
            );
        }
    }

    /// @notice Sends fee tokens to the Messaging Hub on `dstChainId`.
    /// @param dstChainId Destination chain ID.
    /// @param amount The amount of token to transfer.
    /// @param gasLimit Gas limit with which to call on destination chain.
    function sendFees(
        uint256 dstChainId,
        uint256 amount,
        uint256 gasLimit
    ) external {
        _checkMessagingHubStatus();

        if (
            !centralRegistry.isHarvester(msg.sender) &&
            !centralRegistry.hasDaoPermissions(msg.sender)
        ) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        ChainData memory chainData = centralRegistry.supportedChainData(
            dstChainId
        );
        uint256 messagingChainId = centralRegistry.GETHToMessagingChainId(
            dstChainId
        );
        OmnichainData memory operator = centralRegistry.getOmnichainOperators(
            chainData.messagingHub,
            dstChainId
        );

        // Validate that the operator is authorized.
        if (operator.isAuthorized < 2) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        // Validate that the operator messaging chain matches
        // the destination chain id and we are aiming for a supported chain.
        if (
            operator.messagingChainId != messagingChainId ||
            chainData.isSupported < 2
        ) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Pull the fee token from the fee accumulator.
        // This will revert if we've misconfigured fee token contract supply
        // by `amount`.
        SafeTransferLib.safeTransferFrom(
            centralRegistry.feeToken(),
            centralRegistry.feeAccumulator(),
            address(this),
            amount
        );

        _sendFeeToken(
            dstChainId,
            chainData.messagingHub,
            amount,
            "",
            gasLimit
        );
    }

    /// @notice Send CVE or a veCVE lock via Wormhole.
    /// @param dstChainId Chain ID of the target blockchain.
    /// @param recipient The address of recipient on destination chain.
    /// @param amount The amount of token to bridge.
    /// @param gasLimit Gas limit with which to call on destination chain.
    /// @param payloadType The type of payload information to relay to
    ///                    estination chain.
    ///                    VeCVE lock migrations have a payloadType of 4,
    ///                    whereas CVE has no payload type because its
    ///                    a native transfer.
    /// @param aux Auxilliary boolean data if needed for bridging token.
    /// @return Wormhole sequence for emitted TransferTokensWithRelay message.
    function bridgeToken(
        uint256 dstChainId,
        address recipient,
        uint256 amount,
        uint256 gasLimit,
        uint256 payloadType,
        bool aux
    ) external payable returns (uint64) {
        _checkMessagingHubStatus();

        uint16 wormholeChainId = centralRegistry
            .wormholeData(dstChainId)
            .chainId;

        if (wormholeChainId == 0) {
            revert ProtocolMessagingHub__InvalidWormholeChainId();
        }
        if (recipient == address(0)) {
            revert ProtocolMessagingHub__InvalidRecipient();
        }

        if (gasLimit == 0) {
            gasLimit = _DEFAULT_GAS_LIMIT;
        }

        if (payloadType == 4) {
            if (msg.sender != address(veCVE)) {
                _revert(_UNAUTHORIZED_SELECTOR);
            }

            ChainData memory chainData = centralRegistry.supportedChainData(
                dstChainId
            );

            // Validate that we are aiming for a supported chain.
            if (chainData.isSupported < 2) {
                _revert(_INVALID_PARAMETER_SELECTOR);
            }

            return
                centralRegistry.wormholeRelayer().sendPayloadToEvm{
                    value: msg.value
                }(
                    wormholeChainId,
                    chainData.messagingHub,
                    abi.encode(4, recipient, amount, aux), // payload
                    0, // No receiver value since we're just passing a message.
                    gasLimit
                );
        }

        if (msg.sender != address(cve)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        ITokenBridge tokenBridge = centralRegistry.tokenBridge();
        IWormhole wormholeCore = centralRegistry.wormholeCore();

        SwapperLib._approveTokenIfNeeded(
            address(cve),
            address(tokenBridge),
            amount
        );

        uint64 sequence = tokenBridge.transferTokensWithPayload{
            value: wormholeCore.messageFee()
        }(
            address(cve),
            amount,
            wormholeChainId,
            bytes32(uint256(uint160(recipient))),
            0,
            ""
        );

        IWormholeRelayer.VaaKey[]
            memory vaaKeys = new IWormholeRelayer.VaaKey[](1);
        vaaKeys[0] = IWormholeRelayer.VaaKey({
            emitterAddress: bytes32(uint256(uint160(address(tokenBridge)))),
            chainId: wormholeCore.chainId(),
            sequence: sequence
        });

        return
            centralRegistry.wormholeRelayer().sendVaasToEvm{
                value: msg.value - wormholeCore.messageFee()
            }(wormholeChainId, recipient, "", 0, gasLimit, vaaKeys);
    }

    /// PERMISSIONED EXTERNAL FUNCTIONS ///

    /// @notice Permissioned function that flips the pause status of the
    ///         Messaging Hub.
    function flipMessagingHubStatus() external {
        // If the messaging hub is currently paused,
        // then we are turning pause state off.
        bool state = isPaused == 2 ? false : true;
        _checkAuthorizedPermissions(state);

        // Possible outcomes:
        // If pause state is being turned off (state = false), then the
        // Messaging Hub is being turned back on which means isPaused will be
        // set to 1.
        //
        // If pause state is being turned on (state = true), then the
        // Messaging Hub is being turned off which means isPaused will be
        // set to 2.
        isPaused = state ? 2 : 1;
    }

    /// @notice Withdraws gas tokens and fee tokens from the Protocol Messaging Hub
    ///         to the DAO address in order to depreciate or rebalance the
    ///         Protocol Messaging Hub.
    /// @dev This does not allow any loss of funds as authorized perms are
    ///      required to change the Protocol Messaging Hub, meaning in order to steal
    ///      funds a malicious actor would have had to compromise the whole
    ///      system already. Thus, we only need to check for DAO perms here.
    function withdrawDeposited() external {
        _checkAuthorizedPermissions(true);

        address feeToken = centralRegistry.feeToken();
        uint256 gasTokenBalance = address(this).balance;
        uint256 feeTokenBalance = IERC20(feeToken).balanceOf(address(this));

        if (gasTokenBalance > 0) {
            SafeTransferLib.forceSafeTransferETH(
                centralRegistry.daoAddress(),
                gasTokenBalance
            );
        }

        if (feeTokenBalance > 0) {
            SafeTransferLib.safeTransfer(
                feeToken,
                centralRegistry.daoAddress(),
                feeTokenBalance
            );
        }
    }

    /// PUBLIC FUNCTIONS ///

    function queryLockPoints() public view returns (uint256) {
        ICVELocker locker = ICVELocker(centralRegistry.cveLocker());
        uint256 epoch = locker.nextEpochToDeliver();

        return veCVE.chainPoints() - veCVE.chainUnlocksByEpoch(epoch);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Executes protocol-wide reporting and distribution of epoch
    ///         results, to all chains within the Curvance Protocol system.
    function _executeCrosschainEpoch(
        uint256[] memory chainIds,
        uint256[] memory chainPoints,
        uint256 numChains,
        uint256 thisChainsPoints,
        uint256 totalPoints,
        uint256 gasLimit
    ) internal {
        if (gasLimit == 0) {
            gasLimit = _DEFAULT_GAS_LIMIT;
        }

        // Query rewards for this epoch.
        uint256 feeTokensOverall = IERC20(feeToken).balanceOf(address(this));
        // Calculate rewards per veCVE point.
        uint256 epochRewardsPerCVE = (feeTokensOverall * WAD) / totalPoints;

        uint256 feeTokensForChain;
        uint256 currentChainId;

        ICVELocker locker = ICVELocker(centralRegistry.cveLocker());

        feeTokensForChain =
            (((feeTokensOverall * WAD) / totalPoints) * thisChainsPoints) /
            WAD;

        // If the locker is shutdown, transfer fees to DAO
        // instead of recording epoch rewards.
        if (locker.isShutdown() == 2) {
            SafeTransferLib.safeTransfer(
                feeToken,
                centralRegistry.daoAddress(),
                feeTokensForChain
            );
        } else {
            // Transfer fees to locker and record newest epoch rewards.
            SafeTransferLib.safeTransfer(
                feeToken,
                address(locker),
                feeTokensForChain
            );
            locker.recordEpochRewards(epochRewardsPerCVE);
        }

        // Notify the other chains of the per epoch rewards.
        for (uint256 i; i < numChains; ++i) {
            currentChainId = chainIds[i];
            // Calculate fees for current foreign Chain ID.
            feeTokensForChain =
                (((feeTokensOverall * WAD) / totalPoints) * chainPoints[i]) /
                WAD;

            // Send fees and information.
            _sendFeeToken(
                currentChainId,
                centralRegistry
                    .supportedChainData(currentChainId)
                    .messagingHub,
                feeTokensForChain,
                abi.encode(3, epochRewardsPerCVE),
                gasLimit
            );
        }
    }

    /// @dev Internal helper for reverting efficiently.
    function _revert(uint256 s) internal pure {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, s)
            revert(0x1c, 0x04)
        }
    }

    /// @dev Checks whether the Messaging Hub is paused or not.
    function _checkMessagingHubStatus() internal view {
        if (isPaused == 2) {
            revert ProtocolMessagingHub__MessagingHubPaused();
        }
    }

    /// @dev Checks whether the caller has sufficient permissions
    ///      based on `state`, turning something off is less "risky" than
    ///      enabling something, so `state` = true has reduced permissioning
    ///      compared to `state` = false.
    function _checkAuthorizedPermissions(bool state) internal view {
        if (state) {
            if (!centralRegistry.hasDaoPermissions(msg.sender)) {
                _revert(_UNAUTHORIZED_SELECTOR);
            }
        } else {
            if (!centralRegistry.hasElevatedPermissions(msg.sender)) {
                _revert(_UNAUTHORIZED_SELECTOR);
            }
        }
    }
}
