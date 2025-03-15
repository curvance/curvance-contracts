// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { CVEBase } from "contracts/token/CVEBase.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @title CVE - Curvance Collective Token
/// @notice The canonical implementation of the Curvance governance and utility token.
/// @dev This contract extends CVEBase to implement the canonical CVE token with:
///      1. Token allocation management for different stakeholders
///      2. Vesting schedules for contributor allocations
///      3. Minting controls for various token allocations
///      4. Role-based permissions for allocation management
///
///      The allocation system includes:
///      - DAO Treasury: 14.5% (60,900,010 tokens) mintable as needed
///      - Initial Community: 3.75% (15,750,002.59 tokens) mintable after LBP
///      - Contributor: 13.5% (44,100,007.245 tokens) vested over 4 years
///      - Initial Mint: 12% (50,400,008.285 tokens) for early backers, contributor 
///        veCVE, and LBP allocation
///
///      All token amounts and allocations use 18 decimals. The canonical CVE contract
///      is deployed on the primary chain of the Curvance ecosystem, while RemoteCVE 
///      instances are deployed on secondary chains.
///
contract CVE is CVEBase {
    /// CONSTANTS ///

    /// @notice Seconds in a month based on 365.2425 days.
    uint256 public constant MONTH = 2_629_746;

    /// @notice DAO treasury allocation of CVE,
    ///         can be minted as needed by the DAO. 14.5%.
    uint256 public immutable daoTreasuryAllocation;
    /// @notice Initial community allocation of CVE,
    ///         can be minted as needed by the DAO. 3.75%.
    uint256 public immutable initialCommunityAllocation;
    /// @notice Buildier allocation of CVE,
    ///         can be minted on a monthly basis. 13.5%.
    uint256 public immutable contributorAllocation;
    /// @notice 3% as veCVE immediately, 10.5% vested over 4 years.
    uint256 public immutable contributorAllocationPerMonth;

    /// STORAGE ///

    /// @notice Contributor operating address.
    address public contributorAddress;
    /// @notice Pending contributor operating address.
    address public pendingContributorAddress;
    /// @notice Number of DAO treasury tokens minted.
    uint256 public daoTreasuryMinted;
    /// @notice Number of Contributor allocation tokens minted.
    uint256 public contributorAllocationMinted;
    /// @notice Number of reserved tokens for community distribution minted.
    uint256 public initialCommunityMinted;

    /// ERRORS ///

    error CVE__InsufficientCVEAllocation();

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address contributorAddress_
    ) CVEBase(centralRegistry_) {
        if (contributorAddress_ == address(0)) {
            contributorAddress_ = msg.sender;
        }

        contributorAddress = contributorAddress_;

        // All allocations and mints are in 18 decimal form to match CVE.

        // 60,900,010 tokens minted as needed by the DAO.
        daoTreasuryAllocation = 60900010e18;
        // 15,750,002.59 tokens (3.75%) minted on conclusion of LBP.
        initialCommunityAllocation = 1575000259e16;
        // 44,100,007.245 tokens (10.5%) vested over 4 years.
        contributorAllocation = 44100007245e15;
        // Contributor Vesting is for 4 years and unlocked monthly.
        contributorAllocationPerMonth = contributorAllocation / 48;

        // 50,400,008.285 (12%) minted initially for:
        // 29,400,004.83 (7%) for early backers.
        // 12,600,002.075 (3%) contributor veCVE initial allocation.
        // 8,400,001.38 (2%) LBP allocation.
        uint256 initialTokenMint = 50400008285e15;

        _mint(msg.sender, initialTokenMint);
    }

    /// ALLOCATED CVE MINTING FUNCTIONS ///

    /// @notice Mint CVE for the DAO treasury.
    /// @param amount The amount of treasury tokens to be minted.
    ///               The number of tokens to mint cannot not exceed
    ///               the available treasury allocation.
    function mintTreasury(uint256 amount) external {
        _checkElevatedPermissions();

        uint256 _daoTreasuryMinted = daoTreasuryMinted;
        if (daoTreasuryAllocation < _daoTreasuryMinted + amount) {
            revert CVE__InsufficientCVEAllocation();
        }

        daoTreasuryMinted = _daoTreasuryMinted + amount;
        _mint(msg.sender, amount);
    }

    /// @notice Mint CVE for deposit into callOptionCVE contract.
    /// @param amount The amount of call option tokens to be minted.
    ///               The number of tokens to mint cannot not exceed
    ///               the available call option allocation.
    function mintCommunityAllocation(uint256 amount) external {
        _checkDaoPermissions();

        uint256 _initialCommunityMinted = initialCommunityMinted;
        if (initialCommunityAllocation < _initialCommunityMinted + amount) {
            revert CVE__InsufficientCVEAllocation();
        }

        initialCommunityMinted = _initialCommunityMinted + amount;
        _mint(msg.sender, amount);
    }

    /// @notice Mint CVE from contributor allocation.
    /// @dev Allows the DAO Manager to mint new tokens for the contributor
    ///      allocation.
    /// @dev The amount of tokens minted is calculated based on the time passed
    ///      since the Token Generation Event.
    /// @dev The number of tokens minted is capped by the total contributor allocation.
    function mintContributor() external {
        if (msg.sender != contributorAddress) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        uint256 timeSinceTGE = block.timestamp - _genesisEpoch();
        uint256 monthsSinceTGE = timeSinceTGE / MONTH;
        uint256 _contributorAllocationMinted = contributorAllocationMinted;

        uint256 amount = (monthsSinceTGE * contributorAllocationPerMonth) -
            _contributorAllocationMinted;

        if (contributorAllocation <= _contributorAllocationMinted + amount) {
            amount = contributorAllocation - contributorAllocationMinted;
        }

        if (amount == 0) {
            revert CVE__ParametersAreInvalid();
        }

        contributorAllocationMinted = _contributorAllocationMinted + amount;
        _mint(msg.sender, amount);
    }

    /// @notice Sets the pending contributor address to be claimed by `newAddress`.
    /// @dev Allows the contributor address to hand off its authority to another address.
    /// @param newAddress The new address that can claim contributor role.
    function setPendingContributorAddress(address newAddress) external {
        if (msg.sender != contributorAddress) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        pendingContributorAddress = newAddress;
    }

    /// @notice Sets the contributor address.
    /// @dev Allows `pendingContributorAddress` to claim their contributor address
    ///      role.
    function claimContributorAddress() external {
        if (msg.sender != pendingContributorAddress) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        contributorAddress = pendingContributorAddress;
        delete pendingContributorAddress;
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Returns the genesis epoch.
    /// @return The genesis epoch.
    function _genesisEpoch() internal view returns (uint256) {
        return centralRegistry.genesisEpoch();
    }

    /// @dev Checks whether the caller has sufficient permissioning.
    function _checkElevatedPermissions() internal view {
        if (!centralRegistry.hasElevatedPermissions(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }
    }
}
