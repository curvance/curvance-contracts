// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { GaugeController } from "contracts/gauge/GaugeController.sol";

import { WAD, WAD_SQUARED } from "contracts/libraries/Constants.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";
import { BytesParsing } from "contracts/libraries/external/BytesParsing.sol";
import { EthCallQueryResponse, ParsedQueryResponse, QueryResponse, IWormhole } from "contracts/libraries/external/wormhole/QueryResponse.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICVE } from "contracts/interfaces/ICVE.sol";
import { ICentralRegistry, ChainData } from "contracts/interfaces/ICentralRegistry.sol";
import { IFeeAccumulator } from "contracts/interfaces/IFeeAccumulator.sol";
import { IRewardManager, RewardsData } from "contracts/interfaces/IRewardManager.sol";
import { IVeCVE } from "contracts/interfaces/IVeCVE.sol";
import { IWormhole } from "contracts/interfaces/external/wormhole/IWormhole.sol";
import { IWormholeRelayer } from "contracts/interfaces/external/wormhole/IWormholeRelayer.sol";
import { ITokenBridge } from "contracts/interfaces/external/wormhole/ITokenBridge.sol";
import { ITokenMessenger } from "contracts/interfaces/external/wormhole/ITokenMessenger.sol";

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
contract ProtocolMessagingHub is QueryResponse {
    using BytesParsing for bytes;

    /// CONSTANTS ///

    /// @notice Gas limit with which to call `targetAddress` via wormhole.
    uint256 internal constant _DEFAULT_GAS_LIMIT = 250_000;

    /// @dev `bytes4(keccak256(bytes("ProtocolMessagingHub__Unauthorized()")))`.
    uint256 internal constant _UNAUTHORIZED_SELECTOR = 0xc70c67ab;
    /// @dev `bytes4(keccak256(bytes("ProtocolMessagingHub__InvalidParameter()")))`.
    uint256 internal constant _INVALID_PARAMETER_SELECTOR = 0xee61d28c;
    /// @dev `keccak256(bytes("queryLockPoints()"))`.
    bytes4 internal constant _QUERY_POINTS_SELECTOR = bytes4(hex"c8aed262");

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;
    /// @notice Address of fee token.
    address public immutable feeToken;
    /// @notice CVE contract address.
    ICVE public immutable cve;
    /// @notice veCVE contract address.
    IVeCVE public immutable veCVE;

    /// STORAGE ///

    /// @notice Whether the Protocol Messaging Hub is paused or not.
    /// @dev messagingStatus can have three separate values:
    ///      1 = Messages can be created and executed
    ///      2 = Messages cannot be created, but can be executed.
    ///      3 = Messages can be neither created nor executed.
    uint256 public messagingStatus = 1;
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
    error ProtocolMessagingHub__InsufficientGasToken();

    receive() external payable {}

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_
    ) QueryResponse(address(centralRegistry_.wormholeCore())) {
        if (
            !ERC165Checker.supportsInterface(
                address(centralRegistry_),
                type(ICentralRegistry).interfaceId
            )
        ) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        centralRegistry = centralRegistry_;

        feeToken = centralRegistry.feeToken();
        cve = ICVE(centralRegistry.cve());
        veCVE = IVeCVE(centralRegistry.veCVE());
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Executes a protocol epoch via CCQ by querying
    ///         `queryLockPoints` on all other chains, stores the results for
    ///         the other chains, and updates the data for this chain.
    function executeEpoch(
        bytes memory response,
        IWormhole.Signature[] memory signatures,
        uint256 chainFeeAmount,
        uint256 gasLimit
    ) external {
        _checkMessagingStatus(1);

        IRewardManager rewardManager = _getRewardManager();
        uint256 epoch = _getNextEpochToDeliver(rewardManager);

        if (rewardManager.currentEpoch(block.timestamp) <= epoch) {
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

            // Validate our responses came from the
            // expected contract (Messaging Hub), and expected function.
            validAddresses[0] = _getChainData(chainIds[i]).messagingHub;
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

        _pullFees(chainFeeAmount);

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

    /// @notice Used when fees are received from other chains.
    ///         When a `send` is performed with this contract as the target,
    ///         this function will be invoked by the WormholeRelayer contract.
    /// NOTE: This function should be restricted such that only
    ///       the Wormhole Relayer contract can call it.
    /// @param payload An arbitrary message which was included in the delivery
    ///                by the requester. This message's signature will already
    ///                have been verified (as long as msg.sender is
    ///                the Wormhole Relayer contract).
    /// @param additionalMessages Additional messages which were requested to be
    ///                           included in this delivery.
    /// @param srcAddress The (wormhole format) address on the sending chain
    ///                   which requested this delivery.
    /// @param srcChainId The wormhole chain ID where delivery was requested.
    /// @param deliveryHash The VAA hash of the deliveryVAA.
    function receiveWormholeMessages(
        bytes memory payload,
        bytes[] memory additionalMessages,
        bytes32 srcAddress,
        uint16 srcChainId,
        bytes32 deliveryHash
    ) external payable {
        _checkMessagingStatus(2);

        // Validate that this is not a replay attack.
        if (isDeliveredMessageHash[deliveryHash]) {
            revert ProtocolMessagingHub__MessageHashIsAlreadyDelivered(
                deliveryHash
            );
        }

        // Document messageHash as delivered to prevent replays.
        isDeliveredMessageHash[deliveryHash] = true;

        // Validate that the Wormhole Relayer is the caller.
        if (msg.sender != address(_getWormholeRelayer())) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        uint256 gethChainId = centralRegistry.messagingToGETHChainId(
            srcChainId
        );
        address srcAddr = address(uint160(uint256(srcAddress)));
        ChainData memory chainData = _getChainData(gethChainId);

        // Validate message came directly from MessagingHub on the source chain.
        if (chainData.messagingHub != srcAddr) {
            return;
        }

        uint8 payloadType = abi.decode(payload, (uint8));

        if (payloadType == 1) {
            // PayloadType = 1: Receiving fees from a foreign chain with no
            //                  auxilliary payload for purposes of epoch
            //                  accounting.

            // Should only have 1 CCTP transfer.
            if (additionalMessages.length != 1) {
                _revert(_INVALID_PARAMETER_SELECTOR);
            }

            uint256 amountReceived = _receiveFees(additionalMessages[0]);

            // If the Reward Manager is shutdown, transfer fees to DAO
            // instead of recording epoch rewards.
            if (_checkRewardManagerStatus(_getRewardManager())) {
                _transferFeeTokens(amountReceived, _getDaoAddress());
            }
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
            // payloadType = 3:  Receiving fees from a foreign chain and
            //                   finalized epoch rewards data.

            // Should only have 1 CCTP transfer.
            if (additionalMessages.length != 1) {
                _revert(_INVALID_PARAMETER_SELECTOR);
            }

            uint256 amountReceived = _receiveFees(additionalMessages[0]);

            (, uint256 epochToDeliver, uint256 epochRewardsPerPoint) = abi
                .decode(payload, (uint8, uint256, uint256));

            IRewardManager rewardManager = _getRewardManager();

            // If the Reward Manager is shutdown or epoch progression is
            // incorrect, transfer fees to DAO instead of recording epoch
            // rewards.
            if (
                _checkRewardManagerStatus(rewardManager) ||
                rewardManager.nextEpochToDeliver() != epochToDeliver
            ) {
                _transferFeeTokens(amountReceived, _getDaoAddress());
            } else {
                // Transfer fees to Reward Manager, and record newest epoch
                // rewards.
                _transferFeeTokens(amountReceived, address(rewardManager));
                _recordEpochRewards(rewardManager, epochRewardsPerPoint);
            }
        } else if (payloadType == 4) {
            // payloadType = 4: Indicates migrating a veCVE lock from the source
            //                  chain to this destination chain.

            (, address recipient, uint256 amount, bool continuousLock) = abi
                .decode(payload, (uint8, address, uint256, bool));

            cve.mintLockedTokens(recipient, amount);
            _approveTokenIfNeeded(address(cve), address(veCVE), amount);

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
        } else if (payloadType == 5) {
            // payloadType = 5: Indicates receiving CVE from the source
            //                  chain to this destination chain.

            (, address recipient, uint256 amount) = abi.decode(
                payload,
                (uint8, address, uint256)
            );

            cve.completeBridge(recipient, amount);
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
        _checkMessagingStatus(1);

        if (
            !centralRegistry.isHarvester(msg.sender) &&
            !centralRegistry.hasDaoPermissions(msg.sender)
        ) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        ChainData memory chainData = _getChainData(dstChainId);

        // Validate that the operator messaging chain matches
        // the destination chain id and we are aiming for a supported chain.
        if (chainData.isSupported < 2) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        amount = _pullFees(amount);

        _sendFeeToken(
            dstChainId,
            chainData.messagingHub,
            amount,
            abi.encode(1),
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
    function bridgeToken(
        uint256 dstChainId,
        address recipient,
        uint256 amount,
        uint256 gasLimit,
        uint256 payloadType,
        bool aux
    ) external payable {
        _checkMessagingStatus(1);

        ChainData memory chainData = _getChainData(dstChainId);
        uint16 wormholeChainId = chainData.messagingChainId;

        if (wormholeChainId == 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }
        if (recipient == address(0)) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate that we are aiming for a supported chain.
        if (chainData.isSupported < 2) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        gasLimit = _getGasLimit(gasLimit);
        IWormholeRelayer wormholeRelayer = _getWormholeRelayer();

        if (payloadType == 4) {
            // Bridge VeCVE Lock crosschain.

            if (msg.sender != address(veCVE)) {
                _revert(_UNAUTHORIZED_SELECTOR);
            }

            wormholeRelayer.sendPayloadToEvm{ value: msg.value }(
                wormholeChainId,
                chainData.messagingHub,
                abi.encode(4, recipient, amount, aux), // payload
                0, // No receiver value since we're just passing a message.
                gasLimit
            );

            return;
        }

        // Bridge CVE crosschain.

        if (msg.sender != address(cve)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        wormholeRelayer.sendPayloadToEvm{ value: msg.value }(
            wormholeChainId,
            chainData.messagingHub,
            abi.encode(5, recipient, amount), // payload
            0, // No receiver value since we're just passing a message.
            gasLimit
        );
    }

    /// PERMISSIONED EXTERNAL FUNCTIONS ///

    /// @notice Permissioned function that flips the pause status of the
    ///         Messaging Hub.
    function setMessagingHubStatus(uint256 newMessagingStatus) external {
        if (newMessagingStatus == 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        if (newMessagingStatus > 2) {
            if (!centralRegistry.hasElevatedPermissions(msg.sender)) {
                _revert(_UNAUTHORIZED_SELECTOR);
            }
        } else {
            _checkDaoPermissions();
        }

        messagingStatus = newMessagingStatus > 2 ? 3 : newMessagingStatus;
    }

    /// @notice Withdraws gas tokens and fee tokens from the
    ///         Protocol Messaging Hub to the DAO address in order to
    ///         depreciate or rebalance the Protocol Messaging Hub.
    /// @dev This does not allow any loss of funds as authorized perms are
    ///      required to change the Protocol Messaging Hub, meaning in order
    ///      to steal funds a malicious actor would have had to compromise
    ///      the whole system already. Thus, we only need to check for DAO
    ///      permissions here.
    function withdrawDeposited() external {
        _checkDaoPermissions();

        uint256 gasTokenBalance = address(this).balance;
        uint256 feeTokenBalance = _getFeeTokenHeld();

        if (gasTokenBalance > 0) {
            SafeTransferLib.forceSafeTransferETH(
                _getDaoAddress(),
                gasTokenBalance
            );
        }

        if (feeTokenBalance > 0) {
            _transferFeeTokens(feeTokenBalance, _getDaoAddress());
        }
    }

    /// PUBLIC FUNCTIONS ///

    function queryLockPoints() public view returns (uint256) {
        uint256 epoch = _getNextEpochToDeliver(_getRewardManager());
        return veCVE.chainPoints() - veCVE.chainUnlocksByEpoch(epoch);
    }

    /// @notice Quotes gas cost and token fee for executing crosschain
    ///         deposit and messaging.
    /// @param dstChainId GETH destination chain ID.
    /// @param transferToken Whether deliver token or not.
    /// @param gasLimit Gas limit with which to call on destination chain.
    /// @return nativeFee Total gas cost to send a message to `dstChainId`.
    function quoteMessageFee(
        uint256 dstChainId,
        bool transferToken,
        uint256 gasLimit
    ) public view returns (uint256 nativeFee) {
        (nativeFee, ) = _getWormholeRelayer().quoteEVMDeliveryPrice(
            _getChainData(dstChainId).messagingChainId,
            0,
            _getGasLimit(gasLimit)
        );

        if (transferToken) {
            // Add cost of publishing the 'sending token' wormhole message.
            nativeFee += _getMessageFee();
        }
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Sends fee tokens to the receiver on `dstChainId`.
    /// @param dstChainId GETH destination chain ID.
    /// @param to The address of receiver on `dstChainId`.
    /// @param amount The amount of token to transfer.
    /// @param payload The payload data that is sent along with the message.
    /// @param gasLimit Gas limit with which to call on destination chain.
    function _sendFeeToken(
        uint256 dstChainId,
        address to,
        uint256 amount,
        bytes memory payload,
        uint256 gasLimit
    ) internal {
        uint256 wormholeFee = quoteMessageFee(dstChainId, true, gasLimit);

        // Validate that we have sufficient fees to send crosschain.
        if (address(this).balance < wormholeFee) {
            revert ProtocolMessagingHub__InsufficientGasToken();
        }

        ITokenMessenger circleTokenMessenger = centralRegistry
            .circleTokenMessenger();

        if (
            address(circleTokenMessenger) != address(0) &&
            circleTokenMessenger.remoteTokenMessengers(
                _getChainData(dstChainId).cctpDomain
            ) !=
            bytes32(0)
        ) {
            _transferFeeTokenViaCCTP(
                circleTokenMessenger,
                dstChainId,
                to,
                amount,
                payload,
                wormholeFee,
                gasLimit
            );
        } else {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }
    }

    /// @notice Sends fee tokens to the receiver on `dstChainId`.
    /// @param circleTokenMessenger Token Messenger contract to submit
    ///                             transfer message to.
    /// @param dstChainId GETH destination chain ID.
    /// @param to The address of receiver on `dstChainId`.
    /// @param amount The amount of token to transfer.
    /// @param payload The payload data that is sent along with the message.
    /// @param wormholeFee Total gas cost to attach send a CCTP message
    ///                    to `dstChainId`.
    /// @param gasLimit Gas limit with which to call on destination chain.
    function _transferFeeTokenViaCCTP(
        ITokenMessenger circleTokenMessenger,
        uint256 dstChainId,
        address to,
        uint256 amount,
        bytes memory payload,
        uint256 wormholeFee,
        uint256 gasLimit
    ) internal {
        IWormholeRelayer wormholeRelayer = _getWormholeRelayer();
        ChainData memory chainData = _getChainData(dstChainId);

        _approveTokenIfNeeded(feeToken, address(circleTokenMessenger), amount);

        uint64 nonce = circleTokenMessenger.depositForBurnWithCaller(
            amount,
            chainData.cctpDomain,
            _addressToBytes32(to),
            feeToken,
            _addressToBytes32(to)
        );

        IWormholeRelayer.MessageKey[]
            memory messageKeys = new IWormholeRelayer.MessageKey[](1);
        messageKeys[0] = IWormholeRelayer.MessageKey(
            2, // CCTP_KEY_TYPE
            abi.encodePacked(centralRegistry.cctpDomain(), nonce)
        );

        wormholeRelayer.sendToEvm{ value: wormholeFee }(
            chainData.messagingChainId,
            to,
            payload,
            0,
            0,
            _getGasLimit(gasLimit),
            chainData.messagingChainId,
            address(0),
            wormholeRelayer.getDefaultDeliveryProvider(),
            messageKeys,
            15
        );
    }

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
        gasLimit = _getGasLimit(gasLimit);

        // Query rewards for this epoch.
        uint256 feeTokensOverall = _getFeeTokenHeld();
        // Calculate rewards per veCVE point.
        uint256 epochRewardsPerPoint = (feeTokensOverall * WAD_SQUARED) /
            totalPoints;

        uint256 feeTokensForChain;
        uint256 currentChainId;

        feeTokensForChain =
            (((feeTokensOverall * WAD) / totalPoints) * thisChainsPoints) /
            WAD;

        IRewardManager rewardManager = _getRewardManager();

        // If the Reward Manager is shutdown, transfer fees to DAO
        // instead of recording epoch rewards.
        if (_checkRewardManagerStatus(rewardManager)) {
            _transferFeeTokens(feeTokensForChain, _getDaoAddress());
        } else {
            // Transfer fees to Reward Manager, and record newest epoch rewards.
            _transferFeeTokens(feeTokensForChain, address(rewardManager));
            _recordEpochRewards(rewardManager, epochRewardsPerPoint);
        }

        uint256 epochToDeliver = rewardManager.nextEpochToDeliver();

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
                _getChainData(currentChainId).messagingHub,
                feeTokensForChain,
                abi.encode(3, epochToDeliver, epochRewardsPerPoint),
                gasLimit
            );
        }
    }

    /// @dev Pulls `amount` fee tokens from the fee accumulator to
    ///      aggregate fees.
    function _pullFees(uint256 amount) internal returns (uint256) {
        return
            IFeeAccumulator(centralRegistry.feeAccumulator()).pullFees(amount);
    }

    /// @dev Receives fee tokens from Circle from provided message.
    function _receiveFees(
        bytes memory circleMessage
    ) internal returns (uint256) {
        (bytes memory message, bytes memory signature) = abi.decode(
            circleMessage,
            (bytes, bytes)
        );
        uint256 beforeBalance = IERC20(feeToken).balanceOf(address(this));
        centralRegistry.circleMessageTransmitter().receiveMessage(
            message,
            signature
        );
        return IERC20(feeToken).balanceOf(address(this)) - beforeBalance;
    }

    /// @dev Transfers `amount` `feeToken` to `recipient`.
    function _transferFeeTokens(uint256 amount, address recipient) internal {
        SafeTransferLib.safeTransfer(feeToken, recipient, amount);
    }

    function _recordEpochRewards(
        IRewardManager rewardManager,
        uint256 epochRewardsPerPoint
    ) internal {
        rewardManager.recordEpochRewards(epochRewardsPerPoint);
    }

    /// @dev Approves `token` `amount` to be spent by `spender`, if necessary.
    function _approveTokenIfNeeded(
        address token,
        address spender,
        uint256 amount
    ) internal {
        SwapperLib._approveTokenIfNeeded(token, spender, amount);
    }

    function _addressToBytes32(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    /// @dev Returns the current Reward Manager address to call.
    function _getRewardManager() internal view returns (IRewardManager) {
        return IRewardManager(centralRegistry.rewardManager());
    }

    /// @dev Returns the current Wormhole Relayer address to call.
    function _getWormholeRelayer() internal view returns (IWormholeRelayer) {
        return centralRegistry.wormholeRelayer();
    }

    /// @dev Returns the current Wormhole Core address to call.
    function _getWormholeCore() internal view returns (IWormhole) {
        return centralRegistry.wormholeCore();
    }

    /// @dev Returns the current standard wormhole message fee.
    function _getMessageFee() internal view returns (uint256) {
        return _getWormholeCore().messageFee();
    }

    /// @dev Returns ChainData struct for `chainId`.
    function _getChainData(
        uint256 chainId
    ) internal view returns (ChainData memory) {
        return centralRegistry.supportedChainData(chainId);
    }

    /// @dev Returns the current Curvance DAO address.
    function _getDaoAddress() internal view returns (address) {
        return centralRegistry.daoAddress();
    }

    /// @dev Returns the amount of fee tokens currently held in this
    ///      Protocol Messaging Hub.
    function _getFeeTokenHeld() internal view returns (uint256) {
        return IERC20(feeToken).balanceOf(address(this));
    }

    /// @dev Returns the next protocol epoch to deliver rewards for.
    function _getNextEpochToDeliver(
        IRewardManager rewardManager
    ) internal view returns (uint256) {
        return rewardManager.nextEpochToDeliver();
    }

    /// @dev Returns the proper gas limit to use based on parameter input.
    ///      Fallsback to `_DEFAULT_GAS_LIMIT` if the input is 0.
    function _getGasLimit(uint256 gasLimit) internal pure returns (uint256) {
        return gasLimit == 0 ? _DEFAULT_GAS_LIMIT : gasLimit;
    }

    /// @dev Checks whether the Messaging Hub is paused or not.
    function _checkMessagingStatus(uint256 messageType) internal view {
        if (messagingStatus > messageType) {
            revert ProtocolMessagingHub__MessagingHubPaused();
        }
    }

    /// @dev Checks whether the Reward Manager is shutdown or not.
    /// @return Returns true if the Reward Manager is shutdown.
    function _checkRewardManagerStatus(
        IRewardManager rewardManager
    ) internal view returns (bool) {
        return rewardManager.isShutdown() == 2;
    }

    /// @dev Internal helper for reverting efficiently.
    function _revert(uint256 s) internal pure {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, s)
            revert(0x1c, 0x04)
        }
    }

    /// @dev Checks whether the caller has sufficient permissioning.
    function _checkDaoPermissions() internal view {
        if (!centralRegistry.hasDaoPermissions(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }
    }
}
