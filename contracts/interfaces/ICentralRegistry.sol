// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// TYPES ///

/// @title Chain Data
/// @notice Struct containing information on a chain's data.
/// @param isSupported Whether the chain is supported or not.
///                    2 = yes
///                    0 or 1 = no
/// @param messagingChainId Messaging Chain ID where this address authorized.
/// @param domain Domain for the chain.
/// @param messagingHub Messaging Hub address on the chain.
/// @param votingHub Voting Hub address on the chain.
/// @param cveAddress CVE address on the chain.
/// @param feeTokenAddress Fee token address on the chain.
/// @param crosschainRelayer Crosschain relayer address on the chain.
struct ChainConfig {
    bool isSupported;
    uint16 messagingChainId;
    uint32 domain;
    address messagingHub;
    address votingHub;
    address cveAddress;
    address feeTokenAddress;
    address crosschainRelayer;
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

    /// @notice Returns Protocol Emergency Council address.
    function emergencyCouncil() external view returns (address);

    /// @notice Indicates if address has DAO permissions or not.
    function hasDaoPermissions(
        address addressToCheck
    ) external view returns (bool);

    /// @notice Indicates if address has elevated DAO permissions or not.
    function hasElevatedPermissions(
        address addressToCheck
    ) external view returns (bool);

    /// @notice Indicates if address has lock creation permissions or not.
    function hasLockingPermissions(
        address addressToCheck
    ) external view returns (bool);

    /// @notice Indicates if address has auction permissions or not.
    function hasAuctionPermissions(
        address addressToCheck
    ) external view returns (bool);

    /// @notice Indicates if address has market permissions or not.
    function hasMarketPermissions(
        address addressToCheck
    ) external view returns (bool);

    /// @notice Indicates if address has harvest permissions or not.
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

    /// @notice Returns protocol gas fee on harvest, in `WAD`.
    function protocolCompoundFee() external view returns (uint256);

    /// @notice Returns protocol yield fee on strategy harvest, in `WAD`.
    function protocolYieldFee() external view returns (uint256);

    /// @notice Returns protocol yield + gas fee on strategy harvest,
    ///         in `WAD`.
    function protocolHarvestFee() external view returns (uint256);

    /// @notice Returns protocol fee on leverage actions, in `WAD`.
    function protocolLeverageFee() external view returns (uint256);

    /// @notice Returns protocol fee on interest generated in `market`.
    function protocolInterestFee(
        address market
    ) external view returns (uint256);

    /// @notice Returns earlyUnlockPenaltyMultiplier value, in `Basis Points`.
    function earlyUnlockPenaltyMultiplier() external view returns (uint256);

    /// @notice Returns voteBoostMultiplier value, in `Basis Points`.
    function voteBoostMultiplier() external view returns (uint256);

    /// @notice Returns lockBoostMultiplier value, in `Basis Points`.
    function lockBoostMultiplier() external view returns (uint256);

    /// @notice Returns swap slippage limit, in `WAD`.
    function slippageLimit() external view returns (uint256);

    /// @notice Returns an array of Chain IDs recorded in the Crosschain
    ///         Protocol's Chain ID format.
    function foreignChainIds() external view returns (uint256[] memory);

    /// @notice Returns an array of Curvance markets on this chain.
    function marketManagers() external view returns (address[] memory);

    /// @notice Increments a caller's approval index.
    /// @dev By incrementing their approval index, a user's delegates will all
    ///      have their delegation authority revoked across all Curvance
    ///      contracts.
    ///      Emits an {ApprovalIndexIncremented} event.
    function incrementApprovalIndex() external;

    /// @notice Returns `user`'s approval index.
    /// @param user The user to check approval index for.
    function userApprovalIndex(address user) external view returns (uint256);

    /// @notice Returns whether a user has delegation disabled.
    /// @param user The user to check delegation status for.
    function checkDelegationDisabled(
        address user
    ) external view returns (bool);

    /// @notice Returns whether a particular GETH chainId is supported.
    /// ChainId => messagingHub address, 2 = supported; 1 = unsupported.
    function chainConfig(
        uint256 chainId
    ) external view returns (ChainConfig memory);

    // Messaging specific ChainId => GETH comparable ChainId.
    function messagingToGETHChainId(
        uint16 chainId
    ) external view returns (uint256);

    // GETH comparable ChainId => Messaging specific ChainId.
    function GETHToMessagingChainId(
        uint256 chainId
    ) external view returns (uint16);

    /// @notice Indicates if an address is a market manager or not.
    function isMarketManager(
        address addressToCheck
    ) external view returns (bool);

    /// @notice Indicates if an address is a multicall provider or not.
    function isMulticallProvider(
        address addressToCheck
    ) external view returns (bool);

    /// @notice Maps an intent target address to the contract that will
    ///         inspect provided external calldata.
    function externalCalldataChecker(
        address addressToCheck
    ) external view returns (address);

    /// @notice Maps a Multicall target address to the contract that will
    ///         inspect provided multicall calldata.
    function multicallChecker(
        address addressToCheck
    ) external view returns (address);

    /// @notice Indicates the amount of token rewards allocated on this chain,
    ///         for an epoch.
    function emissionsAllocatedByEpoch(
        uint256 epoch
    ) external view returns (uint256);

    /// @notice Indicates the amount of token rewards allocated across all
    ///         chains, for an era. An era is a particular period in time in
    ///         which rewards are constant, before a halvening event moves the
    ///         protocol to a new era.
    function targetEmissionAllocationByEra(
        uint256 era
    ) external view returns (uint256);

    /// @notice Checks if a market is unlocked for auction operations.
    /// @return Whether the caller is an unlocked market, approved for
    ///         auction-based liquidations.
    function isMarketUnlocked() external view returns (bool);

    /// @notice Sets the amount of token rewards allocated on this chain,
    ///         for an epoch.
    /// @dev Only callable by the Voting Hub.
    /// @param epoch The epoch having its token emission values set.
    /// @param emissionsAllocated The amount of token rewards allocated on
    ///                           this chain, for an epoch.
    function setEmissionsAllocatedByEpoch(
        uint256 epoch,
        uint256 emissionsAllocated
    ) external;

    /// @notice Checks whether `user` has transferability enabled or disabled
    ///         for their tokens.
    /// @dev This is inherited from ActionRegistry portion of centralRegistry.
    /// @param user The address to check whether transferability is enabled or
    ///             disabled for.
    /// @return result Indicates whether `user` has transferability disabled
    ///                or not, true = disabled, false = not disabled.
    function checkTransfersDisabled(
        address user
    ) external view returns (bool result);
}
