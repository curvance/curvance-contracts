// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { DENOMINATOR } from "contracts/libraries/Constants.sol";

import { ERC165 } from "contracts/libraries/external/ERC165.sol";
import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { ActionRegistry } from "contracts/libraries/ActionRegistry.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IEToken } from "contracts/interfaces/IEToken.sol";
import { ICentralRegistry, ChainData } from "contracts/interfaces/ICentralRegistry.sol";
import { ITimelock } from "contracts/interfaces/ITimelock.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { IVotingHub } from "contracts/interfaces/IVotingHub.sol";
import { IWormhole } from "contracts/interfaces/external/wormhole/IWormhole.sol";
import { IWormholeRelayer } from "contracts/interfaces/external/wormhole/IWormholeRelayer.sol";
import { ITokenMessenger } from "contracts/interfaces/external/wormhole/ITokenMessenger.sol";
import { IMessageTransmitter } from "contracts/interfaces/external/wormhole/IMessageTransmitter.sol";
import { ITokenBridge } from "contracts/interfaces/external/wormhole/ITokenBridge.sol";

/// @title Curvance DAO Central Registry.
/// @notice Manages permissions and protocol contract registration
///         within the Curvance Protocol.
/// @dev The Central Registry acts as a single source of truth for the Curvance
///      Protocol. This covers everything from multichain operations, to
///      contract locations, to protocol fees, to protocol multipliers
///      associated with various actions.
///
///      Permissions inside Curvance have two tiers:
///      - Standard DAO permissions: This is associated with actions that
///        reduce risk inside the Curvance system, or need to be continually
///        managed by the DAO elected operating team.
///      - Elevated DAO permissions: This is associated with actions that
///        increase risk inside the Curvance system, the most sensitive of
///        controls. This requires a 7-day delay from the DAO elected
///        operating team for any action, or the "Emergency Council" made up
///        of both Curvance Collective members and external stakeholders.
///
///      All values inside Curvance are entered in basis point form. However,
///      Fees are recorded internally in `WAD` format, or 1e18, rather than
///      basis points, or 1e4. This is for greater precision in computations.
///      As a result, you will see multiplier values stored in 1e4 form,
///      and fees stored in 1e18 form.
///
///      The Central Registry manages the plugin system, creating a new
///      primitive allowing for "delegation" of specific actions to any
///      address, providing that address authority on behalf of the user in
///      the smart contract. Approvals can also be mass revoked via the
///      "approval index" system. By incrementing one's approval index, a user
///      can revoke all approved address' delegation privileges at the same
///      time. This facilitates better management of approvals inside
///      Curvance versus conventional implementations on top of the EVM.
///
///      The Central Registry also manages the locking system,
///      which operates as an optional 2FA setting to reduce the potential of
///      a successful phishing attempt on a user. A cooldown can be set for
///      token transfers and plugin delegation that activates after an action
///      lock is enabled.
///
contract CentralRegistry is ERC165, ActionRegistry {
    /// CONSTANTS ///

    /// @notice The length of one protocol epoch, in seconds.
    uint256 public constant EPOCH_DURATION = 2 weeks;

    /// @notice Sequencer uptime oracle feed address for L2s.
    address public immutable sequencer;

    /// @dev bytes4(keccak256(bytes("CentralRegistry__ParametersMisconfigured()")))
    uint256 internal constant _PARAMETERS_MISCONFIGURED_SELECTOR = 0xa5bb570d;
    /// @dev bytes4(keccak256(bytes("CentralRegistry__Unauthorized()")))
    uint256 internal constant _UNAUTHORIZED_SELECTOR = 0xe675838a;
    /// @dev bytes4(keccak256(bytes("CentralRegistry__EpochHasStarted()")))
    uint256 internal constant _EPOCH_HAS_STARTED_SELECTOR = 0xffb4e740;

    /// @dev A fixed key to use in transient storage for Atlas OEV status
    bytes32 internal constant TRANSIENT_ATLAS_OEV_KEY = 0x1234567890123456789012345678901234567890123456789012345678901234;

    /// STORAGE ///

    /// @notice Genesis Epoch timestamp.
    uint256 public genesisEpoch;

    // FEE TOKEN

    /// @notice Address of fee token which Curvance Protocol compounds
    ///         strategy fees into for distribution.
    address public feeToken;

    // DAO GOVERNANCE OPERATORS

    /// @notice DAO multisig, the primary address that the Curvance
    ///         Collective operates from.
    address public daoAddress;
    /// @notice DAO multisig, with an execution time delay.
    address public timelock;
    /// @notice Multi-protocol multisig, intended to be used only for
    ///         emergencies.
    address public emergencyCouncil;

    // CURVANCE TOKEN CONTRACTS

    /// @notice CVE contract address.
    address public cve;
    /// @notice veCVE contract address.
    address public veCVE;

    // DAO CONTRACTS DATA

    /// @notice Reward Manager contract address, distributes rewards in
    ///         `feeToken` to token lockers every epoch.
    address public rewardManager;
    /// @notice Gauge Manager contract address, distributes native token
    ///         rewards to depositors and lenders inside the Curvance
    ///         Protocol based on decentralized governance outcomes.
    address public gaugeManager;
    /// @notice Voting Hub contract address, receives decentralized governance
    ///         vote outcomes to update onchain across all blockchains.
    address public votingHub;
    /// @notice Messaging Hub contract address, processes crosschain messages
    ///         across all supported blockchains.
    address public messagingHub;
    /// @notice Oracle Manager contract address, manages oracle prices
    ///         for supported assets.
    address public oracleManager;
    /// @notice Fee Manager contract address, manages fees for decentralized
    ///         strategies for distribution.
    address public feeManager;

    // CROSS-CHAIN MESSAGING DATA

    /// @notice Address of Wormhole core contract.
    IWormhole public wormholeCore;
    /// @notice Address of Wormhole Relayer.
    IWormholeRelayer public wormholeRelayer;

    /// @notice Address of Circle Token Messenger.
    ITokenMessenger public circleTokenMessenger;

    /// @notice Address of Circle Token Messenger.
    IMessageTransmitter public circleMessageTransmitter;

    /// @notice Wormhole TokenBridge.
    ITokenBridge public tokenBridge;

    /// @notice CCTP Domain.
    uint32 public cctpDomain;

    // PROTOCOL FEE VALUES

    // Values are always set in `Basis Points` (1e4), fee values are converted
    // and stored in `WAD` while multipliers stay in `DENOMINATOR`.

    /// @notice Fee on yield generated for compounding vaults.
    uint256 public protocolCompoundFee = 100 * 1e14;
    /// @notice Fee on yield generated in vaults distributed to veCVE lockers.
    uint256 public protocolYieldFee = 1500 * 1e14;
    /// @notice Joint fee value so that we can perform one less external call
    ///         in vault contracts.
    uint256 public protocolHarvestFee = protocolCompoundFee + protocolYieldFee;
    /// @notice Protocol fee on leverage usage.
    uint256 public protocolLeverageFee;
    /// @notice Protocol slippage limit for safe swap.
    uint256 public slippageLimit = 1000 * 1e14;

    // ACTION MULTIPLIER VALUES

    /// @notice Penalty multiplier for unlocking a veCVE lock early.
    uint256 public earlyUnlockPenaltyMultiplier;
    /// @notice Voting power multiplier for Continuous Lock mode.
    uint256 public voteBoostMultiplier;
    /// @notice Gauge rewards multiplier for locking gauge emissions.
    uint256 public lockBoostMultiplier;

    // PROTOCOL INTEREST RATE FEES

    /// @notice Debt token fee on interest generated.
    /// @dev Market Manager => Protocol Interest Factor, in `WAD`.
    mapping(address => uint256) public protocolInterestFactor;

    // DAO PERMISSION DATA

    /// @notice Whether an address has DAO permissioning or not.
    /// @dev Address => DAO permission status.
    mapping(address => bool) public hasDaoPermissions;
    /// @notice Whether an address has Elevated DAO permissioning or not.
    /// @dev Address => Elevated DAO permission status.
    mapping(address => bool) public hasElevatedPermissions;
    /// @notice Whether an address has lock creation permissioning or not.
    /// @dev Address => Lock creation permission status.
    mapping(address => bool) public hasLockingPermissions;

    // MULTICHAIN CONFIGURATION DATA

    // We store this data redundantly so that we can quickly get whatever
    // output we need, with low gas overhead.

    /// @notice The number of chains supported by the Curvance Protocol.
    uint256 public supportedChains;
    /// @notice Array of Chain IDs recorded in the Messaging Layers Chain ID
    ///         format.
    uint256[] public foreignChainIds;
    /// @notice Address array for all Curvance markets on this chain.
    address[] public marketManagers;

    /// @notice ChainId => 2 = supported; 1 = unsupported.
    mapping(uint256 => ChainData) public supportedChainData;
    /// @notice Messaging ChainId => GETH ChainId.
    mapping(uint16 => uint256) public messagingToGETHChainId;
    /// @notice GETH ChainId => Messaging ChainId.
    mapping(uint256 => uint16) public GETHToMessagingChainId;

    /// @notice The amount of CVE rewards allocated on this chain,
    ///         for an epoch.
    /// @dev Epoch # => CVE rewards allocated.
    mapping(uint256 => uint256) public emissionsAllocatedByEpoch;

    /// @notice The amount of CVE rewards allocated across all chains,
    ///         for an era. An era is a particular period in time in which
    ///         CVE rewards are constant, before a halvening event moves the
    ///         protocol to a new era.
    /// @dev Era # => CVE rewards allocated.
    mapping(uint256 => uint256) public targetEmissionAllocationByEra;

    // DAO CONTRACT MAPPINGS
    
    /// @notice Specifies if an address is a harvester or not.
    mapping(address => bool) public isHarvester;
    /// @notice Specifies if an address is the market manager or not.
    mapping(address => bool) public isMarketManager;
    /// @notice Target contract such as 1inch => calldata checker.
    mapping(address => address) public externalCalldataChecker;
    /// @notice Specifies if an address is a multiCallProvider contract.
    mapping(address => bool) public isMulticallProvider;
    /// @notice Target contract for external calldata => Multi call checker
    mapping(address => address) public multicallChecker;

    /// EVENTS ///

    event GenesisEpochSet(uint256 newGenesisEpoch);
    event FeeSet(string indexed fee, uint256 newFee);
    event FeeTokenSet(address newAddress);
    event SlippageLimit(uint256 newSlippage);
    event InterestFeeSet(address indexed market, uint256 newFee);
    event MultiplierSet(string indexed multiplier, uint256 newMultiplier);
    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );
    event NewTimelockConfiguration(
        address indexed previousTimelock,
        address indexed newTimelock
    );
    event EmergencyCouncilTransferred(
        address indexed previousEmergencyCouncil,
        address indexed newEmergencyCouncil
    );
    event CoreContractSet(string indexed contractType, address newAddress);
    event NewCurvanceContract(string indexed contractType, address newAddress);
    event RemovedCurvanceContract(
        string indexed contractType,
        address removedAddress
    );
    event WormholeCoreSet(address newAddress);
    event WormholeRelayerSet(address newAddress);
    event CircleTokenMessengerSet(address newAddress);
    event MessageTransmitterSet(address newAddress);
    event TokenBridgeSet(address newAddress);
    event CCTPDomainSet(uint32 newDomain);
    event NewChainAdded(uint256 chainId, address relayer);
    event RemovedChain(
        uint256 chainId,
        address messagingHub,
        address votingHub
    );
    event CalldataCheckerSet(
        string indexed calldataType,
        address targetAddress,
        address calldataChecker
    );
    event MulticallProviderSet(address provider, bool supportedStatus);
    event EraEmissionsAllotmentSet(uint256 epochEmissionAllotment);

    /// ERRORS ///

    error CentralRegistry__InvalidFeeToken();
    error CentralRegistry__ParametersMisconfigured();
    error CentralRegistry__Unauthorized();
    error CentralRegistry__EpochHasStarted();

    /// CONSTRUCTOR ///

    constructor(
        address daoAddress_,
        address timelock_,
        address emergencyCouncil_,
        uint256 genesisEpoch_,
        address sequencer_,
        address feeToken_
    ) {
        if (feeToken_ == address(0)) {
            revert CentralRegistry__InvalidFeeToken();
        }

        if (daoAddress_ == address(0)) {
            daoAddress_ = msg.sender;
        }

        if (timelock_ == address(0)) {
            timelock_ = msg.sender;
        }

        if (emergencyCouncil_ == address(0)) {
            emergencyCouncil_ = msg.sender;
        }

        // Check to make sure that genesis epoch is at least at the beginning
        // of 2022 (Jan 1 12:00 EST) so we know the value is not accidently
        // misconverted or missing with a value of 0.
        if (genesisEpoch_ < 1640926800) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        // Configure DAO permission data.
        daoAddress = daoAddress_;
        timelock = timelock_;
        emergencyCouncil = emergencyCouncil_;

        // Provide base dao permissioning to `daoAddress`,
        // `timelock`, `emergencyCouncil`.
        hasDaoPermissions[daoAddress] = true;
        hasDaoPermissions[timelock] = true;
        hasDaoPermissions[emergencyCouncil] = true;

        // Provide elevated dao permissioning to `timelock`,
        // `emergencyCouncil`.
        hasElevatedPermissions[timelock] = true;
        hasElevatedPermissions[emergencyCouncil] = true;

        genesisEpoch = genesisEpoch_;
        sequencer = sequencer_;

        feeToken = feeToken_;

        emit OwnershipTransferred(address(0), daoAddress_);
        emit NewTimelockConfiguration(address(0), timelock_);
        emit EmergencyCouncilTransferred(address(0), emergencyCouncil_);
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Withdraw fee token from central registry.
    function withdrawFee() external {
        _checkDaoPermissions();

        SafeTransferLib.safeTransfer(
            feeToken,
            daoAddress,
            IERC20(feeToken).balanceOf(address(this))
        );
    }

    /// @notice Withdraws all protocol reserve fees from a eToken
    ///         from interest generated and liquidations.
    /// @param eTokens Array of eToken addresses to withdraw fees from.
    function withdrawReservesMulti(address[] calldata eTokens) external {
        // Match permissioning check to normal withdrawReserves().
        _checkDaoPermissions();

        uint256 numTokens = eTokens.length;
        if (numTokens == 0) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        IEToken eToken;

        for (uint256 i; i < numTokens; ) {
            eToken = IEToken(eTokens[i++]);
            // Revert if somehow a misconfigured token made it in here.
            if (eToken.isPToken()) {
                _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
            }

            eToken.processWithdrawReserves();
        }
    }

    /// @notice Sets fee token address.
    /// @dev Only callable on a 7 day delay or by the Emergency Council.
    ///      Only settable once. Emits a {FeeTokenSet} event.
    /// @param newFeeToken The new address of fee token.
    function setFeeToken(address newFeeToken) external {
        // If the contract is already set and needs to be updated, make sure
        // reward system as not already started, ossifying contracts.
        if (feeToken != address(0)) {
            _checkGenesisEpochHasNotStarted();
        }

        _checkElevatedPermissions();

        feeToken = newFeeToken;
        emit FeeTokenSet(newFeeToken);
    }

    /// @notice Sets a new genesis epoch.
    /// @dev Only callable by the Emergency Council.
    ///      Emits a {GenesisEpochSet} event.
    /// @param newGenesisEpoch The new genesis epoch.
    function setGenesisEpoch(uint256 newGenesisEpoch) external {
        // Its not possible for `genesisEpoch` to be 0 based on constructor
        // restrictions, so we do not need to check for 0 input here as this
        // check would catch `newGenesisEpoch` == 0.
        if (newGenesisEpoch < genesisEpoch) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        _checkElevatedPermissions();
        _checkGenesisEpochHasNotStarted();

        genesisEpoch = newGenesisEpoch;

        emit GenesisEpochSet(newGenesisEpoch);
    }

    /// @notice Sets a CVE contract address.
    /// @dev Only callable on a 7 day delay or by the Emergency Council.
    ///      Only settable once. Emits a {CoreContractSet} event.
    /// @param newCVE The new address of cve.
    function setCVE(address newCVE) external {
        // If the contract is already set and needs to be updated, make sure
        // reward system as not already started, ossifying contracts.
        if (cve != address(0)) {
            _checkGenesisEpochHasNotStarted();
        }

        _checkElevatedPermissions();

        cve = newCVE;
        emit CoreContractSet("CVE", newCVE);
    }

    /// @notice Sets a veCVE contract address.
    /// @dev Only callable on a 7 day delay or by the Emergency Council.
    ///      Only settable once. Emits a {CoreContractSet} event.
    /// @param newVeCVE The new address of veCVE.
    function setVeCVE(address newVeCVE) external {
        // If the contract is already set and needs to be updated, make sure
        // reward system as not already started, ossifying contracts.
        if (veCVE != address(0)) {
            _checkGenesisEpochHasNotStarted();
        }

        _checkElevatedPermissions();

        veCVE = newVeCVE;
        emit CoreContractSet("VeCVE", newVeCVE);
    }

    /// @notice Sets a new Reward Manager contract address.
    /// @dev Only callable on a 7 day delay or by the Emergency Council.
    ///      Emits a {CoreContractSet} event.
    ///      Can only be set once.
    /// @param newRewardManager The new address of rewardManager.
    function setRewardManager(address newRewardManager) external {
        // If the contract is already set and needs to be updated, make sure
        // reward system as not already started, ossifying contracts.
        if (rewardManager != address(0)) {
            _checkGenesisEpochHasNotStarted();
        }

        _checkElevatedPermissions();

        rewardManager = newRewardManager;
        emit CoreContractSet("Reward Manager", newRewardManager);
    }

    /// @notice Sets a new Gauge Manager contract address.
    /// @dev Only callable on a 7 day delay or by the Emergency Council.
    ///      Emits a {CoreContractSet} event.
    ///      Can only be set once.
    /// @param newGaugeManager The new address of Gauge Manager.
    function setGaugeManager(address newGaugeManager) external {
        if (gaugeManager != address(0)) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        _checkElevatedPermissions();

        gaugeManager = newGaugeManager;
        emit CoreContractSet("Gauge Manager", newGaugeManager);
    }

    /// @notice Sets a new voting hub contract address.
    /// @dev Only callable on a 7 day delay or by the Emergency Council.
    ///      Emits a {CoreContractSet} event.
    /// @param newVotingHub The new address of votingHub.
    function setVotingHub(address newVotingHub) external {
        _checkElevatedPermissions();

        votingHub = newVotingHub;
        emit CoreContractSet("Voting Hub", newVotingHub);
    }

    /// @notice Sets a new messaging hub contract address.
    /// @dev Only callable on a 7 day delay or by the Emergency Council.
    ///      Emits a {CoreContractSet} event.
    /// @param newMessagingHub The new address of messagingHub.
    function setMessagingHub(address newMessagingHub) external {
        _checkElevatedPermissions();

        messagingHub = newMessagingHub;
        emit CoreContractSet("Messaging Hub", newMessagingHub);
    }

    /// @notice Sets a new Oracle Manager contract address.
    /// @dev Only callable on a 7 day delay or by the Emergency Council.
    ///      Emits a {CoreContractSet} event.
    /// @param newOracleManager The new address of oracleManager.
    function setOracleManager(address newOracleManager) external {
        _checkElevatedPermissions();

        oracleManager = newOracleManager;
        emit CoreContractSet("Oracle Manager", newOracleManager);
    }

    /// @notice Sets a new Fee Manager contract address.
    /// @dev Only callable on a 7 day delay or by the Emergency Council.
    ///      Emits a {CoreContractSet} event.
    /// @param newFeeManager The new address of feeManager.
    function setFeeManager(address newFeeManager) external {
        _checkElevatedPermissions();

        feeManager = newFeeManager;
        emit CoreContractSet("Fee Manager", newFeeManager);
    }

    /// @notice Sets a new Wormhole Core contract address.
    /// @dev Only callable on a 7 day delay or by the Emergency Council.
    ///      Emits a {WormholeCoreSet} event.
    /// @param newWormholeCore The new address of WormholeCore.
    function setWormholeCore(address newWormholeCore) external {
        _checkElevatedPermissions();

        wormholeCore = IWormhole(newWormholeCore);
        emit WormholeCoreSet(newWormholeCore);
    }

    /// @notice Sets a new WormholeRelayer contract address.
    /// @dev Only callable on a 7 day delay or by the Emergency Council.
    ///      Emits a {WormholeRelayerSet} event.
    /// @param newWormholeRelayer The new address of wormholeRelayer.
    function setWormholeRelayer(address newWormholeRelayer) external {
        _checkElevatedPermissions();

        wormholeRelayer = IWormholeRelayer(newWormholeRelayer);
        emit WormholeRelayerSet(newWormholeRelayer);
    }

    /// @notice Sets an address of Circle TokenMessenger contract.
    /// @dev Only callable on a 7 day delay or by the Emergency Council.
    ///      Emits a {CircleTokenMessengerSet} event.
    /// @param newCircleTokenMessenger The new address of Circle TokenMessenger.
    function setCircleTokenMessenger(
        address newCircleTokenMessenger
    ) external {
        _checkElevatedPermissions();

        circleTokenMessenger = ITokenMessenger(newCircleTokenMessenger);
        emit CircleTokenMessengerSet(newCircleTokenMessenger);
    }

    /// @notice Sets an address of Circle MessageTransmitter contract.
    /// @dev Only callable on a 7 day delay or by the Emergency Council.
    ///      Emits a {MessageTransmitterSet} event.
    /// @param newMessageTransmitter The new address of Circle MessageTransmitter.
    function setMessageTransmitter(address newMessageTransmitter) external {
        _checkElevatedPermissions();

        circleMessageTransmitter = IMessageTransmitter(newMessageTransmitter);
        emit MessageTransmitterSet(newMessageTransmitter);
    }

    /// @notice Sets an address of Wormhole TokenBridge contract.
    /// @dev Only callable on a 7 day delay or by the Emergency Council.
    ///      Emits a {TokenBridgeSet} event.
    /// @param newTokenBridge The new address of Wormhole TokenBridge.
    function setTokenBridge(address newTokenBridge) external {
        _checkElevatedPermissions();

        tokenBridge = ITokenBridge(newTokenBridge);
        emit TokenBridgeSet(newTokenBridge);
    }

    /// @notice Registers CCTP domain.
    /// @dev Only callable on a 7 day delay or by the Emergency Council.
    ///      Emits a {CCTPDomainsSet} event.
    /// @param newDomain CCTP domain.
    function setCCTPDomain(uint32 newDomain) external {
        _checkElevatedPermissions();

        cctpDomain = newDomain;

        emit CCTPDomainSet(newDomain);
    }

    /// @notice Sets the fee from yield by Curvance DAO to use as gas
    ///         to compound rewards for users.
    /// @dev Only callable on a 7 day delay or by the Emergency Council,
    ///      can only have a maximum value of 5%.
    ///      Emits a {FeeSet} event.
    /// @param value The new fee to take on compound to fund future
    ///              auto compounding, in `basis points`.
    function setProtocolCompoundFee(uint256 value) external {
        _checkElevatedPermissions();

        // Compound fee cannot be more than 5%.
        if (value > 500) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }
        // Convert the parameters from basis points to `WAD` format
        // while inefficient we want to minimize potential human error
        // as much as possible, even if it costs a bit extra gas on config.
        protocolCompoundFee = _bpToWad(value);

        // Update vault harvest fee with new yield fee.
        protocolHarvestFee = protocolYieldFee + _bpToWad(value);

        emit FeeSet("Compound", value);
    }

    /// @notice Sets the fee taken by Curvance DAO on all generated
    ///         by the protocol.
    /// @dev Only callable on a 7 day delay or by the Emergency Council,
    ///      can only have a maximum value of 50%.
    ///      Emits a {FeeSet} event.
    /// @param value The new fee to take on compound to distribute to veCVE
    ///              lockers, in `basis points`.
    function setProtocolYieldFee(uint256 value) external {
        _checkElevatedPermissions();

        // Compound fee cannot be more than 50%.
        if (value > 5000) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }
        // Convert the parameters from basis points to `WAD` format
        // while inefficient we want to minimize potential human error
        // as much as possible, even if it costs a bit extra gas on config.
        protocolYieldFee = _bpToWad(value);

        // Update vault harvest fee with new yield fee.
        protocolHarvestFee = _bpToWad(value) + protocolCompoundFee;

        emit FeeSet("Yield", value);
    }

    /// @notice Sets the fee taken by Curvance DAO on leverage/deleverage
    ///         via position folding.
    /// @dev Only callable on a 7 day delay or by the Emergency Council,
    ///      can only have a maximum value of 2%.
    ///      Emits a {FeeSet} event.
    /// @param value The new fee to take on leverage/deleverage when done
    ///              by position folding, in `basis points`.
    function setProtocolLeverageFee(uint256 value) external {
        _checkElevatedPermissions();

        // Leverage fee cannot be more than 2%.
        if (value > 200) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }
        // Convert the parameters from basis points to `WAD` format
        // while inefficient we want to minimize potential human error
        // as much as possible, even if it costs a bit extra gas on config.
        protocolLeverageFee = _bpToWad(value);

        emit FeeSet("Leverage", value);
    }

    /// @notice Sets the maximum slippage users can input with swap
    ///         instructions.
    /// @dev Only callable on a 7 day delay or by the Emergency Council,
    ///      must have a minimum value of 4%.
    ///      Emits a {SlippageLimit} event.
    /// @param value The new slippage limit users can input on swap
    ///              instructions, in `basis points`.
    function setSlippageLimit(uint256 value) external {
        _checkElevatedPermissions();

        // Slippage limit cannot be less than 4%.
        if (value < 400) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        // Convert the parameters from basis points to `WAD` format
        // while inefficient we want to minimize potential human error
        // as much as possible, even if it costs a bit extra gas on config.
        slippageLimit = _bpToWad(value);

        emit SlippageLimit(value);
    }

    /// @notice Sets the fee taken by Curvance DAO from interest generated.
    /// @dev Only callable on a 7 day delay or by the Emergency Council,
    ///      can only have a maximum value of 75%.
    ///      Emits an {InterestFeeSet} event.
    /// @param market The address of the market manager to configure
    ///               interest fees of.
    /// @param value The new fee to take on interest generated
    ///              by a debt token, in `basis points`.
    function setProtocolInterestRateFee(
        address market,
        uint256 value
    ) external {
        _checkElevatedPermissions();

        // Interest fee cannot be more than 75%.
        if (value > 7500) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        // Validate that you're setting the fee for an actual market manager.
        if (!isMarketManager[market]) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        // Convert the parameters from basis points to `WAD` format
        // while inefficient we want to minimize potential human error
        // as much as possible, even if it costs a bit extra gas on config.
        protocolInterestFactor[market] = _bpToWad(value);

        emit InterestFeeSet(market, value);
    }

    /// @notice Sets the early unlock penalty value for when users want to
    ///         unlock their veCVE early.
    /// @dev Only callable on a 7 day delay or by the Emergency Council,
    ///      must be between 30% and 90%, or off, with a value of 0%.
    ///      Emits a {MultiplierSet} event.
    /// @param value The new penalty on early expiring a vote escrowed
    ///              cve position, in `basis points`.
    function setEarlyUnlockPenaltyMultiplier(uint256 value) external {
        _checkElevatedPermissions();

        // Early unlock penalty cannot be more than 90%.
        if (value > 9000) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        // Early unlock penalty cannot be less than 30%,
        // unless its being turned off.
        if (value < 3000 && value != 0) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        earlyUnlockPenaltyMultiplier = value;

        emit MultiplierSet("Early Unlock Penalty", value);
    }

    /// @notice Sets the voting power boost received by locks using
    ///         Continuous Lock mode.
    /// @dev Only callable on a 7 day delay or by the Emergency Council,
    ///      must be a positive boost i.e. > 1.01 or greater multiplier.
    ///      Emits a {MultiplierSet} event.
    /// @param value The new voting power boost for continuous lock mode
    ///              vote escrowed cve positions, in `basis points`.
    function setVoteBoostMultiplier(uint256 value) external {
        _checkElevatedPermissions();

        // Voting power boost cannot be less than or equal to 1,
        // unless its being turned off, which is represented with a
        // value of 0.
        if (value <= DENOMINATOR && value != 0) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        voteBoostMultiplier = value;

        emit MultiplierSet("Vote Boost", value);
    }

    /// @notice Sets the emissions boost received by choosing
    ///         to lock emissions at veCVE.
    /// @dev Only callable on a 7 day delay or by the Emergency Council,
    ///      must be a positive boost i.e. > 1.01 or greater multiplier.
    ///      Emits a {MultiplierSet} event.
    /// @param value The new emissions boost for opting to take emissions
    ///              in a vote escrowed cve position instead of liquid CVE,
    ///              in `basis points`.
    function setLockBoostMultiplier(uint256 value) external {
        _checkElevatedPermissions();

        // Locking emissions boost cannot be less than or equal to 1,
        // unless its being turned off, which is represented with a
        // value of 0.
        if (value <= DENOMINATOR && value != 0) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        lockBoostMultiplier = value;

        emit MultiplierSet("Lock Boost", value);
    }

    /// EMISSIONS LOGIC

    /// @notice Sets the amount of CVE rewards allocated on this chain,
    ///         for an epoch.
    /// @dev Only callable by the Voting Hub.
    /// @param epoch The epoch having its token emission values set.
    /// @param emissionsAllocated The amount of CVE rewards allocated on
    ///                           this chain, for an epoch.
    function setEmissionsAllocatedByEpoch(
        uint256 epoch,
        uint256 emissionsAllocated
    ) external {
        if (msg.sender != votingHub) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        emissionsAllocatedByEpoch[epoch] = emissionsAllocated;
    }

    /// @notice Sets the target token emissions for each Protocol Era.
    /// @dev Only callable by the Emergency Council.
    /// @param epochEmissions The initial token emissions value that the
    ///                       protocol should allocate, per epoch.
    function setEraTargetEmissions(uint256 epochEmissions) external {
        _checkElevatedPermissions();

        uint256 numEras = IVotingHub(votingHub).protocolRewardEras();

        for (uint256 i; i < numEras; ++i) {
            targetEmissionAllocationByEra[i] = epochEmissions;
            epochEmissions = epochEmissions / 2;
        }

        emit EraEmissionsAllotmentSet(epochEmissions);
    }

    /// OWNERSHIP LOGIC

    /// @notice Sets DAO ownership to a new address.
    /// @dev Only callable on a 7 day delay or by the Emergency Council.
    ///      Emits a {OwnershipTransferred} event.
    /// @param newDaoAddress The new DAO address.
    function transferDaoOwnership(address newDaoAddress) public virtual {
        _checkElevatedPermissions();

        // Cache old dao address for event emission.
        address previousDaoAddress = daoAddress;
        daoAddress = newDaoAddress;

        // Delete permission data.
        delete hasDaoPermissions[previousDaoAddress];
        // Add new permission data.
        hasDaoPermissions[newDaoAddress] = true;
        emit OwnershipTransferred(previousDaoAddress, newDaoAddress);

        // Notify Timelock Controller of a DAO address update.
        if (timelock != address(0)) {
            if (
                ERC165Checker.supportsInterface(
                    timelock,
                    type(ITimelock).interfaceId
                )
            ) {
                ITimelock(timelock).updateDaoAddress();
            }
        }
    }

    /// @notice Sets timelock ownership to a new address.
    /// @dev Only callable by the Emergency Council.
    ///      Emits a {NewTimelockConfiguration} event.
    /// @param newTimelock The new timelock address.
    function migrateTimelockConfiguration(address newTimelock) external {
        _checkEmergencyCouncilPermissions();

        // Cache old timelock for event emission.
        address previousTimelock = timelock;
        timelock = newTimelock;

        // Delete permission data.
        // If the previous Timelock also has Emergency Council permissions
        // for some reason, do not remove their elevated permissioning.
        if (previousTimelock != emergencyCouncil) {
            delete hasElevatedPermissions[previousTimelock];

            // If the previous Timelock also has DAO permissions
            // for some reason, do not remove their permissioning.
            if (previousTimelock != daoAddress) {
                delete hasDaoPermissions[previousTimelock];
            }
        }

        // Add new permission data.
        hasDaoPermissions[newTimelock] = true;
        hasElevatedPermissions[newTimelock] = true;

        emit NewTimelockConfiguration(previousTimelock, newTimelock);
    }

    /// @notice Sets emergency council ownership to a new address.
    /// @dev Only callable by the Emergency Council.
    ///      Emits a {NewTimelockConfiguration} event.
    /// @param newEmergencyCouncil The new emergency council address.
    function transferEmergencyCouncil(address newEmergencyCouncil) external {
        _checkEmergencyCouncilPermissions();

        // Cache old emergency council for event emission.
        address previousEmergencyCouncil = emergencyCouncil;
        emergencyCouncil = newEmergencyCouncil;

        // If the previous Emergency Council also has timelock permissions
        // for some reason, do not remove their elevated permissioning.
        if (previousEmergencyCouncil != timelock) {
            delete hasElevatedPermissions[previousEmergencyCouncil];

            // If the previous Emergency Council also has DAO permissions
            // for some reason, do not remove their permissioning.
            if (previousEmergencyCouncil != daoAddress) {
                delete hasDaoPermissions[previousEmergencyCouncil];
            }
        }

        // Add new permission data.
        hasDaoPermissions[newEmergencyCouncil] = true;
        hasElevatedPermissions[newEmergencyCouncil] = true;

        emit EmergencyCouncilTransferred(
            previousEmergencyCouncil,
            newEmergencyCouncil
        );
    }

    /// @notice Adds an approved address to create locks for other
    ///         addresses inside Curvance.
    /// @dev Only callable on a 7 day delay or by the Emergency Council.
    ///      Cannot have locking permissions prior.
    ///      Emits a {NewCurvanceContract} event.
    /// @param newApprovedAddress The new address to approve lock
    ///                           creation authority inside Curvance.
    function addLockingPermissions(address newApprovedAddress) external {
        _checkElevatedPermissions();

        // Validate `newApprovedAddress` is not currently supported.
        if (hasLockingPermissions[newApprovedAddress]) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        hasLockingPermissions[newApprovedAddress] = true;

        emit NewCurvanceContract("Locking Permissions", newApprovedAddress);
    }

    /// @notice Removes an approved address to create locks for other
    ///         addresses inside Curvance.
    /// @dev Only callable on a 7 day delay or by the Emergency Council.
    ///      Has to have locking permissions prior.
    ///      Emits a {RemovedCurvanceContract} event.
    /// @param currentApprovedAddress The approved address to remove lock
    ///                               creation authority inside Curvance.
    function removeLockingPermissions(
        address currentApprovedAddress
    ) external {
        _checkElevatedPermissions();

        // Validate `currentApprovedAddress` is currently supported.
        if (!hasLockingPermissions[currentApprovedAddress]) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        delete hasLockingPermissions[currentApprovedAddress];

        emit RemovedCurvanceContract(
            "Locking Permissions",
            currentApprovedAddress
        );
    }

    /// MULTICHAIN SUPPORT LOGIC

    /// @notice Adds support for a new chain.
    /// @dev Only callable on a 7 day delay or by the Emergency Council.
    ///      Emits a {NewChainAdded} event.
    /// @param remoteMessagingHub Address for new chain's Messaging Hub.
    /// @param remoteVotingHub Address for new chain's Voting Hub.
    /// @param feeTokenAddress Fee token address on the chain.
    /// @param cveAddress CVE address on the chain.
    /// @param chainId GETH Chain ID where this address authorized.
    /// @param messagingChainId Messaging Chain ID where this address authorized.
    /// @param relayer Wormhole relayer address on the chain.
    /// @param domain CCTP domain for the chain.
    function addChainSupport(
        address remoteMessagingHub,
        address remoteVotingHub,
        address cveAddress,
        address feeTokenAddress,
        uint256 chainId,
        uint16 messagingChainId,
        address relayer,
        uint32 domain
    ) external {
        _checkElevatedPermissions();

        // Validate this "new" chain is not currently supported.
        if (supportedChainData[chainId].isSupported == 2) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        supportedChainData[chainId] = ChainData({
            isSupported: 2,
            messagingHub: remoteMessagingHub,
            votingHub: remoteVotingHub,
            cveAddress: cveAddress,
            feeTokenAddress: feeTokenAddress,
            messagingChainId: messagingChainId,
            wormholeRelayer: relayer,
            cctpDomain: domain
        });

        messagingToGETHChainId[messagingChainId] = chainId;
        GETHToMessagingChainId[chainId] = messagingChainId;
        ++supportedChains;
        foreignChainIds.push(chainId);

        emit NewChainAdded(chainId, relayer);
    }

    /// @notice Removes support for a chain.
    /// @dev Callable by an address with DAO Authority or higher.
    ///      Emits a {RemovedChain} event.
    /// @param expectedMessagingHub Expected Address for `chainId` Messaging
    ///                             Hub.
    /// @param expectedVotingHub Expected Address for `chainId` Voting Hub.
    /// @param chainId GETH Chain ID where `currentMessagingHub` is
    ///                authorized.
    function removeChainSupport(
        address expectedMessagingHub,
        address expectedVotingHub,
        uint256 chainId
    ) external {
        // Lower permissioning on removing chains as it will reduce risk to
        // the system.
        _checkDaoPermissions();

        ChainData memory chainDataToRemove = supportedChainData[chainId];

        // Validate that `expectedMessagingHub` is currently supported.
        if (chainDataToRemove.messagingHub != expectedMessagingHub) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        // Validate that `expectedVotingHub` is currently supported.
        if (chainDataToRemove.votingHub != expectedVotingHub) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        // Validate that `chainId` is currently supported.
        if (chainDataToRemove.isSupported < 2) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        // Remove chain support from protocol.
        supportedChainData[chainId].isSupported = 1;
        // Decrease supportedChains.
        --supportedChains;
        // Remove messagingChainId <> GETH chainId mapping table references.
        delete GETHToMessagingChainId[
            messagingToGETHChainId[chainDataToRemove.messagingChainId]
        ];
        delete messagingToGETHChainId[chainDataToRemove.messagingChainId];

        _removeForeignChainId(chainId);

        emit RemovedChain(chainId, expectedMessagingHub, expectedVotingHub);
    }

    /// CONTRACT MAPPING LOGIC

    /// @notice Sets an external calldata checker contract.
    /// @dev Only callable on a 7 day delay or by the Emergency Council.
    ///      Emits a {CalldataCheckerSet} event.
    /// @param target The target contract for external calldata
    ///               such as 1Inch V5.
    /// @param calldataChecker The contract that will check calldata prior
    ///                        to execution in `target`.
    function setExternalCalldataChecker(
        address target,
        address calldataChecker
    ) external {
        _checkElevatedPermissions();

        externalCalldataChecker[target] = calldataChecker;
        emit CalldataCheckerSet("External", target, calldataChecker);
    }

    /// @notice Sets a multicall calldata checker contract.
    /// @dev Only callable on a 7 day delay or by the Emergency Council.
    ///      Emits a {CalldataCheckerSet} event.
    /// @param target The target contract for external calldata
    ///               such as Pyth or Redstone.
    /// @param calldataChecker The contract that will check calldata prior
    ///                        to execution in `target`.
    function setMulticallChecker(
        address target,
        address calldataChecker
    ) external {
        _checkElevatedPermissions();

        multicallChecker[target] = calldataChecker;
        emit CalldataCheckerSet("Multicall", target, calldataChecker);
    }

    /// @notice Sets multicall provider contracts, either enabling,
    ///         or disabling support inside the Curvance Protocol.
    /// @dev Only callable on a 7 day delay or by the Emergency Council.
    ///      Emits one or many {MulticallProviderSet} events.
    /// @param providers Array containing the addresses of multicall provider
    ///                  contracts such as collateral or debt token contracts.
    /// @param supported Whether a provider should be supported or not.
    function setMulticallProviders(
        address[] calldata providers,
        bool supported
    ) external {
        _checkElevatedPermissions();

        uint256 numProviders = providers.length;
        address provider;

        for (uint256 i; i < numProviders; ++i) {
            provider = providers[i];
            if (isMulticallProvider[provider] == supported) {
                _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
            }

            isMulticallProvider[provider] = supported;
            emit MulticallProviderSet(provider, supported);
        }
    }

    /// @notice Updates status of unique liquidation sequencing to
    ///         `sequencingActive`.
    function setSequencingStatus(bool sequencingActive) external {
        _checkElevatedPermissions();

        // Cache market list.
        uint256 numMarkets = marketManagers.length;

        for (uint256 i; i < numMarkets; ++i) {
            IMarketManager(marketManagers[i]).setSequencingStatus(
                sequencingActive
            );
        }
    }
    
    function setRegularDuration(uint256 _duration) external {
        _checkElevatedPermissions();

        // Cache market list.
        uint256 numMarkets = marketManagers.length;

        for (uint256 i; i < numMarkets; ++i) {
            IMarketManager(marketManagers[i]).setRegularDuration(
                _duration
            );
        }
    }

    function setPriorityDuration(uint256 _duration) external {
        _checkElevatedPermissions();

        // Cache market list.
        uint256 numMarkets = marketManagers.length;

        for (uint256 i; i < numMarkets; ++i) {
            IMarketManager(marketManagers[i]).setPriorityDuration(
                _duration
            );
        }
    }

    function setEndDuration(uint256 _duration) external {
        _checkElevatedPermissions();

        // Cache market list.
        uint256 numMarkets = marketManagers.length;

        for (uint256 i; i < numMarkets; ++i) {
            IMarketManager(marketManagers[i]).setEndDuration(
                _duration
            );
        }
    }

    /// @notice Called from the Atlas DappControl as a pre hook
    ///         before liquidations are tried.
    function lockAtlasOev() external {
        if (!hasAtlasPermissions[msg.sender]) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        assembly {
            tstore(TRANSIENT_ATLAS_OEV_KEY, 0)
        }
    }

    /// @notice Called from the Atlas DappControl as a post hook
    ///         after liquidations are tried.
    function unlockAtlasOev() external {
        if (!hasAtlasPermissions[msg.sender]) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        assembly {
            tstore(TRANSIENT_ATLAS_OEV_KEY, 1)
        }
    }

    /// @notice Returns whether Atlas OEV is currently allowed
    function isAtlasOevAllowed() public view returns (bool) {
        uint256 result;
        assembly {
            result := tload(TRANSIENT_ATLAS_OEV_KEY)
        }
        return result == 1;
    }

    /// @notice Authorizes an address to lock and unlock Atlas OEV.
    /// @dev Only callable on a 7 day delay or by the Emergency Council.
    ///      Cannot be a supported Atlas controller address prior.
    ///      Emits a {AtlasControlAuthorized} event.
    /// @param newAtlasController The new address to allow control of Atlas
    ///                           support for use in Curvance.
    function addAuthorizedAtlasDAppControl(
        address newAtlasController
    ) external {
        _checkElevatedPermissions();

        // Validate `newAtlasController` is not currently supported.
        if (hasAtlasPermissions[newAtlasController]) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        hasAtlasPermissions[newAtlasController] = true;

        emit NewCurvanceContract("Atlas", newAtlasController);
    }

    /// @notice Deauthorizes an address to lock and unlock Atlas OEV.
    /// @dev Only callable on a 7 day delay or by the Emergency Council.
    ///      Cannot be a supported Atlas controller address prior.
    ///      Emits a {AtlasControlAuthorized} event.
    /// @param currentAtlasController The address to remove control of Atlas
    ///                           support from inside Curvance.
    function removeAuthorizedAtlasDAppControl(
        address currentAtlasController
    ) external {
        _checkElevatedPermissions();

        // Validate `currentAtlasController` is currently supported.
        if (!hasAtlasPermissions[currentAtlasController]) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        delete hasAtlasPermissions[currentAtlasController];

        emit RemovedCurvanceContract("Atlas", currentAtlasController);
    }

    /// @notice Adds a Harvester contract for use in Curvance.
    /// @dev Only callable on a 7 day delay or by the Emergency Council.
    ///      Cannot be a supported Harvester contract prior.
    ///      Emits a {NewCurvanceContract} event.
    /// @param newHarvester The new Harvester contract to support for use
    ///                     in Curvance.
    function addHarvester(address newHarvester) external {
        _checkElevatedPermissions();

        // Validate `newHarvester` is not currently supported.
        if (isHarvester[newHarvester]) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        isHarvester[newHarvester] = true;

        emit NewCurvanceContract("Harvestor", newHarvester);
    }

    /// @notice Removes a Harvester contract from Curvance.
    /// @dev Only callable on a 7 day delay or by the Emergency Council.
    ///      Has to be a supported Harvester contract prior.
    ///      Emits a {RemovedCurvanceContract} event.
    /// @param currentHarvester The supported Harvester contract to remove
    ///                         from Curvance.
    function removeHarvester(address currentHarvester) external {
        _checkElevatedPermissions();

        // Validate `currentHarvester` is currently supported.
        if (!isHarvester[currentHarvester]) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        delete isHarvester[currentHarvester];

        emit RemovedCurvanceContract("Harvestor", currentHarvester);
    }

    /// @notice Returns an array of Chain IDs recorded in the Messaging Layers
    ///         Chain ID format.
    function getForeignChainIds() external view returns (uint256[] memory) {
        return foreignChainIds;
    }

    /// @notice Returns an array of Curvance markets on this chain.
    function getMarketManagers() external view returns (address[] memory) {
        return marketManagers;
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Adds a new Market Manager and associated fee configurations.
    /// @dev Only callable on a 7 day delay or by the Emergency Council,
    ///      can only have a maximum value of 50% interest fee.
    ///      Cannot be a supported Market Manager contract prior.
    ///      Emits a {NewCurvanceContract} and {InterestFeeSet} events.
    ///      This has a lower limit than `setProtocolInterestRateFee` because
    ///      in specific cases it could make sense to start assigning a high
    ///      interest rate take rate to push people to a new market
    ///      implementation.
    /// @param newMarketManager The new Market Manager contract to support
    ///                         for use in Curvance.
    /// @param marketInterestFactor The interest factor associated with
    ///                             the market manager.
    function addMarketManager(
        address newMarketManager,
        uint256 marketInterestFactor
    ) public virtual {
        _checkElevatedPermissions();

        // Validate `newMarketManager` is not currently supported.
        if (isMarketManager[newMarketManager]) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        // Ensure that `newMarketManager` is a market manager.
        if (
            !ERC165Checker.supportsInterface(
                newMarketManager,
                type(IMarketManager).interfaceId
            )
        ) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        /// Interest fee cannot be more than 50%.
        if (marketInterestFactor > 5000) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        isMarketManager[newMarketManager] = true;
        // We store supported markets semi redundantly for offchain querying.
        marketManagers.push(newMarketManager);
        // Convert interest factor parameter from basis points to `WAD`
        // for precision calculations.
        protocolInterestFactor[newMarketManager] = _bpToWad(
            marketInterestFactor
        );

        emit NewCurvanceContract("Market Manager", newMarketManager);
        emit InterestFeeSet(newMarketManager, marketInterestFactor);
    }

    /// @notice Removes a current market manager from Curvance.
    /// @dev Only callable on a 7 day delay or by the Emergency Council.
    ///      Has to be a supported Market Manager contract prior.
    ///      Emits a {RemovedCurvanceContract} event.
    /// @param currentMarketManager The supported Market Manager contract
    ///                             to remove from Curvance.
    function removeMarketManager(address currentMarketManager) public virtual {
        _checkElevatedPermissions();

        // Validate `currentMarketManager` is currently supported.
        if (!isMarketManager[currentMarketManager]) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        delete isMarketManager[currentMarketManager];

        // Cache market list.
        uint256 numMarkets = marketManagers.length;
        uint256 marketIndex = numMarkets;

        for (uint256 i; i < numMarkets; ++i) {
            if (marketManagers[i] == currentMarketManager) {
                marketIndex = i;
                break;
            }
        }

        // Validate we found the market and remove 1 from numMarkets
        // so it corresponds to last element index now (starting at index 0).
        // This is an additional runtime invariant check for extra security.
        if (marketIndex >= numMarkets--) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        // Copy last `marketManagers` slot to `marketIndex` slot.
        marketManagers[marketIndex] = marketManagers[numMarkets];
        // Remove the last element to remove `currentMarketManager`
        // from marketManagers list.
        marketManagers.pop();

        emit RemovedCurvanceContract("Market Manager", currentMarketManager);
    }

    /// @notice Returns true if this contract implements the interface defined
    ///         by `interfaceId`.
    /// @param interfaceId The interface to check for implementation.
    /// @return Whether `interfaceId` is implemented or not.
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(ICentralRegistry).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Remove Chain ID from foreign chain id array.
    /// @param chainId Chain ID to remove.
    function _removeForeignChainId(uint256 chainId) internal {
        uint256 i;
        uint256 numForeignChainIds = foreignChainIds.length;

        for (; i < numForeignChainIds; ++i) {
            if (foreignChainIds[i] == chainId) {
                break;
            }
        }

        numForeignChainIds--;

        for (; i < numForeignChainIds; ++i) {
            foreignChainIds[i] = foreignChainIds[i + 1];
        }

        foreignChainIds.pop();
    }

    /// @notice Multiplies `value` by 1e14 to convert it from `basis points`
    ///         to WAD.
    /// @dev Internal helper function for easily converting between scalars.
    function _bpToWad(uint256 value) internal pure returns (uint256) {
        return value * 1e14;
    }

    /// @dev Checks whether the caller has sufficient permissioning.
    function _checkEmergencyCouncilPermissions() internal view {
        if (msg.sender != emergencyCouncil) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }
    }

    /// @dev Checks whether the caller has sufficient permissioning.
    function _checkDaoPermissions() internal view {
        if (!hasDaoPermissions[msg.sender]) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }
    }

    /// @dev Checks whether the caller has sufficient permissioning.
    function _checkElevatedPermissions() internal view {
        if (!hasElevatedPermissions[msg.sender]) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }
    }

    function _checkGenesisEpochHasNotStarted() internal view {
        if (genesisEpoch <= block.timestamp) {
            _revert(_EPOCH_HAS_STARTED_SELECTOR);
        }
    }
}
