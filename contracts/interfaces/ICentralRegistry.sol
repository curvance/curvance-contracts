// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// TYPES ///

/// @title Chain Data
/// @notice Struct containing information on a chain's data.
/// @param isSupported Whether the chain is supported or not.
///                    2 = yes
///                    0 or 1 = no
/// @param messagingHub Messaging Hub address on the chain.
/// @param votingHub Voting Hub address on the chain.
/// @param cveAddress CVE address on the chain.
/// @param feeTokenAddress Fee token address on the chain.
/// @param messagingChainId Messaging Chain ID where this address authorized.
/// @param crosschainRelayer Crosschain relayer address on the chain.
/// @param domain Domain for the chain.
struct ChainData {
    uint256 isSupported;
    address messagingHub;
    address votingHub;
    address cveAddress;
    address feeTokenAddress;
    uint16 messagingChainId;
    address crosschainRelayer;
    uint32 domain;
}

interface ICentralRegistry {
    /// @notice The length of one protocol epoch, in seconds.
    function EPOCH_DURATION() external view returns (uint256);

    /// @notice Returns Genesis Epoch Timestamp of Curvance.
    function genesisEpoch() external view returns (uint256);

    /// @notice Sequencer Uptime Feed address for L2.
    function sequencer() external view returns (address);

    /// @notice Returns Protocol DAO address.
    function daoAddress() external view returns (address);

    /// @notice Returns whether the address has dao permissions or not.
    function hasDaoPermissions(
        address addressToCheck
    ) external view returns (bool);

    /// @notice Returns whether the address has elevated permissions or not.
    function hasElevatedPermissions(
        address addressToCheck
    ) external view returns (bool);

    /// @notice Returns whether the address has lock creation permissions
    ///         or not.
    function hasLockingPermissions(
        address addressToCheck
    ) external view returns (bool);

    /// @notice Returns whether the address has Auction permissions or not.
    function hasAuctionPermissions(
        address addressToCheck
    ) external view returns (bool);

    /// @notice Returns whether the address has Harvest permissions or not.
    function hasHarvestPermissions(
        address addressToCheck
    ) external view returns (bool);

    /// @notice Returns Reward Manager address.
    function rewardManager() external view returns (address);

    /// @notice Returns Gauge Manager address.
    function gaugeManager() external view returns (address);

    /// @notice Returns CVE address.
    function cve() external view returns (address);

    /// @notice Returns veCVE address.
    function veCVE() external view returns (address);

    /// @notice Returns Voting Hub address.
    function votingHub() external view returns (address);

    /// @notice Returns Messaging Hub address.
    function messagingHub() external view returns (address);

    /// @notice Returns Oracle Manager address.
    function oracleManager() external view returns (address);

    /// @notice Returns Fee Manager address.
    function feeManager() external view returns (address);

    /// @notice Returns Fee Token address.
    function feeToken() external view returns (address);

    /// @notice Returns Crosschain Core contract address.
    function crosschainCore() external view returns (address);

    /// @notice Returns Crosschain Relayer contract address.
    function crosschainRelayer() external view returns (address);

    /// @notice Returns Token Messenger contract address.
    function tokenMessager() external view returns (address);

    /// @notice Returns Messenger Transmitter contract address.
    function messageTransmitter() external view returns (address);

    /// @notice Returns domain value.
    function domain() external view returns (uint32);

    /// @notice Returns protocolCompoundFee, in `WAD`.
    function protocolCompoundFee() external view returns (uint256);

    /// @notice Returns protocolYieldFee, in `WAD`.
    function protocolYieldFee() external view returns (uint256);

    /// @notice Returns protocolHarvestFee, in `WAD`.
    function protocolHarvestFee() external view returns (uint256);

    /// @notice Returns protocolLeverageFee, in `WAD`.
    function protocolLeverageFee() external view returns (uint256);

    /// @notice Returns slippage limit, in `WAD`.
    function slippageLimit() external view returns (uint256);

    /// @notice Lending Market => Protocol Reserve Factor on interest
    ///         generated.
    function protocolInterestFee(
        address market
    ) external view returns (uint256);

    /// @notice Returns earlyUnlockPenaltyMultiplier value, in `Basis Points`
    function earlyUnlockPenaltyMultiplier() external view returns (uint256);

    /// @notice Returns voteBoostMultiplier value, in `Basis Points`
    function voteBoostMultiplier() external view returns (uint256);

    /// @notice Returns lockBoostMultiplier value, in `Basis Points`
    function lockBoostMultiplier() external view returns (uint256);

    /// @notice Returns an array of Chain IDs recorded in the Messaging Layers
    ///         Chain ID format.
    function getForeignChainIds() external view returns (uint256[] memory);

    /// @notice Returns an array of Curvance markets on this chain.
    function getMarketManagers() external view returns (address[] memory);

    /// @notice Increments a caller's approval index.
    /// @dev By incrementing their approval index, a user's delegates will all
    ///      have their delegation authority revoked across all Curvance
    ///      contracts.
    ///      Emits an {ApprovalIndexIncremented} event.
    function incrementApprovalIndex() external;

    /// @notice Returns `user`'s approval index.
    /// @param user The user to check approval index for.
    function getUserApprovalIndex(
        address user
    ) external view returns (uint256);

    /// @notice Returns whether a user has delegation disabled.
    /// @param user The user to check delegation status for.
    function checkDelegationDisabled(
        address user
    ) external view returns (bool);

    /// @notice Returns whether a particular GETH chainId is supported.
    /// ChainId => messagingHub address, 2 = supported; 1 = unsupported.
    function supportedChainData(
        uint256 chainId
    ) external view returns (ChainData memory);

    // Messaging specific ChainId => GETH comparable ChainId.
    function messagingToGETHChainId(
        uint16 chainId
    ) external view returns (uint256);

    // GETH comparable ChainId => Messaging specific ChainId.
    function GETHToMessagingChainId(
        uint256 chainId
    ) external view returns (uint16);

    /// @notice Returns whether the inputted address is a Multicall provider.
    function isMulticallProvider(
        address addressToCheck
    ) external view returns (bool);

    /// @notice Returns whether the inputted address is a Market Manager.
    function isMarketManager(
        address addressToCheck
    ) external view returns (bool);

    function externalCalldataChecker(
        address addressToCheck
    ) external view returns (address);

    function multicallChecker(
        address addressToCheck
    ) external view returns (address);

    function isAtlasOevAllowed() external view returns (bool);
    /// @notice Returns the amount of CVE rewards allocated on this chain,
    ///         for an epoch.
    function emissionsAllocatedByEpoch(
        uint256 epoch
    ) external view returns (uint256);

    /// @notice Returns the amount of CVE rewards allocated across all chains,
    ///         for an era.
    function targetEmissionAllocationByEra(
        uint256 era
    ) external view returns (uint256);

    /// @notice Sets the amount of CVE rewards allocated on this chain,
    ///         for an epoch.
    function setEmissionsAllocatedByEpoch(
        uint256 epoch,
        uint256 emissionsAllocated
    ) external;
}
