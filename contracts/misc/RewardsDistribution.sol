// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";
import { ReentrancyGuard } from "contracts/libraries/ReentrancyGuardTransient.sol";

import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @title Curvance Rewards Distribution.
/// @notice Manages distribution of ERC20 rewards for Curvance users.
/// @dev A hub contract for handling all ERC20 rewards distribution inside
///      Curvance, based on Merkle Proofs. Users have a predetermined amount
///      of time to claim rewards allocated to them in various ERC20 tokens.
///
///      NOTE: Native Tokens are not intended to be supported by this
///            contract, nor are ERC777 or other callback related tokens,
///            or transfer token tokens, or any other weird ERC20
///            implementations.
///
///      Curvance DAO authorized addresses reserves the right to remove
///      allocated token rewards at any time for any need via
///      removeMerkleRoots().
///
contract RewardsDistribution is ReentrancyGuard {
    /// TYPES ///

    /// @title Rewards Configuration.
    /// @notice Stores configuration data for reward distribution.
    /// @param rewardToken The address of the token to distribute rewards in.
    /// @param claimEndTimestamp The timestamp by which rewards must be
    ///                          claimed by, in unix time.
    /// @param rewardAmount The total remaining rewards available for claim.
    struct RewardsConfig {
        address rewardToken;
        uint40 claimEndTimestamp;
        uint256 rewardAmount;
    }

    /// CONSTANTS ///

    /// @notice The maximum period of time that a rewards claim window should
    ///         be open for, in unix time.
    uint256 public constant MAXIMUM_CLAIM_WINDOW = 60 days;

    /// @notice The minimum period of time that a rewards claim window should
    ///         be open for, in unix time.
    uint256 public constant MINIMUM_CLAIM_WINDOW = 30 days;

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;

    /// STORAGE ///

    /// @notice Rewards claim state;
    /// @dev 1 = unpaused; 2 = paused.
    uint256 public isPaused = 2;

    /// @notice Documents how to distribute rewards to users.
    /// @dev Merkle Root => Rewards Distribution Configuration.
    mapping(bytes32 => RewardsConfig) public rewardsConfig;

    /// @notice Tracks user claims of allocated rewards.
    /// @dev User => Merkle Root => Rewards claimed.
    mapping(address => mapping(bytes32 => bool)) public rewardsClaimed;

    /// EVENTS ///

    event RewardsClaimed(
        bytes32 root,
        address claimer,
        address rewardAddress,
        uint256 amount
    );
    event RewardsRemoved(bytes32 root, address rewardAddress, uint256 amount);
    event ClaimingPaused(bool pauseState);

    /// ERRORS ///

    error RewardDistribution__Paused();
    error RewardDistribution__ParametersAreInvalid();
    error RewardDistribution__Unauthorized();
    error RewardDistribution__NotEligible();

    constructor(ICentralRegistry cr) {
        CentralRegistryLib._isCentralRegistry(cr);
        centralRegistry = cr;
    }

    /// @notice Claims rewards allocated to the caller.
    /// @dev Emits a {RewardsClaimed} event for each successful claim.
    /// @param roots Array of Merkle Roots to validate rewards claim from
    ///              using `amounts` and `proofs`.
    /// @param amounts Array containing requested reward claim amounts for
    ///                each root.
    /// @param proofs Array containing Bytes32 arrays containing merkle proofs
    ///               for each root.
    function claim(
        bytes32[] calldata roots,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external nonReentrant {
        if (isPaused == 2) {
            revert RewardDistribution__Paused();
        }

        uint256 numRoots = roots.length;
        if (numRoots != amounts.length || numRoots != proofs.length) {
            revert RewardDistribution__ParametersAreInvalid();
        }

        RewardsConfig memory config;
        bytes32 root;
        for (uint256 i; i < numRoots; ++i) {
            root = roots[i];
            config = rewardsConfig[root];
            // Validate that the claim data is correct and that there is not
            // somehow insufficient tokens to distribute, or that claim value
            // is equal to 0.
            if (amounts[i] > config.rewardAmount || amounts[i] == 0) {
                revert RewardDistribution__ParametersAreInvalid();
            }

            // Verify the caller has not claimed already.
            if (rewardsClaimed[msg.sender][root]) {
                revert RewardDistribution__NotEligible();
            }

            // Validate that this is a supported Merkle Root for claiming,
            // and that the claim period has not ended.
            if (_checkTimestamp(config.claimEndTimestamp)) {
                revert RewardDistribution__NotEligible();
            }

            // Compute the merkle leaf and verify the merkle proof.
            // We add padding so we do not run into leaf collision issues.
            if (
                !_verify(
                    proofs[i],
                    root,
                    keccak256(abi.encodePacked(msg.sender, config.rewardToken, amounts[i]))
                )
            ) {
                revert RewardDistribution__NotEligible();
            }

            // Document that the callers rewards has been claimed.
            rewardsClaimed[msg.sender][root] = true;
            config.rewardAmount = config.rewardAmount - amounts[i];

            // Transfer rewards to caller.
            SafeTransferLib
                .safeTransfer(config.rewardToken, msg.sender, amounts[i]);

            // Emit event indicating that the caller's rewards have been
            // claimed for the frontend.
            emit RewardsClaimed(root, msg.sender, config.rewardToken, amounts[i]);
        }
    }

    /// @notice Check whether a user has pending rewards to claim.
    /// @param user Address of the user to check for pending rewards.
    /// @param amount Amount of rewards expected to be pending claim.
    /// @param proof Array containing the merkle proof for `root`.
    function canClaim(
        address user,
        bytes32 root,
        uint256 amount,
        bytes32[] calldata proof
    ) external view returns (bool) {
        // Validate that reward claiming is not currently paused.
        if (isPaused == 2) {
            return false;
        }

        // Validate that a Merkle Root was properly provided.
        if (root == bytes32(0)) {
            return false;
        }

        RewardsConfig memory config = rewardsConfig[root];
        // Validate the caller did not already claim the rewards,
        // if there are any.
        if (!rewardsClaimed[msg.sender][root]) {
            // Validate that this is a supported Merkle Root for claiming,
            // and that the claim period has not ended.
            if (_checkTimestamp(config.claimEndTimestamp)) {
                // Compute the leaf and verify the merkle proof.
                return 
                    _verify(
                        proof,
                        root,
                        keccak256(abi.encodePacked(user, config.rewardToken, amount))
                    );
            }
        }

        return false;
    }

    /// @notice Adds Merkle Root(s) configured to distribute rewards to users.
    /// @param newRoots An array containing new Markle Root(s) containing
    ///                 reward distribution data.
    /// @param rewardToken Array containing the token address(es) to
    ///                    distribute rewards in.
    /// @param rewardAmount An array containing the amounts of `rewardToken`
    ///                     to distribute via the Merkle Root(s).
    /// @param claimEndTimestamp An array containing the reward claim end
    ///                          timestamp for each Merkle Root, in unix time.
    function addMerkleRoots(
        bytes32[] calldata newRoots,
        address[] calldata rewardToken,
        uint256[] calldata rewardAmount,
        uint256[] calldata claimEndTimestamp
    ) external {
        _checkDaoPermissions();

        uint256 numRoots = newRoots.length;
        if (
            numRoots != rewardToken.length ||
            numRoots != rewardAmount.length ||
            numRoots != claimEndTimestamp.length
        ) {
            revert RewardDistribution__ParametersAreInvalid();
        }

        RewardsConfig memory config;
        bytes32 root;
        bytes32 priorRoot;
        for (uint256 i; i < numRoots; ++i) {
            root = newRoots[i];

            // Merkle Roots MUST be sorted offchain from smallest bytes32
            // value to largest to validate there are no duplicates, which
            // would accidently delete rewards.
            if (priorRoot >= root) {
                revert RewardDistribution__ParametersAreInvalid();
            }

            if (
                root == bytes32(0) ||
                rewardToken[i] == address(0) ||
                rewardAmount[i] == 0 ||
                claimEndTimestamp[i] > block.timestamp + MINIMUM_CLAIM_WINDOW ||
                claimEndTimestamp[i] < block.timestamp + MAXIMUM_CLAIM_WINDOW
            ) {
                revert RewardDistribution__ParametersAreInvalid();
            }

            SafeTransferLib.safeTransferFrom(
                rewardToken[i],
                msg.sender,
                address(this),
                rewardAmount[i]
            );

            config.rewardToken = rewardToken[i];
            config.rewardAmount = rewardAmount[i];
            config.claimEndTimestamp = uint40(claimEndTimestamp[i]);
            rewardsConfig[root] = config;

            /// Update prior root to current root.
            priorRoot = root;
        }
    }

    /// @notice Removes currently supported Merkle Root(s) configured to
    ///         distribute rewards to users, withdrawing unclaimed rewards.
    /// @param currentRoots An array containing Markle Root(s) currently
    ///                     providing reward distribution which will be
    ///                     disabled.
    function removeMerkleRoots(bytes32[] calldata currentRoots) external {
        _checkDaoPermissions();

        address daoAddress = centralRegistry.daoAddress();
        uint256 numRoots = currentRoots.length;
        bytes32 root;
        RewardsConfig memory config;
        uint256 rewardsRemaining;
        address rewardToken;

        for (uint256 i; i < numRoots; ++i) {
            root = currentRoots[i];
            config = rewardsConfig[root];

            // Validate `root` is a currently supported Merkle Root.
            if (config.claimEndTimestamp == 0) {
                revert RewardDistribution__ParametersAreInvalid();
            }

            rewardsRemaining = config.rewardAmount;
            rewardToken = config.rewardToken;
            delete rewardsConfig[root];

            if (rewardsRemaining > 0) {
                SafeTransferLib
                    .safeTransfer(rewardToken, daoAddress, rewardsRemaining);
                emit RewardsRemoved(root, rewardToken, rewardsRemaining);
            }
        }
    }

    /// @notice Set whether reward claiming is paused or not.
    /// @dev NOTE: Reward claim periods are not extended during paused state,
    ///            effectively reducing the available time for users to claim
    ///            rewards. Unless reconfigured via removeMerkleRoots()
    ///            followed by addMerkleRoots().
    /// @param paused New pause state.
    function setPauseState(bool paused) external {
        _checkDaoPermissions();

        isPaused = paused ? 2 : 1;
        emit ClaimingPaused(paused);
    }

    /// INTERNAL FUNCTIONS ///

    /// @dev Returns whether `leaf` exists in the Merkle tree with `root`,
    ///      given `proof`.
    function _verify(
        bytes32[] memory proof,
        bytes32 root,
        bytes32 leaf
    ) internal pure returns (bool isValid) {
        /// @solidity memory-safe-assembly
        assembly {
            if mload(proof) {
                // Initialize `offset` to the offset of `proof` elements in memory.
                let offset := add(proof, 0x20)
                // Left shift by 5 is equivalent to multiplying by 0x20.
                let end := add(offset, shl(5, mload(proof)))
                // Iterate over proof elements to compute root hash.
                for {} 1 {} {
                    // Slot of `leaf` in scratch space.
                    // If the condition is true: 0x20, otherwise: 0x00.
                    let scratch := shl(5, gt(leaf, mload(offset)))
                    // Store elements to hash contiguously in scratch space.
                    // Scratch space is 64 bytes (0x00 - 0x3f) and both elements are 32 bytes.
                    mstore(scratch, leaf)
                    mstore(xor(scratch, 0x20), mload(offset))
                    // Reuse `leaf` to store the hash to reduce stack operations.
                    leaf := keccak256(0x00, 0x40)
                    offset := add(offset, 0x20)
                    if iszero(lt(offset, end)) {
                        break
                    }
                }
            }
            isValid := eq(leaf, root)
        }
    }

    /// @dev Checks based on `endClaimTimestamp` if the merkle root can be
    ///      claimed from.
    function _checkTimestamp(
        uint256 endClaimTimestamp
    ) internal view returns (bool result) {
        result = endClaimTimestamp == 0 || block.timestamp >= endClaimTimestamp ?
            false : true;
    }

    /// @dev Checks whether the caller has sufficient permissioning.
    function _checkDaoPermissions() internal view {
        if (!centralRegistry.hasDaoPermissions(msg.sender)) {
            revert RewardDistribution__Unauthorized();
        }
    }
}