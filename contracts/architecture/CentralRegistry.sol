// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { DENOMINATOR } from "contracts/libraries/Constants.sol";

import { ERC165 } from "contracts/libraries/external/ERC165.sol";
import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { ActionRegistry } from "contracts/libraries/ActionRegistry.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICentralRegistry, ChainData } from "contracts/interfaces/ICentralRegistry.sol";
import { IActionRegistry } from "contracts/interfaces/IActionRegistry.sol";
import { ITimelock } from "contracts/interfaces/ITimelock.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { IVotingHub } from "contracts/interfaces/IVotingHub.sol";

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
///        controls. This requires a 5-day delay from the DAO elected
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

    /// STORAGE ///

    /// @notice Genesis Epoch timestamp.
    uint256 public genesisEpoch;

    // DAO GOVERNANCE OPERATORS

    /// @notice DAO multisig, the primary address that the Curvance
    ///         Collective operates from.
    address public daoAddress;
    /// @notice DAO multisig, with an execution time delay.
    address public timelock;
    /// @notice Multi-protocol multisig, intended to be used only for
    ///         emergencies.
    address public emergencyCouncil;

    // TOKEN CONTRACTS

    /// @notice Address of fee token which Curvance Protocol compounds
    ///         strategy fees into.
    address public feeToken;
    /// @notice CVE contract address on this chain.
    address public cve;
    /// @notice veCVE contract address on this chain.
    address public veCVE;

    // PROTOCOL CONTRACTS

    /// @notice Reward Manager contract address, distributes rewards in
    ///         `feeToken` to token lockers every epoch.
    address public rewardManager;
    /// @notice Gauge Manager contract address, distributes native token
    ///         rewards to depositors and lenders inside the Curvance
    ///         Protocol based on decentralized governance outcomes.
    address public gaugeManager;
    /// @notice Oracle Manager contract address, manages oracle prices
    ///         for supported assets.
    address public oracleManager;
    /// @notice Fee Manager contract address, manages fees for decentralized
    ///         strategies for distribution.
    address public feeManager;
    /// @notice Messaging Hub contract address, processes crosschain messages
    ///         across all supported blockchains.
    address public messagingHub;
    /// @notice Voting Hub contract address, receives decentralized governance
    ///         vote outcomes to update onchain across all blockchains.
    address public votingHub;

    /// @notice Array of all the addresses for all Curvance market managers
    ///         on this chain.
    address[] internal _marketManagers;

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

    /// @notice Percentage fee on interest generated by market inside
    ///         Curvance Protocol.
    /// @dev Market Manager => Protocol Interest Fee, in `WAD`.
    mapping(address => uint256) public protocolInterestFee;
    
    // ACTION MULTIPLIER VALUES

    /// @notice Penalty multiplier for unlocking a veCVE lock early.
    uint256 public earlyUnlockPenaltyMultiplier;
    /// @notice Voting power multiplier for Continuous Lock mode.
    uint256 public voteBoostMultiplier;
    /// @notice Gauge rewards multiplier for locking gauge emissions.
    uint256 public lockBoostMultiplier;

    // SLIPPAGE VALUES

    /// @notice Protocol slippage limit for safe swap.
    uint256 public slippageLimit = 1000 * 1e14;

    // ATLAS PARAMETER
    // Controls which markets Atlas liquidators can act on
    bytes32 internal constant _TRANSIENT_MARKET_UNLOCKED_KEY
        = 0x3456789012345678901234567890123456789012345678901234567890123457;

    // CROSSCHAIN CONFIGURATION DATA

    /// @notice Address of Crosschain Core contract on this chain.
    address public crosschainCore;
    /// @notice Address of Crosschain Relayer contract on this chain.
    address public crosschainRelayer;
    /// @notice Address of Token Messenger contract on this chain.
    address public tokenMessager;
    /// @notice Address of Message Transmitter contract on this chain.
    address public messageTransmitter;
    /// @notice Domain value on this chain.
    uint32 public domain;
    /// @notice The number of chains supported by the Curvance Protocol.
    /// @dev Stored redundantly to reduce gas overhead.
    uint256 public supportedChains;

    /// @notice Array of Chain IDs recorded in the Crosschain Protocol's Chain
    ///         ID format.
    /// @dev Stored redundantly to reduce gas overhead.
    uint256[] internal _foreignChainIds;
    
    /// @notice ChainId => 2 = supported; 1 = unsupported.
    mapping(uint256 => ChainData) public supportedChainData;
    /// @notice Messaging ChainId => GETH ChainId.
    mapping(uint16 => uint256) public messagingToGETHChainId;
    /// @notice GETH ChainId => Messaging ChainId.
    mapping(uint256 => uint16) public GETHToMessagingChainId;

    /// @notice Indicates the amount of token rewards allocated on this chain,
    ///         for an epoch.
    /// @dev Epoch # => Token rewards allocated.
    mapping(uint256 => uint256) public emissionsAllocatedByEpoch;

    /// @notice Indicates the amount of token rewards allocated across all
    ///         chains, for an era. An era is a particular period in time in
    ///         which rewards are constant, before a halvening event moves the
    ///         protocol to a new era.
    /// @dev Era # => Token rewards allocated.
    mapping(uint256 => uint256) public targetEmissionAllocationByEra;

    // CONTRACT MAPPINGS
    
    /// @notice Indicates if an address is a market manager or not.
    /// @dev Address => Market Manager status.
    mapping(address => bool) public isMarketManager;
    /// @notice Indicates if an address is a multicall provider or not.
    /// @dev Address => Multicall provider status.
    mapping(address => bool) public isMulticallProvider;

    /// @notice Maps an intent target address to the contract that will
    ///         inspect provided external calldata.
    /// @dev Address => External calldata checker address.
    mapping(address => address) public externalCalldataChecker;
    /// @notice Maps a Multicall target address to the contract that will
    ///         inspect provided multicall calldata.
    /// @dev Address => Multicall checker address.
    mapping(address => address) public multicallChecker;

    // PERMISSION MAPPINGS

    /// @notice Indicates if address has DAO permissions or not.
    /// @dev Address => DAO permission status.
    mapping(address => bool) public hasDaoPermissions;
    /// @notice Indicates if address has elevated DAO permissions or not.
    /// @dev Address => Elevated DAO permission status.
    mapping(address => bool) public hasElevatedPermissions;
    /// @notice Indicates if address has lock creation permissions or not.
    /// @dev Address => Lock creation permission status.
    mapping(address => bool) public hasLockingPermissions;
    /// @notice Indicates if an address has auction permissions or not.
    /// @dev Address => Auction permission status.
    mapping(address => bool) public hasAuctionPermissions;
    /// @notice Indicates if an address has market permissions or not.
    /// @dev Address => Market permission status.
    mapping(address => bool) public hasMarketPermissions;
    /// @notice Indicates if an address has harvest permissions or not.
    /// @dev Address => Harvest permission status.
    mapping(address => bool) public hasHarvestPermissions;

    /// EVENTS ///

    event GenesisEpochUpdated(uint256 newGenesisEpoch);
    event FeeSet(string indexed fee, uint256 newFee);
    event FeeTokenSet(address newAddress);
    event InterestFeeSet(address indexed market, uint256 newFee);
    event MultiplierSet(string indexed multiplier, uint256 newMultiplier);
    event SlippageLimit(uint256 newSlippage);
    event CoreContractUpdated(
        string indexed contractType,
        address addressUpdated
    );
    event ContractUpdated(
        string indexed contractType,
        address addressUpdated,
        bool isAdded
    );
    event DomainSet(uint32 newDomain);
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
    event MulticallProviderSet(address provider, bool isSupported);
    event EraEmissionsAllotmentSet(uint256 epochEmissionAllotment);
    event PermissionsTransferred(
        string indexed permissionsType,
        address previousAddress,
        address newAddress
    );
    event PermissionsUpdated(
        string indexed permissionsType,
        address addressUpdated,
        bool isAdded
    );

    /// ERRORS ///

    error CentralRegistry__ParametersMisconfigured();
    error CentralRegistry__Unauthorized();
    error CentralRegistry__EpochHasStarted();

    /// CONSTRUCTOR ///

    constructor(
        address daoAddress_,
        address emergencyCouncil_,
        uint256 genesisEpoch_,
        address sequencer_,
        address feeToken_
    ) {
        if (daoAddress_ == address(0)) {
            daoAddress_ = msg.sender;
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
        emergencyCouncil = emergencyCouncil_;

        emit PermissionsTransferred(
            "DAO Permissions",
            address(0),
            daoAddress_
        );
        emit PermissionsTransferred(
            "Emergency Council",
            address(0),
            emergencyCouncil_
        );

        // Provide base dao permissions to `daoAddress_`,
        // and `emergencyCouncil_`.
        hasDaoPermissions[daoAddress_] = true;
        hasDaoPermissions[emergencyCouncil_] = true;

        // Provide elevated dao permissions to `emergencyCouncil`.
        hasElevatedPermissions[emergencyCouncil_] = true;

        // Provide market permissions to `daoAddress_`,
        // and `emergencyCouncil_`.
        hasMarketPermissions[daoAddress_] = true;
        hasMarketPermissions[emergencyCouncil_] = true;

        emit PermissionsUpdated("Market", daoAddress_, true);
        emit PermissionsUpdated("Market", emergencyCouncil_, true);

        genesisEpoch = genesisEpoch_;
        sequencer = sequencer_;
        feeToken = feeToken_;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Withdraw fees in `feeToken` from this central registry.
    function withdrawFees() external {
        _checkDaoPermissions();

        SafeTransferLib.safeTransfer(
            feeToken,
            daoAddress,
            IERC20(feeToken).balanceOf(address(this))
        );
    }

    /// @notice Sets a new genesis epoch.
    /// @dev Only callable by the Emergency Council.
    ///      Emits a {GenesisEpochUpdated} event.
    /// @param newGenesisEpoch The new genesis epoch.
    function setGenesisEpoch(uint256 newGenesisEpoch) external {
        // Its not possible for `genesisEpoch` to be 0 based on constructor
        // restrictions, so we do not need to check for 0 input here as this
        // check would catch `newGenesisEpoch` == 0.
        if (newGenesisEpoch < genesisEpoch) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        _checkElevatedPermissions();
        if (genesisEpoch <= block.timestamp) {
            _revert(_EPOCH_HAS_STARTED_SELECTOR);
        }

        genesisEpoch = newGenesisEpoch;

        emit GenesisEpochUpdated(newGenesisEpoch);
    }

    /// @notice Sets the fee token address.
    /// @dev Only callable on a 5-day delay or by the Emergency Council.
    ///      Only settable once. Emits a {FeeTokenSet} event.
    /// @param newFeeToken The new address of fee token.
    function setFeeToken(address newFeeToken) external {
        _checkCanSetCoreContract(feeToken);
        _checkElevatedPermissions();

        feeToken = newFeeToken;
        emit FeeTokenSet(newFeeToken);
    }

    /// @notice Sets the CVE contract address.
    /// @dev Only callable on a 5-day delay or by the Emergency Council.
    ///      Only settable once. Emits a {CoreContractUpdated} event.
    /// @param newCVE The new address of cve.
    function setCVE(address newCVE) external {
        _checkCanSetCoreContract(cve);
        _checkElevatedPermissions();

        cve = newCVE;
        emit CoreContractUpdated("CVE", newCVE);
    }

    /// @notice Sets the veCVE contract address.
    /// @dev Only callable on a 5-day delay or by the Emergency Council.
    ///      Only settable once. Emits a {CoreContractUpdated} event.
    /// @param newVeCVE The new address of veCVE.
    function setVeCVE(address newVeCVE) external {
        _checkCanSetCoreContract(veCVE);
        _checkElevatedPermissions();

        veCVE = newVeCVE;
        emit CoreContractUpdated("VeCVE", newVeCVE);
    }

    /// @notice Sets the Reward Manager contract address.
    /// @dev Only callable on a 5-day delay or by the Emergency Council.
    ///      Emits a {CoreContractUpdated} event.
    ///      Can only be set once.
    /// @param newRewardManager The new address of rewardManager.
    function setRewardManager(address newRewardManager) external {
        _checkCanSetCoreContract(rewardManager);
        _checkElevatedPermissions();

        rewardManager = newRewardManager;
        emit CoreContractUpdated("Reward Manager", newRewardManager);
    }

    /// @notice Sets the Gauge Manager contract address.
    /// @dev Only callable on a 5-day delay or by the Emergency Council.
    ///      Emits a {CoreContractUpdated} event.
    ///      Can only be set once.
    /// @param newGaugeManager The new address of Gauge Manager.
    function setGaugeManager(address newGaugeManager) external {
        _checkCanSetCoreContract(gaugeManager);
        _checkElevatedPermissions();

        gaugeManager = newGaugeManager;
        emit CoreContractUpdated("Gauge Manager", newGaugeManager);
    }

    /// @notice Sets the voting hub contract address.
    /// @dev Only callable on a 5-day delay or by the Emergency Council.
    ///      Emits a {CoreContractUpdated} event.
    /// @param newVotingHub The new address of votingHub.
    function setVotingHub(address newVotingHub) external {
        _checkElevatedPermissions();

        votingHub = newVotingHub;
        emit CoreContractUpdated("Voting Hub", newVotingHub);
    }

    /// @notice Sets the messaging hub contract address.
    /// @dev Only callable on a 5-day delay or by the Emergency Council.
    ///      Emits a {CoreContractUpdated} event.
    /// @param newMessagingHub The new address of messagingHub.
    function setMessagingHub(address newMessagingHub) external {
        _checkElevatedPermissions();

        messagingHub = newMessagingHub;
        emit CoreContractUpdated("Messaging Hub", newMessagingHub);
    }

    /// @notice Sets the Oracle Manager contract address.
    /// @dev Only callable on a 5-day delay or by the Emergency Council.
    ///      Emits a {CoreContractUpdated} event.
    /// @param newOracleManager The new address of oracleManager.
    function setOracleManager(address newOracleManager) external {
        _checkElevatedPermissions();

        oracleManager = newOracleManager;
        emit CoreContractUpdated("Oracle Manager", newOracleManager);
    }

    /// @notice Sets the Fee Manager contract address.
    /// @dev Only callable on a 5-day delay or by the Emergency Council.
    ///      Emits a {CoreContractUpdated} event.
    /// @param newFeeManager The new address of feeManager.
    function setFeeManager(address newFeeManager) external {
        _checkElevatedPermissions();

        feeManager = newFeeManager;
        emit CoreContractUpdated("Fee Manager", newFeeManager);
    }

    /// @notice Sets the Crosschain Core contract address.
    /// @dev Only callable on a 5-day delay or by the Emergency Council.
    ///      Emits a {CoreContractUpdated} event.
    /// @param newCrosschainCore The new Crosschain Core address.
    function setCrosschainCore(address newCrosschainCore) external {
        _checkElevatedPermissions();

        crosschainCore = newCrosschainCore;
        emit CoreContractUpdated("Crosschain Core", newCrosschainCore);
    }

    /// @notice Sets the Crosschain Relayer contract address.
    /// @dev Only callable on a 5-day delay or by the Emergency Council.
    ///      Emits a {CoreContractUpdated} event.
    /// @param newCrosschainRelayer The new crosschainRelayer address.
    function setCrosschainRelayer(address newCrosschainRelayer) external {
        _checkElevatedPermissions();

        crosschainRelayer = newCrosschainRelayer;
        emit CoreContractUpdated("Crosschain Relayer", newCrosschainRelayer);
    }

    /// @notice Sets the Token Messager contract address.
    /// @dev Only callable on a 5-day delay or by the Emergency Council.
    ///      Emits a {CoreContractUpdated} event.
    /// @param newTokenMessager The new Token Messager address.
    function setTokenMessager(address newTokenMessager) external {
        _checkElevatedPermissions();

        tokenMessager = newTokenMessager;
        emit CoreContractUpdated("Token Messager", newTokenMessager);
    }

    /// @notice Sets the Message Transmitter contract address.
    /// @dev Only callable on a 5-day delay or by the Emergency Council.
    ///      Emits a {CoreContractUpdated} event.
    /// @param newMessageTransmitter The new Message Transmitter address.
    function setMessageTransmitter(address newMessageTransmitter) external {
        _checkElevatedPermissions();

        messageTransmitter = newMessageTransmitter;
        emit CoreContractUpdated(
            "Message Transmitter",
            newMessageTransmitter
        );
    }

    /// @notice Sets the domain.
    /// @dev Only callable on a 5-day delay or by the Emergency Council.
    ///      Emits a {DomainsSet} event.
    /// @param newDomain The new domain value.
    function setDomain(uint32 newDomain) external {
        _checkElevatedPermissions();

        domain = newDomain;
        emit DomainSet(newDomain);
    }

    /// @notice Sets the fee from yield by Curvance DAO to use as gas
    ///         to compound rewards for users.
    /// @dev Only callable on a 5-day delay or by the Emergency Council,
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

    /// @notice Sets the fee taken by Curvance DAO on all yield generated
    ///         by the protocol.
    /// @dev Only callable on a 5-day delay or by the Emergency Council,
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
    ///         via position managers.
    /// @dev Only callable on a 5-day delay or by the Emergency Council,
    ///      can only have a maximum value of 2%.
    ///      Emits a {FeeSet} event.
    /// @param value The new fee to take on leverage/deleverage when done
    ///              by position managers, in `basis points`.
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

    /// @notice Sets the fee taken by Curvance DAO on interest generated.
    /// @dev Only callable on a 5-day delay or by the Emergency Council,
    ///      can only have a maximum value of 75%.
    ///      Emits an {InterestFeeSet} event.
    /// @param market The address of the market manager to configure
    ///               interest fees of.
    /// @param value The new fee to take on interest generated
    ///              by a debt token, in `basis points`.
    function setProtocolInterestFee(
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
        protocolInterestFee[market] = _bpToWad(value);
        emit InterestFeeSet(market, value);
    }

    /// @notice Sets the early unlock penalty value for when users unlock
    ///         their veCVE early.
    /// @dev Only callable on a 5-day delay or by the Emergency Council,
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
    /// @dev Only callable on a 5-day delay or by the Emergency Council,
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

    /// @notice Sets the emissions boost received by choosing to lock
    ///         emissions in veCVE.
    /// @dev Only callable on a 5-day delay or by the Emergency Council,
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

    /// @notice Sets the maximum slippage users can input with swap
    ///         instructions.
    /// @dev Only callable on a 5-day delay or by the Emergency Council,
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

    /// EMISSIONS LOGIC

    /// @notice Sets the amount of token rewards allocated on this chain,
    ///         for an epoch.
    /// @dev Only callable by the Voting Hub.
    /// @param epoch The epoch having its token emission values set.
    /// @param emissionsAllocated The amount of token rewards allocated on
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

    /// @notice Transfers DAO permissions to another address.
    /// @dev Only callable on a 5-day delay or by the Emergency Council.
    ///      Emits a {PermissionsTransferred} event.
    /// @param newDaoAddress The new DAO steward address.
    function transferDaoPermissions(address newDaoAddress) public virtual {
        _checkElevatedPermissions();

        // Cache old dao address.
        address previousDaoAddress = daoAddress;
        daoAddress = newDaoAddress;

        // Delete permission data only if the old dao address does not also
        // have Timelock or Emergency Council permissions.
        if (previousDaoAddress != emergencyCouncil) {
            if (previousDaoAddress != timelock) {
                delete hasDaoPermissions[previousDaoAddress];
                delete hasMarketPermissions[previousDaoAddress];
                emit PermissionsUpdated("Market", previousDaoAddress, false);
            }
        }

        // Add new permission data.
        hasDaoPermissions[newDaoAddress] = true;
        emit PermissionsTransferred(
            "DAO Permissions",
            previousDaoAddress,
            newDaoAddress
        );

        // Assign market permissions only if the new address does
        // not already have them.
        if (!hasMarketPermissions[newDaoAddress]) {
            hasMarketPermissions[newDaoAddress] = true;
            emit PermissionsUpdated("Market", newDaoAddress, true);
        }
        
        // Notify Timelock Controller of a DAO address update.
        if (timelock != address(0)) {
            if (
                ERC165Checker.supportsInterface(
                    timelock,
                    type(ITimelock).interfaceId
                )
            ) {
                ITimelock(timelock).updateRoles();
            }
        }
    }

    /// @notice Transfers Timelock permissions to another address.
    /// @dev Only callable by the Emergency Council.
    ///      Emits a {PermissionsTransferred} event.
    /// @param newTimelock The new timelock address.
    function transferTimelockPermissions(address newTimelock) external {
        _checkEmergencyCouncilPermissions();

        if (
            !ERC165Checker.supportsInterface(
                newTimelock,
                type(ITimelock).interfaceId
            )
        ) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        // Cache old timelock.
        address previousTimelock = timelock;
        timelock = newTimelock;

        // If the previous Timelock also has Emergency Council permissions
        // for some reason, do not remove their elevated permissioning.
        if (previousTimelock != emergencyCouncil) {
            delete hasElevatedPermissions[previousTimelock];

            // If the previous Timelock also has DAO permissions
            // for some reason, do not remove their permissioning.
            if (previousTimelock != daoAddress) {
                delete hasDaoPermissions[previousTimelock];
                delete hasMarketPermissions[previousTimelock];
                emit PermissionsUpdated("Market", previousTimelock, false);
            }
        }

        // Add new permission data.
        hasDaoPermissions[newTimelock] = true;
        hasElevatedPermissions[newTimelock] = true;
        emit PermissionsTransferred(
            "Timelock",
            previousTimelock,
            newTimelock
        );

        // Assign market permissions only if the new address does
        // not already have them.
        if (!hasMarketPermissions[newTimelock]) {
            hasMarketPermissions[newTimelock] = true;
            emit PermissionsUpdated("Market", newTimelock, true);
        }
    }

    /// @notice Transfers Emergency Council permissions to another address.
    /// @dev Only callable by the Emergency Council.
    ///      Emits a {PermissionsTransferred} event.
    /// @param newEmergencyCouncil The new emergency council address.
    function transferEmergencyCouncil(address newEmergencyCouncil) external {
        _checkEmergencyCouncilPermissions();

        // Cache old emergency council.
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
                delete hasMarketPermissions[previousEmergencyCouncil];
                emit PermissionsUpdated(
                    "Market",
                    previousEmergencyCouncil,
                    false
                );
            }
        }

        // Add new permission data.
        hasDaoPermissions[newEmergencyCouncil] = true;
        hasElevatedPermissions[newEmergencyCouncil] = true;
        emit PermissionsTransferred(
            "Emergency Council",
            previousEmergencyCouncil,
            newEmergencyCouncil
        );

        // Assign market permissions only if the new address does
        // not already have them.
        if (!hasMarketPermissions[newEmergencyCouncil]) {
            hasMarketPermissions[newEmergencyCouncil] = true;
            emit PermissionsUpdated("Market", newEmergencyCouncil, true);
        }
    }

    /// @notice Adds a new Market Manager and corresponding interest fee
    ///         configurations.
    /// @dev Only callable on a 5-day delay or by the Emergency Council,
    ///      can only have a maximum value of 50% interest fee.
    ///      Cannot be a supported Market Manager contract prior.
    ///      Emits a {PermissionsUpdated} and {InterestFeeSet} events.
    ///      This has a lower limit than `setProtocolInterestFee` because
    ///      in specific cases it could make sense to start assigning a high
    ///      interest rate take rate to push people to a new market
    ///      implementation.
    /// @param newMarket The new Market Manager contract to support for use
    ///                  in Curvance.
    /// @param marketInterestFee The portion of interest paid by borrowers
    ///                          that goes to the protocol, for this Market
    ///                          Manager.
    function addMarketManager(
        address newMarket,
        uint256 marketInterestFee
    ) external virtual {
        _checkElevatedPermissions();

        // Validate `newMarket` is not currently supported.
        if (isMarketManager[newMarket]) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        // Ensure that `newMarket` is a market manager.
        if (
            !ERC165Checker.supportsInterface(
                newMarket,
                type(IMarketManager).interfaceId
            )
        ) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        /// Interest fee cannot be more than 50%.
        if (marketInterestFee > 5000) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        isMarketManager[newMarket] = true;
        // We store supported markets semi redundantly for offchain querying.
        _marketManagers.push(newMarket);
        // Convert interest factor parameter from basis points to `WAD`
        // for precision calculations.
        protocolInterestFee[newMarket] = _bpToWad(
            marketInterestFee
        );
        emit PermissionsUpdated("Market Manager", newMarket, true);
        emit InterestFeeSet(newMarket, marketInterestFee);
    }

    /// @notice Removes a current market manager from Curvance.
    /// @dev Only callable on a 5-day delay or by the Emergency Council.
    ///      Has to be a supported Market Manager contract prior.
    ///      Emits a {PermissionsUpdated} event.
    /// @param marketApproved The supported Market Manager contract to remove
    ///                       from Curvance.
    function removeMarketManager(address marketApproved) public virtual {
        _checkElevatedPermissions();

        // Validate `marketApproved` is currently supported.
        if (!isMarketManager[marketApproved]) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        delete isMarketManager[marketApproved];

        // Cache market list.
        uint256 numMarkets = _marketManagers.length;
        uint256 marketIndex = numMarkets;

        for (uint256 i; i < numMarkets; ++i) {
            if (_marketManagers[i] == marketApproved) {
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

        // Copy last `_marketManagers` slot to `marketIndex` slot.
        _marketManagers[marketIndex] = _marketManagers[numMarkets];
        // Remove the last element to remove `marketApproved`
        // from _marketManagers list.
        _marketManagers.pop();
        emit PermissionsUpdated("Market Manager", marketApproved, false);
    }

    /// @notice Adds an approved address to create locks for other
    ///         addresses inside Curvance.
    /// @dev Only callable on a 5-day delay or by the Emergency Council.
    ///      Cannot have locking permissions prior.
    ///      Emits a {PermissionsUpdated} event.
    /// @param newAddress The new address to approve lock creation authority
    ///                   inside Curvance.
    function addLockingPermissions(address newAddress) external {
        _checkElevatedPermissions();

        // Validate `newAddress` is not currently supported.
        if (hasLockingPermissions[newAddress]) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        hasLockingPermissions[newAddress] = true;
        emit PermissionsUpdated("Locking", newAddress, true);
    }

    /// @notice Removes an approved address to create locks for other
    ///         addresses inside Curvance.
    /// @dev Only callable on a 5-day delay or by the Emergency Council.
    ///      Has to have locking permissions prior.
    ///      Emits a {PermissionsUpdated} event.
    /// @param addressApproved The approved address to remove lock
    ///                        creation authority inside Curvance.
    function removeLockingPermissions(address addressApproved) external {
        _checkElevatedPermissions();

        // Validate `addressApproved` is currently supported.
        if (!hasLockingPermissions[addressApproved]) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        delete hasLockingPermissions[addressApproved];
        emit PermissionsUpdated("Locking", addressApproved, false);
    }

    /// @notice Authorizes an address to manage auction process.
    /// @dev Only callable on a 5-day delay or by the Emergency Council.
    ///      Cannot be a supported Atlas controller address prior.
    ///      Emits a {AtlasControlAuthorized} event.
    /// @param newAddress The address to add auction permissions to
    ///                   inside Curvance.
    function addAuctionPermissions(address newAddress) external {
        _checkElevatedPermissions();

        // Validate `newAddress` is not currently supported.
        if (hasAuctionPermissions[newAddress]) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        hasAuctionPermissions[newAddress] = true;
        emit PermissionsUpdated("Auction", newAddress, true);
    }

    /// @notice Deauthorizes an address to manage auction process.
    /// @dev Only callable on a 5-day delay or by the Emergency Council.
    ///      Cannot be a supported Atlas controller address prior.
    ///      Emits a {AtlasControlAuthorized} event.
    /// @param addressApproved The address to remove auction permissions from
    ///                        inside Curvance.
    function removeAuctionPermissions(address addressApproved) external {
        _checkElevatedPermissions();

        // Validate `addressApproved` is currently supported.
        if (!hasAuctionPermissions[addressApproved]) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        delete hasAuctionPermissions[addressApproved];
        emit PermissionsUpdated("Auction", addressApproved, false);
    }

    //// @notice Authorizes an address to manage markets.
    /// @notice Adds a Harvester contract for use in Curvance.
    /// @dev Only callable on a 5-day delay or by the Emergency Council.
    ///      Cannot be a supported Harvester contract prior.
    ///      Emits a {PermissionsUpdated} event.
    /// @param newAddress The address to add market permissions to
    ///                   inside Curvance.
    function addMarketPermissions(address newAddress) external {
        _checkElevatedPermissions();

        // Validate `newAddress` is not currently supported.
        if (hasMarketPermissions[newAddress]) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        hasMarketPermissions[newAddress] = true;
        emit PermissionsUpdated("Market", newAddress, true);
    }

    //// @notice Deauthorizes an address to manage markets.
    /// @dev Only callable on a 5-day delay or by the Emergency Council.
    ///      Has to be a supported Harvester contract prior.
    ///      Emits a {PermissionsUpdated} event.
    /// @param addressApproved The address to remove market permissions from
    ///                        inside Curvance.
    function removeMarketPermissions(address addressApproved) external {
        _checkElevatedPermissions();

        // Validate `addressApproved` is currently supported.
        if (!hasMarketPermissions[addressApproved]) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        delete hasMarketPermissions[addressApproved];
        emit PermissionsUpdated("Market", addressApproved, false);
    }

    //// @notice Authorizes an address to manage harvest process.
    /// @dev Only callable on a 5-day delay or by the Emergency Council.
    ///      Cannot be a supported Harvester contract prior.
    ///      Emits a {PermissionsUpdated} event.
    /// @param newAddress The address to add harvest permissions to
    ///                   inside Curvance.
    function addHarvestPermissions(address newAddress) external {
        _checkElevatedPermissions();

        // Validate `newAddress` is not currently supported.
        if (hasHarvestPermissions[newAddress]) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        hasHarvestPermissions[newAddress] = true;
        emit PermissionsUpdated("Harvest", newAddress, true);
    }

    //// @notice Deauthorizes an address to manage harvest process.
    /// @dev Only callable on a 5-day delay or by the Emergency Council.
    ///      Has to be a supported Harvester contract prior.
    ///      Emits a {PermissionsUpdated} event.
    /// @param addressApproved The address to remove harvest permissions from
    ///                        from inside Curvance.
    function removeHarvestPermissions(address addressApproved) external {
        _checkElevatedPermissions();

        // Validate `addressApproved` is currently supported.
        if (!hasHarvestPermissions[addressApproved]) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        delete hasHarvestPermissions[addressApproved];
        emit PermissionsUpdated("Harvest", addressApproved, false);
    }

    /// CROSSCHAIN SUPPORT LOGIC

    /// @notice Adds support for a new chain.
    /// @dev Only callable on a 5-day delay or by the Emergency Council.
    ///      Emits a {NewChainAdded} event.
    /// @param remoteMessagingHub Address for new chain's Messaging Hub.
    /// @param remoteVotingHub Address for new chain's Voting Hub.
    /// @param feeTokenAddress Fee token address on the chain.
    /// @param cveAddress CVE address on the chain.
    /// @param chainId GETH Chain ID where this address authorized.
    /// @param messagingChainId Messaging Chain ID where this address
    ///                         authorized.
    /// @param relayer Crosschain relayer address on the chain.
    /// @param chainDomain Domain for the chain.
    function addChainSupport(
        address remoteMessagingHub,
        address remoteVotingHub,
        address cveAddress,
        address feeTokenAddress,
        uint256 chainId,
        uint16 messagingChainId,
        address relayer,
        uint32 chainDomain
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
            crosschainRelayer: relayer,
            domain: chainDomain
        });

        messagingToGETHChainId[messagingChainId] = chainId;
        GETHToMessagingChainId[chainId] = messagingChainId;
        ++supportedChains;
        _foreignChainIds.push(chainId);

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

    /// AUCTION CONFIGURATION LOGIC

    /// @notice Unlocks a market to process auction-based liquidations.
    /// @param marketToUnlock The address of the market manager to unlock
    ///                       auction-based liquidations with a specific
    ///                       liquidation bonus.
    function unlockAuctionForMarket(address marketToUnlock) external {
        if (!hasAuctionPermissions[msg.sender]) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        // Validate that you're unlocking an approved market manager.
        if (!isMarketManager[marketToUnlock]) {
            _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
        }

        uint256 marketToUnlockUint = uint256(uint160(marketToUnlock));
        /// @solidity memory-safe-assembly
        assembly {
            tstore(_TRANSIENT_MARKET_UNLOCKED_KEY, marketToUnlockUint)
        }
    }

    /// @notice Returns whether the caller is approved to execute
    ///         auction-based liquidations with a specific liquidation bonus.
    function isMarketUnlocked() public view returns (bool isUnlocked) {
        uint256 result;
        /// @solidity memory-safe-assembly
        assembly {
            result := tload(_TRANSIENT_MARKET_UNLOCKED_KEY)
        }

        // CASE: This is not an Auction tx, so allow all markets,
        // and return false, the caller is not approved for auction-based
        // liquidations. 
        if (result == 0) {
            return isUnlocked;
        }

        // True if the caller is approved for auction-based liquidations,
        // otherwise false.
        isUnlocked = uint256(uint160(msg.sender)) == result;
    }

    /// CONTRACT MAPPING LOGIC

    /// @notice Sets an external calldata checker contract.
    /// @dev Only callable on a 5-day delay or by the Emergency Council.
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
    /// @dev Only callable on a 5-day delay or by the Emergency Council.
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
    /// @dev Only callable on a 5-day delay or by the Emergency Council.
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
        address cachedProvider;

        for (uint256 i; i < numProviders; ++i) {
            cachedProvider = providers[i];
            if (isMulticallProvider[cachedProvider] == supported) {
                _revert(_PARAMETERS_MISCONFIGURED_SELECTOR);
            }

            isMulticallProvider[cachedProvider] = supported;
            emit MulticallProviderSet(cachedProvider, supported);
        }
    }

    /// @notice Returns an array of Chain IDs recorded in the Crosschain
    /// Protocol's Chain ID format.
    function foreignChainIds() external view returns (uint256[] memory) {
        return _foreignChainIds;
    }

    /// @notice Returns an array of Curvance markets on this chain.
    function marketManagers() external view returns (address[] memory) {
        return _marketManagers;
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Returns true if this contract implements the interface defined
    ///         by `interfaceId`.
    /// @param interfaceId The interface to check for implementation.
    /// @return Whether `interfaceId` is implemented or not.
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(ICentralRegistry).interfaceId ||
            interfaceId == type(IActionRegistry).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Remove Chain ID from foreign chain id array.
    /// @param chainId Chain ID to remove.
    function _removeForeignChainId(uint256 chainId) internal {
        uint256 i;
        uint256 numForeignChainIds = _foreignChainIds.length;

        for (; i < numForeignChainIds; ++i) {
            if (_foreignChainIds[i] == chainId) {
                break;
            }
        }

        numForeignChainIds--;

        for (; i < numForeignChainIds; ++i) {
            _foreignChainIds[i] = _foreignChainIds[i + 1];
        }

        _foreignChainIds.pop();
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

    /// @notice Checks whether a core contract should be allowed to be set.
    /// @dev If the contract is already set and needs to be updated, make sure
    ///      reward system as not already started, ossifying contracts.
    function _checkCanSetCoreContract(address coreContract) internal view {
        if (coreContract == address(0)) {
            return;
        }

        if (genesisEpoch <= block.timestamp) {
            _revert(_EPOCH_HAS_STARTED_SELECTOR);
        }
    }
}
