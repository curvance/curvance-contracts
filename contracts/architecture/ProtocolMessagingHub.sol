// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { GaugeController } from "contracts/gauge/GaugeController.sol";
import { FeeTokenBridgingHub } from "contracts/architecture/FeeTokenBridgingHub.sol";

import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { BytesParsing } from "contracts/libraries/external/BytesParsing.sol";
import { EthCallQueryResponse, ParsedQueryResponse, QueryResponse } from "contracts/libraries/external/wormhole/QueryResponse.sol";
import { TypedMemView } from "contracts/libraries/external/TypedMemView.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICVE } from "contracts/interfaces/ICVE.sol";
import { IFeeAccumulator, EpochRolloverData, LockData } from "contracts/interfaces/IFeeAccumulator.sol";
import { ICentralRegistry, ChainData, OmnichainData } from "contracts/interfaces/ICentralRegistry.sol";
import { ICVELocker } from "contracts/interfaces/ICVELocker.sol";
import { IVeCVE } from "contracts/interfaces/IVeCVE.sol";
import { RewardsData } from "contracts/interfaces/ICVELocker.sol";
import { IWormhole } from "contracts/interfaces/external/wormhole/IWormhole.sol";

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
    /// TYPES ///

    struct ChainEntry {
        uint16 chainID;
        address contractAddress;
        uint256 chainPoints;
        uint256 blockNum;
        uint256 blockTime;
    }

    /// CONSTANTS ///

    /// @notice CVE contract address.
    ICVE public immutable cve;
    /// @notice veCVE contract address.
    IVeCVE public immutable veCVE;
    /// @notice Messaging layer Chain ID in their integer format.
    uint16 public thisChainID;

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
    /// @notice Contains last reported data for a particular chain
    ///         after crosschain querying.
    /// @dev Chain ID is recorded in the Messaging Layers Chain ID
    ///      not GETH format.
    mapping(uint16 => ChainEntry) public reportedLockPoints;
    /// @notice Status of message hash whether it's delivered or not.
    /// @dev False = undelivered; True = delivered.
    mapping(bytes32 => bool) public isDeliveredMessageHash;
    /// @notice ChainID => Epoch => 2 = yes; 0 = no.
    mapping(uint256 => mapping(uint256 => uint256)) public lockedTokenDataSent;

    /// ERRORS ///

    error ProtocolMessagingHub__Unauthorized();
    error ProtocolMessagingHub__InvalidParameter();
    error ProtocolMessagingHub__MessagingHubPaused();
    error ProtocolMessagingHub__MessageHashIsAlreadyDelivered(
        bytes32 messageHash
    );
    receive() external payable {}

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address wormhole_
    ) FeeTokenBridgingHub(centralRegistry_) QueryResponse(wormhole_){
        cve = ICVE(centralRegistry.cve());
        veCVE = IVeCVE(centralRegistry.veCVE());
        if (address(centralRegistry_.wormholeCore()) != wormhole_) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }
    }

    /// EXTERNAL FUNCTIONS ///
    
    /// @notice Executes a protocol epoch via CCQ by querying `queryLockPoints` on all other chains, 
    ///         stores the results for the other chains, and updates the data for this chain.
    function executeEpoch(bytes memory response, IWormhole.Signature[] memory signatures) external {
        uint256 adjustedBlockTime;
        ParsedQueryResponse memory r = parseAndVerifyQueryResponse(response, signatures);
        uint256 numResponses = r.responses.length;
        uint256[] memory chainIDs = centralRegistry.foreignChainIDs();
        if (numResponses != chainIDs.length) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        for (uint256 i; i < numResponses; ) {
            // Create a storage pointer for frequently read and updated data stored on the blockchain
            ChainEntry storage chainEntry = reportedLockPoints[r.responses[i].chainId];
            if (chainEntry.chainID != chainIDs[i]) {
                _revert(_INVALID_PARAMETER_SELECTOR);
            }

            EthCallQueryResponse memory eqr = parseEthCallQueryResponse(r.responses[i]);

            // Validate that update is not obsolete
            validateBlockNum(eqr.blockNum, chainEntry.blockNum);

            // Validate that update is not stale
            validateBlockTime(eqr.blockTime, block.timestamp - 300);

            if (eqr.result.length != 1) {
                _revert(_INVALID_PARAMETER_SELECTOR);
            }

            // Validate addresses and function signatures
            address[] memory validAddresses = new address[](1);
            bytes4[] memory validFunctionSignatures = new bytes4[](1);
            validAddresses[0] = chainEntry.contractAddress;
            validFunctionSignatures[0] = _QUERY_POINTS_SELECTOR;

            validateMultipleEthCallData(eqr.result, validAddresses, validFunctionSignatures);

            // Validate that the result is a uint256.
            if (eqr.result[0].result.length != 32) {
                _revert(_INVALID_PARAMETER_SELECTOR);
            }

            chainEntry.blockNum = eqr.blockNum;
            chainEntry.blockTime = adjustedBlockTime;
            chainEntry.chainPoints = abi.decode(eqr.result[0].result, (uint256));

            unchecked {
                ++i;
            }
        }

        /// Add executeEpoch call here ///

        reportedLockPoints[thisChainID].blockNum = block.number;
        reportedLockPoints[thisChainID].blockTime = block.timestamp;
        reportedLockPoints[thisChainID].chainPoints = queryLockPoints();
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
        address wormholeRelayer = address(centralRegistry.wormholeRelayer());

        // Validate that the Wormhole Relayer is the caller.
        if (msg.sender != wormholeRelayer) {
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

        // PayloadType = 1: Submitting fees and epoch lock data for THIS chain,
        //                  for a reported epoch.
        if (payloadType == 1) {
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
            SafeTransferLib.safeTransfer(
                feeToken,
                address(locker),
                amount
            );
            locker.recordEpochRewards(amount);
            return;
            
        // PayloadID = 2: Crosschain Gauge Emission Configuration.
        } else if (payloadType == 2) {
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
                    (
                        address[],
                        uint256[],
                        address[][],
                        uint256[][]
                    )
                );

            // Use scoping for stack too deep logic.
            uint256 numPools = gaugePools.length;
            GaugeController gaugePool;

            for (uint256 i; i < numPools; ) {
                gaugePool = GaugeController(gaugePools[i]);
                // Mint epoch gauge emissions to the gauge pool.
                cve.mintGaugeEmissions(
                    address(gaugePool),
                    emissionTotals[i]
                );
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
            return;

        // PayloadID = 3: Receive finalized epoch rewards data.
        } else if (payloadType == 3) {
            (, uint256 chainLockedAmount) = abi.decode(
                payload,
                (uint8, uint256)
            );

            IFeeAccumulator(centralRegistry.feeAccumulator())
                    .receiveExecutableLockData(chainLockedAmount);
            return;

        // PayloadID = 4: Indicates migrating a veCVE lock from the source
        //                chain to this destination chain.
        }  else if (payloadType == 4) {
            (, bytes memory lockData) = abi.decode(payload, (uint8, bytes));

            (address recipient, uint256 amount, bool continuousLock) = abi
                .decode(lockData, (address, uint256, bool));

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
    /// @param to The address of Messaging Hub on `dstChainId`.
    /// @param amount The amount of token to transfer.
    /// @param gasLimit Gas limit with which to call on destination chain.
    function sendFees(
        uint256 dstChainId,
        address to,
        uint256 amount,
        uint256 gasLimit
    ) external {
        _checkMessagingHubStatus();
        _checkPermissions();

        uint256 messagingChainId = centralRegistry.GETHToMessagingChainId(
            dstChainId
        );

        {
            // Avoid stack too deep
            OmnichainData memory operator = centralRegistry
                .getOmnichainOperators(to, dstChainId);

            // Validate that the operator is authorized.
            if (operator.isAuthorized < 2) {
                _revert(_UNAUTHORIZED_SELECTOR);
            }

            // Validate that the operator messaging chain matches.
            // the destination chain id.
            if (operator.messagingChainId != messagingChainId) {
                _revert(_INVALID_PARAMETER_SELECTOR);
            }

            // Validate that we are aiming for a supported chain.
            if (
                centralRegistry.supportedChainData(dstChainId).isSupported < 2
            ) {
                _revert(_INVALID_PARAMETER_SELECTOR);
            }
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

        _sendFeeToken(dstChainId, to, amount, gasLimit);
    }

    /// @notice Send wormhole message to bridge CVE.
    /// @param dstChainId Chain ID of the target blockchain.
    /// @param recipient The address of recipient on destination chain.
    /// @param amount The amount of token to bridge.
    /// @param gasLimit Gas limit with which to call on destination chain.
    /// @return Wormhole sequence for emitted TransferTokensWithRelay message.
    function bridgeCVE(
        uint256 dstChainId,
        address recipient,
        uint256 amount,
        uint256 gasLimit
    ) external payable returns (uint64) {
        if (msg.sender != address(cve)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        _checkMessagingHubStatus();

        return
            _transferTokenViaWormhole(
                address(cve),
                dstChainId,
                recipient,
                amount,
                msg.value,
                gasLimit
            );
    }

    /// @notice Send wormhole message to bridge VeCVE lock.
    /// @param dstChainId Chain ID of the target blockchain.
    /// @param recipient The address of recipient on destination chain.
    /// @param amount The amount of token to bridge.
    /// @param continuousLock Whether the lock should be continuous or not.
    /// @param gasLimit Gas limit with which to call on destination chain.
    /// @return Wormhole sequence for emitted TransferTokensWithRelay message.
    function bridgeVeCVELock(
        uint256 dstChainId,
        address recipient,
        uint256 amount,
        bool continuousLock,
        uint256 gasLimit
    ) external payable returns (uint64) {
        if (msg.sender != address(veCVE)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        _checkMessagingHubStatus();

        address dstMessagingHub = centralRegistry
            .supportedChainData(dstChainId)
            .messagingHub;
        bytes memory payload = abi.encode(recipient, amount, continuousLock);

        return
            _sendWormholeMessages(
                dstChainId,
                dstMessagingHub,
                msg.value,
                5,
                payload,
                gasLimit > 0 ? gasLimit : _DEFAULT_GAS_LIMIT
            );
    }

    /// @notice Sends veCVE locked token data to destination chain.
    /// @param dstChainId Destination chain ID where the message data
    ///                   should be sent.
    /// @param toAddress The destination address specified by `dstChainId`.
    /// @param gasLimit Gas limit with which to call on destination chain.
    function sendVeCVELockData(
        uint256 dstChainId,
        address toAddress,
        uint256 gasLimit
    ) external payable {
        if (!centralRegistry.isHarvester(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        ICVELocker locker = ICVELocker(centralRegistry.cveLocker());
        uint256 epoch = locker.nextEpochToDeliver();

        if (lockedTokenDataSent[dstChainId][epoch] == 2) {
            return;
        }

        lockedTokenDataSent[dstChainId][epoch] = 2;

        ChainData memory chainData = centralRegistry.supportedChainData(
            dstChainId
        );

        if (chainData.isSupported < 2) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        if (chainData.messagingHub != toAddress) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        if (gasLimit == 0) {
            gasLimit = _DEFAULT_GAS_LIMIT;
        }

        bytes memory payload = abi.encode(
            IVeCVE(veCVE).chainPoints() -
                IVeCVE(veCVE).chainUnlocksByEpoch(epoch)
        );

        _sendWormholeMessages(
            dstChainId,
            toAddress,
            _quoteMessageFee(dstChainId, false, gasLimit),
            4,
            payload,
            gasLimit
        );
    }

    /// @notice Records a Curvance reward epoch, if all chains have been
    ///         recorded executes system wide reporting and distribution
    ///         to all chains within the Curvance Protocol system.
    function sendEpochRewardData(
        LockData[] calldata crossChainLockData,
        uint256 epochRewardsPerCVE,
        uint256 gasLimit
    ) external {
        if (msg.sender != centralRegistry.feeAccumulator()) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        if (gasLimit == 0) {
            gasLimit = _DEFAULT_GAS_LIMIT;
        }

        uint256 numChainData = crossChainLockData.length;
        uint16 lockDataChainId;
        ChainData memory chainData;

        // Notify the other chains of the per epoch rewards.
        for (uint256 i; i < numChainData; ) {
            lockDataChainId = crossChainLockData[i].chainId;
            chainData = centralRegistry.supportedChainData(lockDataChainId);

            _sendWormholeMessages(
                uint256(lockDataChainId),
                chainData.messagingHub,
                _quoteMessageFee(uint256(lockDataChainId), false, gasLimit),
                4,
                abi.encode(epochRewardsPerCVE),
                gasLimit
            );

            unchecked {
                ++i;
            }
        }
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
        uint256 currentEpoch = veCVE.currentEpoch(block.timestamp);
        return veCVE.chainPoints() - veCVE.chainUnlocksByEpoch(currentEpoch);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Sends veCVE locked token data to destination chain.
    /// @param dstChainId Destination chain ID where the message data
    ///                   should be sent.
    /// @param toAddress The destination address specified by `dstChainId`.
    /// @param payloadId The id of payload.
    /// @param payload The payload data that is sent along with the message.
    /// @return Wormhole sequence for emitted TransferTokensWithRelay message.
    function _sendWormholeMessages(
        uint256 dstChainId,
        address toAddress,
        uint256 messageFee,
        uint8 payloadId,
        bytes memory payload,
        uint256 gasLimit
    ) internal returns (uint64) {
        // Validate that we are aiming for a supported chain.
        if (centralRegistry.supportedChainData(dstChainId).isSupported < 2) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        return
            centralRegistry.wormholeRelayer().sendPayloadToEvm{
                value: messageFee
            }(
                centralRegistry.wormholeChainId(dstChainId),
                toAddress,
                abi.encode(payloadId, payload), // payload
                0, // No receiver value since we're just passing a message.
                gasLimit
            );
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

    /// @dev Checks whether the caller has sufficient permissioning.
    function _checkPermissions() internal view {
        if (
            !centralRegistry.isHarvester(msg.sender) &&
            msg.sender != centralRegistry.feeAccumulator()
        ) {
            _revert(_UNAUTHORIZED_SELECTOR);
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
