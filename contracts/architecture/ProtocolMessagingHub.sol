// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { GaugeController } from "contracts/gauge/GaugeController.sol";
import { FeeTokenBridgingHub } from "contracts/architecture/FeeTokenBridgingHub.sol";

import { WAD } from "contracts/libraries/Constants.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";
import { BytesParsing } from "contracts/libraries/external/BytesParsing.sol";
import { EthCallQueryResponse, ParsedQueryResponse, QueryResponse, IWormhole } from "contracts/libraries/external/wormhole/QueryResponse.sol";
import { TypedMemView } from "contracts/libraries/external/TypedMemView.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICVE } from "contracts/interfaces/ICVE.sol";
import { ICentralRegistry, ChainData, OmnichainData, WormholeData } from "contracts/interfaces/ICentralRegistry.sol";
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
    error ProtocolMessagingHub__InsufficientGasToken();

    receive() external payable {}

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_
    )
        QueryResponse(address(centralRegistry_.wormholeCore()))
    {
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

    /// @notice Executes a protocol epoch via CCQ by querying `queryLockPoints`
    ///         on all other chains, stores the results for the other chains,
    ///         and updates the data for this chain.
    function executeEpoch(
        bytes memory response,
        IWormhole.Signature[] memory signatures,
        uint256 chainFeeAmount,
        uint256 gasLimit
    ) external {
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

            // Validate our responses came from the expected contract (Messaging Hub),
            // and expected function.
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
        if (msg.sender != address(_getWormholeRelayer())) {
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

        ChainData memory chainData = _getChainData(gethChainId);
        // Validate message came directly from MessagingHub on the source chain.
        if (chainData.messagingHub != srcAddr) {
            return;
        }

        uint8 payloadType = abi.decode(payload, (uint8));

        if (payloadType == 1) {
            // PayloadType = 1: Submitting fees from a foreign chain,
            //                  for a reported epoch.

            (, address srcFeeToken, uint256 amount) = abi.decode(
                payload,
                (uint8, address, uint256)
            );
            // Validate fee token address.
            if (chainData.feeTokenAddress != srcFeeToken) {
                _revert(_INVALID_PARAMETER_SELECTOR);
            }

            // If the Reward Manager is shutdown, transfer fees to DAO
            // instead of recording epoch rewards.
            if (_checkRewardManagerStatus(_getRewardManager())) {
                _transferFeeTokens(amount, _getDaoAddress());
                return;
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
            // payloadType = 3: Receive finalized epoch rewards data.

            (, uint256 chainLockedAmount) = abi.decode(
                payload,
                (uint8, uint256)
            );

            _recordEpochRewards(_getRewardManager(), chainLockedAmount);
        } else if (payloadType == 4) {
            // payloadType = 4: Indicates migrating a veCVE lock from the source
            //                  chain to this destination chain.

            (, address recipient, uint256 amount, bool continuousLock) = abi
                .decode(payload, (uint8, address, uint256, bool));

            cve.mintVeCVELock(amount);
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

        ChainData memory chainData = _getChainData(dstChainId);

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
            operator.messagingChainId != centralRegistry.GETHToMessagingChainId(
            dstChainId
        ) ||
            chainData.isSupported < 2
        ) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        amount = _pullFees(amount);

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

        uint16 wormholeChainId = _getWormholeData(dstChainId).chainId;

        if (wormholeChainId == 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }
        if (recipient == address(0)) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        gasLimit = _getGasLimit(gasLimit);

        if (payloadType == 4) {
            if (msg.sender != address(veCVE)) {
                _revert(_UNAUTHORIZED_SELECTOR);
            }

            ChainData memory chainData = _getChainData(dstChainId);

            // Validate that we are aiming for a supported chain.
            if (chainData.isSupported < 2) {
                _revert(_INVALID_PARAMETER_SELECTOR);
            }

            return
                _getWormholeRelayer().sendPayloadToEvm{
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
        _approveTokenIfNeeded(address(cve), address(tokenBridge), amount);

        uint64 sequence = tokenBridge.transferTokensWithPayload{
            value: _getMessageFee()
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
            chainId: _getWormholeCore().chainId(),
            sequence: sequence
        });

        return
            _getWormholeRelayer().sendVaasToEvm{
                value: msg.value - _getMessageFee()
            }(wormholeChainId, recipient, "", 0, gasLimit, vaaKeys);
    }

    /// PERMISSIONED EXTERNAL FUNCTIONS ///

    /// @notice Permissioned function that flips the pause status of the
    ///         Messaging Hub.
    function flipMessagingHubStatus() external {
        _checkDaoPermissions();

        // Possible outcomes:
        // If pause state is being turned off (state = false), then the
        // Messaging Hub is being turned back on which means isPaused will be
        // set to 1.
        //
        // If pause state is being turned on (state = true), then the
        // Messaging Hub is being turned off which means isPaused will be
        // set to 2.
        isPaused = isPaused == 2 ? 1 : 2;
    }

    /// @notice Withdraws gas tokens and fee tokens from the Protocol Messaging Hub
    ///         to the DAO address in order to depreciate or rebalance the
    ///         Protocol Messaging Hub.
    /// @dev This does not allow any loss of funds as authorized perms are
    ///      required to change the Protocol Messaging Hub, meaning in order to steal
    ///      funds a malicious actor would have had to compromise the whole
    ///      system already. Thus, we only need to check for DAO perms here.
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
        (nativeFee, ) = _getWormholeRelayer()
            .quoteEVMDeliveryPrice(
                _getWormholeData(dstChainId).chainId,
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

        if (payload.length == 0) {
            payload = abi.encode(uint8(1), feeToken, amount);
        }

        if (
            address(circleTokenMessenger) != address(0) &&
            circleTokenMessenger.remoteTokenMessengers(
                _getCCTPDomain(dstChainId)
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
        WormholeData memory wormholeData = _getWormholeData(dstChainId);

        _approveTokenIfNeeded(feeToken, address(circleTokenMessenger), amount);

        uint64 nonce = circleTokenMessenger.depositForBurnWithCaller(
            amount,
            _getCCTPDomain(dstChainId),
            bytes32(uint256(uint160(to))),
            feeToken,
            bytes32(uint256(uint160(wormholeData.relayer)))
        );

        IWormholeRelayer.MessageKey[]
            memory messageKeys = new IWormholeRelayer.MessageKey[](1);
        messageKeys[0] = IWormholeRelayer.MessageKey(
            2, // CCTP_KEY_TYPE
            abi.encodePacked(_getCCTPDomain(block.chainid), nonce)
        );

        wormholeRelayer.sendToEvm{ value: wormholeFee }(
            wormholeData.chainId,
            to,
            payload,
            0,
            0,
            _getGasLimit(gasLimit),
            wormholeData.chainId,
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
        uint256 epochRewardsPerCVE = (feeTokensOverall * WAD) / totalPoints;

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
            _recordEpochRewards(rewardManager, epochRewardsPerCVE);
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
                _getChainData(currentChainId).messagingHub,
                feeTokensForChain,
                abi.encode(3, epochRewardsPerCVE),
                gasLimit
            );
        }
    }

    /// @dev Pulls `amount` fee tokens from the fee accumulator to aggregate fees.
    function _pullFees(uint256 amount) internal returns (uint256) {
        return IFeeAccumulator(centralRegistry.feeAccumulator()).pullFees(amount);
    }

    /// @dev Transfers `amount` `feeToken` to `recipient`.
    function _transferFeeTokens(uint256 amount, address recipient) internal {
        SafeTransferLib.safeTransfer(feeToken, recipient, amount);
    }

    function _recordEpochRewards(IRewardManager rewardManager, uint256 epochRewardsPerCVE) internal {
        rewardManager.recordEpochRewards(epochRewardsPerCVE);
    }

    /// @dev Approves `token` `amount` to be spent by `spender`, if necessary.
    function _approveTokenIfNeeded(
        address token,
        address spender,
        uint256 amount
    ) internal {
        SwapperLib._approveTokenIfNeeded(token, spender, amount);
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
    function _getChainData(uint256 chainId) internal view returns (ChainData memory) {
        return centralRegistry.supportedChainData(chainId);
    }

    /// @dev Returns WormholeData struct for `chainId`.
    function _getWormholeData(uint256 chainId) internal view returns (WormholeData memory) {
        return centralRegistry.wormholeData(chainId);
    }

    /// @dev Returns the CCTP domain for `chainId`.
    function _getCCTPDomain(uint256 chainId) internal view returns (uint32) {
        return centralRegistry.cctpDomain(chainId);
    }

    /// @dev Returns the current Curvance DAO address.
    function _getDaoAddress() internal view returns (address) {
        return centralRegistry.daoAddress();
    }

    /// @dev Returns the amount of fee tokens currently held in this Protocol Messaging Hub.
    function _getFeeTokenHeld() internal view returns (uint256) {
        return IERC20(feeToken).balanceOf(address(this));
    }

    /// @dev Returns the next protocol epoch to deliver rewards for.
    function _getNextEpochToDeliver(IRewardManager rewardManager) internal view returns (uint256) {
        return rewardManager.nextEpochToDeliver();
    }

    /// @dev Returns the proper gas limit to use based on parameter input.
    ///      Fallsback to `_DEFAULT_GAS_LIMIT` if the input is 0.
    function _getGasLimit(uint256 gasLimit) internal pure returns (uint256) {
        return gasLimit == 0 ? _DEFAULT_GAS_LIMIT : gasLimit;
    }

    /// @dev Checks whether the Messaging Hub is paused or not.
    function _checkMessagingHubStatus() internal view {
        if (isPaused == 2) {
            revert ProtocolMessagingHub__MessagingHubPaused();
        }
    }

    /// @dev Checks whether the Reward Manager is shutdown or not.
    /// @return Returns true if the Reward Manager is shutdown.
    function _checkRewardManagerStatus(IRewardManager rewardManager) internal view returns (bool) {
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
