// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { CVEBase } from "contracts/token/CVEBase.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @notice Curvance DAO's Canonical CVE Contract.
contract CVE is CVEBase {
    /// CONSTANTS ///

    /// @notice Seconds in a month based on 365.2425 days.
    uint256 public constant MONTH = 2_629_746;

    // Timestamp when token was created
    uint256 public immutable tokenGenerationEventTimestamp;
    /// @notice DAO treasury allocation of CVE,
    ///         can be minted as needed by the DAO. 14.5%.
    uint256 public immutable daoTreasuryAllocation;
    /// @notice Initial community allocation of CVE,
    ///         can be minted as needed by the DAO. 3.75%.
    uint256 public immutable initialCommunityAllocation;
    /// @notice Buildier allocation of CVE,
    ///         can be minted on a monthly basis. 13.5%
    uint256 public immutable builderAllocation;
    /// @notice 3% as veCVE immediately, 10.5% vested over 4 years.
    uint256 public immutable builderAllocationPerMonth;

    /// STORAGE ///

    /// @notice Builder operating address.
    address public builderAddress;
    /// @notice Pending builder operating address.
    address public pendingBuilderAddress;
    /// @notice Number of DAO treasury tokens minted.
    uint256 public daoTreasuryMinted;
    /// @notice Number of Builder allocation tokens minted.
    uint256 public builderAllocationMinted;
    /// @notice Number of Call Option reserved tokens minted.
    uint256 public initialCommunityMinted;

    /// ERRORS ///

    error CVE__InsufficientCVEAllocation();

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address builder_
    ) CVEBase(centralRegistry_) {
        if (builder_ == address(0)) {
            builder_ = msg.sender;
        }

        tokenGenerationEventTimestamp = block.timestamp;
        builderAddress = builder_;

        // All allocations and mints are in 18 decimal form to match CVE.

        // 60,900,010 tokens minted as needed by the DAO.
        daoTreasuryAllocation = 60900010e18;
        // 15,750,002.59 tokens (3.75%) minted on conclusion of LBP.
        initialCommunityAllocation = 1575000259e16;
        // 44,100,007.245 tokens (10.5%) vested over 4 years.
        builderAllocation = 44100007245e15;
        // Builder Vesting is for 4 years and unlocked monthly.
        builderAllocationPerMonth = builderAllocation / 48;

        // 50,400,008.285 (12%) minted initially for:
        // 29,400,004.83 (7%) from Capital Raises.
        // 12,600,002.075 (3%) builder veCVE initial allocation.
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

    /// @notice Mint CVE from builder allocation.
    /// @dev Allows the DAO Manager to mint new tokens for the builder
    ///      allocation.
    /// @dev The amount of tokens minted is calculated based on the time passed
    ///      since the Token Generation Event.
    /// @dev The number of tokens minted is capped by the total builder allocation.
    function mintBuilder() external {
        if (msg.sender != builderAddress) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        uint256 timeSinceTGE = block.timestamp - tokenGenerationEventTimestamp;
        uint256 monthsSinceTGE = timeSinceTGE / MONTH;
        uint256 _builderAllocationMinted = builderAllocationMinted;

        uint256 amount = (monthsSinceTGE * builderAllocationPerMonth) -
            _builderAllocationMinted;

        if (builderAllocation <= _builderAllocationMinted + amount) {
            amount = builderAllocation - builderAllocationMinted;
        }

        if (amount == 0) {
            revert CVE__ParametersAreInvalid();
        }

        builderAllocationMinted = _builderAllocationMinted + amount;
        _mint(msg.sender, amount);
    }

    /// @notice Sets the pending builder address to be claimed by `newAddress`.
    /// @dev Allows the builder address to hand off its authority to another address.
    /// @param newAddress The new address that can claim builder role.
    function setPendingBuilderAddress(address newAddress) external {
        if (msg.sender != builderAddress) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        pendingBuilderAddress = newAddress;
    }

    /// @notice Sets the builder address.
    /// @dev Allows the builders to change the builder's address.
    function claimBuilderAddress() external {
        if (msg.sender != pendingBuilderAddress) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        builderAddress = msg.sender;
    }

    /// INTERNAL FUNCTIONS ///

    /// @dev Checks whether the caller has sufficient permissioning.
    function _checkElevatedPermissions() internal view {
        if (!centralRegistry.hasElevatedPermissions(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }
    }
}
