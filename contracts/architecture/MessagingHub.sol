// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { WAD, WAD_SQUARED } from "contracts/libraries/Constants.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";
import { BytesParsing } from "contracts/libraries/external/BytesParsing.sol";
import { EthCallQueryResponse, ParsedQueryResponse, QueryResponse, IWormhole } from "contracts/libraries/external/wormhole/QueryResponse.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICVE } from "contracts/interfaces/ICVE.sol";
import { IVeCVE } from "contracts/interfaces/IVeCVE.sol";
import { IGaugeManager } from "contracts/interfaces/IGaugeManager.sol";
import { ICentralRegistry, ChainData } from "contracts/interfaces/ICentralRegistry.sol";
import { EmissionData } from "contracts/interfaces/IMessagingHub.sol";
import { IFeeManager } from "contracts/interfaces/IFeeManager.sol";
import { IRewardManager, RewardsData } from "contracts/interfaces/IRewardManager.sol";
import { IWormholeRelayer } from "contracts/interfaces/external/wormhole/IWormholeRelayer.sol";
import { ITokenMessenger } from "contracts/interfaces/external/wormhole/ITokenMessenger.sol";

/// @title Curvance Messaging Hub.
/// @notice A system for sending messages across the Curvance Protocol from
///         chain to chain.
/// @dev The Messaging Hub acts as a unified hub for sending messages
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
contract MessagingHub is QueryResponse {
    using BytesParsing for bytes;

    /// CONSTANTS ///

    /// @notice Gas limit with which to call `targetAddress` via wormhole.
    uint256 internal constant _DEFAULT_GAS_LIMIT = 500_000;

    /// @dev `bytes4(keccak256(bytes("MessagingHub__Unauthorized()")))`.
    uint256 internal constant _UNAUTHORIZED_SELECTOR = 0x68bc8bd3;
    /// @dev `bytes4(keccak256(bytes("MessagingHub__InvalidParameter()")))`.
    uint256 internal constant _INVALID_PARAMETER_SELECTOR = 0xd6112bfe;
    /// @dev `keccak256(bytes("queryLockPoints()"))`.
    bytes4 internal constant _QUERY_POINTS_SELECTOR = bytes4(hex"c8aed262");

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;
    /// @notice Address of the Gauge Manager.
    IGaugeManager public immutable gaugeManager;
    /// @notice Address of fee token.
    address public immutable feeToken;

    /// STORAGE ///

    /// @notice Whether the Messaging Hub is paused or not.
    /// @dev messagingStatus can have three separate values:
    ///      1 = Messages can be created and executed
    ///      2 = Messages cannot be created, but can be executed.
    ///      3 = Messages can be neither created nor executed.
    uint256 public messagingStatus = 1;
    /// @notice Status of message hash whether it's delivered or not.
    /// @dev False = undelivered; True = delivered.
    mapping(bytes32 => bool) public isDeliveredMessageHash;

    /// ERRORS ///

    error MessagingHub__Unauthorized();
    error MessagingHub__InvalidParameter();
    error MessagingHub__InvalidEpoch();
    error MessagingHub__MessagingHubPaused();
    error MessagingHub__MessageHashIsAlreadyDelivered(bytes32 messageHash);
    error MessagingHub__InsufficientGasToken();

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

        // Query gauge and token configuration directly to minimize potential
        // human error.
        gaugeManager = IGaugeManager(centralRegistry.gaugeManager());
        feeToken = centralRegistry.feeToken();
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Executes a protocol epoch via CCQ by querying
    ///         `queryLockPoints` on all other chains, stores the results for
    ///         the other chains, and updates the data for this chain.
    /// @dev Chain lock point values across all chains are validated by
    ///      decoding the `response` and `signatures` containing the desired
    ///      values.
    /// @param response The Wormhole query response.
    /// @param signatures The wormhole signatures corresponding to the query
    ///                   response value.
    /// @param chainFeeAmount The amount of fees on this chain that should
    ///                       be distributed this epoch.
    /// @param gasLimit Gas limit value for each remote chain message,
    ///                 0 = default value inside messaging hub.
    function executeEpoch(
        bytes calldata response,
        IWormhole.Signature[] calldata signatures,
        uint256 chainFeeAmount,
        uint256 gasLimit
    ) external {
        _checkMessagingStatus(1);
        _canSubmitQueries();

        IRewardManager rewardManager = _getRewardManager();
        uint256 epoch = _getNextEpochToDeliver(rewardManager);

        if (rewardManager.currentEpoch(block.timestamp) <= epoch) {
            revert MessagingHub__InvalidEpoch();
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
        uint256 totalRemotePoints;

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
            totalRemotePoints += currentPoints;
        }

        _pullFees(chainFeeAmount);

        // Execute crosschain fee distribution.
        _executeCrosschainEpoch(
            chainIds,
            chainPoints,
            epoch,
            numResponses,
            totalRemotePoints,
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
            revert MessagingHub__MessageHashIsAlreadyDelivered(deliveryHash);
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

        ICVE cve = _getCVE();
        IVeCVE veCVE = _getVeCVE();

        // Validate message came directly from MessagingHub on the source chain.
        if (chainData.messagingHub != srcAddr) {
            return;
        }

        uint8 payloadType = abi.decode(payload, (uint8));

        if (payloadType == 1) {
            // PayloadType = 1: Receiving fees from a foreign chain.

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

            (
                ,
                uint256 epoch,
                uint256 emissionTotal,
                address[] emissionTokens,
                uint256[] emissionAmounts
            ) = abi.decode(
                    payload,
                    (uint8, uint256, uint256, address[], uint256[])
                );

            IGaugeManager cachedGaugeManager = gaugeManager;

            // Mint appropriate gauge emissions to Gauge Manager.
            cve.mintGaugeEmissions(address(cachedGaugeManager), emissionTotal);

            // Set upcoming epoch emissions for voted configuration.
            cachedGaugeManager.setEmissionRates(
                epoch,
                emissionTokens,
                emissionAmounts
            );
        } else if (payloadType == 3) {
            // payloadType = 3: Receiving fees from a foreign chain and
            //                  finalized epoch rewards data.

            IRewardManager rewardManager = _getRewardManager();
            (, uint256 epochToDeliver, uint256 epochRewardsPerPoint) = abi
                .decode(payload, (uint8, uint256, uint256));

            // If the reward per point ratio is 0, theres no rewards to
            // distribute this epoch, and we'd expect there to be no CCTP
            // message as well.
            if (epochRewardsPerPoint == 0) {
                if (
                    !_checkRewardManagerStatus(rewardManager) &&
                    _getNextEpochToDeliver(rewardManager) == epochToDeliver
                ) {
                    _recordEpochRewards(rewardManager, 0);
                }
                return;
            }

            // Should only have 1 CCTP transfer.
            if (additionalMessages.length != 1) {
                _revert(_INVALID_PARAMETER_SELECTOR);
            }

            uint256 amountReceived = _receiveFees(additionalMessages[0]);

            // If the Reward Manager is shutdown or epoch progression is
            // incorrect, transfer fees to DAO instead of recording epoch
            // rewards.
            if (
                _checkRewardManagerStatus(rewardManager) ||
                _getNextEpochToDeliver(rewardManager) != epochToDeliver
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
        _canSubmitQueries();

        ChainData memory chainData = _getChainData(dstChainId);

        amount = _pullFees(amount);
        _sendFeeToken(
            dstChainId,
            chainData.cctpDomain,
            amount,
            abi.encode(1),
            gasLimit
        );
    }

    /// @notice Sends token emissions configuration to the Messaging Hub
    ///         on `dstChainId`.
    /// @param emissionData Struct containing information on emission
    ///                     configuration.
    ///                     Containing values:
    ///                     1. The total amount of token emissions to allocate
    ///                        to the Gauge Manager.
    ///                     2. The token contract addresses receiving
    ///                        emissions.
    ///                     3. The emission amounts that each token should
    ///                        receive.
    /// @param dstChainId The remote chain's ID that will have its token
    ///                   emissions values set, in GETH format.
    /// @param gasLimit Gas limit value for each remote chain message,
    ///                 0 = default value inside messaging hub.
    /// @param epoch The epoch having its token emission values set.
    function sendEmissions(
        EmissionData calldata emissionData,
        uint256 dstChainId,
        uint256 gasLimit,
        uint256 epoch
    ) external {
        _checkMessagingStatus(1);

        if (msg.sender != centralRegistry.votingHub()) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        ChainData memory chainData = _getChainData(dstChainId);
        uint256 wormholeFee = quoteMessageFee(dstChainId, gasLimit);

        // Validate that we have sufficient fees to send crosschain.
        if (address(this).balance < wormholeFee) {
            revert MessagingHub__InsufficientGasToken();
        }

        _sendPayload(
            chainData.messagingChainId,
            chainData.messagingHub,
            abi.encode(
                2,
                epoch,
                emissionData.emissionTotal,
                emissionData.tokens,
                emissionData.emissions
            ), // payload
            gasLimit,
            wormholeFee
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
    ) external payable returns (uint64) {
        _checkMessagingStatus(1);

        ChainData memory chainData = _getChainData(dstChainId);
        uint16 wormholeChainId = chainData.messagingChainId;

        if (wormholeChainId == 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }
        if (recipient == address(0)) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        if (payloadType == 4) {
            // Bridge VeCVE Lock crosschain.

            if (msg.sender != address(_getVeCVE())) {
                _revert(_UNAUTHORIZED_SELECTOR);
            }
            return
                _sendPayload(
                    wormholeChainId,
                    chainData.messagingHub,
                    abi.encode(4, recipient, amount, aux), // payload
                    gasLimit,
                    msg.value
                );
        }

        // Bridge CVE crosschain.

        if (msg.sender != address(_getCVE())) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        return
            _sendPayload(
                wormholeChainId,
                chainData.messagingHub,
                abi.encode(5, recipient, amount), // payload
                gasLimit,
                msg.value
            );
    }

    /// PERMISSIONED EXTERNAL FUNCTIONS ///

    /// @notice Permissioned function that flips the pause status of the
    ///         Messaging Hub.
    function setMessagingHubStatus(uint256 newMessagingStatus) external {
        if (newMessagingStatus == 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // It is more dangerous to unpause the protocol than to pause it,
        // so turning message creation back on requires elevated permissions.
        if (newMessagingStatus == 1) {
            if (!centralRegistry.hasElevatedPermissions(msg.sender)) {
                _revert(_UNAUTHORIZED_SELECTOR);
            }
        } else {
            _checkDaoPermissions();
        }

        messagingStatus = newMessagingStatus > 2 ? 3 : newMessagingStatus;
    }

    /// @notice Withdraws gas tokens and fee tokens from the
    ///         Messaging Hub to the DAO address in order to
    ///         depreciate or rebalance the Messaging Hub.
    /// @dev This does not allow any loss of funds as authorized perms are
    ///      required to change the Messaging Hub, meaning in order
    ///      to steal funds a malicious actor would have had to compromise
    ///      the whole system already. Thus, we only need to check for DAO
    ///      permissions here.
    function withdrawDeposited() external {
        _checkDaoPermissions();

        uint256 gasTokenBalance = address(this).balance;
        uint256 feeTokenBalance = _getFeeTokenHeld();

        if (gasTokenBalance > 0) {
            SafeTransferLib.safeTransferETH(_getDaoAddress(), gasTokenBalance);
        }

        if (feeTokenBalance > 0) {
            _transferFeeTokens(feeTokenBalance, _getDaoAddress());
        }
    }

    /// PUBLIC FUNCTIONS ///

    function queryLockPoints() public view returns (uint256) {
        IVeCVE veCVE = _getVeCVE();
        uint256 epoch = _getNextEpochToDeliver(_getRewardManager());

        return veCVE.chainPoints() - veCVE.chainUnlocksByEpoch(epoch);
    }

    /// @notice Quotes gas cost and token fee for executing crosschain
    ///         deposit and messaging.
    /// @param dstChainId GETH destination chain ID.
    /// @param gasLimit Gas limit with which to call on destination chain.
    /// @return nativeFee Total gas cost to send a message to `dstChainId`.
    function quoteMessageFee(
        uint256 dstChainId,
        uint256 gasLimit
    ) public view returns (uint256 nativeFee) {
        (nativeFee, ) = _getWormholeRelayer().quoteEVMDeliveryPrice(
            _getChainData(dstChainId).messagingChainId,
            0,
            _getGasLimit(gasLimit)
        );

        // Add any potential fee premium for publishing wormhole message.
        nativeFee += _getWormholeCore().messageFee();
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Sends fee tokens to the receiver on `dstChainId`.
    /// @param dstChainId GETH destination chain ID.
    /// @param cctpDomain CCTP domain for `dstChainId`.
    /// @param amount The amount of token to transfer.
    /// @param payload The payload data that is sent along with the message.
    /// @param gasLimit Gas limit with which to call on destination chain.
    function _sendFeeToken(
        uint256 dstChainId,
        uint32 cctpDomain,
        uint256 amount,
        bytes memory payload,
        uint256 gasLimit
    ) internal {
        uint256 wormholeFee = quoteMessageFee(dstChainId, gasLimit);

        // Validate that we have sufficient fees to send crosschain.
        if (address(this).balance < wormholeFee) {
            revert MessagingHub__InsufficientGasToken();
        }

        ITokenMessenger circleTokenMessenger = centralRegistry
            .circleTokenMessenger();

        if (
            address(circleTokenMessenger) != address(0) &&
            circleTokenMessenger.remoteTokenMessengers(cctpDomain) !=
            bytes32(0)
        ) {
            _transferFeeTokenViaCCTP(
                circleTokenMessenger,
                dstChainId,
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
    /// @dev WARNING: Our CCTP message implementation requires finality
    ///               on a chain, meaning if finality takes longer than
    ///               CCTP's attestation, message and value delivery can
    ///               be longer than expected.
    /// @param circleTokenMessenger Token Messenger contract to submit
    ///                             transfer message to.
    /// @param dstChainId GETH destination chain ID.
    /// @param amount The amount of token to transfer.
    /// @param payload The payload data that is sent along with the message.
    /// @param wormholeFee Total gas cost to attach send a CCTP message
    ///                    to `dstChainId`.
    /// @param gasLimit Gas limit with which to call on destination chain.
    function _transferFeeTokenViaCCTP(
        ITokenMessenger circleTokenMessenger,
        uint256 dstChainId,
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
            _addressToBytes32(chainData.messagingHub),
            feeToken,
            _addressToBytes32(chainData.messagingHub)
        );

        IWormholeRelayer.MessageKey[]
            memory messageKeys = new IWormholeRelayer.MessageKey[](1);
        messageKeys[0] = IWormholeRelayer.MessageKey(
            2, // CCTP_KEY_TYPE
            abi.encodePacked(centralRegistry.cctpDomain(), nonce)
        );

        wormholeRelayer.sendToEvm{ value: wormholeFee }(
            chainData.messagingChainId,
            chainData.messagingHub,
            payload,
            0,
            0,
            _getGasLimit(gasLimit),
            chainData.messagingChainId,
            chainData.messagingHub,
            wormholeRelayer.getDefaultDeliveryProvider(),
            messageKeys,
            15
        );
    }

    /// @notice Executes protocol-wide reporting and distribution of epoch
    ///         results, to all chains within the Curvance Protocol system.
    /// @param gasLimit Gas limit value for each remote chain message,
    ///                 0 = default value inside messaging hub.
    function _executeCrosschainEpoch(
        uint256[] memory chainIds,
        uint256[] memory chainPoints,
        uint256 epochToDeliver,
        uint256 numChains,
        uint256 totalPoints,
        uint256 gasLimit
    ) internal {
        // Query rewards for this epoch.
        uint256 feeTokensHeld = _getFeeTokenHeld();

        // We temporary cache this chains lock points inside the currentChainId
        // variable since it will be overridden before it is ever called again.
        // We do this to avoid having to reserve another storage slot which will
        // create a stack too deep error and reduces runtime gas costs.
        uint256 currentChainId = queryLockPoints();

        // Add this chain's lock points to the sum of all remote
        // chain's points.
        totalPoints += currentChainId;

        // Calculate rewards per veCVE point.
        uint256 epochRewardsPerPoint = (feeTokensHeld * WAD_SQUARED) /
            totalPoints;

        IRewardManager rewardManager = _getRewardManager();
        ChainData memory chainData;
        uint256 feeTokensForChain;

        // If theres no epoch rewards per point this implies fee token amount
        // of 0 everywhere so we can record epoch rewards of 0 everywhere
        // and return.
        if (epochRewardsPerPoint == 0) {
            if (!_checkRewardManagerStatus(rewardManager)) {
                _recordEpochRewards(rewardManager, 0);
                // Notify the other chains of the per epoch rewards.
                for (uint256 i; i < numChains; ++i) {
                    currentChainId = chainIds[i];
                    chainData = _getChainData(currentChainId);
                    _sendPayload(
                        chainData.messagingChainId,
                        chainData.messagingHub,
                        abi.encode(3, epochToDeliver, 0),
                        gasLimit,
                        quoteMessageFee(currentChainId, gasLimit)
                    );
                }

                return;
            }
        }

        // Calculate the fee tokens that should stay on this chain by querying
        // this chains lock points directly and adjusting versus all remote
        // chains.
        feeTokensForChain =
            (((feeTokensHeld * WAD) / totalPoints) * currentChainId) /
            WAD;

        // If the Reward Manager is shutdown, transfer fees to DAO
        // instead of recording epoch rewards.
        if (_checkRewardManagerStatus(rewardManager)) {
            _transferFeeTokens(feeTokensHeld, _getDaoAddress());
            return;
        } else {
            // Transfer fees to Reward Manager, and record newest epoch rewards.
            _transferFeeTokens(feeTokensForChain, address(rewardManager));
            _recordEpochRewards(rewardManager, epochRewardsPerPoint);
        }

        // Notify the other chains of the per epoch rewards.
        for (uint256 i; i < numChains; ++i) {
            currentChainId = chainIds[i];
            chainData = _getChainData(currentChainId);

            // Calculate fees for current foreign Chain ID.
            feeTokensForChain =
                (((feeTokensHeld * WAD) / totalPoints) * chainPoints[i]) /
                WAD;

            // If there are no rewards for this chain we can record epoch
            // rewards of 0 without sending any fee tokens.
            if (feeTokensForChain == 0) {
                // Send epoch information of 0.
                _sendPayload(
                    chainData.messagingChainId,
                    chainData.messagingHub,
                    abi.encode(3, epochToDeliver, 0),
                    gasLimit,
                    quoteMessageFee(currentChainId, gasLimit)
                );
            } else {
                // If theres rewards for this chain we can record epoch rewards
                // and send expected amount of fee tokens.
                // Send fees and epoch information.
                _sendFeeToken(
                    currentChainId,
                    chainData.cctpDomain,
                    feeTokensForChain,
                    abi.encode(3, epochToDeliver, epochRewardsPerPoint),
                    gasLimit
                );
            }
        }
    }

    /// @dev Pulls `amount` fee tokens from the fee manager to
    ///      aggregate fees.
    function _pullFees(uint256 amount) internal returns (uint256) {
        return IFeeManager(centralRegistry.feeManager()).pullFees(amount);
    }

    /// @notice Publishes an instruction for the default delivery provider to
    ///         relay a payload to the address `targetAddress` on chain
    ///         `targetChain` with gas limit `gasLimit` and msg.value` equal to
    ///         `receiverValue`.
    ///         `targetAddress` must implement the IWormholeReceiver interface.
    ///         This function must be called with `msg.value` equal to
    ///         `quoteEVMDeliveryPrice(targetChain, receiverValue, gasLimit)`.
    ///         Any refunds (from leftover gas) will be paid to
    ///         the delivery provider. In order to receive the refunds, use
    ///         the `sendPayloadToEvm` function with `refundChain` and
    ///         `refundAddress` as parameters.
    /// @param targetChaidId In Wormhole Chain ID format.
    /// @param targetAddress Address to call on targetChain
    ///                      (that implements IWormholeReceiver).
    /// @param payload Arbitrary bytes to pass in as parameter in call to
    ///                `targetAddress`.
    /// @param gasLimit Gas limit with which to call `targetAddress`.
    /// @param messageFee Attached native gas token to pay for relayed payload.
    /// @return Sequence number of published VAA containing delivery instructions.
    function _sendPayload(
        uint16 targetChaidId,
        address targetAddress,
        bytes memory payload,
        uint256 gasLimit,
        uint256 messageFee
    ) internal returns (uint64) {
        return
            _getWormholeRelayer().sendPayloadToEvm{ value: messageFee }(
                targetChaidId,
                targetAddress,
                payload,
                0, // No receiver value since we're just passing a message.
                _getGasLimit(gasLimit),
                targetChaidId,
                targetAddress
            );
    }

    /// @dev Receives fee tokens from Circle from provided message.
    /// @param circleMessage A byte array containing a message and signature
    ///                      from Circle allowing redemption of a CCTP
    ///                      message.
    /// @return The amount of fee tokens received from processing
    ///         and receiving CCTP message.
    function _receiveFees(
        bytes memory circleMessage
    ) internal returns (uint256) {
        (bytes memory message, bytes memory signature) = abi.decode(
            circleMessage,
            (bytes, bytes)
        );
        uint256 beforeBalance = _getFeeTokenHeld();
        centralRegistry.circleMessageTransmitter().receiveMessage(
            message,
            signature
        );
        return _getFeeTokenHeld() - beforeBalance;
    }

    /// @dev Transfers `amount` `feeToken` to `recipient`.
    function _transferFeeTokens(uint256 amount, address recipient) internal {
        SafeTransferLib.safeTransfer(feeToken, recipient, amount);
    }

    /// @notice Record user rewards allocated to an epoch.
    /// @notice The address of the Reward Manager to record epoch rewards on.
    /// @param rewardsPerPoint The rewards allocated to 1 veCVE point for
    ///                        the next reward epoch delivered, in WAD.
    function _recordEpochRewards(
        IRewardManager rewardManager,
        uint256 rewardsPerPoint
    ) internal {
        rewardManager.recordEpochRewards(rewardsPerPoint);
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

    /// @notice Returns the current CVE address to call.
    function _getCVE() internal view returns (ICVE) {
        return ICVE(centralRegistry.cve());
    }

    /// @notice Returns the current VeCVE address to call.
    function _getVeCVE() internal view returns (IVeCVE) {
        return IVeCVE(centralRegistry.veCVE());
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

    /// @dev Returns ChainData struct for `chainId`.
    function _getChainData(
        uint256 chainId
    ) internal view returns (ChainData memory chainData) {
        chainData = centralRegistry.supportedChainData(chainId);
        // Validate that we are aiming for a supported chain.
        if (chainData.isSupported < 2) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }
    }

    /// @dev Returns the current Curvance DAO address.
    function _getDaoAddress() internal view returns (address) {
        return centralRegistry.daoAddress();
    }

    /// @dev Returns the amount of fee tokens currently held in this
    ///      Messaging Hub.
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
    ///      Fallsback to `_DEFAULT_GAS_LIMIT` if the input is less than default.
    function _getGasLimit(uint256 gasLimit) internal pure returns (uint256) {
        return gasLimit < _DEFAULT_GAS_LIMIT ? _DEFAULT_GAS_LIMIT : gasLimit;
    }

    /// @dev Checks whether the Messaging Hub is paused or not.
    function _checkMessagingStatus(uint256 messageType) internal view {
        if (messagingStatus > messageType) {
            revert MessagingHub__MessagingHubPaused();
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

    /// @notice Checks if the caller can submit votes to the protocol.
    function _canSubmitQueries() internal view {
        if (
            !centralRegistry.isHarvester(msg.sender) &&
            !centralRegistry.hasDaoPermissions(msg.sender)
        ) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }
    }

    /// @dev Checks whether the caller has sufficient permissioning.
    function _checkDaoPermissions() internal view {
        if (!centralRegistry.hasDaoPermissions(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }
    }
}
