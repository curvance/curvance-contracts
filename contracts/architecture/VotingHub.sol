// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { EthCallQueryResponse, ParsedQueryResponse, QueryResponse, IWormhole } from "contracts/libraries/external/wormhole/QueryResponse.sol";

import { ICentralRegistry, ChainData } from "contracts/interfaces/ICentralRegistry.sol";
import { IMessagingHub, EmissionData } from "contracts/interfaces/IMessagingHub.sol";
import { ICVE } from "contracts/interfaces/ICVE.sol";
import { IVeCVE } from "contracts/interfaces/IVeCVE.sol";
import { IGaugeManager } from "contracts/interfaces/IGaugeManager.sol";

contract VotingHub is QueryResponse {
    /// CONSTANTS ///

    /// @notice Number of Protocol Epochs before rewards are halved,
    ///         26 epoch corresponds to roughly 1 year.
    uint256 public constant REWARD_HALVENING_RATE = 26;
    /// @notice Number of Protocol Eras, corresponds to how many different
    ///         periods there are with token emission incentives.
    /// @dev As the protocol moves from one era to another, emissions natively
    ///      halve per epoch.
    uint256 public constant PROTOCOL_REWARD_ERAS = 6;

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;
    /// @notice CVE contract address.
    ICVE public immutable cve;
    /// @notice VeCVE contract address.
    IVeCVE public immutable veCVE;
    /// @notice Address of the Gauge Manager.
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

    /// STORAGE ///

    /// @notice Start time that the voting hub starts, in unix time.
    uint256 public startTime;

    /// @notice The amount of CVE rewards allocated on this chain,
    ///         for an epoch.
    /// @dev Epoch # => CVE rewards allocated.
    mapping(uint256 => uint256) public emissionsAllocatedByEpoch;

    /// @notice The amount of CVE rewards allocated across all chains,
    ///         for an era. An era is a particular period in time in which
    ///         CVE rewards are constant, before a halvening event moves the
    ///         protocol to a new era.
    /// @dev Epoch # => CVE rewards allocated.
    mapping(uint256 => uint256) public targetEmissionAllocationByEra;

    /// EVENTS ///

    event EraEmissionsAllotmentSet(uint256 epochEmissionAllotment);

    /// ERRORS ///

    error VotingHub__Unauthorized();
    error VotingHub__InvalidParameter();

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        uint256 baseEmissionsPerEpoch
    ) QueryResponse(address(centralRegistry_.wormholeCore())) {
        centralRegistry = centralRegistry_;

        // Query epoch and token configuration directly to minimize potential
        // human error.
        cve = ICVE(centralRegistry.cve());
        veCVE = IVeCVE(centralRegistry.veCVE());
        gaugeManager = IGaugeManager(centralRegistry.gaugeManager());
        epochDuration = centralRegistry.EPOCH_DURATION();
        startTime = veCVE.nextEpochStartTime();

        _setEraTargetEmissions(baseEmissionsPerEpoch);
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
        _canSubmitQueries();

        ParsedQueryResponse memory r = parseAndVerifyQueryResponse(
            response,
            signatures
        );
        uint256 numResponses = r.responses.length;
        uint256[] memory chainIds = centralRegistry.getForeignChainIds();
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
        // Verify emission values are valid.
        (
            emissionsAllocatedByEpoch[epoch],
            emissionData,
            remoteEmissionData
        ) = _validateEmissionValues(
            emissionData,
            remoteEmissionData,
            numResponses,
            queryEmissionsAllocated(),
            totalEmissionsAllocated
        );

        // Set emissions for this chain.
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

    /// @notice Sets the token emission values for each protocol epoch based
    ///         on an initial emission value, by epoch.
    /// @param baseEmissionsPerEpoch The initial token emissions value that
    ///                              the protocol should allocate, per epoch.
    function setEraTargetEmissions(uint256 baseEmissionsPerEpoch) external {
        if (!centralRegistry.hasElevatedPermissions(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }
        _setEraTargetEmissions(baseEmissionsPerEpoch);
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Returns current token emissions allocated, for this epoch.
    function queryEmissionsAllocated() public view returns (uint256) {
        return emissionsAllocatedByEpoch[currentEpoch()];
    }

    /// @notice Returns current target token emissions, for this epoch.
    function currentTargetEmissions() public view returns (uint256) {
        return targetEmissionAllocationByEra[currentEra()];
    }

    /// @notice Returns current era number.
    function currentEra() public view returns (uint256) {
        return currentEpoch() / REWARD_HALVENING_RATE;
    }

    /// @notice Returns current epoch number.
    function currentEpoch() public view returns (uint256) {
        return epochOfTimestamp(block.timestamp);
    }

    /// @notice Returns epoch number of `timestamp`.
    /// @param timestamp Timestamp in seconds.
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

    /// @dev Sets the token emission values for each protocol epoch based on
    ///      an initial emission value, by epoch.
    /// @param epochEmissions The initial token emissions value that the
    ///                       protocol should allocate, per epoch.
    function _setEraTargetEmissions(uint256 epochEmissions) internal {
        uint256 numEras = PROTOCOL_REWARD_ERAS;

        for (uint256 i; i < numEras; ++i) {
            targetEmissionAllocationByEra[i] = epochEmissions;
            epochEmissions = epochEmissions / 2;
        }

        emit EraEmissionsAllotmentSet(epochEmissions);
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
        IGaugeManager cachedGaugeManager = gaugeManager;

        // Mint epoch gauge emissions to the Gauge Manager.
        cve.mintGaugeEmissions(
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
        IMessagingHub(centralRegistry.messagingHub()).sendEmissions(
            emissionData,
            dstChainId,
            gasLimit,
            epoch
        );
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

    /// @dev Internal helper for reverting efficiently.
    function _revert(uint256 s) internal pure {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, s)
            revert(0x1c, 0x04)
        }
    }
}
