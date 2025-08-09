// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";

import { EthCallQueryResponse, ParsedQueryResponse, QueryResponse } from "contracts/libraries/external/wormhole/QueryResponse.sol";

import { ICentralRegistry, ChainData } from "contracts/interfaces/ICentralRegistry.sol";
import { IMessagingHub, EmissionData } from "contracts/interfaces/IMessagingHub.sol";

import { IGaugeManager } from "contracts/interfaces/IGaugeManager.sol";
import { ICVE } from "contracts/interfaces/ICVE.sol";

import { IWormhole } from "contracts/interfaces/external/wormhole/IWormhole.sol";

/// @title Curvance Protocol Cross-Chain Voting and Emissions Hub
/// @notice Coordinates protocol-wide token emission allocation based on governance decisions
/// @dev VotingHub serves as the central coordinator for the Curvance tokenomics system by:
///      
///      1. Emission Management:
///         - Sets token emission values in GaugeManager for the local chain
///         - Coordinates emission distribution to other chains via MessagingHub
///         - Enforces the protocol's deflationary emission schedule across all chains
///      
///      2. Cross-Chain Validation:
///         - Uses Wormhole Cross-Chain Queries (CCQ) to verify emission data
///         - Validates that total emissions across all chains don't exceed protocol limits
///         - Ensures emission configurations are properly synchronized network-wide
///      
///      3. Tokenomics Implementation:
///         - Manages the halving emission schedule (26 epochs ≈ 1 year per era)
///         - Tracks emissions across multiple protocol eras (6 total eras)
///         - Enforces supply control by reducing emissions by 50% each era
///      
///      The contract implements strict verification of cross-chain data to prevent
///      manipulation, requiring Wormhole Guardian signatures. This ensures that
///      token emissions are correctly balanced across the entire Curvance ecosystem,
///      regardless of which chains users interact with.
///
contract VotingHub is QueryResponse {
    /// CONSTANTS ///

    /// @notice Number of Protocol Epochs before rewards are halved,
    ///         26 epoch corresponds to roughly 1 year.
    uint256 public constant REWARD_HALVENING_RATE = 26;
    /// @notice Number of Protocol Eras, corresponds to how many different
    ///         periods there are with token emission incentives.
    /// @dev As the protocol moves from one era to another, emissions natively
    ///      halve per epoch, this is localized to a voting hub deployment
    ///      meaning the number of eras can change when a new voting hub is
    ///      deployed.
    uint256 public constant PROTOCOL_REWARD_ERAS = 6;

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;
    /// @notice Gauge Manager contract address, distributes native token
    ///         rewards to depositors and lenders inside the Curvance
    ///         Protocol based on decentralized governance outcomes.
    IGaugeManager public immutable gaugeManager;
    /// @notice The length of one protocol epoch, in seconds.
    uint256 public immutable epochDuration;

    /// @dev `bytes4(keccak256(bytes("VotingHub__Unauthorized()")))`.
    uint256 internal constant _UNAUTHORIZED_SELECTOR = 0xef474362;
    /// @dev `bytes4(keccak256(bytes("VotingHub__InvalidParameter()")))`.
    uint256 internal constant _INVALID_PARAMETER_SELECTOR = 0x10e2435f;
    /// @dev `keccak256(bytes("queryEmissionsAllocated()"))`.
    bytes4 internal constant _QUERY_EMISSIONS_ALLOCATED_SELECTOR =
        bytes4(hex"a214a94e");

    /// ERRORS ///

    error VotingHub__Unauthorized();
    error VotingHub__InvalidParameter();

    /// CONSTRUCTOR ///

    constructor(ICentralRegistry cr) QueryResponse(address(cr.crosschainCore())) {
        CentralRegistryLib._isCentralRegistry(cr);
        centralRegistry = cr;

        // Query epoch and token configuration directly to minimize potential
        // human error.
        gaugeManager = IGaugeManager(centralRegistry.gaugeManager());
        epochDuration = centralRegistry.EPOCH_DURATION();
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Executes new token emission values of the protocol for this
    ///         chain, and potentially other remote chains. Validates the
    ///         total number of token emissions allocated this epoch across
    ///         all chains via Wormhole Querying.
    /// @dev Emission values across all chains are validated by decoding the
    ///      `response` and `signatures` containing the desired values.
    /// @param response The Wormhole query response.
    /// @param signatures The wormhole signatures corresponding to the query
    ///                   response value.
    /// @param gasLimit Array containing gas limit values for each remote
    ///                 chain message, 0 = default value inside messaging hub.
    /// @param emissionData Struct containing information on emission
    ///                     configuration.
    ///                     Containing values:
    ///                     1. The total amount of token emissions to allocate
    ///                        to the Gauge Manager.
    ///                     2. The token contract addresses receiving
    ///                        emissions.
    ///                     3. The emission amounts that each token should
    ///                        receive.
    /// @param remoteEmissionData Array of structs containing information on
    ///                           emission configuration for each remote
    ///                           chain.
    ///                           Containing values:
    ///                           1. The total amount of token emissions to
    ///                              allocate to the Gauge Manager.
    ///                           2. The token contract addresses receiving
    ///                              emissions.
    ///                           3. The emission amounts that each token
    ///                              should receive.
    function executeEmissionConfiguration(
        bytes calldata response,
        IWormhole.Signature[] calldata signatures,
        uint256[] calldata gasLimit,
        EmissionData memory emissionData,
        EmissionData[] memory remoteEmissionData
    ) external {
        if (
            !centralRegistry.hasHarvestPermissions(msg.sender) &&
            !centralRegistry.hasDaoPermissions(msg.sender)
        ) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        _ensureNonEmptyEmissionConfigParameters(
            response,
            signatures,
            gasLimit,
            emissionData,
            remoteEmissionData
        );

        ParsedQueryResponse memory r = parseAndVerifyQueryResponse(
            response,
            signatures
        );
        uint256 numResponses = r.responses.length;
        uint256[] memory chainIds = centralRegistry.foreignChainIds();
        if (numResponses != chainIds.length) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        uint256 totalEmissionsAllocated;
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
            // expected contract (Voting Hub), and expected function.
            validAddresses[0] = _getChainData(chainIds[i]).votingHub;
            validFunctionSignatures[0] = _QUERY_EMISSIONS_ALLOCATED_SELECTOR;
            validateMultipleEthCallData(
                eqr.result,
                validAddresses,
                validFunctionSignatures
            );

            // Validate that the result is a uint256.
            if (eqr.result[0].result.length != 32) {
                _revert(_INVALID_PARAMETER_SELECTOR);
            }

            // Document emissions on current foreign chain.
            totalEmissionsAllocated += abi.decode(
                eqr.result[0].result,
                (uint256)
            );
        }

        uint256 epoch = currentEpoch();
        uint256 emissionsAllocated;

        // Verify emission values are valid.
        (
            emissionsAllocated,
            emissionData,
            remoteEmissionData
        ) = _validateEmissionValues(
            emissionData,
            remoteEmissionData,
            numResponses,
            queryEmissionsAllocated(),
            totalEmissionsAllocated
        );

        centralRegistry.setEmissionsAllocatedByEpoch(
            epoch,
            emissionsAllocated
        );

        // Set emissions for this chain, this will natively fail in
        // `GaugeManager` if `epoch` has not started yet.
        _setEmissions(emissionData, epoch);

        // Submit emissions for remote chains.
        for (uint256 i; i < numResponses; ++i) {
            _sendEmissions(
                remoteEmissionData[i],
                chainIds[i],
                gasLimit[i],
                epoch
            );
        }
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Returns the number of Protocol Eras, corresponds to how many
    ///         different periods there are with token emission incentives.
    /// @return The number of Protocol Eras.
    function protocolRewardEras() public pure returns (uint256) {
        return PROTOCOL_REWARD_ERAS;
    }

    /// @notice Returns current token emissions allocated, for this epoch.
    /// @return The current token emissions allocated.
    function queryEmissionsAllocated() public view returns (uint256) {
        return centralRegistry.emissionsAllocatedByEpoch(currentEpoch());
    }

    /// @notice Returns current target token emissions, for this epoch.
    /// @return The current target token emissions.
    function currentTargetEmissions() public view returns (uint256) {
        return centralRegistry.targetEmissionAllocationByEra(currentEra());
    }

    /// @notice Returns current era number.
    /// @return The current era number.
    function currentEra() public view returns (uint256) {
        return currentEpoch() / REWARD_HALVENING_RATE;
    }

    /// @notice Returns current epoch number.
    /// @return The current epoch number.
    function currentEpoch() public view returns (uint256) {
        return epochOfTimestamp(block.timestamp);
    }

    /// @notice Returns epoch number of `timestamp`.
    /// @param timestamp Timestamp in seconds.
    /// @return The epoch number of the timestamp.
    function epochOfTimestamp(
        uint256 timestamp
    ) public view returns (uint256) {
        uint256 cachedGenesisEpoch = centralRegistry.genesisEpoch();

        // Rounds down intentionally.
        return
            timestamp < cachedGenesisEpoch
                ? 0
                : (timestamp - cachedGenesisEpoch) / epochDuration;
    }

    /// INTERNAL FUNCTIONS ///

    /// @dev Returns ChainData struct for `chainId`.
    /// @param chainId The chain ID to get ChainData for.
    /// @return chainData The ChainData struct for the given chain ID.
    function _getChainData(
        uint256 chainId
    ) internal view returns (ChainData memory chainData) {
        chainData = centralRegistry.supportedChainData(chainId);
        // Validate that we are aiming for a supported chain.
        if (chainData.isSupported < 2) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }
    }

    /// @dev Validates that the input emission values are within the
    ///      constraints of the protocol.
    /// @param emissionData Struct containing information on emission
    ///                     configuration.
    ///                     Containing values:
    ///                     1. The total amount of token emissions to allocate
    ///                        to the Gauge Manager.
    ///                     2. The token contract addresses receiving
    ///                        emissions.
    ///                     3. The emission amounts that each token should
    ///                        receive.
    /// @param remoteEmissionData Array of structs containing information on
    ///                           emission configuration for each remote
    ///                           chain.
    ///                           Containing values:
    ///                           1. The total amount of token emissions to
    ///                              allocate to the Gauge Manager.
    ///                           2. The token contract addresses receiving
    ///                              emissions.
    ///                           3. The emission amounts that each token
    ///                              should receive.
    /// @param numRemoteChains The number of remote chains to receive
    ///                        token emissions.
    /// @param cachedEmissionsAllocated The emissions currently allocated,
    ///                                 for the epoch being validated.
    /// @param totalEmissionsAllocated The total emissions allocated, for the
    ///                                epoch being validated.
    /// @return cachedEmissionsAllocated The emissions currently allocated,
    ///                                 for the epoch being validated.
    /// @return emissionData The emission data for the current chain.
    /// @return remoteEmissionData The emission data for the remote chains.
    function _validateEmissionValues(
        EmissionData memory emissionData,
        EmissionData[] memory remoteEmissionData,
        uint256 numRemoteChains,
        uint256 cachedEmissionsAllocated,
        uint256 totalEmissionsAllocated
    )
        internal
        view
        returns (uint256, EmissionData memory, EmissionData[] memory)
    {
        uint256[] memory emissions = emissionData.emissions;
        uint256 numTokens = emissionData.tokens.length;
        uint256 emissionsTotal;

        if (numTokens != emissions.length) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Allocate emission rewards for this chain.
        for (uint256 j; j < numTokens; ++j) {
            emissionsTotal += emissions[j];
        }

        emissionData.emissionTotal = emissionsTotal;
        cachedEmissionsAllocated += emissionsTotal;
        emissionsTotal = 0;

        EmissionData memory cachedEmissionData;

        // Allocate emission rewards for remote chains.
        for (uint256 i; i < numRemoteChains; ++i) {
            cachedEmissionData = remoteEmissionData[i];
            numTokens = cachedEmissionData.tokens.length;
            emissions = cachedEmissionData.emissions;

            if (numTokens != emissions.length) {
                _revert(_INVALID_PARAMETER_SELECTOR);
            }

            for (uint256 j; j < numTokens; ++j) {
                emissionsTotal += emissions[j];
            }

            remoteEmissionData[i].emissionTotal = emissionsTotal;
            cachedEmissionsAllocated += emissionsTotal;
            emissionsTotal = 0;
        }

        if (
            totalEmissionsAllocated + cachedEmissionsAllocated >
            currentTargetEmissions()
        ) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        return (cachedEmissionsAllocated, emissionData, remoteEmissionData);
    }

    /// @dev Sets new token emissions values to Gauge Managers on this chain,
    ///      for `epoch`.
    /// @param emissionData Struct containing information on emission
    ///                     configuration.
    ///                     Containing values:
    ///                     1. The total amount of token emissions to allocate
    ///                        to the Gauge Manager.
    ///                     2. The token contract addresses receiving
    ///                        emissions.
    ///                     3. The emission amounts that each token should
    ///                        receive.
    /// @param epoch The epoch having its token emission values set.
    function _setEmissions(
        EmissionData memory emissionData,
        uint256 epoch
    ) internal {
        // If there are no emissions to distribute we can skip emission
        // configuration logic.
        if (emissionData.emissionTotal == 0) {
            return;
        }

        IGaugeManager cachedGaugeManager = gaugeManager;

        // Mint epoch gauge emissions to the Gauge Manager.
        ICVE(centralRegistry.cve()).mintGaugeEmissions(
            address(cachedGaugeManager),
            emissionData.emissionTotal
        );

        // Set upcoming epoch emissions for voted configuration.
        cachedGaugeManager.setEmissionRates(
            epoch,
            emissionData.tokens,
            emissionData.emissions
        );
    }

    /// @dev Sets new token emissions values to Gauge Managers on a remote chain,
    ///      for `epoch`.
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
    function _sendEmissions(
        EmissionData memory emissionData,
        uint256 dstChainId,
        uint256 gasLimit,
        uint256 epoch
    ) internal {
        // If there are no emissions to distribute we can skip emission
        // configuration logic.
        if (emissionData.emissionTotal == 0) {
            return;
        }

        IMessagingHub(centralRegistry.messagingHub()).sendEmissions(
            emissionData,
            dstChainId,
            gasLimit,
            epoch
        );
    }

    /**
     * @dev Ensures that all emission configuration parameters provided
     *      to `executeEmissionConfiguration` are non-empty and valid.
     * @param response The Wormhole query response. Must not be empty.
     * @param signatures The Wormhole signatures corresponding to the
     *      query response. Must not be empty.
     * @param gasLimit An array of gas limit values for each remote
     *      chain message. Must not be empty.
     * @param emissionData The emission configuration data for the
     *      current chain. Must include non-empty arrays for tokens and
     *      emissions.
     * @param remoteEmissionData An array of emission configuration data
     *      for remote chains. Must not be empty.
     * @notice This function reverts if any of the provided parameters
     *      are empty or invalid. It ensures that all required data is
     *      available for the emission configuration process.
     *      custom error VotingHub__InvalidParameter Emitted when any of
     *      the input parameters are empty or invalid.
     */
    function _ensureNonEmptyEmissionConfigParameters(
        bytes calldata response,
        IWormhole.Signature[] calldata signatures,
        uint256[] calldata gasLimit,
        EmissionData memory emissionData,
        EmissionData[] memory remoteEmissionData
    ) internal pure {
        if (response.length == 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        if (signatures.length == 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        if (gasLimit.length == 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        if (emissionData.tokens.length == 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        if (emissionData.emissions.length == 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        if (remoteEmissionData.length == 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
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
}
